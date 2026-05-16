#!/usr/bin/env zsh
# test_p02_first_prompt_up_arrow
#
# Validates: a freshly-spawned shell's FIRST up-arrow loads the last
# saved entry from disk into BUFFER. This is the case the user originally
# reported as broken (the off-by-one from set-directory-history's
# HISTSIZE=0 trick); with the pre-init HISTFILE swap, the ring is
# loaded cleanly and up-arrow works on the first prompt.
#
# Sequence:
#   t0: pre-populate HISTFILE (= the global file, since we use
#       HISTORY_START_WITH_GLOBAL=true) with two known entries.
#   t1: spawn shellA.
#   t2: press ^P -> assert BUFFER == last entry.
#   t3: press ^P again -> assert BUFFER == first entry.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p02.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

# Pre-populate global file. Use TEST_START_GLOBAL=1 so the spawned
# shell's HISTFILE stays at the global path (no pre-init swap to per-dir).
print -r -- ': 1000:0;echo entry-1' > "$HISTROOT/global"
print -r -- ': 1001:0;echo entry-2' >> "$HISTROOT/global"

TEST_SHARE_HISTORY=1 TEST_START_GLOBAL=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-2' ]] \
  || pty_fail "first ^P expected 'echo entry-2', got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-1' ]] \
  || pty_fail "second ^P expected 'echo entry-1', got <$buf>"

pty_pass
