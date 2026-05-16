#!/usr/bin/env zsh
# test_p30_foreign_tag_semantics
#
# Empirically pins down the L/F semantic that the fzf widget's
# local/all toggle uses. zsh's raw HIST_FOREIGN is "loaded via
# HFILE_FAST after shell start" - which leaves pre-existing on-disk
# entries (from any prior session, any shell) as non-foreign. The
# snapshot adds a startup-curhist baseline so the user-facing
# semantic is closer to "L = I typed this in THIS shell since it
# started; F = everything else":
#
#   1. Entries on disk before a shell starts -> F (pre-baseline).
#   2. Entries written by a peer shell AFTER our shell started -> F
#      (post-baseline AND HIST_FOREIGN from fast-refresh).
#   3. Pre-existing entries' classification is stable across refreshes.
#   4. This shell's own typing since startup -> L (post-baseline,
#      no HIST_FOREIGN).
#
# Requires the native module (for case 2 to exercise fast-refresh).
# Skips otherwise.

source "${0:A:h}/lib/pty_harness.zsh"

PLUGIN_DIR=${0:A:h:h}
MODULE_BUNDLE="$PLUGIN_DIR/module/zsh/contextual_history.bundle"
MODULE_SO="$PLUGIN_DIR/module/zsh/contextual_history.so"

if [[ ! -f $MODULE_BUNDLE && ! -f $MODULE_SO ]]; then
  print -ru2 -- "SKIP ${0:t}: native module not built (run \`cd module && make\`)"
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  print -ru2 -- "SKIP ${0:t}: fzf not on PATH"
  exit 0
fi
FZF_DIR=$(dirname "$(command -v fzf)")
TEST_PRE_SOURCE="path=(${(q)FZF_DIR} \$path)"

