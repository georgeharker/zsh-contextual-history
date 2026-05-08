#!/usr/bin/env zsh
#
# This is a SHARE_HISTORY-compatible fork of jimhester/per-directory-history.
# It implements per directory history for zsh, as well as a
# context-history-toggle-history function to change from using the
# directory history to using the global history. In both cases the history is
# always saved to both the global history and the directory history, so the
# toggle state will not affect the saved histories.
#
# Unlike the original, this implementation never calls `fc -p` (which silently
# reassigns $HISTFILE in a way that breaks SHARE_HISTORY). Instead, it swaps
# $HISTFILE between two real files (the user's original global history file
# and the per-directory file) and lets native zsh history machinery
# (SHARE_HISTORY, INC_APPEND_HISTORY, fc) operate on whichever file $HISTFILE
# names. Cross-terminal synchronisation within the same directory therefore
# works for free, with zero per-prompt overhead.
#
#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
#
# HISTORY_BASE                  - base directory for per-directory histories
#                                 (default: $HOME/.directory_history)
# HISTORY_START_WITH_GLOBAL     - if true, start in global mode (default: false)
# CONTEXTUAL_HISTORY_TOGGLE  - keybinding to toggle modes (default: ^G)
# CONTEXTUAL_HISTORY_REFRESH_BEFORE_EXEC
#                               - if true (the default), wrap each history-
#                                 navigation widget (up-arrow, ↓,
#                                 history-search-*) so that just before it
#                                 reads `$history` we run `fc -RI` to merge
#                                 in any cross-shell writes that happened
#                                 while this shell was idle. Mtime-gated:
#                                 steady-state cost is one stat() per
#                                 widget invocation. Only meaningful when
#                                 SHARE_HISTORY is set; otherwise refresh
#                                 is a no-op (per-shell isolation
#                                 respected).
# CONTEXTUAL_HISTORY_USE_MODULE      - if true, prepend the plugin's `module/`
#                                 directory to $module_path so the optional
#                                 native helper (built from module/ via its
#                                 Makefile) loads from the plugin tree
#                                 directly without a system install. The
#                                 plugin still works fine without this
#                                 (pure-shell fallback). Default: false.
# CONTEXTUAL_HISTORY_GROUP_BY
#                               - array of marker filenames (e.g. (.git Cargo.toml
#                                 package.json)). When non-empty, the plugin
#                                 walks up from $PWD looking for any of these
#                                 markers; the first ancestor directory that
#                                 contains a match becomes the "group root"
#                                 whose per-dir history file is used. So all
#                                 directories under one project share one
#                                 history file. If no marker is found while
#                                 walking up to /, falls back to ${PWD:A}.
#                                 Default: () empty -> every dir is its own
#                                 group (original behaviour).
# _context-history-group  - resolver function. Returns (prints) a
#                                 canonical "group key" path that determines
#                                 which per-dir history file is used for the
#                                 current $PWD. Default uses GROUP_BY above
#                                 if set, else returns ${PWD:A}. Override
#                                 this function for fully custom grouping.
#
#-------------------------------------------------------------------------------
# History
#-------------------------------------------------------------------------------
#
# The idea/inspiration for a per directory history is from Stewart MacArthur[1]
# and Dieter[2], the implementation idea is from Bart Schaefer on the the zsh
# mailing list[3]. The original implementation is by Jim Hester in September
# 2012; this SHARE_HISTORY-compatible fork is from 2026.
#
# [1]: http://www.compbiome.com/2010/07/bash-per-directory-bash-history.html
# [2]: http://dieter.plaetinck.be/per_directory_bash
# [3]: http://www.zsh.org/mla/users/1997/msg00226.html
#
################################################################################
#
# Copyright (c) 2014 Jim Hester      -- original implementation
# Copyright (c) 2026 George Harker   -- contextual-history fork (this file)
#
# This is an ALTERED SOURCE VERSION of jimhester/per-directory-history,
# substantially reworked. Notable changes from the original include:
#   * SHARE_HISTORY compatibility (direct $HISTFILE swap instead of
#     `fc -p`/`fc -P`, which silently breaks SHARE's incremental merge);
#   * pre-init $HISTFILE swap so zsh's startup load populates the
#     correct file on first prompt (fixing first-up-arrow);
#   * configurable contextual grouping (GROUP_BY / GROUP_STOPS /
#     custom resolver function);
#   * lock-coordinated tee writes matching zsh's lockhistfile protocol;
#   * an optional native helper module (zsh/contextual_history) that
#     provides clean ring-replace and lock-coordinated tee builtins;
#   * a PTY-driven test suite covering the interactive scenarios.
#
# The original work's contribution - the chpwd/zshaddhistory hook
# structure and the global/local toggle widget - is preserved in shape.
#
# Released under the same zlib-style license as the original (terms
# below). Original notice retained verbatim per clause 3.
#
# This software is provided 'as-is', without any express or implied warranty.
# In no event will the authors be held liable for any damages arising from the
# use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions:
#
# 1. The origin of this software must not be misrepresented; you must not claim
# that you wrote the original software. If you use this software in a product,
# an acknowledgment in the product documentation would be appreciated but is
# not required.
#
# 2. Altered source versions must be plainly marked as such, and must not be
# misrepresented as being the original software.
#
# 3. This notice may not be removed or altered from any source distribution..
#
################################################################################

