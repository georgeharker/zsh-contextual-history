#!/usr/bin/env zsh
# test_s01_concurrent_share: concurrent two-shell same-directory scenario
# with SHARE_HISTORY enabled.
#
# Question: when shell 1 writes 6 commands in /tmp/pdh-mst-dirA, does
# shell 2 (also in /tmp/pdh-mst-dirA, also with SHARE_HISTORY on) see
# them in its `history` output?
#
# Runs the scenario against a clean upstream and against this fork.
# Outputs land in docs/tests/results/test_s01_concurrent_share/{upstream,fork}/.
#
# Usage:   zsh test_s01_concurrent_share.zsh
# Layout:  results/<test_name>/<plugin_label>/{shell1.log,shell2.log,
#          driver.log,shell2_history.out,files_after.log,meta.log}

set -e

# Resolve repo paths from this script's location.
SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}                # test_s01_concurrent_share
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

# Single-source the option matrix: SHARE_HISTORY only.
export TEST_SHARE_HISTORY=1
unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL

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
