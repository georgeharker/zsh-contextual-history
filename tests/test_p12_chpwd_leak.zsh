#!/usr/bin/env zsh
# test_p12_chpwd_leak
#
# Validates AND documents the 2-entry leak when chpwd fires
# `set-directory-history` (same `HISTSIZE=2; fc -R` mechanism as
# p11's toggle leak).
#
# Important sequencing detail observed in this scenario:
#   hend (which adds the typed command to history) fires BEFORE
#   execlist runs the command, so a `cd dirB` command typed in
#   dirA gets written to dirA's per-dir file, not dirB's. Only
#   AFTER cd executes does chpwd swap HISTFILE to per-dir B.
#   Therefore the cd-to-B command survives as part of the in-memory
#   ring during chpwd's HISTSIZE=2 trim and shows up as one of the
#   2 leaked entries when navigating in dirB.
#
# Sequence:
#   t0: pre-populate per-dir files for dirA (A1..A5) and dirB (B1..B5).
#   t1: spawn shellA in default per-dir mode.
#   t2: shellA `cd dirA`. chpwd loads per-dir A.
#   t3: shellA `cd dirB`. The cd-to-B command was written to per-dir
#       A by hend, then chpwd swapped to per-dir B with HISTSIZE=2
#       trim leaving 2 entries (A5 and cd-to-B), then fc -R loaded
#       B1..B5 on top.
#   t4: walk ^P:
#        #1: echo B5     (top of per-dir B)
#        #2: echo B4
#        #3: echo B3
#        #4: echo B2
#        #5: echo B1
#        #6: cd dirB     (LEAK - the cd command itself)
#        #7: echo A5     (LEAK - oldest survivor of HISTSIZE=2 trim)

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p12.XXXXXX)
DIRA=$(mktemp -d -t ch-pty-p12-dirA.XXXXXX)
DIRB=$(mktemp -d -t ch-pty-p12-dirB.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT $DIRA $DIRB" EXIT

DIRA_REAL=${DIRA:A}
DIRB_REAL=${DIRB:A}

PERDIR_A="$HISTROOT/dirhist${DIRA_REAL}/history"
PERDIR_B="$HISTROOT/dirhist${DIRB_REAL}/history"
mkdir -p "${PERDIR_A:h}" "${PERDIR_B:h}"
{ for i in 1 2 3 4 5; do print -r -- ": $((1000+i)):0;echo A$i"; done } > "$PERDIR_A"
{ for i in 1 2 3 4 5; do print -r -- ": $((2000+i)):0;echo B$i"; done } > "$PERDIR_B"

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

pty_run_cmd shellA "cd $DIRA" || pty_fail "cd to dirA failed"
pty_run_cmd shellA "cd $DIRB" || pty_fail "cd to dirB failed"

# Walk through B's per-dir entries in reverse order.
EXPECTED=(
  'echo B5'
  'echo B4'
  'echo B3'
  'echo B2'
  'echo B1'
)

for ((i=1; i<=${#EXPECTED}; i++)); do
  pty_press_up shellA
  buf=$(pty_inspect_buf shellA)
  [[ $buf == ${EXPECTED[$i]} ]] \
    || pty_fail "step ${i}: expected '${EXPECTED[$i]}', got <$buf>"
done

# Now positions 6 and 7. Assertion switches on whether the native
# module is in use:
#   module=true  -> chpwd's swap used the clean-replace builtin; ring
#                   has only B1..B5; positions 6,7 must be empty.
#   module=false -> HISTSIZE=2 trim leaks 2 entries: 'cd $DIRB' (the
#                   most-recent in-memory event before chpwd) and
#                   'echo A5' (one prior survivor of the trim).
pty_press_up shellA
leak1=$(pty_inspect_buf shellA)
pty_press_up shellA
leak2=$(pty_inspect_buf shellA)

if [[ ${CONTEXTUAL_HISTORY_USE_MODULE:-false} == true ]]; then
  # Clean ring: ^P past the oldest (B1) holds at B1 — there is no
  # older entry to load, and up-line-or-history is a no-op at the top.
  [[ $leak1 == 'echo B1' && $leak2 == 'echo B1' ]] \
    || pty_fail "module mode should hold at B1 past oldest (clean ring); positions 6,7 were <$leak1>,<$leak2>"
  print -ru2 -- "OK: module clean-replace verified; positions 6,7 stuck at B1 (no leak)"
else
  [[ $leak1 == "cd $DIRB" && $leak2 == 'echo A5' ]] \
    || pty_fail "no-module mode should show 2-entry leak ('cd $DIRB','echo A5'); positions 6,7 were <$leak1>,<$leak2>"
  print -ru2 -- "OK: confirmed 2-entry leak ('cd $DIRB','echo A5') at positions 6-7"
fi

pty_pass
