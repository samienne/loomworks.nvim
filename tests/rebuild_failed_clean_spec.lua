--- Rebuild = clean, then build only if the clean succeeded.
---
--- Regression: the status page's unit rebuild action (`R` on a
--- configuration row) passed the build as ConfigUnit:clean's legacy
--- `on_done` callback, which fires on success AND failure — so a failed
--- clean still started the build. The profile-level rebuild chains the
--- clean Future and is covered here too.

local h = require("tests.helpers")
local Project = require("loomworks.project")

local function make_unit()
    -- Real Workspace:stop_tasks_then returns a Future; the shared mock's
    -- default is the old callback form.
    local core = h.make_mock_core({
        stop_tasks_then = function() return require("loomworks.future").resolved(true) end,
    })
    core._projects["App"] = Project.new(core, "App", {
        type = "cmake", path = "App", status = "unconfigured",
        configurations = {}, cached_configurations = {},
    })
    local project = core._projects["App"]
    local unit = core:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
    unit.state_value = "built"
    -- The real run-once mark clearer that ConfigUnit:clean calls.
    unit._workspace._deleting_mark_clearer = require("loomworks.workspace").Workspace._deleting_mark_clearer
    return unit
end

--- Make the unit's clean fail for a real reason: the tool/configuration
--- compatibility gate rejects run_configuration_clean (spec §3).
local function make_clean_fail(unit)
    unit._workspace._active_profile = {
        projects = function()
            return { { _config_unit = unit,
                _tool_compat_error = "ABI is arm64-v8a but profile tool is armeabi-v7a" } }
        end,
    }
end

describe("rebuild after a failed clean", function()
    local overseer_mod = require("loomworks.overseer")
    local actions = require("loomworks.ui.actions")
    local wv = require("loomworks.workspace_view")
    local loomworks = require("loomworks")

    local saved, notified

    before_each(function()
        saved = {
            run_action = overseer_mod.run_configuration_action,
            confirm = actions._show_confirmation,
            collect = wv.collect_clean_items_for_unit,
            context = wv.compute_clean_confirmation_context,
            get_ws = loomworks.get_workspace,
            notify = vim.notify,
        }
        notified = {}
        vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
        actions._show_confirmation = function(_, on_confirm) on_confirm() end
        wv.collect_clean_items_for_unit = function() return {} end
        wv.compute_clean_confirmation_context = function() return { lines = {} } end
        loomworks.get_workspace = function() return nil end
    end)

    after_each(function()
        overseer_mod.run_configuration_action = saved.run_action
        actions._show_confirmation = saved.confirm
        wv.collect_clean_items_for_unit = saved.collect
        wv.compute_clean_confirmation_context = saved.context
        loomworks.get_workspace = saved.get_ws
        vim.notify = saved.notify
    end)

    it("unit rebuild does not start the build when the clean fails", function()
        local unit = make_unit()
        make_clean_fail(unit)

        local build_calls = 0
        overseer_mod.run_configuration_action = function()
            build_calls = build_calls + 1
            return require("loomworks.future").resolved(true)
        end

        actions.rebuild_configuration(unit)()
        vim.wait(200, function() return false end)

        assert.equals(0, build_calls, "build must not run after a failed clean")
        local reported = false
        for _, n in ipairs(notified) do
            if n.level == vim.log.levels.ERROR and tostring(n.msg):find("[Rr]ebuild") then
                reported = true
            end
        end
        assert.is_true(reported, "the rebuild failure is reported")
    end)

    it("unit rebuild builds after a successful clean", function()
        local unit = make_unit()
        local orig_clean = overseer_mod.run_configuration_clean
        overseer_mod.run_configuration_clean = function()
            return require("loomworks.future").resolved(true)
        end

        local build_calls = 0
        overseer_mod.run_configuration_action = function(u, action)
            assert.equals(unit, u)
            assert.equals("build", action)
            build_calls = build_calls + 1
            return require("loomworks.future").resolved(true)
        end

        actions.rebuild_configuration(unit)()
        vim.wait(200, function() return build_calls > 0 end)
        overseer_mod.run_configuration_clean = orig_clean

        assert.equals(1, build_calls)
    end)

    it("Profile:rebuild does not build when the clean fails", function()
        local Profile = require("loomworks.profile").Profile
        local future_mod = require("loomworks.future")
        local built = false
        local fake = {
            clean = function() return future_mod.rejected("clean failed") end,
            build = function() built = true; return future_mod.resolved(true) end,
        }
        local rejected = false
        Profile.rebuild(fake):catch(function() rejected = true end)
        vim.wait(200, function() return rejected end)

        assert.is_false(built)
        assert.is_true(rejected)
    end)
end)
