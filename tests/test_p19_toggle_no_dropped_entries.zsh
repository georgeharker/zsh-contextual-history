#!/usr/bin/env zsh
# test_p19_toggle_no_dropped_entries
#
# Validates: when shell A toggles between modes mid-session and writes
# in each mode, peer shell B (still in per-dir mode, same context) sees
# all of A's writes in its per-dir history -- the tee writes the
# inactive store on every command, so A's global-mode writes also land
# in the per-dir file.
#
# This is the "no entries dropped on the peer's view" guarantee: a
# shell flipping modes shouldn't make their commands invisible to a
# sibling shell that stayed in per-dir mode.
#
# Sequence:
#   t0: spawn A + B, same dir, SHARE.
#   t1: A writes 'echo a-perdir-1' (per-dir mode).
#   t2: A toggles to global.
#   t3: A writes 'echo a-global-2' (A's hend writes to global, plugin's
#       tee writes per-dir).
#   t4: A toggles back to per-dir.
#   t5: A writes 'echo a-perdir-3' (per-dir mode).
#   t6: B's ^P walk: should see a-perdir-3, a-global-2, a-perdir-1
#       in that order (latest-first; tee preserves insertion order).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p19.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"
TEST_SHARE_HISTORY=1 pty_spawn shellB "$HISTROOT" || pty_fail "spawn B"

pty_run_cmd shellA 'echo a-perdir-1' || pty_fail "A perdir-1"
sleep 1.1

# Toggle A to global. The toggle widget swaps HISTFILE in-place, no
# accept-line. We probe ZLE state via pty_inspect_buf afterwards --
# besides asserting BUFFER is empty (no stale text), the inspector's
# ^X dispatch forces ZLE to drain any pending input so the next
# pty_run_cmd doesn't race with the toggle's ring-replace.
pty_press_ctrlg shellA
sleep 0.2
buf=$(pty_inspect_buf shellA)
[[ -z $buf ]] || pty_fail "after-1st-toggle BUFFER unexpectedly <$buf>"

pty_run_cmd shellA 'echo a-global-2' || pty_fail "A global-2"
sleep 1.1

# Toggle back to per-dir, same drain-via-inspector pattern.
pty_press_ctrlg shellA
sleep 0.2
buf=$(pty_inspect_buf shellA)
[[ -z $buf ]] || pty_fail "after-2nd-toggle BUFFER unexpectedly <$buf>"

pty_run_cmd shellA 'echo a-perdir-3' || pty_fail "A perdir-3"
sleep 0.5

# B walks per-dir history. All three of A's writes should be present
# in the per-dir file (the tee guarantees this) and B's SHARE merge
# brings them in.
pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo a-perdir-3' ]] || pty_fail "B step1 expected 'echo a-perdir-3', got <$buf>"

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo a-global-2' ]] \
  || pty_fail "B step2 expected 'echo a-global-2' (tee'd into per-dir despite A being in global mode), got <$buf>"

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo a-perdir-1' ]] || pty_fail "B step3 expected 'echo a-perdir-1', got <$buf>"

pty_pass
