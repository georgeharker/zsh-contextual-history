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
# Configuration (summary)
#-------------------------------------------------------------------------------
#
# Each setting resolves env-var > zstyle > default. zstyle context is
# `:contextual-history:*`. Full descriptions, wire-up examples, and
# the design rationale live in README.md; this table is the in-source
# quick reference and is kept current with the code.
#
#   env-var                                | zstyle key            | default     | file
#   ---------------------------------------+-----------------------+-------------+----------
#   Core (this file)
#   HISTORY_BASE                           | history-base          | $HOME/.directory_history
#   HISTORY_START_WITH_GLOBAL              | start-with-global     | false
#   CONTEXTUAL_HISTORY_TOGGLE              | toggle-key            | ^G
#   CONTEXTUAL_HISTORY_USE_MODULE          | use-module            | false
#   CONTEXTUAL_HISTORY_FZF_INTEGRATION     | fzf-integration       | true        | (gate)
#   CONTEXTUAL_HISTORY_DEBUG               | debug                 | false
#   CONTEXTUAL_HISTORY_GROUP_BY            | group-by              | ()
#   CONTEXTUAL_HISTORY_GROUP_STOPS         | group-stops           | ()
#
#   Widget machinery (contextual-history-widgets.zsh)
#   CONTEXTUAL_HISTORY_WRAP_WIDGETS        | wrap-widgets          | true
#   CONTEXTUAL_HISTORY_REFRESHING_WIDGETS  | refreshing-widgets    | (nav widgets)
#
#   Local-history navigation filter (contextual-history-keybinds.zsh)
#   CONTEXTUAL_HISTORY_LOCAL_KEY           | local-toggle-key      | (unbound)
#   CONTEXTUAL_HISTORY_START_WITH_LOCAL    | start-with-local      | false
#   CONTEXTUAL_HISTORY_LOCAL_WIDGETS       | local-widgets         | (nav widgets - incremental)
#
#   fzf integration (contextual-history-fzf.zsh)
#   CONTEXTUAL_HISTORY_FZF_BIND_CTRL_R     | fzf-bind-ctrl-r       | false
#   CONTEXTUAL_HISTORY_FZF_VIEW            | fzf-default-view      | all
#   CONTEXTUAL_HISTORY_FZF_LOCAL_KEY       | fzf-toggle-local-key  | alt-l
#   CONTEXTUAL_HISTORY_FZF_ALL_KEY         | fzf-toggle-all-key    | alt-a
#   CONTEXTUAL_HISTORY_FZF_PROMPT_LOCAL    | fzf-prompt-local      | 'LOCAL> '
#   CONTEXTUAL_HISTORY_FZF_PROMPT_ALL      | fzf-prompt-all        | 'ALL> '
#   CONTEXTUAL_HISTORY_FZF_EXTRA_OPTS      | fzf-extra-opts        | ''
#
#   zsh-autosuggestions integration (contextual-history-autosuggest.zsh)
#   (no settings; opt in by adding `contextual_history` to
#    ZSH_AUTOSUGGEST_STRATEGY)
#
# For arbitrary grouping logic, override `_context-history-group`
# (a function returning the canonical group key on stdout).
#
#-------------------------------------------------------------------------------
# Relationship to upstream
#-------------------------------------------------------------------------------
#
# This is a SHARE_HISTORY-compatible fork of jimhester/per-directory-history,
# substantially reworked. The summary table at the top of INTERNALS.md
# enumerates the changes; the file as a whole walks through each.
# Highlights: direct $HISTFILE swap (not `fc -p`); pre-init swap for
# first-prompt correctness; configurable contextual grouping;
# lock-coordinated tee in extended-history format; optional native
# module; opt-in fzf widget; opt-in local-history navigation filter;
# scenario-based PTY test matrix.
#
# Original idea: Stewart MacArthur, Dieter, Bart Schaefer (zsh-users,
# 1997). Original implementation: Jim Hester, 2012. This fork: 2026.
#
################################################################################
#
# Copyright (c) 2014 Jim Hester      -- original implementation
# Copyright (c) 2026 George Harker   -- contextual-history fork (this file)
#
# ALTERED SOURCE VERSION of jimhester/per-directory-history. Released
# under the same zlib-style license as the original; original notice
# retained verbatim per clause 3.
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
zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS
zmodload -F zsh/stat b:zstat
zmodload -F zsh/files b:ln   # builtin ln avoids fork(2) per tee
zmodload zsh/system          # provides zsystem flock (fcntl)

