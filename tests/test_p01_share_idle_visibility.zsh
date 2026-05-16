#!/usr/bin/env zsh
# test_p01_share_idle_visibility
#
# Validates: with SHARE_HISTORY on, shell A idle at a prompt sees an
# event written by shell B (in another terminal) when pressing up-arrow.
# This is the empirical test the user described.
#
# Sequence:
#   t0: shellA + shellB spawn (both SHARE_HISTORY, same HISTFILE).
#   t1: shellB runs `echo from-B` (its hend appends to file).
#   t2: shellA presses up-arrow.
#   t3: assert shellA's BUFFER == 'echo from-B'.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p01.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

# t1: shellB writes a new event. With SHARE_HISTORY, hend appends to
# the shared HISTFILE before the next prompt.
pty_run_cmd shellB 'echo from-B' \
  || pty_fail "shellB run_cmd failed"

# Tiny pause for filesystem flush. zsh's hend already locked, wrote,
# unlocked synchronously, but a few ms lets any async barrier settle.
sleep 0.1

# t2: shellA presses up-arrow.
pty_press_up shellA
buf=$(pty_inspect_buf shellA)

if [[ $buf == 'echo from-B' ]]; then
  pty_pass
else
  pty_fail "shellA up-arrow expected 'echo from-B' (cross-shell write); got <$buf>"
fi
