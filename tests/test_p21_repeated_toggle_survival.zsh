#!/usr/bin/env zsh
# test_p21_repeated_toggle_survival
#
# Validates: repeated mode toggles within a single shell don't drop
# entries, corrupt the ring, or break the tee. Five full toggle cycles
# (10 mode switches) with a write in each phase. After the run, both
# stores must contain every write that landed in the corresponding
# active store, in chronological order.
#
# This is a stress test for the ring-replace machinery (and the native
# module's clean-replace builtin when loaded). p07/p13 cover one
# toggle; this catches state accumulation bugs that only surface after
# many cycles.

source "${0:A:h}/lib/pty_harness.zsh"

HISTROOT=$(mktemp -d -t ch-pty-p21.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

TEST_SHARE_HISTORY=1 pty_spawn shellA "$HISTROOT" || pty_fail "spawn A"

# Five cycles. A starts in per-dir mode (default).
# Phase pattern per cycle i: write per-dir-i, toggle to global, write
# global-i, toggle back to per-dir.
typeset -a EXPECT_PERDIR EXPECT_GLOBAL
for ((i=1; i<=5; i++)); do
  cmd="echo perdir-$i"
  pty_run_cmd shellA "$cmd" || pty_fail "perdir-$i"
  EXPECT_PERDIR+=("$cmd")
  EXPECT_GLOBAL+=("$cmd")    # tee writes inactive (global) store too
  sleep 1.1

  pty_press_ctrlg shellA
  sleep 0.2
  buf=$(pty_inspect_buf shellA)
  [[ -z $buf ]] || pty_fail "cycle $i: BUFFER unexpectedly <$buf> after toggle-to-global"

  cmd="echo global-$i"
  pty_run_cmd shellA "$cmd" || pty_fail "global-$i"
  EXPECT_GLOBAL+=("$cmd")
  EXPECT_PERDIR+=("$cmd")    # tee writes inactive (per-dir) store
  sleep 1.1

  pty_press_ctrlg shellA
  sleep 0.2
  buf=$(pty_inspect_buf shellA)
  [[ -z $buf ]] || pty_fail "cycle $i: BUFFER unexpectedly <$buf> after toggle-to-per-dir"
done

# Verify both files contain every expected entry, in order.
PERDIR_FILE="$HISTROOT/dirhist${PWD:A}/history"
GLOBAL_FILE="$HISTROOT/global"

verify_order() {
  local label=$1 file=$2; shift 2
  local -a expected=("$@")
  local -a actual
  while IFS= read -r line; do
    case $line in
      (': '*':0;'*) actual+=("${line#*;}") ;;
    esac
  done < "$file"
  local i
  for ((i=1; i<=${#expected}; i++)); do
    [[ ${actual[$i]} == ${expected[$i]} ]] \
      || pty_fail "$label: position $i expected '${expected[$i]}', got '${actual[$i]}'"
  done
  (( ${#actual} >= ${#expected} )) \
    || pty_fail "$label: expected at least ${#expected} entries, got ${#actual}"
}

verify_order "PERDIR" "$PERDIR_FILE" "${EXPECT_PERDIR[@]}"
verify_order "GLOBAL" "$GLOBAL_FILE" "${EXPECT_GLOBAL[@]}"

pty_pass
