zsh-contextual-history
======================

Share history across all shells — then filter what you see down to
whatever scope you want: every shell, this project's directory, or
just commands you typed in this shell.

A `SHARE_HISTORY`-compatible fork of [per-directory-history][upstream]
that adds two orthogonal filter axes, an fzf-based search picker, and
a zsh-autosuggestions-aware suggestion strategy.

[upstream]: https://github.com/jimhester/per-directory-history
[modr]: module/README.md

## Features at a glance

| Feature | What it does | How to use |
|---|---|---|
| Context vs global | One history file per directory or project, with a toggle to fall back to your global history. | `^G` (default; configurable) |
| Local-history filter | Up-arrow walks only commands this shell typed, skipping other-shell and prior-session entries. | Opt-in. Set `local-toggle-key` to bind a key, or `start-with-local true` to pin it on. |
| fzf integration | `^R`-style picker that shows the same toggles inline, so you can flip between "this shell" / "all shells" without leaving the picker. | Auto-loaded if `fzf` is on `$PATH` |
| Autosuggestions strategy | Inline grey suggestion respects both filter axes. | Opt-in via `ZSH_AUTOSUGGEST_STRATEGY` |

The two filter axes are independent — context-vs-global and
local-vs-all-shells — giving four navigation slices:

|                       | Context (per-dir or per-project) | Global |
|-----------------------|----------------------------------|--------|
| **All shells**        | Every entry typed in this context  | Every entry on this machine |
| **This shell only**   | Just what you typed here, in this context | Just what you typed in this shell |

Both toggles emit a `zle -M` status line covering the current state,
e.g. `history: context | this-shell only (12 entries)`.

## Quickstart

```zsh
# .zshrc
source /path/to/contextual-history.zsh
```

That's enough to get per-directory history + the `^G` global-toggle.
Common additions:

```zsh
# Group history by project root (any of these markers) rather than
# strictly per-directory.
zstyle ':contextual-history:*' group-by .git .histroot

# Bind the local-history toggle so up-arrow can filter to this shell.
zstyle ':contextual-history:*' local-toggle-key '^X^L'

# Use the autosuggestions strategy that respects both filters.
# Add this line AFTER sourcing zsh-autosuggestions (it sets a default).
ZSH_AUTOSUGGEST_STRATEGY=(contextual_history)
```

