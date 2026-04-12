--- loomworks/test_units/ctest.lua — CTestUnit: wraps ctest for cmake projects.
---
--- Discovers test targets via ctest --show-only, probes executables for
--- framework detection via GTest helper, runs tests via ctest commands.
--- One CTestUnit per ConfigUnit.

local TestUnit = require("loomworks.test_unit")
local gtest = require("loomworks.gtest")

local uv = vim.uv or vim.loop

--- @class loomworks.CTestUnit : loomworks.TestUnit
--- @field _build_dir string absolute build dir
--- @field _configuration string|nil variant name (for -C flag)
--- @field _ctest_dir string|nil cached CTestTestfile directory
--- @field _source_files_by_exe table<string, string[]> executable → source files
--- @field _exec_specs table<string, table> executable → { cmd, cwd, env, timeout }
local CTestUnit = setmetatable({}, { __index = TestUnit })
CTestUnit.__index = CTestUnit

--- @param config_unit loomworks.ConfigUnit
--- @return loomworks.CTestUnit
function CTestUnit.new(config_unit)
    local self = setmetatable({}, CTestUnit)
    self._config_unit = config_unit
    self._entries = nil
    self._framework_cache = {}
    self._build_dir = config_unit:build_dir()
    self._configuration = config_unit:variant()
    self._ctest_dir = nil
    self._source_files_by_exe = {}
    self._exec_specs = {}
    return self
end

--- Find the directory containing CTestTestfile.cmake.
--- @return string|nil
function CTestUnit:_find_ctest_dir()
    if self._ctest_dir then return self._ctest_dir end
    local bd = self._build_dir
    if not bd then return nil end

    local skip = { _deps = true, CMakeFiles = true, [".cmake"] = true }
    local function search(dir, depth)
        if depth > 5 then return nil end
        if uv.fs_stat(dir .. "/CTestTestfile.cmake") then return dir end
        local handle = uv.fs_scandir(dir)
        if not handle then return nil end
        while true do
            local name, typ = uv.fs_scandir_next(handle)
            if not name then break end
            if not skip[name] and typ == "directory" then
                local found = search(dir .. "/" .. name, depth + 1)
                if found then return found end
            end
        end
        return nil
    end

    self._ctest_dir = search(bd, 0)
    return self._ctest_dir
end

