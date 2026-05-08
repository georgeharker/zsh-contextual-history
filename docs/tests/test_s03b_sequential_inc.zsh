#!/usr/bin/env zsh
# test_s03b_sequential_inc: sequential two-shell same-directory scenario
# with INC_APPEND_HISTORY only.
#
# Question: when shell 1 writes 6 commands in /tmp/pdh-mst-dirA and
# exits, does a fresh shell 2 starting later in the same directory see
# them in its `history` output? This is the scenario INC_APPEND_HISTORY
# is actually designed for: persistence to disk that survives shell
# termination.
#
# Usage:   zsh test_s03b_sequential_inc.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_SHARE_HISTORY TEST_EXTENDED TEST_START_GLOBAL
export TEST_INC_APPEND=1

mkdir -p /tmp/pdh-mst-dirA

run_one() {
  local label=$1 plugin=$2
  local outroot="$RESULTS_DIR/$label"
  local histroot="$outroot/histroot"
  mkdir -p "$histroot"

  print -- "=== $TEST_NAME / $label / pass1 (shell 1 writes commands) ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" \
    "$outroot/pass1" \
    "$SCRIPT_DIR/inputs/seq_first_shell.zsh"

  print -- "=== $TEST_NAME / $label / pass2 (shell 2 reads history) ==="
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