_ch_dbg() {
  [[ $CONTEXTUAL_HISTORY_DEBUG == true ]] && print -ru2 -- "[ch-dbg] $*"
}

#-------------------------------------------------------------------------------
# configuration
#-------------------------------------------------------------------------------
#
# See the resolution table at the top of this file. The plugin reads
# only the canonical env-var-style variable internally, so the hot path
# stays a plain `$VAR` lookup.

_ch_resolve() {
  local varname=$1 key=$2 default=$3 val
  [[ -n ${(P)varname} ]] && return 0
  if zstyle -s ':contextual-history:*' "$key" val; then
    typeset -g "$varname=$val"
  else
    typeset -g "$varname=$default"
  fi
}

# Array resolver. Treats an empty array as "unset" (matches the user's
# intuition that `arr=()` means "don't override"). Remaining args after
# <key> are the default array.
_ch_resolve_arr() {
  local varname=$1 key=$2; shift 2
  [[ -n ${(P)varname} ]] && return 0
  local -a result
  typeset -ga "$varname"
  if zstyle -a ':contextual-history:*' "$key" result; then
    set -A "$varname" "${result[@]}"
  else
    set -A "$varname" "$@"
  fi
}

_ch_resolve HISTORY_BASE                      history-base       "$HOME/.directory_history"
_ch_resolve HISTORY_START_WITH_GLOBAL         start-with-global  false
_ch_resolve CONTEXTUAL_HISTORY_TOGGLE         toggle-key         '^G'
_ch_resolve CONTEXTUAL_HISTORY_USE_MODULE     use-module         false
_ch_resolve CONTEXTUAL_HISTORY_DEBUG          debug              false

# Note: CONTEXTUAL_HISTORY_WRAP_WIDGETS and
# CONTEXTUAL_HISTORY_REFRESHING_WIDGETS are resolved inside
# contextual-history-widgets.zsh, which is auto-sourced near the end
# of this file.

# Gate for the optional fzf integration file (contextual-history-fzf.zsh).
# Even when set to true, the fzf file is only sourced if `fzf` is on
# PATH at plugin source time. All fzf-widget-specific settings live in
# the fzf file itself and only matter when the integration loads.
_ch_resolve CONTEXTUAL_HISTORY_FZF_INTEGRATION fzf-integration   true

# Extra keybind-driven features (e.g. local-history navigation filter)
# live in contextual-history-keybinds.zsh, auto-sourced near the end
# of this file. Individual features remain inert unless the user sets
# their respective keybind zstyle.

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
_ch_resolve_arr CONTEXTUAL_HISTORY_GROUP_BY    group-by

# Stop points - paths above which walk-up should NOT cross. If walk-up
# reaches a stop point without finding any marker, the resolver falls back
# to ${PWD:A}. Useful to bound the search to e.g. $HOME so we don't pick
# up a stray marker in a parent of $HOME.
# Default: empty (walk all the way to /).
_ch_resolve_arr CONTEXTUAL_HISTORY_GROUP_STOPS group-stops

