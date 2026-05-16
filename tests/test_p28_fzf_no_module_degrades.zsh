#!/usr/bin/env zsh
# test_p28_fzf_no_module_degrades
#
# Verifies the no-module degradation path: with
# CONTEXTUAL_HISTORY_USE_MODULE=false the widget functions but the
# foreign-tagging refresh isn't available. Specifically:
#
#   1. The plugin's `_context_history_have_native_fast_refresh` flag
#      is `false` when the module isn't loaded.
#   2. The fzf widget function is still registered.
#   3. The snapshot builder still produces well-formed output (one L
#      record per local entry) - it just can't distinguish foreign
#      entries because `fc -RI` doesn't set HIST_FOREIGN.
#   4. The toggle helper script is still generated and works.
#
# This test deliberately avoids the cross-shell HIST_FOREIGN
# observation - that's covered by test_p27 (with module). Here we just
# certify that the plugin doesn't break when the module is absent.

source "${0:A:h}/lib/pty_harness.zsh"

# The fzf integration file is only sourced when fzf is on PATH at
# plugin load (fzf-integration gate + command -v fzf check). The PTY harness
# uses a scrubbed PATH, so inject fzf's directory via TEST_PRE_SOURCE
# so the widget actually loads even in the no-module scenario.
if ! command -v fzf >/dev/null 2>&1; then
  print -ru2 -- "SKIP ${0:t}: fzf not on PATH"
  exit 0
fi
FZF_DIR=$(dirname "$(command -v fzf)")
TEST_PRE_SOURCE="path=(${(q)FZF_DIR} \$path)"

HISTROOT=$(mktemp -d -t ch-pty-p28.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=false TEST_PRE_SOURCE="$TEST_PRE_SOURCE" \
  pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

# Module flag should be false.
pty_run_cmd shellA 'print -r -- "FAST_REFRESH=$_context_history_have_native_fast_refresh"' \
  || pty_fail "could not query module flag"
[[ $REPLY == *FAST_REFRESH=false* ]] \
  || pty_fail "expected FAST_REFRESH=false; got <$REPLY>"

# Widget is still registered (we register unconditionally so users can
# bind it independently of the module).
pty_run_cmd shellA 'print -r -- "WIDGET_REG=$((${+widgets[contextual-history-fzf-widget]}))"' \
  || pty_fail "could not query widget"
[[ $REPLY == *WIDGET_REG=1* ]] \
  || pty_fail "widget not registered without module; got <$REPLY>"

# Add a few local commands and verify snapshot has them tagged L.
pty_run_cmd shellA 'echo p28-local-a' || pty_fail "p28-local-a"
pty_run_cmd shellA 'echo p28-local-b' || pty_fail "p28-local-b"

pty_run_cmd shellA "_context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/snap-out" \
  || pty_fail "snapshot build"

if ! awk -F'\t' '$1=="L" && $4=="echo p28-local-a" {found=1} END {exit !found}' "$HISTROOT/snap-out"; then
  print -ru2 -- "--- snap-out ---"
  cat "$HISTROOT/snap-out" >&2
  pty_fail "snapshot missing L-tagged p28-local-a in no-module path"
fi

if ! awk -F'\t' '$1=="L" && $4=="echo p28-local-b" {found=1} END {exit !found}' "$HISTROOT/snap-out"; then
  print -ru2 -- "--- snap-out ---"
  cat "$HISTROOT/snap-out" >&2
  pty_fail "snapshot missing L-tagged p28-local-b in no-module path"
fi

# Toggle helper script still works without the module.
pty_run_cmd shellA "_context-history-fzf-ensure-toggle-helper; echo HELPER_IS=\$_context_history_fzf_toggle_helper" \
  || pty_fail "could not query helper path"
helper=${REPLY##*HELPER_IS=}
helper=${helper%%$'\r'*}
helper=${helper%%$'\n'*}
[[ -x $helper ]] || pty_fail "helper not executable: $helper"
[[ "$($helper local 'foo')" == '^L foo' ]] || pty_fail "helper local foo in no-module path"
[[ "$($helper all '^L foo')" == 'foo'  ]] || pty_fail "helper strip ^L in no-module path"

pty_pass
