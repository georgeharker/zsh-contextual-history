#!/usr/bin/env zsh
# test_s06_diag_no_toggle: same as test_s06 but with toggle replaced by
# a no-op command. If shell 2 still fails, the issue is the no-op
# command's mere presence; if shell 2 succeeds, it confirms the toggle
# itself triggers the regression.

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
unset S1_DIR S2_DIR

# Replace toggle with a plain `:` no-op.
export S1_CMDS='echo cmd-1
echo cmd-2
echo cmd-3
:
echo cmd-4
echo cmd-5
echo cmd-6'

zsh "$SCRIPT_DIR/lib/multi_shell.zsh" "$FORK_PLUGIN" "$RESULTS_DIR/fork"

print -- "=== fork shell 2 history with toggle REPLACED by : noop ==="
cat "$RESULTS_DIR/fork/shell2_history.out"
