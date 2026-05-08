# Sequential cross-shell scenario, second half: a fresh shell starts in
# the same directory shell 1 used and dumps its in-memory history to a
# file. The driver passes PDH_HIST_OUT as the absolute target path.
#
# Run via docs/tests/harness.sh with TEST_HISTROOT shared with the
# first-half script.

cd /tmp/pdh-mst-dirA

history > "$PDH_HIST_OUT"

exit
