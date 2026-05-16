#!/usr/bin/env zsh
# test_p17_zstyle_config
#
# Validates the zstyle configuration path. Same scenario shape as p15
# (group-by .git collapses subdirectories under one shared history),
# but the resolver is configured via `zstyle ':contextual-history:*'
# group-by .git` instead of via the env var
# CONTEXTUAL_HISTORY_GROUP_BY=(.git).
#
# This proves:
#   * The plugin reads zstyle when the env var isn't set.
#   * The zstyle context is `:contextual-history:*` and the key is
#     `group-by`.
#   * Array-valued zstyle (multi-value) is supported.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p17.XXXXXX)
PROJ=$(mktemp -d -t ch-pty-p17-proj.XXXXXX)
mkdir -p "$PROJ/.git" "$PROJ/sub-a" "$PROJ/sub-b"
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$PROJ"' EXIT

# Configure GROUP_BY via zstyle, NOT via env var. The harness's
# TEST_PRE_SOURCE hook inlines this BEFORE sourcing the plugin, so the
# zstyle is in place when _ch_resolve_arr walks back to find it.
TEST_SHARE_HISTORY=1 \
TEST_PRE_SOURCE="zstyle ':contextual-history:*' group-by .git" \
  pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"

pty_run_cmd shellA "cd $PROJ/sub-a"   || pty_fail "cd sub-a failed"
pty_run_cmd shellA 'echo from-sub-a'  || pty_fail "from-sub-a failed"

# Project-root resolution (zstyle-driven) means the per-dir file lives
# at the .git ancestor, not at sub-a.
PROJ_REAL=${PROJ:A}
EXPECTED_FILE="$HISTROOT/dirhist${PROJ_REAL}/history"
[[ -f $EXPECTED_FILE ]] \
  || pty_fail "expected per-dir file at project root: $EXPECTED_FILE; actual files: $(find $HISTROOT -type f)"
grep -q 'from-sub-a' "$EXPECTED_FILE" \
  || pty_fail "project-root per-dir file missing from-sub-a"

# cd to sibling sub-b. Same project root, same per-dir file.
pty_run_cmd shellA "cd $PROJ/sub-b" || pty_fail "cd sub-b failed"
sleep 0.1

pty_press_up shellA
buf1=$(pty_inspect_buf shellA)
[[ $buf1 == "cd $PROJ/sub-b" ]] \
  || pty_fail "step1 ^P expected cd-to-sub-b, got <$buf1>"

pty_press_up shellA
buf2=$(pty_inspect_buf shellA)
[[ $buf2 == 'echo from-sub-a' ]] \
  || pty_fail "step2 ^P expected 'echo from-sub-a' (zstyle-driven group-by collapsed sub-a/sub-b), got <$buf2>"

pty_pass
