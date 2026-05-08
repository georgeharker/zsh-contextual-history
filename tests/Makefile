# Test runner for the contextual-history plugin.
#
# Usage:
#   make            # default: run the full PTY suite
#   make test       # alias for default
#   make test-no-module     # PTY suite with USE_MODULE=false only
#   make test-with-module   # PTY suite with USE_MODULE=true only
#   make clean      # remove transient test artifacts
#
# The PTY suite (`run_pty_tests.zsh`) spawns real interactive zsh
# shells via zsh's `zpty` module, sends keystrokes (including history
# navigation), and asserts on observable BUFFER state. By default
# every test runs twice: once with USE_MODULE=false (pure-shell tee)
# and once with USE_MODULE=true (native-helper tee). The runner skips
# the with-module pass if the module isn't built.

.PHONY: test test-no-module test-with-module clean

test:
	@zsh run_pty_tests.zsh

test-no-module:
	@CONTEXTUAL_HISTORY_USE_MODULE=false zsh run_pty_tests.zsh

test-with-module:
	@CONTEXTUAL_HISTORY_USE_MODULE=true zsh run_pty_tests.zsh

clean:
	@find . -maxdepth 2 -name '*.tmp' -delete 2>/dev/null || true
	@echo "Cleaned test artifacts."
