TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: test test-file test-standalone test-all install dist

## Run all tests (nvim/busted suite)
## scripts/run_specs.lua runs every spec file as PlenaryBustedDirectory does
## (one headless child nvim per file, same minimal_init, all started at once,
## TEST_TIMEOUT ms for ALL of them together) but ends with a table naming each
## file that exited non-zero, printed no summary, or was still running at the
## deadline -- PlenaryBustedDirectory only exits 1. The budget must cover the
## slowest file on a loaded machine. TEST_JOBS=N caps the concurrency.
TEST_TIMEOUT := 600000
TEST_JOBS := 0
test:
	nvim -l scripts/run_specs.lua --timeout $(TEST_TIMEOUT) --jobs $(TEST_JOBS) --init $(INIT_FILE) $(TESTS_DIR)

## Run a single test file: make test-file FILE=tests/config_spec.lua
## Run in this nvim, as each file of `make test` is: PlenaryBustedFile would
## spawn it under plenary's fixed 50 s budget and, past it, exit 1 and drop
## the run mid-test (on a loaded machine the daemon specs take longer,
## leaving the daemons they started running).
test-file:
	nvim --headless -u $(INIT_FILE) -c "lua require('plenary.busted').run('$(FILE)')"

## Run the standalone bootstrap tests (boot.verify / boot.json) under luvi.
## These exercise luvi's OpenSSL and so cannot run under nvim/busted.
test-standalone:
	@command -v luvi >/dev/null 2>&1 || { echo "luvi not found on PATH (needed for standalone bootstrap tests)"; exit 1; }
	luvi tests/standalone

## Run both suites.
test-all: test test-standalone

## Build a fused-everything lw host from the working tree and install it for the
## current user (frozen snapshot; use `lw --dev` for the live repo). Re-run to
## update the installed snapshot.
install:
	bash scripts/dev-install.sh

## Dry-run a release build into dist/ using the TEST key + local luvi. CI passes
## the real version and signing key (see .github/workflows/release.yml).
dist:
	@command -v luvi >/dev/null 2>&1 || { echo "luvi not found on PATH"; exit 1; }
	bash scripts/release/build_bundle.sh 0.0.0-dev dist tests/fixtures/dist/test_ec_priv.pem
	bash scripts/release/fuse_host.sh "$$(command -v luvi)" tests/fixtures/dist/test_ec_pub.pem dist/lw-local 0.0.0-dev
	@echo "dist/ built (dry-run, test key). Real releases: CI on a v* tag."
