#!/usr/bin/env zsh
# test_s08_mode_N_chpwd_flush: mode N (no SHARE_HISTORY, no INC_APPEND_HISTORY)
# scenario verifying that the plugin flushes pending in-memory entries to the
# OUTGOING per-dir file at chpwd time.
#
# Three-pass sequential test:
#   pass1: single shell starts in /tmp/pdh-mst-dirA. Types cmd-A1, cmd-A2,
#          cmd-A3. cd's to /tmp/pdh-mst-dirB. Types cmd-B1. Exits.
#   pass2: fresh shell starts in /tmp/pdh-mst-dirA. Dumps `history`. Should
#          see cmd-A1..cmd-A3 (the entries typed there in pass1) but NOT
#          cmd-B1 (typed in dirB, must not leak).
#
# Without Option B (chpwd flush), pass2's per-dir-A history would be empty
# because mode N has no incremental writes - cmd-A1..A3 were only in
# pass1's in-memory ring, which was wiped on cd /tmp/pdh-mst-dirB.
#
# With Option B, set-directory-history fires fc -AI on the outgoing file
# before the swap, so cmd-A1..A3 land in per-dir-A's file.
#
# Usage:   zsh test_s08_mode_N_chpwd_flush.zsh

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

# Mode N: no SHARE, no INC.
unset TEST_SHARE_HISTORY TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL

mkdir -p /tmp/pdh-mst-dirA /tmp/pdh-mst-dirB

# Per-shell input scripts.
PASS1_SCRIPT="$SCRIPT_DIR/inputs/_s08_pass1.zsh"
PASS2_SCRIPT="$SCRIPT_DIR/inputs/_s08_pass2.zsh"

cat > "$PASS1_SCRIPT" <<'EOF'
cd /tmp/pdh-mst-dirA
echo cmd-A1
echo cmd-A2
echo cmd-A3
cd /tmp/pdh-mst-dirB
echo cmd-B1
exit
EOF

cat > "$PASS2_SCRIPT" <<'EOF'
cd /tmp/pdh-mst-dirA
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
print -- "=== Comparison: pass2 shell's history in /tmp/pdh-mst-dirA ==="
print -- "(should contain cmd-A1..A3 but NOT cmd-B1)"
print
print -- "--- fork ---"
if [[ -f "$RESULTS_DIR/fork/pass2/shell_history.out" ]]; then
  cat "$RESULTS_DIR/fork/pass2/shell_history.out"
else
  print -- "(missing)"
fi
