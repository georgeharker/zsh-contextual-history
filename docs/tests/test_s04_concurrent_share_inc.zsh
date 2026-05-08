#!/usr/bin/env zsh
# test_s04_concurrent_share_inc: concurrent two-shell same-directory
# scenario with both SHARE_HISTORY and INC_APPEND_HISTORY enabled.
#
# Tests that the SHARE_HISTORY-driven cross-shell visibility behaviour
# we observed in test_s01 still holds when INC_APPEND_HISTORY is
# additionally enabled.
#
# Usage:   zsh test_s04_concurrent_share_inc.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
export TEST_INC_APPEND=1

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
    print -- "(missing: $RESULTS_DIR/$label/shell2_history.out)"
  fi
  print
done
