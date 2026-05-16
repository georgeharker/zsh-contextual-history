#!/usr/bin/env zsh
# test_p35_autosuggest_match_prev_cmd
#
# Validates the local-history-aware port of zsh-autosuggestions's
# `match_prev_cmd` strategy:
# `_zsh_autosuggest_strategy_contextual_match_prev_cmd`.
#
# Strategy contract (mirrors upstream + local-history filter):
#   - finds entries matching prefix*;
#   - prefers an entry whose PRECEDING history entry equals the
#     previously-executed command (history[HISTCMD-1]);
#   - falls back to newest prefix match if no such pair exists;
#   - local-history ON: filters candidates AND the preceding-entry
#     check to entries in _context_history_local_texts.
#
# Test scenarios:
#   (a) local-history OFF: prev_cmd-pair match beats pure recency. Two
#       peer candidates exist; only the OLDER one follows prev_cmd
#       in history. Suggestion must be the older one - proves pair
#       logic, not just newest-match.
#   (b) local-history OFF: no prefix match -> empty.
#   (c) local-history ON, candidates are peer-only -> empty.
#   (d) local-history ON, local (prev_cmd, follow) pair exists -> local
#       follow wins.
#
# History entries are aliased to `true` so typing them is a no-op
# but the recorded history text is clean (no error-suppression
# suffix to pollute the entry text).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p35.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" \
  || pty_fail "spawn"

pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not query HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
mkdir -p "${histfile:h}"

# Inject peer entries. Adjacent histents in the file mean the loaded
# ring will preserve adjacency at consecutive histnums. Pattern:
#   <older>  p35-prev-cmd      (peer)
#            p35-follow-PEER-A (peer, follows prev_cmd)
#            unrelated-cmd     (peer)
#            p35-follow-PEER-B (peer, newer match but NOT following
#                              prev_cmd - precedes 'unrelated-cmd'
#                              from this entry's perspective)
#   <newer>
now=$(date +%s)
print -r -- ": $((now-400)):0;p35-prev-cmd"       >> "$histfile"
print -r -- ": $((now-399)):0;p35-follow-PEER-A"  >> "$histfile"
print -r -- ": $((now-398)):0;unrelated-cmd"      >> "$histfile"
print -r -- ": $((now-397)):0;p35-follow-PEER-B"  >> "$histfile"
pty_run_cmd shellA "fc -R \$HISTFILE" || pty_fail "fc -R reload"

# Define aliases so typing the test commands is a no-op AND the
# recorded history text is clean (no suffix).
pty_run_cmd shellA 'alias p35-prev-cmd=true p35-follow-LOCAL=true' \
  || pty_fail "alias setup"

# Sanity: strategy fn defined.
pty_run_cmd shellA 'print -r -- "DEFINED=$((${+functions[_zsh_autosuggest_strategy_contextual_match_prev_cmd]}))"'
[[ $REPLY == *DEFINED=1* ]] \
  || pty_fail "match_prev_cmd strategy not defined; got <$REPLY>"

# Call helper: types p35-prev-cmd then invokes the strategy with the
# given prefix. The p35-prev-cmd typing ensures HISTCMD-1 IS the
# clean string 'p35-prev-cmd' when the strategy fires (any other
# intervening state-mutation command would otherwise have taken that
# slot).
call_strategy() {
  local prefix=$1
  pty_run_cmd shellA 'p35-prev-cmd' || pty_fail "type prev-cmd before strategy"
  pty_run_cmd shellA "typeset suggestion=; _zsh_autosuggest_strategy_contextual_match_prev_cmd ${(q)prefix}; print -r -- \"SUGG=<\${suggestion}>\"" \
    || pty_fail "strategy call failed for prefix '$prefix'"
}

set_local_mode() {
  pty_run_cmd shellA "_context_history_local_mode=$1" \
    || pty_fail "set local-history=$1"
}

# ---------------------------------------------------------------------
# (a) local-history OFF: pair-match beats newest. Two peer candidates
# exist; only PEER-A follows prev_cmd in the on-disk sequence.
# PEER-B is the newer match but its preceding entry is 'unrelated-cmd'.
# Strategy should prefer PEER-A.
# ---------------------------------------------------------------------
set_local_mode 0
call_strategy 'p35-follow-'
[[ $REPLY == *'SUGG=<p35-follow-PEER-A>'* ]] \
  || pty_fail "(a) local-history OFF prefix p35-follow-: expected pair-match PEER-A, got <$REPLY>"

# ---------------------------------------------------------------------
# (b) local-history OFF: prefix matches nothing -> empty.
# ---------------------------------------------------------------------
call_strategy 'p35-no-match-'
[[ $REPLY == *'SUGG=<>'* ]] \
  || pty_fail "(b) local-history OFF prefix p35-no-match-: expected empty, got <$REPLY>"

# ---------------------------------------------------------------------
# (c) local-history ON: candidates are peer-only -> empty (filtered).
# ---------------------------------------------------------------------
set_local_mode 1
call_strategy 'p35-follow-'
[[ $REPLY == *'SUGG=<>'* ]] \
  || pty_fail "(c) local-history ON prefix p35-follow-: expected empty (peers filtered), got <$REPLY>"

# ---------------------------------------------------------------------
# (d) Type a local (p35-prev-cmd, p35-follow-LOCAL) pair, then test.
# After this point in_memory ring has adjacent local entries; both
# are in _context_history_local_texts.
# ---------------------------------------------------------------------
pty_run_cmd shellA 'p35-prev-cmd'    || pty_fail "type prev-cmd for local pair"
pty_run_cmd shellA 'p35-follow-LOCAL' || pty_fail "type follow-LOCAL"
# call_strategy will type p35-prev-cmd again, making the candidate
# p35-follow-LOCAL's preceding entry == p35-prev-cmd (local).
call_strategy 'p35-follow-'
[[ $REPLY == *'SUGG=<p35-follow-LOCAL>'* ]] \
  || pty_fail "(d) local-history ON prefix p35-follow-: expected p35-follow-LOCAL, got <$REPLY>"

pty_pass
