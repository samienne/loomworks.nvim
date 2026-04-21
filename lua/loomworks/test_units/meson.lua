--- loomworks/test_units/meson.lua — MesonTestUnit: wraps meson tests.
---
--- Discovers tests via `meson introspect <build_dir> --tests`, probes
--- executables for gtest via the shared gtest helper, and runs tests
--- by invoking the test executable directly (bypassing `meson test`)
--- so we can pass gtest filter/XML flags and capture per-test results
--- exactly the way the CTestUnit does it.
---
--- One MesonTestUnit per ConfigUnit, created lazily by the meson module.

local TestUnit = require("loomworks.test_unit")
local gtest = require("loomworks.gtest")

local uv = vim.uv or vim.loop

--- @class loomworks.MesonTestUnit : loomworks.TestUnit
--- @field _build_dir string absolute build dir
--- @field _exec_specs table<string, table> executable → { cmd, cwd, env, timeout }
local MesonTestUnit = setmetatable({}, { __index = TestUnit })
MesonTestUnit.__index = MesonTestUnit

--- Find a meson binary. Mirrors the meson module's own detection so
--- the test unit works even when tool_data isn't populated (e.g.
--- discover_async runs before tool scan completes).
--- @return string[]|nil command prefix array
local function find_meson_prefix()
    local p = vim.fn.exepath("meson")
    if p ~= "" then return { p } end
    local py_probe = [[
import os,sys,sysconfig
ds=[sysconfig.get_path('scripts')]
try:
    ds.append(sysconfig.get_path('scripts','nt_user' if os.name=='nt' else os.name+'_user'))
except Exception:
    pass
for d in ds:
    for n in ('meson','meson.exe'):
        q=os.path.join(d,n)
        if os.path.isfile(q): print(q); sys.exit(0)
sys.exit(1)
]]
    for _, py in ipairs({ "python", "python3", "py" }) do
        local pp = vim.fn.exepath(py)
        if pp ~= "" then
            local out = vim.fn.system({ pp, "-c", py_probe })
            if vim.v.shell_error == 0 then
                local path = vim.trim(out or "")
                if path ~= "" and uv.fs_stat(path) then
                    return { path }
                end
            end
        end
    end
    return nil
end

--- Resolve the meson command prefix from the ConfigUnit's stored tool_data,
--- or fall back to a fresh scan.
--- @param config_unit loomworks.ConfigUnit
--- @return string[]|nil
local function meson_prefix_for(config_unit)
    local td = config_unit._tool_data
    if td and type(td.meson) == "table" and td.meson[1] then
        return vim.list_extend({}, td.meson)
    end
    if td and type(td.meson) == "string" and td.meson ~= "" then
        return { td.meson }
    end
    return find_meson_prefix()
end

--- @param config_unit loomworks.ConfigUnit
--- @return loomworks.MesonTestUnit
function MesonTestUnit.new(config_unit)
    local self = setmetatable({}, MesonTestUnit)
    self._config_unit = config_unit
    self._entries = nil
    self._framework_cache = {}
    self._build_dir = config_unit:build_dir()
    self._exec_specs = {}
    return self
end