# zsh modules used throughout. Group at the top so it's clear what
# external machinery we depend on.
zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload -F zsh/files b:ln 2>/dev/null   # builtin ln avoids fork(2) per tee
zmodload zsh/system 2>/dev/null          # provides zsystem flock (fcntl)

# Debug helper. Set CONTEXTUAL_HISTORY_DEBUG=true to enable trace prints
# to stderr. Used liberally inside hooks and widgets but only emits
# when explicitly enabled, so default cost is one branch.
_ch_dbg() {
  [[ $CONTEXTUAL_HISTORY_DEBUG == true ]] && print -ru2 -- "[ch-dbg] $*"
}

#-------------------------------------------------------------------------------
# configuration, the base under which the directory histories are stored
#-------------------------------------------------------------------------------

[[ -z $HISTORY_BASE ]] && HISTORY_BASE="$HOME/.directory_history"
[[ -z $HISTORY_START_WITH_GLOBAL ]] && HISTORY_START_WITH_GLOBAL=false
[[ -z $CONTEXTUAL_HISTORY_TOGGLE ]] && CONTEXTUAL_HISTORY_TOGGLE='^G'
[[ -z $CONTEXTUAL_HISTORY_REFRESH_BEFORE_EXEC ]] && CONTEXTUAL_HISTORY_REFRESH_BEFORE_EXEC=true
[[ -z $CONTEXTUAL_HISTORY_USE_MODULE ]] && CONTEXTUAL_HISTORY_USE_MODULE=false

# List of marker filenames to look for when walking up from $PWD. The
# resolver does ONE upward traversal; at each ancestor, it checks all
# patterns. The first ancestor that contains ANY of the patterns wins,
# and that ancestor becomes the group root. So "closest match wins" -
# pattern order only matters for same-ancestor tie-breaking.
#
# Recommended setting:
#   CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git)
#
# .histroot is a custom marker users can drop into a project root to
# explicitly mark "everything under here shares one history". Including
# both means a directory is grouped by its closest ancestor that has
# either marker - useful for groupings within projects (a vendored
# submodule's .git, or an explicit .histroot anywhere up the tree).
#
# Default: empty - every dir is its own group (original behaviour).
typeset -ga CONTEXTUAL_HISTORY_GROUP_BY

# Stop points - paths above which walk-up should NOT cross. If walk-up
# reaches a stop point without finding any marker, the resolver falls back
# to ${PWD:A}. Useful to bound the search to e.g. $HOME so we don't pick
# up a stray marker in a parent of $HOME.
# Default: empty (walk all the way to /).
typeset -ga CONTEXTUAL_HISTORY_GROUP_STOPS

