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

--- Reach the logger through the owning workspace's core deps. Silently
--- no-ops when any link is missing (e.g. during isolated unit tests
--- where the ConfigUnit stub has no workspace back-reference).
--- @param self loomworks.MesonTestUnit
--- @return loomworks.Logger|nil
local function logger(self)
    local cu = self._config_unit
    local ws = cu and cu._workspace
    local core = ws and ws._core
    local deps = core and core._deps
    return deps and deps.log or nil
end

--- Treat vim.NIL (JSON null) as Lua nil for a single field. vim.NIL
--- is userdata and truthy in Lua, which poisons downstream overseer
--- specs if passed through (e.g. `spec.cwd or fallback` keeps vim.NIL).
--- @param v any
--- @return any|nil
local function denull(v)
    if v == vim.NIL then return nil end
    return v
end

--- Normalize a Windows path to a single separator style. Meson emits
--- paths with mixed `/` and `\` — Windows APIs handle that, but some
--- downstream tools (and human eyeballs reading the log) don't. We
--- standardize on `\` on Windows because that's what every Windows
--- shell and tool accepts without surprises; on POSIX we just return
--- the path unchanged.
--- @param p any
--- @return any
local function normalize_path(p)
    if type(p) ~= "string" or p == "" then return p end
    if vim.fn.has("win32") ~= 1 then return p end
    return (p:gsub("/", "\\"))
end

--- Build an env table for a test run.
---
--- On Windows the binary's DLL dependencies come from three distinct
--- places and we need all three on PATH with the right priority:
---
--- 1. The compiler's bin directory (e.g. `C:\mingw64\bin`) — source
---    of the C/C++ runtime DLLs (libstdc++-6.dll, libgcc_s_seh-1.dll,
---    or the MSVC redist). HIGHEST priority: if a wrong-version
---    runtime is picked up from elsewhere on PATH the binary hangs in
---    the loader with STATUS_ENTRYPOINT_NOT_FOUND.
--- 2. `extra_paths` reported by `meson introspect --tests` — the
---    project's own shared libraries.
--- 3. The current process env's PATH — everything else the binary or
---    its subprocesses might need.
---
--- Windows cmd.exe pseudo-variables whose name starts with "=" (e.g.
--- "=::", "=C:") track per-drive cwd state for cmd.exe and confuse
--- libuv's env-block formatter, so they are filtered out.
--- @param base_env table per-test env from meson introspect
--- @param extra_paths string[]
--- @param compiler_bin_dir string|nil toolchain bin dir (for runtime DLLs)
--- @return table<string, string>
local function compose_env(base_env, extra_paths, compiler_bin_dir)
    -- Prefix: compiler bin dir FIRST (for runtime DLLs), then extra_paths (for
    -- the project's shared libs). Both prepended so they win over inherited
    -- PATH. Shared PATH-composition lives in loomworks.runenv (also used by
    -- build-target launches).
    local prefix_parts = {}
    if compiler_bin_dir and compiler_bin_dir ~= "" then
        prefix_parts[#prefix_parts + 1] = compiler_bin_dir
    end
    for _, p in ipairs(extra_paths or {}) do
        prefix_parts[#prefix_parts + 1] = p
    end
    return require("loomworks.runenv").compose(prefix_parts, base_env)
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
        local name = denull(test.name)
        if not name then goto continue end

        local cmd_raw = denull(test.cmd)
        local cmd
        if type(cmd_raw) == "table" then
            cmd = {}
            for i, part in ipairs(cmd_raw) do
                cmd[i] = normalize_path(denull(part)) or ""
            end
        end
        local exe = (type(cmd) == "table" and cmd[1] ~= "" and cmd[1]) or nil

        if exe and not exec_specs[exe] then
            -- Strip vim.NIL values from the env table so we don't
            -- propagate them into the runtime environment.
            local env_clean = {}
            if type(test.env) == "table" then
                for k, v in pairs(test.env) do
                    local cv = denull(v)
                    if cv ~= nil then env_clean[k] = tostring(cv) end
                end
            end
            -- Collect Windows DLL / POSIX rpath paths meson requires to
            -- run the test. On Windows these MUST be prepended to PATH
            -- or the binary hangs / fails in the DLL loader.
            local extra_paths = {}
            if type(test.extra_paths) == "table" then
                for _, p in ipairs(test.extra_paths) do
                    local cp = denull(p)
                    if type(cp) == "string" and cp ~= "" then
                        extra_paths[#extra_paths + 1] = normalize_path(cp)
                    end
                end
            end
            exec_specs[exe] = {
                cmd = cmd,
                cwd = normalize_path(denull(test.workdir)),
                env = env_clean,
                extra_paths = extra_paths,
                timeout = tonumber(denull(test.timeout)) or nil,
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

    local log = logger(self)
    if log then log:debug("meson test discover: %s", table.concat(cmd, " ")) end

    local result = vim.system(cmd, { text = true, timeout = 10000 }):wait()
    if result.code ~= 0 or not result.stdout then
        if log then log:warn("meson test discover failed: code=%s stderr=%s",
            tostring(result.code), tostring(result.stderr or "")) end
        return nil
    end

    local entries, exec_specs = parse_meson_tests(result.stdout)
    if not entries then return nil end

    self._exec_specs = exec_specs or {}
    self:_log_exec_specs(log)

    self:_probe_frameworks_sync(entries)
    self:_find_sources(entries)

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
                self_ref:_log_exec_specs(logger(self_ref))

                self_ref:_probe_frameworks(entries, function()
                    self_ref:_find_sources(entries)
                    self_ref._entries = entries
                    callback(entries)
                end)
            end)
        end
    )
end

--- Read the toolchain's bin directory from the owning ConfigUnit's
--- tool_data, if the meson module populated it. Returns nil for
--- legacy non-keyed caches so we degrade to the old behaviour.
--- @return string|nil
function MesonTestUnit:_compiler_bin_dir()
    local td = self._config_unit and self._config_unit._tool_data
    if type(td) == "table" and type(td.compiler_bin_dir) == "string" then
        return td.compiler_bin_dir
    end
    return nil
end

--- Build probe opts (env + cwd) for a target executable, so gtest
--- probing inherits the same DLL / rpath paths meson prepared for the
--- test. Without this, probing a Windows binary whose DLLs live in the
--- build tree will hang in the loader and time out.
--- @param exe string executable path
--- @return { env: table<string,string>, cwd: string }
function MesonTestUnit:_probe_opts_for(exe)
    local spec = self._exec_specs[exe] or {}
    return {
        env = compose_env(spec.env, spec.extra_paths, self:_compiler_bin_dir()),
        cwd = spec.cwd or self._build_dir,
    }
end

--- Probe targets without a declared framework for gtest (sync).
---
--- Skips (without caching) any entry whose executable doesn't exist
--- yet. This lets discovery run the moment `meson introspect --tests`
--- has data — typically right after configure — without the probe
--- trying to spawn a binary that hasn't been built yet (which would
--- fail with ENOENT). The next discovery pass, invalidated after a
--- successful build via `record_task_result`, retries the probe.
---
--- @param entries table[]
function MesonTestUnit:_probe_frameworks_sync(entries)
    local log = logger(self)
    for _, e in ipairs(entries) do
        if not e.parent and not e.framework and e.executable then
            local cached = self._framework_cache[e.executable]
            if cached == nil then
                if not uv.fs_stat(e.executable) then
                    if log then
                        log:debug("meson gtest probe (sync) %s: skipped — binary not built yet",
                            e.executable)
                    end
                else
                    local framework, test_list, diag = gtest.probe_sync(
                        e.executable, e.id, self:_probe_opts_for(e.executable))
                    self._framework_cache[e.executable] = framework or false
                    if log then
                        log:debug("meson gtest probe (sync) %s: %s | %s",
                            e.executable, framework or "not detected", diag or "")
                    end
                    if framework and test_list then
                        e.framework = framework
                        for _, t in ipairs(test_list) do
                            entries[#entries + 1] = t
                        end
                    end
                end
            elseif cached and cached ~= false then
                e.framework = cached
            end
        end
    end
end

--- Probe targets async. See `_probe_frameworks_sync` for the
--- rationale behind the fs_stat guard.
--- @param entries table[]
--- @param callback fun()
function MesonTestUnit:_probe_frameworks(entries, callback)
    local log = logger(self)
    local targets = {}
    for _, e in ipairs(entries) do
        if not e.parent and not e.framework and e.executable then
            local cached = self._framework_cache[e.executable]
            if cached == nil then
                if not uv.fs_stat(e.executable) then
                    if log then
                        log:debug("meson gtest probe %s: skipped — binary not built yet",
                            e.executable)
                    end
                else
                    targets[#targets + 1] = e
                end
            elseif cached and cached ~= false then
                e.framework = cached
            end
        end
    end
    if #targets == 0 then callback() return end

    local remaining = #targets
    for _, target in ipairs(targets) do
        gtest.probe(target.executable, target.id, self:_probe_opts_for(target.executable), function(framework, test_list, diag)
            self._framework_cache[target.executable] = framework or false
            if log then
                log:debug("meson gtest probe %s: %s | %s",
                    target.executable, framework or "not detected", diag or "")
            end
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

--- Populate `file` + `line` on each discovered gtest entry by
--- scanning the target's source files for TEST/TEST_F/TEST_P macros.
---
--- Matches the MesonTestUnit exe path to a parsed meson target by
--- executable filename (with `.exe` stripped on Windows), reads the
--- `sources` list that `modules/meson.parse_targets` attached to the
--- target, and hands it off to the shared `gtest.find_source_locations`.
--- Mirrors CTestUnit's `_find_sources`.
--- @param entries table[]
function MesonTestUnit:_find_sources(entries)
    local unit = self._config_unit
    if not unit or not unit.targets then return end

    -- Map executable filename → target.sources
    local sources_by_exe_name = {}
    for _, target in pairs(unit.targets) do
        if target.sources and target.artifact then
            local art_name = vim.fn.fnamemodify(target.artifact, ":t")
                :gsub("%.exe$", ""):lower()
            sources_by_exe_name[art_name] = target.sources
        end
    end
    if not next(sources_by_exe_name) then return end

    -- Group gtest case entries by the executable they live in
    local entries_by_exe = {}
    for _, e in ipairs(entries) do
        if e.framework == "gtest" and e.parent and e.executable then
            local exe_name = vim.fn.fnamemodify(e.executable, ":t")
                :gsub("%.exe$", ""):lower()
            entries_by_exe[exe_name] = entries_by_exe[exe_name] or {}
            table.insert(entries_by_exe[exe_name], e)
        end
    end

    for exe_name, exe_entries in pairs(entries_by_exe) do
        local sources = sources_by_exe_name[exe_name]
        if sources and #sources > 0 then
            gtest.find_source_locations(exe_entries, sources)
        end
    end
end

--- Log a terse summary of each discovered exec spec (cmd, cwd, env
--- keys, extra_paths) at DEBUG level. Env values are not logged to
--- keep sensitive material (PATH, tokens) out of the on-disk log.
--- @param log loomworks.Logger|nil
function MesonTestUnit:_log_exec_specs(log)
    if not log then return end
    for exe, spec in pairs(self._exec_specs) do
        local env_keys = {}
        for k in pairs(spec.env or {}) do env_keys[#env_keys + 1] = k end
        table.sort(env_keys)
        log:debug("meson exec_spec for %s: cmd=%s cwd=%s timeout=%s env_keys=[%s] extra_paths=%d",
            exe,
            vim.inspect(spec.cmd),
            tostring(spec.cwd),
            tostring(spec.timeout),
            table.concat(env_keys, ","),
            spec.extra_paths and #spec.extra_paths or 0)
        if spec.extra_paths and #spec.extra_paths > 0 then
            log:debug("  extra_paths: %s", table.concat(spec.extra_paths, " | "))
        end
    end
end

--- Find a test entry by id. Returns the first matching entry or nil.
--- @param test_id string
--- @return table|nil
function MesonTestUnit:_entry(test_id)
    if not self._entries then return nil end
    for _, e in ipairs(self._entries) do
        if e.id == test_id then return e end
    end
    return nil
end

--- Build a gtest-style run spec (filter + XML output) for a gtest
--- executable. Adds gtest-specific CLI flags that require the target
--- to actually be a gtest binary — caller must confirm framework first.
--- @param exe string
--- @param filter? string GTEST_FILTER value
--- @return table|nil
function MesonTestUnit:_build_gtest_run(exe, filter)
    local spec = self._exec_specs[exe]
    if not spec then return nil end

    local cmd = vim.deepcopy(spec.cmd)
    local env = compose_env(spec.env, spec.extra_paths, self:_compiler_bin_dir())
    if filter then
        env.GTEST_FILTER = filter
    end

    local nvim_dir = self._build_dir .. "/.nvim"
    if not uv.fs_stat(nvim_dir) then
        uv.fs_mkdir(nvim_dir, 493) -- 0755
    end
    local xml = nvim_dir .. "/gtest_results.xml"
    cmd[#cmd + 1] = "--gtest_output=xml:" .. xml

    local result = {
        cmd = cmd,
        env = env,
        cwd = spec.cwd or self._build_dir,
        output_path = xml,
    }
    local log = logger(self)
    if log then
        log:debug("meson gtest run: cmd=%s cwd=%s path_len=%d filter=%s",
            vim.inspect(result.cmd), tostring(result.cwd),
            #(env.PATH or ""), tostring(filter))
        log:debug("meson gtest run PATH=%s", env.PATH or "")
    end
    return result
end

--- Build a plain run spec that invokes the test executable exactly as
--- meson introspect reported it. Used for frameworks we don't have
--- specific handling for (or opaque targets where the probe was
--- inconclusive). No extra CLI flags, no structured result parsing.
--- @param exe string
--- @return table|nil
function MesonTestUnit:_build_plain_run(exe)
    local spec = self._exec_specs[exe]
    if not spec then return nil end
    local env = compose_env(spec.env, spec.extra_paths, self:_compiler_bin_dir())
    local result = {
        cmd = vim.deepcopy(spec.cmd),
        env = env,
        cwd = spec.cwd or self._build_dir,
        output_path = nil,
    }
    local log = logger(self)
    if log then
        log:debug("meson plain run: cmd=%s cwd=%s path_len=%d",
            vim.inspect(result.cmd), tostring(result.cwd), #(env.PATH or ""))
        log:debug("meson plain run PATH=%s", env.PATH or "")
    end
    return result
end

--- Determine the detected framework for an entry, walking up to parent.
--- @param entry table|nil
--- @return string|nil
function MesonTestUnit:_framework_for(entry)
    if not entry then return nil end
    if entry.framework then return entry.framework end
    if entry.parent then
        local parent = self:_entry(entry.parent)
        if parent and parent.framework then return parent.framework end
    end
    return nil
end

--- @param test_id string
--- @param opts? table { gtest_filter? }
--- @return table|nil
function MesonTestUnit:test_command(test_id, opts)
    opts = opts or {}

    local entry = self:_entry(test_id)
    if not entry then return nil end

    local exe = entry.executable
    if not exe and entry.parent then
        local parent = self:_entry(entry.parent)
        exe = parent and parent.executable or nil
    end
    if not exe then return nil end

    local framework = self:_framework_for(entry)

    if framework == "gtest" then
        local filter
        local is_target = test_id:match("^target:")
        if not is_target then
            filter = opts.gtest_filter or (test_id:match("^test:(.+)$") or test_id)
        elseif opts.gtest_filter then
            filter = opts.gtest_filter
        end
        return self:_build_gtest_run(exe, filter)
    end

    -- Unknown framework — run the executable exactly as meson reported
    -- it. No per-test filtering or XML capture.
    return self:_build_plain_run(exe)
end

--- @param opts? table { filter? }
--- @return table|nil
function MesonTestUnit:test_command_all(opts)
    opts = opts or {}
    local entry, exe = nil, nil
    if self._entries then
        for _, e in ipairs(self._entries) do
            if e.executable then
                entry = e
                exe = e.executable
                break
            end
        end
    end
    if not exe then return nil end

    if self:_framework_for(entry) == "gtest" then
        return self:_build_gtest_run(exe, opts.filter)
    end
    return self:_build_plain_run(exe)
end

--- Native meson test run: authoritative exit code, streaming output.
--- `meson test -C <build_dir>` runs every declared test.
--- @param opts? table { filter?: string, extra_args?: string[], junit?: string }
--- @return table|nil { cmd, env, cwd, junit_out }
function MesonTestUnit:run_command_all(opts)
    opts = opts or {}
    local prefix = meson_prefix_for(self._config_unit)
    if not prefix or not self._build_dir then return nil end
    local cmd = vim.list_extend({}, prefix)
    cmd[#cmd + 1] = "test"
    -- Print failing tests' output on the console (ctest's --output-on-failure
    -- equivalent); otherwise meson only writes it to meson-logs/testlog.txt.
    cmd[#cmd + 1] = "--print-errorlogs"
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = self._build_dir
    if opts.filter then cmd[#cmd + 1] = opts.filter end  -- meson filters by test name
    -- Caller args (from `lw test -- …`, e.g. `--num-processes N`) go last.
    if opts.extra_args then vim.list_extend(cmd, opts.extra_args) end
    -- `meson test` REBUILDS stale targets before running (which is why
    -- a headless test run skips building this unit itself), so it needs the
    -- same toolchain environment a build gets. Composed by the module so both
    -- paths agree: without MSVC's vcvars env (INCLUDE / LIB / PATH-to-cl) the
    -- implicit ninja rebuild dies with "CreateProcess failed" — cl is not on
    -- PATH — turning `lw test` on a stale tree into a false failure.
    local ok_mod, meson_mod = pcall(require, "loomworks.modules.meson")
    local task_env = (ok_mod and meson_mod.compose_task_env)
        and meson_mod.compose_task_env({}, self._config_unit._tool_data) or nil
    return {
        cmd = cmd,
        env = compose_env(task_env, nil, self:_compiler_bin_dir()),
        cwd = self._build_dir,
        -- meson has no output-path flag: it always writes JUnit to this fixed
        -- location under the build dir. Reported only when JUnit was requested,
        -- so the core copies it to the caller's path.
        junit_out = opts.junit and (self._build_dir .. "/meson-logs/testlog.junit.xml") or nil,
    }
end

--- `meson test` rebuilds test dependencies before running, so a headless test
--- run need not build this unit separately.
--- @return boolean
function MesonTestUnit:run_command_all_rebuilds()
    return true
end

--- @param output_path string|nil
--- @return table[]|nil
function MesonTestUnit:parse_results(output_path)
    if not output_path then return nil end  -- plain-run path has no structured results
    return gtest.parse_xml_results(output_path)
end

--- Invalidate cached data.
function MesonTestUnit:invalidate()
    TestUnit.invalidate(self)
    self._exec_specs = {}
    self._build_dir = self._config_unit:build_dir()
end

return MesonTestUnit
