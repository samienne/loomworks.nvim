--- Regression tests for the "meson re-runs setup every time" bug.
---
--- A ConfigUnit's identity is (project_key, config_key). Its build-dir path is
--- a derived value persisted in the cache. When a cache entry is written
--- without tool_data, the compiler path segment can't be recomputed on reload,
--- so the recomputed build-dir key no longer matches the stored key. The unit
--- must still be matched to its persisted state on the stable
--- (project_key, variant, tool_key) tuple — otherwise it reloads as
--- "unconfigured" and the planner re-runs configure every build.
---
--- These drive a full Core reload from a serialized cache and assert the unit
--- stays built, that genuine reconfigure triggers still fire, and that the
--- planner (overseer.plan_profile_build) emits no configure step when nothing
--- changed.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

--- Real module registry get(), guarded against nil ids (the test-deps mock
--- tolerates nil; the real registry concatenates the id into a require path).
local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

--- Build a Core from in-memory files. When tools_by_type is supplied it is
--- injected and the workspace remerged (module detection needs real modules).
local function make_core(config_overrides, user_overrides, cache_overrides, tools_by_type)
    local files = { ["loomworks.json"] = h.make_config_json(config_overrides) }
    if user_overrides then
        files["loomworks.user.json"] = h.make_user_json(user_overrides)
    end
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end
    local deps = h.make_test_deps(files, {
        modules = { get = modules_get },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    if tools_by_type then
        core._workspace._tools_by_type = tools_by_type
        core:remerge()
    end
    return core
end

--- Mirror overseer.filter_unconfigured_tasks: a configure step is emitted iff
--- the unit is unconfigured/configure_failed, stale, or its project needs
--- refresh. Kept in lockstep with that filter so these tests track the planner
--- without depending on a build toolchain being installed.
local function planner_needs_configure(unit)
    local state = unit:state()
    if state == "unconfigured" or state == "configure_failed" then return true end
    if unit:is_stale() then return true end
    if unit._project and unit._project.needs_refresh then return true end
    return false
end

--- Resolve the ConfigUnit driven for a project. Each test has a single
--- profile, so we don't depend on its (derived) key.
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

--- Build a unit through the real record_task_result path, serialize the cache,
--- then strip tool_data from every entry so the compiler segment can't be
--- recomputed on the next load. Returns the serialized (stripped) cache table.
local function build_and_strip_cache(core, unit)
    local build_dir = unit:build_dir()
    core:record_task_result({ unit = unit, action = "configure", success = true, build_dir = build_dir })
    core:record_task_result({ unit = unit, action = "build", success = true, build_dir = build_dir })
    assert.equals("built", unit:state())
    local cache = core:get_workspace():_serialize_cache()
    for _, entry in pairs(cache.build_dirs or {}) do
        entry.tool_data = nil
    end
    return cache, build_dir
end

describe("config unit cache matching survives a lost path segment", function()

    it("meson: unit stays built across reload when cache entry lacks tool_data", function()
        local config = {
            projects = { App = { meson = {} } },
            configuration_sets = { debug = { App = "Debug" } },
        }
        local user = {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    tools = { meson = { key = "gcc-12", data = { compiler_id = "gcc-12", meson = { "meson" } } } },
                },
            },
        }
        local tools = {
            meson = {
                { tool_key = "gcc-12", tool_data = { compiler_id = "gcc-12", meson = { "meson" } }, tool_label = "gcc 12" },
            },
        }

        -- Phase 1: build the unit (with a detected compiler) and persist.
        local core1 = make_core(config, user, nil, tools)
        local unit1 = profile_unit(core1, "App")
        assert.is_not_nil(unit1)
        assert.truthy(unit1:build_dir():match("gcc%-12"))
        local cache = build_and_strip_cache(core1, unit1)

        -- Phase 2: fresh load, no detected tools. The recomputed build-dir key
        -- would drop the compiler segment; the stable-tuple match must win.
        local core2 = make_core(config, user, cache, nil)
        local unit2 = profile_unit(core2, "App")
        assert.is_not_nil(unit2)
        assert.equals("built", unit2:state())
        assert.truthy(unit2.id:match("gcc%-12"))
        assert.is_false(planner_needs_configure(unit2))
    end)

    it("cmake: same fix applies (module-agnostic)", function()
        local config = {
            projects = { Lib = { cmake = {} } },
            configuration_sets = { debug = { Lib = "Debug" } },
        }
        local user = {
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" } } },
                },
            },
        }
        local tools = {
            cmake = {
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
        }

        local core1 = make_core(config, user, nil, tools)
        local unit1 = profile_unit(core1, "Lib")
        assert.is_not_nil(unit1)
        assert.truthy(unit1:build_dir():match("ninja%-gcc"))
        local cache = build_and_strip_cache(core1, unit1)

        local core2 = make_core(config, user, cache, nil)
        local unit2 = profile_unit(core2, "Lib")
        assert.is_not_nil(unit2)
        assert.equals("built", unit2:state())
        assert.truthy(unit2.id:match("ninja%-gcc"))
        assert.is_false(planner_needs_configure(unit2))
    end)

