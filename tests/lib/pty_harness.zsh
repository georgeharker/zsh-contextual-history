#!/usr/bin/env zsh
# PTY-based test harness for contextual-history.
#
# Provides turn-based multi-shell INTERACTIVE testing using zsh's built-in
# zpty module. Each spawned shell gets a unique marker prompt so we can
# synchronize on prompt-ready state without sleeps or races.
#
# Why this exists: the existing scripted-stdin tests (single_shell.zsh /
# multi_shell.zsh) pipe a script of commands into `zsh -i`; ZLE widgets
# never run because there's no real terminal. This harness gives us
# real ZLE: actual keystrokes (including escape sequences for arrow
# keys), observable BUFFER state, and per-shell turn ordering.
#
# Usage:
#   source ${0:A:h}/lib/pty_harness.zsh
#   HISTROOT=$(mktemp -d)
#   TEST_SHARE_HISTORY=1 pty_spawn shellA $HISTROOT
#   TEST_SHARE_HISTORY=1 pty_spawn shellB $HISTROOT
#   pty_run_cmd shellB 'echo from-B'
#   pty_press_up shellA
#   buf=$(pty_inspect_buf shellA)
#   [[ $buf == 'echo from-B' ]] || pty_fail "expected from-B, got <$buf>"
#   pty_pass

zmodload zsh/zpty 2>/dev/null \
  || { print -ru2 -- "FATAL: zsh/zpty module not available"; exit 1; }

# Plugin path - test scripts can override via env.
# This file lives at <repo>/tests/lib/pty_harness.zsh; the plugin is
# at <repo>/contextual-history.zsh - so strip 3 path components from
# the harness's file path (lib -> tests -> repo) to reach the repo
# root, then add the plugin filename.
: ${PTY_PLUGIN_PATH:=${0:A:h:h:h}/contextual-history.zsh}

# Per-shell state
typeset -gA _pty_zdotdirs   # shell-name -> ZDOTDIR
typeset -gA _pty_markers    # shell-name -> ready marker string

# How long pty_read_until waits for a pattern before giving up.
: ${PTY_READ_TIMEOUT:=10}

# --- internal helpers -------------------------------------------------------

# Build the rc files for a spawned shell. We need stronger isolation
# than the existing scripted-stdin tests because PTY tests depend on
# $PROMPT being a deterministic marker; the existing harness only
# observes file outputs post-mortem and doesn't care about PROMPT.
#
# Two-stage isolation:
#   1. The spawned shell is launched with `env -i HOME=$zdotdir
#      ZDOTDIR=$zdotdir ...` (see pty_spawn). This clears the parent's
#      env so the user's $HOME/.zshenv (and any zdot/oh-my-zsh init
#      it triggers) is not visible -- $HOME points at our scratch dir.
#   2. We write an empty .zshenv into $zdotdir as a belt-and-braces
#      measure: zsh always reads $ZDOTDIR/.zshenv (or $HOME/.zshenv if
#      ZDOTDIR is unset). With HOME=$zdotdir, both paths resolve to our
#      empty file - no user-level config can leak in.
#
# /etc/zshenv (if present) still runs but is typically empty/innocuous
# on macOS and Linux distros; we accept that as the unavoidable
# floor.
_pty_make_zshrc() {
  local name=$1 zdotdir=$2 histroot=$3
  local marker="_PTYRDY_${name}_"
  _pty_markers[$name]=$marker

  : > "$zdotdir/.zshenv"   # explicit empty - blocks any user .zshenv

  cat > "$zdotdir/.zshrc" <<RC
# Clean-room PTY test rc -- NO oh-my-zsh, NO plugin managers, NO user-level config.
setopt INTERACTIVE_COMMENTS

# Prompt: literal marker, no PROMPT_SP/CR cursor-positioning that would
# otherwise prepend ANSI escapes obscuring the marker in pty output.
unsetopt PROMPT_SUBST PROMPT_SP PROMPT_CR
PROMPT='${marker}\$ '
RPROMPT=''

# Force emacs keymap with deterministic bindings. With env -i, $EDITOR
# is empty so zsh's keymap auto-selection may produce inconsistent
# bindings across hosts; explicit bindkey -e gives us the same
# baseline everywhere.
bindkey -e

HISTFILE="$histroot/global"
HISTORY_BASE="$histroot/dirhist"
HISTSIZE=10000
SAVEHIST=10000

# Mode flags from caller environment.
[[ -n \${TEST_SHARE_HISTORY:-} ]] && setopt SHARE_HISTORY
[[ -n \${TEST_INC_APPEND:-}    ]] && setopt INC_APPEND_HISTORY
[[ -n \${TEST_EXTENDED:-}      ]] && setopt EXTENDED_HISTORY
[[ -n \${TEST_START_GLOBAL:-}  ]] && HISTORY_START_WITH_GLOBAL=true

CONTEXTUAL_HISTORY_USE_MODULE=\${CONTEXTUAL_HISTORY_USE_MODULE:-false}

source "$PTY_PLUGIN_PATH"

# Bind ^P/^N AFTER plugin source so the keymap binding resolves to
# our wrapper widget rather than the original builtin.
bindkey '^P' up-line-or-history
bindkey '^N' down-line-or-history

# Inspector widget bound to ^X. Prints BUFFER and HISTNO to stderr
# (visible in pty stream) without modifying ZLE state.
function _pty_debug_buffer() {
  print -ru2 -- "_PTYDBG_${name}_ BUFFER=<\$BUFFER> HISTNO=\$HISTNO"
  zle -M ""
}
zle -N _pty_debug_buffer
bindkey '^X' _pty_debug_buffer
RC
}

