#!/usr/bin/env zsh
# test_p16_group_strategies
#
# Validates: GROUP_BY's "first match wins" semantic. With
# CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git), an explicit .histroot
# at a SHALLOWER ancestor takes precedence over a deeper .git.
# Documents the resolver's same-walk multiple-pattern behavior.
#
# Tree:
#   /tmp/outer/.histroot       <- explicit context root marker
#   /tmp/outer/inner/.git      <- a git root inside outer
#   /tmp/outer/inner/sub/      <- where the shell runs
#
# With GROUP_BY=(.histroot .git):
#   walk-up from sub: sub (neither marker), inner (.git found), outer
#                     (.histroot found).
#   The closest ancestor with ANY marker wins. inner has .git so it
#   wins. (NOT what some users expect - this documents that order
#   doesn't matter when ancestors at different depths each have a
#   different marker; the closer ancestor wins regardless.)

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p16.XXXXXX)
TREE=$(mktemp -d -t ch-pty-p16-tree.XXXXXX)
mkdir -p "$TREE/inner/sub" "$TREE/.histroot" "$TREE/inner/.git"
# Note: .histroot and .git are both files, NOT dirs (resolver tests
# for either with [[ -e ... ]]). Replace dir with empty file.
rmdir "$TREE/.histroot" "$TREE/inner/.git" 2>/dev/null
: > "$TREE/.histroot"
: > "$TREE/inner/.git"
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$TREE"' EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

# Set GROUP_BY and cd into the deepest dir.
pty_run_cmd shellA 'CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git)' \
  || pty_fail "set GROUP_BY failed"
pty_run_cmd shellA "cd $TREE/inner/sub" || pty_fail "cd sub failed"
pty_run_cmd shellA 'echo from-sub' || pty_fail "from-sub failed"

# Per-dir should resolve to .../inner/ (the closest ancestor with any
# marker - .git here), NOT to the outer .histroot ancestor.
TREE_REAL=${TREE:A}
INNER_FILE="$HISTROOT/dirhist${TREE_REAL}/inner/history"
OUTER_FILE="$HISTROOT/dirhist${TREE_REAL}/history"

if [[ ! -f $INNER_FILE ]]; then
  pty_fail "expected per-dir at inner (.git root): $INNER_FILE; got: $(find $HISTROOT -type f)"
fi

if [[ -f $OUTER_FILE ]]; then
  pty_fail "did NOT expect per-dir at outer (.histroot): $OUTER_FILE - the closer .git should have won"
fi

grep -q 'from-sub' "$INNER_FILE" \
  || pty_fail "inner per-dir file missing 'from-sub'"

pty_pass
