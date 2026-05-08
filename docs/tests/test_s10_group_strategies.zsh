#!/usr/bin/env zsh
# test_s10_group_strategies: closest-ancestor wins + stop-point bounding.
#
# Tree:
#   /tmp/pdh-mst-monorepo/
#     .histroot               <- outer marker
#     submodule/
#       .git/                 <- inner marker (closer to PWD)
#       deep/
#
# Sub-test A (closest wins):
#   GROUP_BY=(.histroot .git), PWD=submodule/deep.
#   Walk-up: deep -> nothing. submodule -> has .git, return /submodule.
#   So submodule/deep groups under /submodule (closest-ancestor wins
#   regardless of pattern order).
#
# Sub-test B (stop-point bounds the walk):
#   GROUP_BY=(.histroot .git), STOPS=(/tmp/pdh-mst-monorepo/submodule),
#   PWD=submodule/deep.
#   Walk-up: deep -> nothing. submodule -> has .git AND is a stop. Marker
#   match wins (it's checked before stop check), so still returns
#   /submodule. Stop point is irrelevant when the stop dir itself has a
#   marker.
#
# Sub-test C (stop-point blocks finding higher marker):
#   GROUP_BY=(.histroot), STOPS=(/tmp/pdh-mst-monorepo/submodule),
#   PWD=submodule/deep.
#   Walk-up: deep -> nothing. submodule -> no .histroot, AT stop -> fail.
#   Resolver falls back to PWD. So submodule/deep is its own group.
#
# We exercise A + C with sequential pass1/pass2 patterns: shell writes
# something in PWD, fresh shell reads it back; if grouping is right, the
# read sees the write.

set -e

SCRIPT_DIR=${0:A:h}
TEST_NAME=${${0:t}:r}
RESULTS_DIR="$SCRIPT_DIR/results/$TEST_NAME"
FORK_PLUGIN="$SCRIPT_DIR/../../contextual-history.zsh"

unset TEST_INC_APPEND TEST_EXTENDED TEST_START_GLOBAL
export TEST_SHARE_HISTORY=1

REPO=/tmp/pdh-mst-monorepo
rm -rf "$REPO"
mkdir -p "$REPO/submodule/.git/anything"
mkdir -p "$REPO/submodule/deep"
touch "$REPO/.histroot"

INPUT_DIR="$SCRIPT_DIR/inputs"

# === Sub-test A: closest-ancestor wins ===
# pass1 typed in submodule/deep -> grouped under submodule (.git)
# pass2 in submodule/leaf -> also under submodule -> sees pass1's write
mkdir -p "$REPO/submodule/leaf"

cat > "$INPUT_DIR/_s10_A_pass1.zsh" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
cd /tmp/pdh-mst-monorepo/submodule/deep
echo cmd-from-deep
exit
EOF
cat > "$INPUT_DIR/_s10_A_pass2.zsh" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
cd /tmp/pdh-mst-monorepo/submodule/leaf
history > "$PDH_HIST_OUT"
exit
EOF

# === Sub-test C: stop point blocks finding higher marker ===
# pass1 typed in submodule/deep with STOPS=(submodule) and only .histroot
# pattern. Walk-up hits submodule (no .histroot, is stop) -> fall back to
# PWD-as-group. So submodule/deep is its own group.
# pass2 in submodule/leaf reads from leaf-as-group (different) so should
# NOT see pass1's write.
cat > "$INPUT_DIR/_s10_C_pass1.zsh" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot)
PER_DIRECTORY_HISTORY_GROUP_STOPS=(/tmp/pdh-mst-monorepo/submodule)
cd /tmp/pdh-mst-monorepo/submodule/deep
echo cmd-deep-stopped
exit
EOF
cat > "$INPUT_DIR/_s10_C_pass2.zsh" <<'EOF'
PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot)
PER_DIRECTORY_HISTORY_GROUP_STOPS=(/tmp/pdh-mst-monorepo/submodule)
cd /tmp/pdh-mst-monorepo/submodule/leaf
history > "$PDH_HIST_OUT"
exit
EOF

run_pair() {
  local label=$1 plugin=$2 p1=$3 p2=$4
  local outroot=$RESULTS_DIR/$label
  local histroot=$outroot/histroot
  mkdir -p "$histroot"

  print -- "=== $TEST_NAME / $label / pass1 ==="
  TEST_HISTROOT="$histroot" zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
    "$plugin" "$outroot/pass1" "$p1"
  print -- "=== $TEST_NAME / $label / pass2 ==="
  TEST_HISTROOT="$histroot" \
  PDH_HIST_OUT="$outroot/pass2/shell_history.out" \
    zsh "$SCRIPT_DIR/lib/single_shell.zsh" \
      "$plugin" "$outroot/pass2" "$p2"
}

run_pair sub_A_closest_wins  "$FORK_PLUGIN" "$INPUT_DIR/_s10_A_pass1.zsh" "$INPUT_DIR/_s10_A_pass2.zsh"
run_pair sub_C_stop_blocks   "$FORK_PLUGIN" "$INPUT_DIR/_s10_C_pass1.zsh" "$INPUT_DIR/_s10_C_pass2.zsh"

print
print -- "=== Sub-test A: closest-ancestor wins (.git at submodule beats .histroot at monorepo) ==="
print -- "(should see cmd-from-deep - both deep and leaf walk up to submodule)"
cat "$RESULTS_DIR/sub_A_closest_wins/pass2/shell_history.out" 2>/dev/null
print
print -- "=== Sub-test C: stop point blocks reaching .histroot at monorepo ==="
print -- "(should NOT see cmd-deep-stopped - deep and leaf are separate groups)"
cat "$RESULTS_DIR/sub_C_stop_blocks/pass2/shell_history.out" 2>/dev/null
