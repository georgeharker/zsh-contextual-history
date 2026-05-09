# Internals — motivation, discovery, and design

This document is the canonical "why and how" for `zsh-contextual-history`.
Both the [README](README.md) and the [Reddit announcement](REDDIT_POST.md)
link here for the source-level walkthrough — they each carry only a
short summary so the user-facing docs stay readable.

What you'll find below:

- Why the fork exists and what specifically diverges from upstream
- The zsh-source-level mechanism for each finding (with `Src/hist.c`
  line numbers verified against the source tree under `module/build/`)
- The fix that was chosen for each, and the alternatives ruled out
- Pointers to the PTY scenario tests under `tests/` that pin each finding

Every claim here has a corresponding test in the matrix. If you find a
disagreement between this doc and the test outcome, the test wins —
file an issue.

----------------------------------------------------------------------------

## Summary table

| Change from upstream | Reason |
|---|---|
| `$HISTFILE` is swapped on `chpwd`/toggle (was: `fc -p` inside `zshaddhistory`) | `fc -p` inside the addhistory hook is auto-popped by `hend()` (`Src/hist.c:1633`). The per-dir file never becomes zsh's authoritative `$HISTFILE`, so `SHARE_HISTORY`'s prompt-time merge never reads it. Same-directory cross-terminal sync is silently broken in upstream. |
| No `fc -AI` flush in mode-swap functions | `fc -AI` against an active history file triggers `savehistfile()`'s rewrite block (`Src/hist.c:3082-3098`), which truncates and rewrites the file. Concurrent SHARE readers see invalidated `lasthist.fpos` and silently lose entries. |
| Mode-N (no `SHARE`/`INC`) gets `fc -AI` flush at `chpwd`, gated to mode N | Without an explicit flush, in-memory entries get wiped at the `HISTSIZE=0; fc -R newfile` step before reaching disk. The rewrite-block hazard doesn't apply in mode N because there's no concurrent reader. |
| Tee writes the *inactive* store on every command, in extended-history format unconditionally | Keeps both stores ever-growing regardless of mode. `EXTENDED_HISTORY` is treated as display-only because `SHARE_HISTORY`'s incremental writer forces extended format internally — mixed format on disk perturbs the per-process `lasthist` tracker. |
| Tee uses zsh's actual lock protocol | Without it, multi-syscall writes (large pasted blobs) can interleave with stock zsh's incremental writers on the same file. |
| Optional native helper module | Calls zsh's own `lockhistfile`/`unlockhistfile` directly, plus a clean ring-replace builtin that avoids the 2-entry leak inherent to `HISTSIZE=2; fc -R`. Plugin gracefully falls back to pure-shell when not built. |
| Configurable contextual grouping | Per-directory granularity is too fine for project work. Walking up to a marker (`.histroot`, `.git`) gives one history file per project; stop-points bound the walk. |

----------------------------------------------------------------------------

## `SHARE_HISTORY` cross-terminal sync was broken in upstream

Two terminals, both started in the same directory, both with `setopt
SHARE_HISTORY`. Shell 1 runs commands. Shell 2 runs `history`.

**Upstream:** shell 2's `history` shows only its own startup commands.
None of shell 1's writes appear, even though they're on disk in the
per-directory file. The cross-shell merge that is `SHARE_HISTORY`'s
entire point silently doesn't happen.

**Fork:** shell 2's `history` shows all of shell 1's commands with the
`*` foreign-shell marker, exactly as `SHARE_HISTORY` is supposed to
deliver. Verified by `test_p01_share_idle_visibility.zsh`.

### Why upstream fails

