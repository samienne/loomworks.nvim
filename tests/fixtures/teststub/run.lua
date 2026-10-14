-- The teststub module's test program (lua/loomworks/modules/teststub.lua):
--   nvim -l run.lua <tests.json> <xml> <target> [<Suite.Case>]
-- Runs the target's cases (or the one named), printing gtest-format
-- progress, and writes a gtest XML results file. `tests.json` `results`
-- (`{ "<Suite.Case>": "failed" | "skipped" }`) chooses outcomes; a case
-- not named passes. Exits 1 when a case failed. Sleeps LW_TEST_RUN_SLEEP ms
-- per case.
local path, xml, target, only = arg[1], arg[2], arg[3], arg[4]
local f = assert(io.open(path, "rb"))
local spec = vim.json.decode(f:read("*a"))
f:close()
local outcomes = spec.results or {}
local ms = tonumber(os.getenv("LW_TEST_RUN_SLEEP") or "")
local cases = {}
for _, t in ipairs(spec.targets or {}) do
    if t.name == target then
        for _, c in ipairs(t.cases or {}) do
            if not only or only == c then cases[#cases + 1] = c end
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
    if ms then vim.uv.sleep(ms) end
    local o = outcomes[c] or "passed"
    if o == "failed" then
        failed = failed + 1
        io.write("teststub: " .. c .. " failed\n[  FAILED  ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format(
            '    <testcase name="%s" status="run" result="completed" time="0" classname="%s">\n'
            .. '      <failure message="%s" type=""><![CDATA[%s]]></failure>\n    </testcase>',
            esc(case), esc(suite), esc(c .. " failed"), c .. " failed")
    elseif o == "skipped" then
        io.write("[  SKIPPED ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format(
            '    <testcase name="%s" status="run" result="skipped" time="0" classname="%s">\n      <skipped/>\n    </testcase>',
            esc(case), esc(suite))
    else
        io.write("[       OK ] " .. c .. " (0 ms)\n")
        rows[#rows + 1] = string.format('    <testcase name="%s" status="run" result="completed" time="0" classname="%s" />',
            esc(case), esc(suite))
    end
end
io.write("[==========] " .. #cases .. " tests ran.\n")
io.stdout:flush()
local out = assert(io.open(xml, "wb"))
out:write('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites tests="' .. #cases .. '" failures="' .. failed .. '">\n'
    .. '  <testsuite name="' .. esc(target) .. '">\n' .. table.concat(rows, "\n") .. "\n  </testsuite>\n</testsuites>\n")
out:close()
os.exit(failed > 0 and 1 or 0)
