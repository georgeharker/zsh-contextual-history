#!/usr/bin/env zsh
# test_p13_concurrent_toggle
#
# Validates: concurrent two-shell scenario where shellA toggles between
# per-dir and global modes mid-session while shellB is also active.
# Catches the s06 bug pattern: upstream's `fc -p`/`fc -P` toggle calls
# savehistfile which can rewrite the file in place, invalidating
# concurrent shellB's `lasthist.fpos` and breaking SHARE_HISTORY's
# incremental reads. The fork's direct HISTFILE-assignment toggle
# avoids this hazard.
#
# Per the plugin's tee mechanism, ALL commands typed (regardless of
# mode) are written to both stores. So shellB (staying in per-dir
# mode) should see every command that shellA typed, regardless of
# which mode shellA was in when typing it.
#
# Sequence:
#   t0: shellA + shellB spawn (SHARE, default per-dir, same PWD).
#   t1: shellA runs 'echo A-dir1' (dir mode -> per-dir + tee to global).
#   t2: shellA runs 'echo A-dir2' (still dir mode).
#   t3: shellA toggles to global (^G).
#   t4: shellA runs 'echo A-global1' (global mode -> global + tee to per-dir).
#   t5: shellB walks ^P: expect A-global1, A-dir2, A-dir1 in order.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p13.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

# Both shells now in dir mode at same PWD. shellA writes some commands.
pty_run_cmd shellA 'echo A-dir1' || pty_fail "A-dir1 failed"
pty_run_cmd shellA 'echo A-dir2' || pty_fail "A-dir2 failed"

# shellA toggles to global mode. The widget emits a status line
# ("history: global | ..."), swaps HISTFILE, and ZLE redraws the
# prompt - we drain all of that output INCLUDING the post-toggle
# marker so the next `pty_run_cmd`'s read_until isn't fooled by a
# stale marker.
pty_press_ctrlg shellA
_pty_read_until shellA "*history: global*" 5 > /dev/null
_pty_read_until shellA "*${_pty_markers[shellA]}*" 5 > /dev/null

# shellA runs another command in global mode.
pty_run_cmd shellA 'echo A-global1' || pty_fail "A-global1 failed"
sleep 0.1

# shellB (in dir mode) walks ^P. Plugin's tee made all 3 commands
# visible in shellB's per-dir history file.
EXPECTED=(
  'echo A-global1'
  'echo A-dir2'
  'echo A-dir1'
)

for ((i=1; i<=${#EXPECTED}; i++)); do
  pty_press_up shellB
  buf=$(pty_inspect_buf shellB)
  [[ $buf == "${EXPECTED[$i]}" ]] \
    || pty_fail "shellB ^P #${i}: expected '${EXPECTED[$i]}', got <$buf>"
done

pty_pass