--- Build the ctest base command.
--- @return string[]
function CTestUnit:_base_cmd()
    local test_dir = self:_find_ctest_dir() or self._build_dir
    local cmd = { "ctest", "--test-dir", test_dir }
    if self._configuration then
        cmd[#cmd + 1] = "-C"
        cmd[#cmd + 1] = self._configuration
    end
    return cmd
end

--- Parse ctest --show-only=json-v1 output into test entries.
--- @param json_str string
--- @return table[]|nil
local function parse_ctest_json(json_str)
    local ok, data = pcall(vim.json.decode, json_str)
    if not ok or not data then return nil end

    local tests_data = data.tests
    if not tests_data or #tests_data == 0 then return nil end

    local entries = {}
    local executables = {}
    local exec_specs = {}  -- executable → { cmd, cwd, env, timeout }

    for _, test in ipairs(tests_data) do
        local name = test.name
        if not name then goto continue end

        local exe = test.command and test.command[1] or nil
        local suite, case = name:match("^([^%.]+)%.(.+)$")
        local is_individual = suite ~= nil and exe ~= nil

        -- Extract execution spec from ctest properties
        if exe and not exec_specs[exe] then
            local spec = {
                cmd = test.command,  -- full command array (exe + args)
                cwd = nil,
                env = {},
                timeout = nil,
            }
            if test.properties then
                for _, prop in ipairs(test.properties) do
                    if prop.name == "WORKING_DIRECTORY" then
                        spec.cwd = prop.value
                    elseif prop.name == "ENVIRONMENT" then
                        -- ENVIRONMENT can appear multiple times (one per var)
                        local key, val = prop.value:match("^([^=]+)=(.*)")
                        if key then
                            spec.env[key] = val
                        end
                    elseif prop.name == "TIMEOUT" then
                        spec.timeout = tonumber(prop.value)
                    end
                end
            end
            exec_specs[exe] = spec
        end

        if is_individual then
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

--- Discover test targets and individual tests.
--- @return table[]|nil
function CTestUnit:discover()
    if self._entries then return self._entries end
    if not self._build_dir then return nil end

    local cmd = self:_base_cmd()
    cmd[#cmd + 1] = "--show-only=json-v1"

    local result = vim.system(cmd, { text = true, timeout = 10000 }):wait()
    if result.code ~= 0 or not result.stdout then return nil end

    local entries, exec_specs = parse_ctest_json(result.stdout)
    if not entries then return nil end

    self._exec_specs = exec_specs or {}

    -- Probe opaque targets for framework detection
    self:_probe_frameworks_sync(entries)

    -- Find source locations for gtest entries
    self:_find_sources(entries)

    self._entries = entries
    return entries
end

--- Async version of discover.
--- @param callback fun(entries: table[]|nil)
function CTestUnit:discover_async(callback)
    if self._entries then
        callback(self._entries)
        return
    end
    if not self._build_dir then
        callback(nil)
        return
    end

    local cmd = self:_base_cmd()
    cmd[#cmd + 1] = "--show-only=json-v1"
    local self_ref = self

    vim.system(cmd, { text = true, timeout = 10000 },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 or not result.stdout then
                    callback(nil)
                    return
                end
                local entries, exec_specs = parse_ctest_json(result.stdout)
                if not entries then
                    callback(nil)
                    return
                end
                self_ref._exec_specs = exec_specs or {}

                -- Probe frameworks async, then find sources
                self_ref:_probe_frameworks(entries, function()
                    self_ref:_find_sources(entries)
                    self_ref._entries = entries
                    callback(entries)
                end)
            end)
        end
    )
end

--- Probe opaque targets for framework (sync).
--- @param entries table[]
function CTestUnit:_probe_frameworks_sync(entries)
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

--- Probe opaque targets for framework (async).
--- @param entries table[]
--- @param callback fun()
function CTestUnit:_probe_frameworks(entries, callback)
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

    if #targets == 0 then
        callback()
        return
    end

    local pending = #targets
    for _, target in ipairs(targets) do
        gtest.probe(target.executable, target.id, function(framework, test_list)
            self._framework_cache[target.executable] = framework or false
            if framework and test_list then
                target.framework = framework
                for _, t in ipairs(test_list) do
                    entries[#entries + 1] = t
                end
            end
            pending = pending - 1
            if pending == 0 then callback() end
        end)
    end
end

--- Find source locations for gtest entries using file-api target data.
--- Matches ctest executables to cmake targets by artifact filename,
--- then scans source files for TEST() macros.
--- @param entries table[]
function CTestUnit:_find_sources(entries)
    local unit = self._config_unit
    if not unit or not unit.targets then return end

    -- Build a mapping from executable filename → target's source files
    local sources_by_exe_name = {}
    for _, target in pairs(unit.targets) do
        if target.sources and target.artifact then
            local art_name = vim.fn.fnamemodify(target.artifact, ":t"):gsub("%.exe$", ""):lower()
            sources_by_exe_name[art_name] = target.sources
        end
    end

    if not next(sources_by_exe_name) then return end

    -- Collect gtest entries grouped by executable
    local entries_by_exe = {}
    for _, e in ipairs(entries) do
        if e.framework == "gtest" and e.parent and e.executable then
            local exe_name = vim.fn.fnamemodify(e.executable, ":t"):gsub("%.exe$", ""):lower()
            if not entries_by_exe[exe_name] then
                entries_by_exe[exe_name] = {}
            end
            entries_by_exe[exe_name][#entries_by_exe[exe_name] + 1] = e
        end
    end

    -- Scan source files for each executable's tests
    for exe_name, exe_entries in pairs(entries_by_exe) do
        local sources = sources_by_exe_name[exe_name]
        if sources and #sources > 0 then
            gtest.find_source_locations(exe_entries, sources)
        end
    end
end

--- Construct command to run a specific test.
--- @param test_id string
--- @param opts? table { gtest_filter?: string }
--- @return table { cmd, env, cwd, output_path }
--- Find the execution spec for a test entry's executable.
--- @param test_id string
--- @return table|nil exec_spec { cmd, cwd, env, timeout }
--- @return string|nil executable path
function CTestUnit:_find_exec_spec(test_id)
    local exe = nil
    if self._entries then
        for _, e in ipairs(self._entries) do
            if e.id == test_id then
                exe = e.executable
                break
            end
            -- For individual tests, look up via parent target
            if e.id == test_id or (e.parent and e.id == test_id) then
                exe = e.executable
                break
            end
        end
    end
    if not exe then return nil, nil end
    return self._exec_specs[exe], exe
end

function CTestUnit:test_command(test_id, opts)
    opts = opts or {}

    -- Find the executable for this test
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
        -- Look up parent's executable
        for _, e in ipairs(self._entries) do
            if e.id == parent_id then
                exe = e.executable
                break
            end
        end
    end
    if not exe then return nil end

    local spec = self._exec_specs[exe]
    if not spec then return nil end

    -- Build command: original command + gtest flags
    local cmd = vim.deepcopy(spec.cmd)
    local env = vim.deepcopy(spec.env)

    -- Determine gtest filter
    local is_target = test_id:match("^target:")
    if not is_target then
        local test_name = test_id:match("^test:(.+)$") or test_id
        env.GTEST_FILTER = opts.gtest_filter or test_name
    elseif opts.gtest_filter then
        env.GTEST_FILTER = opts.gtest_filter
    end

    -- gtest XML output for per-test results and output capture
    local nvim_dir = self._build_dir .. "/.nvim"
    if not uv.fs_stat(nvim_dir) then
        uv.fs_mkdir(nvim_dir, 493) -- 0755
    end
    local gtest_xml = nvim_dir .. "/gtest_results.xml"
    cmd[#cmd + 1] = "--gtest_output=xml:" .. gtest_xml

    return {
        cmd = cmd,
        env = env,
        cwd = spec.cwd or self._build_dir,
        output_path = gtest_xml,
    }
end

--- Construct command to run all tests.
--- @param opts? table { filter?: string }
--- @return table { cmd, env, cwd, output_path }
function CTestUnit:test_command_all(opts)
    opts = opts or {}

    -- Find the first executable (for single-target projects)
    local exe = nil
    if self._entries then
        for _, e in ipairs(self._entries) do
            if e.executable then
                exe = e.executable
                break
            end
        end
    end
    if not exe then return nil end

    local spec = self._exec_specs[exe]
    if not spec then return nil end

    local cmd = vim.deepcopy(spec.cmd)
    local env = vim.deepcopy(spec.env)

    -- Apply filter via GTEST_FILTER if specified
    if opts.filter then
        env.GTEST_FILTER = opts.filter
    end

    local nvim_dir = self._build_dir .. "/.nvim"
    if not uv.fs_stat(nvim_dir) then
        uv.fs_mkdir(nvim_dir, 493) -- 0755
    end
    local gtest_xml = nvim_dir .. "/gtest_results.xml"
    cmd[#cmd + 1] = "--gtest_output=xml:" .. gtest_xml

    return {
        cmd = cmd,
        env = env,
        cwd = spec.cwd or self._build_dir,
        output_path = gtest_xml,
    }
end

--- Parse test results from gtest XML output.
--- @param output_path string
--- @return table[]|nil
function CTestUnit:parse_results(output_path)
    return gtest.parse_xml_results(output_path)
end

--- Invalidate all cached data.
function CTestUnit:invalidate()
    TestUnit.invalidate(self)
    self._ctest_dir = nil
    self._exec_specs = {}
    self._build_dir = self._config_unit:build_dir()
    self._configuration = self._config_unit:variant()
end

return CTestUnit
