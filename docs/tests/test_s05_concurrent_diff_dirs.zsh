#!/usr/bin/env zsh
# test_s05_concurrent_diff_dirs: concurrent two-shell scenario with each
# shell in a different directory, SHARE_HISTORY enabled.
#
# Question: when shell 1 writes commands in /tmp/pdh-mst-dirA and shell 2
# runs `history` in /tmp/pdh-mst-dirB (with SHARE_HISTORY on for both),
# does shell 2 see shell 1's commands?
#
# Expectation: per-directory isolation should hold. Neither plugin
# should leak shell 1's directory-A commands into shell 2's
# directory-B history view.
#
# Usage:   zsh test_s05_concurrent_diff_dirs.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
export S1_DIR=/tmp/pdh-mst-dirA
export S2_DIR=/tmp/pdh-mst-dirB

run_one() {
  local label=$1 plugin=$2
  print -- "=== $TEST_NAME / $label ==="
  zsh "$SCRIPT_DIR/lib/multi_shell.zsh" "$plugin" "$RESULTS_DIR/$label"
}

run_one upstream "$UPSTREAM_PLUGIN"
run_one fork     "$FORK_PLUGIN"

print
print -- "=== Comparison: shell 2's history output (should NOT contain shell 1's cmd-N) ==="
for label in upstream fork; do
  print -- "--- $label ---"
  if [[ -f "$RESULTS_DIR/$label/shell2_history.out" ]]; then
    cat "$RESULTS_DIR/$label/shell2_history.out"
  else
    print -- "(missing: $RESULTS_DIR/$label/shell2_history.out)"
  fi
  print
done
