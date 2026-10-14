-- The teststub module's discovery probe (lua/loomworks/modules/teststub.lua):
--   nvim -l probe.lua <tests.json> <target>
-- Prints the target's cases in `--gtest_list_tests` format. Sleeps
-- LW_TEST_DISCOVER_SLEEP ms first (read from this process's environment).
-- A target listed in `fail_probe` exits 1.
local path, target = arg[1], arg[2]
local ms = tonumber(os.getenv("LW_TEST_DISCOVER_SLEEP") or "")
if ms then vim.uv.sleep(ms) end
local f = assert(io.open(path, "rb"))
local spec = vim.json.decode(f:read("*a"))
f:close()
for _, name in ipairs(spec.fail_probe or {}) do
    if name == target then
        io.stderr:write("probe failed: " .. target .. "\n")
        os.exit(1)
    end
end
local suites, order = {}, {}
for _, t in ipairs(spec.targets or {}) do
    if t.name == target then
        for _, c in ipairs(t.cases or {}) do
            local suite, case = c:match("^([^%.]+)%.(.+)$")
            if suite then
                if not suites[suite] then suites[suite] = {}; order[#order + 1] = suite end
                table.insert(suites[suite], case)
            end
        end
    end
end
for _, s in ipairs(order) do
    io.write(s .. ".\n")
    for _, c in ipairs(suites[s]) do io.write("  " .. c .. "\n") end
end
io.stdout:flush()