HISTROOT=$(mktemp -d -t ch-pty-p30.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

# Pre-populate the per-dir histfile with one "pre-startup" entry. The
# resolver uses cwd, which inside the PTY is set to the spawned
# shell's $zdotdir; we mirror that path layout below.
SPAWN_CWD_PROBE_SHELL=tmp
TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=true TEST_PRE_SOURCE="$TEST_PRE_SOURCE" \
  pty_spawn $SPAWN_CWD_PROBE_SHELL "$HISTROOT" || pty_fail "could not spawn probe"
pty_run_cmd $SPAWN_CWD_PROBE_SHELL 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not read probe HISTFILE"
histfile=${REPLY##*HISTFILE_IS=}
histfile=${histfile%%$'\r'*}
histfile=${histfile%%$'\n'*}
pty_cleanup $SPAWN_CWD_PROBE_SHELL

# Now seed the histfile and spawn the real test shell. Both shells in
# this test resolve to the same per-dir file because they share cwd
# (the harness sets HOME=$zdotdir; PWD at shell start is whatever the
# child inherited, which under env -i is `/`; per-dir context resolves
# off ${PWD:A} -> "/" -> a stable empty key, so both probe and test
# get the same histfile).
mkdir -p "${histfile:h}"
print -r -- ": $(date +%s):0;ENTRY-PREEXISTING" > "$histfile"

# Sleep to ensure the post-start injection's stim is strictly greater.
sleep 1

TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=true TEST_PRE_SOURCE="$TEST_PRE_SOURCE" \
  pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

# Sanity: shellA's HISTFILE should be the same path we seeded.
pty_run_cmd shellA 'print -r -- "HISTFILE_IS=$HISTFILE"' \
  || pty_fail "could not query shellA histfile"
shellA_histfile=${REPLY##*HISTFILE_IS=}
shellA_histfile=${shellA_histfile%%$'\r'*}
shellA_histfile=${shellA_histfile%%$'\n'*}
[[ $shellA_histfile == $histfile ]] \
  || pty_fail "shellA histfile <$shellA_histfile> != seeded <$histfile>"

# CASE 1 - entry that was on disk BEFORE shellA started. zsh itself
# doesn't mark it HIST_FOREIGN (startup load uses HFILE_USE_OPTIONS
# without HFILE_FAST), so `fc -li` shows it without `*`. But our
# snapshot's baseline filter classifies it as F because its histnum
# is <= startup_curhist (i.e. it was in the ring already at first
# precmd).
pty_run_cmd shellA "fc -li 1 > $HISTROOT/before.fc; _context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/before.snap" \
  || pty_fail "shellA initial dump failed"

# Raw zsh: no `*` on the pre-existing entry.
if grep -E '^[[:space:]]*[0-9]+\*.*ENTRY-PREEXISTING' "$HISTROOT/before.fc" >/dev/null; then
  print -ru2 -- "--- before.fc ---"
  cat "$HISTROOT/before.fc" >&2
  pty_fail "CASE 1a: pre-existing entry was tagged HIST_FOREIGN by zsh at startup (it shouldn't be)"
fi
# Snapshot: F via baseline filter (pre-existing entries aren't 'local' to this shell).
if ! awk -F'\t' '$1=="F" && $4=="ENTRY-PREEXISTING" {found=1} END {exit !found}' "$HISTROOT/before.snap"; then
  print -ru2 -- "--- before.snap ---"
  cat "$HISTROOT/before.snap" >&2
  pty_fail "CASE 1b: pre-existing entry not tagged F in snapshot (baseline filter)"
fi

# CASE 2 - entry written to disk by a peer AFTER shellA started.
# fast-refresh pulls it in via HFILE_FAST -> HIST_FOREIGN -> snapshot
# tags as F.
sleep 1
print -r -- ": $(date +%s):0;ENTRY-POSTSTART-PEER" >> "$histfile"
sleep 1
pty_run_cmd shellA "contextual-history-fast-refresh \$HISTFILE; fc -li 1 > $HISTROOT/after.fc; _context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/after.snap" \
  || pty_fail "shellA post-injection dump failed"

if ! grep -E '^[[:space:]]*[0-9]+\*.*ENTRY-POSTSTART-PEER' "$HISTROOT/after.fc" >/dev/null; then
  print -ru2 -- "--- after.fc ---"
  cat "$HISTROOT/after.fc" >&2
  pty_fail "CASE 2: post-start peer entry not foreign-tagged by fast-refresh"
fi
if ! awk -F'\t' '$1=="F" && $4=="ENTRY-POSTSTART-PEER" {found=1} END {exit !found}' "$HISTROOT/after.snap"; then
  print -ru2 -- "--- after.snap ---"
  cat "$HISTROOT/after.snap" >&2
  pty_fail "CASE 2: post-start peer entry not tagged F in snapshot"
fi

# CASE 3 - the pre-existing entry's classification is STABLE across
# fast-refresh. It stays F (pre-baseline, regardless of HIST_FOREIGN
# state on the underlying entry).
if ! awk -F'\t' '$1=="F" && $4=="ENTRY-PREEXISTING" {found=1} END {exit !found}' "$HISTROOT/after.snap"; then
  print -ru2 -- "--- after.snap ---"
  cat "$HISTROOT/after.snap" >&2
  pty_fail "CASE 3: pre-existing entry's F classification was unexpectedly changed by fast-refresh"
fi

# CASE 4 - a command typed BY shellA itself stays L (this is the bit
# the user wants verified - shellA's own typing isn't foreign).
pty_run_cmd shellA 'echo ENTRY-SHELL-A-OWN-TYPING' \
  || pty_fail "shellA local command failed"
pty_run_cmd shellA "_context-history-fzf-build-snapshot | tr '\\0' '\\n' > $HISTROOT/own.snap" \
  || pty_fail "shellA own-typing dump failed"
if ! awk -F'\t' '$1=="L" && $4=="echo ENTRY-SHELL-A-OWN-TYPING" {found=1} END {exit !found}' "$HISTROOT/own.snap"; then
  print -ru2 -- "--- own.snap ---"
  cat "$HISTROOT/own.snap" >&2
  pty_fail "CASE 4: shellA's own typed command not tagged L"
fi

pty_pass