Every setting can be set as either a `zstyle` or an environment
variable — pick whichever fits your dotfiles. See [Configuration](#configuration)
for the full list.

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

Every setting can be configured as either an environment variable or
a `zstyle` — both are fully supported. Resolution at plugin source
time: env var → `zstyle ':contextual-history:*' <key>` → built-in
default.

Each row below lists the env-var name on the first line and the
zstyle key on the second. Either form sets the same internal
variable.

### Core settings

| Setting | Default | Effect |
|---|---|---|
| `HISTORY_BASE`<br>`history-base` | `$HOME/.directory_history` | Where per-context history files live. |
| `HISTORY_START_WITH_GLOBAL`<br>`start-with-global` | `false` | Start in global history mode rather than per-context. |
| `CONTEXTUAL_HISTORY_TOGGLE`<br>`toggle-key` | `^G` | Keybind to flip between context-history and global-history. |
| `CONTEXTUAL_HISTORY_GROUP_BY`<br>`group-by` | `()` | Ordered marker filenames for the default resolver. With `(.git .histroot)`, all subdirectories under a `.git` (or `.histroot`) root share one history file. See [Contextual grouping](#contextual-grouping). |
| `CONTEXTUAL_HISTORY_GROUP_STOPS`<br>`group-stops` | `()` | Walk-up boundary paths. Reaching one without finding a marker fails the search and falls back to per-directory. |
| `CONTEXTUAL_HISTORY_LOCAL_KEY`<br>`local-toggle-key` | `''` (unbound) | Keybind for the local-history toggle (skip peer-shell entries on up-arrow). Opt-in. See [Local-history filter](#local-history-navigation-filter). |
| `CONTEXTUAL_HISTORY_START_WITH_LOCAL`<br>`start-with-local` | `false` | Start new shells in local-history mode. Independent of `local-toggle-key` — you can pin the mode on without binding a key. |
| `CONTEXTUAL_HISTORY_WRAP_WIDGETS`<br>`wrap-widgets` | `true` | Install our wraps around zsh's history-navigation widgets. The wraps deliver idle peer visibility on up-arrow (without them, pressing up between commands under `SHARE_HISTORY` walks a stale view) and provide the scope for the local-history filter. Set `false` to leave zsh's history widgets untouched. |
| `CONTEXTUAL_HISTORY_FZF_INTEGRATION`<br>`fzf-integration` | `true` | Load the fzf integration if `fzf` is on `$PATH` at source time. See [fzf integration](#fzf-integration). |
| `CONTEXTUAL_HISTORY_USE_MODULE`<br>`use-module` | `false` | Load the locally-built native helper module (avoids the 2-entry ring-replace leak; preserves `HIST_FOREIGN` on idle refreshes). See [Optional native helper module](#optional-native-helper-module). |
| `CONTEXTUAL_HISTORY_DEBUG`<br>`debug` | `false` | Print `[ch-dbg] ...` lines to stderr at key transitions (mode swap, chpwd, tee fallback). |

A handful of rarely-needed override knobs (which widgets get
wrapped, whether the nav-widget mtime refresh is active) live in
INTERNALS.md alongside the mechanism they control.

### fzf-integration settings

Only consulted when the fzf integration loads. See
[fzf integration](#fzf-integration) for narrative + wire-up examples.

| Setting | Default | Effect |
|---|---|---|
| `CONTEXTUAL_HISTORY_FZF_BIND_CTRL_R`<br>`fzf-bind-ctrl-r` | `false` | At first precmd, bind `^R` to our widget if fzf's `fzf-history-widget` is also present. Off by default so users with custom `^R` bindings keep them. |
| `CONTEXTUAL_HISTORY_FZF_VIEW`<br>`fzf-default-view` | `all` | Initial view: `local` (this shell only) or `all` (every entry). |
| `CONTEXTUAL_HISTORY_FZF_LOCAL_KEY`<br>`fzf-toggle-local-key` | `alt-l` | fzf-internal bind to switch to local view. |
| `CONTEXTUAL_HISTORY_FZF_ALL_KEY`<br>`fzf-toggle-all-key` | `alt-a` | fzf-internal bind to switch to all view. |
| `CONTEXTUAL_HISTORY_FZF_PROMPT_LOCAL`<br>`fzf-prompt-local` | `'LOCAL> '` | fzf prompt string for local view. |
| `CONTEXTUAL_HISTORY_FZF_PROMPT_ALL`<br>`fzf-prompt-all` | `'ALL> '` | fzf prompt string for all view. |
| `CONTEXTUAL_HISTORY_FZF_EXTRA_OPTS`<br>`fzf-extra-opts` | `''` | Extra fzf opts appended after our defaults. Also honours upstream `FZF_CTRL_R_OPTS`. |

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

The plugin ships with an optional zsh module providing three builtins.
It's not required for any feature — the pure-shell fallback works —
but it sharpens behaviour in a few specific areas:

- **`contextual-history-tee`** — the tee write, using zsh's own
  `lockhistfile`/`unlockhistfile` directly. Strictest possible
  coordination with stock zsh's incremental writers, single-builtin
  call.
- **`contextual-history-replace-ring`** — clean in-memory ring replace.
  The pure-shell fallback (`HISTSIZE=2; HISTSIZE=$orig; fc -R newfile`)
  leaks 2 entries from the previous context because zsh's `histsiz`
  clamps at a minimum of 2. The native builtin walks the ring directly
  and replaces it with no leak.
- **`contextual-history-fast-refresh`** — refresh from disk preserving
  the `HIST_FOREIGN` flag on newly-loaded entries (`HFILE_USE_OPTIONS |
  HFILE_FAST | HFILE_SKIPOLD`). The pure-shell `fc -RI` fallback drops
  the foreign flag, which means the fzf widget's L/F classification
  (and the autosuggestions strategy's local-history filter) treat
  newly-arrived peer entries as local until the next ring swap. With
  the module, the foreign bit survives, so classification stays
  correct in real time.

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

With the module loaded, all three native builtins are used
automatically. Without it, the pure-shell fallback runs (with the
documented 2-entry ring-replace leak on toggle/chpwd, and `HIST_FOREIGN`
not surviving mid-session refreshes).

See [module/README.md][modr] for build details, troubleshooting, and a
discussion of when the native lock actually matters.

----------------------------------------------------------------------------
Local-history navigation filter
----------------------------------------------------------------------------

> Makes up-arrow walk only commands you typed in this shell, skipping
> entries other shells wrote or prior sessions left on disk.

Opt-in toggle. The bit is per-shell-instance and persists until you
toggle off (or the shell exits). Combine with `^G` (context/global)
to navigate any of the four slices in the [axis grid above](#features-at-a-glance).

### Setup

```zsh
# Pick a key for the toggle (unbound by default).
zstyle ':contextual-history:*' local-toggle-key '^X^L'

# Optional: start new shells already in local-history mode.
zstyle ':contextual-history:*' start-with-local true

source /path/to/contextual-history.zsh
```

That binds your key in emacs, viins, and vicmd keymaps. Toggling
either this widget or `^G` emits a `zle -M` status line showing both
axes, e.g. `history: context | this-shell only (12 entries)` or
`history: global | all shells`.

### What it covers

Applied to the standard history navigation widgets: `up-history`,
`down-history`, `up-line-or-history`, `down-line-or-history`,
`up-line-or-search`, `down-line-or-search`, `history-search-*`, and
`history-beginning-search-*`. Incremental search (`history-incremental-search-*`)
is intentionally excluded — its per-keystroke read loop doesn't
compose with a skip-after-dispatch filter.

For the mechanism, edge cases (peer-typed identical text, prior-session
entries), and override knobs, see
[INTERNALS — Local-history navigation filter][il].

[il]: INTERNALS.md#local-history-navigation-filter

----------------------------------------------------------------------------
zsh-autosuggestions integration
----------------------------------------------------------------------------

> Makes the inline grey suggestion respect both filter axes — so what
> you're being suggested matches what up-arrow would walk.

Two opt-in suggestion strategies, parallel to upstream's two:

- **`contextual_history`** — local-history-aware port of upstream's
  `history` strategy (newest entry matching the prefix).
- **`contextual_match_prev_cmd`** — local-history-aware port of
  upstream's `match_prev_cmd` strategy (prefer an entry whose
  preceding history entry equals your previously-executed command,
  fall back to newest prefix match).

Both strategies:

- automatically scope to whichever history `^G` has currently
  selected (context vs global) — they read from zsh's live history
  parameter, and the `^G` toggle swaps that wholesale; and
- when local-history mode is on, restrict suggestions to entries
  this shell typed (and, for `contextual_match_prev_cmd`, also
  require the preceding entry to be local — patterns are learned
  from this shell's typing only).

The integration lives in **`contextual-history-autosuggest.zsh`**,
auto-sourced by the main plugin. The functions are just *defined*;
nothing fires until you opt in below.

### Setup

```zsh
# .zshrc — order of these two source lines is free
source /path/to/zsh-autosuggestions.zsh
source /path/to/contextual-history.zsh

# Opt in to ONE of the two strategies. MUST be after sourcing
# zsh-autosuggestions (it assigns a default at source time).
ZSH_AUTOSUGGEST_STRATEGY=(contextual_history)
# - or -
ZSH_AUTOSUGGEST_STRATEGY=(contextual_match_prev_cmd)
```

Toggling `^G` or your local-history key refreshes the inline suggestion
immediately (both toggles call `zle autosuggest-fetch` via the shared
status helper, so the visible suggestion reflects the new state on
the same press rather than the next keystroke).

### Picking a strategy

| You currently use | Use this |
|---|---|
| stock `history` | `contextual_history` |
| stock `match_prev_cmd` | `contextual_match_prev_cmd` |

Stock `match_prev_cmd` already follows the context-vs-global axis for
free (it reads zsh's live history, which the `^G` toggle has already
swapped). What it doesn't know is the local-vs-other-shell filter —
so with local-history mode on, stock would still suggest entries from
other shells, contradicting what up-arrow walks. The port closes that
gap.

### How they work

Each strategy mirrors its upstream counterpart when local-history mode
is off (so users lose nothing by opting in). When local-history mode is
on:

- **`contextual_history`** restricts the prefix-match search to
  entries this shell typed, picking the most recent match.
- **`contextual_match_prev_cmd`** does the same for the candidate
  list, and additionally requires the *preceding* entry to be local —
  so the "what comes after X" pattern is learned from this shell's
  typing only, not from peer shells.

Both honour `ZSH_AUTOSUGGEST_HISTORY_IGNORE` the same way upstream
does. Full algorithmic detail in
[INTERNALS — autosuggestions strategies][ia].

[ia]: INTERNALS.md#zsh-autosuggestions-strategies

### Load-order notes

- Both plugin source lines can be in either order. Our nav-widget
  wrap chain composes correctly either way (test_p33).
- The `ZSH_AUTOSUGGEST_STRATEGY` assignment must come **after**
  sourcing `zsh-autosuggestions.zsh`, which assigns a default at
  source time.

----------------------------------------------------------------------------
fzf integration
----------------------------------------------------------------------------

> Replaces `^R` with a picker that distinguishes this-shell entries
> from peer-shell entries, with an in-picker toggle to switch between
> "this shell only" and "everything".

Provided by `contextual-history-fzf-widget`. Auto-loads when `fzf` is
on `$PATH` at plugin source time.

### Quick start

The integration auto-loads when `fzf` is on `$PATH` — you don't need
to source anything extra. All you do is decide how the widget gets
invoked. The simplest path:

```zsh
zstyle ':contextual-history:*' fzf-bind-ctrl-r true
source /path/to/contextual-history.zsh
```

That hands `^R` to `contextual-history-fzf-widget` at first precmd
(replacing fzf's stock `fzf-history-widget`). Press `alt-l` inside
the picker to see local-only history, `alt-a` to flip back to all.
That's it.

Two alternative wire-ups (separate key, or manual `^R` with fzf's
default suppressed) are described under
[Wire-up alternatives](#wire-up-alternatives) below.

### How it works

The fzf widget lives in **`contextual-history-fzf.zsh`**, auto-sourced
by the main plugin when `fzf` is on `$PATH` (gateable with
`fzf-integration` / `CONTEXTUAL_HISTORY_FZF_INTEGRATION`).

Each entry in the picker is tagged `L` (typed in *this* shell) or `F`
(arrived from somewhere else — another shell, or a prior session of
this terminal). The toggle binds (default `alt-l` / `alt-a`) flip
between "L-only" and "everything" by adjusting fzf's query filter —
no subprocess relaunch, no race, and your in-flight free-text query
is preserved.

For the on-disk record format, fzf wire-up details, and how `L`/`F`
classification stays correct across `^G` toggles and `cd`, see
[INTERNALS — fzf widget][ifw].

[ifw]: INTERNALS.md#fzf-widget-and-the-foreign-tag-preservation-problem

### Wire-up alternatives

The Quick Start above shows the auto-bind path. If you want a
different key or want fzf's `^R` left alone entirely:

**Bind to a separate key — leave fzf's `^R` alone:**

```zsh
# In .zshrc, AFTER both fzf's key-bindings.zsh and contextual-history are sourced.
bindkey -M emacs '^X^R' contextual-history-fzf-widget
bindkey -M viins '^X^R' contextual-history-fzf-widget
bindkey -M vicmd '^X^R' contextual-history-fzf-widget
```

**Disable fzf's `^R`, bind ours to `^R` manually:**

```zsh
FZF_CTRL_R_COMMAND=''                       # tells fzf to skip ^R install
source /path/to/fzf/key-bindings.zsh
source /path/to/contextual-history.zsh

bindkey -M emacs '^R' contextual-history-fzf-widget
bindkey -M viins '^R' contextual-history-fzf-widget
bindkey -M vicmd '^R' contextual-history-fzf-widget
```

Load-order note: for the auto-bind path (Quick Start), order doesn't
matter — the plugin checks at first precmd. For the two manual paths
above, `bindkey` runs immediately, so fzf must have already been
sourced (or had its `^R` install suppressed via `FZF_CTRL_R_COMMAND=''`)
to avoid fzf clobbering your bind afterwards.

### Toggle keys, prompts, default view

```zsh
zstyle ':contextual-history:*' fzf-default-view      all          # or 'local'
zstyle ':contextual-history:*' fzf-toggle-local-key  'alt-l'
zstyle ':contextual-history:*' fzf-toggle-all-key    'alt-a'
zstyle ':contextual-history:*' fzf-prompt-local      'LOCAL> '
zstyle ':contextual-history:*' fzf-prompt-all        'ALL> '
zstyle ':contextual-history:*' fzf-extra-opts        '--height 60%'
```

Inside the fzf session: press `alt-l` to filter to local entries
only; press `alt-a` to see everything. The flag is anchored to the
start of the visible field, so user-typed queries combine cleanly:
typing `make build` in local view searches local-only entries
containing those tokens.

### Live refresh

The picker shows a snapshot taken when you press the bind key. While
fzf is open, that snapshot is fixed. To pick up commands that arrived
from other shells while you were in the picker, close it and re-press
the bind key — that re-snapshots.

### What the native module changes

The picker works fine without the optional native module. With the
module loaded, mid-session refreshes preserve the `L`/`F` distinction
more accurately for entries that arrive while you're idle. See
[Optional native helper module](#optional-native-helper-module).

----------------------------------------------------------------------------
Tests
----------------------------------------------------------------------------

```sh
cd tests
make                # full PTY suite, both module configs (50 cases)
make test           # alias for the above
make test-no-module # pure-shell only
make test-with-module
make test-upstream  # curated subset run against jimhester's upstream
                    # plugin (auto-fetched into .upstream/) -- documents
                    # which bugs the fork fixes by showing them failing
                    # on upstream vs. passing on the fork
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
`SHARE_HISTORY` (and to keep working under mid-session toggling, mode
flips, and concurrent shells) required architectural changes deep enough
that this is no longer the upstream plugin, even if the user-facing
surface is similar. Each finding below is grounded in a reproducible
scenario test under `tests/`.

| Change from upstream | Reason |
|---|---|
| `$HISTFILE` is swapped on `chpwd`/toggle (was: `fc -p` inside `zshaddhistory`) | `fc -p` inside the addhistory hook is auto-popped by `hend()` (`Src/hist.c:1633`). The per-dir file never becomes zsh's authoritative `$HISTFILE`, so `SHARE_HISTORY`'s prompt-time merge never reads it. Same-directory cross-terminal sync is silently broken in upstream. |
| No `fc -AI` flush in mode-swap functions | `fc -AI` against an active history file triggers `savehistfile()`'s rewrite block (`Src/hist.c:3082-3098`), which truncates and rewrites the file out from under concurrent SHARE readers. They silently lose entries. |
| Shell-exit mode (no `SHARE`/`INC`) gets `fc -AI` flush at `chpwd`, gated to that mode | Without an explicit flush, in-memory entries get wiped at ring-replace before reaching disk. The rewrite-block hazard doesn't apply in shell-exit mode because there's no concurrent reader. |
| Tee writes the *inactive* store on every command, in extended-history format unconditionally | Keeps both stores ever-growing regardless of mode. `SHARE_HISTORY`'s incremental writer forces extended format internally; mixed format on disk perturbs the per-process `lasthist` tracker. |
| Tee uses zsh's actual lock protocol | Without it, multi-syscall writes (large pasted blobs) can interleave with stock zsh's incremental writers on the same file. |
| Optional native helper module | Calls zsh's own `lockhistfile`/`unlockhistfile` directly, plus a clean ring-replace builtin that avoids the 2-entry leak inherent to `HISTSIZE=2; fc -R`. Plugin gracefully falls back to pure-shell when not built. |
| Configurable contextual grouping | Per-directory granularity is too fine for project work. Walking up to a marker (`.histroot`, `.git`) gives one history file per project; stop-points bound the walk. |

For the source-level walk-through — `Src/hist.c` line numbers, the
rewrite-block call trace, the 2-entry leak's mechanism in
`histsizesetfn`, the investigation arc, and what we ruled out along
the way — see [**INTERNALS.md**](INTERNALS.md). It's the canonical
record of how each finding was confirmed and what alternatives were
rejected.

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
