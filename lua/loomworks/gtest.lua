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
    -- By case name: "Case" → entry[]
    -- By base name: "Suite.Case" → entry[] (for parameterized tests
    --   where runtime name is "Prefix/Suite.Case/N")
    local by_exact = {}
    local by_case = {}
    local by_base = {}  -- for parameterized tests
    for _, entry in ipairs(test_entries) do
        local test_name = entry.id:match("^test:(.+)$")
        if test_name then
            by_exact[test_name] = entry
            local _, case = test_name:match("^(.+)%.(.+)$")
            if case then
                -- Strip param index suffix (e.g. "Case/0" → "Case")
                local base_case = case:match("^(.+)/") or case
                by_case[base_case] = by_case[base_case] or {}
                by_case[base_case][#by_case[base_case] + 1] = entry
            end
            -- For parameterized: "Prefix/Suite.Case/N" → base "Suite.Case"
            local base = test_name:match("^[^/]+/(.+)/[^/]+$")
            if base then
                by_base[base] = by_base[base] or {}
                by_base[base][#by_base[base] + 1] = entry
            end
        end
    end

    if not next(by_exact) and not next(by_base) then return end

    -- Scan each source file for TEST macros.
    -- Handles multi-line macros by accumulating lines until the first
    -- two arguments (suite, name) are found.
    local function try_match(suite, name, canonical_path, macro_line)
        local full = suite .. "." .. name
        -- Exact match
        local entry = by_exact[full]
        if entry and not entry.file then
            entry.file = canonical_path
            entry.line = macro_line
            return
        end
        -- Parameterized: "Prefix/Suite.Name/N" → base "Suite.Name"
        local base_entries = by_base[full]
        if base_entries then
            for _, e in ipairs(base_entries) do
                if not e.file then
                    e.file = canonical_path
                    e.line = macro_line
                end
            end
            return
        end
        -- Fuzzy: match by case name.
        -- Handles: UNIT_TEST prefix (suite suffix), typed tests
        -- (TYPED_TEST uses different suite from gtest runtime),
        -- and fixture inheritance (gtest uses base class as suite).
        -- Only assigns to entries that don't already have a file.
        local candidates = by_case[name]
        if candidates then
            for _, e in ipairs(candidates) do
                if not e.file then
                    e.file = canonical_path
                    e.line = macro_line
                end
            end
        end
    end

    for _, file_path in ipairs(source_files) do
        local canonical_path = vim.fn.fnamemodify(file_path, ":p"):gsub("[/\\]$", "")
        local f = io.open(file_path, "r")
        if not f then goto continue end

        local line_num = 0
        local pending_line = nil
        local pending_args = nil
        for line in f:lines() do
            line_num = line_num + 1

            if pending_args then
                -- Continue accumulating a multi-line macro
                pending_args = pending_args .. " " .. line
            else
                local args = line:match("TEST[_%w]*%s*%((.+)")
                if args then
                    pending_args = args
                    pending_line = line_num
                elseif line:match("TEST[_%w]*%s*%(%s*$") then
                    -- Opening paren with nothing after (macro continues on next line)
                    pending_args = ""
                    pending_line = line_num
                end
            end

            if pending_args then
                local suite, name = pending_args:match("^%s*([%w_]+)%s*,%s*([%w_]+)")
                if suite and name then
                    try_match(suite, name, canonical_path, pending_line)
                    pending_args = nil
                    pending_line = nil
                elseif pending_args:match("%)") or line_num - (pending_line or 0) > 5 then
                    -- Give up: closing paren without match, or too many lines
                    pending_args = nil
                    pending_line = nil
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

--- Parse file:line from a gtest failure message.
--- gtest embeds "path/to/file.cpp:42\nExpected..." in failure text.
--- @param text string failure message text
--- @return loomtest.TestError[]
local function parse_failure_locations(text)
    local errors = {}
    -- Match lines like "path/file.cpp:42" or "path\file.cpp:42"
    for file, line in text:gmatch("([%w_/\\%.%-]+%.[ch]pp?):(%d+)") do
        errors[#errors + 1] = {
            message = text:match("^.-\n(.-)$") or text,
            file = file:gsub("\\", "/"),
            line = tonumber(line),
        }
    end
    return errors
end

--- Parse gtest XML output into test results.
--- Handles both gtest native XML (--gtest_output=xml) and ctest JUnit
--- (--output-junit). Extracts per-test output from <system-out>/<system-err>,
--- failure locations from message text, and builds full test IDs from
--- classname + name.
--- @param output_path string path to XML file
--- @return table[]|nil TestResult entries
function M.parse_xml_results(output_path)
    local f = io.open(output_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then return nil end

    local results = {}

    for tag in content:gmatch("<testcase%s[^>]->.-</testcase>") do
        local attrs = tag:match("<testcase%s(.-[^/])>")
        local body = tag:match("<testcase[^>]*>(.-)</testcase>") or ""
        if not attrs then
            attrs = tag:match("<testcase%s(.-)/%s*>")
            body = ""
        end
        if not attrs then goto continue end

        local name = attrs:match('name="([^"]*)"')
        local classname = attrs:match('classname="([^"]*)"')
        local time_str = attrs:match('time="([^"]*)"')
        if not name then goto continue end

        -- Build full test ID: classname.name (gtest format)
        -- or just name (ctest JUnit format)
        local test_id
        if classname and classname ~= "" then
            test_id = "test:" .. classname .. "." .. name
        else
            test_id = "test:" .. name
        end

        local status = "passed"
        local message
        local errors
        if body:match("<failure") then
            status = "failed"
            message = body:match("<failure[^>]*>(.-)<%/failure>")
                or body:match('<failure message="([^"]*)"')
            if message then
                errors = parse_failure_locations(message)
            end
        elseif body:match("<skipped") then
            status = "skipped"
        elseif body:match("<error") then
            status = "errored"
            message = body:match("<error[^>]*>(.-)<%/error>")
                or body:match('<error message="([^"]*)"')
        end

        -- Extract per-test output
        local sys_out = body:match("<system%-out>(.-)</system%-out>")
        local sys_err = body:match("<system%-err>(.-)</system%-err>")
        local output
        if sys_out or sys_err then
            local parts = {}
            if sys_out and sys_out ~= "" then parts[#parts + 1] = sys_out end
            if sys_err and sys_err ~= "" then
                parts[#parts + 1] = "--- stderr ---"
                parts[#parts + 1] = sys_err
            end
            output = table.concat(parts, "\n")
        end

        results[#results + 1] = {
            test_id = test_id,
            status = status,
            message = message,
            output = output,
            errors = errors,
            duration = time_str and tonumber(time_str)
                and tonumber(time_str) * 1000 or nil,
        }

        ::continue::
    end

    return #results > 0 and results or nil
end

return M