#-------------------------------------------------------------------------------
# Tracking sets - this shell's writes
#-------------------------------------------------------------------------------
#
# Two associative sets populated from the addhistory hook. Keyed
# differently because they're consulted at different points:
#
#   _context_history_local_writes : "${EPOCHSECONDS}:${cmd}" keys.
#     Used by the fzf widget's snapshot. Stim disambiguates against
#     peer same-text-different-second writes.
#
#   _context_history_local_texts  : "${cmd}" keys. Used by the
#     local-history navigation filter's per-keystroke O(1) lookup
#     ($history exposes text only, no stim per histnum).
#
# Stable across ring replacement (toggle, chpwd) - the keys are
# on-disk identity, not histnum (which gets reassigned on reload).
# See INTERNALS.md "The L/F semantic and the local-writes set" for
# the design discussion and the false-positive corner case.

typeset -gA _context_history_local_writes
typeset -gA _context_history_local_texts

# Captured at plugin source time. ${(%):-%x} evaluates to the path of
# the currently-being-sourced file; locking it into a global so
# helpers defined here can refer to the plugin dir regardless of
# where they're invoked from.
typeset -g _context_history_plugin_dir=${${(%):-%x}:A:h}

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
    for stop in "${CONTEXTUAL_HISTORY_GROUP_STOPS[@]}"; do
      if [[ $d == "${stop:A}" ]]; then
        return 1
      fi
    done
    d=${d:h}
  done
  return 1
}

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

function _context-history-resolve-file() {
  # Normalize the join so the result is well-formed regardless of
  # whether HISTORY_BASE has a trailing slash, or the resolver's key
  # has a leading slash, or the key is empty (which legitimately means
  # "all dirs collapse to one file").
  local key=$(_context-history-group)
  local base=${HISTORY_BASE%/}
  key=${key#/}
  if [[ -z $key ]]; then
    _context_history_directory="$base/history"
  else
    _context_history_directory="$base/$key/history"
  fi
}

#-------------------------------------------------------------------------------
# toggle global/directory history used for searching - ctrl-G by default
#-------------------------------------------------------------------------------

# Shared status print used by both toggle widgets so the user sees
# the full plugin state (both orthogonal axes) after flipping either
# axis:
#   - context-vs-global: which $HISTFILE the ring is loaded from.
#   - this-shell-vs-all: whether local-history filtering is on.
# Reads `_context_history_local_mode` defensively (`${var:-0}`) so this
# works even when the keybinds sibling isn't loaded.
function _context-history-print-status() {
  local context_axis local_axis
  if [[ $_context_history_is_global == true ]]; then
    context_axis="global"
  else
    context_axis="context"
  fi
  if (( ${_context_history_local_mode:-0} )); then
    local_axis="this-shell only (${#_context_history_local_texts} entries)"
  else
    local_axis="all shells"
  fi
  zle -I
  zle -M "history: $context_axis | $local_axis"
  # If zsh-autosuggestions is loaded, ask it to recompute the inline
  # suggestion now - otherwise it'd stay stale (computed against the
  # pre-toggle state) until the next keystroke. Defensive existence
  # check keeps the dependency soft.
  (( ${+widgets[autosuggest-fetch]} )) && zle autosuggest-fetch
}

function context-history-toggle-history() {
  if [[ $_context_history_is_global == true ]]; then
    _context-history-set-directory-history
    _context_history_is_global=false
  else
    _context-history-set-global-history
    _context_history_is_global=true
  fi
  _context-history-print-status
}

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

# Pre-init $HISTFILE swap: zsh reads $HISTFILE via readhistfile after
# rc files are sourced (init.c:1395), so setting $HISTFILE here
# lets zsh's startup load populate the ring from the per-dir file
# directly - no mid-session ring-replace needed for the first prompt,
# which side-steps the 2-entry leak (see _context-history-replace-ring
# below).
mkdir -p "${_context_history_directory:h}" 2>/dev/null
if [[ ${HISTORY_START_WITH_GLOBAL:-false} == true ]]; then
  _context_history_is_global=true
else
  _context_history_is_global=false
  HISTFILE="$_context_history_directory"
fi

function _context-history-change-directory() {
  _context-history-resolve-file
  mkdir -p "${_context_history_directory:h}" 2>/dev/null
  if [[ $_context_history_is_global == false ]]; then
    _context-history-set-directory-history
  fi
}

#-------------------------------------------------------------------------------
# Tee write coordination
#-------------------------------------------------------------------------------
#
# The tee writes one command to the *inactive* store (the file NOT
# currently named by $HISTFILE). zsh's incremental writers
# (SHARE_HISTORY / INC_APPEND_HISTORY) acquire a file lock via
# `lockhistfile()` using one of two protocols (fcntl if
# HIST_FCNTL_LOCK is set, symlink `<file>.LOCK` otherwise). We
# replicate whichever protocol is in effect so the tee serialises
# with stock zsh's own writers on the same file. Without this,
# multi-syscall tees (huge pasted blobs) can interleave with concurrent
# SHARE writes. On timeout we proceed lock-free: a single-syscall
# O_APPEND write is kernel-atomic, and losing the entry is worse
# than briefly racing. See INTERNALS.md "The tee: format and locking".

# Optional native helper: `contextual-history-tee` builtin uses
# zsh's own `lockhistfile`/`unlockhistfile` directly + appends in
# extended format - same coordination as SHARE/INC writers, including
# HIST_FCNTL_LOCK awareness. Pure-shell fallback below has the same
# behaviour modulo a rare multi-syscall race the native lock closes
# (see module/README.md). When use-module=true we prepend the
# plugin's ./module/ dir to $module_path so a built .so/.bundle from
# the source tree loads without a system install.
typeset -g _context_history_have_native_tee=false
typeset -g _context_history_have_native_replace=false
typeset -g _context_history_have_native_fast_refresh=false
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
      # builtin in bintab[] is present. All flags set together.
      _context_history_have_native_tee=true
      _context_history_have_native_replace=true
      _context_history_have_native_fast_refresh=true
    fi
  fi
}

