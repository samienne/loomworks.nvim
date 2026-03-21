local h = require("tests.helpers")
local ConfigUnit = require("loomworks.config_unit")

describe("ConfigUnit", function()
    local function make_unit(core_overrides)
        local core = h.make_mock_core(core_overrides)
        local unit = core:get_config_unit("App", "Debug")
        return unit, core
    end

    describe("identity", function()
        it("stores project_key and config_key", function()
            local unit = make_unit()
            assert.equals("App", unit.project_key)
            assert.equals("Debug", unit.config_key)
        end)

    end)

    describe("registry", function()
        it("returns same instance for same key pair", function()
            local core = h.make_mock_core()
            local u1 = core:get_config_unit("App", "Debug")
            local u2 = core:get_config_unit("App", "Debug")
            assert.equals(u1, u2)
            assert.is_true(rawequal(u1, u2))
        end)

        it("returns different instances for different keys", function()
            local core = h.make_mock_core()
            local u1 = core:get_config_unit("App", "Debug")
            local u2 = core:get_config_unit("App", "Release")
            local u3 = core:get_config_unit("Lib", "Debug")
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
            local unit = ws:get_config_unit("App", "Debug")

            unit:register_task(1, "build")
            time = 105
            assert.equals(5, unit:elapsed())
        end)
    end)

    describe("cached_state", function()
        it("returns nil when no workspace", function()
            local unit = make_unit()
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
            local u1 = core:get_config_unit("App", "debug")
            local u2 = core:get_config_unit("App", "debug")

            u1:register_task(1, "configure")
            assert.equals("configuring", u2:state())
            assert.is_true(u2:is_running())
        end)
    end)

    describe("variant resolution", function()
        it("resolves variant from ProfileProject when no cache entry exists", function()
            local core = h.make_mock_core()
            -- Simulate a ProfileProject with a tool-qualified config_key
            core._profile_projects["pp1"] = {
                project_key = "App",
                config_key = "Debug:ninja-gcc",
                variant = "Debug",
                _profile = { tool = { key = "ninja-gcc", data = { id = "ninja-gcc" } } },
            }
            local unit = core:get_config_unit("App", "Debug:ninja-gcc")
            assert.equals("Debug", unit.variant)
        end)

        it("uses config_key as variant for non-keyed modules (no tool)", function()
            local core = h.make_mock_core()
            local unit = core:get_config_unit("App", "development")
            assert.equals("development", unit.variant)
        end)

        it("uses config_key as variant when no keyed tools detected", function()
            local core = h.make_mock_core()
            -- No tools detected, no cache, no PP → safe to use config_key
            local unit = core:get_config_unit("App", "development")
            assert.equals("development", unit.variant)
        end)

        it("leaves variant nil when keyed tools are detected for project type", function()
            local core = h.make_mock_core()
            -- Project has type "cmake", and keyed tools are detected
            core._projects["App"] = { type = "cmake" }
            core._tools_by_type = {
                cmake = { { tool_key = "ninja-gcc", tool_data = {} } },
            }
            local unit = core:get_config_unit("App", "Debug:ninja-gcc")
            assert.is_nil(unit.variant)
        end)

        it("resolves variant from cache when no ProfileProject", function()
            local core = h.make_mock_core({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
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
                    }
                end,
            })
            local unit = core:get_config_unit("App", "Debug")
            assert.equals("Debug", unit.variant)
        end)

        it("ProfileProject variant overrides stale cached variant", function()
            local core = h.make_mock_core({
                get_workspace = function()
                    return {
                        config = { projects = { App = { type = "cmake" } } },
                        cache = {
                            configurations = {
                                ["App/Debug:ninja-gcc"] = {
                                    project_key = "App",
                                    config_key = "Debug:ninja-gcc",
                                    type = "cmake",
                                    variant = "Debug:ninja-gcc",
                                    tool_key = "ninja-gcc",
                                },
                            },
                        },
                    }
                end,
            })
            core._profile_projects["pp1"] = {
                project_key = "App",
                config_key = "Debug:ninja-gcc",
                variant = "Debug",
                _profile = { tool = { key = "ninja-gcc", data = { id = "ninja-gcc" } } },
            }
            local unit = core:get_config_unit("App", "Debug:ninja-gcc")
            -- ProfileProject is authoritative, overrides the stale cached variant
            assert.equals("Debug", unit.variant)
        end)
    end)
end)
