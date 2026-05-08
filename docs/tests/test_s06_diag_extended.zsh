#!/usr/bin/env zsh
# test_s06_diag_extended: same as test_s06 but with EXTENDED_HISTORY set
# in the harness so EVERY entry — including ones written by fc -AI and by
# the fork's manual tee (printf >> file) — is timestamped.
#
# Hypothesis: in the default s06 (no EXTENDED_HISTORY), SHARE_HISTORY's
# incremental writes are timestamped (because savehistfile forces
# extended_history when HFILE_USE_OPTIONS && SHAREHISTORY) but fc -AI and
# tee writes are NOT (because they don't pass HFILE_USE_OPTIONS, and
# EXTENDED_HISTORY isn't set as an option). The mixed format may be what
# breaks shell 2's prompt-time merge in the toggle scenario.
#
# If shell 2 starts seeing the cmd-N entries with EXTENDED_HISTORY on,
# the format mismatch is at least part of the cause.

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1
export TEST_EXTENDED=1
unset S1_DIR S2_DIR

export S1_CMDS='echo cmd-1
echo cmd-2
echo cmd-3
per-directory-history-toggle-history
echo cmd-4
echo cmd-5
echo cmd-6'

zsh "$SCRIPT_DIR/lib/multi_shell.zsh" "$FORK_PLUGIN" "$RESULTS_DIR/fork"

print
print -- "=== fork shell 2 history with EXTENDED_HISTORY=1 ==="
cat "$RESULTS_DIR/fork/shell2_history.out"