# Build the optional native module the way fzf-tab builds its module:
# symlink our .c/.mdd into a zsh source tree's Src/Modules/ and let
# zsh's own module build system do the rest. configure scans the .mdd
# into config.modules; make generates the .mdh/.pro headers and
# compiles/links with the same DLCFLAGS/DLLDFLAGS zsh uses for its
# bundled dynamic modules - no hand-rolled platform flags.
#
# Usage: contextual-history-build-module [zsh-version]
#   zsh-version defaults to $CONTEXTUAL_HISTORY_ZSH_SRC_VERSION,
#   then the running zsh's $ZSH_VERSION.
function _context-history-build-module() {
  emulate -LR zsh -o extended_glob -o err_return

  local zsh_version=${1:-${CONTEXTUAL_HISTORY_ZSH_SRC_VERSION:-$ZSH_VERSION}}
  local module_home=$PWD

  # macOS: match the running zsh's module flavour (.bundle vs .so).
  local bundle nproc
  if [[ $OSTYPE == darwin* ]]; then
    [[ -n ${module_path[1]}/**/*.bundle(#qN) ]] && bundle=true
    nproc=$(sysctl -n hw.logicalcpu)
  else
    nproc=$(nproc)
  fi

  # A build tree left behind by the old tarball-based Makefile flow
  # has no .git - the git commands below would escape to whatever
  # repo contains the plugin. Replace it with a proper clone (it
  # needs reconfiguring anyway: its config.modules was generated
  # without our .mdd present).
  if [[ -d ./build/zsh-$zsh_version && ! -e ./build/zsh-$zsh_version/.git ]]; then
    print -ru2 -- "contextual-history-build-module: replacing pre-git build tree at $PWD/build/zsh-$zsh_version"
    rm -rf ./build/zsh-$zsh_version
  fi

  # Shallow-clone the release tag matching the running zsh.
  [[ -d ./build/zsh-$zsh_version ]] || {
    git clone --depth=1 --branch zsh-$zsh_version \
      https://github.com/zsh-users/zsh ./build/zsh-$zsh_version
  }

  # Our module source. Symlinked before configure so the .mdd is
  # scanned into config.modules.
  ln -sf $module_home/contextual_history.c   ./build/zsh-$zsh_version/Src/Modules/
  ln -sf $module_home/contextual_history.mdd ./build/zsh-$zsh_version/Src/Modules/

  cd -q ./build/zsh-$zsh_version

  git checkout -- .

  # zsh 5.9 needs two upstream fixes to build with modern toolchains
  # (same pair fzf-tab applies).
  [[ $zsh_version != "5.9" ]] || {
    curl -s https://github.com/zsh-users/zsh/commit/4c89849c98172c951a9def3690e8647dae76308f.patch | git apply --exclude=ChangeLog -
    curl -s https://github.com/zsh-users/zsh/commit/ab4d62eb975a4c4c51dd35822665050e2ddc6918.patch | git apply --exclude=ChangeLog -
  }

  [[ -f ./configure ]] || ./Util/preconfig
  [[ -f ./Makefile ]] || ./configure --disable-gdbm --disable-pcre \
    --without-tcsetpgrp --prefix=/tmp/zsh-contextual-history-module \
    ${bundle:+DL_EXT=bundle}
  make -j$nproc

  # Harvest to where the plugin (and tests) look for it:
  # module/zsh/contextual_history.<so|bundle>.
  mkdir -p $module_home/zsh
  mv ./Src/Modules/contextual_history.(so|bundle) $module_home/zsh/
}

function contextual-history-build-module() {
  {
    pushd -q "$_context_history_plugin_dir/module"
    if _context-history-build-module "$@"; then
      print -P "%F{green}%Bcontextual-history: module built. Restart zsh (or zmodload zsh/contextual_history) to use it.%f%b"
    else
      print -P -u2 "%F{red}%Bcontextual-history: module build failed. See the output above for details.%f%b"
      return 1
    fi
  } always {
    popd -q
  }
}

function _context-history-tee-acquire-symlink-lock() {
  # Matches lockhistfile()'s symlink path (Src/hist.c around line 3156) and
  # checklocktime() (line 3120). Returns 0 on acquire, 1 on timeout.
  local lockfile="$1"
  local lnk_target="/pid-$$/host-${HOST:-localhost}"
  local end_time=$(( EPOCHSECONDS + 10 ))
  local lock_mtime=""

  while true; do
    if ln -s "$lnk_target" "$lockfile" 2>/dev/null; then
      return 0
    fi
    lock_mtime=""
    zstat -A lock_mtime +mtime "$lockfile" 2>/dev/null
    if [[ -z $lock_mtime ]]; then
      continue   # lock disappeared between symlink and stat
    fi
    if (( EPOCHSECONDS - lock_mtime > 10 )); then
      # Stale - clean up. Race-tolerant: other processes may also unlink.
      rm -f "$lockfile" 2>/dev/null
      continue
    fi
    if (( EPOCHSECONDS >= end_time )); then
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
  # by exit-time save (shell-exit mode).
  local cmd="${1%%$'\n'}" file

  # Populate the two tracking sets (declared in the "Tracking sets"
  # block above) used by fzf and local-history for L/F classification.
  # ~5us combined, swamped by the existing tee printf below.
  _context_history_local_writes[${EPOCHSECONDS}:${cmd}]=1
  _context_history_local_texts[$cmd]=1

  if [[ $_context_history_is_global == true ]]; then
    file="$_context_history_directory"
  else
    file="$_context_history_global_histfile"
  fi

  # Fast path: optional native helper handles lock + append + extended
  # format internally using zsh's own lockhistfile/unlockhistfile. On
  # non-zero return, fall through to the pure-shell path rather than
  # silently drop the entry.
  if [[ $_context_history_have_native_tee == true ]]; then
    if contextual-history-tee "$file" "$cmd"; then
      return 0
    fi
  fi

  # Pure-shell path: extended-format write under zsh's own lock
  # protocol (fcntl or symlink, chosen by HIST_FCNTL_LOCK). We
  # ALWAYS write extended format because SHARE_HISTORY internally
  # forces it regardless of EXTENDED_HISTORY option, and mixed
  # formats on disk perturb the per-process lasthist tracker; treat
  # EXTENDED_HISTORY as display-only. Lock timeout -> proceed
  # lock-free (single-syscall O_APPEND is kernel-atomic).
  local locked=0 lock_fd= lockfile=
  if [[ -o hist_fcntl_lock ]]; then
    zsystem flock -t 10 -f lock_fd "$file" 2>/dev/null && locked=1
  else
    lockfile="$file.LOCK"
    _context-history-tee-acquire-symlink-lock "$lockfile" && locked=2
  fi
  printf ': %d:0;%s\n' "$EPOCHSECONDS" "$cmd" >> "$file"
  case $locked in
    1) zsystem flock -u "$lock_fd" 2>/dev/null ;;
    2) rm -f "$lockfile" 2>/dev/null ;;
  esac
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

    # Widget wraps install via their own first-precmd hook in
    # contextual-history-widgets.zsh; this hook doesn't need to do
    # anything for them.
  fi

  # No precmd-time refresh: ZLE isn't active here so the off-by-one
  # compensation can't run. Refresh is widget-time only.
}

#-------------------------------------------------------------------------------
# Mode swap implementation
#-------------------------------------------------------------------------------
#
# Direct $HISTFILE reassignment + ring replace + reload. We do NOT
# use `fc -p`/`fc -P` because `fc -P` triggers savehistfile's rewrite
# path, which truncates and rewrites the file out from under
# concurrent SHARE readers. See INTERNALS.md "Why fc -p / fc -P
# aren't an option" for the full trace; here just preserve the
# property that swaps never call `fc -P` against a shared file.
#
# `fc -AI` has the same rewrite-block hazard. We use it only in
# shell-exit mode (no SHARE, no INC) - the only mode where the
# in-memory ring needs a manual flush before the swap, AND the only
# mode where there are no concurrent SHARE readers to break.

function _context-history-flush-if-shell-exit() {
  if ! [[ -o share_history ]] \
     && ! [[ -o inc_append_history ]] \
     && ! [[ -o inc_append_history_time ]]; then
    fc -AI "$HISTFILE"
  fi
}

# Replace the in-memory ring with the contents of $newfile.
#
# Pure-shell limitation: zsh's `histsizesetfn` clamps `histsiz` to a
# minimum of 2, so the HISTSIZE=2; HISTSIZE=$orig; fc -R dance leaves
# 2 leftover entries from the previous context in the ring. Pinned
# by test_p11/test_p12. The native builtin's clean ring walk avoids
# this; see INTERNALS.md "The 2-entry ring-replace leak".
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
  _context-history-flush-if-shell-exit
  HISTFILE="$_context_history_directory"
  _context_history_last_mtime=""
  _context-history-replace-ring "$HISTFILE"
}

