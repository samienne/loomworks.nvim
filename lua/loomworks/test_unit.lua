--- loomworks/test_unit.lua — TestUnit interface.
---
--- A TestUnit represents one source of test discovery and execution within
--- a ConfigUnit (e.g., ctest, meson test, direct gtest binary).
--- Implementations: CTestUnit, MesonTestUnit (future), GTestUnit (future).

--- @class loomworks.TestUnit
--- @field _config_unit loomworks.ConfigUnit owning config unit
--- @field _entries table[]|nil cached test entries
--- @field _framework_cache table<string, string|false> per-executable framework detection
local TestUnit = {}
TestUnit.__index = TestUnit

--- @return table[]|nil test entries
function TestUnit:discover() end

--- @param callback fun(entries: table[]|nil)
function TestUnit:discover_async(callback) end

--- Construct a command to run a specific test.
--- @param test_id string
--- @param opts? table
--- @return table|nil { cmd, env, cwd, output_path }
function TestUnit:test_command(test_id, opts) end

--- Construct a command to run all tests.
--- @param opts? table { filter?: string }
--- @return table|nil { cmd, env, cwd, output_path }
function TestUnit:test_command_all(opts) end

--- Parse test results from output.
--- @param output_path string
--- @return table[]|nil TestResult entries
function TestUnit:parse_results(output_path) end

--- Invalidate all cached data.
function TestUnit:invalidate()
    self._entries = nil
    self._framework_cache = {}
end

--- Get cached entries.
--- @return table[]|nil
function TestUnit:entries()
    return self._entries
end

return TestUnit
