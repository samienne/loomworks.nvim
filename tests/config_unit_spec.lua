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
        it("stores id as build_dir key", function()
            local unit = make_unit()
            assert.equals("build/App/Debug", unit.id)
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
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
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
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
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
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
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
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
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
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
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

    describe("first-class fields", function()
        it("fields are nil when no data applied", function()
            local unit = ConfigUnit.new(nil, "build/App/Debug", "App")
            assert.is_nil(unit.state_value)
            assert.is_nil(unit.build_dir_value)
        end)

        it("fields populated from _apply", function()
            local unit = make_unit({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            build_dirs = {
                                ["build/App/Debug"] = {
                                    project_key = "App",
                                    type = "cmake",
                                    variant = "Debug",
                                    state = "built",
                                    build_dir = "/build/App/Debug",
                                },
                            },
                        },
                    }
                end,
            })
            assert.equals("built", unit.state_value)
            assert.equals("/build/App/Debug", unit.build_dir_value)
        end)
    end)

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



    describe("serialize", function()
        it("includes basic fields", function()
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            unit.state_value = "configured"
            unit.build_dir_value = "/build/Debug"
            local entry = unit:serialize()
            assert.equals("App", entry.project_key)
            assert.equals("cmake", entry.type)
            assert.equals("configured", entry.state)
            assert.equals("Debug", entry.config_key)
            assert.equals("Debug", entry.variant)
            assert.equals("/build/Debug", entry.build_dir)
        end)

        it("includes configuration snapshot when Configuration exists", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            -- Create a Configuration with rich data
            local cfg = Configuration.new(project, "Debug", {
                is_user = true,
                options = { ENABLE_TESTS = "ON" },
                inherits = "Base",
                variant = "Debug",
                generator = "Ninja",
                toolchain = "/path/to/toolchain.cmake",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            local entry = unit:serialize()
            assert.is_true(entry.is_user)
            assert.same({ ENABLE_TESTS = "ON" }, entry.options)
            assert.equals("Base", entry.inherits)
            assert.same({ variant = "Debug", generator = "Ninja", toolchain = "/path/to/toolchain.cmake" }, entry.module_config)
        end)

        it("omits snapshot fields when Configuration has no extra data", function()
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            local entry = unit:serialize()
            assert.is_nil(entry.is_user)
            assert.is_nil(entry.options)
            assert.is_nil(entry.inherits)
            assert.is_nil(entry.module_config)
        end)

        it("serializes multiple inherits as array", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug-asan", {
                inherits = { "Debug", "Sanitize" },
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            local entry = unit:serialize()
            assert.same({ "Debug", "Sanitize" }, entry.inherits)
        end)

        it("serializes single inherits as string", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug-asan", {
                inherits = "Debug",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            local entry = unit:serialize()
            assert.equals("Debug", entry.inherits)
        end)

        it("omits module_config when empty", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                is_user = true,
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            local entry = unit:serialize()
            assert.is_true(entry.is_user)
            assert.is_nil(entry.module_config)
        end)

        it("omits snapshot when Configuration is removed", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                is_user = true,
                variant = "Debug",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            cfg._removed = true
            local entry = unit:serialize()
            assert.is_nil(entry.is_user)
            assert.is_nil(entry.module_config)
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

    describe("is_stale", function()
        it("returns false when no cached snapshot exists", function()
            local unit = make_unit()
            assert.is_false(unit:is_stale())
        end)

        it("returns false when options match", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                options = { ENABLE_TESTS = "ON" },
                variant = "Debug",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            -- Simulate _apply with matching cached options
            unit._cached_options = { ENABLE_TESTS = "ON" }
            unit._cached_module_config = { variant = "Debug" }
            assert.is_false(unit:is_stale())
        end)

        it("returns true when options differ", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                options = { ENABLE_TESTS = "ON", NEW_FLAG = "YES" },
                variant = "Debug",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            -- Cached had different options
            unit._cached_options = { ENABLE_TESTS = "ON" }
            unit._cached_module_config = { variant = "Debug" }
            assert.is_true(unit:is_stale())
        end)

        it("returns true when module_config differs", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                variant = "Debug",
                generator = "Ninja",
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            -- Cached had a different generator
            unit._cached_options = nil
            unit._cached_module_config = { variant = "Debug", generator = "Unix Makefiles" }
            assert.is_true(unit:is_stale())
        end)

        it("returns false when configuration is removed", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", {
                options = { CHANGED = "YES" },
            })
            project._configurations[#project._configurations + 1] = cfg
            local unit = core:ensure_config_unit(project, cfg, nil)
            unit._cached_options = { OLD = "val" }
            cfg._removed = true
            assert.is_false(unit:is_stale())
        end)

        it("returns false when configuration is nil", function()
            local unit = make_unit()
            unit._configuration = nil
            unit._cached_options = { A = "1" }
            assert.is_false(unit:is_stale())
        end)

        it("cached options populated from _apply", function()
            local Configuration = require("loomworks.configuration")
            local core = h.make_mock_core()
            local project = ensure_project(core, "App")
            local cfg = Configuration.new(project, "Debug", { variant = "Debug" })
            project._configurations[#project._configurations + 1] = cfg

            local ConfigUnit = require("loomworks.config_unit")
            local unit = ConfigUnit.new(core, "build/App/Debug", "App")
            unit:_apply({
                cached = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    state = "configured",
                    options = { MY_OPT = "ON" },
                    module_config = { variant = "Debug", generator = "Ninja" },
                },
                project = project,
                configuration = cfg,
            })
            assert.same({ MY_OPT = "ON" }, unit._cached_options)
            assert.same({ variant = "Debug", generator = "Ninja" }, unit._cached_module_config)
        end)

        it("cached options cleared on nil _apply", function()
            local ConfigUnit = require("loomworks.config_unit")
            local unit = ConfigUnit.new(nil, "build/App/Debug", "App")
            unit._cached_options = { A = "1" }
            unit._cached_module_config = { variant = "Debug" }
            unit:_apply(nil)
            assert.is_nil(unit._cached_options)
            assert.is_nil(unit._cached_module_config)
        end)
    end)

    describe("cache resolution", function()
        it("resolves first-class fields from cache entry", function()
            local core = h.make_mock_core({
                cache = {
                    build_dirs = {
                        ["build/App/Debug"] = {
                            project_key = "App",
                            type = "cmake",
                            variant = "Debug",
                        },
                    },
                },
            })
            local unit = h.ensure_config_unit_by_id(core, "build/App/Debug", "App")
            assert.equals("Debug", unit._variant)
        end)

        it("first-class fields are nil when no cache entry exists", function()
            local core = h.make_mock_core()
            -- Create a bare ConfigUnit without a cache entry to test nil case
            local unit = ConfigUnit.new(core, "build/App/Debug", "App")
            assert.is_nil(unit._variant)
            assert.is_nil(unit._config_key)
        end)

        it("resolves tool domain object from cache entry", function()
            local core = h.make_mock_core({
                cache = {
                    build_dirs = {
                        ["build/App/Debug"] = {
                            project_key = "App",
                            type = "cmake",
                            variant = "Debug",
                            tool_key = "ninja-gcc",
                            tool_data = { id = "ninja-gcc" },
                        },
                    },
                },
            })
            local unit = h.ensure_config_unit_by_id(core, "build/App/Debug", "App")
            assert.equals("Debug", unit._variant)
            assert.equals("ninja-gcc", unit._tool_key)
        end)
    end)
end)
