--- Configure-record migration (core §5.1 *Configure record migration*, §8.1
--- `configure_record_version`; cmake §5d, meson §5a).
---
--- Real-world regression (lw v0.1.29-beta.6, Windows MSVC + Ninja): a build
--- dir configured by an earlier beta with sccache under `auto` kept
--- `CMAKE_CXX_COMPILER_LAUNCHER=…sccache.exe` in CMakeCache.txt, while its
--- cache record had an EMPTY `module_info` (an older CLI dropped the module
--- record). `auto` is now off for MSVC-style compilers, but the nil recorded
--- launcher hit the legacy carve-out, so the unit was never stale, the build
--- gate never reconfigured, Ninja's own re-run kept the stale launcher and
--- every `/Zi` compile failed (C1041). A configured unit whose record predates
--- the module's record format must be stale and take exactly ONE full
--- reconfigure, after which the fresh record makes it stable.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "C:/tools/" .. name .. ".exe" end
        return nil
    end
end

local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

local MSVC_TOOL = {
    key = "ninja-msvc-17",
    data = { compiler_id = "msvc-17", generator = "Ninja", cmake_path = "/fake/cmake" },
}

--- A workspace with one cmake project `App` (Debug) and a profile `debug`
--- using `tool` (default: MSVC + Ninja). Root is a real temp dir: the cmake
--- configure builder writes file-api query markers under the build dir.
local function make_core(tool, cfg_extra)
    tool = tool or MSVC_TOOL
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local project = { cmake = { configurations = { Debug = vim.tbl_extend("force",
        { variant = "Debug" }, cfg_extra or {}) } } }
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = project },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = modules_get },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    local unit = profile:projects()[1]._config_unit
    return core, ws, profile, unit, root
end

--- Turn `unit` into the tester's legacy unit: configured (state built, option
--- snapshot present) with the given module_info (default: EMPTY).
local function make_legacy(unit, module_info)
    unit.state_value = "built"
    unit._cached_options = unit:resolved_option_fingerprint()
    unit._cached_module_config = unit._configuration.module_config
    unit.module_info = module_info or {}
end

local function plan(ws, profile, opts)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, steps = pcall(overseer.plan_profile_build, profile, opts)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(steps))
    return steps
end

local function configure_step(steps)
    for _, s in ipairs(steps or {}) do if s.kind == "configure" then return s end end
end

