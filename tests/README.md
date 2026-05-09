# Test infrastructure

PTY-based interactive scenario tests for `contextual-history.zsh`.

## Quickstart

```sh
make            # run the full PTY suite (recommended)
make test       # alias for the above
make clean      # remove transient artifacts
```

Or run individual tests directly:

```sh
zsh test_p01_share_idle_visibility.zsh
```

The runner runs every `test_p*.zsh` under both
`CONTEXTUAL_HISTORY_USE_MODULE=false` (pure-shell tee) and `=true`
(native helper builtin). The with-module pass is skipped if the
module hasn't been built.

## Layout

```
tests/
├── Makefile               (test entry points)
├── README.md              (this file)
├── run_pty_tests.zsh      (runner: every test_p*.zsh x both module configs)
├── lib/
│   └── pty_harness.zsh    (zpty-based PTY harness library)
└── test_p<NN>_<name>.zsh  (per-scenario test files)
```

## How the harness works

`lib/pty_harness.zsh` uses zsh's built-in `zsh/zpty` module to spawn
real interactive zsh shells under controlled pty pairs. Each spawned
shell:

* runs in a scratch `ZDOTDIR` with an empty `.zshenv` (no user-level
  config leaks in),
* gets a deterministic marker prompt (`_PTYRDY_<name>_$ `) so the
  harness can pattern-match for "shell at fresh prompt" without
  sleeps,
* binds a debug widget to `^X` that prints `BUFFER` and `HISTNO` to
  stderr without modifying ZLE state — tests use this to observe what
  up-arrow loaded into the line editor without having to commit it.

The harness exposes:

| Helper | Purpose |
|---|---|
| `pty_spawn <name> <histroot> [opts via env]` | spawn a shell, wait for first prompt |
| `pty_run_cmd <name> <cmd>` | type cmd + Enter, wait for next prompt |
| `pty_press_up <name>` | send `^P` (up-line-or-history) |
| `pty_press_down <name>` | send `^N` (down-line-or-history) |
| `pty_press_ctrlg <name>` | send `^G` (toggle widget) |
| `pty_press_ctrlc/u <name>` | send `^C` / `^U` |
| `pty_press_enter <name>` | send `\r` |
| `pty_inspect_buf <name>` | observe BUFFER without executing; prints to stdout |
| `pty_cleanup <name>...` / `pty_cleanup_all` | tear down pty + tmpdir |
| `pty_pass` / `pty_fail <msg>` | exit with PASS/FAIL marker |

Caller env vars passed through to the spawned shell:
`TEST_SHARE_HISTORY`, `TEST_INC_APPEND`, `TEST_EXTENDED`,
`TEST_START_GLOBAL`, `CONTEXTUAL_HISTORY_USE_MODULE`,
`CONTEXTUAL_HISTORY_DEBUG`.

`TEST_PRE_SOURCE` is a special caller-set string inlined verbatim into
the spawned shell's `.zshrc` immediately before `source $PLUGIN`.
Used to inject `zstyle ...` config (or arbitrary pre-source code) that
must take effect before the plugin resolves its options. Not env-passed
through `zpty` because zpty eval-reparses argv and mangles quoted
values.

## Test scenarios

| ID | Validates |
|---|---|
| **p01** | `SHARE_HISTORY` cross-shell sync at idle prompt — shellA's up-arrow sees shellB's write |
| **p02** | First-prompt up-arrow finds the last saved entry on a fresh shell (the original off-by-one bug, fixed by pre-init `HISTFILE` swap) |
| **p03** | Walking history forward and back with `^P`/`^N` stays consistent across multiple presses |
| **p04** | Multiple cross-shell writes are visible in order |
| **p05** | Per-directory cross-shell sync — two shells in same directory share per-dir history |
| **p06** | Per-directory isolation — shells in different directories don't see each other's per-dir writes |
| **p07** | `^G` toggle between per-dir and global modes loads the correct file's content |
| **p08** | Without `SHARE_HISTORY`, no auto cross-shell merge (per-shell isolation respected) |
| **p09** | `INC_APPEND_HISTORY` persistence — commands typed by one shell visible to a later-spawned shell with same HISTFILE |
| **p10** | Native helper module path is functionally equivalent to pure-shell tee |
| **p11** | Toggle between modes documents the 2-entry leak inherent to `HISTSIZE=2; fc -R` ring replacement |
| **p12** | chpwd swap documents the same 2-entry leak (`hend` writes the cd command to the OLD per-dir file before chpwd swaps) |
| **p13** | Concurrent toggle — shellA toggles modes mid-session while shellB stays in dir mode and observes via the tee |
| **p14** | Mode-N (no SHARE/INC) chpwd flush via `fc -AI` writes in-memory ring to outgoing dir's file before swap |
| **p15** | `CONTEXTUAL_HISTORY_GROUP_BY=(.git)` resolver walks up to project root |
| **p16** | `GROUP_BY` "closest ancestor with any marker wins" — pattern order doesn't matter when ancestors at different depths each have a different marker |
| **p17** | `zstyle ':contextual-history:*' group-by .git` — config via zstyle (no env var) takes effect at plugin source time; verifies the env-var > zstyle > default precedence chain |
| **p18** | Three-shell SHARE same-context — late-joining shell C sees prior writes from A and B; cross-shell merge ordering preserved chronologically |
| **p19** | Repeated mode toggles within one shell don't drop entries — peer shell B (in per-dir) sees every write A made across multiple toggle cycles, including A's global-mode writes (tee'd into per-dir as inactive store) |
| **p20** | chpwd with concurrent peer reader — A `cd`s out of dirA while B reads dirA's per-dir; B's view stays correct and never sees A's post-cd writes from the new directory's per-dir |
| **p21** | Repeated-toggle survival — five full toggle cycles (10 mode switches) with a write per phase; both stores must contain every expected entry in chronological order |
| **p22** | Group-by + two shells + toggle — two shells in different subdirs of the same `.git` project share the project-root per-dir via zstyle group-by; one toggling to global doesn't break the other's view |
| **p23** | `HIST_FCNTL_LOCK` path — two shells write rapidly into the same per-dir context with fcntl locking; all entries land in both stores in well-formed extended-history shape, no truncation |
| **p24** | Per-dir path with spaces and shell-significant characters — cd into an awkward path, write, verify per-dir file at expected path; cross-shell SHARE merge works across the awkward path |
| **p25** | Custom resolver edge cases — empty-string key collapses all dirs to a single shared file; whitespace-containing key works end-to-end with cross-shell SHARE merge. Surfaced and fixed a `HISTORY_BASE` × resolver-key path-join bug |

## Adding a new test

1. Create `test_pNN_<short_name>.zsh` patterned on an existing test.
2. Source `lib/pty_harness.zsh`.
3. `mktemp -d` for `HISTROOT`, set up a `trap` for cleanup.
4. `pty_spawn` whatever shells you need.
5. Drive the scenario with the helpers above.
6. End with `pty_pass` or `pty_fail "<message>"`.
7. Run `make test` to confirm both module configs pass.
