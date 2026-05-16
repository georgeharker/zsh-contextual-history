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
| Shell-exit mode (no `SHARE`/`INC`) gets `fc -AI` flush at `chpwd`, gated to that mode | Without an explicit flush, in-memory entries get wiped at the `HISTSIZE=0; fc -R newfile` step before reaching disk. The rewrite-block hazard doesn't apply in shell-exit mode because there's no concurrent reader. |
| Tee writes the *inactive* store on every command, in extended-history format unconditionally | Keeps both stores ever-growing regardless of mode. `EXTENDED_HISTORY` is treated as display-only because `SHARE_HISTORY`'s incremental writer forces extended format internally — mixed format on disk perturbs the per-process `lasthist` tracker. |
| Tee uses zsh's actual lock protocol | Without it, multi-syscall writes (large pasted blobs) can interleave with stock zsh's incremental writers on the same file. |
| Optional native helper module | Calls zsh's own `lockhistfile`/`unlockhistfile` directly, plus a clean ring-replace builtin that avoids the 2-entry leak inherent to `HISTSIZE=2; fc -R`. Adds a `contextual-history-fast-refresh` builtin that preserves `HIST_FOREIGN` through widget-time refreshes (used by the fzf widget's local/all toggle). Plugin gracefully falls back to pure-shell when not built. |
| Configurable contextual grouping | Per-directory granularity is too fine for project work. Walking up to a marker (`.histroot`, `.git`) gives one history file per project; stop-points bound the walk. |
| Opt-in fzf widget (`contextual-history-fzf-widget`) | fzf's stock `^R` widget reads `$history` (blind to `HIST_FOREIGN`) or `fc -l` (sees `*` but strips it in display). Our widget feeds fzf from `fc -lir` directly, tags each record `L`/`F`, and uses fzf's query-filter mechanism for the local/all toggle. Retrieval via `zle vi-fetch-history -n` sidesteps the documented `${(kv)history[@]}` foreign-lag bug. |
| Local-writes set for fzf L/F tagging | Raw `HIST_FOREIGN` means "loaded via `HFILE_FAST` since shell start" — zsh's startup load (`init.c:1395`) doesn't set it, and ring replacement (toggle / chpwd) reassigns histnums on reload, so neither flag nor histnum can carry a stable "this shell typed it" bit. The fzf integration tracks each write's `(stim, text)` in an associative array at the addhistory hook and looks it up in the snapshot via `fc -lirt '%s'`. Stable across ring replacement (key is on-disk identity, not histnum). Empirically full-text storage is cheapest at write AND read time vs. hashing alternatives. |
| Local-history navigation filter | Opt-in keybind that wraps `up-history` / `down-history` / `up-line-or-history` etc. so they skip entries not in this shell's `_context_history_local_texts` set. Mechanism is purely the existing widget wrap plus a skip loop calling the underlying widget repeatedly until `BUFFER` matches or `HISTNO` stops advancing. No new hooks, no cache invalidation — the text set is shell-lifetime stable and shared with the fzf integration. |
| Per-widget wrap generation | The widget-wrap machinery generates one wrap function per widget (`_context-history-wrap-<widget>`) with the canonical widget name hard-coded, dispatching through a shared `_context-history-wrap-impl` helper. Hard-coding side-steps the case where another plugin (notably zsh-autosuggestions) re-binds our wrap under a renamed alias and dispatches into it through that alias — `$WIDGET` then becomes the alias, but the canonical name we need for `orig_widgets` lookup and local-history scoping is still correct. |
| File structure | Core history behaviour (`$HISTFILE` swap, tee, replace-ring, share-compat) is in `contextual-history.zsh`. Widget-wrap machinery is in `contextual-history-widgets.zsh`. Opt-in keybind features (local-history filter) are in `contextual-history-keybinds.zsh`. fzf integration is in `contextual-history-fzf.zsh`. The main plugin auto-sources the siblings; each has its own first-precmd hook for any installation it needs. |

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
nothing to flush. For shell-exit mode see below.

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

