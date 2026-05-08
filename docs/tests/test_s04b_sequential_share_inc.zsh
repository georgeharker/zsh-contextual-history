#!/usr/bin/env zsh
# test_s04b_sequential_share_inc: sequential two-shell same-directory
# scenario with both SHARE_HISTORY and INC_APPEND_HISTORY enabled.
#
# Like test_s03b but with SHARE_HISTORY also set. Validates persistence
# when both options are on.
#
# Usage:   zsh test_s04b_sequential_share_inc.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
export TEST_INC_APPEND=1

mkdir -p /tmp/pdh-mst-dirA

run_one() {
  local label=$1 plugin=$2
  local outroot="$RESULTS_DIR/$label"
  local histroot="$outroot/histroot"
  mkdir -p "$histroot"

  print -- "=== $TEST_NAME / $label / pass1 ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" \
    "$outroot/pass1" \
    "$SCRIPT_DIR/inputs/seq_first_shell.zsh"

  print -- "=== $TEST_NAME / $label / pass2 ==="
  TEST_HISTROOT="$histroot" \
  PDH_HIST_OUT="$outroot/pass2/shell_history.out" \
    zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
      "$plugin" \
      "$outroot/pass2" \
      "$SCRIPT_DIR/inputs/seq_second_shell.zsh"
}

run_one upstream "$UPSTREAM_PLUGIN"
run_one fork     "$FORK_PLUGIN"

print
print -- "=== Comparison: shell 2's history output ==="
for label in upstream fork; do
  print -- "--- $label ---"
  if [[ -f "$RESULTS_DIR/$label/pass2/shell_history.out" ]]; then
    cat "$RESULTS_DIR/$label/pass2/shell_history.out"
  else
    print -- "(missing: $RESULTS_DIR/$label/pass2/shell_history.out)"
  fi
  print
done
