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

Status: 32 PTY scenarios, run under both pure-shell and native-module
paths — 64/64 green when the module is built, with appropriate skips
when fzf isn't on PATH or the module isn't built. Coverage spans
single-shell flow, two- and three-shell SHARE/INC late-join and
ordering, repeated mode toggles, chpwd with concurrent peer reader,
group-by × multi-shell × toggle interactions, fcntl-lock contention,
paths with spaces, custom-resolver edge cases, the fzf integration
(snapshot tagging, filter toggle, no-module degradation, load gate,
the L/F semantic, L preservation across ring swap), and the
local-history navigation filter.

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

Settings split into two groups: **core** (history behaviour) and
**fzf integration** (auto-loaded by default — see `use-fzf` below).

### Core settings

```zsh
zstyle ':contextual-history:*' history-base     ~/.directory_history
zstyle ':contextual-history:*' toggle-key       '^G'
zstyle ':contextual-history:*' group-by         .histroot .git
zstyle ':contextual-history:*' group-stops      $HOME
zstyle ':contextual-history:*' refresh-on-nav   true
zstyle ':contextual-history:*' use-module       true
zstyle ':contextual-history:*' use-fzf          true
zstyle ':contextual-history:*' debug            false
```

| Variable | zstyle key | Default | Effect |
|----|----|----|----|
| `HISTORY_BASE` | `history-base` | `$HOME/.directory_history` | Base dir for per-context history files. |
| `HISTORY_START_WITH_GLOBAL` | `start-with-global` | `false` | Start in global mode rather than context mode. |
| `CONTEXTUAL_HISTORY_TOGGLE` | `toggle-key` | `^G` | Keybinding to flip between context and global modes. |
| `CONTEXTUAL_HISTORY_GROUP_BY` | `group-by` | `()` | Ordered marker list for the default resolver (single walk-up). |
| `CONTEXTUAL_HISTORY_GROUP_STOPS` | `group-stops` | `()` | Walk-up boundary paths. Reaching one without a marker hit fails the search. |
| `CONTEXTUAL_HISTORY_REFRESH_ON_NAV` | `refresh-on-nav` | `true` | Wrap history-navigation widgets so they run `fc -RI` (or the native fast-refresh) before reading `$history`. Mtime-gated. No-op without `SHARE_HISTORY`. |
| `CONTEXTUAL_HISTORY_USE_MODULE` | `use-module` | `false` | Prepend `module/` to `$module_path` so the locally-built native helper loads without a system install. |
| `CONTEXTUAL_HISTORY_USE_FZF` | `use-fzf` | `true` | Load `contextual-history-fzf.zsh` if `fzf` is on `$PATH` at source time. Set `false` to skip loading the fzf widget code entirely. See [fzf integration](#fzf-integration). |
| `CONTEXTUAL_HISTORY_LOCAL_KEY` | `local-toggle-key` | `''` (unbound) | Keybind for the local-history navigation toggle. When set, pressing this key flips between "walk only entries this shell typed" and "walk everything in the ring". See [local-history](#local-history-navigation-filter). |
| `CONTEXTUAL_HISTORY_START_WITH_LOCAL` | `start-with-local` | `false` | Start new shells in local-history mode (this-shell only). Parallel to `start-with-global` for the other axis. Independent of `local-toggle-key`: you can pin the mode on without binding a key. |
| `CONTEXTUAL_HISTORY_DEBUG` | `debug` | `false` | Print `[ch-dbg] ...` lines to stderr at key transitions (mode swap, chpwd, tee fallback). |
| `CONTEXTUAL_HISTORY_REFRESHING_WIDGETS` | `refreshing-widgets` | (full nav-widget list) | Override which widgets get the refresh wrap. Rarely needed. |
| `CONTEXTUAL_HISTORY_LOCAL_WIDGETS` | `local-widgets` | (nav widgets, see plugin) | Subset of refreshing-widgets that get the local-history skip applied. Excludes incremental search by default. Rarely needed. |

### fzf-integration settings

Only consulted when the fzf integration loads (see `use-fzf` above).
See [fzf integration](#fzf-integration) for narrative + wire-up
examples; this table is the parameter reference.

```zsh
zstyle ':contextual-history:*' fzf-bind-ctrl-r       false
zstyle ':contextual-history:*' fzf-default-view      all
zstyle ':contextual-history:*' fzf-toggle-local-key  'alt-l'
zstyle ':contextual-history:*' fzf-toggle-all-key    'alt-a'
zstyle ':contextual-history:*' fzf-prompt-local      'LOCAL> '
zstyle ':contextual-history:*' fzf-prompt-all        'ALL> '
zstyle ':contextual-history:*' fzf-extra-opts        ''
```

| Variable | zstyle key | Default | Effect |
|----|----|----|----|
| `CONTEXTUAL_HISTORY_FZF_BIND_CTRL_R` | `fzf-bind-ctrl-r` | `false` | At first precmd, bind `^R` (emacs/viins/vicmd) to our widget if fzf's `fzf-history-widget` is also present. Off by default so users with custom `^R` bindings keep them. |
| `CONTEXTUAL_HISTORY_FZF_VIEW` | `fzf-default-view` | `all` | Initial view: `local` (this shell only) or `all` (every entry). |
| `CONTEXTUAL_HISTORY_FZF_LOCAL_KEY` | `fzf-toggle-local-key` | `alt-l` | fzf-internal bind to switch to local view. |
| `CONTEXTUAL_HISTORY_FZF_ALL_KEY` | `fzf-toggle-all-key` | `alt-a` | fzf-internal bind to switch to all view. |
| `CONTEXTUAL_HISTORY_FZF_PROMPT_LOCAL` | `fzf-prompt-local` | `'LOCAL> '` | fzf prompt string for local view. |
| `CONTEXTUAL_HISTORY_FZF_PROMPT_ALL` | `fzf-prompt-all` | `'ALL> '` | fzf prompt string for all view. |
| `CONTEXTUAL_HISTORY_FZF_EXTRA_OPTS` | `fzf-extra-opts` | `''` | Extra fzf opts appended after our defaults. Also honours upstream `FZF_CTRL_R_OPTS`. |

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
Local-history navigation filter
----------------------------------------------------------------------------

Opt-in keybind that makes up-arrow / down-arrow (and the other history
navigation widgets) **skip entries this shell didn't type** — letting
you scroll through your own commands without peer-shell or
prior-session entries in the way. The toggle is per-shell-instance
and persists until you toggle off (or the shell exits).

The feature lives in the sibling file **`contextual-history-keybinds.zsh`**,
auto-sourced by the main plugin. The file is the container for
keybind-driven opt-in features; the local-history toggle is the
first inhabitant, but other keybinds can be added here without
polluting the core plugin.

### Setup

Pick a key and set it via zstyle (unbound by default):

```zsh
zstyle ':contextual-history:*' local-toggle-key '^X^L'
# Equivalent env-var form: CONTEXTUAL_HISTORY_LOCAL_KEY='^X^L'

# Optional: start new shells in local-history mode without needing
# to press the toggle. Independent of the keybind above.
zstyle ':contextual-history:*' start-with-local true
# Equivalent env-var form: CONTEXTUAL_HISTORY_START_WITH_LOCAL=true

source /path/to/contextual-history.zsh
```

That binds your chosen key to a toggle widget in emacs, viins, and
vicmd keymaps. Toggling either this widget or the context/global
toggle (^G) emits a `zle -M` status line showing both axes, e.g.
`history: context | this-shell only (12 entries)` or
`history: global | all shells`.

### How it works

- Every command this shell runs goes through the `zshaddhistory`
  hook, which records the command text in an in-memory set
  (`_context_history_local_texts`). Memory cost: ~60 B per command
  this shell types; bounded by user activity, not history depth.
- When local-history mode is on, the existing nav-widget wrap (the
  same one that handles `refresh-on-nav`) adds a *skip loop* around
  the underlying widget: dispatch the widget, check if the loaded
  `BUFFER` is in the local-texts set; if not, dispatch again. Bail
  on boundary (`HISTNO` stops advancing) or after a safety cap.
- The check is O(1) — a single associative-array lookup.

### What it skips

Applied to the standard history navigation widgets:

- `up-history`, `down-history`
- `up-line-or-history`, `down-line-or-history`
- `up-line-or-search`, `down-line-or-search`
- `history-search-backward`, `history-search-forward`
- `history-beginning-search-backward`, `history-beginning-search-forward`

**Not** applied to incremental search (`history-incremental-search-*`)
— its stateful per-keystroke semantics don't compose well with a
skip-after-dispatch loop. Incremental search behaves as today.

### Caveats

- **Requires `refresh-on-nav=true`** (the default). The local-history
  skip lives inside the same widget wrap that does refresh-on-nav.
  If you've explicitly disabled that, local-history mode won't
  activate.
- **False positive when peer typed the same exact text**. The lookup
  is text-only (`$history` doesn't expose `stim` per entry, so we
  can't do `(stim, text)` cheaply at per-keystroke rate). If a peer
  shell ever typed the same command text as you, local-history mode
  will treat it as yours. Pragmatically acceptable: worst case is
  one extra step that lands on a peer entry that happens to be your
  exact prior command anyway.
- **History from prior sessions isn't yours.** Entries that were on
  disk before this shell started — even your own typing from a
  previous session — aren't in the local-texts set. They'll be
  skipped in local-history mode. This matches the L/F semantic the
  fzf widget uses; documented as the same trade-off there.

### Combining with `^G` context-toggle

The local-history toggle and `^G` (context/global toggle) operate on
orthogonal axes:

|  | Context history (per-dir) | Global history |
|---|---|---|
| **All entries** | up walks every entry in the per-dir ring | up walks every entry in the global ring |
| **Local-history on** | up walks only your typing in this context | up walks only your typing in global mode |

Combine the two keybinds to navigate within whichever slice you want.

----------------------------------------------------------------------------
zsh-autosuggestions integration
----------------------------------------------------------------------------

Opt-in suggestion strategies that mirror the plugin's toggle state
in the inline grey suggestion. Two are provided — pick whichever
matches your preferred upstream strategy:

- **`contextual_history`** — local-history-aware port of upstream's
  `history` strategy (newest entry matching the prefix).
- **`contextual_match_prev_cmd`** — local-history-aware port of
  upstream's `match_prev_cmd` strategy (prefer an entry whose
  preceding history entry equals your previously-executed command,
  fall back to newest prefix match).

Both strategies:

- automatically scope to whichever ring `^G` has currently selected
  (context vs global), because they read from `$history` — which IS
  the swapped ring; and
- when local-history is on, restrict suggestions to entries this shell
  typed (and, for `contextual_match_prev_cmd`, also require the
  preceding entry to be local — patterns are learned from this
  shell's typing only).

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

Stock `match_prev_cmd` would work for the context/global axis on its
own (it reads `$history`, which is the swapped ring), but it has no
knowledge of `_context_history_local_texts` — so it would propose
peer entries even when local-history is on, contradicting what up-arrow
walks. The port closes that gap.

### How they work

**`contextual_history`** — when local-history is off, uses the same
single `${history[(r)PATTERN]}` subscript upstream's `history`
strategy uses (no overhead). When local-history is on, iterates the
prefix-matching histnum keys newest-first and emits the first entry
that is in the this-shell texts set. The membership check is O(1).

**`contextual_match_prev_cmd`** — builds a candidate list of histnum
keys whose entries match the prefix (newest-first by `$history`
iteration order). When local-history is on, filters that list to local
entries only. Default suggestion is the newest remaining candidate;
upgraded to a candidate whose preceding history entry equals the
previously-executed command. In local-history mode the preceding-entry
must also be local. Mirrors upstream's 200-candidate search cap.

Both strategies honour `ZSH_AUTOSUGGEST_HISTORY_IGNORE` the same
way upstream does.

### Load-order notes

- Both plugin source lines can be in either order. Our nav-widget
  wrap chain composes correctly either way (test_p33).
- The `ZSH_AUTOSUGGEST_STRATEGY` assignment must come **after**
  sourcing `zsh-autosuggestions.zsh`, which assigns a default at
  source time.

----------------------------------------------------------------------------
fzf integration
----------------------------------------------------------------------------

The plugin ships an opt-in `^R`-style widget,
`contextual-history-fzf-widget`, that lets you distinguish history
entries this shell wrote from entries merged in from other shells —
and toggle between "local only" and "all entries" inside fzf without
relaunching.

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

The fzf widget lives in a sibling file, **`contextual-history-fzf.zsh`**,
which the main plugin sources automatically when:

- `use-fzf=true` (the default), and
- `fzf` is on `$PATH` at plugin source time.

Set `zstyle ':contextual-history:*' use-fzf false` (or
`CONTEXTUAL_HISTORY_USE_FZF=false`) to skip loading the fzf code
entirely.

Zsh maintains a per-entry `HIST_FOREIGN` flag, visible as the `*`
column in `fc -l` output. Entries this shell wrote itself are
unmarked; entries pulled in via `SHARE_HISTORY`'s incremental merge
get the marker. The plugin's fzf widget surfaces this distinction:

- Reads `fc -li 1` (preserving the `*` column), one record per entry.
- Hands fzf a tab-delimited record `<flag>\t<histnum>\t<stim>\t<text>`
  where `<flag>` is `L` (local) or `F` (foreign).
- `--with-nth=1,4..` displays only flag + text; histnum/stim are
  hidden but available to the post-selection retrieval.
- Two fzf-internal binds (default `alt-l` / `alt-a`) flip between
  views by manipulating the query — fzf's extended search syntax
  filters by an anchored prefix (`^L `) against the joined display.
  No `reload`, no subprocess fork per toggle, and your in-flight
  free-text query is preserved.
- Selection retrieval uses `zle vi-fetch-history -n <histnum>`,
  which sidesteps the documented `${(kv)history[@]}` lag bug on
  foreign entries (see the comment in fzf upstream's
  `key-bindings.zsh`).

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

### How L/F classification works (and why the module is optional)

zsh's `HIST_FOREIGN` flag is set only on entries newly loaded via
the `HFILE_FAST` code path in `readhistfile` (`Src/hist.c:2706-2708`),
which means: peer-shell writes merged in via `SHARE_HISTORY`'s
hend-merge AFTER this shell started. Crucially, entries already on
disk at shell start — including yesterday's typing in this very
terminal — are loaded without `HFILE_FAST` and so have no foreign
tag. Tagging by `HIST_FOREIGN` alone would misclassify yesterday's
own typing as "local to this shell" — surprising.

The widget closes this gap with a `(stim, text)` identity set
populated at every `zshaddhistory` hook firing in the main plugin.
At snapshot time, each ring entry's `${stim}:${text}` is looked up;
hit → L, miss → F. This survives ring replacement (toggle, chpwd)
because the lookup key is on-disk identity (stim + text are
preserved by `readhistfile` from the file's `: stim:elapsed;text`
lines) — not histnum, which gets reassigned on every reload.

The native module is therefore **not required for L/F correctness**.
What the module still buys you for the fzf widget: faster
refresh-on-nav (the `contextual-history-fast-refresh` builtin calls
`readhistfile` with `HFILE_FAST | HFILE_SKIPOLD` for a clean
HIST_FOREIGN-preserving merge), and a clean ring-replace at toggle
that avoids the documented 2-entry leak. Both are nice; neither
changes the L/F semantic.

False-positive case: a peer shell writes the *exact* same command
text in the *exact* same second as you. Vanishingly rare in
practice and the only edge case where (stim, text) collides.

### Snapshot semantics and live refresh

The snapshot is taken once when the widget launches (after a
fast-refresh against the on-disk file). Within an open fzf session
the snapshot is fixed — `HIST_FOREIGN` exists only in this shell's
in-memory ring, so a subprocess can't recompute it. To pick up
writes from peer shells that happened while fzf was open, close fzf
and re-press the bind key.

The toggle binds (alt-l / alt-a) operate on the existing snapshot
via fzf's query-filter mechanism — no reload, no race.

### Test coverage

Six PTY scenarios under `tests/` cover this:

- `test_p26_fzf_snapshot_basic.zsh` — fast-refresh tags new on-disk
  entries foreign; snapshot parser emits L/F flags correctly.
- `test_p27_fzf_filter_toggle.zsh` — two-shell SHARE scenario; shell
  B's writes appear as F in shell A's snapshot; `fzf --filter='^L '`
  excludes them; combined local + free-text queries work.
- `test_p28_fzf_no_module_degrades.zsh` — without the module, the
  widget still loads and the L/F classification still works.
- `test_p29_fzf_load_gate.zsh` — `use-fzf=false` and "fzf not on
  PATH" both correctly skip loading the fzf integration.
- `test_p30_foreign_tag_semantics.zsh` — pins the four classification
  cases: pre-existing → F, peer-after-start → F, dedup across
  fast-refresh, own-typing → L.
- `test_p31_local_across_swap.zsh` — typed entry stays L through a
  full ring replacement cycle (toggle to global and back).

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
