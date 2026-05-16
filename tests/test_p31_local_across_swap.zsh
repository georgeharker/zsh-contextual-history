#!/usr/bin/env zsh
# test_p31_local_across_swap
#
# Validates that the L tag survives a ring swap. With the
# (stim, text) identity set, when this shell types a command, then
# toggles to global mode (which clears + reloads the ring), then
# toggles back to the context, that command's entry — newly loaded
# into the ring with a different histnum — should still tag as L.
#
# This is the property that the earlier startup-curhist baseline
# approach could NOT provide: histnums get reassigned at ring reload,
# so any histnum-keyed flag would be stale.
#
# Doesn't require the native module — the (stim, text) identity is
# stored in shell state and consulted via fc -lirt '%s' parsing.

source "${0:A:h}/lib/pty_harness.zsh"

if ! command -v fzf >/dev/null 2>&1; then
  print -ru2 -- "SKIP ${0:t}: fzf not on PATH (gate skips loading the fzf file)"
  exit 0
fi
FZF_DIR=$(dirname "$(command -v fzf)")
TEST_PRE_SOURCE="path=(${(q)FZF_DIR} \$path)"

HISTROOT=$(mktemp -d -t ch-pty-p31.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=false TEST_PRE_SOURCE="$TEST_PRE_SOURCE" \
  pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

# Type a command in context mode. The zshaddhistory hook records it
# in _context_history_local_writes.
pty_run_cmd shellA 'echo CONTEXT-CMD' || pty_fail "shellA context cmd"

# Toggle to global by calling the function directly (more reliable
# than ^G in tests because we get a proper prompt round-trip).
pty_run_cmd shellA '_context-history-set-global-history' \
  || pty_fail "shellA toggle to global"

# Snapshot from global view.
pty_run_cmd shellA "_context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/global.snap" \
  || pty_fail "shellA global snapshot"

# Toggle back to context. CONTEXT-CMD should reappear in the ring
# (loaded from per-dir histfile via replace-ring) and should be
# tagged L because (stim, text) still matches what we recorded.
pty_run_cmd shellA '_context-history-set-directory-history' \
  || pty_fail "shellA toggle back to context"

pty_run_cmd shellA "_context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/ctx.snap" \
  || pty_fail "shellA context snapshot after toggle-back"

# After two toggles, CONTEXT-CMD should be present and L-tagged.
if ! awk -F'\t' '$1=="L" && $4=="echo CONTEXT-CMD" {found=1} END {exit !found}' "$HISTROOT/ctx.snap"; then
  print -ru2 -- "--- ctx.snap ---"
  cat "$HISTROOT/ctx.snap" >&2
  pty_fail "CONTEXT-CMD lost L tag after toggle-out + toggle-back"
fi

# Also assert that the in-memory set survived (sanity).
pty_run_cmd shellA 'print -r -- "WRITES=${#_context_history_local_writes}"' \
  || pty_fail "could not query writes count"
[[ $REPLY == *WRITES=[1-9]* ]] \
  || pty_fail "_context_history_local_writes empty after swap; got <$REPLY>"

pty_pass
