#!/usr/bin/env zsh
#
# This is a SHARE_HISTORY-compatible fork of jimhester/per-directory-history.
# It implements per directory history for zsh, as well as a
# per-directory-history-toggle-history function to change from using the
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
# PER_DIRECTORY_HISTORY_TOGGLE  - keybinding to toggle modes (default: ^G)
# PER_DIRECTORY_HISTORY_REFRESH_BEFORE_EXEC
#                               - if true, refresh in-memory history from the
#                                 active $HISTFILE via `fc -RI` BEFORE the ZLE
#                                 editing cycle begins each prompt (uses the
#                                 line-init hook). Means up-arrow, fzf-history,
#                                 and any other history-reading zle widgets
#                                 see the freshest view possible, including
#                                 writes from other terminals while this shell
#                                 was idle. mtime-gated so the steady-state
#                                 cost is one stat() per prompt. Default: true.
# PER_DIRECTORY_USE_MODULE      - if true, prepend the plugin's `module/`
#                                 directory to $module_path so the optional
#                                 native helper (built from module/ via its
#                                 Makefile) loads from the plugin tree
#                                 directly without a system install. The
#                                 plugin still works fine without this
#                                 (pure-shell fallback). Default: false.
# PER_DIRECTORY_HISTORY_GROUP_BY
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
# _per-directory-history-group  - resolver function. Returns (prints) a
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
# Copyright (c) 2014 Jim Hester
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

zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null

#-------------------------------------------------------------------------------
# configuration, the base under which the directory histories are stored
#-------------------------------------------------------------------------------

[[ -z $HISTORY_BASE ]] && HISTORY_BASE="$HOME/.directory_history"
[[ -z $HISTORY_START_WITH_GLOBAL ]] && HISTORY_START_WITH_GLOBAL=false
[[ -z $PER_DIRECTORY_HISTORY_TOGGLE ]] && PER_DIRECTORY_HISTORY_TOGGLE='^G'
[[ -z $PER_DIRECTORY_HISTORY_REFRESH_BEFORE_EXEC ]] && PER_DIRECTORY_HISTORY_REFRESH_BEFORE_EXEC=true
[[ -z $PER_DIRECTORY_USE_MODULE ]] && PER_DIRECTORY_USE_MODULE=false

# List of marker filenames to look for when walking up from $PWD. The
# resolver does ONE upward traversal; at each ancestor, it checks all
# patterns. The first ancestor that contains ANY of the patterns wins,
# and that ancestor becomes the group root. So "closest match wins" -
# pattern order only matters for same-ancestor tie-breaking.
#
# Recommended setting:
#   PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
#
# .histroot is a custom marker users can drop into a project root to
# explicitly mark "everything under here shares one history". Including
# both means a directory is grouped by its closest ancestor that has
# either marker - useful for groupings within projects (a vendored
# submodule's .git, or an explicit .histroot anywhere up the tree).
#
# Default: empty - every dir is its own group (original behaviour).
typeset -ga PER_DIRECTORY_HISTORY_GROUP_BY

# Stop points - paths above which walk-up should NOT cross. If walk-up
# reaches a stop point without finding any marker, the resolver falls back
# to ${PWD:A}. Useful to bound the search to e.g. $HOME so we don't pick
# up a stray marker in a parent of $HOME.
# Default: empty (walk all the way to /).
typeset -ga PER_DIRECTORY_HISTORY_GROUP_STOPS

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
#      PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot .git)
#      PER_DIRECTORY_HISTORY_GROUP_STOPS=($HOME)
#
#    The resolver walks $PWD upward ONCE. At each ancestor, if any of the
#    listed marker filenames exists, that ancestor is the group root.
#    Closest ancestor wins. If walk-up reaches a STOP path or / without
#    a hit, the resolver falls back to ${PWD:A}.
#
# 2. Full resolver override:
#      _per-directory-history-group() { ... ; print -r -- "$key" }
#
#    Redefine the resolver function entirely. It takes no args and prints
#    a canonical "group key" (typically a path) that determines which
#    per-dir history file is used.
#
# Example custom resolver:
#
#   _per-directory-history-group() {
#     local pwd=${PWD:A}
#     for root in /work/big-project /work/other-project; do
#       [[ $pwd == $root || $pwd == $root/* ]] && { print -r -- "$root"; return }
#     done
#     print -r -- "$pwd"
#   }

