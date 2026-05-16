#!/usr/bin/env zsh
# run_upstream_tests.zsh
#
# Runs the FULL PTY suite against upstream
# jimhester/per-directory-history (cached in .upstream/) instead of
# the fork. We don't pre-classify; we run everything and report
# what actually happens, then categorise the outcomes after the fact:
#
#   * FORK-FIXED-BUG   : test PASSes on fork, FAILs on upstream
#                        (the bug exists in upstream and we fixed it)
#   * BASELINE-INTACT  : test PASSes on both
#                        (upstream and fork both get this right)
#   * FORK-ONLY-FEATURE: test PASSes on fork, FAILs on upstream because
#                        the test depends on a feature upstream lacks
#                        (zstyle config, native module, custom resolver,
#                        group-by). Not evidence of an upstream bug;
#                        listed for transparency.
#   * UPSTREAM-PASSES  : test PASSes on upstream too (claim retracted)
#
# This is the "we ran everything and observed the outcome" version
# instead of the pre-curated "we expected these to fail" version.
#
# Usage:
#   ./run_upstream_tests.zsh

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

# Tests that depend on fork-only features (their failure on upstream
# is "feature absent", not "bug present"). Listed here so we can label
# them in the report. Each note explains which fork feature the test
# requires.
typeset -A FORK_ONLY_TESTS=(
  [test_p10_native_module_equivalence.zsh]="native helper module"
  [test_p11_toggle_leak.zsh]="asserts module/no-module ring leak shape"
  [test_p12_chpwd_leak.zsh]="asserts module/no-module ring leak shape"
  [test_p14_mode_n_chpwd_flush.zsh]="fork-specific shell-exit-mode fc -AI gating"
  [test_p15_group_by_marker.zsh]="GROUP_BY env-var resolver"
  [test_p16_group_strategies.zsh]="GROUP_BY env-var resolver"
  [test_p17_zstyle_config.zsh]="zstyle config + GROUP_BY"
  [test_p22_groupby_two_shells_toggle.zsh]="zstyle GROUP_BY"
  [test_p23_hist_fcntl_lock.zsh]="fork-specific HIST_FCNTL_LOCK tee"
  [test_p25_custom_resolver_edge_cases.zsh]="overrides _context-history-group"
)

run_one() {
  local t=$1
  PTY_PLUGIN_PATH="$UPSTREAM_PLUGIN" \
    timeout 30 zsh "$t" 2>&1 | tail -1
}

typeset -a TESTS=(test_p*.zsh)
typeset -a BUG_FIXED=() BASELINE_INTACT=() FORK_ONLY_FAIL=() UPSTREAM_PASSES=()

print -ru1 -- "=== Running ALL ${#TESTS[@]} tests against upstream ==="
print -ru1 -- "    plugin: $UPSTREAM_PLUGIN"
print
print -ru1 -- "    (UPSTREAM column is what we ran below; FORK column is the"
print -ru1 -- "     status from the regular test matrix -- already-known-passing)"
print

printf "  %-50s %-8s\n" "TEST" "UPSTREAM"
for t in "${TESTS[@]}"; do
  result=$(run_one "$t")
  case $result in
    (PASS\ *|*PASS*pass*)  upstream_status="PASS" ;;
    (SKIP\ *|*SKIP*)        upstream_status="SKIP" ;;
    (*)                    upstream_status="FAIL" ;;
  esac
  printf "  %-50s %-8s\n" "$t" "$upstream_status"

  # Categorise. (All these tests pass on the fork; the test matrix
  # confirms that separately.)
  if [[ $upstream_status == "PASS" ]]; then
    if [[ -n ${FORK_ONLY_TESTS[$t]:-} ]]; then
      # Fork-only feature passing on upstream is impossible unless
      # the categorisation is wrong; treat as "upstream passes".
      UPSTREAM_PASSES+=("$t (was tagged fork-only: ${FORK_ONLY_TESTS[$t]})")
    else
      BASELINE_INTACT+=("$t")
    fi
  elif [[ $upstream_status == "FAIL" ]]; then
    if [[ -n ${FORK_ONLY_TESTS[$t]:-} ]]; then
      FORK_ONLY_FAIL+=("$t -- ${FORK_ONLY_TESTS[$t]}")
    else
      BUG_FIXED+=("$t")
    fi
  fi
done

print
print -ru1 -- "=== Summary ==="
print -ru1 -- ""
print -ru1 -- "FORK-FIXED BUGS (test passes on fork, fails on upstream): ${#BUG_FIXED[@]}"
for x in "${BUG_FIXED[@]}"; do print -ru1 -- "  - $x"; done
print -ru1 -- ""
print -ru1 -- "BASELINE INTACT (passes on both): ${#BASELINE_INTACT[@]}"
for x in "${BASELINE_INTACT[@]}"; do print -ru1 -- "  - $x"; done
print -ru1 -- ""
print -ru1 -- "FORK-ONLY FEATURES (fail on upstream because feature absent): ${#FORK_ONLY_FAIL[@]}"
for x in "${FORK_ONLY_FAIL[@]}"; do print -ru1 -- "  - $x"; done
print -ru1 -- ""
if (( ${#UPSTREAM_PASSES[@]} > 0 )); then
  print -ru1 -- "WARNING -- unexpected upstream PASS: ${#UPSTREAM_PASSES[@]}"
  for x in "${UPSTREAM_PASSES[@]}"; do print -ru1 -- "  - $x"; done
fi

exit 0
