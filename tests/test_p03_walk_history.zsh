#!/usr/bin/env zsh
# test_p03_walk_history
#
# Validates: navigating UP and DOWN through history with ^P / ^N stays
# consistent. Catches: navigation-state confusion (e.g. histline not
# moving correctly, off-by-one bugs that break only on second press,
# zle_setline failing silently).
#
# Sequence:
#   t0: pre-populate HISTFILE with three entries.
#   t1: spawn shellA.
#   t2: ^P -> entry-3 (last).
#   t3: ^P -> entry-2.
#   t4: ^P -> entry-1.
#   t5: ^N -> entry-2.
#   t6: ^N -> entry-3.
#   t7: ^N -> empty (return to "current" / pre-history position).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p03.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

print -r -- ': 1000:0;echo entry-1' > "$HISTROOT/global"
print -r -- ': 1001:0;echo entry-2' >> "$HISTROOT/global"
print -r -- ': 1002:0;echo entry-3' >> "$HISTROOT/global"

TEST_SHARE_HISTORY=1 TEST_START_GLOBAL=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

# Walk back up
pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-3' ]] || pty_fail "step1 ^P expected entry-3, got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-2' ]] || pty_fail "step2 ^P expected entry-2, got <$buf>"

pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-1' ]] || pty_fail "step3 ^P expected entry-1, got <$buf>"

# Walk forward back down
pty_press_down shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-2' ]] || pty_fail "step4 ^N expected entry-2, got <$buf>"

pty_press_down shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo entry-3' ]] || pty_fail "step5 ^N expected entry-3, got <$buf>"

# One more ^N - returns to "current" (the in-progress edit), which is
# typically empty for a fresh prompt where we haven't typed anything.
pty_press_down shellA
buf=$(pty_inspect_buf shellA)
[[ -z $buf ]] || pty_fail "step6 ^N at end expected empty (return to current), got <$buf>"

pty_pass
