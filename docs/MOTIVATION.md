# Motivation: SHARE_HISTORY interaction in per-directory-history

> **Status: bug confirmed, investigation continuing.**
> The original hypotheses about *how* upstream interacts badly with
> `SHARE_HISTORY` were wrong. But integration testing has now identified
> a real, reproducible user-visible problem with upstream + `SHARE_HISTORY`
> that this fork does fix. See "The actual bug, empirically demonstrated"
> below for the concrete failing case. The full test matrix is still in
> progress; this document will be expanded as more scenarios are run.

## The actual bug, empirically demonstrated

`docs/tests/multishell.sh` drives two concurrent interactive zsh
processes via FIFOs against a shared `HISTROOT`, using marker-based
synchronisation (each step ends with `echo MK-NNNN`; the driver waits for
the marker to appear in the shell's log before issuing the next step).

**Scenario:** both shells start in `/tmp/pdh-mst-dirA` with
`setopt SHARE_HISTORY`. Shell 1 runs six commands (`echo cmd-1` ..
`echo cmd-6`). Shell 2 then runs `history`. We capture what shell 2
sees.

**Files on disk after the run** (both upstream and fork):

The per-directory file
`$HISTORY_BASE/private/tmp/pdh-mst-dirA/history` contains all six of
shell 1's commands. The writes are not lost.

**Shell 2's `history` output:**

* **Upstream**: shell 2's `history` shows only its own startup commands.
  All six of shell 1's `cmd-N` writes are missing from shell 2's
  in-memory view, even though they are on disk in the per-directory
  file. (See `docs/tests/results/multishell_01_upstream/shell2.log`
  between `SHELL2-HIST-BEGIN` and `SHELL2-HIST-END`.)
* **Fork**: shell 2's `history` shows all six of shell 1's commands
  intermixed with shell 2's own. (See
  `docs/tests/results/multishell_01_fork/shell2.log`.)

This is a real, user-visible bug in upstream's interaction with
`SHARE_HISTORY` that this fork fixes.

### Why the bug exists in upstream

`SHARE_HISTORY` works by reading `$HISTFILE` on each prompt to merge in
new entries. In upstream, `$HISTFILE` is the user's original global
history file at all times from the user's perspective (the `fc -p` call
in upstream's `zshaddhistory` hook is function-scoped and reverts on hook
exit \u2014 see "Findings" below for the empirical evidence). The
per-directory file is therefore *write-only*: upstream writes to it via
`fc -AI` and `print -Sr`, but no zsh-native machinery ever reads new
entries back from it during the prompt cycle. Shell 2, which has long
since loaded the per-directory file once at chpwd, has no mechanism to
notice that another shell has appended to it.

### Why the fork fixes the bug

The fork sets `$HISTFILE` to the per-directory file directly when the
plugin is in local mode. `SHARE_HISTORY`'s prompt-time read therefore
targets the per-directory file as a real, current-session history file.
When another shell in the same directory appends, this shell's next
prompt sees the new entries through standard `SHARE_HISTORY` machinery.

The fork pays a small price for this: `$HISTFILE` is observably mutated
when crossing directory boundaries. Users who introspect `$HISTFILE`
directly will see something different than they configured. This is
described in the README's "Interaction with SHARE_HISTORY" section.

## Findings (verified by integration tests)

These findings come from `docs/tests/` scripts run against a clean
upstream clone (`/tmp/pdh-upstream/`) and this fork. Raw outputs live
under `docs/tests/results/`.

### `fc -p` inside a `zshaddhistory` hook does not propagate `$HISTFILE`

`docs/tests/probe_fc_p_in_hook.sh` registers a `zshaddhistory` hook that
calls `fc -p /some/other/file` and prints `$HISTFILE` before, inside,
and after the hook. Result:

* **Before** triggering the hook: `$HISTFILE = /tmp/pdh-probe-fc-p-orig.history`
* **Inside** the hook, after `fc -p`: `$HISTFILE = /tmp/pdh-probe-fc-p-newfile.history`
* **After** the hook returns: `$HISTFILE = /tmp/pdh-probe-fc-p-orig.history`

The reassignment of `$HISTFILE` by `fc -p` is **scoped to the hook
function**. It does not propagate to the user shell context. Either zsh
treats history-stack pushes as function-local for hooks, or there is an
implicit `fc -P` on hook return; either way the empirical result is
clear.

### Upstream's `$HISTFILE` is stable across the entire user session

`docs/tests/scenario_02a_first_shell.sh` runs a sequence of commands and
`cd`s while taking `__obs` snapshots that include `$HISTFILE`. With
upstream + `SHARE_HISTORY`, every snapshot reports `$HISTFILE` as the
user's original global history file. It never appears as a per-directory
file. The fork, by contrast, does swap `$HISTFILE` (by design) on chpwd
and toggle.

### The original "fc -p breaks SHARE_HISTORY" hypothesis is false

The original hypothesis claimed that upstream's `fc -p` redirected
`$HISTFILE` such that `SHARE_HISTORY`'s prompt-time merge would target
the wrong file, breaking cross-terminal global sync. This hypothesis is
falsified: `$HISTFILE` is never visibly redirected from the user's
perspective in upstream, so `SHARE_HISTORY`'s merge target is correct.

