#!/usr/bin/env zsh
# test_p06_per_dir_isolation
#
# Validates: shells in DIFFERENT directories use DIFFERENT per-dir
# history files, so a write in B's directory is NOT visible to A in
# its own directory. The reverse of p05.
#
# Both shells write a command in their own directory so per-dir-A and
# per-dir-B each have a known, distinguishable entry. shellA's
# up-arrow MUST load A's entry (isolation honored) and MUST NOT load
# B's entry. This works the same with and without the native module's
# clean ring-replace -- the test asserts the isolation property
# directly, not via the HISTSIZE=2 leak.
#
# Sequence:
#   t0: shellA + shellB spawn (per-dir mode, SHARE_HISTORY).
#   t1: shellA cd dirA, run 'echo from-A'.
#   t2: shellB cd dirB, run 'echo from-B'.
#   t3: shellA presses ^P.
#   t4: assert BUFFER == 'echo from-A' AND != 'echo from-B'.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p06.XXXXXX)
DIRA=$(mktemp -d -t ch-pty-p06A.XXXXXX)
DIRB=$(mktemp -d -t ch-pty-p06B.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$DIRA" "$DIRB"' EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

# A in dirA, B in dirB. Each shell runs a uniquely identifiable cmd
# so per-dir A and B have distinct content.
pty_run_cmd shellA "cd $DIRA"     || pty_fail "A cd failed"
pty_run_cmd shellA 'echo from-A'  || pty_fail "A run failed"
pty_run_cmd shellB "cd $DIRB"     || pty_fail "B cd failed"
pty_run_cmd shellB 'echo from-B'  || pty_fail "B run failed"
sleep 0.1

# A's up-arrow loads from A's per-dir, NOT B's.
pty_press_up shellA
buf=$(pty_inspect_buf shellA)

if [[ $buf == 'echo from-B' ]]; then
  pty_fail "isolation violated: shellA in $DIRA saw shellB's write 'echo from-B'"
fi

[[ $buf == 'echo from-A' ]] \
  || pty_fail "expected 'echo from-A' (A's own per-dir entry); got <$buf>"

pty_pass