--- Parse `meson introspect --tests` JSON into test entries.
--- The JSON shape is a flat array of test descriptors:
---   { name, suite: [], cmd: [], workdir, env: {}, timeout, ... }
--- Entries use the same shape as CTestUnit: `target:<exe>` for
--- executables, `test:<full-name>` for individual tests, so loomtest's
--- UI is consistent across modules.
--- @param json_str string
--- @return table[]|nil entries, table<string, table> exec_specs
local function parse_meson_tests(json_str)
    local ok, data = pcall(vim.json.decode, json_str)
    if not ok or type(data) ~= "table" or #data == 0 then return nil, {} end

    local entries = {}
    local executables = {}
    local exec_specs = {}

    for _, test in ipairs(data) do
        local name = test.name
        if not name then goto continue end

        local cmd = test.cmd
        local exe = (type(cmd) == "table" and cmd[1]) or nil

        if exe and not exec_specs[exe] then
            exec_specs[exe] = {
                cmd = cmd,
                cwd = test.workdir,
                env = type(test.env) == "table" and vim.deepcopy(test.env) or {},
                timeout = tonumber(test.timeout) or nil,
            }
        end

        -- Use the gtest name convention (Suite.Case) when meson tests
        -- come from a gtest binary. Probing later populates framework.
        local suite, _case = name:match("^([^%.]+)%.(.+)$")
        local looks_like_gtest = suite ~= nil and exe ~= nil

        if looks_like_gtest then
            if not executables[exe] then
                local exe_name = vim.fn.fnamemodify(exe, ":t:r")
                executables[exe] = exe_name
                entries[#entries + 1] = {
                    id = "target:" .. exe_name,
                    name = exe_name,
                    parent = nil,
                    runnable = true,
                    framework = "gtest",
                    executable = exe,
                }
            end
            entries[#entries + 1] = {
                id = "test:" .. name,
                name = name,
                parent = "target:" .. executables[exe],
                runnable = true,
                framework = "gtest",
                executable = exe,
            }
        else
            entries[#entries + 1] = {
                id = "target:" .. name,
                name = name,
                parent = nil,
                runnable = true,
                framework = nil,
                executable = exe,
            }
        end

        ::continue::
    end

    return (#entries > 0 and entries or nil), exec_specs
end

--- Build the `meson introspect --tests` command.
--- @return string[]|nil
function MesonTestUnit:_introspect_cmd()
    local prefix = meson_prefix_for(self._config_unit)
    if not prefix or not self._build_dir then return nil end
    local cmd = vim.list_extend({}, prefix)
    cmd[#cmd + 1] = "introspect"
    cmd[#cmd + 1] = self._build_dir
    cmd[#cmd + 1] = "--tests"
    return cmd
end

--- Discover test targets and individual tests (sync).
--- @return table[]|nil
function MesonTestUnit:discover()
    if self._entries then return self._entries end
    local cmd = self:_introspect_cmd()
    if not cmd then return nil end

    local result = vim.system(cmd, { text = true, timeout = 10000 }):wait()
    if result.code ~= 0 or not result.stdout then return nil end

    local entries, exec_specs = parse_meson_tests(result.stdout)
    if not entries then return nil end

    self._exec_specs = exec_specs or {}

    self:_probe_frameworks_sync(entries)

    self._entries = entries
    return entries
end

--- Discover async.
--- @param callback fun(entries: table[]|nil)
function MesonTestUnit:discover_async(callback)
    if self._entries then
        callback(self._entries)
        return
    end
    local cmd = self:_introspect_cmd()
    if not cmd then
        callback(nil)
        return
    end
    local self_ref = self

    vim.system(cmd, { text = true, timeout = 10000 },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 or not result.stdout then
                    callback(nil)
                    return
                end
                local entries, exec_specs = parse_meson_tests(result.stdout)
                if not entries then
                    callback(nil)
                    return
                end
                self_ref._exec_specs = exec_specs or {}

                self_ref:_probe_frameworks(entries, function()
                    self_ref._entries = entries
                    callback(entries)
                end)
            end)
        end
    )
end

--- Probe targets without a declared framework for gtest (sync).
--- @param entries table[]
function MesonTestUnit:_probe_frameworks_sync(entries)
    for _, e in ipairs(entries) do
        if not e.parent and not e.framework and e.executable then
            local cached = self._framework_cache[e.executable]
            if cached == nil then
                local framework, test_list = gtest.probe_sync(e.executable, e.id)
                self._framework_cache[e.executable] = framework or false
                if framework and test_list then
                    e.framework = framework
                    for _, t in ipairs(test_list) do
                        entries[#entries + 1] = t
                    end
                end
            elseif cached and cached ~= false then
                e.framework = cached
            end
        end
    end
end

--- Probe targets async.
--- @param entries table[]
--- @param callback fun()
function MesonTestUnit:_probe_frameworks(entries, callback)
    local targets = {}
    for _, e in ipairs(entries) do
        if not e.parent and not e.framework and e.executable then
            local cached = self._framework_cache[e.executable]
            if cached == nil then
                targets[#targets + 1] = e
            elseif cached and cached ~= false then
                e.framework = cached
            end
        end
    end
    if #targets == 0 then callback() return end

    local remaining = #targets
    for _, target in ipairs(targets) do
        gtest.probe_async(target.executable, target.id, function(framework, test_list)
            self._framework_cache[target.executable] = framework or false
            if framework and test_list then
                target.framework = framework
                for _, t in ipairs(test_list) do
                    entries[#entries + 1] = t
                end
            end
            remaining = remaining - 1
            if remaining == 0 then callback() end
        end)
    end
end

--- Common runner: produce { cmd, env, cwd, output_path } for a
--- gtest-compatible executable with filter + XML output.
--- @param exe string
--- @param filter? string GTEST_FILTER value
--- @return table|nil
function MesonTestUnit:_build_gtest_run(exe, filter)
    local spec = self._exec_specs[exe]
    if not spec then return nil end

    local cmd = vim.deepcopy(spec.cmd)
    local env = vim.deepcopy(spec.env)
    if filter then
        env.GTEST_FILTER = filter
    end

    local nvim_dir = self._build_dir .. "/.nvim"
    if not uv.fs_stat(nvim_dir) then
        uv.fs_mkdir(nvim_dir, 493) -- 0755
    end
    local xml = nvim_dir .. "/gtest_results.xml"
    cmd[#cmd + 1] = "--gtest_output=xml:" .. xml

    return {
        cmd = cmd,
        env = env,
        cwd = spec.cwd or self._build_dir,
        output_path = xml,
    }
end

--- @param test_id string
--- @param opts? table { gtest_filter? }
--- @return table|nil
function MesonTestUnit:test_command(test_id, opts)
    opts = opts or {}

    local exe = nil
    local parent_id = nil
    if self._entries then
        for _, e in ipairs(self._entries) do
            if e.id == test_id then
                exe = e.executable
                parent_id = e.parent
                break
            end
        end
    end
    if not exe and parent_id then
        for _, e in ipairs(self._entries) do
            if e.id == parent_id then
                exe = e.executable
                break
            end
        end
    end
    if not exe then return nil end

    local filter
    local is_target = test_id:match("^target:")
    if not is_target then
        filter = opts.gtest_filter or (test_id:match("^test:(.+)$") or test_id)
    elseif opts.gtest_filter then
        filter = opts.gtest_filter
    end
    return self:_build_gtest_run(exe, filter)
end

--- @param opts? table { filter? }
--- @return table|nil
function MesonTestUnit:test_command_all(opts)
    opts = opts or {}
    local exe = nil
    if self._entries then
        for _, e in ipairs(self._entries) do
            if e.executable then exe = e.executable break end
        end
    end
    if not exe then return nil end
    return self:_build_gtest_run(exe, opts.filter)
end

--- @param output_path string
--- @return table[]|nil
function MesonTestUnit:parse_results(output_path)
    return gtest.parse_xml_results(output_path)
end

--- Invalidate cached data.
function MesonTestUnit:invalidate()
    TestUnit.invalidate(self)
    self._exec_specs = {}
    self._build_dir = self._config_unit:build_dir()
end

return MesonTestUnit
