local h = require("tests.helpers")
local ConfigUnit = require("loomworks.config_unit")
local Project = require("loomworks.project")

describe("ConfigUnit", function()
    --- Helper: ensure a Project exists in the mock workspace registry.
    local function ensure_project(core, project_key, type_name)
        type_name = type_name or "cmake"
        if not core._projects[project_key] then
            core._projects[project_key] = Project.new(core, project_key, {
                type = type_name, path = project_key, status = "unconfigured",
                configurations = {}, cached_configurations = {},
            })
        end
        return core._projects[project_key]
    end

    local function make_unit(core_overrides)
        local core = h.make_mock_core(core_overrides)
        local project = ensure_project(core, "App")
        local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
        return unit, core
    end

    describe("identity", function()
        it("stores id as cache dict key", function()
            local unit = make_unit()
            assert.equals("App/Debug", unit.id)
        end)

    end)

    describe("registry", function()
        it("returns same instance for same key pair", function()
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local u1 = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            local u2 = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            assert.equals(u1, u2)
            assert.is_true(rawequal(u1, u2))
        end)

        it("returns different instances for different keys", function()
            local core = h.make_mock_core()
            local app = ensure_project(core, "App")
            local lib = ensure_project(core, "Lib")
            local u1 = core:ensure_config_unit(app, h.get_or_create_config(app, "Debug"), nil)
            local u2 = core:ensure_config_unit(app, h.get_or_create_config(app, "Release"), nil)
            local u3 = core:ensure_config_unit(lib, h.get_or_create_config(lib, "Debug"), nil)
            assert.is_false(rawequal(u1, u2))
            assert.is_false(rawequal(u1, u3))
        end)
    end)

    describe("state", function()
        it("returns unconfigured by default", function()
            local unit = make_unit()
            assert.equals("unconfigured", unit:state())
        end)

        it("returns cached state when present", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "built",
                                },
                            },
                        },
                    }
                end,
            })
            assert.equals("built", unit:state())
        end)

        it("maps failed_configure to configure_failed", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "failed_configure",
                                },
                            },
                        },
                    }
                end,
            })
            assert.equals("configure_failed", unit:state())
        end)

        it("maps failed_build to build_failed", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "failed_build",
                                },
                            },
                        },
                    }
                end,
            })
            assert.equals("build_failed", unit:state())
        end)

        it("returns configuring when configure task is running", function()
            local unit = make_unit()
            unit:register_task(1, "configure")
            assert.equals("configuring", unit:state())
        end)

        it("returns building when build task is running", function()
            local unit = make_unit()
            unit:register_task(1, "build")
            assert.equals("building", unit:state())
        end)

        it("running state takes priority over cached state", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "configured",
                                },
                            },
                        },
                    }
                end,
            })
            unit:register_task(1, "build")
            assert.equals("building", unit:state())
        end)

        it("returns deleting when marked", function()
            local unit = make_unit()
            unit:mark_deleting(true)
            assert.equals("deleting", unit:state())
        end)

        it("deleting takes priority over running", function()
            local unit = make_unit()
            unit:register_task(1, "build")
            unit:mark_deleting(true)
            assert.equals("deleting", unit:state())
        end)

        it("returns unknown when cached state is unknown", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "unknown",
                                },
                            },
                        },
                    }
                end,
            })
            assert.equals("unknown", unit:state())
        end)
    end)

    describe("is_running", function()
        it("returns false by default", function()
            local unit = make_unit()
            assert.is_false(unit:is_running())
        end)

        it("returns true when task registered", function()
            local unit = make_unit()
            unit:register_task(1, "configure")
            assert.is_true(unit:is_running())
        end)

        it("returns false after task unregistered", function()
            local unit = make_unit()
            unit:register_task(1, "configure")
            unit:unregister_task(1)
            assert.is_false(unit:is_running())
        end)
    end)

    describe("running_action", function()
        it("returns nil by default", function()
            local unit = make_unit()
            assert.is_nil(unit:running_action())
        end)

        it("returns the action of the running task", function()
            local unit = make_unit()
            unit:register_task(1, "build")
            assert.equals("build", unit:running_action())
        end)
    end)

    describe("register_task / unregister_task", function()
        it("tracks the task id", function()
            local unit = make_unit()
            unit:register_task(42, "configure")
            assert.equals(42, unit._task_id)
            assert.equals("configure", unit._action)
        end)

        it("unregister clears state but preserves last_task_id", function()
            local unit = make_unit()
            unit:register_task(42, "configure")
            unit:unregister_task(42)
            assert.is_nil(unit._task_id)
            assert.is_nil(unit._action)
            assert.is_nil(unit._progress)
            assert.is_nil(unit._start_time)
            assert.equals(42, unit:last_task_id())
        end)

        it("unregister ignores mismatched task id", function()
            local unit = make_unit()
            unit:register_task(42, "configure")
            unit:unregister_task(99)
            assert.equals(42, unit._task_id)
            assert.equals("configure", unit._action)
        end)

        it("last_task_id updates on each register", function()
            local unit = make_unit()
            unit:register_task(1, "configure")
            assert.equals(1, unit:last_task_id())
            unit:unregister_task(1)
            unit:register_task(2, "build")
            assert.equals(2, unit:last_task_id())
        end)

        it("register clears previous progress", function()
            local unit = make_unit()
            unit:register_task(1, "configure")
            unit:update_progress(1, { current = 5, total = 10 })
            unit:register_task(2, "build")
            assert.is_nil(unit:progress())
        end)
    end)

    describe("progress", function()
        it("returns nil by default", function()
            local unit = make_unit()
            assert.is_nil(unit:progress())
        end)

        it("returns progress after update", function()
            local unit = make_unit()
            unit:register_task(1, "build")
            unit:update_progress(1, { current = 3, total = 10 })
            local p = unit:progress()
            assert.equals(3, p.current)
            assert.equals(10, p.total)
        end)

        it("ignores update for wrong task id", function()
            local unit = make_unit()
            unit:register_task(1, "build")
            unit:update_progress(99, { current = 3, total = 10 })
            assert.is_nil(unit:progress())
        end)
    end)

    describe("elapsed", function()
        it("returns nil when no task running", function()
            local unit = make_unit()
            assert.is_nil(unit:elapsed())
        end)

        it("returns elapsed time from clock", function()
            local time = 100
            local ws = h.make_mock_core({ _core = { _deps = { clock = function() return time end } } })
            local project = ensure_project(ws, "App")
            local unit = ws:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)

            unit:register_task(1, "build")
            time = 105
            assert.equals(5, unit:elapsed())
        end)
    end)

    describe("cached_state", function()
        it("returns nil when no workspace", function()
            -- Create a bare ConfigUnit without a workspace to test nil case
            local unit = ConfigUnit.new(nil, "App/Debug", "App")
            assert.is_nil(unit:cached_state())
        end)

        it("returns cached config when present", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    state = "built",
                                    build_dir = "/build/App/Debug",
                                },
                            },
                        },
                    }
                end,
            })
            local cached = unit:cached_state()
            assert.equals("built", cached.state)
            assert.equals("/build/App/Debug", cached.build_dir)
        end)
    end)

    -- build_dir() is a trivial accessor over cached_state() — covered by cached_state tests above.

    describe("is_deleting", function()
        it("returns false by default", function()
            local unit = make_unit()
            assert.is_false(unit:is_deleting())
        end)

        it("returns true when marked", function()
            local unit = make_unit()
            unit:mark_deleting(true)
            assert.is_true(unit:is_deleting())
        end)

        it("returns false after unmarked", function()
            local unit = make_unit()
            unit:mark_deleting(true)
            unit:mark_deleting(false)
            assert.is_false(unit:is_deleting())
        end)
    end)

    describe("listeners", function()
        it("fires on register_task", function()
            local unit = make_unit()
            local called = 0
            unit:on_state_change(function() called = called + 1 end)
            unit:register_task(1, "configure")
            assert.equals(1, called)
        end)

        it("fires on unregister_task", function()
            local unit = make_unit()
            local states = {}
            unit:on_state_change(function(u) states[#states + 1] = u:state() end)
            unit:register_task(1, "configure")
            unit:unregister_task(1)
            assert.equals(2, #states)
            assert.equals("configuring", states[1])
            assert.equals("unconfigured", states[2])
        end)

        it("fires on mark_deleting", function()
            local unit = make_unit()
            local called = false
            unit:on_state_change(function() called = true end)
            unit:mark_deleting(true)
            assert.is_true(called)
        end)

        it("fires on update_progress", function()
            local unit = make_unit()
            local called = false
            unit:on_state_change(function() called = true end)
            unit:register_task(1, "build")
            called = false
            unit:update_progress(1, { current = 1, total = 5 })
            assert.is_true(called)
        end)

        it("multiple listeners all fire", function()
            local unit = make_unit()
            local a, b = 0, 0
            unit:on_state_change(function() a = a + 1 end)
            unit:on_state_change(function() b = b + 1 end)
            unit:register_task(1, "build")
            assert.equals(1, a)
            assert.equals(1, b)
        end)

        it("on_state_change returns unsubscribe function", function()
            local unit = make_unit()
            local count = 0
            local unsub = unit:on_state_change(function() count = count + 1 end)
            unit:register_task(1, "build")
            assert.equals(1, count)

            unsub()
            unit:unregister_task(1)
            -- Should not fire after unsubscribe
            assert.equals(1, count)
        end)

        it("unsubscribed listeners are removed from list", function()
            local unit = make_unit()
            local initial_count = #unit._listeners
            local unsub = unit:on_state_change(function() end)
            assert.equals(initial_count + 1, #unit._listeners)
            unsub()
            assert.equals(initial_count, #unit._listeners)
        end)
    end)



    describe("shared state across profiles", function()
        it("same unit visible from two profiles", function()
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local u1 = core:ensure_config_unit(project, h.get_or_create_config(project, "debug"), nil)
            local u2 = core:ensure_config_unit(project, h.get_or_create_config(project, "debug"), nil)

            u1:register_task(1, "configure")
            assert.equals("configuring", u2:state())
            assert.is_true(u2:is_running())
        end)
    end)

    describe("cache resolution", function()
        it("resolves cached data from cache entry", function()
            local core = h.make_mock_core({
                cache = {
                    configurations = {
                        ["App/Debug"] = {
                            project_key = "App",
                            config_key = "Debug",
                            type = "cmake",
                            variant = "Debug",
                        },
                    },
                },
            })
            local unit = h.ensure_config_unit_by_id(core, "App/Debug", "App")
            assert.is_not_nil(unit._cached)
            assert.equals("Debug", unit._cached.variant)
        end)

        it("_cached is nil when no cache entry exists", function()
            local core = h.make_mock_core()
            -- Create a bare ConfigUnit without a cache entry to test nil case
            local unit = ConfigUnit.new(core, "App/Debug", "App")
            assert.is_nil(unit._cached)
        end)

        it("resolves tool domain object from cache entry", function()
            local core = h.make_mock_core({
                cache = {
                    configurations = {
                        ["App/cfg-1"] = {
                            project_key = "App",
                            config_key = "cfg-1",
                            type = "cmake",
                            variant = "Debug",
                            tool_key = "ninja-gcc",
                            tool_data = { id = "ninja-gcc" },
                        },
                    },
                },
            })
            local unit = h.ensure_config_unit_by_id(core, "App/cfg-1", "App")
            assert.is_not_nil(unit._cached)
            assert.equals("Debug", unit._cached.variant)
            assert.equals("ninja-gcc", unit._cached.tool_key)
        end)
    end)
end)
