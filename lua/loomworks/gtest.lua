--- loomworks/gtest.lua — GTest helper: shared gtest-specific functionality.
---
--- Not a TestUnit — a utility class used by CTestUnit and future TestUnits
--- for gtest framework detection, test listing, source location scanning,
--- and result parsing.

local M = {}

local uv = vim.uv or vim.loop

--- Parse --gtest_list_tests output into test entries.
--- @param output string stdout from --gtest_list_tests
--- @param executable string path to the test executable
--- @param target_id string parent target id for tree nesting
--- @return table[] test entries
function M.parse_list_tests(output, executable, target_id)
    local entries = {}
    local current_suite = nil

    for line in output:gmatch("[^\r\n]+") do
        -- Suite lines end with "."
        local suite = line:match("^(%S+)%.$")
        if suite then
            current_suite = suite
        elseif current_suite then
            -- Test case lines are indented
            local case = line:match("^%s+(%S+)")
            if case then
                -- Strip type parameter suffix if present
                case = case:match("^([^#]+)") or case
                -- Trim trailing whitespace from # stripping
                case = case:match("^(.-)%s*$")
                local full_name = current_suite .. "." .. case
                entries[#entries + 1] = {
                    id = "test:" .. full_name,
                    name = full_name,
                    parent = target_id,
                    runnable = true,
                    framework = "gtest",
                    executable = executable,
                }
            end
        end
    end

    return entries
end

--- Probe an executable to detect if it's a gtest binary.
--- Async: calls callback with results.
--- @param executable string absolute path to the test binary
--- @param target_id string the target id for parenting discovered tests
--- @param callback fun(framework: string|nil, test_list: table[]|nil)
function M.probe(executable, target_id, callback)
    vim.system(
        { executable, "--gtest_list_tests" },
        { text = true, timeout = 5000 },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 or not result.stdout then
                    callback(nil, nil)
                    return
                end
                -- Validate it looks like gtest output (first line should be a suite)
                local first_line = result.stdout:match("^([^\r\n]+)")
                if not first_line or not first_line:match("^%S+%.$") then
                    callback(nil, nil)
                    return
                end
                local entries = M.parse_list_tests(result.stdout, executable, target_id)
                callback("gtest", entries)
            end)
        end
    )
end

--- Synchronous version of probe.
--- @param executable string
--- @param target_id string
--- @return string|nil framework, table[]|nil test_list
function M.probe_sync(executable, target_id)
    local result = vim.system(
        { executable, "--gtest_list_tests" },
        { text = true, timeout = 5000 }
    ):wait()

    if result.code ~= 0 or not result.stdout then
        return nil, nil
    end
    local first_line = result.stdout:match("^([^\r\n]+)")
    if not first_line or not first_line:match("^%S+%.$") then
        return nil, nil
    end
    local entries = M.parse_list_tests(result.stdout, executable, target_id)
    return "gtest", entries
end

--- Scan source files for gtest macros to find source locations.
--- Searches for TEST(Suite, Name), TEST_F(Suite, Name), TEST_P(Suite, Name).
--- @param test_entries table[] entries with id like "test:Suite.Case"
--- @param source_files string[] absolute paths to source files
function M.find_source_locations(test_entries, source_files)
    -- Build lookups for matching test entries by name.
    -- Exact: "Suite.Case" → entry
    -- By case name: "Case" → entry[] (for fuzzy matching when macros
    -- transform the suite name, e.g. UNIT_TEST(API_Suite, Case) → Suite.Case)
    local by_exact = {}
    local by_case = {}
    for _, entry in ipairs(test_entries) do
        local test_name = entry.id:match("^test:(.+)$")
        if test_name then
            by_exact[test_name] = entry
            local _, case = test_name:match("^(.+)%.(.+)$")
            if case then
                by_case[case] = by_case[case] or {}
                by_case[case][#by_case[case] + 1] = entry
            end
        end
    end

    if not next(by_exact) then return end

    -- Scan each source file for TEST macros
    for _, file_path in ipairs(source_files) do
        local f = io.open(file_path, "r")
        if not f then goto continue end

        local line_num = 0
        for line in f:lines() do
            line_num = line_num + 1
            -- Match test macros: find TEST followed by optional suffix,
            -- then extract first two arguments from the parenthesized list.
            -- Covers: TEST(S,N), TEST_F(S,N), TEST_P(S,N), UNIT_TEST(S,N,...),
            -- UNIT_TEST_F(S,N,...), TYPED_TEST(S,N), etc.
            -- Two-step: check for TEST macro, then extract args after "("
            local args = line:match("TEST[_%w]*%s*%((.+)")
            local suite, name
            if args then
                suite, name = args:match("^%s*([%w_]+)%s*,%s*([%w_]+)")
            end
            if suite and name then
                -- Try exact match first
                local full = suite .. "." .. name
                local entry = by_exact[full]
                if entry and not entry.file then
                    entry.file = file_path
                    entry.line = line_num
                else
                    -- Fuzzy: match by case name + suite suffix.
                    -- Handles macros that add/remove prefixes (e.g.
                    -- UNIT_TEST(API_Suite, Case) registers as Suite.Case)
                    local candidates = by_case[name]
                    if candidates then
                        for _, e in ipairs(candidates) do
                            if not e.file then
                                -- Check if the gtest suite is a suffix of the macro suite
                                local gtest_suite = e.id:match("^test:(.+)%.")
                                if gtest_suite and suite:match(gtest_suite .. "$") then
                                    e.file = file_path
                                    e.line = line_num
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        f:close()

        ::continue::
    end
end

--- Build a --gtest_filter string from a test ID.
--- @param test_id string e.g. "test:MathSuite.test_add" or "MathSuite.test_add"
--- @return string filter e.g. "MathSuite.test_add"
function M.build_filter(test_id)
    return test_id:match("^test:(.+)$") or test_id
end

--- Parse gtest XML output into test results.
--- @param output_path string path to gtest XML file
--- @return table[]|nil TestResult entries
function M.parse_xml_results(output_path)
    local f = io.open(output_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then return nil end

    local results = {}

    -- Parse JUnit/gtest XML testcase elements.
    for tag in content:gmatch("<testcase%s[^>]->.-</testcase>") do
        local attrs = tag:match("<testcase%s(.-[^/])>")
        local body = tag:match("<testcase[^>]*>(.-)</testcase>") or ""
        if not attrs then
            attrs = tag:match("<testcase%s(.-)/%s*>")
            body = ""
        end
        if not attrs then goto continue end

        local name = attrs:match('name="([^"]*)"')
        local time_str = attrs:match('time="([^"]*)"')
        if not name then goto continue end

        local status = "passed"
        local message
        if body:match("<failure") then
            status = "failed"
            message = body:match("<failure[^>]*>(.-)<%/failure>")
                or body:match('<failure message="([^"]*)"')
        elseif body:match("<skipped") then
            status = "skipped"
        elseif body:match("<error") then
            status = "errored"
            message = body:match("<error[^>]*>(.-)<%/error>")
                or body:match('<error message="([^"]*)"')
        end

        results[#results + 1] = {
            test_id = "test:" .. name,
            status = status,
            message = message,
            duration = time_str and tonumber(time_str)
                and tonumber(time_str) * 1000 or nil,
        }

        ::continue::
    end

    return #results > 0 and results or nil
end

return M
