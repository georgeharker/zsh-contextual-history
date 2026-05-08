#!/usr/bin/env zsh
# Multi-shell concurrent test driver for per-directory-history.
#
# Spawns two interactive zsh processes against a shared HISTROOT and drives
# them via named FIFOs as stdin. Synchronisation is observation-based: each
# step ends with `echo MARKER-N` and the driver waits for that marker to
# appear in the shell's output log before issuing the next step.
#
# Usage: multishell.sh <plugin_path> <output_dir>
#
# Env vars:
#   TEST_SHARE_HISTORY   if non-empty, both shells run with SHARE_HISTORY
#   TEST_INC_APPEND      if non-empty, both shells run with INC_APPEND_HISTORY
#   TEST_EXTENDED        if non-empty, both shells run with EXTENDED_HISTORY
#
# Outputs (in <output_dir>):
#   shell1.log, shell2.log     full session output of each shell
#   driver.log                 timeline of what the driver did
#   files_after.log            HISTFILE + per-dir files after both shells exit
#   meta.log                   paths and env used
#
# Scenario currently exercised (the simplest case):
#   1. Each shell cd's to its configured test dir (S1_DIR / S2_DIR env vars,
#      both default to /tmp/pdh-mst-dirA i.e. same-directory case)
#   2. Shell 1 runs 6 echo commands
#   3. Shell 2 then runs `history` and we observe its output

set -e

PLUGIN_PATH="$1"
OUTDIR="$2"

mkdir -p "$OUTDIR"
# Resolve OUTDIR to an absolute path so commands run inside the shells (which
# may have `cd`'d to other directories) can still write into it.
OUTDIR="$(cd "$OUTDIR" && pwd)"
ZDOTDIR=$(mktemp -d -t pdh-mst-zdotdir.XXXXXX)
HISTROOT="${TEST_HISTROOT:-$(mktemp -d -t pdh-mst-hist.XXXXXX)}"
mkdir -p "$HISTROOT"
FIFODIR=$(mktemp -d -t pdh-mst-fifo.XXXXXX)

# Per-shell working directories (override via S1_DIR / S2_DIR env vars).
# Both default to the same dir, which is the cross-shell-visibility case.
S1_DIR="${S1_DIR:-/tmp/pdh-mst-dirA}"
S2_DIR="${S2_DIR:-/tmp/pdh-mst-dirA}"
mkdir -p "$S1_DIR" "$S2_DIR"

DRIVERLOG="$OUTDIR/driver.log"
SHELL1_LOG="$OUTDIR/shell1.log"
SHELL2_LOG="$OUTDIR/shell2.log"

# .zshrc shared by both shells. INTERACTIVE_COMMENTS so we can comment in
# command streams. PROMPT='' to avoid prompt noise polluting marker matches.
cat > "$ZDOTDIR/.zshrc" <<RC
setopt INTERACTIVE_COMMENTS

HISTFILE="$HISTROOT/global_history"
HISTORY_BASE="$HISTROOT/dirhist"
HISTSIZE=10000
SAVEHIST=10000

[[ -n \${TEST_SHARE_HISTORY:-} ]] && setopt SHARE_HISTORY
[[ -n \${TEST_INC_APPEND:-}    ]] && setopt INC_APPEND_HISTORY
[[ -n \${TEST_EXTENDED:-}      ]] && setopt EXTENDED_HISTORY

# Forward the test driver's PER_DIRECTORY_USE_MODULE setting to the plugin
# so we can exercise both the pure-shell tee path and the native helper.
PER_DIRECTORY_USE_MODULE=${PER_DIRECTORY_USE_MODULE:-false}

# Suppress prompt and right-prompt to keep marker grepping clean.
PROMPT=''
RPROMPT=''

source "$PLUGIN_PATH"
RC

# Make FIFOs for stdin to each shell.
mkfifo "$FIFODIR/shell1.in"
mkfifo "$FIFODIR/shell2.in"

drv() {
  # zsh's printf does not support the bash %(...)T strftime directive, so we
  # use the prompt-expansion form via `print -P`. %D{...} formats the current
  # date/time per strftime conventions.
  print -P "[%D{%H:%M:%S}] $*" >> "$DRIVERLOG"
}

drv "starting shell 1, log=$SHELL1_LOG"
drv "starting shell 2, log=$SHELL2_LOG"

