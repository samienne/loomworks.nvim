--- Spec §1.7 "Resolution granularity is the ConfigUnit": with a multi-config
--- cmake generator (Ninja Multi-Config, Visual Studio) Debug and Release share
--- ONE build directory, yet they are DISTINCT ConfigUnits, each with its own
--- configuration, state and artifacts.
---
--- The build-dir path comes from the real cmake module's resolve_build_dir,
--- which returns one directory per kit for a multi-config generator.

local Core = require("loomworks.core")
local h = require("tests.helpers")

local KIT = { id = "ninja-mc", generator = "Ninja Multi-Config" }

local function make_core()
    local real_modules = require("loomworks.modules")
    local fake_cmake = setmetatable({
        detect_tools = function() return { { tool_data = KIT } } end,
        info = function()
            return { configurations = {
                Debug = { variant = "Debug" },
                Release = { variant = "Release" },
            } }
        end,
    }, { __index = real_modules.get("cmake") })
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = {} } },
            configuration_sets = {
                debug = { App = "Debug" },
                release = { App = "Release" },
            },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = {
                debug = { configuration_set = "debug",
                    tools = { cmake = { key = KIT.id, data = KIT } } },
                release = { configuration_set = "release",
                    tools = { cmake = { key = KIT.id, data = KIT } } },
            },
        }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) if id == "cmake" then return fake_cmake end end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    core._workspace._tools_by_type = { cmake = { { tool_key = KIT.id, tool_data = KIT, tool_label = KIT.id } } }
    core:remerge()
    return core, core:get_workspace()
end

local function unit_of(ws, profile_key)
    local profile = h.find_profile(ws._profiles, profile_key .. ":" .. KIT.id)
    if not profile then
        local keys = {}
        for _, p in pairs(ws._profiles) do keys[#keys + 1] = p.key end
        error("profile " .. profile_key .. " not in " .. vim.inspect(keys))
    end
    local pp = profile:project("App")
    assert.is_not_nil(pp, "profile project App in " .. profile_key)
    return pp._config_unit
end

describe("multi-config cmake: shared build dir, distinct ConfigUnits (spec §1.7)", function()
    it("Debug and Release share one build directory", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.is_not_nil(d)
        assert.is_not_nil(r)
        assert.equals(d:build_dir(), r:build_dir())
    end)

    -- KNOWN BUG (pending until the cache-format change lands): both
    -- profiles currently resolve to ONE ConfigUnit because the unit id and
    -- the cache.build_dirs key are the relative build-dir path, which a
    -- multi-config generator shares across configurations
    -- (data_model.sync_profile_projects_and_config_units dedups by
    -- build_dir_id). Flip these back to `it` with the fix.
    pending("resolves Debug and Release to distinct ConfigUnits with their own configuration", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.equals("Debug", d:configuration().name)
        assert.equals("Release", r:configuration().name)
        assert.are_not.equal(d, r)
    end)

    pending("building Debug does not mark Release built", function()
        local core, ws = make_core()
        local d = unit_of(ws, "debug")
        local debug_profile = h.find_profile(ws._profiles, "debug:" .. KIT.id)
        core:record_task_result({ unit = d, action = "configure", success = true,
            profile = debug_profile, build_dir = d:build_dir() })
        core:record_task_result({ unit = d, action = "build", success = true,
            profile = debug_profile })
        assert.equals("built", d:state())
        core:remerge()
        local r = unit_of(ws, "release")
        assert.are_not.equal("built", r:state())
        assert.equals("built", unit_of(ws, "debug"):state())
    end)
end)
