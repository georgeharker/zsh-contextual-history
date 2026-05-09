#!/usr/bin/env zsh
# run_upstream_tests.zsh
#
# Runs a curated subset of the PTY suite against upstream
# jimhester/per-directory-history (cached in .upstream/) instead of
# the fork. Demonstrates -- in matrix form -- which bugs the fork
# fixes and which behaviours upstream gets right.
#
# For every test we list whether we EXPECT it to PASS or FAIL on
# upstream. EXPECT-FAIL means "this test asserts a fork-fixed
# behaviour; failing on upstream confirms the bug". A test that
# passes upstream when we expected FAIL means upstream changed (or
# our test is too lenient); a test that fails upstream when we
# expected PASS means basic per-dir is broken in unexpected ways.
#
# Usage:
#   ./run_upstream_tests.zsh
# Auto-fetches upstream if missing.

cd "${0:A:h}"

UPSTREAM_DIR="$PWD/.upstream"
UPSTREAM_PLUGIN="$UPSTREAM_DIR/per-directory-history.zsh"

if [[ ! -f $UPSTREAM_PLUGIN ]]; then
  print -ru2 -- "Fetching upstream into $UPSTREAM_DIR ..."
  mkdir -p "$UPSTREAM_DIR"
  curl -sSL https://raw.githubusercontent.com/jimhester/per-directory-history/master/per-directory-history.zsh \
       -o "$UPSTREAM_PLUGIN" \
    || { print -ru2 -- "fetch failed"; exit 2 }
fi

# Tests expected to FAIL on upstream -- each one asserts a fork-fixed
# behaviour. A FAIL is the bug being demonstrated.
EXPECTED_FAIL=(
  # SHARE_HISTORY same-context cross-shell merge is silently broken
  # (the headline "fc -p in addhistory hook is auto-popped" finding).
  test_p01_share_idle_visibility.zsh
  test_p04_multi_event_cross_shell.zsh
  test_p05_per_dir_cross_shell.zsh
  test_p13_concurrent_toggle.zsh
  test_p18_three_shell_share.zsh
  test_p19_toggle_no_dropped_entries.zsh
  test_p20_chpwd_concurrent_peer.zsh
  # Toggle to global doesn't reliably load the global file's
  # pre-populated content into the ring (additional issue surfaced
  # by running our matrix; upstream's `fc -R "$HISTFILE"` step in
  # set-global-history doesn't take effect as expected after the
  # empty-Enter resync our harness uses).
  test_p07_toggle_buffer_state.zsh
)

# Tests expected to PASS on upstream -- features upstream has too,
# no fork-specific behaviour required. Sanity baseline.
EXPECTED_PASS=(
  test_p02_first_prompt_up_arrow.zsh
  test_p03_walk_history.zsh
  test_p06_per_dir_isolation.zsh
  test_p08_no_share_isolation.zsh
  test_p09_inc_append_persistence.zsh
  test_p24_path_with_spaces.zsh
)

run_one() {
  local t=$1
  PTY_PLUGIN_PATH="$UPSTREAM_PLUGIN" \
    timeout 30 zsh "$t" 2>&1 | tail -1
}

typeset -i confirmed=0 surprises=0 unexpected_pass=0 unexpected_fail=0

print -ru1 -- "=== Upstream comparison: jimhester/per-directory-history ==="
print -ru1 -- "    plugin path: $UPSTREAM_PLUGIN"
print

print -ru1 -- "-- Tests expected to FAIL on upstream (fork-fixed behaviours) --"
for t in "${EXPECTED_FAIL[@]}"; do
  result=$(run_one "$t")
  case $result in
    (PASS\ *|*PASS*pass*)
      printf "  %-50s PASS  (UNEXPECTED -- upstream got this right?)\n" "$t"
      (( surprises++ ))
      (( unexpected_pass++ ))
      ;;
    (*)
      printf "  %-50s FAIL  (expected -- bug confirmed)\n" "$t"
      (( confirmed++ ))
      ;;
  esac
done
print

print -ru1 -- "-- Tests expected to PASS on upstream (sanity baseline) --"
for t in "${EXPECTED_PASS[@]}"; do
  result=$(run_one "$t")
  case $result in
    (PASS\ *|*PASS*pass*)
      printf "  %-50s PASS  (expected -- baseline ok)\n" "$t"
      (( confirmed++ ))
      ;;
    (*)
      printf "  %-50s FAIL  (UNEXPECTED -- baseline broken: %s)\n" "$t" "$result"
      (( surprises++ ))
      (( unexpected_fail++ ))
      ;;
  esac
done
print

print -ru1 -- "Summary: $confirmed expected outcome(s), $surprises surprise(s)"
if (( surprises > 0 )); then
  print -ru1 -- "  unexpected PASS (upstream may have been fixed): $unexpected_pass"
  print -ru1 -- "  unexpected FAIL (upstream baseline broken):     $unexpected_fail"
  exit 1
fi
exit 0
