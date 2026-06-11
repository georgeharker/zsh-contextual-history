#!/usr/bin/env zsh
# run_pty_tests.zsh
#
# Run every test_p*.zsh under both CONTEXTUAL_HISTORY_USE_MODULE=false
# and =true. Skips the module run when the module isn't built.
#
# Usage:
#   ./run_pty_tests.zsh                  # run all p* tests, both configs
#   ./run_pty_tests.zsh test_p01*.zsh    # filter by glob
#
# Each test inherits CONTEXTUAL_HISTORY_USE_MODULE from the runner's
# env; tests that need the module specifically (test_p10) check
# whether the module is built and skip if not.

cd "${0:A:h}"

# Tests to run - default is everything. Honors arg-list filter.
if (( $# > 0 )); then
  TESTS=("$@")
else
  TESTS=(test_p*.zsh)
fi

# Probe for built module so we know whether to attempt the with-module
# pass. Suffix differs by platform: .bundle on macOS, .so on Linux.
PLUGIN_DIR=${0:A:h:h}
MODULE_FILE=""
[[ -f "$PLUGIN_DIR/module/zsh/contextual_history.bundle" ]] \
  && MODULE_FILE="$PLUGIN_DIR/module/zsh/contextual_history.bundle"
[[ -f "$PLUGIN_DIR/module/zsh/contextual_history.so" ]] \
  && MODULE_FILE="$PLUGIN_DIR/module/zsh/contextual_history.so"

CONFIGS=(false)
if [[ -n $MODULE_FILE ]]; then
  CONFIGS+=(true)
else
  print -ru2 -- "(module not built; skipping with-module pass. Build with: contextual-history-build-module)"
fi

typeset -i PASS=0 FAIL=0 SKIP=0
typeset -A FAILED_TESTS

print -ru1 -- "Running ${#TESTS[@]} tests x ${#CONFIGS[@]} configs"
print

for cfg in "${CONFIGS[@]}"; do
  print -- "=== CONTEXTUAL_HISTORY_USE_MODULE=$cfg ==="
  for t in "${TESTS[@]}"; do
    [[ -f $t ]] || { print -- "  $t: NOT FOUND"; continue }
    result=$(CONTEXTUAL_HISTORY_USE_MODULE=$cfg timeout 30 zsh "$t" 2>&1 | tail -1)
    case $result in
      (PASS\ *|*PASS*pass*)
        printf "  %-50s PASS\n" "$t"
        (( PASS++ ))
        ;;
      (SKIP\ *|*SKIP*)
        printf "  %-50s SKIP\n" "$t"
        (( SKIP++ ))
        ;;
      (*)
        printf "  %-50s FAIL: %s\n" "$t" "$result"
        FAILED_TESTS[$t/$cfg]=$result
        (( FAIL++ ))
        ;;
    esac
  done
  print
done

print -- "Summary: $PASS passed, $FAIL failed, $SKIP skipped"
if (( FAIL > 0 )); then
  print
  print -- "Failed tests:"
  for k in "${(@k)FAILED_TESTS}"; do
    print -- "  $k -> ${FAILED_TESTS[$k]}"
  done
  exit 1
fi
exit 0
