#!/usr/bin/env zsh
# test_s06_diag_fc_AI: same as s06 but replace toggle with just `fc -AI
# "$HISTFILE"` to isolate whether the fc -AI call itself is what breaks
# shell 2's SHARE_HISTORY view.

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
unset S1_DIR S2_DIR

export S1_CMDS='echo cmd-1
echo cmd-2
echo cmd-3
fc -AI "$HISTFILE"
echo cmd-4
echo cmd-5
echo cmd-6'

zsh "$SCRIPT_DIR/lib/multi_shell.zsh" "$FORK_PLUGIN" "$RESULTS_DIR/fork"
print -- "=== fork shell 2 history with just fc -AI mid-stream ==="
cat "$RESULTS_DIR/fork/shell2_history.out"
