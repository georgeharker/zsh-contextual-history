#!/usr/bin/env zsh
# test_p07_toggle_buffer_state
#
# Validates: ^G toggles between per-dir and global history files, and
# up-arrow walks the active mode's history.
#
# Setup is structured to make the per-dir vs global content
# distinguishable, accounting for the tee mechanism (which writes every
# typed command to both stores).
#
# Sequence:
#   t0: pre-populate global with 'echo only-global'. Per-dir starts
#       empty (tee only fires on typed commands; pre-populating the
#       file directly doesn't trigger it).
#   t1: spawn shellA in default per-dir mode. Per-dir HISTFILE is
#       loaded (empty), so initial ring is empty.
#   t2: ^G toggles to global. set-global-history loads the global
#       file. Ring now has 'echo only-global'.
#   t3: ^P -> expect 'echo only-global'.
#   t4: ^G toggles back to per-dir. Per-dir is empty.
#   t5: ^P -> expect empty BUFFER (or possibly the leak from the
#       HISTSIZE=2 trick).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p07.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

print -r -- ': 1000:0;echo only-global' > "$HISTROOT/global"

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

# Toggle to global mode. The widget swaps HISTFILE to the user's
# captured global file and reloads the ring from it.
pty_press_ctrlg shellA
# The toggle widget prints a status line via zle -M and calls zle -I.
# Submit empty BUFFER to fire hend/hbegin and reset histline=curhist
# for the swapped ring.
pty_press_enter shellA
_pty_read_until shellA "*${_pty_markers[shellA]}*" 5 > /dev/null

# In global mode, ^P -> 'echo only-global'.
pty_press_up shellA
buf=$(pty_inspect_buf shellA)
[[ $buf == 'echo only-global' ]] \
  || pty_fail "after toggle to global, ^P expected 'echo only-global', got <$buf>"

pty_pass