end)

describe("genuine reconfigure triggers still fire after the fix", function()

    it("changed build options mark the reloaded unit stale (is_stale)", function()
        local tools = {
            cmake = {
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
        }
        local user = {
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" } } },
                },
            },
        }
        -- Phase 1: build with a user config carrying options { O = "1" }.
        local config_v1 = {
            projects = { Lib = { cmake = { configurations = { Debug = { options = { O = "1" } } } } } },
            configuration_sets = { debug = { Lib = "Debug" } },
        }
        local core1 = make_core(config_v1, user, nil, tools)
        local unit1 = profile_unit(core1, "Lib")
        assert.is_not_nil(unit1)
        local cache = build_and_strip_cache(core1, unit1)

        -- Phase 2: reload, but the config's options changed to { O = "2" }.
        -- The unit re-adopts its persisted (built) state, yet the option
        -- delta must still mark it stale so the planner configures.
        local config_v2 = {
            projects = { Lib = { cmake = { configurations = { Debug = { options = { O = "2" } } } } } },
            configuration_sets = { debug = { Lib = "Debug" } },
        }
        local core2 = make_core(config_v2, user, cache, nil)
        local unit2 = profile_unit(core2, "Lib")
        assert.is_not_nil(unit2)
        assert.equals("built", unit2:state())
        assert.is_true(unit2:is_stale())
        assert.is_true(planner_needs_configure(unit2))
    end)

    it("meson.build edited after last configure marks the project needs_refresh", function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. "/App", "p")
        local f = io.open(root .. "/App/meson.build", "w")
        f:write("project('app', 'cpp')\n")
        f:close()

        local config = {
            projects = { App = { meson = {} } },
            configuration_sets = { debug = { App = "Debug" } },
        }
        local user = {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    tools = { meson = { key = "gcc-12", data = { compiler_id = "gcc-12", meson = { "meson" } } } },
                },
            },
        }
        local tools = {
            meson = {
                { tool_key = "gcc-12", tool_data = { compiler_id = "gcc-12", meson = { "meson" } }, tool_label = "gcc 12" },
            },
        }

        -- Phase 1: build on a real workspace root. record_task_result stamps
        -- last_configured with the test clock (a fixed year-2000 timestamp),
        -- which is older than the meson.build we just wrote.
        local files1 = {
            ["loomworks.json"] = h.make_config_json(config),
            ["loomworks.user.json"] = h.make_user_json(user),
        }
        local deps1 = h.make_test_deps(files1, {
            modules = { get = modules_get }, cache = { save = function() return true end },
            -- Stamp last_configured well before the meson.build we just wrote.
            now = function() return "2000-01-01T00:00:00Z" end,
        })
        local core1 = Core.new(deps1)
        core1:setup({ root = root })
        core1._workspace._tools_by_type = tools
        core1:remerge()
        local unit1 = profile_unit(core1, "App")
        assert.is_not_nil(unit1)
        local build_dir = unit1:build_dir()
        core1:record_task_result({ unit = unit1, action = "configure", success = true, build_dir = build_dir })
        core1:record_task_result({ unit = unit1, action = "build", success = true, build_dir = build_dir })
        local cache = core1:get_workspace():_serialize_cache()

        -- Phase 2: fresh reload — inspect() sees meson.build newer than the
        -- cached last_configured and flags the project for refresh.
        local files2 = {
            ["loomworks.json"] = h.make_config_json(config),
            ["loomworks.user.json"] = h.make_user_json(user),
            ["loomworks.cache.json"] = h.make_cache_json(cache),
        }
        local deps2 = h.make_test_deps(files2, {
            modules = { get = modules_get }, cache = { save = function() return true end },
        })
        local core2 = Core.new(deps2)
        core2:setup({ root = root })
        local unit2, _, _ = profile_unit(core2, "App")
        assert.is_not_nil(unit2)
        assert.equals("built", unit2:state())
        assert.is_true(unit2._project.needs_refresh)
        assert.is_true(planner_needs_configure(unit2))
    end)

