--- Regression tests for the "build directory deleted out of band" deadlock.
---
--- State is normally derived purely from the cache; the physical build
--- directory is never stat'd. So when a user deletes `.nvim/build` behind
--- loomworks' back, the surviving `loomworks.cache.json` reloads the unit as
--- `built`. The build gate only configures `unconfigured` / `configure_failed`
--- / stale units, so it skips configure and runs `cmake --build <missing dir>`
--- which fails → `failed_build`, which is *also* not a configure trigger →
--- every subsequent build fails the same way: a permanent deadlock.
---
--- The fix (spec §3.1 rule 7, §4.6): a cached `configured` / `built` /
--- `build_failed` / `configure_failed` unit whose build directory is absent on
--- disk resets to `unconfigured` on the next load/remerge, and is re-checked at
--- the build gate so a directory that vanishes after remerge still reconfigures.
--- `unknown` / `deleting` are exempt to preserve async-deletion crash safety.
---
--- Detection is a plain directory stat, injected via `deps.dir_exists` so these
--- tests can simulate a present/absent directory with no real filesystem.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

--- Real module registry get(), guarded against nil ids.
local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

--- A fully-controlled module whose build-dir path carries a compiler segment,
--- mirroring meson/cmake. Lets us drive overseer.plan_profile_build with no
--- build toolchain installed. (Copied from meson_reconfigure_spec.)
local function make_fake_module()
    return {
        id = "fakemod",
        api_version = 1,
        has_keyed_tools = true,
        languages = { "c++" },
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return (a.compiler_id or a.id) == (b.compiler_id or b.id)
        end,
        tool_key = function(td) return td and (td.compiler_id or td.id) or nil end,
        tool_label = function(td) return td and (td.compiler_id or td.id) or "fake" end,
        resolve_build_dir = function(project_name, config_name, _config_info, root, tool_data)
            local seg = tool_data and (tool_data.compiler_id or tool_data.id) or nil
            local base = root .. "/.nvim/build/" .. project_name
            if seg then return base .. "/" .. seg .. "/" .. (config_name or "default") end
            return base .. "/" .. (config_name or "default")
        end,
        info = function(_, type_config)
            local Configuration = require("loomworks.configuration")
            local configs = Configuration.canonicalize(
                {}, type_config and type_config.configurations, "fakemod")
            return { configurations = configs }
        end,
        tasks = function(project, active_config)
            local build_dir = project.cached_build_dir
            local function td(action)
                return {
                    name = project.name .. ": " .. action,
                    builder = function() return { cmd = { "true" } } end,
                    loomworks = {
                        project_key = project.name,
                        action = action,
                        configuration_key = project.configuration_key or active_config,
                        build_dir = build_dir,
                    },
                }
            end
            return { td("configure"), td("build") }
        end,
    }
end

--- Count plan steps by kind.
local function count_kind(steps, kind)
    local n = 0
    for _, s in ipairs(steps or {}) do
        if s.kind == kind then n = n + 1 end
    end
    return n
end

--- Resolve the ConfigUnit driven for a project (single-profile workspaces).
local function profile_unit(core, project_key)
    local ws = core:get_workspace()
    for _, profile in pairs(ws._profiles) do
        for _, pp in ipairs(profile:projects()) do
            if pp._init_project_key == project_key then
                return pp._config_unit, pp, profile
            end
        end
    end
    return nil
end

local CONFIG = {
    projects = { App = { fakemod = { configurations = { Debug = {} } } } },
    configuration_sets = { debug = { App = "Debug" } },
}
local USER = {
    profiles = {
        debug = {
            configuration_set = "debug",
            tools = { fakemod = { key = "cc", data = { compiler_id = "cc" } } },
        },
    },
}
local TOOLS = {
    fakemod = { { tool_key = "cc", tool_data = { compiler_id = "cc" }, tool_label = "cc" } },
}

--- Build a Core over the fake module. `dir_exists` and `cache` overrides let a
--- caller simulate a reload with an absent build directory.
local function build_core(cache_overrides, dir_exists)
    local fake = make_fake_module()
    local function fake_get(id)
        if id == "fakemod" then return fake end
        return modules_get(id)
    end
    local files = {
        ["loomworks.json"] = h.make_config_json(CONFIG),
        ["loomworks.user.json"] = h.make_user_json(USER),
    }
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end
    local opts = {
        modules = { get = fake_get },
        cache = { save = function() return true end },
    }
    if dir_exists then opts.dir_exists = dir_exists end
    local deps = h.make_test_deps(files, opts)
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    if not cache_overrides then
        -- Fresh workspace: inject detected tools and remerge (module detection
        -- needs real modules the mock can't provide).
        core._workspace._tools_by_type = TOOLS
        core:remerge()
    end
    return core
end

--- Drive the real planner (overseer.plan_profile_build) through the loomworks
--- singleton seam, returning its steps.
local function plan(core, profile)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return core:get_workspace() end
    local ok, steps = pcall(overseer.plan_profile_build, profile)
    loomworks.get_workspace = orig
    assert.is_true(ok, "plan_profile_build errored: " .. tostring(steps))
    return steps
end

--- Build the unit and return the serialized cache (state = built).
local function built_cache()
    local core = build_core(nil, nil)
    local unit = profile_unit(core, "App")
    assert.is_not_nil(unit)
    local build_dir = unit:build_dir()
    core:record_task_result({ unit = unit, action = "configure", success = true, build_dir = build_dir })
    core:record_task_result({ unit = unit, action = "build", success = true, build_dir = build_dir })
    assert.equals("built", unit:state())
    return core:get_workspace():_serialize_cache(), build_dir
end

describe("build directory removed out of band", function()

    it("resets a cached built unit to unconfigured on reload when its dir is gone", function()
        local cache = built_cache()

        -- Reload: cache still says built, but the directory is absent on disk.
        local core = build_core(cache, function() return false end)
        local unit, _, profile = profile_unit(core, "App")
        assert.is_not_nil(unit)

        -- Primary fix: the load/remerge resets the vanished unit.
        assert.equals("unconfigured", unit:state())

        -- Build gate: the planner emits a configure step (deadlock broken).
        local steps = plan(core, profile)
        assert.is_true(count_kind(steps, "configure") >= 1)
    end)

    it("re-checks at the build gate when the dir vanishes after remerge", function()
        local cache = built_cache()

        -- The directory is present during setup/remerge (unit stays built), then
        -- is deleted before the build gate runs.
        local present = true
        local core = build_core(cache, function() return present end)
        local unit, _, profile = profile_unit(core, "App")
        assert.is_not_nil(unit)
        assert.equals("built", unit:state())  -- survived remerge

        present = false  -- user rm -rf's the build dir now
        local steps = plan(core, profile)
        assert.is_true(count_kind(steps, "configure") >= 1)
    end)

    it("does NOT reset an 'unknown' unit whose dir is absent (deletion crash safety)", function()
        local cache = built_cache()
        -- Simulate a crash mid-deletion: the crash-safe sequence set the entry
        -- to `unknown` BEFORE removing the directory (spec §4.6).
        for _, entry in pairs(cache.build_dirs or {}) do
            entry.state = "unknown"
        end

        local core = build_core(cache, function() return false end)
        local unit = profile_unit(core, "App")
        assert.is_not_nil(unit)
        -- Must stay unknown: downgrading it could let a build run into a
        -- directory that is being deleted.
        assert.equals("unknown", unit:state())
    end)

end)
