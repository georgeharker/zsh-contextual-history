#!/usr/bin/env zsh
# test_p29_fzf_load_gate
#
# Verifies the two conditions that gate loading of the fzf
# integration file (contextual-history-fzf.zsh) from the main plugin:
#
#   1. CONTEXTUAL_HISTORY_FZF_INTEGRATION / fzf-integration=false → don't source,
#      even if fzf is on PATH.
#   2. fzf not on PATH → don't source, even if fzf-integration=true.
#
# When the file isn't sourced, the widget isn't registered. The check
# probes `${+widgets[contextual-history-fzf-widget]}` for 0.
#
# Skips if fzf isn't on the host at all (we need to control PATH
# precisely, which is impossible without a baseline fzf binary).

source "${0:A:h}/lib/pty_harness.zsh"

if ! command -v fzf >/dev/null 2>&1; then
  print -ru2 -- "SKIP ${0:t}: fzf not on host (can't isolate the gate behaviour)"
  exit 0
fi
FZF_DIR=$(dirname "$(command -v fzf)")

HISTROOT=$(mktemp -d -t ch-pty-p29.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

# --- case 1: fzf-integration=false, fzf IS on PATH ---
#
# Inject fzf into PATH so the gate's `command -v fzf` would succeed,
# then set fzf-integration=false BEFORE the plugin sources. The integration
# file should be skipped because of the zstyle / env var, not the
# PATH check.
TEST_PRE_SOURCE="path=(${(q)FZF_DIR} \$path); CONTEXTUAL_HISTORY_FZF_INTEGRATION=false" \
  TEST_SHARE_HISTORY=1 pty_spawn shellOff "$HISTROOT" \
  || pty_fail "could not spawn shellOff"

pty_run_cmd shellOff 'print -r -- "WIDGET=$((${+widgets[contextual-history-fzf-widget]}))"' \
  || pty_fail "could not query widget (off)"
[[ $REPLY == *WIDGET=0* ]] \
  || pty_fail "case 1: widget should NOT be registered when fzf-integration=false; got <$REPLY>"

# Also verify fzf-integration reading: env var should be observable post-source.
pty_run_cmd shellOff 'print -r -- "FZF_INTEGRATION=$CONTEXTUAL_HISTORY_FZF_INTEGRATION"' \
  || pty_fail "could not query fzf-integration var"
[[ $REPLY == *FZF_INTEGRATION=false* ]] \
  || pty_fail "case 1: FZF_INTEGRATION env var lost; got <$REPLY>"

# --- case 2: fzf-integration=true (default), fzf NOT on PATH ---
#
# Don't inject fzf into PATH. The harness's scrubbed PATH
# (/usr/bin:/bin:/usr/sbin:/sbin) doesn't include fzf on a typical
# host. The gate's `command -v fzf` should fail and we skip sourcing.
TEST_SHARE_HISTORY=1 pty_spawn shellNoFzf "$HISTROOT" \
  || pty_fail "could not spawn shellNoFzf"

# Sanity: confirm fzf really isn't reachable from inside the PTY.
pty_run_cmd shellNoFzf 'print -r -- "HAS_FZF=$((${+commands[fzf]}))"'
if [[ $REPLY == *HAS_FZF=1* ]]; then
  print -ru2 -- "SKIP ${0:t}: harness PATH unexpectedly contains fzf; can't run case 2"
  pty_pass
fi

pty_run_cmd shellNoFzf 'print -r -- "WIDGET=$((${+widgets[contextual-history-fzf-widget]}))"' \
  || pty_fail "could not query widget (no-fzf)"
[[ $REPLY == *WIDGET=0* ]] \
  || pty_fail "case 2: widget should NOT be registered when fzf not on PATH; got <$REPLY>"

pty_pass
