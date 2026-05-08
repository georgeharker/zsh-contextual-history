#!/usr/bin/env zsh
# test_p04_multi_event_cross_shell
#
# Validates: multiple cross-shell writes are visible in order. Catches
# subtle ring-state bugs where one event syncs but a sequence drifts
# (e.g. histnum collisions between cross-shell writes).
#
# Sequence:
#   t0: shellA + shellB spawn (SHARE, shared HISTFILE).
#   t1: shellB writes B1, B2, B3 (each via run_cmd, each fires hend).
#   t2: shellA: ^P -> B3, ^P -> B2, ^P -> B1.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p04.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 TEST_START_GLOBAL=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 TEST_START_GLOBAL=1 pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

pty_run_cmd shellB 'echo B1' || pty_fail "B1 run failed"
pty_run_cmd shellB 'echo B2' || pty_fail "B2 run failed"
pty_run_cmd shellB 'echo B3' || pty_fail "B3 run failed"
sleep 0.1

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo B3' ]] || pty_fail "step1 ^P expected B3, got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo B2' ]] || pty_fail "step2 ^P expected B2, got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo B1' ]] || pty_fail "step3 ^P expected B1, got <$buf>"

pty_pass