### Both upstream and fork persist per-directory writes correctly

`docs/tests/scenario_02b_second_shell.sh` is run with the same
`TEST_HISTROOT` as 02a. Shell 2 in `dirA` sees the commands shell 1 wrote
in `dirA` (`cmd-A1-from-shell-1`, `cmd-A2-from-shell-1`) under both
upstream and fork. Persistence-on-startup is equivalent.

## What we still need to test

The basic single-shell scenarios show upstream working as advertised. The
remaining open questions before any PR:

1. **In-memory recall semantics**: with upstream and `$HISTFILE` stable
   at the global file, does the in-memory `$history` array shown by
   Up-arrow / `fc -l` actually filter to per-directory contents, or does
   it just show the global history? If the per-directory recall is
   illusory, the plugin's value proposition is itself in question.
2. **Live cross-terminal sync** (the user's mtime-tracker hypothesis):
   when one shell writes to `$HISTFILE` after another shell has already
   read it, does `SHARE_HISTORY`'s precmd-time merge pick up the new
   entries? `fc` may track per-file last-read state internally, in
   which case writes may appear "already seen" because the writing
   shell updated its own tracker. This needs a parallel two-shell test.
3. **Behaviour after toggle to global**: when a user toggles from local
   to global mid-session, does upstream show stale data, fresh data, or
   the wrong data? The fork's explicit swap is a different mechanism
   that may or may not produce different observable behaviour.

Until these are answered we cannot honestly say what the fork actually
fixes. The original "this fixes SHARE_HISTORY" framing is not supported
by the evidence and must not appear in any PR description.

---

## Original hypotheses (for the record \u2014 falsified)

The following sections capture the analysis as it stood before the
investigation began. They are preserved here for transparency about
what we believed and why, even though the evidence has since shown the
core claim to be wrong.

### Original (falsified) claim

The fork was originally written believing that upstream's `fc -p` call
silently reassigned `$HISTFILE` in a way that broke `SHARE_HISTORY`.
Empirical testing has shown this not to be the case: `fc -p` inside a
`zshaddhistory` hook is function-scoped and `$HISTFILE` remains stable
from the user's perspective.

### Original reasoning

Working from a reading of upstream's `_per-directory-history-addhistory`:

```zsh
function _per-directory-history-addhistory() {
  if [[ -o hist_ignore_space ]] && [[ "$1" == \ * ]]; then
      true
  else
      print -Sr -- "${1%%$'\n'}"
      if [[ -o share_history ]] || \
         [[ -o inc_append_history ]] || \
         [[ -o inc_append_history_time ]]; then
          fc -AI "$HISTFILE"
          fc -AI "$_per_directory_history_directory"
      fi
      fc -p "$_per_directory_history_directory"
  fi
}
```

The reasoning was:

1. `fc -p "$_per_directory_history_directory"` pushes the per-directory file
   onto zsh's history stack and (per the manual) sets `$HISTFILE` to that
   filename.
2. After the first command, therefore, `$HISTFILE` no longer points at the
   user's original (global) history file \u2014 it points at the per-directory
   file.
3. `SHARE_HISTORY`'s prompt-time read-from-`$HISTFILE` would then read from
   the per-directory file rather than the global file, breaking
   cross-terminal global synchronisation.
4. The `$HISTFILE` variable, as observed by the user (`echo $HISTFILE`),
   would no longer match what they configured in `~/.zshrc`.

This reasoning was internally consistent but assumed `fc -p`'s effect
propagates out of hook functions. It does not. See the verified findings
above.

### "Refined hypothesis: stale-recall, not lost-writes" (also falsified)

A second hypothesis was that writes worked (because `fc -AI "$HISTFILE"`
runs *before* `fc -p`), but in-memory `$history` would go stale because
`SHARE_HISTORY`'s prompt-time merge would target the per-directory file
after `fc -p` reassigned `$HISTFILE`. Same falsification: `fc -p`'s
reassignment doesn't reach prompt time at all, so `SHARE_HISTORY`'s
merge target is the correct global file.

## Investigation plan

For each scenario, run on:

* Clean upstream `jimhester/per-directory-history`.
* This fork.

Compare the results. Update this document with verified findings and
correct any hypotheses that turn out to be wrong before drafting the PR.

### Scenarios already exercised

* `scenario_02a` (single shell, SHARE_HISTORY, default local mode, two
  directories) \u2014 confirms `$HISTFILE` stability in upstream and
  `$HISTFILE` swap in fork.
* `scenario_02b` (second shell same `HISTROOT`, with persistence checks)
  \u2014 confirms cross-shell persistence works for both.

### Scenarios still required

* In-memory filter check: in upstream, does `fc -l` after `cd /dirA`
  actually show only commands run in `/dirA`?
* Live two-shell overlap: shell A writes after shell B has rendered a
  prompt; does shell B's next prompt show shell A's write?
* Toggle behaviour with SHARE_HISTORY: does toggle observably differ
  between upstream and fork in scenarios users care about?

## Conclusions and PR rationale

*(To be written once the remaining scenarios are complete. The original
"fixes SHARE_HISTORY" framing is dead and must be replaced with a
verified rationale or the fork should be considered for retirement /
merge into upstream as a stylistic refactor only.)*
