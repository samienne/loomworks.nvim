TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: lw test test-file

## Run all tests (nvim/busted suite)
## scripts/run_specs.lua runs every spec file as PlenaryBustedDirectory does
## (one headless child nvim per file, same minimal_init, all started at once,
## TEST_TIMEOUT ms for ALL of them together) but ends with a table naming each
## file that exited non-zero, printed no summary, or was still running at the
## deadline -- PlenaryBustedDirectory only exits 1. The budget must cover the
## slowest file on a loaded machine. TEST_JOBS=N caps the concurrency.
## The daemon specs run a real lw: the release the plugin pins, provisioned
## into .lw-test/ (gitignored) by scripts/test_lw.lua with the plugin's own
## download code. `make test` / `make test-file` set LOOMWORKS_LW to it; to
## run a spec by hand, `eval "$$(nvim -l scripts/test_lw.lua .lw-test)"` first.
LW_TEST_DIR := .lw-test
LW_ENV = lw_env="$$(nvim -l scripts/test_lw.lua $(LW_TEST_DIR))" && eval "$$lw_env"

lw:
	nvim -l scripts/test_lw.lua $(LW_TEST_DIR)

TEST_TIMEOUT := 600000
TEST_JOBS := 0
test:
	$(LW_ENV) && nvim -l scripts/run_specs.lua --timeout $(TEST_TIMEOUT) --jobs $(TEST_JOBS) --init $(INIT_FILE) $(TESTS_DIR)

## Run a single test file: make test-file FILE=tests/config_spec.lua
## Run in this nvim, as each file of `make test` is: PlenaryBustedFile would
## spawn it under plenary's fixed 50 s budget and, past it, exit 1 and drop
## the run mid-test (on a loaded machine the daemon specs take longer,
## leaving the daemons they started running).
test-file:
	$(LW_ENV) && nvim --headless -u $(INIT_FILE) -c "lua require('plenary.busted').run('$(FILE)')"
