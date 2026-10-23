--- The runtime "deleting"/"cleaning" mark a clean or deletion puts on its
--- config units must be cleared on EVERY exit path — success, failed task,
--- cancellation, refusal before start, and a throw — or the unit stays
--- "deleting" for the rest of the session (status row stuck on "cleaning",
--- data_model won't drop it, rename skips it, operations never finish).
---
--- Drives the real ConfigUnit:clean / Profile:clean / execute_deletion paths
--- on a real Core; only the overseer clean runner is replaced, with a Future
--- the test settles (that is the boundary where the clean task runs).

local h = require("tests.helpers")
local Core = require("loomworks.core")
local future_mod = require("loomworks.future")

local function make_core()
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { typescript = {} } },
            configuration_sets = { debug = { App = "dev" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = { debug = { configuration_set = "debug" } },
        }),
        ["loomworks.cache.json"] = h.make_cache_json({
            configurations = {
                ["App/dev"] = {
                    project_key = "App", config_key = "dev", variant = "dev",
                    type = "typescript", state = "built",
                },
            },
        }),
    }
    local deps = h.make_test_deps(files, { cache = { save = function() return true end } })
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    return core
end

local function the_unit(core)
    local profile = h.find_profile(core:get_profiles(), "debug")
    local pp = profile:projects()[1]
    return pp._config_unit, profile
end

describe("clean/deletion runtime mark", function()
    local overseer = require("loomworks.overseer")
    local orig_unit_clean, orig_profile_clean, orig_notify
    local pending -- { resolve, reject, future } for the stubbed runner

    before_each(function()
        orig_unit_clean = overseer.run_configuration_clean
        orig_profile_clean = overseer.run_profile_clean
        orig_notify = vim.notify
        vim.notify = function() end
        local function runner()
            local f = future_mod.create(function(resolve, reject)
                pending = { resolve = resolve, reject = reject }
            end)
            pending.future = f
            return f
        end
        overseer.run_configuration_clean = runner
        overseer.run_profile_clean = runner
    end)

    after_each(function()
        overseer.run_configuration_clean = orig_unit_clean
        overseer.run_profile_clean = orig_profile_clean
        vim.notify = orig_notify
        pending = nil
    end)

    describe("ConfigUnit:clean", function()
        it("clears the mark after a successful clean", function()
            local unit = the_unit(make_core())
            unit:clean()
            assert.equals("deleting", unit:state())
            pending.resolve(true)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark after a failed clean task", function()
            local unit = the_unit(make_core())
            local rejected = false
            unit:clean():catch(function() rejected = true end)
            assert.equals("deleting", unit:state())
            pending.reject("clean task failed")
            assert.is_true(rejected, "the failure still propagates")
            assert.is_false(unit:is_deleting())
            assert.are_not.equal("deleting", unit:state())
            assert.is_nil(unit:deleting_reason())
        end)

        it("clears the mark when the clean is cancelled", function()
            local unit = the_unit(make_core())
            local f = unit:clean()
            assert.is_true(unit:is_deleting())
            f:cancel()
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when the clean task is stopped", function()
            local unit = the_unit(make_core())
            unit:clean()
            pending.future:cancel()
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when the clean is refused before start (compat gate)", function()
            overseer.run_configuration_clean = orig_unit_clean
            local unit = the_unit(make_core())
            unit.tool_compat_error = function() return "ABI mismatch" end
            local rejected = false
            unit:clean():catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when the runner throws", function()
            overseer.run_configuration_clean = function() error("boom") end
            local unit = the_unit(make_core())
            local rejected = false
            unit:clean():catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)
    end)

    describe("Profile:clean", function()
        it("clears the mark after a failed clean task", function()
            local unit, profile = the_unit(make_core())
            local rejected = false
            profile:clean():catch(function() rejected = true end)
            assert.equals("deleting", unit:state())
            pending.reject("clean task failed")
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when the clean is cancelled", function()
            local unit, profile = the_unit(make_core())
            local f = profile:clean()
            assert.is_true(unit:is_deleting())
            f:cancel()
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when the clean is refused before start", function()
            overseer.run_profile_clean = function()
                return future_mod.rejected("overseer.nvim not found")
            end
            local unit, profile = the_unit(make_core())
            profile:clean():catch(function() end)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark after a successful clean", function()
            local unit, profile = the_unit(make_core())
            profile:clean()
            pending.resolve(true)
            assert.is_false(unit:is_deleting())
        end)
    end)

    describe("execute_deletion", function()
        it("clears the mark when the deletion throws before removing anything", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws._mark_cache_unknown = function() error("boom") end
            local rejected = false
            ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean" } } }):catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)

        it("clears the mark when stopping the running tasks fails", function()
            local core = make_core()
            local unit = the_unit(core)
            local ws = core._workspace
            ws.stop_tasks_then = function() return future_mod.rejected("stop failed") end
            local rejected = false
            ws:execute_deletion({ items = { { unit = unit, project_key = "App",
                config_key = "dev", disposition = "clean" } } }):catch(function() rejected = true end)
            assert.is_true(rejected)
            assert.is_false(unit:is_deleting())
        end)
    end)
end)
