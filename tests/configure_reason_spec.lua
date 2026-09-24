--- Why a configure runs (headless §16.4, core §5.1 / §8.1 `reconfigure`) and
--- the forced full reconfigure (`lw build --reconfigure`).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

local GCC_TOOL = {
    key = "ninja-gcc-13",
    data = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake" },
}

--- cmake project App/Debug with `options`, profile `debug` on gcc + Ninja, in
--- a real temp root (the configure builder writes file-api markers).
local function make_core(options)
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = { configurations = { Debug = {
                variant = "Debug", options = options,
            } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = GCC_TOOL.key, data = GCC_TOOL.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = modules_get },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = GCC_TOOL.key, tool_data = GCC_TOOL.data, tool_label = GCC_TOOL.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    return ws, profile, profile:projects()[1]._config_unit, root
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, res = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(res))
    return res
end

local function plan(ws, profile, opts)
    return with_ws(ws, function() return overseer.plan_profile_build(profile, opts) end)
end

local function configure_step(steps)
    for _, s in ipairs(steps or {}) do if s.kind == "configure" then return s end end
end

local function has(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

describe("configure reason", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end -- no cache tools on "PATH"
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    --- Plan + record a successful configure so the unit is up to date.
    local function configure_once(ws, profile)
        local step = configure_step(plan(ws, profile))
        assert.is_not_nil(step)
        require("loomworks.cli")._record_step(ws, step, true)
        return step
    end

    it("first configure", function()
        local ws, profile, _, r = make_core()
        root = r
        local step = configure_step(plan(ws, profile))
        assert.equals("first configure", step.configure_reason)
        assert.equals("initial", step.reconfigure)
        assert.equals("configure: first configure", overseer.configure_reason_line(step))
    end)

    it("an option removed → full reconfigure naming the option", function()
        local ws, profile, unit, r = make_core({ FOO = "1", BAR = "2" })
        root = r
        configure_once(ws, profile)
        assert.is_nil(configure_step(plan(ws, profile)))
        -- The user drops FOO (the Configuration and the module's view of it).
        unit._configuration.options = { BAR = "2" }
        local mc = unit._project.configurations and unit._project.configurations.Debug
        if mc then mc.options = { BAR = "2" } end
        assert.equals("options changed (FOO removed)", unit:stale_reason())
        local step = configure_step(plan(ws, profile))
        assert.is_true(has(step.cmd, "--fresh"))
        assert.equals("full reconfigure (--fresh): options changed (FOO removed)",
            overseer.configure_reason_line(step))
    end)

    it("a configuration environment change → full reconfigure", function()
        local ws, profile, unit, r = make_core()
        root = r
        configure_once(ws, profile)
        unit._configuration.env = { SCCACHE_DIR = "/c" }
        assert.equals("configuration environment changed", unit:stale_reason())
        assert.equals("full reconfigure (--fresh): configuration environment changed",
            overseer.configure_reason_line(configure_step(plan(ws, profile))))
    end)

    it("a launcher that appeared on a gcc unit → in-place reconfigure", function()
        local ws, profile, unit, r = make_core()
        root = r
        configure_once(ws, profile)
        cpp.lookup_path = function(n) return n == "ccache" and "/usr/bin/ccache" or nil end
        assert.equals("compiler launcher changed", unit:stale_reason())
        local step = configure_step(plan(ws, profile))
        assert.is_false(has(step.cmd, "--fresh"))
        assert.equals("reconfigure (in place): compiler launcher changed",
            overseer.configure_reason_line(step))
    end)

    it("below CMake 3.24 the full path names the reset", function()
        local ws, profile, unit, r = make_core()
        root = r
        unit.state_value = "built"
        unit._cached_options = unit:resolved_option_fingerprint()
        unit.module_info = {}
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 21 } }
        assert.equals(
            "full reconfigure (reset CMakeCache.txt + CMakeFiles): configure record from an older lw",
            overseer.configure_reason_line(configure_step(plan(ws, profile))))
    end)

    it("a failed configure is retried with its reason", function()
        local ws, profile, unit, r = make_core()
        root = r
        local step = configure_step(plan(ws, profile))
        require("loomworks.cli")._record_step(ws, step, false)
        assert.equals("configure_failed", unit:state())
        assert.equals("previous configure failed", configure_step(plan(ws, profile)).configure_reason)
    end)

    it("composes the line for a module that does not classify", function()
        assert.equals("configure: project files changed",
            overseer.configure_reason_line({ configure_reason = "project files changed" }))
        assert.is_nil(overseer.configure_reason_line({}))
    end)
end)