Upstream's `_per-directory-history-addhistory` calls `fc -p
"$_per_directory_history_directory"` inside the `zshaddhistory` hook.
The intent: push the per-dir file onto zsh's history stack and make it
`$HISTFILE`, so subsequent prompt-time reads pull from the per-dir file.

Reading `Src/hist.c`:

- `1464` of `hend()`: `int flag, hookret, stack_pos = histsave_stack_pos;` — captures stack depth at start of hend.
- `1503-1514`: `zshaddhistory` hooks fire (where upstream's `fc -p` runs).
- `1517-1519`: SHARE_HISTORY's prompt-time read merge.
- `1627`: SHARE_HISTORY's incremental write.
- **`1633`: `while (histsave_stack_pos > stack_pos) pophiststack();`** — auto-pops anything pushed during the hook.

So upstream's `fc -p` push is auto-popped by `hend` before the hook
returns. From the user's perspective, `$HISTFILE` never observably
changes — it stays at the user's original global file. The
SHARE_HISTORY merge at line 1517 reads from the global file, never
from the per-directory file. The per-dir file is *write-only* from
SHARE_HISTORY's perspective, and other shells in the same directory
have no native zsh mechanism that re-reads it mid-session.

Empirical confirmation (probe script we wrote during the
investigation):

- Before triggering the hook: `$HISTFILE = /tmp/probe-orig.history`
- Inside the hook, after `fc -p`: `$HISTFILE = /tmp/probe-newfile.history`
- After the hook returns: `$HISTFILE = /tmp/probe-orig.history`

### Why the fork fixes it

The fork doesn't use `fc -p` from inside the addhistory hook. Instead,
on `chpwd` (or `precmd` first-run, or toggle), it directly assigns
`$HISTFILE` to the per-dir file using a clear-and-reload pattern:

```zsh
HISTFILE="$_context_history_directory"
local original_histsize=$HISTSIZE
HISTSIZE=0                                 # clear in-memory ring (or use module)
HISTSIZE=$original_histsize                # restore size
fc -R "$HISTFILE"                          # load new file content
```

`chpwd` runs *outside* `hend()`, so the assignment isn't auto-popped.
SHARE_HISTORY's next prompt-time merge reads from the per-dir file,
and cross-terminal merge in the same directory works as it should.

----------------------------------------------------------------------------

## The toggle bug: `fc -AI` is a cross-shell hazard

`fc -AI <file>` from a script:

- Calls `savehistfile(file, 1, HFILE_APPEND | HFILE_SKIPOLD)` (`Src/builtin.c:1513`).
- Inside `savehistfile`, the rewrite block at `Src/hist.c:3082-3098` fires when `HFILE_SKIPOLD` is set, `HFILE_FAST` is *not* set, and `HFILE_NO_REWRITE` is *not* set.
- The rewrite block does `pushhiststack`, `readhistfile(fn, ..., 0)`, `savehistfile(fn, ..., 0)`, `pophiststack`. The internal `savehistfile(fn, ..., 0)` opens with `O_TRUNC` (no `HFILE_APPEND`) and rewrites the entire file using the calling shell's view, possibly without timestamps if `EXTENDED_HISTORY` is unset.

So `fc -AI` rewrites the file out from under any concurrent reader.
SHARE_HISTORY's reader in the *other* shell tracks
`lasthist.fpos`/`lasthist.stim`/`lasthist.text` per-process — values
pointing into the pre-rewrite byte layout. After the rewrite, byte
offsets shift; the reader's `searching=1` lookup at the old
`lasthist.fpos` doesn't match; it falls back to `searching=-1` mode
and skips entries with `stim < lasthist.stim`. If the rewrite stripped
timestamps (because `EXTENDED_HISTORY` is off), all entries now have
`stim=0` and *all* get skipped.

Net effect: the *write* succeeds; the other shell *silently loses*
its entire incremental merge. No error, no log, just stale data.

The fix: removed the `fc -AI` calls in the swap functions entirely.
For SHARE/INC the entries are already on disk via incremental writes —
nothing to flush. For mode N see below.

----------------------------------------------------------------------------

## Why `fc -p` / `fc -P` aren't an option for the swap

A natural alternative to direct `$HISTFILE=` assignment is zsh's own
history-stack: `fc -p new_file` to enter, `fc -P` to leave. `fc -p`
is clean. But `fc -P` is `saveandpophiststack(-1, HFILE_USE_OPTIONS)`,
which calls `savehistfile(fn, 1, HFILE_USE_OPTIONS)`. With
`SHARE_HISTORY` set, flag inheritance at `Src/hist.c:2929-2931` adds
`HFILE_APPEND | HFILE_SKIPOLD` — the same rewrite-block hazard as
`fc -AI`. There's no script-level way to pass `HFILE_NO_REWRITE`.
Direct `$HISTFILE=` assignment is the only path that doesn't trip
the rewrite block.

----------------------------------------------------------------------------

## Mode-N flush: explicit, isolated from the cross-shell hazard

In mode N (neither `SHARE_HISTORY` nor `INC_APPEND_HISTORY`), zsh
doesn't write incrementally; commands are saved at shell exit. So a
`chpwd`-triggered ring-replace would discard pending in-memory
entries that haven't yet reached disk.

The fix: in mode N specifically, do `fc -AI "$HISTFILE"` before the
swap (`test_p14_mode_n_chpwd_flush.zsh` verifies this). Safe in mode
N because the rewrite-block hazard only damages *concurrent*
SHARE_HISTORY readers, and by definition there are no concurrent
SHARE readers in mode N. The user has explicitly opted out of the
live-merge mechanism.

----------------------------------------------------------------------------

## The tee: format and locking

The plugin tees every command to the *inactive* store via the
`zshaddhistory` hook, so toggling between context-history and
global-history always shows an up-to-date view of either store. Two
things had to get right.

**Always extended format.** `SHARE_HISTORY`'s incremental writer
forces `extended_history=1` internally (`Src/hist.c:2937`, inside the
`HFILE_USE_OPTIONS` block). Every entry it writes has a `:
timestamp:0;` prefix, regardless of the user's `EXTENDED_HISTORY`
shell option. Bare-format tees mixed with prefixed SHARE writes
produce a file where the per-process `lasthist` tracker can mis-search.
The tee always writes extended format; the user's option becomes
display-only.

**Lock coordination.** A naive tee is `print -r >> $file`. Single-line
`O_APPEND` writes are kernel-atomic, so for the typical case there's
no corruption. But a *huge* pasted command may exceed the stream
buffer and decompose into multiple `write(2)` syscalls, and a
concurrent SHARE writer holds zsh's `lockhistfile` lock around its
read-modify-write window — the two writers can interleave at write
boundaries. The tee acquires the *same lock* zsh's `lockhistfile`
acquires:

- **HIST_FCNTL_LOCK set**: `zsystem flock` (the `zsh/system` module's fcntl `F_WRLCK`).
- **default**: replicate the `<file>.LOCK` symlink protocol, including stale-detection by mtime > 10s, matching `Src/hist.c`'s `lockhistfile()` symlink path.

On lock-acquire timeout the tee proceeds lock-free rather than drop
the entry — losing data is strictly worse than briefly racing.

The optional native module exposes a `contextual-history-tee`
builtin that calls zsh's own `lockhistfile`/`unlockhistfile`
directly. Same coordination, done by zsh itself rather than emulated.

----------------------------------------------------------------------------

## The 2-entry ring-replace leak

The pure-shell ring-replace pattern `HISTSIZE=2; HISTSIZE=$orig; fc
-R newfile` leaks 2 entries from the previous context, because zsh's
`histsizesetfn` clamps the minimum at 2 (see `Src/params.c`). After
the trim, restoring HISTSIZE expands capacity but the lost entries
don't come back; `fc -R` then appends the new file's events on top of
2 stale survivors. Ring shape:

```
[2 leftover entries from prior context, ..., events from new file]
```

Walking `^P` past the new file's oldest entry exposes the leak.
`test_p11_toggle_leak.zsh` (mode toggle) and `test_p12_chpwd_leak.zsh`
(chpwd swap) both assert leak-present without the module.

The native module's `contextual-history-replace-ring <file>` builtin
walks `hist_ring` directly, freeing every entry, and then calls
`readhistfile()`. Same tests assert the ring is clean (no leak) when
the module is loaded.

----------------------------------------------------------------------------

## Contextual grouping

Per-physical-directory granularity is often too fine. A user with one
project rooted at `~/code/proj` and lots of subdirectories
(`~/code/proj/src/{a,b,c}`) gets a separate history file in each,
which fragments history that is conceptually one project's commands.

Two ways to group: marker-list config (single upward walk; closest
ancestor with any listed marker wins; bounded by `GROUP_STOPS`), or a
custom `_context-history-group()` resolver function that prints the
context key directly. Verified by `test_p15_group_by_marker.zsh`,
`test_p16_group_strategies.zsh`, and `test_p25_custom_resolver_edge_cases.zsh`.

The `_context-history-resolve-file` function normalizes the join
between `HISTORY_BASE` and the resolver's key — strips trailing `/`
from the base, leading `/` from the key, and special-cases empty key
(produces `$HISTORY_BASE/history`, the "all dirs collapse to one
file" mode).

----------------------------------------------------------------------------

## Investigation arc — what we got wrong along the way

For transparency about the discovery process:

1. **Original hypothesis**: "`fc -p` inside upstream's hook silently
   redirects `$HISTFILE`, so SHARE_HISTORY's prompt-time merge reads
   the wrong file." **Falsified** by the probe: the hook's `fc -p` is
   auto-popped before the hook returns. From the user's perspective,
   `$HISTFILE` never visibly changes. The *symptom* (SHARE_HISTORY
   same-dir merge fails in upstream) is real; the *mechanism* is the
   opposite — the per-dir file is write-only from SHARE_HISTORY's
   perspective because `$HISTFILE` never points at it during the merge
   window.

2. **Refined hypothesis**: "writes work but in-memory recall goes
   stale because SHARE_HISTORY's merge target shifts after `fc -p`."
   **Same falsification**: `fc -p`'s reassignment doesn't reach the
   merge in the first place. The recall doesn't go stale; it just
   never gets fresh data from the per-dir file.

3. **First fix attempt**: gate `fc -AI` to mode N. **Insufficient**:
   the rewrite-block hazard exists in `fc -P` too, and we'd hit it
   if we used `fc -p`/`fc -P` for the swap.

4. **Second fix attempt**: use `fc -p`/`fc -P` instead of direct
   `$HISTFILE=` (would give cleaner per-process `lasthist`
   isolation). **Rejected**: `fc -P` triggers the same rewrite block
   as `fc -AI`. There's no script-level escape.

5. **Final design**: direct `$HISTFILE=` swap; mode-N-gated `fc -AI`
   for non-incremental flush; lock-coordinated tee in extended format
   for the inactive store; optional native module for tighter lock
   coordination + clean ring replacement; contextual-grouping resolver
   as a layer above all of this.

----------------------------------------------------------------------------

## What this is *not*

It's *not* a candidate PR back to upstream as a stylistic refactor.
The fork's `$HISTFILE`-swap design is observably different from
upstream's `fc -p`-in-hook design (`$HISTFILE` is now mutable across
chpwd / toggle, and the user can see it via `echo $HISTFILE`). That's
a user-visible behavioural change that needs to be a documented
opt-in choice, not a silent merge.

It's also *not* a one-feature add. The set of changes
(SHARE_HISTORY compat + mode-N flush + lock-coordinated tee + optional
native module + contextual grouping) is enough that this is more
naturally a sibling project than a PR.

----------------------------------------------------------------------------

## Test coverage

25 PTY-based scenario tests under `tests/`, each covering one
behaviour grounded above. Run `make test` for the full matrix (both
module configs); `make test-upstream` runs the same suite against the
unmodified upstream plugin to demonstrate which findings translate
to specific test failures on upstream master.

Today's matrix outcome: 50/50 green on the fork (with module),
9 fork-fixed bugs failing on upstream, 6 baseline tests passing on
both.
