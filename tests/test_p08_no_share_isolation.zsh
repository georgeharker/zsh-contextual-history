#!/usr/bin/env zsh
# test_p08_no_share_isolation
#
# Validates: WITHOUT SHARE_HISTORY, shells don't auto-merge each other's
# writes via SHARE's hend mechanism. shellB's write isn't visible to
# shellA's idle up-arrow. This documents the user's stated semantic:
# "without SHARE_HISTORY, no cross-shell contamination."
#
# Note: even without SHARE_HISTORY, the plugin's tee mechanism writes
# typed commands to BOTH stores. So if A and B share the same per-dir
# context (same PWD), B's tee write does land on disk in the shared
# files. The point of this test is that A's IN-MEMORY ring is not
# auto-synced.
#
# Sequence:
#   t0: shellA + shellB spawn WITHOUT SHARE_HISTORY (no INC either).
#   t1: shellB runs `echo no-share-B`.
#   t2: shellA presses ^P.
#   t3: assert BUFFER is NOT 'echo no-share-B'.
#       (Empty is the expected outcome - A's ring stays at startup state.)

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p08.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

# Default per-dir mode, NO SHARE_HISTORY, NO INC_APPEND.
pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"
pty_spawn shellB "$HISTROOT" || pty_fail "could not spawn shellB"

pty_run_cmd shellB 'echo no-share-B' || pty_fail "B run failed"
sleep 0.1

pty_press_up shellA
buf=$(pty_inspect_buf shellA)

if [[ $buf == 'echo no-share-B' ]]; then
  pty_fail "without SHARE_HISTORY, A's ring should not auto-merge B's write; got <$buf>"
fi

pty_pass
