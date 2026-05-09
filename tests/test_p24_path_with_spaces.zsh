#!/usr/bin/env zsh
# test_p24_path_with_spaces
#
# Validates: per-dir history works correctly when $PWD contains spaces
# (and other shell-significant characters). The default resolver uses
# ${PWD:A} which is a literal path; the plugin must quote consistently
# at every assignment site for tee, mkdir, lockhistfile, fc -R and
# friends.
#
# Sequence:
#   t0: mktemp dir whose path contains a space and a single quote.
#   t1: spawn shellA, cd into the awkward dir.
#   t2: write 'echo from-spaces'.
#   t3: assert the per-dir file was created at the expected path with
#       all special characters preserved.
#   t4: spawn shellB into the same awkward dir; ^P should see A's
#       write (cross-shell SHARE merge across an awkward path).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p24.XXXXXX)
# Build an awkward dir name. We avoid backticks, $, glob chars, and
# newlines to keep the test debuggable; spaces and a single quote are
# enough to surface unquoted-expansion bugs.
AWKWARD="$HISTROOT/has space and ' quote"
mkdir -p "$AWKWARD" || pty_fail "mkdir awkward dir"
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"

# cd into the awkward dir. We have to quote the path inside the
# command we send into the pty.
pty_run_cmd shellA "cd \"$AWKWARD\"" || pty_fail "A cd awkward"
sleep 0.2

pty_run_cmd shellA 'echo from-spaces' || pty_fail "A from-spaces"
sleep 0.5

# Per-dir file path: $HISTORY_BASE${PWD:A}/history.
AWKWARD_REAL=${AWKWARD:A}
EXPECTED_FILE="$HISTROOT/dirhist${AWKWARD_REAL}/history"
[[ -f $EXPECTED_FILE ]] \
  || pty_fail "per-dir file missing at <$EXPECTED_FILE>; HISTROOT contents: $(find "$HISTROOT" -type f)"
fgrep -q 'echo from-spaces' "$EXPECTED_FILE" \
  || pty_fail "per-dir file missing 'echo from-spaces': $(cat "$EXPECTED_FILE")"

# Cross-shell verification. B in the same awkward dir should see A's
# write via SHARE merge.
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" || pty_fail "spawn B"
pty_run_cmd shellB "cd \"$AWKWARD\"" || pty_fail "B cd awkward"
sleep 0.3

# B's own `cd "$AWKWARD"` was hended in B's spawn-dir per-dir (the
# documented chpwd-timing leak: hend fires BEFORE chpwd swaps), NOT
# in the awkward dir. So B's first ^P inside the awkward dir hits
# A's `echo from-spaces` directly.
pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo from-spaces' ]] \
  || pty_fail "B step1 expected 'echo from-spaces' (A's write across awkward path), got <$buf>"

pty_pass
