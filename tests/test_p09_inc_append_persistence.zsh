#!/usr/bin/env zsh
# test_p09_inc_append_persistence
#
# Validates: with INC_APPEND_HISTORY (no SHARE), commands typed in shell
# A persist to the file, so a NEW shell A' (started after A exits) sees
# A's commands on up-arrow.
#
# Sequence:
#   t0: shellA spawns with INC_APPEND only.
#   t1: shellA runs cmd1, cmd2, cmd3 (each appends to file at hend).
#   t2: shellA cleanup (kill pty).
#   t3: shellA' spawns with same HISTROOT (same per-dir file).
#   t4: shellA' presses ^P -> expect cmd3 (latest from A's writes).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p09.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT"' EXIT

# INC_APPEND only (no SHARE).
TEST_INC_APPEND=1 pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

pty_run_cmd shellA 'echo inc-cmd1' || pty_fail "cmd1 run failed"
pty_run_cmd shellA 'echo inc-cmd2' || pty_fail "cmd2 run failed"
pty_run_cmd shellA 'echo inc-cmd3' || pty_fail "cmd3 run failed"

# Tear down shellA.
pty_cleanup shellA
sleep 0.1

# Spawn a new shell at same HISTROOT.
TEST_INC_APPEND=1 pty_spawn shellAprime "$HISTROOT" || pty_fail "could not spawn shellAprime"

pty_press_up shellAprime
buf=$(pty_inspect_buf shellAprime)
[[ $buf == 'echo inc-cmd3' ]] \
  || pty_fail "post-restart shellA' first ^P expected 'echo inc-cmd3', got <$buf>"

pty_pass