## Shell-exit-mode flush: explicit, isolated from the cross-shell hazard

In shell-exit mode (neither `SHARE_HISTORY` nor `INC_APPEND_HISTORY`), zsh
doesn't write incrementally; commands are saved at shell exit. So a
`chpwd`-triggered ring-replace would discard pending in-memory
entries that haven't yet reached disk.

The fix: in shell-exit mode specifically, do `fc -AI "$HISTFILE"` before the
swap (`test_p14_mode_n_chpwd_flush.zsh` verifies this). Safe in mode
N because the rewrite-block hazard only damages *concurrent*
SHARE_HISTORY readers, and by definition there are no concurrent
SHARE readers in shell-exit mode. The user has explicitly opted out of the
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

## fzf widget and the foreign-tag preservation problem

zsh exposes a single bit of per-entry provenance to userspace: the
`HIST_FOREIGN` flag, set on entries pulled in via `SHARE_HISTORY`'s
hend-merge and printed as `*` in `fc -l` output. It's the only
mechanism in stock zsh for distinguishing entries this shell wrote
from entries that arrived from peers.

The flag is fragile: it's set only by `readhistfile` calls that
include the `HFILE_FAST` flag (`Src/hist.c:2706-2708`). Inside zsh
there are exactly two callers with `HFILE_FAST`: the hend-merge
itself, and (indirectly) the rewrite-block. From script context,
`fc -RI` is the closest equivalent — and it passes `HFILE_SKIPOLD`
without `HFILE_FAST`, so `fc -RI` does NOT set `HIST_FOREIGN`.

This matters for the plugin's `refresh-on-nav` path. Refresh-on-nav
fires inside history-navigation widgets and refreshes the ring
against the on-disk file so peer-shell writes are visible to the
widget. If refresh uses `fc -RI`, every entry it pulls in is loaded
as if this shell wrote it — laundering the foreign tag before any
downstream consumer (fzf widget, custom ranker) can read it.

### The native fast-refresh builtin

`module/contextual_history.c` exposes `contextual-history-fast-refresh
<file>`, a thin wrapper around `readhistfile(fn, 0, HFILE_USE_OPTIONS |
HFILE_FAST | HFILE_SKIPOLD)`. The flag combination:

- `HFILE_FAST` — the only way to set `HIST_FOREIGN` on new loads.
- `HFILE_SKIPOLD` — sets `HIST_MAKEUNIQUE` on each candidate, which
  `Src/hashtable.c:1424-1428` then converts to `HIST_DUP` when the
  histtab already has the same text. Without this, the bare
  `HFILE_FAST` path relies on per-process `lasthist.{fpos,stim,text}`
  consistency that can be broken by external writes between SHARE
  cycles — the searching=1 check fails, falls to searching=-1, and
  entries with `stim >= lasthist.stim` get re-loaded as foreign
  duplicates of local entries.
- `HFILE_USE_OPTIONS` — matches the hend-merge's call.

When the module is loaded, `refresh-on-nav` automatically uses the
builtin. When it isn't, the plugin falls back to `fc -RI` and the
widget's local/all toggle becomes a no-op (every entry appears
local). The widget itself still works without the module — just
without the discrimination.

### The widget design

The fzf widget, its config knobs, and the auto-takeover hook live in
`contextual-history-fzf.zsh` — a sibling file the main plugin sources
automatically when present. This keeps `contextual-history.zsh`
focused on the core `$HISTFILE`-swap / tee / SHARE-compat path.
Users who want to skip the fzf code entirely can delete or rename
the sibling.


fzf's stock `^R` widget has two read paths
(`shell/key-bindings.zsh`):

- **Perl path** (default): reads `${(kv)history[@]}` via
  `zsh/parameter`. That assoc array carries text only — no flag bits.
  Foreign tag is invisible.
