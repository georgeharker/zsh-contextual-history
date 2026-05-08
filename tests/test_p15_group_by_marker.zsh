#!/usr/bin/env zsh
# test_p15_group_by_marker
#
# Validates: with CONTEXTUAL_HISTORY_GROUP_BY=(.git), the resolver
# walks up from PWD to find a directory containing the marker file
# (.git in this case) and uses that ancestor as the context root for
# the per-dir history file. Two subdirectories under the same .git-
# rooted project share one history.
#
# Sequence:
#   t0: create project tree:
#         /tmp/projX/.git
#         /tmp/projX/sub-a/
#         /tmp/projX/sub-b/
#   t1: spawn shellA with GROUP_BY=(.git), in sub-a.
#   t2: run 'echo from-sub-a'.
#   t3: cd to sub-b (still under projX).
#   t4: ^P -> expect 'echo from-sub-a' (since projX is one context).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p15.XXXXXX)
PROJ=$(mktemp -d -t ch-pty-p15-proj.XXXXXX)
mkdir -p "$PROJ/.git" "$PROJ/sub-a" "$PROJ/sub-b"
trap "pty_cleanup_all; rm -rf $HISTROOT $PROJ" EXIT

# We need GROUP_BY set BEFORE the plugin's source-time resolve.
# pty_harness's mk_rc writes the rc with HISTFILE etc. BEFORE the
# `source $PLUGIN`. We append GROUP_BY config by appending an extra
# rc fragment; the harness lets caller override CONTEXTUAL_HISTORY_*
# via env.
#
# Simpler: use TEST_SHARE_HISTORY=1 + a CONTEXTUAL_HISTORY_GROUP_BY
# env var. But mk_rc doesn't propagate that one - we'd need to
# extend the harness OR just set it in env -i forwarding directly.

# Use a custom approach: we set GROUP_BY via shell command after
# spawn, then explicitly invoke `_context-history-resolve-file` and
# `_context-history-set-directory-history` to take effect.
TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

# Set GROUP_BY in the spawned shell, cd to project subdirectory.
pty_run_cmd shellA "CONTEXTUAL_HISTORY_GROUP_BY=(.git)" \
  || pty_fail "set GROUP_BY failed"
pty_run_cmd shellA "cd $PROJ/sub-a" || pty_fail "cd sub-a failed"

# Run a command in sub-a. Per-dir resolves to projX (the .git root).
pty_run_cmd shellA 'echo from-sub-a' || pty_fail "from-sub-a failed"

# Verify the per-dir file resolves to the project root (NOT to sub-a).
PROJ_REAL=${PROJ:A}
EXPECTED_FILE="$HISTROOT/dirhist${PROJ_REAL}/history"
if [[ ! -f $EXPECTED_FILE ]]; then
  pty_fail "expected per-dir file at project root: $EXPECTED_FILE; actual files: $(find $HISTROOT -type f)"
fi
grep -q 'from-sub-a' "$EXPECTED_FILE" \
  || pty_fail "project-root per-dir file missing from-sub-a"

# cd to sub-b (still under projX). Should resolve to SAME per-dir file.
pty_run_cmd shellA "cd $PROJ/sub-b" || pty_fail "cd sub-b failed"
sleep 0.1

# ^P walks the shared per-dir history. Latest entry is the cd command,
# next is from-sub-a.
pty_press_up shellA
buf1=$(pty_inspect_buf shellA)
[[ $buf1 == "cd $PROJ/sub-b" ]] \
  || pty_fail "step1 ^P expected cd-to-sub-b, got <$buf1>"

pty_press_up shellA
buf2=$(pty_inspect_buf shellA)
[[ $buf2 == 'echo from-sub-a' ]] \
  || pty_fail "step2 ^P expected 'echo from-sub-a' (sub-a's command shared via project root), got <$buf2>"

pty_pass
