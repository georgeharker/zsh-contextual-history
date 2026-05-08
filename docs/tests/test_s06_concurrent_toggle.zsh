#!/usr/bin/env zsh
# test_s06_concurrent_toggle: concurrent two-shell same-directory scenario
# with SHARE_HISTORY enabled, where shell 1 toggles to global mode mid-run.
#
# Question: when shell 1 runs commands, toggles to global, and runs more
# commands, what does shell 2 (still in local mode) see in its
# directory-A history view?
#
# Shell 1 sequence:
#   echo cmd-1, cmd-2, cmd-3 (local mode, in /tmp/pdh-mst-dirA)
#   per-directory-history-toggle-history (now global mode)
#   echo cmd-4, cmd-5, cmd-6 (global mode)
#
# Expected behaviour depends on plugin semantics. The test surfaces the
# difference between upstream and fork.
#
# Usage:   zsh test_s06_concurrent_toggle.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
unset S1_DIR S2_DIR  # both default to same /tmp/pdh-mst-dirA

# Override shell 1's command list to include a toggle in the middle.
export S1_CMDS='echo cmd-1
echo cmd-2
echo cmd-3
per-directory-history-toggle-history
echo cmd-4
echo cmd-5
echo cmd-6'

run_one() {
  local label=$1 plugin=$2
  print -- "=== $TEST_NAME / $label ==="
  zsh "$SCRIPT_DIR/lib/multi_shell.zsh" "$plugin" "$RESULTS_DIR/$label"
}

run_one upstream "$UPSTREAM_PLUGIN"
run_one fork     "$FORK_PLUGIN"

print
print -- "=== Comparison: shell 2's history output ==="
for label in upstream fork; do
  print -- "--- $label ---"
  if [[ -f "$RESULTS_DIR/$label/shell2_history.out" ]]; then
    cat "$RESULTS_DIR/$label/shell2_history.out"
  else
    print -- "(missing)"
  fi
  print
done
