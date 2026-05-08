# Motivation

This document explains why `zsh-contextual-history` exists as a separate
fork rather than a PR back to `jimhester/per-directory-history`. The
short answer: getting per-directory history to work correctly under
`SHARE_HISTORY` (and to keep working correctly under all the corner
cases of mid-session toggling, mode flips, and concurrent shells)
required architectural changes deep enough that this is no longer the
upstream plugin, even if the user-facing surface is similar.

The long answer is below — six findings that together drove the fork's
design, each grounded in a reproducible scenario test under
`docs/tests/`.

## TL;DR of what changed and why

| Change | Reason |
|---|---|
| `$HISTFILE` is swapped on `chpwd`/toggle (was: `fc -p` inside `zshaddhistory`) | `fc -p` inside a `zshaddhistory` hook is function-scoped — `hend()` auto-pops the stack at line 1633 of `Src/hist.c`. So the per-dir file never becomes zsh's authoritative `$HISTFILE` from the user's perspective, and `SHARE_HISTORY`'s prompt-time merge never reads it. Same-directory cross-terminal sync is silently broken in upstream. |
| No `fc -AI` flush in mode-swap functions | `fc -AI` against an active history file triggers `savehistfile()`'s internal rewrite block (`Src/hist.c` lines 3082-3098), which truncates and rewrites the file. Other shells reading via `SHARE_HISTORY`'s incremental machinery see invalidated `lasthist.fpos` and silently lose entries. (The "s06 toggle bug.") |
| Mode-N (no `SHARE`/`INC`) gets `fc -AI` flush at `chpwd`, gated to mode N | Without an explicit flush, in-memory entries get wiped at the `HISTSIZE=0; fc -R newfile` step before reaching disk. The rewrite-block hazard doesn't apply in mode N because there's no concurrent reader. |
| Tee writes the *inactive* store on every command, in extended-history format unconditionally | Keeps both per-dir and global stores ever-growing, regardless of mode. `EXTENDED_HISTORY` is treated as display-only because `SHARE_HISTORY`'s incremental writer forces extended format internally — mixed format on disk perturbs the per-process `lasthist` tracker. |
| Tee uses zsh's actual lock protocol (`zsystem flock` if `HIST_FCNTL_LOCK`, else `<file>.LOCK` symlink) | Without it, multi-syscall writes (large pasted blobs) can interleave with stock zsh's incremental writers on the same file. |
| Optional native helper module (`pdh-tee` builtin) | Calls zsh's own `lockhistfile`/`unlockhistfile` directly. Strictest possible coordination, single-builtin call. Plugin gracefully falls back to pure-shell when not built. |
| Configurable contextual grouping (`GROUP_BY`, `GROUP_STOPS`, custom resolver) | Per-directory granularity is too fine for project work. Walking up to a marker (`.histroot`, `.git`) gives one history file per project; stoppoints bound the walk. |

The rest of this document expands each of these.

## Headline finding: `SHARE_HISTORY` cross-terminal sync is broken in upstream

**Test:** `docs/tests/test_s01_concurrent_share.zsh`. Two terminals
(driven via FIFOs against a shared `HISTROOT`, with marker-based
synchronisation), both started in `/tmp/pdh-mst-dirA`, both with
`setopt SHARE_HISTORY`. Shell 1 runs six commands. Shell 2 then runs
`history`.

**Upstream:** shell 2's `history` shows only its own startup commands.
None of shell 1's `cmd-N` writes appear, even though they're on disk
in the per-directory file. The cross-shell merge that is
`SHARE_HISTORY`'s entire point silently doesn't happen.

**Fork:** shell 2's `history` shows all six of shell 1's commands with
the `*` foreign-shell marker, exactly as `SHARE_HISTORY` is supposed
to deliver.

### Why upstream fails

