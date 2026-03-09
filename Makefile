TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: test test-file

## Run all tests
test:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(INIT_FILE)'}"

## Run a single test file: make test-file FILE=tests/config_spec.lua
test-file:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedFile $(FILE)"
