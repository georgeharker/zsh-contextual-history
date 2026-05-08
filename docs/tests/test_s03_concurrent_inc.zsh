#!/usr/bin/env zsh
# test_s03_concurrent_inc: concurrent two-shell same-directory scenario
# with INC_APPEND_HISTORY only (no SHARE_HISTORY).
#
# This is a control: INC_APPEND_HISTORY's contract is crash-safe writes,
# not live cross-shell read sync. We expect NEITHER plugin to surface
# shell 1's commands in shell 2's `history`. The corresponding sequential
# test (test_s03b_sequential_inc.zsh) checks that INC_APPEND's actual
# contract \u2014 persistence into a later shell \u2014 holds.
#
# Usage:   zsh test_s03_concurrent_inc.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_SHARE_HISTORY TEST_EXTENDED TEST_START_GLOBAL
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
