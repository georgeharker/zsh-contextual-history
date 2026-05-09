#!/usr/bin/env zsh
# test_p20_chpwd_concurrent_peer
#
# Validates: when shell A `cd`s away from a directory while shell B
# remains in that directory and reads via SHARE_HISTORY, B's view of
# dirA's per-dir history stays correct -- A's outgoing chpwd does
# NOT trip the rewrite-block hazard against B's concurrent reader.
#
# This is the cross-shell version of the rewrite-block hazard
# documented in MOTIVATION/README. The fork's design (no `fc -AI` in
# the swap path for SHARE/INC; direct $HISTFILE= reassignment) is
# specifically what makes this safe; if the swap regressed to using
# `fc -AI`, B's merge would break.
#
# Sequence:
#   t0: dirA + dirB; spawn A and B both in dirA, SHARE.
#   t1: A writes 'echo dirA-A-pre'.
#   t2: B verifies it sees 'echo dirA-A-pre' via ^P.
#   t3: A `cd dirB` (chpwd swap fires; B keeps reading dirA's per-dir).
#   t4: A writes 'echo dirB-A-post' in dirB.
#   t5: B writes 'echo dirA-B-post' in dirA.
#   t6: B's ^P walk: dirA-B-post (B's own, top of stack), then back
#       through cd-dirB (leaked on no-module path) and dirA-A-pre.
#       Crucially MUST NOT see dirB-A-post (different per-dir file).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p20.XXXXXX)
DIRA=$(mktemp -d -t ch-pty-p20-A.XXXXXX)
DIRB=$(mktemp -d -t ch-pty-p20-B.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT $DIRA $DIRB" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" || pty_fail "spawn B"

pty_run_cmd shellA "cd $DIRA" || pty_fail "A cd dirA"
pty_run_cmd shellB "cd $DIRA" || pty_fail "B cd dirA"
sleep 0.3

# A writes in dirA. B should see it via SHARE merge.
pty_run_cmd shellA 'echo dirA-A-pre' || pty_fail "A pre"
sleep 1.1

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo dirA-A-pre' ]] \
  || pty_fail "B (in dirA) before A's cd: expected 'echo dirA-A-pre', got <$buf>"
pty_press_ctrlu shellB   # clear BUFFER, leave histline alone

# A leaves dirA. B stays in dirA; B's $HISTFILE doesn't change.
pty_run_cmd shellA "cd $DIRB" || pty_fail "A cd dirB"
sleep 0.3

# A writes in dirB. B's per-dir is dirA -- B must NOT see this entry.
pty_run_cmd shellA 'echo dirB-A-post' || pty_fail "A post-dirB"
sleep 1.1

# B writes in dirA.
pty_run_cmd shellB 'echo dirA-B-post' || pty_fail "B post-dirA"
sleep 0.3

# B's ^P walk: 'echo dirA-B-post' (most recent, B's own).
pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo dirA-B-post' ]] \
  || pty_fail "B step1 expected 'echo dirA-B-post', got <$buf>"

# Walk further. We want to ensure 'echo dirB-A-post' is NEVER seen
# in B's history (it lives in dirB's per-dir, not dirA's). Walk up to
# 8 more presses; if dirB-A-post appears anywhere, fail.
for ((i=2; i<=8; i++)); do
  pty_press_up shellB
  buf=$(pty_inspect_buf shellB)
  [[ $buf == 'echo dirB-A-post' ]] \
    && pty_fail "B step$i unexpectedly saw 'echo dirB-A-post' (cross-context leak across chpwd)"
done

pty_pass
