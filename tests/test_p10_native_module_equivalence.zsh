#!/usr/bin/env zsh
# test_p10_native_module_equivalence
#
# Validates: with the native helper module loaded
# (CONTEXTUAL_HISTORY_USE_MODULE=true), the same cross-shell scenarios
# behave identically to the pure-shell path. Re-runs p01's scenario but
# with the module enabled.
#
# Skips gracefully if the module isn't built. Build with:
#   cd module && make

source "${0:A:h}/lib/pty_harness.zsh"

# Probe for the built module. The Makefile produces a .bundle on macOS,
# .so on Linux.
PLUGIN_DIR=${0:A:h:h}
MODULE_BUNDLE="$PLUGIN_DIR/module/zsh/contextual_history.bundle"
MODULE_SO="$PLUGIN_DIR/module/zsh/contextual_history.so"

if [[ ! -f $MODULE_BUNDLE && ! -f $MODULE_SO ]]; then
  print -ru2 -- "SKIP ${0:t}: native module not built (run \`cd module && make\`)"
  exit 0
fi

HISTROOT=$(mktemp -d -t ch-pty-p10.XXXXXX)
trap "pty_cleanup_all; rm -rf $HISTROOT" EXIT

# Same scenario as p01 but with USE_MODULE=true.
TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=true pty_spawn shellA "$HISTROOT" \
  || pty_fail "could not spawn shellA"
TEST_SHARE_HISTORY=1 CONTEXTUAL_HISTORY_USE_MODULE=true pty_spawn shellB "$HISTROOT" \
  || pty_fail "could not spawn shellB"

pty_run_cmd shellB 'echo from-B-via-module' || pty_fail "B run failed"
sleep 0.1

pty_press_up shellA
buf=$(pty_inspect_buf shellA)

if [[ $buf == 'echo from-B-via-module' ]]; then
  pty_pass
else
  pty_fail "shellA up-arrow expected 'echo from-B-via-module' (cross-shell with module); got <$buf>"
fi
