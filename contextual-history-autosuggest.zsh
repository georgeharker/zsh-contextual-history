#!/usr/bin/env zsh
#
# contextual-history-autosuggest.zsh
#
# zsh-autosuggestions integration. Defines two suggestion strategies
# that mirror the plugin's navigation behaviour in the inline grey
# suggestion:
#
#   - contextual_history          (port of upstream `history`)
#   - contextual_match_prev_cmd   (port of upstream `match_prev_cmd`)
#
# Both add the local-history filter on top of their upstream behaviour:
#
#   - context-vs-global axis: implicit. Each strategy reads `$history`,
#     which IS the currently-active ring (we swap it on ^G). So
#     toggling ^G automatically scopes suggestions to the new ring,
#     no per-axis code needed here.
#
#   - this-shell-vs-all axis (local-history): explicit. When the
#     local-history bit is on, both strategies require candidates (and
#     for match_prev_cmd, the preceding entry too) to appear in
#     `_context_history_local_texts` - so the suggestion mirrors the
#     "my-shell only" filter the up-arrow walks under when local-history
#     mode is on.
#
# Auto-sourced unconditionally from the main plugin. The strategy
# functions are just *defined*; nothing fires unless the user opts in:
#
#     ZSH_AUTOSUGGEST_STRATEGY=(contextual_history)
#     # or for command-pair prediction with local-history filtering:
#     ZSH_AUTOSUGGEST_STRATEGY=(contextual_match_prev_cmd)
#
# The opt-in line must run AFTER zsh-autosuggestions is sourced
# (autosuggestions assigns a default to the variable at source time),
# but the ordering of `source` lines for the two plugins themselves
# is free - wrap-chain composition works either way (test_p33).
#
# Toggle responsiveness: `_context-history-print-status` (shared by
# both toggle widgets) calls `zle autosuggest-fetch` if that widget
# exists, so the visible inline suggestion refreshes the instant
# the user flips either axis, not on the next keystroke.
#
# Escape regexes below are kept char-for-char identical to upstream's
# src/strategies/history.zsh and src/util.zsh so behaviour matches
# autosuggestions's own strategies when local-history is off. The two
# regexes legitimately differ - upstream uses different sets for
# prefix-escape (glob-pattern-bound) and command-escape (used
# in `[[ a == b ]]` equality where b is otherwise treated as a glob).

# Prefix-escape: matches upstream src/strategies/{history,match_prev_cmd}.zsh.
# Treats the user's buffer prefix as a literal pattern by escaping
# every glob metachar that would otherwise be interpreted.
_ch_as_escape_prefix() {
  REPLY="${1//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"
}

# Command-escape: matches upstream src/util.zsh _zsh_autosuggest_escape_command.
# Used to make the previous-command string literal in a `[[ a == b ]]`
# comparison where b would otherwise be a glob pattern.
_ch_as_escape_command() {
  REPLY="${1//(#m)[\"\'\\()\[\]|*?~]/\\$MATCH}"
}

# Build the `(prefix)*` glob, honouring ZSH_AUTOSUGGEST_HISTORY_IGNORE
# the same way upstream does (intersection with negative class).
_ch_as_build_pattern() {
  local escaped_prefix=$1
  REPLY="${escaped_prefix}*"
  if [[ -n $ZSH_AUTOSUGGEST_HISTORY_IGNORE ]]; then
    REPLY="(${REPLY})~(${ZSH_AUTOSUGGEST_HISTORY_IGNORE})"
  fi
}

# zsh-autosuggestions discovers strategies by function name. The
# convention is `_zsh_autosuggest_strategy_<name>`; the `<name>` is
# what users put in `ZSH_AUTOSUGGEST_STRATEGY`. No registration call
# is needed.

#------------------------------------------------------------------------------
# Strategy: contextual_history
#------------------------------------------------------------------------------
# Local-history-aware port of upstream's `history` strategy. Returns
# the newest history entry whose text starts with the given prefix;
# when local-history mode is on, restricts the search to entries this
# shell typed.

function _zsh_autosuggest_strategy_contextual_history() {
  emulate -L zsh
  setopt extended_glob

  local REPLY
  _ch_as_escape_prefix "$1"
  local prefix=$REPLY
  _ch_as_build_pattern "$prefix"
  local pattern=$REPLY

  if (( ! ${_context_history_local_mode:-0} )); then
    # Local-history off: same single-subscript fast path as upstream.
    typeset -g suggestion="${history[(r)$~pattern]}"
    return
  fi

  # Local-history on: iterate matching keys (already prefix-filtered,
  # newest-first by $history iteration order) and pick the first
  # entry that is in the this-shell text set.
  local -a candidate_keys=( ${(k)history[(R)$~pattern]} )
  local key entry
  for key in $candidate_keys; do
    entry=${history[$key]}
    (( ${+_context_history_local_texts[$entry]} )) || continue
    typeset -g suggestion=$entry
    return
  done
  typeset -g suggestion=
}

#------------------------------------------------------------------------------
# Strategy: contextual_match_prev_cmd
#------------------------------------------------------------------------------
# Local-history-aware port of upstream's `match_prev_cmd` strategy.
#
# Upstream behaviour: among history entries that start with the prefix,
# prefer one whose immediately-preceding history entry equals the most
# recently executed command (`history[HISTCMD-1]`); fall back to the
# newest prefix match if no such pair exists.
#
# Local-history mode change: candidates are filtered to entries in
# `_context_history_local_texts` (only this shell's typing). The
# preceding-entry adjacency match runs upstream's logic unchanged on
# that filtered candidate list.

function _zsh_autosuggest_strategy_contextual_match_prev_cmd() {
  emulate -L zsh
  setopt extended_glob

  local REPLY
  _ch_as_escape_prefix "$1"
  local prefix=$REPLY
  _ch_as_build_pattern "$prefix"
  local pattern=$REPLY

  # Histnums of entries matching the prefix, newest-first ordering by
  # $history's iteration order.
  local -a history_match_keys=( ${(k)history[(R)$~pattern]} )

  if (( ${_context_history_local_mode:-0} )); then
    local -a filtered
    local key
    for key in $history_match_keys; do
      (( ${+_context_history_local_texts[${history[$key]}]} )) \
        && filtered+=( $key )
    done
    history_match_keys=( $filtered )
  fi

  # Nothing matched (after filter) - no suggestion.
  if (( ${#history_match_keys} == 0 )); then
    typeset -g suggestion=
    return
  fi

  # Default: newest matching candidate. Upgraded below if we find one
  # whose preceding entry equals prev_cmd.
  local histkey="${history_match_keys[1]}"

  _ch_as_escape_command "${history[$((HISTCMD-1))]}"
  local prev_cmd=$REPLY

  # Upstream caps the search at 200 candidates; we do the same.
  local key
  for key in "${(@)history_match_keys[1,200]}"; do
    [[ $key -gt 1 ]] || break
    if [[ "${history[$((key - 1))]}" == "$prev_cmd" ]]; then
      histkey=$key
      break
    fi
  done

  typeset -g suggestion="${history[$histkey]}"
}
