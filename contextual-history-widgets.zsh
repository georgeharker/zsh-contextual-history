#!/usr/bin/env zsh
#
# contextual-history-widgets.zsh
#
# History-navigation widget wraps and the in-memory refresh impl that
# runs at widget-time. Sibling to the main plugin; auto-sourced.
#
# Why this is separated from the main plugin:
#
# The main plugin handles file-level concerns ($HISTFILE swap, tee,
# replace-ring, SHARE/INC compatibility, module loading). The widget
# wrap is a different concern: it sits between ZLE and the underlying
# history widgets so that history-navigation refreshes the ring from
# disk (mtime-gated) and so that feature files (local-history, fzf) can
# hook into a single dispatch path.
#
# What lives here:
#   _context-history-refresh-impl
#   _context-history-call-original
#   _context-history-wrap-impl
#   _context-history-wrap-widget
#   _context_history_orig_widgets  (state)
#   _context_history_last_mtime    (state)
#   CONTEXTUAL_HISTORY_WRAP_WIDGETS / wrap-widgets config
#   CONTEXTUAL_HISTORY_REFRESHING_WIDGETS / refreshing-widgets config
#   First-precmd hook to install wraps
#
# Required from the main plugin: _ch_resolve, _ch_resolve_arr, _ch_dbg,
# add-zsh-hook (autoloaded), and the variable
# _context_history_have_native_fast_refresh.
#
# Feature sibling files (contextual-history-keybinds.zsh,
# contextual-history-fzf.zsh) define skip functions named
# `_context-history-local-skip` etc. that wrap-impl calls via a
# function-existence check, so they can plug in without coupling to
# this file's internals.

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

_ch_resolve CONTEXTUAL_HISTORY_WRAP_WIDGETS wrap-widgets true

# Set of widgets to wrap. Configurable so users can extend (or shrink)
# the list. The wrap is idempotent, so calling wrap-widget with
# different lists between precmds is safe.
_ch_resolve_arr CONTEXTUAL_HISTORY_REFRESHING_WIDGETS refreshing-widgets \
  up-line-or-history down-line-or-history \
  up-line-or-search down-line-or-search \
  up-history down-history \
  history-search-backward history-search-forward \
  history-beginning-search-backward history-beginning-search-forward \
  history-incremental-search-backward history-incremental-search-forward

#-------------------------------------------------------------------------------
# Mtime-gated refresh
#-------------------------------------------------------------------------------
#
# zsh's SHARE_HISTORY only syncs cross-shell writes at command-end
# (`hend` calls readhistfile(HFILE_FAST|HFILE_USE_OPTIONS)). A shell
# idle at a fresh prompt has no hend pending, so writes from OTHER
# shells in the meantime aren't reflected in our in-memory ring -
# up-arrow walks a stale ring. We close that window by running
# `fc -RI` (mtime-gated) before delegating to the underlying widget.
#
# Without SHARE_HISTORY the user has explicitly chosen per-shell
# isolation, so refresh-impl is a no-op in that case.
#
# See tests/test_p01_share_idle_visibility.zsh (idle visibility) and
# test_p11/p12 (the 2-entry leak this can trigger) for the empirical
# contract.

typeset -g _context_history_last_mtime=""

function _context-history-refresh-impl() {
  # No-op without SHARE_HISTORY (user chose per-shell isolation).
  [[ -o share_history ]] || return 0

  # Mtime gate: if file hasn't changed since the last refresh we can
  # skip the fc -RI entirely. Steady-state cost is one stat() per
  # widget invocation.
  local cur_mtime=""
  zstat -A cur_mtime +mtime "$HISTFILE" 2>/dev/null
  [[ $cur_mtime == $_context_history_last_mtime ]] && return 0

  # Prefer the native fast-refresh builtin (HFILE_USE_OPTIONS|HFILE_FAST,
  # same readflags zsh's hend-merge uses) so newly loaded entries get
  # HIST_FOREIGN. `fc -RI` uses HFILE_SKIPOLD without HFILE_FAST, which
  # at Src/hist.c:2706-2708 sets HIST_OLD|HIST_READ but NOT HIST_FOREIGN
  # - so refreshing via `fc -RI` would launder the local/foreign axis
  # for any entry pulled in here, breaking the fzf widget's filter.
  if [[ $_context_history_have_native_fast_refresh == true ]]; then
    _ch_dbg "refresh-impl: mtime $_context_history_last_mtime -> $cur_mtime, fast-refresh ${HISTFILE}"
    contextual-history-fast-refresh "$HISTFILE" 2>/dev/null
  else
    _ch_dbg "refresh-impl: mtime $_context_history_last_mtime -> $cur_mtime, fc -RI ${HISTFILE} (native fast-refresh unavailable; HIST_FOREIGN will not survive this refresh)"
    fc -RI "$HISTFILE" 2>/dev/null
  fi
  _context_history_last_mtime=$cur_mtime

  # Off-by-one compensation: fc -RI's HFILE_SKIPOLD path leaves
  # `curline.histnum = curhist + 1` after a HIST_DUP free, so
  # histline=curhist names no event and quietgethist(histline)
  # silently returns NULL - up-arrow does nothing. Surfaces only at a
  # fresh prompt with empty BUFFER (HISTNO==HISTCMD); we nudge HISTNO
  # past the gap so set_histno's quietgethist(N+1) hits curline and
  # zle_setline aligns histline. In the non-bug path HISTNO+1 lands
  # on no event and set_histno is a no-op.
  if [[ -n ${WIDGET:-} && -z $BUFFER && $HISTNO -eq $HISTCMD ]]; then
    _ch_dbg "  compensate off-by-one: HISTNO $HISTNO -> $((HISTNO+1))"
    HISTNO=$((HISTNO + 1))
  fi
  return 0
}