function _context-history-set-global-history() {
  [[ "$HISTFILE" == "$_context_history_global_histfile" ]] && return 0
  _context-history-flush-if-shell-exit
  HISTFILE="$_context_history_global_histfile"
  _context_history_last_mtime=""
  _context-history-replace-ring "$HISTFILE"
}

autoload -U add-zsh-hook
add-zsh-hook chpwd _context-history-change-directory
add-zsh-hook zshaddhistory _context-history-addhistory
add-zsh-hook precmd _context-history-precmd

#-------------------------------------------------------------------------------
# Auto-source the widgets sibling
#-------------------------------------------------------------------------------
#
# History-navigation widget wraps + mtime-gated refresh live in
# contextual-history-widgets.zsh. Sourced FIRST among the sibling
# files because the keybinds and fzf siblings depend on its wrap
# infrastructure (_context-history-call-original, the
# refresh-impl, the orig_widgets state map).
#
# Always-sourced when the file is present. The wrap-widgets switch
# and the refreshing-widgets list are zstyle-configurable inside
# that file; the wrap installation is gated on wrap-widgets=true
# (the default).

{
  local _ch_self_dir=${${(%):-%x}:A:h}
  local _ch_widgets_file="$_ch_self_dir/contextual-history-widgets.zsh"
  if [[ -f $_ch_widgets_file ]]; then
    source "$_ch_widgets_file"  # shuck: ignore=C002
  fi
}