#-------------------------------------------------------------------------------
# Directory grouping
#-------------------------------------------------------------------------------
#
# A "group" determines which per-dir history file a given $PWD uses. By
# default each absolute directory is its own group (one history file per
# physical directory).
#
# Two layers of customisation:
#
# 1. Pattern-list config:
#      CONTEXTUAL_HISTORY_GROUP_BY=(.histroot .git)
#      CONTEXTUAL_HISTORY_GROUP_STOPS=($HOME)
#
#    The resolver walks $PWD upward ONCE. At each ancestor, if any of the
#    listed marker filenames exists, that ancestor is the group root.
#    Closest ancestor wins. If walk-up reaches a STOP path or / without
#    a hit, the resolver falls back to ${PWD:A}.
#
# 2. Full resolver override:
#      _context-history-group() { ... ; print -r -- "$key" }
#
#    Redefine the resolver function entirely. It takes no args and prints
#    a canonical "group key" (typically a path) that determines which
#    per-dir history file is used.
#
# Example custom resolver:
#
#   _context-history-group() {
#     local pwd=${PWD:A}
#     for root in /work/big-project /work/other-project; do
#       [[ $pwd == $root || $pwd == $root/* ]] && { print -r -- "$root"; return }
#     done
#     print -r -- "$pwd"
#   }

# Walk up from $PWD looking for any of the named markers. Print the first
# ancestor that contains any one of them, return 0. If walk-up reaches a
# stop point or / without a hit, return 1.
function _context-history-walk-up() {
  local d=${PWD:A}
  local target stop
  while [[ -n $d && $d != / ]]; do
    for target in "$@"; do
      if [[ -e "$d/$target" ]]; then
        print -r -- "$d"
        return 0
      fi
    done
    # Stop if THIS dir is a stop point (don't walk above stop points).
    for stop in "${CONTEXTUAL_HISTORY_GROUP_STOPS[@]}"; do
      if [[ $d == "${stop:A}" ]]; then
        return 1
      fi
    done
    d=${d:h}
  done
  return 1
}

