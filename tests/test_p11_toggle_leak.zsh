#!/usr/bin/env zsh
# test_p11_toggle_leak
#
# Validates the toggle ring-replace's leak behavior - specifically,
# that with the native module's clean replace-ring builtin loaded,
# the leak is GONE; without the module (pure-shell HISTSIZE=2 + fc
# -R), the leak is PRESENT.
#
# Why the leak exists in pure-shell: zsh's histsizesetfn clamps
# histsiz to a minimum of 2, so HISTSIZE=2 trims the ring to the 2
# most-recent entries instead of emptying it. Restoring HISTSIZE
# expands capacity but the lost entries don't come back. After fc -R
# appends the new file, the ring has [2 leftover entries from prior
# context, ..., new file events].
#
# The native module's contextual-history-replace-ring builtin walks
# hist_ring + freehistnode for every entry, leaving a clean ring
# before readhistfile loads the new file. No leak.
#
# Sequence:
#   t0: pre-populate global (G1..G5) and per-dir (D1..D5).
#   t1: spawn shellA in per-dir mode. Ring loads D1..D5.
#   t2: ^G toggle to global, sync.
#   t3: walk ^P through G5..G1 (always present).
#   t4: walk past G1: 2 more presses.
#       - With module: assert empty BUFFER (no leak).
#       - Without module: assert D5, D4 visible (leak).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p11.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

# Pre-populate global file with G1..G5.
{
  for i in 1 2 3 4 5; do
    print -r -- ": $((1000+i)):0;echo G$i"
  done
} > "$HISTROOT/global"

# Per-dir file for the test's PWD (where shellA will start). The
# resolver computes ${HISTORY_BASE}${PWD:A}/history.
PERDIR_FILE="$HISTROOT/dirhist${PWD:A}/history"
mkdir -p "${PERDIR_FILE:h}"
{
  for i in 1 2 3 4 5; do
    print -r -- ": $((2000+i)):0;echo D$i"
  done
} > "$PERDIR_FILE"

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

# NOTE: we deliberately do NOT verify per-dir loaded by ^P+inspect
# here. The inspect widget's terminal output can disrupt ZLE's
# internal cursor state, making subsequent ^U not fully clear BUFFER
# (^U is unix-line-discard = kill from cursor to start of line; if
# the cursor isn't where ZLE thinks it is, the kill is partial).
# Instead we go straight to the toggle - the global-after-toggle
# walk implicitly proves the per-dir was loaded too, because the
# leak (if present) shows D entries appearing.

# Toggle to global. Submit empty line to fire hend/hbegin which
# resets histline=curhist for the swapped ring.
pty_press_ctrlg shellA
pty_press_enter shellA
_pty_read_until shellA "*${_pty_markers[shellA]}*" 5 > /dev/null

# In global mode now, ring SHOULD have G1..G5 and (per the leak)
# 2 most-recent D entries (D4, D5) at low histnums.
# Walk ^P: should see G5, G4, ..., G1, then D5, D4 (leak).
EXPECTED=(echo\ G5 echo\ G4 echo\ G3 echo\ G2 echo\ G1)
for ((i=1; i<=5; i++)); do
  pty_press_up shellA
  buf=$(pty_inspect_buf shellA)
  [[ $buf == ${EXPECTED[$i]} ]] \
    || pty_fail "global-after-toggle ^P #${i}: expected '${EXPECTED[$i]}', got <$buf>"
done

# Now press ^P twice more. Assertion switches on whether the native
# module is in use:
#   module=true  -> ring was cleanly replaced; positions 6,7 must be
#                   empty (^P past oldest entry holds buffer empty).
#   module=false -> documented 2-entry leak; positions 6,7 must be D5,D4.
pty_press_up shellA
buf6=$(pty_inspect_buf shellA)
pty_press_up shellA
buf7=$(pty_inspect_buf shellA)

if [[ ${CONTEXTUAL_HISTORY_USE_MODULE:-false} == true ]]; then
  # Clean ring: ^P past the oldest (G1) holds at G1 — there is no
  # older entry to load, and up-line-or-history is a no-op at the top.
  [[ $buf6 == 'echo G1' && $buf7 == 'echo G1' ]] \
    || pty_fail "module mode should hold at G1 past oldest (clean ring); positions 6,7 were <$buf6>,<$buf7>"
  print -ru2 -- "OK: module clean-replace verified; positions 6,7 stuck at G1 (no D-leak)"
else
  [[ $buf6 == 'echo D5' && $buf7 == 'echo D4' ]] \
    || pty_fail "no-module mode should show 2-entry leak D5,D4; positions 6,7 were <$buf6>,<$buf7>"
  print -ru2 -- "OK: confirmed 2-entry leak D5,D4 (documented HISTSIZE=2 behavior)"
fi

pty_pass
