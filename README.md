zsh-contextual-history
======================

Per-directory (or per-project, or arbitrary "context") shell history for zsh,
with full `SHARE_HISTORY` / `INC_APPEND_HISTORY` compatibility.

A history file is selected based on a configurable **resolver** that maps
your current `$PWD` to a "context key". The default resolver gives you one
history file per absolute directory (the original
[per-directory-history][upstream] behaviour). With a one-line config you
can group all subdirectories under any project marker (`.git`, `.histroot`,
`Cargo.toml`, etc.) into one shared history. You can also drop in a
fully custom resolver function for arbitrary grouping logic.

The fork preserves the original toggle behaviour (`^G` flips between
context-history and global-history), and adds:

- Live cross-terminal merge in the same context via `SHARE_HISTORY` (the
  upstream plugin silently broke this — see [Why this fork](#why-this-fork-exists))
- Configurable contextual grouping (markers / project roots / custom)
- Optional native zsh module for tighter lock coordination on the tee
  writes, plus a clean ring-replace builtin (see [module/README.md][modr])
- A scenario-based test matrix that exercises both pure-shell and
  native-module paths against `SHARE` / `INC_APPEND` / both / neither

Status: 17 PTY scenarios, run under both pure-shell and native-module
paths — 34/34 green when the module is built, 17/17 + 17 skips when it
isn't.

[upstream]: https://github.com/jimhester/per-directory-history
[modr]: module/README.md

----------------------------------------------------------------------------
Usage
----------------------------------------------------------------------------

```zsh
# In your .zshrc, BEFORE sourcing the plugin:

# Optional: group history by project root rather than per-directory.
zstyle ':contextual-history:*' group-by .histroot .git
# Equivalent env-var form: CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git)

# Optional: don't walk above $HOME looking for markers.
zstyle ':contextual-history:*' group-stops $HOME
# Equivalent env-var form: CONTEXTUAL_HISTORY_GROUP_STOPS=($HOME)

source /path/to/contextual-history.zsh
```

Every setting accepts both forms — pick whichever fits your dotfile
style. The full mapping is in the [Configuration](#configuration)
section below; if a setting is set both ways, the env var wins.

Press `^G` to toggle between the active context's history and your global
history. The toggle key is configurable via the `toggle-key` zstyle (or the
`CONTEXTUAL_HISTORY_TOGGLE` env var).

----------------------------------------------------------------------------
Contextual grouping
----------------------------------------------------------------------------

The resolver decides which history file is used for the current `$PWD`.
There are two ways to configure it.

### 1. Marker-list config

```zsh
zstyle ':contextual-history:*' group-by    .histroot .git
zstyle ':contextual-history:*' group-stops $HOME
```

(Equivalent env-var form: `CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git)`,
`CONTEXTUAL_HISTORY_GROUP_STOPS=($HOME)`.)

How it works: the resolver does **one** upward walk from `$PWD`. At each
ancestor it checks whether the ancestor contains *any* of the listed
marker filenames. The **closest ancestor with any marker wins** and
becomes the context root. Pattern order only matters for same-ancestor
tie-breaking.

If walk-up reaches a directory listed in `group-stops` without finding
a marker, the resolver gives up and falls back to `$PWD` (per-directory
behaviour for that branch of the tree).

Conventions worth knowing:

- **`.histroot`** — a custom marker. Drop an empty `.histroot` file at
  any directory you want to be a context root, and everything under it
  shares one history file. Useful when you don't want a project's `.git`
  to be the boundary (e.g. monorepos with nested submodules).
- **`.git`** — the obvious project-root marker. Listing it after
  `.histroot` means an explicit `.histroot` overrides a deeper `.git`.
  Listing it on its own gives you "one history per git repo".

If `GROUP_BY` is empty (the default) every absolute directory is its
own context, matching the original plugin's behaviour.

### 2. Custom resolver function

For arbitrary logic, redefine the resolver:

```zsh
_context-history-group() {
  local pwd=${PWD:A}
  for root in /work/big-project /work/other-project; do
    [[ $pwd == $root || $pwd == $root/* ]] && { print -r -- "$root"; return }
  done
  print -r -- "$pwd"
}
```

The function takes no arguments and prints a canonical "context key"
(typically a path). Whatever you print becomes part of the history file's
path under `$HISTORY_BASE`.

A helper `_context-history-walk-up <markers...>` is exposed for
you to compose custom resolvers using the same walk-up semantics. It
honours the `group-stops` zstyle / `CONTEXTUAL_HISTORY_GROUP_STOPS` env var.

----------------------------------------------------------------------------
Configuration
----------------------------------------------------------------------------

Every setting can be configured **either** as an environment variable
**or** via `zstyle` — pick whichever your dotfiles already use. Both
forms are fully supported; the mapping table below lists both side by
side.

Resolution order at plugin source time:

1. If the env var is already set, use it.
2. Otherwise look up `zstyle ':contextual-history:*' <key>`.
3. Otherwise apply the built-in default.

The plugin reads only the canonical env-var name internally, so the
hot path stays a plain `$VAR` lookup. Setting via zstyle just
populates that variable at source time.

### zstyle context

```zsh
zstyle ':contextual-history:*' use-module       true
zstyle ':contextual-history:*' refresh-on-nav   true
zstyle ':contextual-history:*' toggle-key       '^G'
zstyle ':contextual-history:*' group-by         .histroot .git
zstyle ':contextual-history:*' group-stops      $HOME
zstyle ':contextual-history:*' history-base     ~/.directory_history
zstyle ':contextual-history:*' debug            false
```

### Mapping table

| Variable | zstyle key | Default | Effect |
|----|----|----|----|
| `HISTORY_BASE` | `history-base` | `$HOME/.directory_history` | Base dir for per-context history files. |
| `HISTORY_START_WITH_GLOBAL` | `start-with-global` | `false` | If `true`, start in global mode rather than context mode. |
| `CONTEXTUAL_HISTORY_TOGGLE` | `toggle-key` | `^G` | Keybinding to flip between context and global modes. |
| `CONTEXTUAL_HISTORY_GROUP_BY` | `group-by` | `()` | Ordered marker list for the default resolver (single walk-up). |
| `CONTEXTUAL_HISTORY_GROUP_STOPS` | `group-stops` | `()` | Walk-up boundary paths. Reaching one without a marker hit fails the search. |
| `CONTEXTUAL_HISTORY_REFRESH_ON_NAV` | `refresh-on-nav` | `true` | Wrap each history-navigation widget (`up-history`, `down-history`, `history-search-*`, `history-incremental-search-*`, etc.) so it runs `fc -RI` immediately before reading `$history`, picking up cross-shell writes that landed while this shell was idle. Mtime-gated — steady-state cost is one `stat()` per widget invocation. Only meaningful with `SHARE_HISTORY`; otherwise a no-op. |
| `CONTEXTUAL_HISTORY_USE_MODULE` | `use-module` | `false` | If `true`, prepend `module/` to `$module_path` so the optional native helper loads from the source tree without a system install. |
| `CONTEXTUAL_HISTORY_DEBUG` | `debug` | `false` | If `true`, the plugin prints `[ch-dbg] ...` lines to stderr at key transitions (mode swap, chpwd, tee fallback). Off by default to avoid prompt noise. |
| `CONTEXTUAL_HISTORY_REFRESHING_WIDGETS` | `refreshing-widgets` | (full list, see plugin) | Override which widgets get the refresh wrap. Rarely needed. |

----------------------------------------------------------------------------
Interaction with SHARE_HISTORY / INC_APPEND_HISTORY
----------------------------------------------------------------------------

The plugin works in three effective zsh history modes:

- **`SHARE_HISTORY` (with or without `INC_APPEND_HISTORY`)**: every
  command is written incrementally under file lock at `hend()`. Multiple
  terminals in the same context share the active history file as their
  `$HISTFILE`, so cross-terminal merge happens natively at every prompt.
- **`INC_APPEND_HISTORY` only**: incremental writes happen but no
  read-merge. New shells in the same context see prior shells' commands
  on next start.
- **Neither**: no native incremental writes. The plugin's chpwd handler
  flushes pending in-memory entries to the outgoing context's file via
  `fc -AI`, so commands typed in directory A end up in A's history file
  even if you `cd` away before exiting.

Both stores (active and inactive) stay current via a tee in the
`zshaddhistory` hook — so toggling between context and global modes
always shows an up-to-date view of either history.

The tee is lock-coordinated with stock zsh's own `lockhistfile` —
fcntl when `HIST_FCNTL_LOCK` is set, otherwise the `<file>.LOCK`
symlink protocol. This serialises us against zsh's own incremental
writers on the same file.

----------------------------------------------------------------------------
Optional native helper module
----------------------------------------------------------------------------

The plugin ships with an optional zsh module providing two builtins:

- **`contextual-history-tee`** — the tee write, using zsh's own
  `lockhistfile`/`unlockhistfile` directly. Strictest possible
  coordination, single-builtin call.
- **`contextual-history-replace-ring`** — clean in-memory ring replace.
  The pure-shell fallback (`HISTSIZE=2; HISTSIZE=$orig; fc -R newfile`)
  leaks 2 entries from the previous context because zsh's `histsiz`
  clamps at a minimum of 2. The native builtin walks the ring directly
  and replaces it with no leak. Verified by the `test_p11`/`test_p12`
  matrix, which asserts leak-present without the module and clean ring
  with it.

```sh
cd module
make                              # auto-fetch zsh source matching $ZSH_VERSION,
                                  # ./configure, build, produce zsh/contextual_history.{so,bundle}
```

Two ways to use it once built:

```zsh
# Option 1: load from the source tree (no system install).
zstyle ':contextual-history:*' use-module true
# Equivalent env-var form: CONTEXTUAL_HISTORY_USE_MODULE=true
source /path/to/contextual-history.zsh

# Option 2: install into a $module_path location.
cd module && make install
# Then in zshrc:
source /path/to/contextual-history.zsh
```

When the module is loaded, both the tee and the ring-replace paths use
the native builtins automatically. When it isn't, the pure-shell
fallback runs (which has the documented 2-entry leak on toggle/chpwd).

See [module/README.md][modr] for build details, troubleshooting, and a
discussion of when the native lock actually matters.

----------------------------------------------------------------------------
Tests
----------------------------------------------------------------------------

```sh
cd tests
make                # full PTY suite, both module configs (34 cases)
make test           # alias for the above
make test-no-module # pure-shell only
make test-with-module
```

The matrix runs every `test_p*.zsh` under both
`CONTEXTUAL_HISTORY_USE_MODULE=false` (pure-shell tee + leaky ring
replace) and `=true` (native tee + clean ring replace). The with-module
pass is skipped automatically if the module isn't built.

See [tests/README.md](tests/README.md) for layout, the harness API,
and the per-scenario index.

----------------------------------------------------------------------------
Why this fork exists
----------------------------------------------------------------------------

The short version: getting per-directory history to work correctly under
`SHARE_HISTORY` (and to keep working under all the corner cases of
mid-session toggling, mode flips, and concurrent shells) required
architectural changes deep enough that this is no longer the upstream
plugin, even if the user-facing surface is similar. Each finding below
is grounded in a reproducible scenario test under `tests/`.

| Change | Reason |
|---|---|
| `$HISTFILE` is swapped on `chpwd`/toggle (was: `fc -p` inside `zshaddhistory`) | `fc -p` inside the addhistory hook is auto-popped by `hend()` (`Src/hist.c:1633`). The per-dir file never becomes zsh's authoritative `$HISTFILE`, so `SHARE_HISTORY`'s prompt-time merge never reads it. Same-directory cross-terminal sync is silently broken in upstream. |
| No `fc -AI` flush in mode-swap functions | `fc -AI` against an active history file triggers `savehistfile()`'s rewrite block (`Src/hist.c:3082-3098`), which truncates and rewrites the file. Concurrent SHARE readers see invalidated `lasthist.fpos` and silently lose entries. (The "s06 toggle bug.") |
| Mode-N (no `SHARE`/`INC`) gets `fc -AI` flush at `chpwd`, gated to mode N | Without an explicit flush, in-memory entries get wiped at the `HISTSIZE=0; fc -R newfile` step before reaching disk. The rewrite-block hazard doesn't apply in mode N because there's no concurrent reader. |
| Tee writes the *inactive* store on every command, in extended-history format unconditionally | Keeps both stores ever-growing regardless of mode. `EXTENDED_HISTORY` is treated as display-only because `SHARE_HISTORY`'s incremental writer forces extended format internally — mixed format on disk perturbs the per-process `lasthist` tracker. |
| Tee uses zsh's actual lock protocol | Without it, multi-syscall writes (large pasted blobs) can interleave with stock zsh's incremental writers on the same file. |
| Optional native helper module | Calls zsh's own `lockhistfile`/`unlockhistfile` directly, plus a clean ring-replace builtin that avoids the 2-entry leak inherent to `HISTSIZE=2; fc -R`. Plugin gracefully falls back to pure-shell when not built. |
| Configurable contextual grouping | Per-directory granularity is too fine for project work. Walking up to a marker (`.histroot`, `.git`) gives one history file per project; stop-points bound the walk. |

### `SHARE_HISTORY` cross-terminal sync was broken in upstream

Two terminals, both started in the same directory, both with `setopt
SHARE_HISTORY`. Shell 1 runs commands. Shell 2 runs `history`.

**Upstream:** shell 2's `history` shows only its own startup commands.
None of shell 1's writes appear, even though they're on disk in the
per-directory file. The cross-shell merge that is `SHARE_HISTORY`'s
entire point silently doesn't happen.

**Fork:** shell 2's `history` shows all of shell 1's commands with the
`*` foreign-shell marker, exactly as `SHARE_HISTORY` is supposed to
deliver. Verified by `test_p01_share_idle_visibility.zsh`.

#### Why upstream fails

Upstream's `_context-history-addhistory` calls `fc -p
"$_context_history_directory"` inside the `zshaddhistory` hook. The
intent: push the per-dir file onto zsh's history stack and make it
`$HISTFILE`, so subsequent prompt-time reads pull from the per-dir file.

Reading `Src/hist.c`:

- `1464` of `hend()`: `int flag, hookret, stack_pos = histsave_stack_pos;` — captures stack depth at start of hend
- `1503-1514`: `zshaddhistory` hooks fire (where upstream's `fc -p` runs)
- `1517-1519`: SHARE_HISTORY's prompt-time read merge
- `1627`: SHARE_HISTORY's incremental write
- **`1633`: `while (histsave_stack_pos > stack_pos) pophiststack();`** — auto-pop anything pushed during the hook

So upstream's `fc -p` push is auto-popped by `hend` before the hook
returns. From the user's perspective, `$HISTFILE` never observably
changes — it stays at the user's original global file. The
SHARE_HISTORY merge at line 1517 reads from the global file, never
from the per-directory file. The per-dir file is *write-only* from
SHARE_HISTORY's perspective, and other shells in the same directory
have no native zsh mechanism that re-reads it mid-session.

#### Why the fork fixes it

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

### The toggle bug: `fc -AI` is a cross-shell hazard

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

The fix: removed the `fc -AI` calls in the swap functions entirely.
For SHARE/INC the entries are already on disk via incremental writes —
nothing to flush. For mode N see below.

### Why `fc -p` / `fc -P` aren't an option for the swap

A natural alternative to direct `$HISTFILE=` assignment is zsh's own
history-stack: `fc -p new_file` to enter, `fc -P` to leave. `fc -p`
is clean. But `fc -P` is `saveandpophiststack(-1, HFILE_USE_OPTIONS)`,
which calls `savehistfile(fn, 1, HFILE_USE_OPTIONS)`. With
`SHARE_HISTORY` set, flag inheritance at `Src/hist.c:2929-2931` adds
`HFILE_APPEND | HFILE_SKIPOLD` — the same rewrite-block hazard as
`fc -AI`. There's no script-level way to pass `HFILE_NO_REWRITE`.
Direct `$HISTFILE=` assignment is the only path that doesn't trip
the rewrite block.

### Mode-N flush: explicit, isolated from the cross-shell hazard

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

### The tee: format and locking

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
directly. Same coordination, but done by zsh itself rather than
emulated.

### The 2-entry ring-replace leak

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

### Contextual grouping

Per-physical-directory granularity is often too fine. A user with one
project rooted at `~/code/proj` and lots of subdirectories
(`~/code/proj/src/{a,b,c}`) gets a separate history file in each,
which fragments history that is conceptually one project's commands.

Two ways to group: marker-list config (single upward walk; closest
ancestor with any listed marker wins; bounded by `GROUP_STOPS`), or a
custom `_context-history-group()` resolver function that prints the
context key directly. Verified by `test_p15_group_by_marker.zsh` and
`test_p16_group_strategies.zsh`.

----------------------------------------------------------------------------
Relationship to upstream
----------------------------------------------------------------------------

This is a fork of [jimhester/per-directory-history][upstream]. The fork
diverged on:

- `SHARE_HISTORY` compatibility (root cause: upstream's `fc -p` inside `zshaddhistory` is auto-popped by `hend`, so the per-dir file is never zsh's authoritative `$HISTFILE`)
- The `fc -AI` cross-shell rewrite-block hazard in mode-toggle
- The contextual grouping / resolver design
- The optional native helper module (tee + clean ring replace)
- Always-extended-format on-disk for tee writes
- A scenario-driven PTY test matrix

[upstream]: https://github.com/jimhester/per-directory-history

----------------------------------------------------------------------------
History
----------------------------------------------------------------------------

The original idea is from [Stewart MacArthur][m1] and [Dieter][m2]; the
implementation idea is from [Bart Schaefer][m3] on the zsh mailing list.
The original implementation is by [Jim Hester][m5] in September 2012.
This `SHARE_HISTORY`-compatible / contextual fork is from 2026.

[m1]: http://www.compbiome.com/2010/07/bash-per-directory-bash-history.html
[m2]: http://dieter.plaetinck.be/per_directory_bash
[m3]: http://www.zsh.org/mla/users/1997/msg00226.html
[m5]: http://jimhester.com
