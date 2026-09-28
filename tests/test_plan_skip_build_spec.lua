--- Regression: `lw test` on a fresh clone must not run a full `meson compile`
--- before `meson test` (headless §16.16, core §8.9.2).
---
--- `meson test` rebuilds exactly the targets its tests need, so a headless test
--- run drops the unit's separate build step. #58 (workspace trust, §17.8) gated
--- `ConfigUnit:test_units()` on `configured_here()` — correctly, since discovery
--- runs binaries from the build dir — but the planner asked that same gated
--- accessor whether the unit's runner self-rebuilds. On a fresh clone every unit
--- is unconfigured when the plan is made (configure is one of its steps), so
--- `test_units()` returned `{}` and the full build step was kept.
---
--- These drive the real planner (`overseer.plan_profile_build`) over real
--- meson / cmake ConfigUnits. Nothing is spawned: planning only builds commands.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local MESON_TOOL = { key = "gcc-12", data = { compiler_id = "gcc-12", meson = { "meson" } } }
local CMAKE_TOOL = { key = "ninja-gcc", data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" } }

--- One project App/Debug of `mod_type` + profile `debug` on `tool`, in a real
--- temp root. Returns the workspace, profile, and the profile's ConfigUnit.
local function make_ws(mod_type, tool)
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { [mod_type] = { configurations = { Debug = { variant = "Debug" } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { [mod_type] = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { [mod_type] = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    local unit = profile:projects()[1]._config_unit
    return ws, profile, unit
end

--- Run the real planner through the loomworks singleton seam.
local function plan(ws, profile, opts)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, steps, err = pcall(overseer.plan_profile_build, profile, opts)
    loomworks.get_workspace = orig
    assert.is_true(ok, "plan_profile_build raised: " .. tostring(steps))
    assert.is_nil(err, "plan_profile_build refused: " .. tostring(err))
    return steps
end

local function count_kind(steps, kind)
    local n = 0
    for _, s in ipairs(steps or {}) do
        if s.kind == kind then n = n + 1 end
    end
    return n
end

describe("plan_profile_build { for_test = true } (§16.16 self-rebuilding runners)", function()

    it("meson, unconfigured (fresh clone): configure is planned, the build step is dropped", function()
        local ws, profile, unit = make_ws("meson", MESON_TOOL)
        assert.is_not_nil(unit)
        assert.equals("unconfigured", unit:state())

        local steps = plan(ws, profile, { for_test = true })
        assert.equals(1, count_kind(steps, "configure"))
        assert.equals(0, count_kind(steps, "build"),
            "meson test rebuilds what the tests need; no full meson compile")
    end)

    it("meson, unconfigured: planning discovers nothing and caches no TestUnit (§17.8)", function()
        local ws, profile, unit = make_ws("meson", MESON_TOOL)
        plan(ws, profile, { for_test = true })
        assert.same({}, unit:test_units())
        assert.is_nil(unit._test_units, "the trust-gated TestUnit cache stays empty")
    end)

    it("meson, configured here: the build step is still dropped", function()
        local ws, profile, unit = make_ws("meson", MESON_TOOL)
        ws._core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir() })
        assert.is_true(unit:configured_here())

        local steps = plan(ws, profile, { for_test = true })
        assert.equals(0, count_kind(steps, "configure"))
        assert.equals(0, count_kind(steps, "build"))
    end)

    it("meson, without for_test: the build step is kept", function()
        local ws, profile = make_ws("meson", MESON_TOOL)
        local steps = plan(ws, profile)
        assert.equals(1, count_kind(steps, "build"))
    end)

    it("cmake (ctest does not rebuild), unconfigured: the build step is kept", function()
        local ws, profile = make_ws("cmake", CMAKE_TOOL)
        local steps = plan(ws, profile, { for_test = true })
        assert.equals(1, count_kind(steps, "configure"))
        assert.equals(1, count_kind(steps, "build"))
    end)

    it("cmake, configured here: the build step is kept", function()
        local ws, profile, unit = make_ws("cmake", CMAKE_TOOL)
        ws._core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir() })
        local steps = plan(ws, profile, { for_test = true })
        assert.equals(1, count_kind(steps, "build"))
    end)
end)
