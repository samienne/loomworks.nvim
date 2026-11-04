-- The teststub module's test program (lua/loomworks/modules/teststub.lua):
--   nvim -l run.lua <tests.json> <target> --gtest_output=xml:<xml>
-- Runs the target's cases that GTEST_FILTER selects (`:`-separated exact
-- names or `Suite.*`; unset or empty: every case), printing gtest-format
-- progress, and writes a gtest XML results file. `tests.json` `results`
-- (`{ "<Suite.Case>": "failed" | "skipped" }`) chooses outcomes; a case
-- not named passes and prints `output of <Suite.Case>`. A failed case
-- prints `<dir of tests.json>/<file>:<line>: Failure` when `failures`
-- (`{ "<Suite.Case>": "<file>:<line>" }`) names its location. Exits 1 when
-- a case failed. Sleeps LW_TEST_RUN_SLEEP ms per case (only before the case
-- LW_TEST_RUN_SLEEP_CASE when that is set).
local path, target = arg[1], arg[2]
local xml
for i = 3, #arg do xml = arg[i]:match("^%-%-gtest_output=xml:(.+)$") or xml end
local f = assert(io.open(path, "rb"))
local spec = vim.json.decode(f:read("*a"))
f:close()
local dir = path:gsub("\\", "/"):gsub("/[^/]*$", "")
local outcomes = spec.results or {}
local locations = spec.failures or {}
local ms = tonumber(os.getenv("LW_TEST_RUN_SLEEP") or "")
local sleep_case = os.getenv("LW_TEST_RUN_SLEEP_CASE")
local filter = os.getenv("GTEST_FILTER")
local function wanted(name)
    if not filter or filter == "" then return true end
    for pat in filter:gmatch("[^:]+") do
        if pat == name then return true end
        local suite = pat:match("^(.-)%.%*$")
        if suite and name:match("^([^%.]+)") == suite then return true end
    end
    return false
end
local cases = {}
for _, t in ipairs(spec.targets or {}) do
    if t.name == target then
        for _, c in ipairs(t.cases or {}) do
            if wanted(c) then cases[#cases + 1] = c end
        end
    end
end
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) end
local rows, failed = {}, 0
io.write("[==========] Running " .. #cases .. " tests.\n")
for _, c in ipairs(cases) do
    local suite, case = c:match("^([^%.]+)%.(.+)$")
    io.write("[ RUN      ] " .. c .. "\n")
    io.stdout:flush()
    if ms and (not sleep_case or sleep_case == c) then vim.uv.sleep(ms) end
    local o = outcomes[c] or "passed"
    if o == "failed" then
        failed = failed + 1
        local text = c .. " failed"
        if locations[c] then text = dir .. "/" .. locations[c] .. ": Failure\n" .. text end
        io.write(text .. "\n[  FAILED  ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format(
            '    <testcase name="%s" status="run" result="completed" time="0" classname="%s">\n'
            .. '      <failure message="%s" type=""><![CDATA[%s]]></failure>\n    </testcase>',
            esc(case), esc(suite), esc(c .. " failed"), text)
    elseif o == "skipped" then
        io.write("[  SKIPPED ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format(
            '    <testcase name="%s" status="run" result="skipped" time="0" classname="%s">\n      <skipped/>\n    </testcase>',
            esc(case), esc(suite))
    else
        io.write("output of " .. c .. "\n[       OK ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format('    <testcase name="%s" status="run" result="completed" time="0" classname="%s" />',
            esc(case), esc(suite))
    end
    io.stdout:flush()
end
io.write("[==========] " .. #cases .. " tests ran.\n")
io.stdout:flush()
if xml then
    local out = assert(io.open(xml, "wb"))
    out:write('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites tests="' .. #cases .. '" failures="' .. failed .. '">\n'
        .. '  <testsuite name="' .. esc(target) .. '">\n' .. table.concat(rows, "\n") .. "\n  </testsuite>\n</testsuites>\n")
    out:close()
end
os.exit(failed > 0 and 1 or 0)
