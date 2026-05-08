#!/usr/bin/env zsh
# test_s07_three_shells_isolation: three sequential shells exercising
# per-directory isolation. Shell A writes commands in /tmp/pdh-mst-dirA,
# shell B writes in /tmp/pdh-mst-dirB, shell C reads history in
# /tmp/pdh-mst-dirA. Shell C should see shell A's commands but NOT
# shell B's commands.
#
# This is sequential rather than concurrent because the question we are
# answering is about per-directory persistence and isolation rather than
# live cross-shell sync.
#
# Usage:   zsh test_s07_three_shells_isolation.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
UPSTREAM_PLUGIN=${UPSTREAM_PLUGIN:-/tmp/pdh-upstream/contextual-history.zsh}
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1

mkdir -p /tmp/pdh-mst-dirA /tmp/pdh-mst-dirB

# Write tiny one-off input scripts for shells A, B, C. They live in inputs/
# rather than being constructed inline so the harness can read them.
A_SCRIPT="$SCRIPT_DIR/inputs/_s07_shellA.zsh"
B_SCRIPT="$SCRIPT_DIR/inputs/_s07_shellB.zsh"
C_SCRIPT="$SCRIPT_DIR/inputs/_s07_shellC.zsh"

cat > "$A_SCRIPT" <<'EOF'
cd /tmp/pdh-mst-dirA
echo cmd-A1
echo cmd-A2
echo cmd-A3
exit
EOF

cat > "$B_SCRIPT" <<'EOF'
cd /tmp/pdh-mst-dirB
echo cmd-B1
echo cmd-B2
echo cmd-B3
exit
EOF

cat > "$C_SCRIPT" <<'EOF'
cd /tmp/pdh-mst-dirA
history > "$PDH_HIST_OUT"
exit
EOF

run_one() {
  local label=$1 plugin=$2
  local outroot="$RESULTS_DIR/$label"
  local histroot="$outroot/histroot"
  mkdir -p "$histroot"

  print -- "=== $TEST_NAME / $label / shell A in dirA ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" "$outroot/shellA" "$A_SCRIPT"

  print -- "=== $TEST_NAME / $label / shell B in dirB ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" "$outroot/shellB" "$B_SCRIPT"

  print -- "=== $TEST_NAME / $label / shell C in dirA (reads history) ==="
  TEST_HISTROOT="$histroot" \
  PDH_HIST_OUT="$outroot/shellC/shell_history.out" \
    zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
      "$plugin" "$outroot/shellC" "$C_SCRIPT"
}

run_one upstream "$UPSTREAM_PLUGIN"
run_one fork     "$FORK_PLUGIN"

print
print -- "=== Comparison: shell C's history in dirA ==="
print -- "(should contain cmd-A1..A3 but NOT cmd-B1..B3)"
print
for label in upstream fork; do
  print -- "--- $label ---"
  if [[ -f "$RESULTS_DIR/$label/shellC/shell_history.out" ]]; then
    cat "$RESULTS_DIR/$label/shellC/shell_history.out"
  else
    print -- "(missing)"
  fi
  print
done