_context_history_initialized=false

#-------------------------------------------------------------------------------
# Optional fzf integration
#-------------------------------------------------------------------------------
#
# The fzf widget, its config, and the auto-bind hook live in a
# sibling file so this entry point stays focused on the core
# history-swap / tee / share behaviour. The fzf file is sourced
# only when ALL of:
#   1. `fzf` is on PATH at plugin source time;
#   2. CONTEXTUAL_HISTORY_FZF_INTEGRATION / fzf-integration is true (default);
#   3. the sibling file exists alongside us.
# This avoids registering an unused widget for users who don't have
# fzf installed, and lets users opt out explicitly. Loader ordering
# (ensuring fzf is on PATH before this plugin is sourced) is the
# loader's responsibility - e.g. under zdot, the history module
# declares `--after-tool fzf`.

#-------------------------------------------------------------------------------
# Auto-source the keybinds sibling
#-------------------------------------------------------------------------------
#
# Extra keybind-driven features (local-history navigation filter today;
# room for more later) live in contextual-history-keybinds.zsh so
# this entry point stays focused on core history behaviour. Always-
# sourced when the file is present; individual features are inert
# unless their keybind zstyle is configured.

{
  local _ch_self_dir=${${(%):-%x}:A:h}
  local _ch_kb_file="$_ch_self_dir/contextual-history-keybinds.zsh"
  if [[ -f $_ch_kb_file ]]; then
    source "$_ch_kb_file"  # shuck: ignore=C002
  fi
}

