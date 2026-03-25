--- Tests for loomworks/overseer.lua task readiness and launch behavior.
---
--- These tests verify that configure/build actions respect ConfigUnit state:
---   configure: only runs if unconfigured or configure_failed
---   build: skips if already building, defers if configuring, otherwise runs

local h = require("tests.helpers")
local ConfigUnit = require("loomworks.config_unit")

--- Build a mock ConfigUnit with a given state.
--- @param state string ConfigUnit state to simulate
--- @return loomworks.ConfigUnit
local function make_unit(project_key, config_key, state)
    local core = h.make_mock_core()
    local unit = core:get_config_unit(project_key, config_key)

    -- Set up cached state or running state as needed
    if state == "configuring" then
        unit:register_task(100, "configure")
    elseif state == "building" then
        unit:register_task(100, "build")
    elseif state == "deleting" then
        unit:mark_deleting(true)
    elseif state ~= "unconfigured" then
        -- Cached states: configured, built, configure_failed, build_failed
        local cache_state = state
        if state == "configure_failed" then cache_state = "failed_configure" end
        if state == "build_failed" then cache_state = "failed_build" end
        local cache_key = project_key .. "/" .. config_key
        core.get_workspace = function()
            return {
                cache = {
                    configurations = {
                        [cache_key] = {
                            project_key = project_key,
                            config_key = config_key,
                            type = "cmake",
                            state = cache_state,
                        },
                    },
                },
            }
        end
    end

    return unit, core
end

--- Build a minimal task_def for testing.
--- @param action string "configure" or "build"
--- @param project_key? string
--- @param config_key? string
--- @return table task_def
local function make_task_def(action, project_key, config_key)
    project_key = project_key or "App"
    config_key = config_key or "Debug"
    return {
        name = project_key .. ": " .. action .. " " .. config_key,
        builder = function()
            return {
                cmd = { "echo", action },
                components = { "default" },
            }
        end,
        loomworks = {
            project_key = project_key,
            action = action,
            configuration_key = config_key,
        },
    }
end

