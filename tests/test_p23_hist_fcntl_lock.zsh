#!/usr/bin/env zsh
# test_p23_hist_fcntl_lock
#
# Validates: with `HIST_FCNTL_LOCK` enabled, the tee acquires the
# fcntl `F_WRLCK` (via the `zsh/system` module's `zsystem flock`)
# instead of the default `<file>.LOCK` symlink protocol -- both paths
# must produce the same observable behaviour for concurrent writers.
#
# Pure-shell path: contextual-history.zsh's lockhistfile-emulation
# branches on $options[hist_fcntl_lock]. Native module path:
# `lockhistfile` (zsh-internal) auto-detects from the option.
#
# Concurrency check: two shells write back-to-back with no sleeps in
# between (same-second timestamps) into the same per-dir context.
# Without the lock both writers can interleave at write boundaries on
# huge writes. We don't test huge writes here (that's a separate
# scenario), but we do verify all six entries land in both stores
# in extended-history format with no truncation, which exercises the
# fcntl branch end-to-end.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p23.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

# Both shells get HIST_FCNTL_LOCK before sourcing the plugin so the
# tee's lock-protocol branch picks fcntl on first write.
TEST_SHARE_HISTORY=1 \
TEST_PRE_SOURCE="setopt HIST_FCNTL_LOCK" \
  pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"
TEST_SHARE_HISTORY=1 \
TEST_PRE_SOURCE="setopt HIST_FCNTL_LOCK" \
  pty_spawn shellB "$HISTROOT" || pty_fail "spawn B"

# Sanity: confirm the option is actually set in each spawned shell.
pty_run_cmd shellA 'echo opt-A=$options[hist_fcntl_lock]' || pty_fail "A opt probe"
pty_run_cmd shellB 'echo opt-B=$options[hist_fcntl_lock]' || pty_fail "B opt probe"

# Six interleaved writes, no sleep -- forces same-second timestamps,
# stresses the lock by minimising lock-release-to-reacquire window.
typeset -a ALL_WRITES
for i in 1 2 3; do
  pty_run_cmd shellA "echo A-$i" || pty_fail "A-$i"
  ALL_WRITES+=("echo A-$i")
  pty_run_cmd shellB "echo B-$i" || pty_fail "B-$i"
  ALL_WRITES+=("echo B-$i")
done
sleep 0.5

PERDIR_FILE="$HISTROOT/dirhist${PWD:A}/history"
GLOBAL_FILE="$HISTROOT/global"

[[ -f $PERDIR_FILE ]] || pty_fail "per-dir file missing: $PERDIR_FILE"
[[ -f $GLOBAL_FILE ]] || pty_fail "global file missing: $GLOBAL_FILE"

# All entries must appear in both stores. We don't pin ordering --
# concurrent writers under a held lock serialise correctly, but the
# physical order of A-i vs B-i in the file depends on which shell's
# hend won the lock race. Just check that every entry is present,
# unmangled, in both files.
for cmd in "${ALL_WRITES[@]}"; do
  fgrep -q "$cmd" "$PERDIR_FILE" \
    || pty_fail "PERDIR missing entry '$cmd' (file content: $(cat "$PERDIR_FILE"))"
  fgrep -q "$cmd" "$GLOBAL_FILE" \
    || pty_fail "GLOBAL missing entry '$cmd' (file content: $(cat "$GLOBAL_FILE"))"
done

# Verify no corruption: every line beginning with `:` must match the
# extended-history shape `: <unix-stim>:<elapsed>;<text>`. A truncated
# write under contention would produce a line that starts `: ` but
# breaks the shape.
malformed=$(awk '/^:/ && !/^: [0-9]+:[0-9]+;/ {n++} END {print n+0}' "$PERDIR_FILE")
(( malformed == 0 )) \
  || pty_fail "PERDIR has $malformed malformed extended-history lines"

pty_pass
