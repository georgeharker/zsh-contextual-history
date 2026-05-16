#!/usr/bin/env zsh
# test_p33_wrap_under_autosuggest
#
# Validates that the local-history skip-loop still fires when another
# plugin (specifically: a zsh-autosuggestions-style wrap) takes the
# top spot in $widgets[$widget] after our wrap is installed.
#
# Autosuggestions's bind pattern:
#   1. Take what's currently in $widgets[$widget] (our wrap function).
#   2. Register it under a renamed alias `_zsh_autosuggest_orig_1_<widget>`.
#   3. Install a new bound widget on top as $widgets[$widget].
#   4. The bound widget dispatches through the renamed alias - so
#      *our wrap function still runs*, but $WIDGET inside it is the
#      renamed alias, not the canonical widget name.
#
# Our wrap is generated per-widget with the canonical name hard-coded,
# so it doesn't depend on $WIDGET for dispatch-target lookup or
# local-history widget-scope check. This test reproduces the layering
# and verifies the skip-loop still skips peer entries correctly.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p33.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "spawn"

# Find the histfile.
pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not query HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
mkdir -p "${histfile:h}"

# Inject a peer entry on disk (older stim) and reload.
inject_stim=$(($(date +%s) - 100))
print -r -- ": ${inject_stim}:0;cmd-PEER-XYZ-MARKER" >> "$histfile"
pty_run_cmd shellA "fc -R \$HISTFILE" || pty_fail "fc -R"

# Write a fake-autosuggestions wrap script to disk and source it from
# the test shell. Doing this inline via pty_run_cmd is fragile because
# multi-line shell input through zpty enters ZLE multi-line edit mode.
mock_script="$HISTROOT/fake-autosuggest.zsh"
cat > "$mock_script" <<'MOCK'
local ORIG=${widgets[up-line-or-history]#*:}
zle -N _zsh_autosuggest_orig_1_up-line-or-history $ORIG
_zsh_autosuggest_bound_1_up-line-or-history() {
  zle _zsh_autosuggest_orig_1_up-line-or-history -- "$@"
}
zle -N up-line-or-history _zsh_autosuggest_bound_1_up-line-or-history
MOCK

pty_run_cmd shellA "source $mock_script" \
  || pty_fail "could not source fake-autosuggestions mock"

# Verify the layering. After the mock script runs, autosuggestions
# is on top and our wrap is reachable via the renamed alias. We do
# NOT re-wrap on subsequent precmds (that'd cause infinite recursion
# through the orig alias), so our wrap stays buried - and that's
# fine, because dispatch through autosuggestions's orig_1 alias
# still calls our per-widget wrap function (which has the canonical
# widget name hard-coded).
pty_run_cmd shellA 'print -r -- "TOP=$widgets[up-line-or-history]"' \
  || pty_fail "could not query top wrap"
[[ $REPLY == *_zsh_autosuggest_bound_1_up-line-or-history* ]] \
  || pty_fail "expected fake autosuggestions on top; got <$REPLY>"

pty_run_cmd shellA 'print -r -- "ORIG=$widgets[_zsh_autosuggest_orig_1_up-line-or-history]"' \
  || pty_fail "could not query renamed alias"
[[ $REPLY == *_context-history-wrap-up-line-or-history* ]] \
  || pty_fail "expected our per-widget wrap under the alias; got <$REPLY>"

# Toggle local-history on. With our per-widget wrap, the skip-loop
# should fire correctly even though up-arrow dispatches through
# the autosuggestions chain.
pty_run_cmd shellA '_context_history_local_mode=1' \
  || pty_fail "could not enable local-history"

# Press up many times. The peer entry should never appear in BUFFER.
PEER='cmd-PEER-XYZ-MARKER'
typeset -i tries
local landed_on_peer=0
for ((tries=1; tries<=50; tries++)); do
  pty_press_up shellA
  buf=$(pty_inspect_buf shellA)
  if [[ $buf == $PEER ]]; then
    landed_on_peer=1
    break
  fi
done

if (( landed_on_peer )); then
  pty_fail "local-history skipped through autosuggestions wrap: $tries presses landed on peer entry"
fi

pty_pass
