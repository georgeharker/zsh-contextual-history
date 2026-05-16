#!/usr/bin/env zsh
# test_p25_custom_resolver_edge_cases
#
# Validates: custom `_context-history-group` resolver functions
# returning unusual values are handled without crashes or misrouted
# writes:
#
#   * empty string -> all dirs collapse to one history file at
#     $HISTORY_BASE/history (effectively a "single shared file"
#     resolver, useful for simple "always-shared" setups).
#   * whitespace-containing key -> directory name with spaces is fine
#     (the plugin's path handling stays quoted).
#
# Note: the plugin defines `_context-history-group` itself during
# source, so a TEST_PRE_SOURCE override would get clobbered. We
# redefine after the spawn (post-source) via pty_run_cmd; the resolver
# is consulted on every chpwd, so post-spawn redefinition takes effect
# from the next cd onwards.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p25.XXXXXX)
DIRA=$(mktemp -d -t ch-pty-p25-A.XXXXXX)
DIRB=$(mktemp -d -t ch-pty-p25-B.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$DIRA" "$DIRB"' EXIT

# --- case 1: empty-string resolver ----------------------------------
# All dirs collapse to one shared per-dir file at
# $HISTORY_BASE/history (because $HISTORY_BASE is "$histroot/dirhist"
# and the resolver appends nothing).

TEST_SHARE_HISTORY=1 pty_spawn shellEmpty "$HISTROOT" \
  || pty_fail "spawn shellEmpty"

# Override the resolver post-source. We pass a single-line redef so
# pty_run_cmd's accept-line semantics are happy.
pty_run_cmd shellEmpty 'function _context-history-group() { print -r -- "" }' \
  || pty_fail "redef resolver (empty)"

pty_run_cmd shellEmpty "cd $DIRA"            || pty_fail "Empty cd dirA"
pty_run_cmd shellEmpty 'echo from-dirA-empty' || pty_fail "Empty write A"
pty_run_cmd shellEmpty "cd $DIRB"            || pty_fail "Empty cd dirB"
pty_run_cmd shellEmpty 'echo from-dirB-empty' || pty_fail "Empty write B"
sleep 0.3

# Shared file should be $HISTORY_BASE/history. With empty-key resolver,
# the path is "$HISTROOT/dirhist" + "" + "/history".
SHARED_FILE="$HISTROOT/dirhist/history"
[[ -f $SHARED_FILE ]] \
  || pty_fail "empty-resolver shared file missing at <$SHARED_FILE>; HISTROOT: $(find "$HISTROOT" -type f)"

fgrep -q 'echo from-dirA-empty' "$SHARED_FILE" \
  || pty_fail "shared file missing dirA write"
fgrep -q 'echo from-dirB-empty' "$SHARED_FILE" \
  || pty_fail "shared file missing dirB write (resolver should collapse both dirs into one file)"

# Also: no dir-specific files should exist (the resolver returned "",
# so the plugin never resolves to anything under DIRA or DIRB).
DIRA_REAL=${DIRA:A}
DIRB_REAL=${DIRB:A}
[[ ! -f "$HISTROOT/dirhist${DIRA_REAL}/history" ]] \
  || pty_fail "unexpected per-dir file under dirA -- empty resolver should collapse"
[[ ! -f "$HISTROOT/dirhist${DIRB_REAL}/history" ]] \
  || pty_fail "unexpected per-dir file under dirB -- empty resolver should collapse"

pty_cleanup shellEmpty

# --- case 2: resolver returns key with spaces -----------------------
# Resolver returns a fixed group key "shared workspace" (with space).
# All shells collapse to $HISTORY_BASE/shared workspace/history.

TEST_SHARE_HISTORY=1 pty_spawn shellSpaceA "$HISTROOT" \
  || pty_fail "spawn shellSpaceA"

pty_run_cmd shellSpaceA 'function _context-history-group() { print -r -- "shared workspace" }' \
  || pty_fail "redef resolver (space-key, A)"

pty_run_cmd shellSpaceA "cd $DIRA"             || pty_fail "SpaceA cd dirA"
pty_run_cmd shellSpaceA 'echo from-spaceA-A'   || pty_fail "SpaceA write"
sleep 0.3

SPACE_FILE="$HISTROOT/dirhist/shared workspace/history"
[[ -f $SPACE_FILE ]] \
  || pty_fail "space-key resolver file missing at <$SPACE_FILE>; HISTROOT: $(find "$HISTROOT" -type f)"
fgrep -q 'echo from-spaceA-A' "$SPACE_FILE" \
  || pty_fail "space-key file missing the write"

# Cross-shell: a sibling shell with the same resolver should see the
# write via SHARE merge.
TEST_SHARE_HISTORY=1 pty_spawn shellSpaceB "$HISTROOT" \
  || pty_fail "spawn shellSpaceB"

pty_run_cmd shellSpaceB 'function _context-history-group() { print -r -- "shared workspace" }' \
  || pty_fail "redef resolver (space-key, B)"

pty_run_cmd shellSpaceB "cd $DIRB" || pty_fail "SpaceB cd dirB"
sleep 0.3

# B's `cd $DIRB` was hended in B's spawn-dir per-dir (chpwd-leak), so
# B's first ^P inside the space-key context hits A's prior write.
pty_press_up shellSpaceB
buf=$(pty_inspect_buf shellSpaceB)
[[ $buf == 'echo from-spaceA-A' ]] \
  || pty_fail "SpaceB step1 expected 'echo from-spaceA-A' (cross-shell via space-key resolver), got <$buf>"

pty_pass
