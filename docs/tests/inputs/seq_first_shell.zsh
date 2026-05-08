# Sequential cross-shell scenario, first half: shell 1 cd's into the
# shared test directory, runs six commands, and exits cleanly.
#
# This script is run via docs/tests/harness.sh with TEST_HISTROOT shared
# with the second-half script so that disk state is preserved between
# the two zsh processes.

cd /tmp/pdh-mst-dirA

echo cmd-1
echo cmd-2
echo cmd-3
echo cmd-4
echo cmd-5
echo cmd-6

exit
