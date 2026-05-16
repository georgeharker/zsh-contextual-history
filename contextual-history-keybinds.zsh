#!/usr/bin/env zsh
#
# contextual-history-keybinds.zsh
#
# Container for extra keybind-driven features that aren't core to
# the plugin's history-swap / tee / share behaviour. Today this is
# the local-history navigation filter; future opt-in keybind features
# can land here too.
#
# Auto-sourced from the main plugin. Each feature is inert unless
# the user sets its keybind zstyle.
#
# Hard dependencies:
#   _context_history_local_texts             - main plugin
#   _ch_resolve, _ch_resolve_arr             - main plugin
#   _context-history-call-original   - widgets sibling
#   _context-history-wrap-impl               - widgets sibling
#       (calls our skip functions via function-existence check)

#==============================================================================
# Local-history navigation filter
#==============================================================================
#
# Opt-in keybind that toggles "scroll only through entries this
# shell typed". When enabled, up-arrow / down-arrow (and the other
# history navigation widgets) skip ring entries that aren't in
# `_context_history_local_texts`. User opts in by setting:
#
#     zstyle ':contextual-history:*' local-toggle-key '^X^L'
#
# (or any key they prefer). With no key set this section's contents
# are inert — the state bit, configs, and toggle widget exist but
# nothing fires.

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# Keybind for the local-history toggle. Default empty = unbound; user
# opts in by setting this.
_ch_resolve CONTEXTUAL_HISTORY_LOCAL_KEY local-toggle-key ''

# Initial state of the local-history mode bit. Parallel to
# `start-with-global` for the context-vs-global axis. Default off
# means new shells start with all-shells history visible; set true
# to start in this-shell-only mode without needing to press the
# toggle. Independent of `local-toggle-key` - users can pin the
# mode on without binding a key, or bind a key without changing
# the start state.
_ch_resolve CONTEXTUAL_HISTORY_START_WITH_LOCAL start-with-local false

# Subset of `refreshing-widgets` that get the local-history skip-loop.
# Excludes incremental search (whose stateful per-keystroke semantics
# don't compose with a skip-after-dispatch loop). User can shrink or
# extend.
_ch_resolve_arr CONTEXTUAL_HISTORY_LOCAL_WIDGETS local-widgets \
  up-line-or-history down-line-or-history \
  up-line-or-search down-line-or-search \
  up-history down-history \
  history-search-backward history-search-forward \
  history-beginning-search-backward history-beginning-search-forward

#-------------------------------------------------------------------------------
# State + skip loop
#-------------------------------------------------------------------------------

typeset -gi _context_history_local_mode
if [[ ${CONTEXTUAL_HISTORY_START_WITH_LOCAL:-false} == true ]]; then
  _context_history_local_mode=1
else
  _context_history_local_mode=0
fi

# The skip loop: after the underlying nav widget has dispatched and
# advanced HISTNO, if local-history mode is on AND the just-loaded
# BUFFER isn't in our local-texts set, dispatch the underlying widget
# again. Bail on boundary (HISTNO unchanged), on a non-local-widget
# entry, or after a safety cap.
#
# Called from `_context-history-wrap-impl` in the widgets sibling,
# guarded by `(( ${+functions[_context-history-local-skip]} ))`
# so the widgets sibling doesn't need to know this file exists.

function _context-history-local-skip() {
  # Args: <canonical widget name> <pre buffer> <pre histno> <pre cursor> [widget args...]
  # The widget name is the canonical name (not $WIDGET, which can be a
  # renamed alias when called via zsh-autosuggestions's orig-widget
  # chain). The pre-* values are the BUFFER/HISTNO/CURSOR state before
  # the wrap dispatched the original widget; we restore them if we
  # can't find a local entry to land on (acts as a soft boundary -
  # up-arrow stops advancing past the last local rather than
  # overshooting into non-local territory).
  local widget=$1 pre_buffer=$2
  local -i pre_histno=$3 pre_cursor=$4
  shift 4

  (( _context_history_local_mode )) || return 0
  if (( ${CONTEXTUAL_HISTORY_LOCAL_WIDGETS[(I)$widget]} == 0 )); then
    return 0
  fi
  # Already on a local entry (or an empty buffer - the live editing
  # slot, always allowed) - nothing to skip.
  if [[ -z $BUFFER ]] || (( ${+_context_history_local_texts[$BUFFER]} )); then
    return 0
  fi

  # If the pre-state was already on a non-local entry, we have no
  # local position to revert to - just leave wherever the skip-loop
  # ends up. Otherwise (pre-state was local or empty) revert on
  # exhaustion so up-arrow stops at the last local position.
  local -i can_revert=0
  if [[ -z $pre_buffer ]] || (( ${+_context_history_local_texts[$pre_buffer]} )); then
    can_revert=1
  fi

  local -i prior_histno=-1 max_skip=10000
  while (( max_skip-- > 0 )); do
    if [[ -z $BUFFER ]] || (( ${+_context_history_local_texts[$BUFFER]} )); then
      return 0
    fi
    if (( HISTNO == prior_histno )); then
      # Boundary: zle couldn't advance further, but BUFFER is still
      # non-local. Treat as "no more local entries in this direction".
      if (( can_revert )); then
        BUFFER=$pre_buffer
        HISTNO=$pre_histno
        CURSOR=$pre_cursor
      fi
      return 0
    fi
    prior_histno=$HISTNO
    _context-history-call-original "$widget" "$@"
  done
  # Safety cap: same conditional revert as boundary.
  if (( can_revert )); then
    BUFFER=$pre_buffer
    HISTNO=$pre_histno
    CURSOR=$pre_cursor
  fi
}

#-------------------------------------------------------------------------------
# Toggle widget + keybind
#-------------------------------------------------------------------------------

function context-history-toggle-local() {
  if (( _context_history_local_mode )); then
    _context_history_local_mode=0
  else
    _context_history_local_mode=1
  fi
  _context-history-print-status
}
zle -N context-history-toggle-local

# Bind the toggle key if the user configured one. Unbound by default;
# users opt in via `zstyle ':contextual-history:*' local-toggle-key '^X^L'`
# (or whatever key they prefer).
if [[ -n $CONTEXTUAL_HISTORY_LOCAL_KEY ]]; then
  bindkey -M emacs "$CONTEXTUAL_HISTORY_LOCAL_KEY" context-history-toggle-local
  bindkey -M viins "$CONTEXTUAL_HISTORY_LOCAL_KEY" context-history-toggle-local
  bindkey -M vicmd "$CONTEXTUAL_HISTORY_LOCAL_KEY" context-history-toggle-local
fi