Upstream's `_per-directory-history-addhistory` calls `fc -p
"$_per_directory_history_directory"` inside the `zshaddhistory` hook.
The intent: push the per-dir file onto zsh's history stack and make it
`$HISTFILE`, so subsequent prompt-time reads pull from the per-dir
file.

Reading `Src/hist.c`:

- Line 1464 of `hend()`: `int flag, hookret, stack_pos = histsave_stack_pos;` — captures stack depth at start of hend
- Line 1503-1514: `zshaddhistory` hooks fire (this is where upstream's `fc -p` runs)
- Line 1517-1519: SHARE_HISTORY's prompt-time read merge
- Line 1627: SHARE_HISTORY's incremental write
- **Line 1633: `while (histsave_stack_pos > stack_pos) pophiststack();`** — auto-pop anything pushed during the hook

So upstream's `fc -p` push is auto-popped by hend before the hook returns to the user. From the user's perspective, `$HISTFILE` never observably changes — it stays at the user's original global file. Verified empirically by `inputs/probe_fc_p_in_hook.zsh`:

- Before triggering the hook: `$HISTFILE = /tmp/probe-orig.history`
- Inside the hook, after `fc -p`: `$HISTFILE = /tmp/probe-newfile.history`
- After the hook returns: `$HISTFILE = /tmp/probe-orig.history`

Consequently, SHARE_HISTORY's prompt-time merge at line 1517 reads from
the user's global file, never from the per-directory file. The per-dir
file is *write-only* from SHARE_HISTORY's perspective. Other shells in
the same directory have no native zsh mechanism that would re-read the
per-dir file mid-session, so they don't see each other's writes.

### Why the fork fixes it

The fork doesn't use `fc -p` from inside the addhistory hook. Instead,
on `chpwd` (or `precmd` first-run, or toggle), it directly assigns
`$HISTFILE` to the per-dir file using a clear-and-reload pattern:

```zsh
HISTFILE="$_per_directory_history_directory"
local original_histsize=$HISTSIZE
HISTSIZE=0                                 # clear in-memory ring
HISTSIZE=$original_histsize                # restore size
fc -R "$HISTFILE"                          # load new file content
```

`chpwd` runs *outside* `hend()`, so the assignment isn't auto-popped.
SHARE_HISTORY's next prompt-time merge reads from the per-dir file,
and cross-terminal merge in the same directory works as it should.

## The s06 toggle bug: `fc -AI` is a cross-shell hazard

**Test:** `docs/tests/test_s06_concurrent_toggle.zsh`. Same as s01,
but shell 1 runs `per-directory-history-toggle-history` partway
through. Shell 2 then dumps `history`.

**Bug surfaced:** before the fix, shell 2 saw NONE of shell 1's
commands — not even the ones written before the toggle. Same in both
upstream and fork.

### Root cause

The fork's mode-swap functions originally called `fc -AI "$HISTFILE"`
to flush in-memory entries to the outgoing file before swapping. That
seemed harmless (and "near-no-op" when SHARE_HISTORY is on, since
entries are already incrementally on disk).

But `fc -AI <file>` from script:

- Calls `savehistfile(file, 1, HFILE_APPEND | HFILE_SKIPOLD)` (`Src/builtin.c` line 1513).
- Inside `savehistfile`, **the rewrite block at lines 3082-3098 fires** when `HFILE_SKIPOLD` is set, `HFILE_FAST` is *not* set, and `HFILE_NO_REWRITE` is *not* set.
- The rewrite block does `pushhiststack`, `readhistfile(fn, ..., 0)`, `savehistfile(fn, ..., 0)`, `pophiststack`. The internal `savehistfile(fn, ..., 0)` opens with `O_TRUNC` (no `HFILE_APPEND`) and rewrites the entire file using the calling shell's view, possibly without timestamps if `EXTENDED_HISTORY` is unset.

So `fc -AI` rewrites the file out from under any concurrent reader.
SHARE_HISTORY's reader in the *other* shell tracks `lasthist.fpos`/
`lasthist.stim`/`lasthist.text` per-process — values pointing into the
pre-rewrite byte layout. After the rewrite, byte offsets shift; the
reader's `searching=1` lookup at the old `lasthist.fpos` doesn't
match; it falls back to `searching=-1` mode and skips entries with
`stim < lasthist.stim`. If the rewrite stripped timestamps (because
`EXTENDED_HISTORY` is off), all entries now have `stim=0` and *all*
get skipped.

Net effect: shell 2 sees nothing.

### Why this also rules out `fc -p`/`fc -P` for the swap

A natural alternative to direct `$HISTFILE=` assignment is to use
zsh's own history-stack: `fc -p new_file` to enter, `fc -P` to
leave. `fc -p` is clean (it doesn't touch existing files). But `fc -P`
is `saveandpophiststack(-1, HFILE_USE_OPTIONS)`, which calls
`savehistfile(fn, 1, HFILE_USE_OPTIONS)`. With `SHARE_HISTORY` set,
flag inheritance at lines 2929-2931 adds `HFILE_APPEND |
HFILE_SKIPOLD`. The rewrite block fires for the same reasons as
above. Same hazard, different door.

There's no shell-script way to pass `HFILE_NO_REWRITE` to `fc -P`.
Direct `$HISTFILE=` assignment is the only path that doesn't trip the
rewrite block.

### The fix

Removed the `fc -AI` calls in the swap functions entirely. For the
SHARE/INC case the entries are already on disk via incremental writes
— there's nothing to flush. For the mode-N case (no incremental
options), see the next section.

## Mode-N: explicit flush, isolated from the cross-shell hazard

In mode N (neither `SHARE_HISTORY` nor `INC_APPEND_HISTORY`), zsh
doesn't write incrementally; commands are saved at shell exit. So
`chpwd`-triggered `HISTSIZE=0; fc -R newfile` would discard pending
in-memory entries that haven't yet reached disk.

The fix: in mode N specifically, do `fc -AI "$HISTFILE"` before the
swap (`docs/tests/test_s08_mode_N_chpwd_flush.zsh` verifies this).

This is safe in mode N because the `fc -AI` rewrite only damages
*concurrent* SHARE_HISTORY readers — and by definition there are no
concurrent SHARE readers in mode N. The user has explicitly opted out
of the live-merge mechanism.

## The tee: format and locking

The plugin tees every command to the *inactive* store via the
`zshaddhistory` hook, so toggling between dir-history and global-history
always shows an up-to-date view of either store. Two things had to
get right.

### Always extended format

`SHARE_HISTORY`'s incremental writer forces `extended_history=1`
internally (`Src/hist.c` line 2937, inside the `HFILE_USE_OPTIONS`
block). So every entry it writes has a `: timestamp:0;` prefix,
regardless of the user's `EXTENDED_HISTORY` shell option.

Bare-format tees mixed with prefixed SHARE writes produce a file
where the per-process `lasthist` tracker can mis-search. Fix: the tee
always writes the extended format, regardless of the user's shell
option. The shell option becomes display-only.

### Lock coordination

A naive tee is `print -r >> $file`. Single-line `O_APPEND` writes are
kernel-atomic, so for the typical case there's no corruption. But:

- A *huge* pasted command may exceed the stream buffer and decompose into multiple `write(2)` syscalls.
- A concurrent SHARE writer in another shell holds zsh's `lockhistfile` lock around its read-modify-write window.

The two writers can interleave at write boundaries when our tee
splits across syscalls, producing entries with bytes from both
shells.

The fix: the tee acquires the *same lock* zsh's `lockhistfile`
acquires — picking the protocol from the `HIST_FCNTL_LOCK` option:

- **HIST_FCNTL_LOCK set**: `zsystem flock` (the `zsh/system` module's fcntl `F_WRLCK`).
- **default**: replicate the `<file>.LOCK` symlink protocol, including stale-detection by mtime > 10s, matching `Src/hist.c`'s `lockhistfile()` symlink path.

On lock-acquire timeout the tee proceeds lock-free rather than drop
the entry — losing data is strictly worse than briefly racing.

### Optional native module

The pure-shell tee replicates zsh's lock protocol from script. The
optional `zsh/pdh` module exposes a `pdh-tee` builtin that calls zsh's
own `lockhistfile`/`unlockhistfile` directly. Same coordination, but
done by zsh itself rather than emulated. The plugin auto-detects the
module on `$module_path` and uses it if present; otherwise falls
through to the pure-shell path. The matrix passes 11/11 in both modes.

See `module/README.md` for build details.

## Contextual grouping

Per-physical-directory granularity is often too fine. A user with one
project rooted at `~/code/proj` and lots of subdirectories
(`~/code/proj/src/{a,b,c}`) gets a separate history file in each,
which fragments history that is conceptually one project's commands.

The plugin offers two ways to group:

### Marker-list config

```zsh
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
PER_DIRECTORY_HISTORY_GROUP_STOPS=($HOME)
```

The resolver does **one** upward walk from `$PWD`. At each ancestor
it checks for any of the listed markers; **first ancestor with any
marker wins** (closest-ancestor semantics). If walk-up reaches a
`STOPS` path or `/` without finding a marker, falls back to `${PWD:A}`
(per-physical-dir behaviour).

Two scenario tests:

- `test_s09_group_by_marker.zsh`: subdirs of one `.git` project share one history file.
- `test_s10_group_strategies.zsh`: closest ancestor wins (nested `.git` beats outer `.histroot` if `.git` is closer); stop point blocks reaching higher markers.

### Custom resolver

For arbitrary logic, redefine `_per-directory-history-group()`. It
takes no arguments and prints a canonical "group key" (typically a
path). Whatever it prints becomes part of the history file's path
under `$HISTORY_BASE`.

A helper `_per-directory-history-walk-up <markers...>` is exposed so
custom resolvers can compose against the same walk-up semantics.

## On the rename

The fork was originally named `per-directory-history` (matching
upstream). After the resolver/grouping work it's no longer accurately
described as "per-directory" — the unit is "context", which can be
anything from one physical directory to one project root to a custom
group key. Rename: `zsh-contextual-history`.

Internal symbol names (`_per_directory_history_*`) are kept as-is for
now; renaming them would be a breaking change for any user who has
referenced them in their `.zshrc` (advanced override case). A `v2` cut
can do the wholesale internal rename.

## Investigation arc — what we got wrong along the way

For transparency about the discovery process:

1. **Original hypothesis**: "`fc -p` inside upstream's hook silently
   redirects `$HISTFILE`, so SHARE_HISTORY's prompt-time merge reads
   the wrong file." **Falsified** by `probe_fc_p_in_hook.zsh`: the
   hook's `fc -p` is auto-popped before the hook returns. From the
   user's perspective, `$HISTFILE` never visibly changes. The
   *symptom* (SHARE_HISTORY same-dir merge fails in upstream) is
   real; the *mechanism* is the opposite — the per-dir file is
   write-only from SHARE_HISTORY's perspective because `$HISTFILE`
   never points at it during the merge window.

2. **Refined hypothesis**: "writes work but in-memory recall goes
   stale because SHARE_HISTORY's merge target shifts after `fc -p`."
   **Same falsification**: `fc -p`'s reassignment doesn't reach the
   merge in the first place. The recall doesn't go stale; it just
   never gets fresh data from the per-dir file.

3. **First fix attempt**: gate `fc -AI` to mode N. **Insufficient**:
   the rewrite-block hazard exists in `fc -P` too, and we'd hit it
   if we used `fc -p`/`fc -P` for the swap. Investigation continued.

4. **Second fix attempt**: use `fc -p`/`fc -P` instead of direct
   `$HISTFILE=` (would give cleaner per-process `lasthist`
   isolation). **Rejected**: `fc -P` triggers the same rewrite block
   as `fc -AI`. There's no script-level escape.

5. **Final design**: direct `$HISTFILE=` swap; mode-N-gated `fc -AI`
   for non-incremental flush; lock-coordinated tee in extended format
   for the inactive store; optional native module for tighter lock
   coordination; contextual-grouping resolver as a layer above all
   of this. 11 scenario tests, all green in both pure-shell and
   native-module modes.

## What this is *not*

It is *not* a candidate PR back to upstream as a stylistic refactor.
The fork's `$HISTFILE`-swap design is observably different from
upstream's `fc -p`-in-hook design (`$HISTFILE` is now mutable across
chpwd / toggle, and the user can see it via `echo $HISTFILE`). That's
a user-visible behavioural change that needs to be a documented
opt-in choice, not a silent merge.

It is also *not* a one-feature add. The set of changes
(SHARE_HISTORY compat + mode-N flush + lock-coordinated tee + optional
native module + contextual grouping) is enough that this is more
naturally a sibling project than a PR.

## Reference: scenario test matrix

See `docs/tests/README.md` for the full index. Eleven scenarios,
organised:

- **SHARE/INC behaviour** (s01, s03, s03b, s04, s04b, s05, s06, s07): the core history-mode interactions.
- **Mode-N flush** (s08): chpwd flush in the no-incremental case.
- **Contextual grouping** (s09, s10): single-marker grouping; closest-ancestor + stop-point semantics.
