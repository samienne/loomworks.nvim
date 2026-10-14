--- tests/fixtures/teststub — a harness-only module with tests (spec §19.19
--- step 5m part B1). It ships only in the test tree: the conformance runner
--- puts `tests/fixtures/teststub` on the runtime path of the daemons it
--- starts for the `tests` fixture (and registers it in-process for the
--- loopback transport); no release bundle contains it.
---
--- It is the `shell` module (configure/build/clean commands, build_dir
--- template) under the id `teststub`, plus a static TestUnit:
---
---   discovery  reads `<project dir>/tests.json`:
---                { "targets": [ { "name": "unit_a", "cases": ["Math.Add", ...],
---                                 "file"?: "<rel path>", "line"?: n } ] }
---              and probes every target by running
---                nvim -l <fixture>/probe.lua <tests.json> <target>
---              (through the discovery's spawner, `TestUnit.system`), which
---              prints the target's cases in `--gtest_list_tests` format
---              (after sleeping `LW_TEST_DISCOVER_SLEEP` ms of ITS
---              environment, so a transcript shows the caller's environment
---              and a cancel at a probe); a target whose name is listed in
---              `fail_probe` exits 1 (no cases). Cases are `gtest` entries
---              under the target.
---   runs       `nvim -l <fixture>/run.lua <tests.json> <target> --gtest_output=xml:<xml>`
---              with `GTEST_FILTER` (a case: its name; a target: the
---              caller's `gtest_filter`, else every case) — gtest's own
---              results option and filter, so the daemon's runs combine and
---              debug it as a gtest program — prints gtest-format progress
---              and writes a gtest XML results file; `tests.json`
---              `"results": { "<Suite.Case>": "failed" | "skipped" }` chooses
---              outcomes (default passed), `"failures": { "<Suite.Case>":
---              "<rel file>:<line>" }` a failed case's location.

local shell = require("loomworks.modules.shell")

local M = setmetatable({}, { __index = shell })

M.id = "teststub"
M.api_version = shell.api_version

--- The fixture directory (this file's `../../../..`).
local function fixture_dir()
    local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
    return (src:gsub("/lua/loomworks/modules/teststub%.lua$", ""))
end

--- The nvim that runs the fixture's scripts.
local function nvim()
    return (vim.v.progpath:gsub("\\", "/"))
end

local TestUnit = {}
TestUnit.__index = TestUnit

--- @param config_unit table
function M.create_test_unit(config_unit)
    return setmetatable({ _config_unit = config_unit, _framework_cache = {} }, TestUnit)
end

--- `<project dir>/tests.json`, decoded (nil: none or unreadable).
function TestUnit:_spec()
    local p = self._config_unit._project
    local dir = p and p.abs_path and p:abs_path()
    if not dir then return nil, nil end
    local path = dir .. "/tests.json"
    local f = io.open(path, "rb")
    if not f then return nil, path end
    local ok, spec = pcall(vim.json.decode, f:read("*a"))
    f:close()
    return ok and type(spec) == "table" and spec or nil, path
end

function TestUnit:discover()
    return nil
end

--- @param callback fun(entries: table[]|nil)
function TestUnit:discover_async(callback)
    local spec, path = self:_spec()
    if not spec or type(spec.targets) ~= "table" or #spec.targets == 0 then
        vim.schedule(function() callback(nil) end)
        return
    end
    local gtest = require("loomworks.gtest")
    local dir = path:gsub("/tests%.json$", "")
    local entries, pending = {}, #spec.targets
    local per = {}
    for i, t in ipairs(spec.targets) do
        local id = "target:" .. t.name
        per[i] = { {
            id = id, name = t.name, runnable = true, source = "teststub", framework = "gtest",
            executable = nvim(),
        } }
        local cmd = { nvim(), "--headless", "-u", "NONE", "-l", fixture_dir() .. "/probe.lua", path, t.name }
        require("loomworks.test_unit").system(self, cmd, { text = true, timeout = 10000, cwd = dir },
            function(res)
                vim.schedule(function()
                    if res.code == 0 and res.stdout then
                        for _, c in ipairs(gtest.parse_list_tests(res.stdout, nvim(), id)) do
                            c.id = id .. "/" .. c.name
                            if t.file then c.file = dir .. "/" .. t.file end
                            if t.line then c.line = t.line end
                            per[i][#per[i] + 1] = c
                        end
                    end
                    pending = pending - 1
                    if pending == 0 then
                        for _, list in ipairs(per) do
                            for _, e in ipairs(list) do entries[#entries + 1] = e end
                        end
                        self._entries = entries
                        callback(entries)
                    end
                end)
            end)
    end
end

--- The entry of an id in the last discovery.
function TestUnit:_entry(id)
    for _, e in ipairs(self._entries or {}) do
        if e.id == id then return e end
    end
    return nil
end

--- The run command of a target (all its cases, or those the gtest filter
--- `filter` selects), writing its results to `xml` (default
--- `<build dir>/teststub-<target>.xml`).
local function run_cmd(self, target, filter, xml)
    local _, path = self:_spec()
    local bd = self._config_unit:build_dir()
    xml = xml or (bd .. "/teststub-" .. target .. ".xml")
    local cmd = { nvim(), "--headless", "-u", "NONE", "-l", fixture_dir() .. "/run.lua", path, target,
        "--gtest_output=xml:" .. xml }
    return { cmd = cmd, env = { GTEST_FILTER = filter }, cwd = bd, output_path = xml }
end

--- @param test_id string
--- @param opts? table { output_path?, gtest_filter? }
function TestUnit:test_command(test_id, opts)
    opts = opts or {}
    local e = self:_entry(test_id)
    if not e then return nil end
    local spec
    if not e.parent then
        spec = run_cmd(self, e.name, opts.gtest_filter, opts.output_path)
    else
        local t = self:_entry(e.parent)
        if not t then return nil end
        spec = run_cmd(self, t.name, opts.gtest_filter or e.name, opts.output_path)
    end
    spec.test_id = test_id
    return spec
end

--- @param opts? table { output_path?, filter? }
function TestUnit:test_command_all(opts)
    opts = opts or {}
    local first
    for _, e in ipairs(self._entries or {}) do
        if not e.parent then first = e; break end
    end
    if not first then return nil end
    return self:test_command(first.id, { output_path = opts.output_path, gtest_filter = opts.filter })
end

function TestUnit:run_command_all()
    return nil
end

--- @param output_path string
function TestUnit:parse_results(output_path)
    local results = require("loomworks.gtest").parse_xml_results(output_path)
    if not results then return nil end
    for _, r in ipairs(results) do
        for _, e in ipairs(self._entries or {}) do
            if e.parent and e.name == (r.test_id or ""):gsub("^test:", "") then r.test_id = e.id end
        end
    end
    return results
end

function TestUnit:invalidate()
    self._entries = nil
    self._framework_cache = {}
end

function TestUnit:entries()
    return self._entries
end

return M
