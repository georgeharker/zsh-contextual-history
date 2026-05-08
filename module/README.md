# per-directory-history-helper (optional native module)

> **TL;DR**: `make ZSH_SRC=/path/to/zsh-source` builds `zsh/per-directory-history-helper.{so,bundle}` in this directory. Then either `make install` to put it on `$module_path`, or set `PER_DIRECTORY_USE_MODULE=true` in your `.zshrc` (before sourcing the plugin) to use it from this directory.


This is an optional zsh module that provides a `pdh-tee` builtin used by
the per-directory-history plugin's tee path. The plugin works fine
without it (falls back to a portable pure-shell implementation); building
and installing this module replaces the manual lock + printf with
native zsh primitives:

- `lockhistfile` / `unlockhistfile` from `Src/hist.c` — automatically
  matches zsh's choice of lock protocol (HIST_FCNTL_LOCK on → fcntl;
  default → `.LOCK` symlink).
- `unmeta` for path metafication, matching zsh's internal conventions.

Net result: the tee writer interlocks bytewise with stock zsh's own
SHARE_HISTORY / INC_APPEND_HISTORY writers on the same file, including
across multi-syscall edge cases (huge pasted commands).

## Building

This module uses zsh's standard out-of-tree module build approach. You
need zsh's source tree available so `make` can find `zsh.mdh`,
`pcre.mdh`-style descriptor processing, and the `mkmakemod` machinery.

Two paths:

### Option 1: build inside a zsh source tree (recommended)

1. Get the zsh source matching your installed zsh version:
   ```sh
   zsh --version          # e.g. 5.9
   curl -L https://sourceforge.net/projects/zsh/files/zsh/5.9/zsh-5.9.tar.xz/download -o zsh-5.9.tar.xz
   tar xf zsh-5.9.tar.xz
   cd zsh-5.9
   ./configure
   ```
2. Copy this directory into the zsh tree's modules location:
   ```sh
   cp -r /path/to/per-directory-history/module Src/Modules/per-directory-history-helper
   ```
3. Add the module name to `config.modules` (or invoke `make` with explicit
   module list). See zsh's `Etc/zsh-development-guide` for details.
4. Build the module: `make Src/Modules/per-directory-history-helper.so`
5. Install: copy the resulting `.so` into a directory on `$module_path`
   (typically `$(zsh --version | head -1)`'s `module_path`; `print -l
   $module_path` from zsh).

### Option 2: standalone Makefile (for the adventurous)

A minimal standalone build is possible but requires manual handling of
zsh's `.mdh` header generation. Most users will want Option 1.

## Installing

The plugin loads the module via `zmodload zsh/per-directory-history-helper`.
Place the compiled `.so` somewhere zsh searches for modules:

```sh
print -l $module_path
```

Common locations:
- `/usr/lib/zsh/<version>/zsh/`
- `$HOME/.local/lib/zsh/<version>/zsh/`

## Verification

After installing, in a fresh zsh:

```sh
zmodload zsh/per-directory-history-helper && echo OK
which pdh-tee
```

Then re-source the plugin. The plugin's tee path will use the native
`pdh-tee` builtin instead of the pure-shell fallback. There's no
visible behaviour difference for users — the builtin is a strict
correctness/performance improvement.

## When NOT to bother

The pure-shell fallback is good enough for the vast majority of use
cases. Single-line `printf >> file` writes are kernel-atomic (POSIX
O_APPEND). The native module only meaningfully helps when:

- You routinely paste multi-kilobyte command lines (unusual)
- Multiple terminals heavily contend on the same history file
- You care about strict bytewise serialisation under all conditions

If none of those apply, skip the build. The plugin will use the pure-shell
path automatically.