# Default resolver. Single walk-up across all GROUP_BY markers; closest
# ancestor wins. Falls back to ${PWD:A} if no marker is found.
function _context-history-group() {
  if (( ${#CONTEXTUAL_HISTORY_GROUP_BY} > 0 )); then
    local result
    if result=$(_context-history-walk-up "${CONTEXTUAL_HISTORY_GROUP_BY[@]}"); then
      print -r -- "$result"
      return 0
    fi
  fi
  print -r -- "${PWD:A}"
}

# Compute the per-dir history file path from the resolver's group key.
# Centralised so chpwd, precmd init, and any future entry points use the
# same logic.
function _context-history-resolve-file() {
  _context_history_directory="$HISTORY_BASE$(_context-history-group)/history"
}

#-------------------------------------------------------------------------------
# toggle global/directory history used for searching - ctrl-G by default
#-------------------------------------------------------------------------------

function context-history-toggle-history() {
  if [[ $_context_history_is_global == true ]]; then
    _context-history-set-directory-history
    _context_history_is_global=false
    zle -I
    echo "using local history"
  else
    _context-history-set-global-history
    _context_history_is_global=true
    zle -I
    echo "using global history"
  fi
}

autoload context-history-toggle-history
zle -N context-history-toggle-history
bindkey "$CONTEXTUAL_HISTORY_TOGGLE" context-history-toggle-history
bindkey -M vicmd "$CONTEXTUAL_HISTORY_TOGGLE" context-history-toggle-history

#-------------------------------------------------------------------------------
# implementation details
#-------------------------------------------------------------------------------

# Capture the user's original $HISTFILE before we possibly reassign it
# below. Used by the toggle widget to swap back to "global" mode.
_context_history_global_histfile="$HISTFILE"

_context-history-resolve-file

# Pre-init $HISTFILE swap.
#
# zsh's init_misc reads $HISTFILE via readhistfile(NULL, 0,
# HFILE_USE_OPTIONS) (Src/init.c:1395) AFTER all rc files are sourced.
# So setting $HISTFILE here at plugin-load time tells zsh's startup
# load to populate the ring from the file we want:
#   * default (per-dir mode): $HISTFILE -> per-dir file.
#   * HISTORY_START_WITH_GLOBAL=true: leave $HISTFILE alone.
#
# This is the alternative to swapping AFTER zsh's load. Mid-session
# swaps (toggle / chpwd) cannot use this trick and have to do a
# pure-shell ring replacement, which has a documented 2-entry leak
# (test_p11 / test_p12). The pre-init path avoids that corruption on
# first prompt.
mkdir -p "${_context_history_directory:h}"
if [[ ${HISTORY_START_WITH_GLOBAL:-false} == true ]]; then
  _context_history_is_global=true
else
  _context_history_is_global=false
  HISTFILE="$_context_history_directory"
fi

function _context-history-change-directory() {
  _context-history-resolve-file
  mkdir -p "${_context_history_directory:h}"
  if [[ $_context_history_is_global == false ]]; then
    _context-history-set-directory-history
  fi
}

#-------------------------------------------------------------------------------
# Tee write coordination
#-------------------------------------------------------------------------------
#
# The tee in zshaddhistory writes one command to the *inactive* store
# (the file NOT currently named by $HISTFILE). zsh's native incremental
# writers (SHARE_HISTORY / INC_APPEND_HISTORY) acquire a file lock via
# lockhistfile() (Src/hist.c) which uses one of two protocols:
#   - HIST_FCNTL_LOCK set: fcntl F_WRLCK (flockhistfile)
#   - default: `<file>.LOCK` symlink whose target encodes
#     /pid-<pid>/host-<HOST>, with stale-detection by mtime > 10s.
#
# We replicate whichever protocol is in effect so our tee coordinates
# with stock zsh's own writers on the same file. Without this, a
# multi-write tee (e.g. a huge pasted blob) could interleave bytes
# with another shell's SHARE write. On timeout we proceed lock-free:
# single-line single-syscall O_APPEND is still kernel-atomic, and
# losing an entry to a dropped tee is strictly worse than briefly
# racing.

# Optional native helper module: provides a `contextual-history-tee <file> <cmd>` builtin
# that calls zsh's own lockhistfile/unlockhistfile + appends in extended
# format - same coordination as stock zsh's SHARE/INC writers, including
# automatic HIST_FCNTL_LOCK awareness. If not installed we fall back to
# the pure-shell paths below; behaviour is the same modulo the multi-write-
# syscall race that the native lock closes (rare; see module/README.md).
#
# zmodload of a missing module aborts the calling source/script (returns
# 126), even with stderr redirected. We probe the filesystem first so we
# only attempt to load when there's actually something to find.
#
# If CONTEXTUAL_HISTORY_USE_MODULE=true we prepend this plugin's `module/` dir
# to $module_path first, so a make-built .so/.bundle from the source tree
# is discoverable without a system install. The directory is resolved
# from the running plugin's own path via `${(%):-%x}` (zsh's prompt-style
# expansion for "the file currently being sourced").
typeset -g _context_history_have_native_tee=false
typeset -g _context_history_have_native_replace=false
{
  if [[ $CONTEXTUAL_HISTORY_USE_MODULE == true ]]; then
    local _ch_self_dir=${${(%):-%x}:A:h}
    if [[ -d "$_ch_self_dir/module" ]]; then
      module_path=("$_ch_self_dir/module" $module_path)
    fi
  fi
  local _ch_d _ch_ext _ch_found=
  for _ch_d in $module_path; do
    for _ch_ext in so bundle dylib; do
      if [[ -f "$_ch_d/zsh/contextual_history.$_ch_ext" ]]; then
        _ch_found=1
        break 2
      fi
    done
  done
  if [[ -n $_ch_found ]]; then
    if zmodload zsh/contextual_history 2>/dev/null; then
      # The module exposes its builtins atomically (all-or-nothing
      # via handlefeatures), so a successful zmodload means every
      # builtin in bintab[] is present. Both flags set together.
      _context_history_have_native_tee=true
      _context_history_have_native_replace=true
    fi
  fi
}

function _context-history-tee-acquire-symlink-lock() {
  # Matches lockhistfile()'s symlink path (Src/hist.c around line 3156) and
  # checklocktime() (line 3120). Returns 0 on acquire, 1 on timeout.
  local lockfile="$1"
  local lnk_target="/pid-$$/host-${HOST:-localhost}"
  local now end_time lock_mtime=""
  now=${EPOCHSECONDS:-$(date +%s)}
  end_time=$(( now + 10 ))

  while true; do
    if ln -s "$lnk_target" "$lockfile" 2>/dev/null; then
      return 0
    fi
    lock_mtime=""
    zstat -A lock_mtime +mtime "$lockfile" 2>/dev/null
    if [[ -z $lock_mtime ]]; then
      continue   # lock disappeared between symlink and stat
    fi
    now=${EPOCHSECONDS:-$(date +%s)}
    if (( now - lock_mtime > 10 )); then
      # Stale - clean up. Race-tolerant: other processes may also unlink.
      rm -f "$lockfile" 2>/dev/null
      continue
    fi
    if (( now >= end_time )); then
      return 1
    fi
    sleep 0.05
  done
}

function _context-history-addhistory() {
  # respect hist_ignore_space
  if [[ -o hist_ignore_space ]] && [[ "$1" == \ * ]]; then
    return 0
  fi

  # Pick the inactive file. The active store is handled by zsh's native
  # incremental machinery (SHARE_HISTORY/INC_APPEND_HISTORY) at hend(), or
  # by exit-time save (mode N).
  local cmd="${1%%$'\n'}" file
  if [[ $_context_history_is_global == true ]]; then
    file="$_context_history_directory"
  else
    file="$_context_history_global_histfile"
  fi
  mkdir -p "${file:h}"

  # Fast path: optional native helper handles lock + append + extended
  # format internally using zsh's own lockhistfile/unlockhistfile.
  if [[ $_context_history_have_native_tee == true ]]; then
    contextual-history-tee "$file" "$cmd" 2>/dev/null
    return 0
  fi

  # Pure-shell path: write extended format manually under a manually-acquired
  # lock matching zsh's protocol. SHARE_HISTORY's incremental writes force
  # extended_history=1 internally regardless of EXTENDED_HISTORY option
  # (Src/hist.c savehistfile, near `if (isset(SHAREHISTORY)) extended_history = 1`).
  # We treat EXTENDED_HISTORY as display-only and always store extended on
  # disk so the file format matches what stock zsh writers produce.
  local ts="${EPOCHSECONDS:-$(date +%s)}"
  local payload
  payload=$(printf ': %d:0;%s\n' "$ts" "$cmd")

  # Acquire the same lock zsh's lockhistfile uses, picking protocol from
  # HIST_FCNTL_LOCK. On timeout we proceed lock-free rather than drop the
  # entry - single-line single-syscall O_APPEND writes are still
  # kernel-atomic, and losing a tee'd entry is strictly worse.
  if [[ -o hist_fcntl_lock ]]; then
    local lock_fd=
    if zsystem flock -t 10 -f lock_fd "$file" 2>/dev/null; then
      print -r -- "$payload" >> "$file"
      zsystem flock -u $lock_fd 2>/dev/null
    else
      print -r -- "$payload" >> "$file"
    fi
  else
    local lockfile="$file.LOCK"
    if _context-history-tee-acquire-symlink-lock "$lockfile"; then
      print -r -- "$payload" >> "$file"
      rm -f "$lockfile" 2>/dev/null
    else
      print -r -- "$payload" >> "$file"
    fi
  fi
  return 0
}

function _context-history-precmd() {
  _ch_dbg "precmd fired (initialized=$_context_history_initialized)"
  if [[ $_context_history_initialized == false ]]; then
    _context_history_initialized=true

    # Re-resolve in case the user redefined the resolver or set GROUP_BY
    # AFTER sourcing the plugin (the load-time call would have used the
    # default resolver). chpwd hasn't fired yet at this point so this is
    # the first chance to pick up user customisations.
    _context-history-resolve-file

    # If the user customized GROUP_BY/GROUP_STOPS/the resolver between
    # plugin source-time and first precmd, the resolved per-dir path
    # may differ from what we set HISTFILE to at source-time. Call the
    # appropriate set-*-history; its skip-guard makes this a no-op
    # when HISTFILE already matches the target (the common case after
    # the source-time pre-init swap), and falls through to a swap
    # (with the documented 2-entry leak) otherwise.
    if [[ $_context_history_is_global == true ]]; then
      _context-history-set-global-history
    else
      _context-history-set-directory-history
    fi

    # Wrap history widgets ONCE, on first precmd. By now all rc files
    # have run and other plugins (zsh-autosuggestions, fzf,
    # history-substring-search, ...) have registered their widgets, so
    # our wrap layers on top of theirs.
    #
    # If you load plugins LATER (e.g. via zsh-defer) that redefine
    # these widgets, the wrap is lost - call
    # `_context-history-ensure-widget-wrap` from your deferred-load
    # hook to re-apply.
    if [[ $CONTEXTUAL_HISTORY_REFRESH_BEFORE_EXEC == true ]]; then
      _context-history-ensure-widget-wrap
    fi
  fi

  # No precmd-time refresh: ZLE isn't active here so the off-by-one
  # compensation can't run. Refresh is widget-time only.
}

#-------------------------------------------------------------------------------
# Mode swap implementation
#-------------------------------------------------------------------------------
#
# Swap between "global" and "directory" modes by direct $HISTFILE
# reassignment + ring replace + reload. We DO NOT use `fc -p`/`fc -P`:
# `fc -P` calls savehistfile's internal rewrite path (HFILE_SKIPOLD &&
# !HFILE_FAST), which truncates and rewrites the file. That changes
# byte offsets and invalidates any concurrent reader's lasthist.fpos -
# in multi-shell SHARE scenarios the rewrite silently breaks the other
# shell's incremental merge.
#
# Mode-N caveat: in mode N (no SHARE, no INC) commands typed in the
# outgoing dir have NOT yet been written to disk. Before any swap we
# call `fc -AI` on the outgoing $HISTFILE to flush them, so they land
# in the right per-dir file. This flush is gated to mode N because
# `fc -AI` triggers the same rewrite path that breaks SHARE readers
# (see flush-if-mode-N below).

# `fc -AI` writes the active in-memory ring to $HISTFILE. We MUST gate
# this to mode N: SHARE/INC users have already written incrementally
# (no flush needed), AND fc -AI's HFILE_APPEND|HFILE_SKIPOLD path
# triggers a file rewrite that breaks concurrent SHARE readers'
# lasthist tracking. Mode N has no concurrent SHARE writers/readers
# by definition, so the rewrite is harmless there.
function _context-history-flush-if-mode-N() {
  if ! [[ -o share_history ]] \
     && ! [[ -o inc_append_history ]] \
     && ! [[ -o inc_append_history_time ]]; then
    fc -AI "$HISTFILE"
  fi
}

# Replace the in-memory ring with the contents of $newfile.
#
# Pure-shell limitation: zsh's histsizesetfn (Src/params.c) clamps
# histsiz to a minimum of 2, so `HISTSIZE=0|1|2` all behave the same:
# trim ring to the 2 most-recent entries. Restoring HISTSIZE expands
# capacity but freed entries don't come back. After fc -R appends the
# new file, the ring contains [2 leftover entries from previous
# context, ..., new file events]. Documented in test_p11/test_p12;
# the native module's contextual-history-replace-ring builtin (when
# loaded) avoids the leak by walking hist_ring + freehistnode for
# every entry.
function _context-history-replace-ring() {
  local newfile=$1
  if [[ ${_context_history_have_native_replace:-false} == true ]]; then
    contextual-history-replace-ring "$newfile" 2>/dev/null
    return 0
  fi
  local original_histsize=$HISTSIZE
  HISTSIZE=2
  HISTSIZE=$original_histsize
  [[ -e $newfile ]] && fc -R "$newfile"
  return 0
}

function _context-history-set-directory-history() {
  # Skip if already active (common: source-time pre-init swap).
  [[ "$HISTFILE" == "$_context_history_directory" ]] && return 0
  _context-history-flush-if-mode-N
  HISTFILE="$_context_history_directory"
  _context_history_last_mtime=""
  _context-history-replace-ring "$HISTFILE"
}

function _context-history-set-global-history() {
  [[ "$HISTFILE" == "$_context_history_global_histfile" ]] && return 0
  _context-history-flush-if-mode-N
  HISTFILE="$_context_history_global_histfile"
  _context_history_last_mtime=""
  _context-history-replace-ring "$HISTFILE"
}

mkdir -p "${_context_history_directory:h}"

#add functions to the exec list for chpwd and zshaddhistory
autoload -U add-zsh-hook
add-zsh-hook chpwd _context-history-change-directory
add-zsh-hook zshaddhistory _context-history-addhistory
add-zsh-hook precmd _context-history-precmd

#-------------------------------------------------------------------------------
# In-memory history refresh: per-widget
#-------------------------------------------------------------------------------
#
# Why this exists: zsh's SHARE_HISTORY only syncs cross-shell writes at
# command-end (`hend` calls readhistfile(HFILE_FAST|HFILE_USE_OPTIONS)).
# A shell idle at a fresh prompt has no hend pending, so writes from
# OTHER shells in the meantime aren't reflected in our in-memory ring -
# up-arrow walks a stale ring. We close that window by wrapping the
# history-navigation widgets and running `fc -RI` (mtime-gated) before
# delegating to the original widget.
#
# Without SHARE_HISTORY the user has explicitly chosen per-shell
# isolation, so refresh-impl is a no-op in that case.
#
# See test_p01 (idle visibility) and test_p11/p12 (the leak this can
# trigger) for the empirical contract.
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

  _ch_dbg "refresh-impl: mtime $_context_history_last_mtime -> $cur_mtime, fc -RI ${HISTFILE}"
  fc -RI "$HISTFILE" 2>/dev/null
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

# Wrapper widget: refresh, then delegate to the original. Returns the
# original widget's exit status verbatim.
function _context-history-refreshing-widget() {
  local target=${_context_history_orig_widgets[$WIDGET]:-}
  _ch_dbg "widget $WIDGET -> $target (pre: HISTNO=$HISTNO)"
  _context-history-refresh-impl
  local rc=0
  case $target in
    user:*)
      "${target#user:}" "$@"
      rc=$?
      ;;
    "")
      rc=0
      ;;
    *)
      # `$target` is either ".X" (canonical builtin alias) or a user
      # widget name. `--` terminates zle option parsing so any `$@`
      # starting with `-` is treated as widget args.
      builtin zle "$target" -- "$@"
      rc=$?
      ;;
  esac
  _ch_dbg "  rc=$rc (post: HISTNO=$HISTNO BUFFER=${BUFFER:-(empty)})"
  return $rc
}
zle -N _context-history-refreshing-widget