local function has_prefix(cmd, prefix)
    for _, a in ipairs(cmd) do
        if type(a) == "string" and a:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function has(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

describe("configure-record migration (legacy build dirs)", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        set_present({ sccache = true })
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("legacy MSVC unit with an EMPTY module_info under cache=auto(off) is stale", function()
        local _, _, _, unit, r = make_core()
        root = r
        make_legacy(unit, {})
        assert.is_true(unit:record_outdated())
        assert.is_true(unit:is_stale())
        assert.equals("configure record from an older lw", unit:stale_reason())
    end)

    it("legacy unit with NO module_info at all is stale too", function()
        local _, _, _, unit, r = make_core()
        root = r
        make_legacy(unit, nil)
        unit.module_info = nil
        assert.is_true(unit:is_stale())
    end)

    it("the gate's configure is FULL (--fresh, no launcher -D), then stable", function()
        local _, ws, profile, unit, r = make_core()
        root = r
        make_legacy(unit, {})

        local step = configure_step(plan(ws, profile))
        assert.is_not_nil(step, "legacy unit must be reconfigured by the build gate")
        assert.is_true(has(step.cmd, "--fresh"), vim.inspect(step.cmd))
        assert.is_false(has_prefix(step.cmd, "-U"))
        assert.is_false(has_prefix(step.cmd, "-DCMAKE_CXX_COMPILER_LAUNCHER"))
        assert.is_false(has_prefix(step.cmd, "-DCMAKE_C_COMPILER_LAUNCHER"))
        assert.is_false(has_prefix(step.cmd, "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
        assert.equals("configure record from an older lw", step.configure_reason)
        assert.equals("full reconfigure (--fresh): configure record from an older lw",
            overseer.configure_reason_line(step))

        -- The CLI records the configure result (success).
        require("loomworks.cli")._record_step(ws, step, true)
        assert.equals(cmake.configure_record_version, unit.module_info.record_version)
        assert.equals("none", unit.module_info.cache_launcher)
        assert.is_table(unit.module_info.passed_options)
        assert.is_false(unit:is_stale())

        -- A second build does NOT reconfigure.
        assert.is_nil(configure_step(plan(ws, profile)))
    end)

    it("the editor gate (shared filter) selects the legacy unit with its reason", function()
        local _, ws, profile, unit, r = make_core()
        root = r
        make_legacy(unit, {})
        local td = { loomworks = { unit = unit, action = "configure" } }
        local sel = overseer._filter_unconfigured_tasks({ configure = { td }, build = {} })
        assert.equals(1, #sel)
        assert.equals("configure record from an older lw", td.loomworks.configure_reason)
        -- Unused but keeps the workspace alive for the unit.
        assert.is_not_nil(ws and profile)
    end)

    it("a recorded launcher that no longer matches (older record) → stale → full", function()
        local _, ws, profile, unit, r = make_core()
        root = r
        -- Configured by an earlier beta: sccache under auto, with a record.
        make_legacy(unit, {
            generator = "Ninja", cache_launcher = "C:/tools/sccache.exe",
            passed_options = {
                CMAKE_BUILD_TYPE = "Debug", CMAKE_EXPORT_COMPILE_COMMANDS = "ON",
                CMAKE_C_COMPILER_LAUNCHER = "C:/tools/sccache.exe",
                CMAKE_CXX_COMPILER_LAUNCHER = "C:/tools/sccache.exe",
                CMAKE_MSVC_DEBUG_INFORMATION_FORMAT = "Embedded",
            },
        })
        assert.is_true(unit:is_stale())
        local step = configure_step(plan(ws, profile))
        assert.is_not_nil(step)
        assert.is_true(has(step.cmd, "--fresh"))
        assert.is_false(has_prefix(step.cmd, "-DCMAKE_CXX_COMPILER_LAUNCHER"))
    end)

    it("a current record whose launcher no longer matches is launcher-stale", function()
        local _, _, _, unit, r = make_core()
        root = r
        make_legacy(unit, {
            generator = "Ninja", cache_launcher = "C:/tools/sccache.exe",
            record_version = cmake.configure_record_version,
            passed_options = { CMAKE_BUILD_TYPE = "Debug" },
        })
        assert.equals("compiler launcher changed", unit:stale_reason())
    end)

    it("a FAILED migration configure stays stale (full again), a success settles it", function()
        local _, ws, profile, unit, r = make_core()
        root = r
        make_legacy(unit, {})
        local step = configure_step(plan(ws, profile))
        local cli = require("loomworks.cli")
        cli._record_step(ws, step, false)
        assert.is_nil(unit.module_info.record_version)
        assert.equals("configure_failed", unit:state())
        local retry = configure_step(plan(ws, profile))
        assert.is_not_nil(retry)
        assert.is_true(has(retry.cmd, "--fresh"))
        cli._record_step(ws, retry, true)
        assert.is_nil(configure_step(plan(ws, profile)))
    end)

    it("a preset configuration migrates once, then stays stable with sccache present", function()
        local _, ws, _, unit, r = make_core()
        root = r
        -- A preset configuration (the module cannot apply a launcher to it).
        unit._configuration.from_preset = true
        make_legacy(unit, {})
        assert.is_true(unit:is_stale())
        -- Its (full) configure records "none" + the appended user options.
        ws:record_task_result({ unit = unit, action = "configure", success = true,
            module_info = { cache_launcher = "none", passed_options = {} } })
        assert.is_false(unit:is_stale())
    end)

    it("a Visual Studio generator unit migrates once, then stays stable", function()
        local vs = { key = "vs-17", data = {
            compiler_id = "msvc-17", generator = "Visual Studio 17 2022", cmake_path = "/fake/cmake",
        } }
        local _, ws, profile, unit, r = make_core(vs)
        root = r
        make_legacy(unit, { cache_launcher = "C:/tools/sccache.exe" })
        assert.is_true(unit:is_stale())
        local step = configure_step(plan(ws, profile))
        assert.is_not_nil(step)
        assert.is_true(has(step.cmd, "--fresh"))
        require("loomworks.cli")._record_step(ws, step, true)
        assert.equals("none", unit.module_info.cache_launcher)
        assert.is_false(unit:is_stale())
        assert.is_nil(configure_step(plan(ws, profile)))
    end)

    it("a module without configure_record_version never takes the record check", function()
        local _, _, _, unit, r = make_core()
        root = r
        make_legacy(unit, {})
        local impl = vim.tbl_extend("force", {}, cmake)
        impl.configure_record_version = nil
        unit._project._module = require("loomworks.module").new("cmake", impl)
        assert.is_false(unit:record_outdated())
    end)

    it("a never-configured unit is not record-stale", function()
        local _, _, _, unit, r = make_core()
        root = r
        assert.is_false(unit:record_outdated())
        assert.is_false(unit:is_stale())
    end)
end)

describe("meson configure-record migration", function()
    it("a legacy record (no record_version) takes the full --wipe once", function()
        local build_dir = vim.fn.tempname()
        vim.fn.mkdir(build_dir .. "/meson-info", "p")
        local function setup(rec)
            for _, t in ipairs(meson.tasks({
                name = "App", path = "app", workspace_root = "/root",
                tool_data = { meson = { "/usr/bin/meson" } },
                configurations = { Debug = { buildtype = "debug" } }, env = {},
                cached_build_dir = build_dir,
                recorded_module_info = rec,
                recorded_cache_launcher = rec and rec.cache_launcher or nil,
            }, "Debug")) do
                if t.loomworks.action == "configure" then return t end
            end
        end
        -- Empty legacy record → full.
        local t = setup({})
        assert.same({ "meson-private/cmd_line.txt" }, t.loomworks.pre_configure_reset)
        assert.equals("full", t.loomworks.reconfigure)
        assert.equals("--wipe", t.loomworks.reconfigure_detail)
        -- A record with passed_options but no version (older lw) → full.
        local rec = vim.deepcopy(t.loomworks.module_info)
        assert.is_not_nil(setup(rec).loomworks.pre_configure_reset)
        -- Stamped with the current version (core does this on success) → in place.
        rec.record_version = meson.configure_record_version
        local t2 = setup(rec)
        assert.is_nil(t2.loomworks.pre_configure_reset)
        assert.equals("in_place", t2.loomworks.reconfigure)
        vim.fn.delete(build_dir, "rf")
    end)
end)