--- Create a mock overseer module that tracks task creation and control.
--- @return table mock_overseer, table tracking { tasks, started, completed }
local function make_mock_overseer()
    local tracking = {
        tasks = {},      -- all created tasks
        started = {},    -- tasks that had :start() called
        completed = {},  -- { task_id, status } for tasks completed via callback
    }

    local next_id = 1

    local mock = {
        new_task = function(build_result)
            local task_id = next_id
            next_id = next_id + 1

            local subscribers = {}
            local task = {
                id = task_id,
                name = build_result.name,
                build_result = build_result,
                subscribe = function(_, event, fn)
                    subscribers[event] = subscribers[event] or {}
                    table.insert(subscribers[event], fn)
                end,
                start = function()
                    tracking.started[#tracking.started + 1] = task_id
                end,
                -- Test helper: simulate task completion
                _complete = function(_, status)
                    tracking.completed[#tracking.completed + 1] = { task_id = task_id, status = status }
                    for _, fn in ipairs(subscribers["on_complete"] or {}) do
                        fn(nil, status)
                    end
                end,
            }

            tracking.tasks[#tracking.tasks + 1] = task
            return task
        end,
    }

    return mock, tracking
end

-- ---------------------------------------------------------------------------
-- Test: launch_tasks integration via mock overseer
-- Task readiness rules (spec §5.1) are validated through ConfigUnit state
-- tests in config_unit_spec.lua. Here we test the integration behavior.
-- ---------------------------------------------------------------------------

describe("overseer launch_tasks", function()
    -- To test launch_tasks without exporting it, we expose it temporarily
    -- by testing through the full run_configuration_action path with mocked
    -- dependencies. However, that requires the full loomworks singleton.
    --
    -- Instead, we test the deferred listener behavior on ConfigUnit directly,
    -- which is the most important integration point.

    describe("deferred build waits for configure", function()
        it("fires build after configure completes successfully", function()
            local core = h.make_mock_core()
            local unit = core:get_config_unit("App", "Debug")
            unit:register_task(1, "configure") -- state = configuring

            local build_fired = false
            local fail_fired = false

            -- Simulate what launch_tasks does for a deferred task
            local fired = false
            unit:on_state_change(function(u)
                if fired then return end
                local new_state = u:state()
                if new_state == "configuring" then return end
                fired = true
                if new_state == "configure_failed" then
                    fail_fired = true
                    return
                end
                build_fired = true
            end)

            -- Configure still running — listener should not fire meaningfully
            assert.is_false(build_fired)
            assert.is_false(fail_fired)

            -- Configure completes (unregister clears running state)
            unit:unregister_task(1)

            -- Now listener should have fired and triggered build
            assert.is_true(build_fired)
            assert.is_false(fail_fired)
        end)

        it("reports failure when configure fails", function()
            local core = h.make_mock_core({
                get_workspace = function()
                    return {
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
            local unit = core:get_config_unit("App", "Debug")
            unit:register_task(1, "configure") -- state = configuring

            local build_fired = false
            local fail_fired = false

            local fired = false
            unit:on_state_change(function(u)
                if fired then return end
                local new_state = u:state()
                if new_state == "configuring" then return end
                fired = true
                if new_state == "configure_failed" then
                    fail_fired = true
                    return
                end
                build_fired = true
            end)

            -- Configure fails (unregister reveals the failed_configure cached state)
            unit:unregister_task(1)

            assert.is_false(build_fired)
            assert.is_true(fail_fired)
        end)

        it("listener is one-shot (does not fire again after initial trigger)", function()
            local core = h.make_mock_core()
            local unit = core:get_config_unit("App", "Debug")
            unit:register_task(1, "configure")

            local fire_count = 0

            local fired = false
            unit:on_state_change(function(u)
                if fired then return end
                local new_state = u:state()
                if new_state == "configuring" then return end
                fired = true
                fire_count = fire_count + 1
            end)

            -- Configure completes
            unit:unregister_task(1)
            assert.equals(1, fire_count)

            -- Subsequent state changes should not re-trigger
            unit:register_task(2, "build")
            unit:unregister_task(2)
            assert.equals(1, fire_count)
        end)

        it("ignores progress updates during configuring", function()
            local core = h.make_mock_core()
            local unit = core:get_config_unit("App", "Debug")
            unit:register_task(1, "configure")

            local build_fired = false

            local fired = false
            unit:on_state_change(function(u)
                if fired then return end
                local new_state = u:state()
                if new_state == "configuring" then return end
                fired = true
                build_fired = true
            end)

            -- Progress update while configuring — should be ignored
            unit:update_progress(1, { current = 5, total = 10 })
            assert.is_false(build_fired)

            -- Still configuring
            unit:update_progress(1, { current = 10, total = 10 })
            assert.is_false(build_fired)

            -- Now configure completes
            unit:unregister_task(1)
            assert.is_true(build_fired)
        end)
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: record_task_result does not downgrade built → configured
-- ---------------------------------------------------------------------------

describe("record_task_result state protection", function()
    local Core = require("loomworks.core")

    local function make_core_with_state(project_key, config_key, cached_state)
        local config_json = h.make_config_json({
            projects = { [project_key] = { cmake = {} } },
        })
        local cache_key = project_key .. "/" .. config_key
        local cache_json = h.make_cache_json({
            configurations = {
                [cache_key] = {
                    project_key = project_key,
                    config_key = config_key,
                    type = "cmake",
                    state = cached_state,
                    variant = config_key,
                },
            },
        })
        local deps = h.make_test_deps({
            ["loomworks.json"] = config_json,
            ["loomworks.cache.json"] = cache_json,
        }, {
            modules = {
                get = function(mod_type)
                    if mod_type ~= "cmake" then return nil end
                    return {
                        validate = function() return { valid = true, warnings = {} } end,
                        info = function() return { configurations = { [config_key] = {} } } end,
                    }
                end,
            },
        })
        local core = Core.new(deps)
        core:setup({ root = "/test" })
        return core
    end

    it("does not downgrade built to configured on successful configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        -- Verify initial state
        local unit = core._workspace:get_config_unit("App", "Debug")
        assert.equals("built", unit:state())

        -- Record a configure success
        core:record_task_result({
            project_key = "App",
            action = "configure",
            configuration_key = "Debug",
            success = true,
        })

        -- State should still be built
        assert.equals("built", unit:state())
    end)

    it("updates last_configured even when state stays built", function()
        local core = make_core_with_state("App", "Debug", "built")

        core:record_task_result({
            project_key = "App",
            action = "configure",
            configuration_key = "Debug",
            success = true,
        })

        local cached = core._workspace:get_config_unit("App", "Debug"):cached_state()
        assert.equals("built", cached.state)
        assert.is_not_nil(cached.last_configured)
    end)

    it("sets configured state when previously unconfigured", function()
        local core = make_core_with_state("App", "Debug", "unconfigured")

        core:record_task_result({
            project_key = "App",
            action = "configure",
            configuration_key = "Debug",
            success = true,
        })

        local unit = core._workspace:get_config_unit("App", "Debug")
        assert.equals("configured", unit:state())
    end)

    it("sets configure_failed on failed configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        core:record_task_result({
            project_key = "App",
            action = "configure",
            configuration_key = "Debug",
            success = false,
        })

        local unit = core._workspace:get_config_unit("App", "Debug")
        assert.equals("configure_failed", unit:state())
    end)

    it("sets built state on successful build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        core:record_task_result({
            project_key = "App",
            action = "build",
            configuration_key = "Debug",
            success = true,
        })

        local unit = core._workspace:get_config_unit("App", "Debug")
        assert.equals("built", unit:state())
    end)

    it("sets build_failed on failed build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        core:record_task_result({
            project_key = "App",
            action = "build",
            configuration_key = "Debug",
            success = false,
        })

        local unit = core._workspace:get_config_unit("App", "Debug")
        assert.equals("build_failed", unit:state())
    end)
end)