- **awk fallback**: reads `fc -rl 1`. The regex
  `^[ \t]*[0-9]+\**[ \t]+` explicitly strips the `*` column for
  display.

Both paths discard `HIST_FOREIGN` by design. Wrapping the widget
can't fix this — the input is already laundered before it reaches
fzf.

`contextual-history-fzf-widget` reads `fc -lE 1` directly (preserving
`*`), tags each record as `L` (no marker) or `F` (marker), and
emits a tab-delimited record:

```
<flag>\t<histnum>\t<stim>\t<text>\0
```

(NUL-delimited so multi-line entries pass through `--read0`
cleanly.)

fzf is launched with `--with-nth=1,4..` — display the flag column
joined with the text column, hide histnum/stim. The search target
becomes `L echo hello` or `F ls -la`. Two binds use
`transform-query` to flip the view by manipulating the user's query:
`alt-l` prepends `^L ` (anchored prefix match against the joined
display), `alt-a` strips it. No `reload`, no subprocess fork per
toggle, and the user's free-text query is preserved across flips.

Selection retrieval uses `zle vi-fetch-history -n <histnum>` —
fzf upstream uses the same approach in their awk fallback to dodge
the documented lag bug in `${(kv)history[@]}` for foreign entries
(see `zsh.org/mla/users/2024/msg00692.html`).

The snapshot is taken once when fzf launches. Within an open
session it's fixed: `HIST_FOREIGN` is in-memory state only, no
subprocess can recompute it. Refresh by closing fzf and re-pressing
the bind.

### The L/F semantic and the local-writes set

A natural user assumption is "L = I typed this in this shell;
F = somebody else did." Raw `HIST_FOREIGN` doesn't deliver that.
What `HIST_FOREIGN` actually means, per `Src/hist.c:2706-2708`, is:

> set on entries newly loaded by a `readhistfile` call that passed
> `HFILE_FAST` — i.e. either zsh's own `SHARE_HISTORY` hend-merge or
> our `contextual-history-fast-refresh` builtin.

Two places in zsh's history machinery load entries without
`HFILE_FAST`:

- **Startup load** at `init.c:1395` — `readhistfile(NULL, 0, HFILE_USE_OPTIONS)`.
- **`fc -R` / `fc -RI`** at `builtin.c:1501` — pass nothing or only
  `HFILE_SKIPOLD`.
- **Ring replacement** inside our own `contextual-history-replace-ring`
  builtin and pure-shell fallback — both call `readhistfile(fn, 0/1,
  HFILE_USE_OPTIONS)` or `fc -R` without `HFILE_FAST`.

Entries loaded by any of these get `HIST_OLD | HIST_READ` but no
`HIST_FOREIGN`. So everything already on disk at shell start —
including entries a peer shell wrote yesterday in this exact
directory — comes in as "non-foreign". A naive snapshot tags them
L, which violates the user's intuition.

**The fix** is a (stim, text) identity set populated at every
`zshaddhistory` hook firing:

```zsh
_context_history_local_writes[${EPOCHSECONDS}:${chline}]=1
```