#-------------------------------------------------------------------------------
# Dispatch + wrap impl
#-------------------------------------------------------------------------------
#
# Per-widget wrap functions (generated by wrap-widget below)
# call wrap-impl with the canonical widget name as their first arg.
# The name then drives dispatch (orig_widgets[name]) and the
# local-history filter scope check. Hard-coding the canonical name in
# each wrap function side-steps the case where another plugin
# (notably zsh-autosuggestions) re-binds our wrap under a renamed
# alias and dispatches into it through that alias - inside the call,
# $WIDGET is the alias, not the canonical name we wrapped.

# Map from wrapped widget -> dispatch target:
#   ".X"             -> dispatch via `zle .X` (canonical builtin alias;
#                        addzlefunction at Src/Zle/zle_thingy.c:281 installs
#                        ".X" as a TH_IMMORTAL thingy alongside "X" so the
#                        dot-prefix lookup always reaches the builtin even
#                        after `zle -N X` is used to override).
#   "user:funcname"  -> call funcname directly as a shell function (covers
#                        user widgets, including ones already wrapped by
#                        another plugin).
typeset -gA _context_history_orig_widgets

function _context-history-call-original() {
  local widget=$1; shift
  local target=${_context_history_orig_widgets[$widget]:-}
  case $target in
    user:*)
      "${target#user:}" "$@"
      ;;
    "")
      return 0
      ;;
    *)
      # `$target` is either ".X" (canonical builtin alias) or a user
      # widget name. `--` terminates zle option parsing so any `$@`
      # starting with `-` is treated as widget args.
      builtin zle "$target" -- "$@"
      ;;
  esac
}

function _context-history-wrap-impl() {
  local widget=$1; shift
  _ch_dbg "wrap $widget (pre: HISTNO=$HISTNO)"
  _context-history-refresh-impl
  # Snapshot pre-dispatch state so feature filters can choose to
  # revert (e.g. local-history's "no more local entries above" boundary).
  local _ch_pre_buffer=$BUFFER
  local -i _ch_pre_histno=$HISTNO _ch_pre_cursor=$CURSOR
  _context-history-call-original "$widget" "$@"
  local rc=$?
  # Feature sibling files plug their own filters in via these
  # function-existence checks. The widgets file doesn't need to know
  # which ones (if any) are loaded.
  (( ${+functions[_context-history-local-skip]} )) \
    && _context-history-local-skip "$widget" \
                                        "$_ch_pre_buffer" \
                                        "$_ch_pre_histno" \
                                        "$_ch_pre_cursor" \
                                        "$@"
  _ch_dbg "  $widget rc=$rc (post: HISTNO=$HISTNO BUFFER=${BUFFER:-(empty)})"
  return $rc
}

#-------------------------------------------------------------------------------
# Wrap installation
#-------------------------------------------------------------------------------
#
# Idempotent. Called once on first precmd from the hook below; safe to
# call again from user code after deferred plugin loads (zsh-defer
# etc.) that re-bind these widgets after our initial pass.
#
# We do NOT re-wrap on later precmds. If a plugin captures our wrap
# under a renamed alias (autosuggestions creates
# `autosuggest-orig-<widget>`) our wrap still runs through that alias
# because the per-widget wrap function hard-codes the canonical
# widget name. Re-wrapping on later precmds would create infinite
# recursion when our wrap dispatches to the bound widget, which
# dispatches back through the orig alias to our wrap.

function _context-history-wrap-widget() {
  local widget current wrap_fn
  _ch_dbg "wrap-widget: scanning ${#CONTEXTUAL_HISTORY_REFRESHING_WIDGETS[@]} widgets"
  for widget in "${CONTEXTUAL_HISTORY_REFRESHING_WIDGETS[@]}"; do
    current=${widgets[$widget]:-}
    wrap_fn="_context-history-wrap-${widget}"
    case $current in
      "")
        _ch_dbg "  $widget: missing - skip"
        ;;
      "user:$wrap_fn")
        _ch_dbg "  $widget: already wrapped - skip"
        ;;
      "builtin")
        _ch_dbg "  $widget: builtin - dispatch via zle .$widget"
        _context_history_orig_widgets[$widget]=".${widget}"
        eval "function $wrap_fn() { _context-history-wrap-impl ${(q)widget} \"\$@\" }"
        zle -N "$widget" "$wrap_fn"
        ;;
      "user:"*)
        _ch_dbg "  $widget: $current - call function directly"
        _context_history_orig_widgets[$widget]="$current"
        eval "function $wrap_fn() { _context-history-wrap-impl ${(q)widget} \"\$@\" }"
        zle -N "$widget" "$wrap_fn"
        ;;
      *)
        _ch_dbg "  $widget: unknown kind '$current' - skip"
        ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# First-precmd hook
#-------------------------------------------------------------------------------
#
# Installs the wraps on first precmd. By then all rc files have run
# and other plugins (zsh-autosuggestions, fzf, history-substring-
# search, ...) have registered their widgets, so our wrap layers on
# top of theirs (or under, if they load later; see above on why we
# don't re-wrap).

typeset -gi _context_history_widgets_installed=0

function _context-history-widgets-install() {
  (( _context_history_widgets_installed )) && return 0
  _context_history_widgets_installed=1
  [[ $CONTEXTUAL_HISTORY_WRAP_WIDGETS == true ]] || return 0
  _context-history-wrap-widget
}

add-zsh-hook precmd _context-history-widgets-install
