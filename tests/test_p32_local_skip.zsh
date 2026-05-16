#!/usr/bin/env zsh
# test_p32_local_skip
#
# Validates the local-history navigation filter: with the mode bit on,
# pressing up-arrow skips ring entries that aren't in
# _context_history_local_texts (i.e. weren't typed by this shell).
# With the bit off, up-arrow walks every entry as today.
#
# Strategy:
#   1. Pre-seed disk histfile with a unique peer-style entry.
#   2. Spawn shellA - startup load brings it into the ring as L-less.
#   3. Verify the peer entry is in the ring but NOT in
#      _context_history_local_texts.
#   4. Toggle local-history ON. Press up. Assert BUFFER does NOT land on
#      the peer entry (must skip it).
#   5. Toggle local-history OFF. Press up again from a fresh prompt.
#      Assert BUFFER DOES find the peer entry (walks everything).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p32.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "spawn"

pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not query HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
mkdir -p "${histfile:h}"

# Inject a peer-style entry directly to disk and reload the ring.
inject_stim=$(($(date +%s) - 100))
print -r -- ": ${inject_stim}:0;cmd-PEER-XYZ-MARKER" >> "$histfile"
pty_run_cmd shellA "fc -R \$HISTFILE" \
  || pty_fail "fc -R reload"

# Sanity: ring has the peer entry, _local_texts doesn't.
pty_run_cmd shellA "fc -l 1 | grep PEER-XYZ > $HISTROOT/peer-grep"
[[ -s "$HISTROOT/peer-grep" ]] \
  || pty_fail "peer entry not loaded into ring"

pty_run_cmd shellA 'print -r -- "PEER_IN=$((${+_context_history_local_texts[cmd-PEER-XYZ-MARKER]}))"' \
  || pty_fail "could not query local_texts"
[[ $REPLY == *PEER_IN=0* ]] \
  || pty_fail "peer entry unexpectedly in _local_texts; got <$REPLY>"

# EXACT-match comparator: the peer entry's full text is precisely the
# string below. Substring matching is misleading here because our
# test-infrastructure commands (pty_run_cmd queries) often mention
# the marker by name in their arguments.
PEER='cmd-PEER-XYZ-MARKER'

# Press up with local-history OFF (default). Walk back through history
# until BUFFER is exactly the peer entry. We need many presses
# because pty_run_cmd commands populate the head of the ring.
typeset -i tries
local found_with_local_off=0
for ((tries=1; tries<=30; tries++)); do
  pty_press_up shellA
  buf=$(pty_inspect_buf shellA)
  if [[ $buf == $PEER ]]; then
    found_with_local_off=1
    break
  fi
done
(( found_with_local_off )) \
  || pty_fail "local-history OFF: couldn't reach peer entry after $tries up-presses (final buf=<$buf>)"

# Reset to fresh prompt.
pty_press_ctrlc shellA
sleep 0.1
pty_run_cmd shellA ':' || pty_fail "noop to clear state"

# Toggle local-history ON.
pty_run_cmd shellA '_context_history_local_mode=1' \
  || pty_fail "could not enable local-history"

# Press up many times. With local-history ON, BUFFER should NEVER become
# the peer entry exactly - skip-loop skips it on every approach.
local landed_on_peer_with_local_on=0
for ((tries=1; tries<=50; tries++)); do
  pty_press_up shellA
  buf=$(pty_inspect_buf shellA)
  if [[ $buf == $PEER ]]; then
    landed_on_peer_with_local_on=1
    break
  fi
done

if (( landed_on_peer_with_local_on )); then
  pty_fail "local-history ON but up-arrow landed on peer entry (after $tries presses, buf=<$buf>)"
fi

pty_pass