# Read from pty until pattern matches, or timeout. Returns matched
# output in $REPLY.
#
# Implementation: zpty has `-r -t` for non-blocking single-chunk read
# (returns rc=1 immediately when nothing's available) and `-r` (no -t)
# for blocking read up to a pattern. The plain pattern-blocking form
# has no timeout, so a missed pattern hangs forever. We poll in a loop:
# accumulate chunks via `-r -t`, check the running buffer against the
# pattern, sleep briefly if no match yet. Bounds the read by
# $PTY_READ_TIMEOUT so test failures surface within seconds, not hang
# the test runner.
_pty_read_until() {
  local name=$1 pat=$2 timeout=${3:-$PTY_READ_TIMEOUT}
  local accumulated="" chunk=""
  local deadline=$(( EPOCHSECONDS + timeout ))

  zmodload zsh/datetime 2>/dev/null   # for $EPOCHSECONDS
  zmodload zsh/zselect 2>/dev/null    # used for sleep

  while (( EPOCHSECONDS < deadline )); do
    if zpty -r -t $name chunk 2>/dev/null; then
      accumulated+="$chunk"
      if [[ $accumulated == ${~pat} ]]; then
        REPLY=$accumulated
        return 0
      fi
    else
      # No data right now - brief pause to avoid busy-loop.
      zselect -t 5 2>/dev/null || sleep 0.05
    fi
  done

  REPLY=$accumulated
  print -ru2 -- "TIMEOUT: pty_read_until($name, '$pat') after ${timeout}s; accumulated=<${(V)accumulated}>"
  return 1
}

# --- public API -------------------------------------------------------------

# Spawn a shell named NAME with isolated ZDOTDIR. HISTROOT is shared
# across all shells in a test (pass the same value to multiple spawns).
pty_spawn() {
  local name=$1 histroot=${2:?HISTROOT required}
  local zdotdir
  zdotdir=$(mktemp -d -t "ch-pty-${name}.XXXXXX")
  _pty_zdotdirs[$name]=$zdotdir
  _pty_make_zshrc "$name" "$zdotdir" "$histroot"

  # Spawn with full env scrubbing. HOME=$zdotdir so any .zshenv lookup
  # hits the empty file we wrote there, not the user's real $HOME.
  # PATH is minimal-but-functional (zsh + coreutils need to be found).
  # TERM=dumb keeps zsh's redraw simple; we don't render terminfo.
  # Forward the TEST_* opt selectors we care about, and any test-driver
  # vars (CONTEXTUAL_HISTORY_USE_MODULE for the native-helper toggle).
  zpty -b $name env -i \
    HOME="$zdotdir" \
    ZDOTDIR="$zdotdir" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TERM="xterm-256color" \
    SHELL="/bin/zsh" \
    USER="${USER:-test}" \
    TEST_SHARE_HISTORY="${TEST_SHARE_HISTORY:-}" \
    TEST_INC_APPEND="${TEST_INC_APPEND:-}" \
    TEST_EXTENDED="${TEST_EXTENDED:-}" \
    TEST_START_GLOBAL="${TEST_START_GLOBAL:-}" \
    CONTEXTUAL_HISTORY_USE_MODULE="${CONTEXTUAL_HISTORY_USE_MODULE:-false}" \
    CONTEXTUAL_HISTORY_DEBUG="${CONTEXTUAL_HISTORY_DEBUG:-false}" \
    zsh --no-globalrcs -i

  # Wait for first prompt
  local marker=${_pty_markers[$name]}
  _pty_read_until $name "*${marker}*" || return 1
}

