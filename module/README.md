# contextual-history — optional native helper module

> **TL;DR**: run `contextual-history-build-module` (defined by the plugin; clones the matching zsh source, builds the module inside zsh's own module build system, produces `zsh/contextual_history.{so,bundle}` here). Then set `zstyle ':contextual-history:*' use-module true` in your `.zshrc` (before sourcing the plugin) to use it from this directory.

This is an optional zsh module that provides three builtins used by
the contextual-history plugin. The plugin works fine without it
(falls back to portable pure-shell implementations); building and
installing this module replaces the manual implementations with
direct calls into zsh's own internals:

- `contextual-history-tee <file> <command>` — append one extended-format
  line to `<file>` while holding zsh's own `lockhistfile` lock.
  Automatically matches zsh's choice of lock protocol
  (`HIST_FCNTL_LOCK` on → fcntl, default → `<file>.LOCK` symlink).
- `contextual-history-replace-ring <file>` — clean in-memory ring
  replacement that avoids the 2-entry leak inherent to the
  `HISTSIZE=2; fc -R` pure-shell pattern (zsh's `histsizesetfn`
  clamps `histsiz` at 2).
- `contextual-history-fast-refresh <file>` — incremental merge from
  `<file>` that sets `HIST_FOREIGN` on newly loaded entries. Same
  flag set zsh's own `SHARE_HISTORY` hend-merge uses
  (`HFILE_USE_OPTIONS | HFILE_FAST`), plus `HFILE_SKIPOLD` for
  histtab-based dedup against entries already in the ring. The
  pure-shell fallback is `fc -RI`, which uses `HFILE_SKIPOLD`
  without `HFILE_FAST` and therefore does NOT set `HIST_FOREIGN` —
  mid-session arrivals then load as if locally typed, so zsh's own
  foreign-entry behaviour (the `*` column in `fc -l`, `fc -L`'s
  foreign exclusion, history expansion's foreign skip) diverges
  from a stock `SHARE_HISTORY` merge.

Common implementation thread: the module is a regular in-tree zsh
module (it includes its generated `.mdh`, which pulls in the `.epro`
prototype tables) and calls `lockhistfile` / `unlockhistfile` /
`readhistfile` / `unmeta` / `freehistnode` directly. Only
`freehistnode` needs a manual `extern` — it isn't `mod_export` in
`hist.c`, so it's absent from `hist.epro`.

Net result for the tee path: the tee writer interlocks with stock
zsh's own `SHARE_HISTORY` / `INC_APPEND_HISTORY` writers on the same
file, even across multi-syscall edge cases (huge pasted commands)
that the pure-shell fallback's lock-free atomicity can't cover. Net
result for fast-refresh: widget-time refreshes stay behaviourally
identical to zsh's own `SHARE_HISTORY` merge, foreign tagging
included.

## Building

After sourcing the plugin:

```zsh
contextual-history-build-module          # build against the running zsh's version
contextual-history-build-module 5.9      # or build against an explicit version
```

(`CONTEXTUAL_HISTORY_ZSH_SRC_VERSION` overrides the default version
pick, mirroring fzf-tab's `FZF_TAB_ZSH_SRC_VERSION`.)

This works the same way fzf-tab's `build-fzf-tab-module` does:

1. Shallow-clone the matching zsh release tag from
   `github.com/zsh-users/zsh` into `build/zsh-X.Y/`.
2. Symlink `contextual_history.c` + `contextual_history.mdd` into the
   tree's `Src/Modules/`.
3. `./configure` (scans the `.mdd` into `config.modules`) and `make`.
   zsh's own module build system generates the `.mdh`/`.pro` headers
   and compiles/links with the same `DLCFLAGS`/`DLLDFLAGS` it uses
   for its bundled dynamic modules — no hand-rolled platform flags,
   and `SHORTBOOTNAMES` entry-point mangling is handled by the
   generated `.mdh`.
4. Harvest `Src/Modules/contextual_history.{so,bundle}` to
   `zsh/contextual_history.{so,bundle}` in this directory.

The first run takes a few minutes (network fetch + full zsh build).
Subsequent runs skip the clone/configure and only recompile what
changed.

## Using it

```zsh
# In .zshrc, BEFORE sourcing the plugin:
zstyle ':contextual-history:*' use-module true
source /path/to/contextual-history.zsh
```

(Equivalent env-var form: `CONTEXTUAL_HISTORY_USE_MODULE=true`.)

Setting `use-module` makes the plugin prepend `module/` to
`$module_path` so the locally-built `.so`/`.bundle` is discoverable.

## Verification

```sh
zsh -c 'zmodload zsh/contextual_history && echo OK'
zsh -c 'zmodload zsh/contextual_history; which contextual-history-tee'
```

Both should print successfully if the module is on a `$module_path`
directory.

## Cross-platform notes

- **macOS**: builds as `.bundle` (the build helper passes
  `DL_EXT=bundle` when the running zsh's modules are bundles).
  Symbols from the running zsh resolve at load time.
- **Linux**: builds as `.so`. Same dynamic-link model.
- **Symbol naming**: stock macOS/Homebrew zsh uses
  `SHORTBOOTNAMES=yes` (the loader looks up plain `setup_`, `boot_`,
  etc.); some Linux source builds default to `SHORTBOOTNAMES=no`
  (mangled `setup_zshQscontextualQuhistory` names). Because the
  module is built inside zsh's module system, the generated `.mdh`
  `#define`s the entry points to whichever form the host build
  expects — no manual double definitions.

## When NOT to bother

The pure-shell fallback is good enough for the tee + ring-replace
paths in the vast majority of use cases. Single-line `printf >> file`
writes are kernel-atomic with `O_APPEND`, and the pure-shell tee
replicates zsh's `lockhistfile` protocol so it interlocks with stock
zsh writers on the same file.

The native module is meaningfully better when:

- **You care about `HIST_FOREIGN` staying accurate.** The fast-refresh
  builtin is the only script-reachable mechanism that preserves
  `HIST_FOREIGN` through the plugin's widget-time refresh. Without it,
  entries arriving mid-session lose the `*` marker in `fc -l` and
  zsh's foreign-entry semantics (`fc -L`, history expansion's foreign
  skip) drift from stock `SHARE_HISTORY` behaviour. (The fzf widget's
  L/F tagging does not depend on this — it uses the plugin's own
  write-tracking.)
- You routinely paste multi-kilobyte command lines (rare; could trigger
  multi-syscall writes that the lock-free fallback's per-write atomicity
  doesn't cover, where the native helper's held-lock does).
- You hit the 2-entry ring-replace leak on toggle / chpwd and care
  (the leak is documented under `test_p11` / `test_p12`).
- You care about strict bytewise serialisation under all conditions.

If none apply, skip the build. The plugin will use the pure-shell
paths automatically.