# Spawn shells with the FIFOs as stdin. Each shell is launched in the
# background; we keep its FIFO open via a separate writer fd so the shell
# does not see EOF until we are ready to close it.
ZDOTDIR="$ZDOTDIR" zsh -i < "$FIFODIR/shell1.in" > "$SHELL1_LOG" 2>&1 &
SHELL1_PID=$!
ZDOTDIR="$ZDOTDIR" zsh -i < "$FIFODIR/shell2.in" > "$SHELL2_LOG" 2>&1 &
SHELL2_PID=$!

# Open writer fds so we can keep the FIFOs open across many command writes.
exec 3>"$FIFODIR/shell1.in"
exec 4>"$FIFODIR/shell2.in"

cleanup() {
  drv "cleanup: closing FIFOs and waiting for shells to exit"
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  wait "$SHELL1_PID" 2>/dev/null || true
  wait "$SHELL2_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for a marker line to appear in a log file. Polls every 50ms, up to
# 10 seconds. Looks for the marker as a substring (after stripping ANSI
# escapes) because prompt color codes can prepend text before our marker
# even when the marker is the only thing zsh's `echo` produced for that
# line.
wait_for_marker() {
  local logfile="$1" marker="$2" tries=0
  while (( tries < 200 )); do
    # Strip CSI sequences and OSC sequences before grepping. The macOS
    # Terminal.app prompt prepends a lot of these around its prompt.
    if sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\][^\x07]*(\x07|\x1b\\)//g' "$logfile" 2>/dev/null \
       | grep -q "$marker" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    tries=$(( tries + 1 ))
  done
  drv "TIMEOUT waiting for marker '$marker' in $logfile"
  return 1
}

# Send a step to a shell: write the command, then echo a marker, then wait
# for that marker to appear in the shell's log. Markers are zero-padded
# and globally unique so substring matches do not collide as the sequence
# advances (e.g. matching '1' would also match '10', '11', etc.).
SEQ=0
step() {
  local fd="$1" log="$2" cmd="$3"
  SEQ=$(( SEQ + 1 ))
  local mk
  mk=$(printf 'MK-%04d' "$SEQ")
  drv "step $SEQ -> fd=$fd: $cmd"
  printf '%s\n' "$cmd" >&"$fd"
  printf 'echo %s\n' "$mk" >&"$fd"
  wait_for_marker "$log" "$mk"
}

# Per-shell wrappers for clarity.
s1() { step 3 "$SHELL1_LOG" "$1"; }
s2() { step 4 "$SHELL2_LOG" "$1"; }

# === Initialisation: each shell cd's to its configured test dir. ===
s1 "cd $S1_DIR"
s2 "cd $S2_DIR"

# === Shell 1 runs its scripted commands. By default this is the canonical
# six-echo sequence used by the basic visibility scenarios. Override via the
# S1_CMDS env var, providing one command per line (literal newlines). ===
S1_CMDS="${S1_CMDS:-echo cmd-1
echo cmd-2
echo cmd-3
echo cmd-4
echo cmd-5
echo cmd-6}"

while IFS= read -r line; do
  [[ -z $line ]] && continue
  s1 "$line"
done <<<"$S1_CMDS"

# === Shell 2 dumps its in-memory history to a file. We use file
# redirection so the captured output is unambiguously the output of the
# `history` builtin, with no interleaving with prompts, command echoes,
# or the bracketing commands themselves. The driver reads
# $OUTDIR/shell2_history.out at the end as the canonical answer to
# "what does shell 2 see?".
SHELL2_HIST_OUT="$OUTDIR/shell2_history.out"
s2 "history > $SHELL2_HIST_OUT"

# === Wind down. Closing the FIFO writer fds gives the shells EOF on stdin
# which makes them exit cleanly. We deliberately do NOT step `exit` because
# the shell would terminate before emitting the marker, causing a spurious
# timeout.
drv "all driven steps done; releasing FIFO writers and waiting for shells"
exec 3>&-
exec 4>&-
wait "$SHELL1_PID" 2>/dev/null || true
wait "$SHELL2_PID" 2>/dev/null || true

# Snapshot files after both shells have exited.
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

{
  echo "ZDOTDIR=$ZDOTDIR"
  echo "HISTROOT=$HISTROOT"
  echo "FIFODIR=$FIFODIR"
  echo "S1_DIR=$S1_DIR"
  echo "S2_DIR=$S2_DIR"
  echo "TEST_SHARE_HISTORY=${TEST_SHARE_HISTORY:-}"
  echo "TEST_INC_APPEND=${TEST_INC_APPEND:-}"
  echo "TEST_EXTENDED=${TEST_EXTENDED:-}"
  echo "PLUGIN=$PLUGIN_PATH"
} > "$OUTDIR/meta.log"

drv "done"