# Set of widgets to wrap. Configurable so users can extend (or shrink)
# the list. The wrap is idempotent, so changing this array between
# precmds is safe.
typeset -ga CONTEXTUAL_HISTORY_REFRESHING_WIDGETS
[[ ${#CONTEXTUAL_HISTORY_REFRESHING_WIDGETS} -eq 0 ]] && \
  CONTEXTUAL_HISTORY_REFRESHING_WIDGETS=(
    up-line-or-history down-line-or-history
    up-line-or-search down-line-or-search
    up-history down-history
    history-search-backward history-search-forward
    history-beginning-search-backward history-beginning-search-forward
    history-incremental-search-backward history-incremental-search-forward
  )

# Re-apply the wrap on each precmd. Idempotent: if our wrapper is
# already in place for a widget, skip it. If another plugin has wrapped
# AFTER us, the widget's `widgets[]` entry now points at their function -
# we capture that as the new "user:funcname" original and our wrapper
# layers on top of theirs.
function _context-history-ensure-widget-wrap() {
  local widget current
  _ch_dbg "ensure-widget-wrap: scanning ${#CONTEXTUAL_HISTORY_REFRESHING_WIDGETS[@]} widgets"
  for widget in "${CONTEXTUAL_HISTORY_REFRESHING_WIDGETS[@]}"; do
    current=${widgets[$widget]:-}
    case $current in
      "")
        _ch_dbg "  $widget: missing - skip"
        ;;
      "user:_context-history-refreshing-widget")
        _ch_dbg "  $widget: already wrapped - skip"
        ;;
      "builtin")
        # Use the canonical immortal `.X` thingy zsh installs for every
        # builtin (Src/Zle/zle_thingy.c addzlefunction). The dot-prefix
        # always reaches the builtin even after `zle -N X` overrides X.
        _ch_dbg "  $widget: builtin - dispatch via zle .$widget"
        _context_history_orig_widgets[$widget]=".${widget}"
        zle -N "$widget" _context-history-refreshing-widget
        ;;
      "user:"*)
        # Call the underlying function directly (no nested `zle -N`
        # round-trip). If another plugin later overrides $widget via
        # `zle -N`, our dispatch via the function name is unaffected.
        _ch_dbg "  $widget: $current - call function directly"
        _context_history_orig_widgets[$widget]="$current"
        zle -N "$widget" _context-history-refreshing-widget
        ;;
      *)
        _ch_dbg "  $widget: unknown kind '$current' - skip"
        ;;
    esac
  done
}

# set initialized flag to false
_context_history_initialized=false