end)

--- A fully-controlled module whose build-dir path carries a compiler segment
--- (dropped when tool_data has no id), mirroring meson/cmake. Lets us drive
--- overseer.plan_profile_build deterministically, with no build toolchain.
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

describe("plan_profile_build after reload (real planner)", function()

    it("emits no configure step for a reloaded-built unit, one when it needs refresh", function()
        local fake = make_fake_module()
        local function fake_get(id)
            if id == "fakemod" then return fake end
            return modules_get(id)
        end

        local config = {
            projects = { App = { fakemod = { configurations = { Debug = {} } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }
        local user = {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    tools = { fakemod = { key = "cc", data = { compiler_id = "cc" } } },
                },
            },
        }
        local tools = {
            fakemod = { { tool_key = "cc", tool_data = { compiler_id = "cc" }, tool_label = "cc" } },
        }

        local function build_core(config_o, user_o, cache_o, tools_o)
            local files = {
                ["loomworks.json"] = h.make_config_json(config_o),
                ["loomworks.user.json"] = h.make_user_json(user_o),
            }
            if cache_o then files["loomworks.cache.json"] = h.make_cache_json(cache_o) end
            local deps = h.make_test_deps(files, {
                modules = { get = fake_get }, cache = { save = function() return true end },
            })
            local core = Core.new(deps)
            core:setup({ root = "/root" })
            if tools_o then
                core._workspace._tools_by_type = tools_o
                core:remerge()
            end
            return core
        end

        -- Phase 1: build and persist, then strip tool_data (segment would drop).
        local core1 = build_core(config, user, nil, tools)
        local unit1 = profile_unit(core1, "App")
        assert.is_not_nil(unit1)
        assert.truthy(unit1:build_dir():match("/cc/"))
        local cache = build_and_strip_cache(core1, unit1)

        -- Phase 2: fresh reload, no detected tools.
        local core2 = build_core(config, user, cache, nil)
        local unit2, _, profile2 = profile_unit(core2, "App")
        assert.is_not_nil(unit2)
        assert.equals("built", unit2:state())

        -- Drive the real planner through the singleton seam.
        local loomworks = require("loomworks")
        local orig = loomworks.get_workspace
        loomworks.get_workspace = function() return core2:get_workspace() end
        local ok_a, steps = pcall(overseer.plan_profile_build, profile2)
        local ok_b, stale_steps
        if ok_a then
            -- Now the project needs a refresh: a configure step must appear.
            unit2._project.needs_refresh = true
            ok_b, stale_steps = pcall(overseer.plan_profile_build, profile2)
        end
        loomworks.get_workspace = orig

        assert.is_true(ok_a, "plan_profile_build errored: " .. tostring(steps))
        assert.equals(0, count_kind(steps, "configure"))
        assert.is_true(count_kind(steps, "build") >= 1)

        assert.is_true(ok_b, "plan_profile_build errored: " .. tostring(stale_steps))
        assert.is_true(count_kind(stale_steps, "configure") >= 1)
    end)

end)
