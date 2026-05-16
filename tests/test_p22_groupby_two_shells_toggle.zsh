#!/usr/bin/env zsh
# test_p22_groupby_two_shells_toggle
#
# Validates the resolver + mode toggle interaction across two shells:
#   * GROUP_BY=.git collapses sub-a and sub-b into the same project-
#     root per-dir file.
#   * Two shells in different subdirs of the same project share that
#     per-dir file via SHARE_HISTORY.
#   * One shell toggling to global mode doesn't break the project
#     per-dir file or the other shell's view of it.
#
# Configuration is via zstyle (no env-var fallback) so this also
# exercises the zstyle path under multi-shell SHARE conditions.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p22.XXXXXX)
PROJ=$(mktemp -d -t ch-pty-p22-proj.XXXXXX)
mkdir -p "$PROJ/.git" "$PROJ/sub-a" "$PROJ/sub-b"
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$PROJ"' EXIT

# Both shells get GROUP_BY=.git via zstyle (set pre-source by the
# harness's TEST_PRE_SOURCE hook).
TEST_SHARE_HISTORY=1 \
TEST_PRE_SOURCE="zstyle ':contextual-history:*' group-by .git" \
  pty_spawn shellA "$HISTROOT" \
  || pty_fail "spawn A"
TEST_SHARE_HISTORY=1 \
TEST_PRE_SOURCE="zstyle ':contextual-history:*' group-by .git" \
  pty_spawn shellB "$HISTROOT" \
  || pty_fail "spawn B"

pty_run_cmd shellA "cd $PROJ/sub-a" || pty_fail "A cd sub-a"
pty_run_cmd shellB "cd $PROJ/sub-b" || pty_fail "B cd sub-b"
sleep 0.3

# A writes in sub-a. Both shells share the project per-dir file
# (resolver collapses sub-a/sub-b under .git ancestor), so B should
# see A's write via SHARE.
pty_run_cmd shellA 'echo from-A-sub-a' || pty_fail "A from-sub-a"
sleep 1.1

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo from-A-sub-a' ]] \
  || pty_fail "B (in sub-b, same project): expected 'echo from-A-sub-a' via shared project per-dir, got <$buf>"
pty_press_ctrlu shellB

# A toggles to global mode and writes there.
pty_press_ctrlg shellA
sleep 0.2
buf=$(pty_inspect_buf shellA)
[[ -z $buf ]] || pty_fail "after-toggle BUFFER unexpectedly <$buf>"
pty_run_cmd shellA 'echo from-A-global-mode' || pty_fail "A global"
sleep 1.1

# B (still per-dir, project context) writes.
pty_run_cmd shellB 'echo from-B-sub-b' || pty_fail "B from-sub-b"
sleep 1.1

# B's ^P walk:
#   step1: 'echo from-B-sub-b' (B's own latest write)
#   step2: 'echo from-A-global-mode' (A's global-mode write,
#          tee'd into project per-dir as inactive store)
#   step3: 'echo from-A-sub-a' (A's earliest write)
pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo from-B-sub-b' ]] \
  || pty_fail "B step1 expected 'echo from-B-sub-b', got <$buf>"

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo from-A-global-mode' ]] \
  || pty_fail "B step2 expected 'echo from-A-global-mode' (tee'd to per-dir despite A in global), got <$buf>"

pty_press_up shellB
buf=$(pty_inspect_buf shellB)
[[ $buf == 'echo from-A-sub-a' ]] \
  || pty_fail "B step3 expected 'echo from-A-sub-a', got <$buf>"

# Verify project per-dir file resolved to the .git ancestor, not sub-b.
PROJ_REAL=${PROJ:A}
PROJECT_PERDIR="$HISTROOT/dirhist${PROJ_REAL}/history"
[[ -f $PROJECT_PERDIR ]] \
  || pty_fail "project-root per-dir file missing at $PROJECT_PERDIR"
SUB_B_PERDIR="$HISTROOT/dirhist${PROJ_REAL}/sub-b/history"
[[ ! -f $SUB_B_PERDIR ]] \
  || pty_fail "sub-b should NOT have its own per-dir file (group-by .git collapses it)"

pty_pass
