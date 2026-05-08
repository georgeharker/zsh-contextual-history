# Test infrastructure

Reproducible scenario tests for `contextual-history.zsh`, comparing this
fork against a clean upstream (`jimhester/per-directory-history`) where
applicable. Used both as regression coverage and as an investigation
ground when debugging shell-driver interactions with native zsh.

## Layout

```
docs/tests/
├── README.md           (this file)
├── .gitignore          (ignores results/)
├── test_sNN_*.zsh      (top-level scenario runners; see scenario index below)
├── lib/                (reusable harnesses)
│   ├── single_shell.zsh
│   └── multi_shell.zsh
├── inputs/             (zsh command streams fed via stdin)
│   ├── probe_*.zsh     (diagnostic probes for ad-hoc investigation)
│   ├── seq_*.zsh       (input scripts for sequential scenarios)
│   └── _sNN_*.zsh      (auto-generated per-test inputs; gitignore'd)
└── results/            (gitignored, ephemeral; each run creates a fresh tree)
```

* `lib/single_shell.zsh` runs one isolated zsh subshell with a controlled
  `ZDOTDIR`, scripted input on stdin, and the named plugin sourced. Used
  for sequential tests and diagnostic probes.
* `lib/multi_shell.zsh` runs two interactive zsh subshells in parallel,
  driving each via a FIFO and synchronising on output markers (`MK-NNNN`)
  so command-by-command interleaving is deterministic. Used for live
  cross-shell visibility tests.
* `inputs/` holds zsh scripts fed as stdin to the harnesses. Pure
  command streams — no orchestration logic.
* `test_sNN_*.zsh` are the user-facing entry points. Each configures
  `TEST_*` env vars, runs the harness against both upstream and fork
  where comparison is meaningful, and prints a side-by-side block at
  the end.

Both harnesses honour two test-driver knobs:

* `TEST_HISTROOT=/path` — base dir for all history files this run uses
  (default: `mktemp -d`). Set to share state across passes in sequential
  tests.
* `PER_DIRECTORY_USE_MODULE=true` — exported to the child shell so the
  plugin loads the optional native helper. Lets the matrix exercise both
  the pure-shell and native-module tee paths.

## Prerequisites

