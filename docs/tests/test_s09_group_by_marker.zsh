#!/usr/bin/env zsh
# test_s09_group_by_marker: PER_DIRECTORY_HISTORY_GROUP_BY=(.git) test.
#
# Two-pass sequential test verifying the resolver groups subdirectories
# under a common ancestor that contains a marker file.
#
#   /tmp/pdh-mst-proj/.git/  (marker)
#   /tmp/pdh-mst-proj/sub-a/
#   /tmp/pdh-mst-proj/sub-b/
#
#   pass1: shell starts in /tmp/pdh-mst-proj/sub-a, types cmd-A1; cd's to
#          /tmp/pdh-mst-proj/sub-b, types cmd-B1; exits.
#   pass2: fresh shell in /tmp/pdh-mst-proj/sub-a, dumps history. Should
#          see BOTH cmd-A1 and cmd-B1 because both subdirs walk up to the
#          same group root (/tmp/pdh-mst-proj/).
#
# Without GROUP_BY, sub-a and sub-b would have separate history files and
# pass2 would only see cmd-A1.

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1

# Set up a project tree with a .git marker and two subdirs.
PROJ=/tmp/pdh-mst-proj
rm -rf "$PROJ"
mkdir -p "$PROJ/.git"
mkdir -p "$PROJ/sub-a"
mkdir -p "$PROJ/sub-b"

PASS1_SCRIPT="$SCRIPT_DIR/inputs/_s09_pass1.zsh"
PASS2_SCRIPT="$SCRIPT_DIR/inputs/_s09_pass2.zsh"

cat > "$PASS1_SCRIPT" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.git)
cd /tmp/pdh-mst-proj/sub-a
echo cmd-A1
cd /tmp/pdh-mst-proj/sub-b
echo cmd-B1
exit
EOF

cat > "$PASS2_SCRIPT" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.git)
cd /tmp/pdh-mst-proj/sub-a
history > "$PDH_HIST_OUT"
exit
EOF

run_one() {
  local label=$1 plugin=$2
  local outroot="$RESULTS_DIR/$label"
  local histroot="$outroot/histroot"
  mkdir -p "$histroot"

  print -- "=== $TEST_NAME / $label / pass1 ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" "$outroot/pass1" "$PASS1_SCRIPT"

  print -- "=== $TEST_NAME / $label / pass2 ==="
  TEST_HISTROOT="$histroot" \
  PDH_HIST_OUT="$outroot/pass2/shell_history.out" \
    zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
      "$plugin" "$outroot/pass2" "$PASS2_SCRIPT"
}

run_one fork "$FORK_PLUGIN"

print
print -- "=== Comparison: pass2 history in sub-a (should see BOTH cmd-A1 and cmd-B1 - shared project group) ==="
print -- "--- fork ---"
if [[ -f "$RESULTS_DIR/fork/pass2/shell_history.out" ]]; then
  cat "$RESULTS_DIR/fork/pass2/shell_history.out"
else
  print -- "(missing)"
fi
