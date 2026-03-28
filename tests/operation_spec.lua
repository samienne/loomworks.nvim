local h = require("tests.helpers")
local Operation = require("loomworks.operation")
local ProjectClass = require("loomworks.project")

describe("Operation", function()
    --- Helper: ensure a Project exists in the mock workspace registry.
    local function ensure_project(core, project_key)
        if not core._projects[project_key] then
            core._projects[project_key] = ProjectClass.new(core, project_key, {
                type = "cmake", path = project_key, status = "unconfigured",
                configurations = {}, cached_configurations = {},
            })
        end
        return core._projects[project_key]
    end

    local function make_operation(action, states, opts)
        opts = opts or {}
        local time = { value = opts.start_time or 0 }
        local core = h.make_mock_core({
            _deps = {
                clock = function() return time.value end,
                events = {
                    emit = function() end,
                    on = function() end,
                    off = function() end,
                },
            },
        })

        local Profile = require("loomworks.profile").Profile
        local profile = Profile.new(core, "debug", {
            configuration_set = "debug",
            mappings = { App = "Debug", Lib = "Debug" },
        })

        local units = {}
        local target_states = {}
        for _, s in ipairs(states) do
            local project = ensure_project(core, s.project)
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, s.config), nil)
            units[#units + 1] = unit
            target_states[unit] = s.target
        end

        local completed_op = nil
        local op = Operation.new(core, profile, action, units, target_states, function(o)
            completed_op = o
        end)

        return op, core, time, units, completed_op, function()
            return completed_op
        end
    end

    describe("creation", function()
        it("assigns unique IDs", function()
            local op1 = make_operation("build", {{ project = "A", config = "D", target = "built" }})
            local op2 = make_operation("build", {{ project = "B", config = "D", target = "built" }})
            assert.is_true(op1.id ~= op2.id)
        end)

        it("stores action and profile", function()
            local op = make_operation("configure", {{ project = "App", config = "Debug", target = "configured" }})
            assert.equals("configure", op.action)
            assert.equals("debug", op.profile.key)
        end)

        it("starts as not completed", function()
            local op, core = make_operation("build", {{ project = "App", config = "Debug", target = "built" }})
            local unit = h.find_config_unit_by_id(core._config_units, "App/Debug")
            unit:register_task(1, "build") -- keep it running
            -- Need to create a new op with the running unit
            local op2 = make_operation("build", {{ project = "App", config = "Debug", target = "built" }})
            -- Unit isn't running in op2's core, so it might complete immediately if state matches
            -- Since unit state is "unconfigured" and target is "built", it won't match → not completed
            assert.is_false(op2.completed)
        end)
    end)

    describe("completion via state changes", function()
        it("completes when unit reaches target state", function()
            local op, core, time, units, _, get_completed = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            local unit = units[1]

            assert.is_false(op.completed)

            -- Simulate: register a build task, then unregister (cache shows "built")
            unit:register_task(1, "build")
            assert.is_false(op.completed)

            -- Set cached state to "built" and unregister task
            unit.state_value = "built"
            time.value = 42
            unit:unregister_task(1)

            assert.is_true(op.completed)
            assert.is_true(op.success)
            assert.equals("built in 42s", op.message)
            assert.is_not_nil(get_completed())
        end)

        it("completes with failure when unit fails", function()
            local op, core, time, units = make_operation("configure", {
                { project = "App", config = "Debug", target = "configured" },
            })
            local unit = units[1]
            unit:register_task(1, "configure")

            unit.state_value = "failed_configure"
            time.value = 15
            unit:unregister_task(1)

            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.equals("configure failed in 15s", op.message)
        end)

        it("waits for all units before completing", function()
            local op, core, time, units = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
                { project = "Lib", config = "Debug", target = "built" },
            })
            local app_unit = units[1]
            local lib_unit = units[2]

            app_unit:register_task(1, "build")
            lib_unit:register_task(2, "build")

            -- App finishes
            app_unit.state_value = "built"
            app_unit:unregister_task(1)
            assert.is_false(op.completed)

            -- Lib finishes
            lib_unit.state_value = "built"
            time.value = 60
            lib_unit:unregister_task(2)
            assert.is_true(op.completed)
            assert.is_true(op.success)
        end)

        it("reports failure if any unit fails", function()
            local op, core, time, units = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
                { project = "Lib", config = "Debug", target = "built" },
            })
            local app_unit = units[1]
            local lib_unit = units[2]

            app_unit:register_task(1, "build")
            lib_unit:register_task(2, "build")

            -- App succeeds
            app_unit.state_value = "built"
            app_unit:unregister_task(1)

            -- Lib fails
            lib_unit.state_value = "failed_build"
            lib_unit:unregister_task(2)

            assert.is_true(op.completed)
            assert.is_false(op.success)
        end)

        it("does not complete immediately if units already in target state", function()
            local time = { value = 0 }
            local core = h.make_mock_core({
                _deps = {
                    clock = function() return time.value end,
                    events = { emit = function() end, on = function() end, off = function() end },
                },
            })

            local Profile = require("loomworks.profile").Profile
            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
            })

            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            -- Set unit to target state before creating operation
            unit.state_value = "built"
            local op = Operation.new(core, profile, "build", { unit }, { [unit] = "built" })

            -- Operations only complete on state transitions, not initial state
            assert.is_false(op.completed)
        end)
    end)

    describe("has_unit", function()
        it("returns true for tracked units", function()
            local op, core = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            local unit = h.find_config_unit_by_id(core._config_units, "App/Debug")
            assert.is_true(op:has_unit(unit))
        end)

        it("returns false for untracked units", function()
            local op, core = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            local lib = ensure_project(core, "Lib")
            local other = core:ensure_config_unit(lib, h.get_or_create_config(lib, "Release"), nil)
            assert.is_false(op:has_unit(other))
        end)
    end)

    describe("progress_counts", function()
        it("tracks done count", function()
            local op, core, _, units = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
                { project = "Lib", config = "Debug", target = "built" },
            })

            local done, total = op:progress_counts()
            assert.equals(0, done)
            assert.equals(2, total)

            -- Complete one unit
            units[1]:register_task(1, "build")
            units[1].state_value = "built"
            units[1]:unregister_task(1)

            done, total = op:progress_counts()
            assert.equals(1, done)
            assert.equals(2, total)
        end)
    end)

    describe("elapsed", function()
        it("returns elapsed time", function()
            local op, _, time = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            time.value = 30
            assert.equals(30, op:elapsed())
        end)
    end)

    describe("cancel", function()
        it("marks operation as completed and failed", function()
            local op = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            op:cancel()
            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.equals("cancelled", op.message)
        end)
    end)

    describe("duration formatting", function()
        it("formats seconds", function()
            local op, core, time, units = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            units[1]:register_task(1, "build")
            units[1].state_value = "built"
            time.value = 42
            units[1]:unregister_task(1)
            assert.equals("built in 42s", op.message)
        end)

        it("formats minutes", function()
            local op, core, time, units = make_operation("build", {
                { project = "App", config = "Debug", target = "built" },
            })
            units[1]:register_task(1, "build")
            units[1].state_value = "built"
            time.value = 150
            units[1]:unregister_task(1)
            assert.equals("built in 2m30s", op.message)
        end)
    end)

    describe("state hierarchy (configure target upgrade)", function()
        it("configure operation completes when unit reaches built", function()
            local op, core, time, units = make_operation("configure", {
                { project = "App", config = "Debug", target = "configured" },
            })
            units[1]:register_task(1, "configure")

            -- Configure completes, but immediately a build starts (deferred task)
            -- so the unit goes configuring → building (never visible as "configured")
            units[1].state_value = "built"
            time.value = 10
            units[1]:unregister_task(1)

            assert.is_true(op.completed)
            assert.is_true(op.success)
        end)

        it("configure operation completes when unit is building", function()
            local op, core, _, units = make_operation("configure", {
                { project = "App", config = "Debug", target = "configured" },
            })
            units[1]:register_task(1, "configure")

            -- Simulate: configure unregisters, but a deferred build immediately
            -- registers on the same unit during the listener notify loop.
            -- The Operation sees "building" rather than "configured".
            units[1]:unregister_task(1)
            -- State is "unconfigured" momentarily (no cache), but that's fine.
            -- Now simulate the deferred build starting:
            units[1]:register_task(2, "build")

            -- Operation should see "building" and treat it as "configured achieved"
            assert.is_true(op.completed)
            assert.is_true(op.success)
        end)

        it("build operation does NOT complete when unit is only configured", function()
            local time = { value = 0 }
            local core = h.make_mock_core({
                get_workspace = function()
                    return {
                        cache = {
                            configurations = {
                                ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", state = "configured" },
                            },
                        },
                    }
                end,
                _deps = {
                    clock = function() return time.value end,
                    events = { emit = function() end, on = function() end, off = function() end },
                },
            })

            local Profile = require("loomworks.profile").Profile
            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
            })

            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            local op = Operation.new(core, profile, "build", { unit }, { [unit] = "built" })

            -- "configured" does NOT satisfy "built" target
            assert.is_false(op.completed)
        end)

        it("shared unit: configure op completes when build op starts on same unit", function()
            -- Simulates the race: Profile A configures, Profile B builds same unit.
            -- When configure finishes, a deferred build fires first in the listener
            -- list and re-registers a build task before Operation A checks state.
            local time = { value = 0 }
            local core = h.make_mock_core({
                _deps = {
                    clock = function() return time.value end,
                    events = { emit = function() end, on = function() end, off = function() end },
                },
            })

            local Profile = require("loomworks.profile").Profile
            local profileA = Profile.new(core, "debug:tool-a", {
                configuration_set = "debug",
                mappings = { TS = "default" },
            })
            local profileB = Profile.new(core, "debug:tool-b", {
                configuration_set = "debug",
                mappings = { TS = "default" },
            })

            local ts_project = ensure_project(core, "TS")
            local unit = core:ensure_config_unit(ts_project, h.get_or_create_config(ts_project, "default"), nil)

            -- Profile A starts configure
            unit:register_task(1, "configure")
            local opA = Operation.new(core, profileA, "configure", { unit }, { [unit] = "configured" })
            assert.is_false(opA.completed)

            -- Profile B creates build operation (deferred — build task not started yet)
            local opB = Operation.new(core, profileB, "build", { unit }, { [unit] = "built" })
            assert.is_false(opB.completed)

            -- Register a deferred build listener BEFORE Operation A's listener
            -- (simulates the listener ordering in the real system)
            local deferred_fired = false
            unit:on_state_change(function(u)
                if deferred_fired then return end
                if u:state() == "configuring" then return end
                deferred_fired = true
                -- Deferred build starts immediately
                u:register_task(2, "build")
            end)

            -- Configure completes
            time.value = 5
            unit:unregister_task(1)

            -- The deferred listener fired and registered a build task.
            -- Operation A should still complete (building implies configured).
            assert.is_true(opA.completed, "Operation A should complete when unit starts building")
            assert.is_true(opA.success)

            -- Operation B should NOT be complete yet (building ≠ built)
            assert.is_false(opB.completed, "Operation B should wait for built")

            -- Build completes
            unit.state_value = "built"
            time.value = 15
            unit:unregister_task(2)

            assert.is_true(opB.completed, "Operation B should complete when built")
            assert.is_true(opB.success)
        end)
    end)

    describe("deletion mode", function()
        it("clean operation completes when deleting flag clears", function()
            local op, core, time, units = make_operation("clean", {
                { project = "App", config = "Debug", target = "unconfigured" },
            })
            local unit = units[1]

            -- Simulate deletion in progress
            unit:mark_deleting(true, "cleaning")
            assert.is_false(op.completed)

            -- Deletion finishes — flag clears, state falls to unconfigured
            time.value = 3
            unit:mark_deleting(false)

            assert.is_true(op.completed)
            assert.is_true(op.success)
            assert.equals("cleaned in 3s", op.message)
        end)

        it("clean operation reports failure when state is unknown after deletion", function()
            local op, core, time, units = make_operation("clean", {
                { project = "App", config = "Debug", target = "unconfigured" },
            })
            local unit = units[1]

            unit:mark_deleting(true, "cleaning")

            -- Deletion fails — cache set to unknown, flag clears
            unit.state_value = "unknown"
            time.value = 5
            unit:mark_deleting(false)

            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.equals("clean failed in 5s", op.message)
        end)

        it("delete operation completes with correct message", function()
            local op, _, time, units = make_operation("delete", {
                { project = "App", config = "Debug", target = "unconfigured" },
            })
            local unit = units[1]

            unit:mark_deleting(true, "deleting")
            time.value = 2
            unit:mark_deleting(false)

            assert.is_true(op.completed)
            assert.is_true(op.success)
            assert.equals("deleted in 2s", op.message)
        end)

        it("deletion operation stays pending while units are deleting", function()
            local op, _, _, units = make_operation("clean", {
                { project = "App", config = "Debug", target = "unconfigured" },
                { project = "Lib", config = "Debug", target = "unconfigured" },
            })

            units[1]:mark_deleting(true, "cleaning")
            units[2]:mark_deleting(true, "cleaning")
            assert.is_false(op.completed)

            -- Only one finishes
            units[1]:mark_deleting(false)
            assert.is_false(op.completed)

            -- Both done
            units[2]:mark_deleting(false)
            assert.is_true(op.completed)
        end)

        it("does not complete immediately — waits for deletion lifecycle", function()
            -- Deletion-mode Operations don't check initial state. They wait
            -- for mark_deleting(true) → mark_deleting(false) lifecycle.
            local op = make_operation("clean", {
                { project = "App", config = "Debug", target = "unconfigured" },
            })
            assert.is_false(op.completed)
        end)

        it("is_deletion returns true for clean/delete", function()
            local op_clean = make_operation("clean", {
                { project = "A", config = "D", target = "unconfigured" },
            })
            local op_delete = make_operation("delete", {
                { project = "B", config = "D", target = "unconfigured" },
            })
            local op_build = make_operation("build", {
                { project = "C", config = "D", target = "built" },
            })
            assert.is_true(op_clean:is_deletion())
            assert.is_true(op_delete:is_deletion())
            assert.is_false(op_build:is_deletion())
        end)
    end)

    describe("cancel calls completion callback", function()
        it("cancel triggers on_complete for registry cleanup", function()
            local time = { value = 0 }
            local core = h.make_mock_core({
                _deps = {
                    clock = function() return time.value end,
                    events = { emit = function() end, on = function() end, off = function() end },
                },
            })

            local Profile = require("loomworks.profile").Profile
            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
            })

            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            unit:register_task(1, "build")

            local callback_called = false
            local op = Operation.new(core, profile, "build", { unit }, { [unit] = "built" }, function()
                callback_called = true
            end)

            op:cancel()
            assert.is_true(callback_called)
        end)
    end)

    describe("optional profile", function()
        it("works without a profile", function()
            local time = { value = 0 }
            local core = h.make_mock_core({
                _deps = {
                    clock = function() return time.value end,
                    events = { emit = function() end, on = function() end, off = function() end },
                },
            })

            local project = ensure_project(core, "App")
            local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
            unit:mark_deleting(true, "cleaning")

            local op = Operation.new(core, nil, "clean", { unit }, { [unit] = "unconfigured" })
            assert.is_nil(op.profile)
            assert.is_false(op.completed)

            time.value = 1
            unit:mark_deleting(false)
            assert.is_true(op.completed)
            assert.equals("cleaned in 1s", op.message)
        end)
    end)
end)