describe("forced full reconfigure (--reconfigure)", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("plans a FULL configure for an up-to-date unit, then nothing sticks", function()
        local ws, profile, unit, r = make_core({ FOO = "1" })
        root = r
        local first = configure_step(plan(ws, profile))
        require("loomworks.cli")._record_step(ws, first, true)
        assert.is_false(unit:is_stale())
        assert.is_nil(configure_step(plan(ws, profile)))

        local step = configure_step(plan(ws, profile, { reconfigure = true }))
        assert.is_not_nil(step)
        assert.is_true(has(step.cmd, "--fresh"))
        assert.equals("full reconfigure (--fresh): forced (--reconfigure)",
            overseer.configure_reason_line(step))
        require("loomworks.cli")._record_step(ws, step, true)
        -- Transient: the next plain build does not reconfigure.
        assert.is_nil(configure_step(plan(ws, profile)))
    end)

    it("a never-configured unit reports a first configure", function()
        local ws, profile, _, r = make_core()
        root = r
        local step = configure_step(plan(ws, profile, { reconfigure = true }))
        assert.equals("first configure", step.configure_reason)
    end)

    it("meson takes --wipe when forced", function()
        local build_dir = vim.fn.tempname()
        vim.fn.mkdir(build_dir .. "/meson-info", "p")
        local rec = { cache_launcher = "none", passed_options = {}, buildtype = "debug",
            record_version = meson.configure_record_version }
        local t
        for _, td in ipairs(meson.tasks({
            name = "App", path = "app", workspace_root = "/root",
            tool_data = { meson = { "/usr/bin/meson" } },
            configurations = { Debug = { buildtype = "debug" } }, env = {},
            cached_build_dir = build_dir, recorded_module_info = rec,
            recorded_cache_launcher = "none", force_full_reconfigure = true,
        }, "Debug")) do
            if td.loomworks.action == "configure" then t = td end
        end
        assert.same({ "meson-private/cmd_line.txt" }, t.loomworks.pre_configure_reset)
        assert.is_true(has(t.builder().cmd, "--wipe"))
        vim.fn.delete(build_dir, "rf")
    end)

    it("`lw build <profile> --reconfigure` runs the forced configure and prints why", function()
        local ws, profile, _, r = make_core({ FOO = "1" })
        root = r
        local cli = require("loomworks.cli")
        local first = configure_step(plan(ws, profile))
        cli._record_step(ws, first, true)

        local spawned, written = {}, {}
        local orig_spawn, orig_write = cli._run_spec, io.write
        cli._run_spec = function(step) spawned[#spawned + 1] = step; return 0 end
        io.write = function(...) for _, s in ipairs({ ... }) do written[#written + 1] = s end end
        local ok, err = pcall(function()
            with_ws(ws, function() return cli.cmd_build(ws, { "build", profile.key, "--reconfigure" }) end)
        end)
        io.write = orig_write
        cli._run_spec = orig_spawn
        assert.is_true(ok, tostring(err))

        assert.equals("configure", spawned[1].kind)
        assert.is_true(has(spawned[1].cmd, "--fresh"))
        assert.equals("build", spawned[2].kind)
        local text = table.concat(written)
        assert.matches("    full reconfigure %(%-%-fresh%): forced %(%-%-reconfigure%)", text)
    end)
end)
