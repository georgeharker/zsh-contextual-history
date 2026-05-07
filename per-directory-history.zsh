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

_per_directory_history_directory="$HISTORY_BASE${PWD:A}/history"

function _per-directory-history-change-directory() {
  _per_directory_history_directory="$HISTORY_BASE${PWD:A}/history"
  mkdir -p "${_per_directory_history_directory:h}"
  if [[ $_per_directory_history_is_global == false ]]; then
    _per-directory-history-set-directory-history
  fi
}

function _per-directory-history-addhistory() {
  # respect hist_ignore_space
  if [[ -o hist_ignore_space ]] && [[ "$1" == \ * ]]; then
    return 0
  fi

  # The upstream plugin called `fc -p "$per_dir_file"` here, which pushed the
  # per-dir file onto zsh's history stack and made it the active $HISTFILE.
  # That broke SHARE_HISTORY: SHARE_HISTORY's prompt-time read of $HISTFILE
  # would then read from the per-dir file instead of the user's global file,
  # so cross-terminal global sync silently stopped working.
  #
  # Instead, we leave $HISTFILE alone (it points at whichever file the
  # current mode designates) and let zsh's native machinery write to it.
  # We tee a copy to the *inactive* store so toggling modes (or chpwd in
  # local mode) finds an up-to-date file without needing any reload work.
  local cmd="${1%%$'\n'}" file
  if [[ $_per_directory_history_is_global == true ]]; then
    file="$_per_directory_history_directory"
  else
    file="$_per_directory_history_global_histfile"
  fi
  mkdir -p "${file:h}"
  if [[ -o extended_history ]]; then
    local ts="${EPOCHSECONDS:-$(date +%s)}"
    printf ': %d:0;%s\n' "$ts" "$cmd" >> "$file"
  else
    printf '%s\n' "$cmd" >> "$file"
  fi
  # Returning 0 lets zsh handle the in-memory + active-$HISTFILE write
  # natively. SHARE_HISTORY / INC_APPEND_HISTORY work as the user configured
  # them because we never redirected zsh's history machinery away from the
  # active file.
  return 0
}

function _per-directory-history-precmd() {
  if [[ $_per_directory_history_initialized == false ]]; then
    _per_directory_history_initialized=true

    if [[ $HISTORY_START_WITH_GLOBAL == true ]]; then
      _per-directory-history-set-global-history
      _per_directory_history_is_global=true
    else
      _per-directory-history-set-directory-history
      _per_directory_history_is_global=false
    fi
  fi
}

function _per-directory-history-set-directory-history() {
  # The upstream plugin used `fc -p` to push the per-dir file as the active
  # history list, then relied on that to make searches see per-dir entries.
  # `fc -p` silently breaks SHARE_HISTORY by redirecting native machinery
  # away from the user's $HISTFILE.
  #
  # Instead we explicitly assign $HISTFILE to the per-dir file. Native zsh
  # then writes commands to the per-dir file (incrementally if SHARE_HISTORY
  # or INC_APPEND_HISTORY is set) and reads from it on each prompt. Multiple
  # terminals in the same directory share that file as their $HISTFILE, so
  # SHARE_HISTORY gives us cross-terminal same-directory sync for free.
  #
  # Before swapping, `fc -AI "$HISTFILE"` flushes any in-memory entries that
  # are new since the last incremental write to the *outgoing* $HISTFILE. With
  # SHARE_HISTORY/INC_APPEND_HISTORY set this is a near no-op because entries
  # were already flushed; without those options it preserves pending entries
  # that would otherwise be lost on the swap (shell-exit-like behavior).
  fc -AI "$HISTFILE"
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
  # See _per-directory-history-set-directory-history for the rationale on the
  # `fc -AI` flush, the explicit $HISTFILE assignment (vs upstream's `fc -p`),
  # and the HISTSIZE=0 clear.
  fc -AI "$HISTFILE"
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

# set initialized flag to false
_per_directory_history_initialized=false
