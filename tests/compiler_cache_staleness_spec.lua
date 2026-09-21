--- Tests for compiler-cache launcher staleness (§5.1, module §11).
---
--- Two layers: (A) the ConfigUnit-level recompute/compare
--- (`launcher_changed` / `is_stale`) with a stubbed PATH lookup — install,
--- remove, unchanged, policy-edit, never-configured; and (B) the real
--- `record_task_result` freeze (a reconfigure with no launcher CLEARS the
--- recorded one — the additive module_info merge cannot) plus the build gate
--- picking up the staleness.

local cpp = require("loomworks.cpp_compilers")
local h = require("tests.helpers")

-- Stub cpp.lookup_path so resolution is deterministic without a real PATH.
local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- (A) ConfigUnit-level recompute/compare
-- ---------------------------------------------------------------------------
describe("ConfigUnit launcher staleness", function()
    after_each(function() cpp.lookup_path = orig_lookup end)
    local Configuration = require("loomworks.configuration")
    local Project = require("loomworks.project")

    --- A configured unit: `family` selects the compiler, `recorded` is the
    --- launcher frozen at configure, `cfg_data` extends the configuration.
    local function make_configured(family, recorded, cfg_data)
        local core = h.make_mock_core()
        local project = Project.new(core, "App", {
            type = "cmake", path = "App",
            configurations = {}, cached_configurations = {},
        })
        core._projects.App = project
        local cfg = Configuration.new(project, "Debug",
            vim.tbl_extend("force", { variant = "Debug" }, cfg_data or {}))
        project._configurations[#project._configurations + 1] = cfg
        local unit = core:ensure_config_unit(project, cfg, nil)
        unit._tool_data = { compiler_family = family }
        -- Simulate a configure snapshot.
        unit._cached_options = unit:resolved_option_fingerprint()
        unit._cached_module_config = cfg.module_config
        unit.module_info = { cache_launcher = recorded }
        return unit
    end

    it("cache installed after a feature configure (recorded \"none\") → stale", function()
        -- A unit configured UNDER the feature with no cache records "none", so a
        -- later-installed cache differs → stale (install-after-configure).
        local unit = make_configured("gcc", "none")
        set_present({ ccache = true })
        assert.is_true(unit:launcher_changed())
        assert.is_true(unit:is_stale())
    end)

    it("legacy unit (nil recorded) is NEVER stale, cache present or absent", function()
        -- Configured before the feature: unknown launcher state. Must not be
        -- retroactively invalidated just because a cache is now installed.
        local u1 = make_configured("gcc", nil)
        set_present({ ccache = true })
        assert.is_false(u1:launcher_changed())
        assert.is_false(u1:is_stale())

        local u2 = make_configured("gcc", nil)
        set_present({})
        assert.is_false(u2:launcher_changed())
        assert.is_false(u2:is_stale())
    end)

    it("feature configure with no cache stays not-stale while still no cache", function()
        local unit = make_configured("gcc", "none")
        set_present({})
        assert.is_false(unit:launcher_changed())
        assert.is_false(unit:is_stale())
    end)

    it("cache removed after configure → stale", function()
        local unit = make_configured("gcc", "/usr/bin/ccache")
        set_present({})
        assert.is_true(unit:launcher_changed())
        assert.is_true(unit:is_stale())
    end)

    it("launcher unchanged → not stale", function()
        local unit = make_configured("gcc", "/usr/bin/ccache")
        set_present({ ccache = true })
        assert.is_false(unit:launcher_changed())
        assert.is_false(unit:is_stale())
    end)

    it("policy edited to off → stale (was ccache)", function()
        local unit = make_configured("gcc", "/usr/bin/ccache", { variables = { cache = "off" } })
        set_present({ ccache = true })
        assert.is_true(unit:launcher_changed())
    end)

    it("msvc auto prefers sccache → differs from a recorded ccache", function()
        local unit = make_configured("msvc", "/usr/bin/ccache")
        set_present({ ccache = true, sccache = true })
        -- msvc auto resolves sccache, but the unit was configured with ccache.
        assert.is_true(unit:launcher_changed())
    end)

    it("never-configured unit is never launcher-stale", function()
        local core = h.make_mock_core()
        local project = Project.new(core, "App", {
            type = "cmake", path = "App",
            configurations = {}, cached_configurations = {},
        })
        core._projects.App = project
        local cfg = Configuration.new(project, "Debug", { variant = "Debug" })
        project._configurations[1] = cfg
        local unit = core:ensure_config_unit(project, cfg, nil)
        unit._tool_data = { compiler_family = "gcc" }
        set_present({ ccache = true })
        assert.is_false(unit:launcher_changed())
        assert.is_false(unit:is_stale())
    end)
end)

-- ---------------------------------------------------------------------------
-- (B) record_task_result freeze + build gate
-- ---------------------------------------------------------------------------
describe("launcher freeze at record_task_result", function()
    after_each(function() cpp.lookup_path = orig_lookup end)
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")

    local function modules_get(id)
        if not id then return nil end
        return real_modules.get(id)
    end

    local function make_core()
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = {
                    debug = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = {
                            compiler_id = "gcc-12", generator = "Ninja",
                            compiler_path = "/usr/bin/g++",
                        } } },
                    },
                },
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = {
            cmake = { {
                tool_key = "ninja-gcc-12",
                tool_data = { compiler_id = "gcc-12", generator = "Ninja", compiler_path = "/usr/bin/g++" },
                tool_label = "gcc 12",
            } },
        }
        core:remerge()
        return core
    end

    local function unit_for(core)
        local ws = core:get_workspace()
        for _, profile in pairs(ws._profiles) do
            for _, pp in ipairs(profile:projects()) do
                if pp._init_project_key == "App" then return pp._config_unit end
            end
        end
    end

    --- Mirror overseer.filter_unconfigured_tasks' staleness leg.
    local function gate_needs_configure(unit)
        local state = unit:state()
        if state == "unconfigured" or state == "configure_failed" then return true end
        return unit:is_stale()
    end

    it("a configure records the launcher; a reconfigure OVERWRITES it", function()
        local core = make_core()
        local unit = unit_for(core)
        assert.is_not_nil(unit)
        local bd = unit:build_dir()

        -- Configure WITH a launcher.
        core:record_task_result({
            unit = unit, action = "configure", success = true, build_dir = bd,
            module_info = { generator = "Ninja", cache_launcher = "/usr/bin/ccache" },
        })
        assert.equals("/usr/bin/ccache", unit.module_info.cache_launcher)

        -- Reconfigure with the module's "none" sentinel (no cache): the additive
        -- module_info merge alone could not replace the old path, so the explicit
        -- freeze must — otherwise is_stale would compare against a stale value.
        core:record_task_result({
            unit = unit, action = "configure", success = true, build_dir = bd,
            module_info = { generator = "Ninja", cache_launcher = "none" },
        })
        assert.equals("none", unit.module_info.cache_launcher)

        -- And an explicit nil still clears (defensive — the freeze uses `or nil`).
        core:record_task_result({
            unit = unit, action = "configure", success = true, build_dir = bd,
            module_info = { generator = "Ninja", cache_launcher = nil },
        })
        assert.is_nil(unit.module_info.cache_launcher)
    end)

    it("the build gate reconfigures a unit whose launcher was removed", function()
        local core = make_core()
        local unit = unit_for(core)
        local bd = unit:build_dir()

        -- Configure while ccache was present (recorded as such).
        core:record_task_result({
            unit = unit, action = "configure", success = true, build_dir = bd,
            module_info = { generator = "Ninja", cache_launcher = "/usr/bin/ccache" },
        })

        -- ccache still on PATH → not stale, gate does not reconfigure.
        set_present({ ccache = true })
        assert.is_false(gate_needs_configure(unit))

        -- ccache removed → launcher disappeared → stale → gate reconfigures.
        set_present({})
        assert.is_true(gate_needs_configure(unit))
    end)
end)
