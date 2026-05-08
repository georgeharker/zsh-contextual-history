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

- Live cross-terminal merge in the same context via `SHARE_HISTORY`
  (the upstream plugin silently broke this — see [docs/MOTIVATION.md][m])
- Configurable contextual grouping (markers / project roots / custom)
- Optional native zsh module for tighter lock coordination on the tee
  writes (see [module/README.md][modr])
- A scenario-based test matrix that exercises both pure-shell and
  native-module paths against `SHARE` / `INC_APPEND` / both / neither

Status: 11 scenarios green in both pure-shell and native-module modes.

[upstream]: https://github.com/jimhester/per-directory-history
[m]: docs/MOTIVATION.md
[modr]: module/README.md

----------------------------------------------------------------------------
Usage
----------------------------------------------------------------------------

```zsh
# In your .zshrc:
source /path/to/contextual-history.zsh

# Optional: group history by project root rather than per-directory.
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)

# Optional: don't walk above $HOME looking for markers.
PER_DIRECTORY_HISTORY_GROUP_STOPS=($HOME)
```

Press `^G` to toggle between the active context's history and your global
history. The toggle key is configurable via `PER_DIRECTORY_HISTORY_TOGGLE`.

----------------------------------------------------------------------------
Contextual grouping
----------------------------------------------------------------------------

The resolver decides which history file is used for the current `$PWD`.
There are two ways to configure it.

### 1. Marker-list config

```zsh
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
PER_DIRECTORY_HISTORY_GROUP_STOPS=($HOME)
```

How it works: the resolver does **one** upward walk from `$PWD`. At each
ancestor it checks whether the ancestor contains *any* of the listed
marker filenames. The **closest ancestor with any marker wins** and
becomes the context root. Pattern order only matters for same-ancestor
tie-breaking.

If walk-up reaches a directory listed in `GROUP_STOPS` without finding
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
_per-directory-history-group() {
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

A helper `_per-directory-history-walk-up <markers...>` is exposed for
you to compose custom resolvers using the same walk-up semantics. It
honours `PER_DIRECTORY_HISTORY_GROUP_STOPS`.

----------------------------------------------------------------------------
Configuration variables
----------------------------------------------------------------------------

| Variable | Default | Effect |
|----|----|----|
| `HISTORY_BASE` | `$HOME/.directory_history` | Base dir for per-context history files. |
| `HISTORY_START_WITH_GLOBAL` | `false` | If `true`, start in global mode rather than context mode. |
| `PER_DIRECTORY_HISTORY_TOGGLE` | `^G` | Keybinding to flip between context and global modes. |
| `PER_DIRECTORY_HISTORY_GROUP_BY` | `()` | Ordered marker list for the default resolver (single walk-up). |
| `PER_DIRECTORY_HISTORY_GROUP_STOPS` | `()` | Walk-up boundary paths. Reaching one without a marker hit fails the search. |
| `PER_DIRECTORY_HISTORY_REFRESH_BEFORE_EXEC` | `true` | Refresh in-memory history from disk at the **start** of each ZLE editing cycle (`line-init` hook), so up-arrow / fzf-history / any history-reading zle widgets see other terminals' writes immediately. Mtime-gated — steady-state cost is one `stat()` per prompt. |
| `PER_DIRECTORY_USE_MODULE` | `false` | If `true`, prepend `module/` to `$module_path` so the optional native helper loads from the source tree without a system install. |

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

For users who want the strictest lock coordination (rare multi-syscall
race window in the lock-free fallback), there's an optional native
module providing a `pdh-tee` builtin that uses zsh's own
`lockhistfile`/`unlockhistfile` directly.

```sh
cd module
make                              # auto-fetch zsh source matching $ZSH_VERSION,
                                  # ./configure, build, produce zsh/pdh.{so,bundle}
```

Two ways to use it once built:

```zsh
# Option 1: load from the source tree (no system install).
PER_DIRECTORY_USE_MODULE=true
source /path/to/contextual-history.zsh

# Option 2: install into a $module_path location.
cd module && make install
# Then in zshrc:
source /path/to/contextual-history.zsh
```

When the module is loaded, the tee path uses the native builtin
automatically. When it isn't, the pure-shell fallback runs. No
behaviour difference for users.

See [module/README.md][modr] for build details, troubleshooting, and a
discussion of when the native lock actually matters.

----------------------------------------------------------------------------
Test infrastructure
----------------------------------------------------------------------------

```sh
cd docs/tests
zsh test_s01_concurrent_share.zsh    # one scenario
# or run the matrix - see docs/tests/README.md
```

The matrix covers SHARE_HISTORY same-dir/diff-dir interactions, INC_APPEND
sequential persistence, mode-N chpwd flush, mid-session toggle, three-shell
isolation, and the resolver's marker / stop-point semantics.

See [docs/tests/README.md](docs/tests/README.md) for layout and scenario
index, and [docs/MOTIVATION.md](docs/MOTIVATION.md) for the design and
mechanism investigation that motivated the fork.

----------------------------------------------------------------------------
Relationship to upstream
----------------------------------------------------------------------------

This is a fork of [jimhester/per-directory-history][upstream]. The fork
diverged on:

- `SHARE_HISTORY` compatibility (root cause: upstream's `fc -p` inside
  `zshaddhistory` is auto-popped by `hend`, so the per-dir file is never
  zsh's authoritative `$HISTFILE` — see [MOTIVATION.md][m])
- The `fc -AI` cross-shell hazard in mode-toggle (the s06 bug)
- The contextual grouping / resolver design
- The optional native helper module
- Always-extended-format on-disk for tee writes
- A scenario-driven test matrix

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
