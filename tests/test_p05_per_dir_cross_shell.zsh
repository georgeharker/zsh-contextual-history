#!/usr/bin/env zsh
# test_p05_per_dir_cross_shell
#
# Validates: with the plugin's default per-directory mode, two shells
# in the same directory share their per-dir history. Cross-shell writes
# from B are visible to A's up-arrow.
#
# Sequence:
#   t0: shellA + shellB spawn in default mode (per-directory). Both
#       shells inherit the same CWD (test runner's), so both resolve
#       the same per-dir HISTFILE.
#   t1: shellB runs `echo p05-cross`. hend appends to per-dir.
#   t2: shellA presses ^P -> assert BUFFER == 'echo p05-cross'.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p05.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

# Default mode (TEST_START_GLOBAL not set) -> per-directory.
TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

pty_run_cmd shellB 'echo p05-cross' || pty_fail "B run failed"
sleep 0.1

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo p05-cross' ]] \
  || pty_fail "shellA up-arrow expected 'echo p05-cross', got <$buf>"

pty_pass