* A clean upstream clone at `/tmp/pdh-upstream/per-directory-history.zsh`
  for tests that compare against upstream. Override with the
  `UPSTREAM_PLUGIN` env var. (Tests that don't compare upstream — s08,
  s09, s10 — don't need it.)
* zsh 5.3+ for `add-zle-hook-widget`.
* For native-module mode: build the module first (`cd module && make`),
  then export `PER_DIRECTORY_USE_MODULE=true` before running tests.

## Running

Run a single scenario:

```sh
zsh docs/tests/test_s01_concurrent_share.zsh
```

Run the matrix in both modes:

```sh
unset PER_DIRECTORY_USE_MODULE
for t in docs/tests/test_s*.zsh; do zsh "$t" >/dev/null && echo "PASS $t"; done

export PER_DIRECTORY_USE_MODULE=true
for t in docs/tests/test_s*.zsh; do zsh "$t" >/dev/null && echo "PASS $t"; done
```

Each test writes to `docs/tests/results/<test_name>/...` and prints a
comparison block at the end summarising what shell 2 (or the read-back
shell) saw.

## Scenario index

The tests fall into three groups: SHARE/INC behaviour, mode-N flush, and
contextual grouping.

### SHARE / INC behaviour

| File | Type | Options | What it tests |
|------|------|---------|---------------|
| `test_s01_concurrent_share.zsh` | concurrent same-dir | `SHARE` | Live cross-shell visibility (the headline feature). |
| `test_s03_concurrent_inc.zsh` | concurrent same-dir | `INC` only | Control: no live sync expected from native zsh. |
| `test_s03b_sequential_inc.zsh` | sequential same-dir | `INC` only | INC persistence across shell exit/start. |
| `test_s04_concurrent_share_inc.zsh` | concurrent same-dir | `SHARE` + `INC` | Combined options match `SHARE`-alone behaviour. |
| `test_s04b_sequential_share_inc.zsh` | sequential same-dir | `SHARE` + `INC` | Persistence with both options. |
| `test_s05_concurrent_diff_dirs.zsh` | concurrent diff-dirs | `SHARE` | Per-context isolation: dir-A activity doesn't leak into dir-B. |
| `test_s06_concurrent_toggle.zsh` | concurrent same-dir + toggle | `SHARE` | Shell 1 toggles to global mid-session; shell 2 still sees pre+post-toggle entries via inactive-store tee. |
| `test_s07_three_shells_isolation.zsh` | sequential A→B→C | `SHARE` | Three shells with intervening different-dir activity; isolation holds. |

### Mode-N (no incremental options)

| File | Type | What it tests |
|------|------|---------------|
| `test_s08_mode_N_chpwd_flush.zsh` | sequential, mode N | `chpwd` flushes pending entries to outgoing dir's file via `fc -AI` so they don't get lost. |

### Contextual grouping resolver

| File | Type | What it tests |
|------|------|---------------|
| `test_s09_group_by_marker.zsh` | sequential, `GROUP_BY=(.git)` | Two subdirs of one project share one history (resolver walks up to the `.git` root). |
| `test_s10_group_strategies.zsh` | sequential | Closest-ancestor wins for nested markers; `GROUP_STOPS` blocks walk-up from finding a higher marker. |

### Diagnostic probes (kept from investigation)

| File | What it explored |
|------|------------------|
| `test_s06_diag_no_toggle.zsh` | Replaces toggle with `:` — confirms toggle-action specifically (not just an extra command) caused the original s06 bug. |
| `test_s06_diag_fc_AI.zsh` | Replaces toggle with bare `fc -AI` — confirms `fc -AI` is the actual cause, not anything else the toggle did. |
| `test_s06_diag_extended.zsh` | Same as s06 but with `EXTENDED_HISTORY` set; surfaces format/timestamp interactions. |
| `inputs/probe_fc_p_in_hook.zsh` | Verifies that `fc -p` inside `zshaddhistory` is auto-popped by `hend` (the upstream plugin's silent-failure mechanism). |
| `inputs/probe_zshenv.zsh` | Verifies our `ZDOTDIR` isolation actually prevents the user's `~/.zshenv` from contaminating tests. |
| `inputs/probe_fc_AI_file_effect.zsh` | Inspects what `fc -AI` does to file bytes — used to discover the savehistfile internal rewrite block. |

## Isolation

The harnesses set `ZDOTDIR` to a freshly-created temp directory and write
a minimal `.zshrc` there. This bypasses any user-level zsh files
(`~/.zshenv`, `~/.zshrc`, `~/.zprofile`) because zsh consults
`$ZDOTDIR/.zshenv` first when `ZDOTDIR` is set, with no fallback to
`$HOME` for those files.

System-wide files (`/etc/zshenv`, `/etc/zshrc`,
`/etc/zshrc_Apple_Terminal` on macOS) still load. Their presence is
acceptable because they reflect the baseline conditions of any zsh user;
their effect on test output (cosmetic prompt characters and ANSI
sequences) is stripped before content matching.

`inputs/probe_zshenv.zsh` exercises this isolation explicitly. Run via
`lib/single_shell.zsh` if you want to verify clean-room isolation on
your machine.

## Adding a scenario

1. Create `test_sNN_<short-description>.zsh` at the top level.
2. Set the `TEST_*` env vars at the top (which options the test cares
   about).
3. Either drive a multi-shell scenario via `lib/multi_shell.zsh`, or a
   sequential scenario via two/three calls to `lib/single_shell.zsh`
   sharing `TEST_HISTROOT`.
4. End with a comparison block — print whatever you want a human (or a
   matrix runner's grep) to see, then echo PASS/FAIL semantics in the
   trailing comments so future-you remembers what "good" looks like.
5. Add an entry to the scenario index above.
