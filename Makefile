TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: test test-file test-standalone test-all install dist

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
	bash scripts/release/fuse_host.sh "$$(command -v luvi)" tests/fixtures/dist/test_ec_pub.pem dist/lw-local
	@echo "dist/ built (dry-run, test key). Real releases: CI on a v* tag."
