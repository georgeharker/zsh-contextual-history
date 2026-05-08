#!/usr/bin/env zsh
# Minimal clean-room harness for testing per-directory-history behavior.
#
# Usage: harness.sh <plugin_path> <output_dir> <commands_file>
#
# Sets up an isolated ZDOTDIR with a minimal .zshrc that:
#   - sources the named plugin
#   - sets HISTFILE, HISTORY_BASE
#   - applies a controlled set of zsh options selected via TEST_* env vars
#   - enables INTERACTIVE_COMMENTS so commented test scripts work as stdin
#
# Runs an interactive zsh fed from <commands_file> via stdin and captures
# observations into <output_dir>.
#
# Env vars (set by the caller of this script to vary the scenario):
#   TEST_SHARE_HISTORY  if non-empty, runs `setopt SHARE_HISTORY`
#   TEST_INC_APPEND     if non-empty, runs `setopt INC_APPEND_HISTORY`
#   TEST_EXTENDED       if non-empty, runs `setopt EXTENDED_HISTORY`
#   TEST_START_GLOBAL   if non-empty, sets HISTORY_START_WITH_GLOBAL=true
#                       *before* the plugin is sourced
#   TEST_HISTROOT       if set, use this as HISTROOT instead of mktemp.
#                       This lets multiple harness invocations share the
#                       same HISTFILE / HISTORY_BASE so we can test
#                       cross-shell visibility.
#
# Outputs (in <output_dir>):
#   session.log       Interleaved stdout+stderr of the zsh session.
#   files_after.log   Contents of HISTFILE and all per-directory files
#                     after the session ended.
#   meta.log          ZDOTDIR + HISTROOT paths used (post-mortem inspection).

set -e

PLUGIN_PATH="$1"
OUTDIR="$2"
COMMANDS="$3"

mkdir -p "$OUTDIR"
# Resolve OUTDIR to an absolute path so test scripts can write into it from
# whatever directory the shell happens to be in.
OUTDIR="$(cd "$OUTDIR" && pwd)"
ZDOTDIR=$(mktemp -d -t pdh-zdotdir.XXXXXX)
HISTROOT="${TEST_HISTROOT:-$(mktemp -d -t pdh-hist.XXXXXX)}"
mkdir -p "$HISTROOT"

# Minimal .zshrc. Only the options selected by TEST_* env vars are set.
# INTERACTIVE_COMMENTS is forced on so test scripts can have # comments
# explaining each step without zsh trying to execute them as commands.
cat > "$ZDOTDIR/.zshrc" <<RC
# Clean-room test rc \u2014 NO oh-my-zsh, NO plugin managers, NO user-level config.
setopt INTERACTIVE_COMMENTS

HISTFILE="$HISTROOT/global_history"
HISTORY_BASE="$HISTROOT/dirhist"
HISTSIZE=10000
SAVEHIST=10000

# Options selected per-scenario by the harness caller.
[[ -n \${TEST_SHARE_HISTORY:-} ]] && setopt SHARE_HISTORY
[[ -n \${TEST_INC_APPEND:-}    ]] && setopt INC_APPEND_HISTORY
[[ -n \${TEST_EXTENDED:-}      ]] && setopt EXTENDED_HISTORY

# Plugin-level start-mode override.
[[ -n \${TEST_START_GLOBAL:-}  ]] && HISTORY_START_WITH_GLOBAL=true

# Forward the test driver's PER_DIRECTORY_USE_MODULE setting to the plugin
# so we can exercise both the pure-shell tee path and the native helper.
PER_DIRECTORY_USE_MODULE=\${PER_DIRECTORY_USE_MODULE:-false}

source "$PLUGIN_PATH"

# Snapshot helper used by command scripts to dump state at points of interest.
__obs() {
  local label="\$1"
  print -r -- "=== OBS: \$label ==="
  print -r -- "HISTFILE=\$HISTFILE"
  print -r -- "PWD=\$PWD"
  print -r -- "is_global=\${_per_directory_history_is_global:-unset}"
  print -r -- "pdh_dir=\${_per_directory_history_directory:-unset}"
  print -r -- "history (last 10):"
  fc -l -10 2>/dev/null || true
  print -r -- "---"
}
RC

# Run interactive zsh with scripted input. Capture stdout+stderr together so
# the chronological order of prompts, command output, and __obs dumps is
# preserved. PDH_HIST_OUT is forwarded so test scripts can redirect
# `history` output to a known absolute path inside OUTDIR.
ZDOTDIR="$ZDOTDIR" PDH_HIST_OUT="${PDH_HIST_OUT:-$OUTDIR/shell_history.out}" \
  zsh -i < "$COMMANDS" > "$OUTDIR/session.log" 2>&1 || true

# Snapshot files after the session has ended.
{
  echo "=== HISTFILE ($HISTROOT/global_history) ==="
  if [[ -f "$HISTROOT/global_history" ]]; then
    cat "$HISTROOT/global_history"
  else
    echo "(missing)"
  fi
  echo
  echo "=== per-directory files under $HISTROOT/dirhist ==="
  if [[ -d "$HISTROOT/dirhist" ]]; then
    find "$HISTROOT/dirhist" -type f -print | sort | while read -r f; do
      echo "--- $f ---"
      cat "$f"
    done
  else
    echo "(no dirhist tree)"
  fi
} > "$OUTDIR/files_after.log"

# Record where the temp dirs are so the caller can inspect them if needed.
{
  echo "ZDOTDIR=$ZDOTDIR"
  echo "HISTROOT=$HISTROOT"
  echo "TEST_SHARE_HISTORY=${TEST_SHARE_HISTORY:-}"
  echo "TEST_INC_APPEND=${TEST_INC_APPEND:-}"
  echo "TEST_EXTENDED=${TEST_EXTENDED:-}"
  echo "TEST_START_GLOBAL=${TEST_START_GLOBAL:-}"
  echo "PLUGIN=$PLUGIN_PATH"
  echo "COMMANDS=$COMMANDS"
} > "$OUTDIR/meta.log"
