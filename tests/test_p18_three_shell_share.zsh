#!/usr/bin/env zsh
# test_p18_three_shell_share
#
# Three-shell SHARE_HISTORY scenario in the same context. Validates:
#   1. Late-joining shell C sees writes from A and B that happened
#      BEFORE C spawned (loaded from per-dir file at spawn time).
#   2. Cross-shell merge ordering: writes from A and B interleaved
#      appear in correct chronological order on every shell's ^P walk.
#
# This is the "I open a third terminal to check what happened" case
# that 2-shell tests can't cover.
#
# Sequence:
#   t0: spawn shellA + shellB in same dir, both SHARE_HISTORY.
#   t1: A writes 'echo a1', B writes 'echo b1', A writes 'echo a2'.
#   t2: spawn shellC (in same dir, same SHARE_HISTORY).
#   t3: C's ^P walk should yield a2, b1, a1 (newest first).
#   t4: A's ^P walk should also see all three.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p18.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" || pty_fail "spawn B"

# Interleaved writes from A and B. The sleeps give SHARE's incremental
# writer enough time to land each entry on disk before the next one;
# without them the kernel's O_APPEND atomicity holds but timestamps
# can collide at second-resolution.
pty_run_cmd shellA 'echo a1' || pty_fail "A a1"
sleep 1.1
pty_run_cmd shellB 'echo b1' || pty_fail "B b1"
sleep 1.1
pty_run_cmd shellA 'echo a2' || pty_fail "A a2"
sleep 0.2

# Late-join: C joins AFTER A and B have written. C should load the
# per-dir file at spawn and see all three on first ^P walk.
TEST_SHARE_HISTORY=1 pty_spawn shellC "$HISTROOT" || pty_fail "spawn C"

# C's ^P: a2 (most recent), b1, a1.
pty_press_up shellC
buf=$(pty_inspect_buf shellC)
[[ $buf == 'echo a2' ]] || pty_fail "C step1 expected 'echo a2', got <$buf>"

pty_press_up shellC
buf=$(pty_inspect_buf shellC)
[[ $buf == 'echo b1' ]] || pty_fail "C step2 expected 'echo b1', got <$buf>"

pty_press_up shellC
buf=$(pty_inspect_buf shellC)
[[ $buf == 'echo a1' ]] || pty_fail "C step3 expected 'echo a1', got <$buf>"

# A also walks. SHARE merge picks up b1 between a1 and a2.
pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo a2' ]] || pty_fail "A step1 expected 'echo a2', got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo b1' ]] || pty_fail "A step2 expected 'echo b1' (B's interleaved write), got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo a1' ]] || pty_fail "A step3 expected 'echo a1', got <$buf>"

pty_pass
