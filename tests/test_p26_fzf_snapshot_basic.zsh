#!/usr/bin/env zsh
# test_p26_fzf_snapshot_basic
#
# Validates the foundation of the fzf widget integration:
#   1. contextual-history-fast-refresh loads new on-disk entries with
#      HIST_FOREIGN set (`*` column in `fc -l` output).
#   2. _context-history-fzf-build-snapshot parses `fc -li 1` correctly
#      and emits L/F flags in column 1, tab-delimited.
#
# Single-shell scenario. A foreign entry is injected directly into the
# active histfile, then the fast-refresh builtin loads it. We
# deliberately inject BEFORE writing any local entries so the
# foreign-tagging path is exercised cleanly without colliding against
# same-second local writes (see the note on lasthist / SHARE-merge
# edge cases below).
#
# Requires the native module. Skips if not built.
#
# Note on the same-second edge case: when injected entries share a
# stim with the most recent local write, zsh's HFILE_FAST searching
# heuristic can mis-attribute previously-local entries on the next
# merge (whether from our fast-refresh or zsh's own SHARE-merge in
# hend). The fzf widget tolerates this in practice because the
# snapshot is rebuilt each invocation, but to keep this regression
# test focused on the L/F tagging path we sleep between injection and
# the subsequent SHARE merge so the stim ordering is unambiguous.

source "${0:A:h}/lib/pty_harness.zsh"

PLUGIN_DIR=${0:A:h:h}
MODULE_BUNDLE="$PLUGIN_DIR/module/zsh/contextual_history.bundle"
MODULE_SO="$PLUGIN_DIR/module/zsh/contextual_history.so"

if [[ ! -f $MODULE_BUNDLE && ! -f $MODULE_SO ]]; then
  print -ru2 -- "SKIP ${0:t}: native module not built (run \`cd module && make\`)"
  exit 0
fi

# The fzf integration file is only sourced when fzf is on PATH at
# plugin load (use-fzf gate + command -v fzf check). The PTY harness
# uses a scrubbed PATH; inject fzf's directory via TEST_PRE_SOURCE so
# the snapshot function is defined inside the test shell.
if ! command -v fzf >/dev/null 2>&1; then
  print -ru2 -- "SKIP ${0:t}: fzf not on PATH"
  exit 0
fi
FZF_DIR=$(dirname "$(command -v fzf)")
TEST_PRE_SOURCE="path=(${(q)FZF_DIR} \$path)"

HISTROOT=$(mktemp -d -t ch-pty-p26.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=true TEST_PRE_SOURCE="$TEST_PRE_SOURCE" \
  pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

# Capture the per-dir histfile path before any commands run; that way
# the histfile is empty on disk and our injection is the only entry.
pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not read HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
[[ -n $histfile ]] || pty_fail "could not determine histfile path: <$histfile>"

# Ensure the file's parent dir exists (plugin creates it on first
# command but we haven't written anything yet that triggers it).
mkdir -p "${histfile:h}"

# Inject a synthetic foreign entry. Using stim from `date -u +%s` so
# it's well past any prior writes in this shell (there are none yet,
# but we sleep before/after to keep the test deterministic in case
# anything in the shell's startup wrote a HIST_TMPSTORE entry).
sleep 1
inject_stim=$(date +%s)
print -r -- ": ${inject_stim}:0;echo injected-foreign-cmd" >> "$histfile"
sleep 1

# Now write one local command so we have a mix.
pty_run_cmd shellA 'echo local-cmd' || pty_fail "shellA local cmd"

# Trigger fast-refresh and dump fc -li + snapshot.
pty_run_cmd shellA "contextual-history-fast-refresh \$HISTFILE; fc -li 1 > $HISTROOT/fc-out; _context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/snap-out" \
  || pty_fail "fast-refresh + dump failed"

# Assertion 1: fc -li shows a foreign marker on the injected entry.
if ! grep -E '^[[:space:]]+[0-9]+\* .*echo injected-foreign-cmd' "$HISTROOT/fc-out" >/dev/null; then
  print -ru2 -- "--- fc-out ---"
  cat "$HISTROOT/fc-out" >&2
  pty_fail "fc -li did not show * on injected-foreign-cmd"
fi

# Assertion 2: fc -li shows NO foreign marker on the local entry.
if grep -E '^[[:space:]]+[0-9]+\* .*echo local-cmd' "$HISTROOT/fc-out" >/dev/null; then
  print -ru2 -- "--- fc-out ---"
  cat "$HISTROOT/fc-out" >&2
  pty_fail "local entry incorrectly marked foreign"
fi

# Assertion 3: snapshot has the F-tagged injection.
# awk avoids grep -P portability issues (macOS grep lacks PCRE).
if ! awk -F'\t' '$1=="F" && $4=="echo injected-foreign-cmd" {found=1} END {exit !found}' "$HISTROOT/snap-out"; then
  print -ru2 -- "--- snap-out ---"
  cat "$HISTROOT/snap-out" >&2
  pty_fail "snapshot missing F-tagged injected-foreign-cmd"
fi

# Assertion 4: snapshot has the L-tagged local entry.
if ! awk -F'\t' '$1=="L" && $4=="echo local-cmd" {found=1} END {exit !found}' "$HISTROOT/snap-out"; then
  print -ru2 -- "--- snap-out ---"
  cat "$HISTROOT/snap-out" >&2
  pty_fail "snapshot missing L-tagged local-cmd"
fi

pty_pass