#-------------------------------------------------------------------------------
# Auto-source the autosuggestions integration sibling
#-------------------------------------------------------------------------------
#
# zsh-autosuggestions strategy that mirrors our toggle state in the
# inline grey suggestion (lives in contextual-history-autosuggest.zsh).
# Always-sourced when the file is present. The strategy function is
# inert until the user opts in via `ZSH_AUTOSUGGEST_STRATEGY=(contextual_history)`.

{
  local _ch_self_dir=${${(%):-%x}:A:h}
  local _ch_as_file="$_ch_self_dir/contextual-history-autosuggest.zsh"
  if [[ -f $_ch_as_file ]]; then
    source "$_ch_as_file"  # shuck: ignore=C002
  fi
}

{
  # ${(%):-%x} expands to "the file currently being sourced" - i.e.
  # this file. :A:h takes its absolute parent dir.
  local _ch_self_dir=${${(%):-%x}:A:h}
  local _ch_fzf_file="$_ch_self_dir/contextual-history-fzf.zsh"

  if [[ ${CONTEXTUAL_HISTORY_FZF_INTEGRATION:-true} != true ]]; then
    _ch_dbg "fzf integration disabled by fzf-integration=false"
  elif ! command -v fzf >/dev/null 2>&1; then
    _ch_dbg "fzf integration skipped: fzf not on PATH"
  elif [[ ! -f $_ch_fzf_file ]]; then
    _ch_dbg "fzf integration skipped: $_ch_fzf_file not found"
  else
    source "$_ch_fzf_file"  # shuck: ignore=C002
  fi
}

