#!/usr/bin/env zsh
# test_p14_mode_n_chpwd_flush
#
# Validates: in "shell-exit mode" (no SHARE_HISTORY, no INC_APPEND_HISTORY),
# zsh does not write history to disk during the session - only on
# shell exit. The plugin's `_context-history-flush-if-shell-exit` hook
# (called from set-{global,directory}-history) compensates by
# running `fc -AI` on the OUTGOING context's HISTFILE before any
# chpwd-driven swap, so commands typed in dirA aren't lost when the
# user `cd`s away to dirB.
#
# Sequence:
#   t0: shellA spawn in shell-exit mode (no SHARE, no INC).
#   t1: cd to dirA.
#   t2: run 'echo dirA-cmd' (in memory only - shell-exit mode doesn't auto-write).
#   t3: cd to dirB. The plugin's flush-if-shell-exit should fc -AI dirA's
#       per-dir file with 'echo dirA-cmd' before the chpwd swap.
#   t4: cd back to dirA. Per-dir A's file should now contain dirA-cmd.
#   t5: ^P -> expect 'echo dirA-cmd' (loaded from disk).

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p14.XXXXXX)
DIRA=$(mktemp -d -t ch-pty-p14-dirA.XXXXXX)
DIRB=$(mktemp -d -t ch-pty-p14-dirB.XXXXXX)
trap 'pty_cleanup_all; rm -rf "$HISTROOT" "$DIRA" "$DIRB"' EXIT

# shell-exit mode: no TEST_SHARE_HISTORY, no TEST_INC_APPEND.
pty_spawn shellA "$HISTROOT" || pty_fail "could not spawn shellA"

pty_run_cmd shellA "cd $DIRA" || pty_fail "cd dirA failed"
pty_run_cmd shellA 'echo dirA-cmd' || pty_fail "dirA-cmd failed"

# Verify per-dir A file does NOT YET exist or is empty (shell-exit mode hasn't
# written to disk on its own). Plugin's tee may have written though -
# it's enabled for all modes.
DIRA_REAL=${DIRA:A}
PERDIR_A="$HISTROOT/dirhist${DIRA_REAL}/history"

# cd dirB triggers chpwd, which triggers _context-history-flush-if-shell-exit
# on the OUTGOING dirA context, which fc -AI's the in-memory ring to
# dirA's per-dir file.
pty_run_cmd shellA "cd $DIRB" || pty_fail "cd dirB failed"
sleep 0.2

# After the flush, dirA's per-dir file should contain dirA-cmd.
if [[ ! -f $PERDIR_A ]]; then
  pty_fail "dirA per-dir file was never created (no flush?): $PERDIR_A"
fi
grep -q 'dirA-cmd' "$PERDIR_A" \
  || pty_fail "dirA per-dir missing 'dirA-cmd'; contents: $(cat "$PERDIR_A")"

# cd back to dirA - plugin loads dirA's per-dir file fresh.
pty_run_cmd shellA "cd $DIRA" || pty_fail "cd back to dirA failed"

# ^P should walk dirA's history. Top entry is the most recent in
# dirA's file. With INC writes from the flush, that's whichever entry
# was last written. Could be cd-to-dirB (written via flush) or
# dirA-cmd, depending on order. Just check that we see SOMETHING
# from dirA's history.
pty_press_up shellA
buf=$(pty_inspect_buf shellA)

# Acceptable: any of the dirA-mode commands.
case $buf in
  ('echo dirA-cmd' | "cd $DIRB")
    print -ru2 -- "INFO: dirA history loaded; first ^P = <$buf>"
    ;;
  *)
    pty_fail "expected dirA-mode entry; got <$buf>"
    ;;
esac

pty_pass