The main plugin's `_context-history-addhistory` writes this set
unconditionally (gated on the array's existence so the main plugin
stays agnostic to fzf when fzf isn't loaded). At snapshot time, the
fzf widget reads `fc -lirt '%s' 1` — using fc's custom-format option
(`builtin.c:1788`: `tdfmt = OPT_ARG(ops,'t')`) — to emit each ring
entry's Unix-epoch stim alongside text. For each entry, the
`${stim}:${text}` key is looked up in the set:

- hit → **L** (this shell typed it, somewhere in its lifetime).
- miss → **F** (pre-existing on disk, or written by a peer).

The crucial property: this **survives ring replacement**. Histnums
are reassigned every time `readhistfile` populates a fresh ring (via
`prepnexthistent` in the loop, `hist.c:2790`), so any histnum-keyed
flag would go stale at every toggle/chpwd. But `stim` and `text` are
preserved on reload (read from the file's
`: stim:elapsed;text\n` lines), so the same on-disk entry has the
same lookup key whatever ring it's currently in. Our typing stays
L across `^G` toggles, across `chpwd` swaps, across as many cycles
as the user wants. `test_p31_local_across_swap.zsh` pins this.

Memory: ~170 bytes per assoc entry (zsh's HashNode overhead
dominates over the key string itself). Bounded by this shell's
typing rate — typical session is hundreds of entries, ~30KB; a
marathon 10k-write session is ~1.7MB.

False-positive case: a peer shell writes the *exact* same command
text in the *exact* same second as us. Vanishingly rare in practice.

`test_p30_foreign_tag_semantics.zsh` and
`test_p31_local_across_swap.zsh` pin all four classification cases
plus the across-swap stability.

### Rejected alternatives

Two designs were considered and dropped in favour of the
(stim, text) set:

1. **Mark pre-existing entries `HIST_FOREIGN` via a native builtin.**
   A new builtin would walk `hist_ring` once at first precmd and
   set `HIST_FOREIGN` on every entry already there. The snapshot
   could then read `HIST_FOREIGN` directly. Rejected because zsh
   uses `HIST_FOREIGN` in places beyond display:

   - **`fc -L`** (`builtin.c:1806`) filters foreign entries OUT of
     its listing. After the mark, `fc -L` would silently exclude
     everything pre-existing — a user-visible behaviour change in
     a stock builtin.
   - **`hcomsearch`** (`hist.c:1820`, used for `?foo?` reverse-
     search history expansion) and **`hconsearch`** (`hist.c:1843`,
     used for `!foo` history expansion) skip `HIST_FOREIGN`
     entries. Marking pre-existing entries foreign means `!ls`
     would no longer match a prior session's `ls`.

   The (stim, text) approach is local to our widget: it gives us
   the L/F semantic for display purposes without perturbing any
   zsh-level behaviour.

2. **Startup-curhist baseline.** An earlier prototype captured
   `HISTCMD - 1` at first precmd and classified entries by
   `histnum > baseline AND not HIST_FOREIGN`. This works within
   a single ring's lifetime but breaks at every ring replacement
   because the new ring's entries get fresh histnums starting from
   `curhist + 1` — every loaded entry then satisfies
   `histnum > old_baseline` and gets tagged L, including ones the
   user typed in a prior session or that peers wrote. Trying to
   re-capture the baseline at every swap is also wrong: it
   reclassifies the user's earlier-in-session typing as F.
   Histnum is the wrong identity for cross-swap stability.

3. **Hashing the text before storing.** An obvious memory
   optimization: store `(stim, hash(text))` instead of
   `(stim, text)`. Empirical benchmarking showed hashing in pure
   shell (djb2) costs ~7× more CPU at write time than just storing
   the text, and ~25× more at read time, while saving only ~20%
   memory (because zsh's per-assoc-entry overhead dominates over
   key length). External `cksum` is ~75× more expensive than
   no-hash due to fork. The CPU cost dwarfed any memory benefit,
   so full-text storage wins on both dimensions.

----------------------------------------------------------------------------

## Local-history navigation filter

A sibling of the fzf widget's L/F view: the user picks a keybind that
toggles "scroll only through entries this shell typed" for the
standard history-navigation widgets (`up-history`, `down-history`,
`up-line-or-history`, the search variants, etc.). Conceptually this
gives the same filter that fzf's `alt-l` provides inside the picker,
but for the raw up/down nav UX outside fzf.

Implementation lives in `contextual-history-keybinds.zsh`, a sibling
file the main plugin auto-sources. That file is the container for
keybind-driven opt-in features; local-history is the first inhabitant,
but the file name is the generic shape so future opt-in keybind
features can be added without proliferating one file per feature.

### Mechanism

The piece-list is intentionally minimal:

- **A mode bit** `_context_history_local_mode` (0/1).
- **A text-only assoc set** `_context_history_local_texts`, populated
  at every `zshaddhistory` hook firing — the same hook that already
  writes the `(stim, text)` set for the fzf widget. Sibling
  invariant: every command this shell adds populates both sets.
- **A toggle widget** that flips the mode bit and `zle -M`'s the new
  state.
- **A skip loop** inside the existing `_context-history-refreshing-widget`
  wrap. After dispatching to the underlying widget, if local-history
  mode is on and the just-loaded `BUFFER` isn't in the text set,
  dispatch the underlying widget again. Bail on boundary (`HISTNO`
  unchanged) or a safety cap (10000 iterations).

No additional hooks. No cache invalidation. No ring-swap rebuild.
The text set is shell-lifetime stable; histnums and the ring change
under it but the set's identity (text) is the same.

### Why text-only and not (stim, text)

Within a single keystroke we have `$BUFFER` (the just-loaded entry's
text) but not the corresponding stim. `$history` exposes text only;
getting stim per ring entry would require `fc -lt '%s'` parsing or
the native module — too expensive for per-keystroke navigation.

The fzf widget uses `(stim, text)` because it walks all entries once
per invocation in a single fc call — it gets stim for free. The
nav filter doesn't have that luxury.

Trade-off: a peer-shell that ever typed identical text to ours will
be marked walkable. For navigation UX this is a one-extra-keystroke
glitch in a very rare case. Not worth the complexity of carrying
stim per HISTNO.

### Why no incremental-search support

`history-incremental-search-{backward,forward}` enter a stateful mode
that reads characters and re-runs the search. The skip-after-dispatch
pattern doesn't compose: each dispatch puts the widget into an
inner read loop. Excluded from `CONTEXTUAL_HISTORY_LOCAL_WIDGETS`
by default. Incremental search behaves as today.

### Composition with the existing wrap

The `_context-history-refreshing-widget` wrap already exists for
refresh-on-nav (mtime-gated `fc -RI` or fast-refresh before each
nav widget invocation). Local-history rides the same wrap: dispatch
to the underlying widget remains a single helper
(`_context-history-dispatch-original`), called once for the normal
case and additionally by the skip loop. Refresh + skip-loop compose
cleanly because refresh runs once before any skip iteration.

Verified by `test_p32_local_skip.zsh`: pre-seed a peer entry, press
up enough times to find it (local-history off), then reset, toggle
local-history on, press up many times — the peer entry is never
reached.

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

3. **First fix attempt**: gate `fc -AI` to shell-exit mode. **Insufficient**:
   the rewrite-block hazard exists in `fc -P` too, and we'd hit it
   if we used `fc -p`/`fc -P` for the swap.

4. **Second fix attempt**: use `fc -p`/`fc -P` instead of direct
   `$HISTFILE=` (would give cleaner per-process `lasthist`
   isolation). **Rejected**: `fc -P` triggers the same rewrite block
   as `fc -AI`. There's no script-level escape.

5. **Final design**: direct `$HISTFILE=` swap; shell-exit-mode-gated `fc -AI`
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
(SHARE_HISTORY compat + shell-exit-mode flush + lock-coordinated tee + optional
native module + contextual grouping) is enough that this is more
naturally a sibling project than a PR.

----------------------------------------------------------------------------

## Test coverage

32 PTY-based scenario tests under `tests/`, each covering one
behaviour grounded above. Tests `p26`-`p31` cover the fzf integration
(snapshot tagging, multi-shell SHARE filter toggle, no-module
degradation, the `use-fzf` load gate, the L/F semantic, and L tag
preservation across ring replacement). Test `p32` covers the
local-history navigation filter.

Run `make test` for the full matrix (both module configs);
`make test-upstream` runs the same suite against the unmodified
upstream plugin to demonstrate which findings translate to specific
test failures on upstream master.

Today's matrix outcome: 64/64 green on the fork (with module),
9 fork-fixed bugs failing on upstream, 6 baseline tests passing on
both.