# Walk up from $PWD looking for any of the named markers. Print the first
# ancestor that contains any one of them, return 0. If walk-up reaches a
# stop point or / without a hit, return 1.
function _per-directory-history-walk-up() {
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
    for stop in "${PER_DIRECTORY_HISTORY_GROUP_STOPS[@]}"; do
      if [[ $d == ${stop:A} ]]; then
        return 1
      fi
    done
    d=${d:h}
  done
  return 1
}

# Default resolver. Single walk-up across all GROUP_BY markers; closest
# ancestor wins. Falls back to ${PWD:A} if no marker is found.
function _per-directory-history-group() {
  if (( ${#PER_DIRECTORY_HISTORY_GROUP_BY} > 0 )); then
    local result
    if result=$(_per-directory-history-walk-up "${PER_DIRECTORY_HISTORY_GROUP_BY[@]}"); then
      print -r -- "$result"
      return 0
    fi
  fi
  print -r -- "${PWD:A}"
}

# Compute the per-dir history file path from the resolver's group key.
# Centralised so chpwd, precmd init, and any future entry points use the
# same logic.
function _per-directory-history-resolve-file() {
  _per_directory_history_directory="$HISTORY_BASE$(_per-directory-history-group)/history"
}

#-------------------------------------------------------------------------------
# toggle global/directory history used for searching - ctrl-G by default
#-------------------------------------------------------------------------------

function per-directory-history-toggle-history() {
  if [[ $_per_directory_history_is_global == true ]]; then
    _per-directory-history-set-directory-history
    _per_directory_history_is_global=false
    zle -I
    echo "using local history"
  else
    _per-directory-history-set-global-history
    _per_directory_history_is_global=true
    zle -I
    echo "using global history"
  fi
}

autoload per-directory-history-toggle-history
zle -N per-directory-history-toggle-history
bindkey "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history
bindkey -M vicmd "$PER_DIRECTORY_HISTORY_TOGGLE" per-directory-history-toggle-history

#-------------------------------------------------------------------------------
# implementation details
#-------------------------------------------------------------------------------

# Capture the user's original $HISTFILE at plugin-load time. The original
# upstream plugin did not need this because it called `fc -p $per_dir_file`
# which silently mutated $HISTFILE; in "global" mode the upstream toggle
# would then read from $HISTFILE which had been reassigned to the per-dir
# file (so toggle to global actually showed per-dir contents \u2014 a bug).
# This fork keeps the user's original $HISTFILE on hand so we can swap back
# to it correctly when entering global mode.
_per_directory_history_global_histfile="$HISTFILE"

_per-directory-history-resolve-file

function _per-directory-history-change-directory() {
  _per-directory-history-resolve-file
  mkdir -p "${_per_directory_history_directory:h}"
  if [[ $_per_directory_history_is_global == false ]]; then
    _per-directory-history-set-directory-history
  fi
}

#-------------------------------------------------------------------------------
# Tee write coordination
#-------------------------------------------------------------------------------
#
# The tee in zshaddhistory writes one command to the *inactive* store (the
# file NOT currently named by $HISTFILE). zsh's native incremental writers
# (SHARE_HISTORY / INC_APPEND_HISTORY) acquire a file lock around their
# read+write window via lockhistfile() (Src/hist.c around line 3156).
#
# zsh's lockhistfile uses one of two protocols depending on the
# HIST_FCNTL_LOCK option:
#   - HIST_FCNTL_LOCK set: fcntl F_WRLCK (Src/hist.c flockhistfile, ~line 2857)
#   - default: `<file>.LOCK` symlink whose target encodes /pid-<pid>/host-<HOST>
#     with stale-detection by mtime > 10s
#
# We replicate the matching protocol so our tee coordinates with stock zsh's
# own SHARE/INC writers on the same file. Without this, a multi-write-syscall
# tee (e.g. a huge pasted blob) could interleave its bytes with another
# shell's SHARE write on the inactive file (typical case: a dir-mode shell
# tees to global while a global-mode shell SHARE-writes to global).
#
# On timeout we proceed lock-free rather than drop the entry - single-line
# single-syscall O_APPEND writes are still kernel-atomic, and losing a
# tee'd entry is strictly worse than briefly racing.
zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/files b:ln 2>/dev/null   # builtin ln avoids fork(2) per tee
zmodload zsh/system 2>/dev/null          # provides zsystem flock (fcntl)

# Optional native helper module: provides a `pdh-tee <file> <cmd>` builtin
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
# If PER_DIRECTORY_USE_MODULE=true we prepend this plugin's `module/` dir
# to $module_path first, so a make-built .so/.bundle from the source tree
# is discoverable without a system install. The directory is resolved
# from the running plugin's own path via `${(%):-%x}` (zsh's prompt-style
# expansion for "the file currently being sourced").
typeset -g _per_directory_history_have_native_tee=false
{
  if [[ $PER_DIRECTORY_USE_MODULE == true ]]; then
    local _pdh_self_dir=${${(%):-%x}:A:h}
    if [[ -d "$_pdh_self_dir/module" ]]; then
      module_path=("$_pdh_self_dir/module" $module_path)
    fi
  fi
  local _pdh_d _pdh_ext _pdh_found=
  for _pdh_d in $module_path; do
    for _pdh_ext in so bundle dylib; do
      if [[ -f "$_pdh_d/zsh/pdh.$_pdh_ext" ]]; then
        _pdh_found=1
        break 2
      fi
    done
  done
  if [[ -n $_pdh_found ]]; then
    if zmodload zsh/pdh 2>/dev/null; then
      _per_directory_history_have_native_tee=true
    fi
  fi
}

function _per-directory-history-tee-acquire-symlink-lock() {
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

function _per-directory-history-addhistory() {
  # respect hist_ignore_space
  if [[ -o hist_ignore_space ]] && [[ "$1" == \ * ]]; then
    return 0
  fi

  # Pick the inactive file. The active store is handled by zsh's native
  # incremental machinery (SHARE_HISTORY/INC_APPEND_HISTORY) at hend(), or
  # by exit-time save (mode N).
  local cmd="${1%%$'\n'}" file
  if [[ $_per_directory_history_is_global == true ]]; then
    file="$_per_directory_history_directory"
  else
    file="$_per_directory_history_global_histfile"
  fi
  mkdir -p "${file:h}"

  # Fast path: optional native helper handles lock + append + extended
  # format internally using zsh's own lockhistfile/unlockhistfile.
  if [[ $_per_directory_history_have_native_tee == true ]]; then
    pdh-tee "$file" "$cmd" 2>/dev/null
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
    if _per-directory-history-tee-acquire-symlink-lock "$lockfile"; then
      print -r -- "$payload" >> "$file"
      rm -f "$lockfile" 2>/dev/null
    else
      print -r -- "$payload" >> "$file"
    fi
  fi
  return 0
}

function _per-directory-history-precmd() {
  if [[ $_per_directory_history_initialized == false ]]; then
    _per_directory_history_initialized=true

    # Re-resolve in case the user redefined the resolver or set GROUP_BY
    # AFTER sourcing the plugin (the load-time call would have used the
    # default resolver). chpwd hasn't fired yet at this point so this is
    # the first chance to pick up user customisations.
    _per-directory-history-resolve-file

    if [[ $HISTORY_START_WITH_GLOBAL == true ]]; then
      _per-directory-history-set-global-history
      _per_directory_history_is_global=true
    else
      _per-directory-history-set-directory-history
      _per_directory_history_is_global=false
    fi
  fi
}

#-------------------------------------------------------------------------------
# Mode swap implementation
#-------------------------------------------------------------------------------
#
# We swap between "global mode" (HISTFILE = user's original) and "directory
# mode" (HISTFILE = per-dir file) by direct $HISTFILE assignment, then
# clearing in-memory and reloading the new file with `fc -R`.
#
# Why direct assignment, not `fc -p` / `fc -P`?
#
# zsh's `fc -p` and `fc -P` (push/pop hist-stack) are well-suited to
# isolating per-file `lasthist` state but `fc -P`'s implementation
# unconditionally invokes savehistfile's internal rewrite path
# (Src/hist.c savehistfile, around `if (... HFILE_SKIPOLD && !... HFILE_FAST
# && !... HFILE_NO_REWRITE)`) which truncates and rewrites the file in
# whatever extended-history setting the option currently has. Even though
# the rewrite preserves content, it (a) changes byte offsets, invalidating
# any concurrent reader's `lasthist.fpos`, and (b) drops timestamps if
# EXTENDED_HISTORY is off, also invalidating `lasthist.stim` matching.
#
# In multi-terminal SHARE_HISTORY scenarios the rewrite from one shell's
# toggle silently breaks the other shell's incremental merge - same shape
# as the s06 toggle bug, just via a different mechanism. There's no
# shell-level way to pass HFILE_NO_REWRITE to fc -P, so we cannot avoid
# the rewrite if we use these primitives.
#
# Direct `HISTFILE=newfile; HISTSIZE=0; HISTSIZE=$x; fc -R newfile` does
# NOT touch the file's bytes. The reuse of the same `lasthist` struct
# across HISTFILE swaps means SHARE_HISTORY's next merge on the new file
# may misposition once - but in practice the FAST short-circuit's stat
# comparison (lasthist.fsiz == sb.st_size && lasthist.mtim == sb.st_mtime)
# almost always fails after a swap, forcing a full read that re-establishes
# lasthist correctly via the per-entry update at savehistfile/readhistfile
# under HFILE_USE_OPTIONS. Cross-shell mid-session swaps remain a corner
# case; users who don't toggle/chpwd while another shell is reading the
# same file are unaffected.
#
# Mode interactions at the moment of swap:
#   Mode SHARE_HISTORY [+ INC_APPEND]: every command typed in the OUTGOING
#     dir was already incrementally written to that dir's file at hend()
#     time. Nothing pending; swap is just an in-memory + active-file
#     reposition.
#   Mode INC_APPEND only: same.
#   Mode N (neither incremental option): no incremental writes have
#     occurred. In-memory holds entries typed since the last load; the
#     HISTSIZE=0 wipe below would discard them. We mimic an exit-time save
#     of the OUTGOING file via `fc -AI` so those entries land in the per-dir
#     file of the dir they were typed in (see _per-directory-history-flush-if-mode-N).

# fc -AI flush gated to mode N. Two reasons it MUST stay gated:
#   (1) In modes SHARE/INC, entries are already on disk - fc -AI would be
#       redundant.
#   (2) fc -AI passes (HFILE_APPEND | HFILE_SKIPOLD) to savehistfile.
#       SKIPOLD set + FAST not set + NO_REWRITE not set fires savehistfile's
#       internal rewrite block (Src/hist.c lines 3082-3098), which truncates
#       and re-emits the entire file. The rewrite invalidates any concurrent
#       reader's `lasthist.fpos`/`lasthist.stim` tracking - in multi-shell
#       SHARE scenarios this silently breaks the other shell's incremental
#       merge (this was the s06 toggle bug, just reached via fc -AI rather
#       than fc -P). In mode N there's no concurrent SHARE merging by
#       definition, so the rewrite is harmless: any other mode-N shell only
#       re-reads the file at startup or exit, and the rewrite preserves
#       content (just normalises format to extended_history's option value).
function _per-directory-history-flush-if-mode-N() {
  if ! [[ -o share_history ]] \
     && ! [[ -o inc_append_history ]] \
     && ! [[ -o inc_append_history_time ]]; then
    fc -AI "$HISTFILE"
  fi
}

function _per-directory-history-set-directory-history() {
  _per-directory-history-flush-if-mode-N
  HISTFILE="$_per_directory_history_directory"
  # Clear the in-memory $history array (HISTSIZE=0 trick) before reloading
  # from the new active file, so the in-memory view is replaced rather than
  # appended to. zsh has no native "replace" mode for `fc -R`.
  local original_histsize=$HISTSIZE
  HISTSIZE=0
  HISTSIZE=$original_histsize
  if [[ -e "$HISTFILE" ]]; then
    fc -R "$HISTFILE"
  fi
}

function _per-directory-history-set-global-history() {
  _per-directory-history-flush-if-mode-N
  HISTFILE="$_per_directory_history_global_histfile"
  local original_histsize=$HISTSIZE
  HISTSIZE=0
  HISTSIZE=$original_histsize
  if [[ -e "$HISTFILE" ]]; then
    fc -R "$HISTFILE"
  fi
}

mkdir -p "${_per_directory_history_directory:h}"

#add functions to the exec list for chpwd and zshaddhistory
autoload -U add-zsh-hook
add-zsh-hook chpwd _per-directory-history-change-directory
add-zsh-hook zshaddhistory _per-directory-history-addhistory
add-zsh-hook precmd _per-directory-history-precmd

# Refresh in-memory history from the active $HISTFILE BEFORE each ZLE
# editing session begins (i.e. once per prompt, before any keystroke or
# zle widget runs). This means everything inside the editing cycle sees a
# fresh view: up-arrow, fzf-history-widget, custom history-reading
# widgets, and the eventual `history`/`fc -l`/`r` commands - all of them.
#
# We use the `line-init` hook (NOT `line-finish` - that fires AFTER all
# widgets have already run, so widgets would still see stale data). We
# register via `add-zle-hook-widget` which safely chains multiple
# registered widgets so we don't clobber other plugins' hooks.
#
# `fc -RI` reads only events not already in the in-memory history, so
# it's safe to call repeatedly without creating duplicates. Format and
# timestamps are handled transparently by zsh's native history reader
# (same EXTENDED_HISTORY semantics as the rest of the plugin).
#
# `fc -RI` does NOT internally short-circuit when the file is unchanged -
# it always reads + scans the entire file (~1ms per 5k entries on disk).
# We mtime-gate via `zstat` so the no-change steady state costs only one
# stat() syscall (~5us) instead of a full file scan per prompt.
#
# (For SHARE_HISTORY users this is partially redundant with hend's native
# merge - but that fires only when *this* shell hits Enter, so a fresh
# prompt sitting idle would have stale state for widgets until the user
# types something. Refreshing at line-init closes that gap.)
if [[ $PER_DIRECTORY_HISTORY_REFRESH_BEFORE_EXEC == true ]]; then
  zmodload -F zsh/stat b:zstat 2>/dev/null

  # Track the mtime of the active $HISTFILE we last read from. Initialised
  # lazily on first call.
  typeset -g _per_directory_history_last_mtime=""
  typeset -g _per_directory_history_last_histfile=""

  function _per-directory-history-line-init() {
    local cur_mtime=""
    zstat -A cur_mtime +mtime "$HISTFILE" 2>/dev/null

    # If $HISTFILE has changed (e.g. after mode toggle or chpwd) reset the
    # tracker so we don't compare against a stale value from another file.
    if [[ "$HISTFILE" != "$_per_directory_history_last_histfile" ]]; then
      _per_directory_history_last_histfile="$HISTFILE"
      _per_directory_history_last_mtime=""
    fi

    if [[ "$cur_mtime" != "$_per_directory_history_last_mtime" ]]; then
      fc -RI "$HISTFILE"
      _per_directory_history_last_mtime="$cur_mtime"
    fi
  }
  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-init _per-directory-history-line-init
fi

# set initialized flag to false
_per_directory_history_initialized=false
