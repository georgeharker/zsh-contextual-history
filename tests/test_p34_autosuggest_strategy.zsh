#!/usr/bin/env zsh
# test_p34_autosuggest_strategy
#
# Validates the zsh-autosuggestions strategy
# `_zsh_autosuggest_strategy_contextual_history` defined in the
# autosuggest sibling file. Called directly (no real autosuggestions
# load needed - it's just a function that reads $history,
# _context_history_local_mode, and _context_history_local_texts, and
# sets `suggestion`).
#
# Strategy contract:
#   - local-history OFF: same result as autosuggestions's stock `history`
#     strategy (newest entry whose text starts with the prefix).
#   - local-history ON:  newest entry that BOTH starts with the prefix
#     AND is in _context_history_local_texts. Returns empty if no
#     local entry matches.
#
# Test matrix:
#   (a) local-history OFF, prefix 'cmd-'  -> peer entry (newest match)
#   (b) local-history OFF, prefix 'echo T'-> local entry
#   (c) local-history ON,  prefix 'cmd-'  -> EMPTY (peer not in texts)
#   (d) local-history ON,  prefix 'echo T'-> local entry

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p34.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "spawn"

# Locate the histfile and inject a peer entry.
pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not query HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
mkdir -p "${histfile:h}"

inject_stim=$(($(date +%s) - 100))
print -r -- ": ${inject_stim}:0;cmd-PEER-P34-MARKER" >> "$histfile"
pty_run_cmd shellA "fc -R \$HISTFILE" \
  || pty_fail "fc -R reload"

# Type a local command. Both $history and _context_history_local_texts
# get it.
LOCAL='echo TEST34-LOCAL'
pty_run_cmd shellA "$LOCAL" \
  || pty_fail "type local cmd"

# Sanity: strategy function exists.
pty_run_cmd shellA 'print -r -- "DEFINED=$((${+functions[_zsh_autosuggest_strategy_contextual_history]}))"' \
  || pty_fail "could not query strategy fn existence"
[[ $REPLY == *DEFINED=1* ]] \
  || pty_fail "strategy function not defined; got <$REPLY>"

# Helper: call the strategy with a prefix, print SUGG=<value>.
# Wrap in `typeset suggestion=` so a stale value doesn't leak across
# calls.
call_strategy() {
  local prefix=$1
  pty_run_cmd shellA "typeset suggestion=; _zsh_autosuggest_strategy_contextual_history ${(q)prefix}; print -r -- \"SUGG=<\${suggestion}>\"" \
    || pty_fail "strategy call failed for prefix '$prefix'"
}

# ---------------------------------------------------------------------
# (a) local-history OFF, prefix 'cmd-' -> peer entry (newest match)
# ---------------------------------------------------------------------
pty_run_cmd shellA '_context_history_local_mode=0' \
  || pty_fail "set local-history=0"
call_strategy 'cmd-'
[[ $REPLY == *'SUGG=<cmd-PEER-P34-MARKER>'* ]] \
  || pty_fail "(a) local-history OFF, prefix 'cmd-': expected peer entry, got <$REPLY>"

# ---------------------------------------------------------------------
# (b) local-history OFF, prefix 'echo T' -> local entry
# ---------------------------------------------------------------------
call_strategy 'echo T'
[[ $REPLY == *"SUGG=<${LOCAL}>"* ]] \
  || pty_fail "(b) local-history OFF, prefix 'echo T': expected '$LOCAL', got <$REPLY>"

# ---------------------------------------------------------------------
# (c) local-history ON, prefix 'cmd-' -> EMPTY
# ---------------------------------------------------------------------
pty_run_cmd shellA '_context_history_local_mode=1' \
  || pty_fail "set local-history=1"
call_strategy 'cmd-'
[[ $REPLY == *'SUGG=<>'* ]] \
  || pty_fail "(c) local-history ON, prefix 'cmd-': expected empty, got <$REPLY>"

# ---------------------------------------------------------------------
# (d) local-history ON, prefix 'echo T' -> local entry
# ---------------------------------------------------------------------
call_strategy 'echo T'
[[ $REPLY == *"SUGG=<${LOCAL}>"* ]] \
  || pty_fail "(d) local-history ON, prefix 'echo T': expected '$LOCAL', got <$REPLY>"

pty_pass
