TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: test test-file test-standalone test-all

## Run all tests (nvim/busted suite)
test:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(INIT_FILE)'}"

## Run a single test file: make test-file FILE=tests/config_spec.lua
test-file:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedFile $(FILE)"

## Run the standalone bootstrap tests (boot.verify / boot.json) under luvi.
## These exercise luvi's OpenSSL and so cannot run under nvim/busted.
test-standalone:
	@command -v luvi >/dev/null 2>&1 || { echo "luvi not found on PATH (needed for standalone bootstrap tests)"; exit 1; }
	luvi tests/standalone

## Run both suites.
test-all: test test-standalone