# Send raw keystrokes (no automatic newline).
pty_send_keys() {
  local name=$1 keys=$2
  zpty -w -n $name "$keys"
}

# Send a command (text + Enter), wait for next prompt.
# Captured output is left in $REPLY.
pty_run_cmd() {
  local name=$1 cmd=$2
  local marker=${_pty_markers[$name]}
  zpty -w -n $name "$cmd"
  zpty -w -n $name $'\r'
  _pty_read_until $name "*${marker}*"
}

# Convenience for "up history" / "down history" / control characters.
# We use the emacs-keymap control-character bindings (^P for up,
# ^N for down) instead of the terminfo-dependent arrow-key escape
# sequences (\e[A / \e[B). Arrow keys require zsh to have loaded
# `terminfo[kcuu1]` and bound it via `bindkey`, which depends on the
# spawned shell having a terminfo entry for $TERM and the user's
# keymap setup; control-character bindings are unconditional.
pty_press_up()    { pty_send_keys "$1" $'\020'; }   # ^P = up-line-or-history
pty_press_down()  { pty_send_keys "$1" $'\016'; }   # ^N = down-line-or-history
pty_press_enter() { pty_send_keys "$1" $'\r'; }
pty_press_ctrlc() { pty_send_keys "$1" $'\003'; }
pty_press_ctrlu() { pty_send_keys "$1" $'\025'; }
pty_press_ctrlg() { pty_send_keys "$1" $'\007'; }   # ^G = context-history-toggle-history

# Inspect current BUFFER without executing OR modifying ZLE state.
# Sends ^X (debug widget), captures the line it prints, returns BUFFER
# content via stdout.
#
# Important: this does NOT clear BUFFER or reset history navigation.
# The debug widget intentionally does no ZLE state changes (no setline,
# no kill, no histline movement) so subsequent ^P / ^N continue from
# whatever history line was last loaded. If a test needs to reset for
# a fresh-prompt scenario, send ^U (pty_press_ctrlu) explicitly between
# steps -- but be aware that ^U bound to kill-whole-line clears BUFFER
# without resetting histline; for a true "back to fresh prompt" reset,
# send ^C (pty_press_ctrlc) which aborts the current ZLE session.
pty_inspect_buf() {
  local name=$1
  local pat="*_PTYDBG_${name}_ BUFFER=<*"
  zpty -w -n $name $'\030'   # ^X
  _pty_read_until $name "$pat" || return 1

  # Extract BUFFER=<...>. Last occurrence in case of leftover stream.
  local extracted=${REPLY##*BUFFER=<}
  extracted=${extracted%%>*}
  print -r -- "$extracted"
}

# Inspect HISTNO (uses same debug widget as inspect_buf). Returns the
# integer HISTNO. Note: also inspects BUFFER as a side effect (the
# widget prints both); use either one but typically not both for the
# same key-press cycle.
pty_inspect_histno() {
  local name=$1
  local pat="*_PTYDBG_${name}_ BUFFER=<*HISTNO=*"
  zpty -w -n $name $'\030'   # ^X
  _pty_read_until $name "$pat" || return 1

  local extracted=${REPLY##*HISTNO=}
  extracted=${extracted%%[!0-9]*}
  print -r -- "$extracted"

  zpty -w -n $name $'\025'   # ^U
}

# Cleanup ptys + their ZDOTDIRs. Safe to call with names that don't
# exist (e.g. from a trap on test failure).
pty_cleanup() {
  local name
  for name in "$@"; do
    zpty -d $name 2>/dev/null
    [[ -n ${_pty_zdotdirs[$name]:-} && -d ${_pty_zdotdirs[$name]} ]] \
      && rm -rf "${_pty_zdotdirs[$name]}"
    unset "_pty_zdotdirs[$name]" "_pty_markers[$name]"
  done
}

# Cleanup ALL spawned shells. Convenient for traps.
pty_cleanup_all() {
  pty_cleanup "${(@k)_pty_zdotdirs}"
}

# Test-result helpers - exit nonzero on failure with a clear marker so
# CI / wrapper scripts can grep for PASS/FAIL.
pty_fail() {
  print -ru2 -- "FAIL ${0:t}: $*"
  pty_cleanup_all
  exit 1
}

pty_pass() {
  print -ru2 -- "PASS ${0:t}"
  pty_cleanup_all
  exit 0
}
