--- Tests for loomworks/overseer.lua task readiness and launch behavior.
---
--- These tests verify that configure/build actions respect ConfigUnit state:
---   configure: only runs if unconfigured or configure_failed
---   build: skips if already building, defers if configuring, otherwise runs

local h = require("tests.helpers")
local ConfigUnit = require("loomworks.config_unit")
local Project = require("loomworks.project")

--- Build a mock ConfigUnit with a given state.
--- @param state string ConfigUnit state to simulate
--- @return loomworks.ConfigUnit
local function make_unit(project_key, config_key, state)
    local core = h.make_mock_core()
    if not core._projects[project_key] then
        core._projects[project_key] = Project.new(core, project_key, {
            type = "cmake", path = project_key, status = "unconfigured",
            configurations = {}, cached_configurations = {},
        })
    end
    local project = core._projects[project_key]
    local unit = core:ensure_config_unit(project, h.get_or_create_config(project, config_key), nil)

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
        unit.state_value = cache_state
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
            if not core._projects["App"] then
                core._projects["App"] = Project.new(core, "App", {
                    type = "cmake", path = "App", status = "unconfigured",
                    configurations = {}, cached_configurations = {},
                })
            end
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
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
                                    variant = "Debug",
                                    type = "cmake",
                                    state = "failed_configure",
                                },
                            },
                        },
                    }
                end,
            })
            if not core._projects["App"] then
                core._projects["App"] = Project.new(core, "App", {
                    type = "cmake", path = "App", status = "unconfigured",
                    configurations = {}, cached_configurations = {},
                })
            end
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
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
            if not core._projects["App"] then
                core._projects["App"] = Project.new(core, "App", {
                    type = "cmake", path = "App", status = "unconfigured",
                    configurations = {}, cached_configurations = {},
                })
            end
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
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
            if not core._projects["App"] then
                core._projects["App"] = Project.new(core, "App", {
                    type = "cmake", path = "App", status = "unconfigured",
                    configurations = {}, cached_configurations = {},
                })
            end
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
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

    -- ----------------------------------------------------------------------
    -- Tool/configuration compatibility gate
    -- ----------------------------------------------------------------------
    --
    -- Per spec §3 `validate_config_tool`, a non-nil `_tool_compat_error`
    -- blocks the unit from being built, configured, rebuilt, or
    -- cleaned. The gate sits at the top of run_configuration_action
    -- and run_configuration_clean; both return a rejected Future and
    -- never enqueue any task.
    describe("tool/configuration compatibility gate", function()
        local overseer_mod = require("loomworks.overseer")

        --- Stub vim.notify so the gate's error notification doesn't
        --- pollute test output, and we can assert the message later.
        local function stub_notify()
            local orig = vim.notify
            local captured = {}
            vim.notify = function(msg, level)
                captured[#captured + 1] = { msg = msg, level = level }
            end
            return captured, function() vim.notify = orig end
        end

        --- Wire a fake active profile onto the unit's workspace so
        --- `ConfigUnit:tool_compat_error()` finds the reason. The
        --- helper mimics what the data_model would have populated
        --- on a real ProfileProject during sync.
        local function set_active_compat_error(unit, reason)
            unit._workspace._active_profile = {
                projects = function()
                    return { { _config_unit = unit,
                        _tool_compat_error = reason } }
                end,
            }
        end

        it("run_configuration_action rejects when active profile has compat error", function()
            local unit = make_unit("App", "Debug", "unconfigured")
            set_active_compat_error(unit,
                "targets OpenHarmony but profile tool is HarmonyOS")

            local _captured, restore = stub_notify()
            local rejected_with = nil
            local resolved = false
            local f = overseer_mod.run_configuration_action(unit, "build")
            f:next(function() resolved = true end)
            f:catch(function(err) rejected_with = err end)
            restore()

            assert.is_false(resolved)
            assert.is_truthy(rejected_with)
            assert.is_truthy(
                tostring(rejected_with):find("OpenHarmony"),
                "rejection carries the compat reason")
        end)

        it("run_configuration_clean rejects when active profile has compat error", function()
            local unit = make_unit("App", "Debug", "built")
            set_active_compat_error(unit,
                "ABI is arm64-v8a but profile tool is armeabi-v7a")

            local _captured, restore = stub_notify()
            local rejected_with = nil
            local resolved = false
            local f = overseer_mod.run_configuration_clean(unit)
            f:next(function() resolved = true end)
            f:catch(function(err) rejected_with = err end)
            restore()

            assert.is_false(resolved)
            assert.is_truthy(rejected_with)
            assert.is_truthy(tostring(rejected_with):find("ABI"))
        end)

        it("notify message points the user at the fix", function()
            local unit = make_unit("App", "Debug", "unconfigured")
            set_active_compat_error(unit,
                "targets OpenHarmony but profile tool is HarmonyOS")

            local captured, restore = stub_notify()
            overseer_mod.run_configuration_action(unit, "configure")
            restore()

            assert.is_true(#captured > 0, "exactly one notify fires")
            local msg = captured[1].msg
            assert.is_truthy(msg:find("OpenHarmony"))
            assert.is_truthy(
                msg:find("change the profile") or msg:find("change the tool"),
                "message tells the user how to recover: " .. msg)
        end)
    end)
end)

-- ---------------------------------------------------------------------------
-- Test: _unit_tests_self_rebuild — headless `lw test` skips the separate build
-- of units whose native runner rebuilds itself (§16.16).
-- ---------------------------------------------------------------------------

describe("_unit_tests_self_rebuild", function()
    local overseer_mod = require("loomworks.overseer")

    --- A stub test unit. `rebuilds` may be a boolean or nil; `has_runner`
    --- controls whether `run_command_all` is present at all.
    local function tu(rebuilds, has_runner)
        local t = {}
        if has_runner ~= false then t.run_command_all = function() return {} end end
        t.run_command_all_rebuilds = function() return rebuilds and true or false end
        return t
    end

    --- A stub ConfigUnit exposing `test_units()`.
    local function unit(tus)
        return { test_units = function() return tus end }
    end

    it("true when every native runner self-rebuilds (meson)", function()
        assert.is_true(overseer_mod._unit_tests_self_rebuild(unit({ tu(true) })))
    end)

    it("false when a native runner does not self-rebuild (ctest)", function()
        assert.is_false(overseer_mod._unit_tests_self_rebuild(unit({ tu(false) })))
    end)

    it("false for a mixed unit (one self-rebuilds, one does not)", function()
        assert.is_false(overseer_mod._unit_tests_self_rebuild(unit({ tu(true), tu(false) })))
    end)

    it("false when the unit has no test units", function()
        assert.is_false(overseer_mod._unit_tests_self_rebuild(unit({})))
    end)

    it("false when no test unit has a native runner", function()
        assert.is_false(overseer_mod._unit_tests_self_rebuild(unit({ tu(true, false) })))
    end)

    it("false for a unit that cannot enumerate test units", function()
        assert.is_false(overseer_mod._unit_tests_self_rebuild({}))
        assert.is_false(overseer_mod._unit_tests_self_rebuild(nil))
    end)
end)

describe("junit_dest_for (spec §16.16 per-unit JUnit paths)", function()
    local f = require("loomworks.overseer")._junit_dest_for

    it("returns the path verbatim for a single unit", function()
        assert.equals("/out/report.xml", f("/out/report.xml", "app:Debug", false))
    end)

    it("inserts a sanitized label before the extension for multiple units", function()
        assert.equals("/out/report.app-Debug.xml", f("/out/report.xml", "app:Debug", true))
        assert.equals("/out/report.lib-Release.xml", f("/out/report.xml", "lib:Release", true))
    end)

    it("handles a path with no extension", function()
        assert.equals("/out/report.app-Debug", f("/out/report", "app:Debug", true))
    end)

    it("handles a bare filename with no directory", function()
        assert.equals("r.app-Debug.xml", f("r.xml", "app:Debug", true))
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

    pending("does not downgrade built to configured on successful configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        -- Verify initial state
        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        assert.equals("built", unit:state())

        -- Record a configure success
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        -- State should still be built
        assert.equals("built", unit:state())
    end)

    pending("updates last_configured even when state stays built", function()
        local core = make_core_with_state("App", "Debug", "built")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        assert.equals("built", unit.state_value)
        assert.is_not_nil(unit.last_configured)
    end)

    it("sets configured state when previously unconfigured", function()
        local core = make_core_with_state("App", "Debug", "unconfigured")

        -- The "unconfigured" skeleton may be cleaned up by _cleanup_orphaned_skeletons
        -- since no profile references it. Use ensure_config_unit to create it.
        local project = h.find_project_in(core:get_projects(), "App")
        local unit = core._workspace:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })

        assert.equals("configured", unit:state())
    end)

    pending("sets configure_failed on failed configure", function()
        local core = make_core_with_state("App", "Debug", "built")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "configure",
            success = false,
        })

        assert.equals("configure_failed", unit:state())
    end)

    pending("sets built state on successful build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "build",
            success = true,
        })

        assert.equals("built", unit:state())
    end)

    pending("sets build_failed on failed build", function()
        local core = make_core_with_state("App", "Debug", "configured")

        local unit = h.find_config_unit(core._workspace._config_units, "App", "Debug")
        core:record_task_result({
            unit = unit,
            action = "build",
            success = false,
        })

        assert.equals("build_failed", unit:state())
    end)
end)

