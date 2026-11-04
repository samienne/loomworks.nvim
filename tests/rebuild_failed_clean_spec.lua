--- Rebuild = clean, then build only if the clean succeeded.
---
--- Regression: the status page's unit rebuild action (`R` on a
--- configuration row) once passed the build as the clean's completion
--- callback, which fires on success AND failure — so a failed clean still
--- started the build. The profile row's rebuild chains the same way. Both
--- go to the workspace daemon (ui/model_calls.lua `Build/1.clean`, then
--- `Build/1.build`, each a task the editor owns; a fake observer here): the
--- build is sent only once the clean's task ended with exit 0.

describe("rebuild after a failed clean", function()
    local actions = require("loomworks.ui.actions")
    local observer = require("loomworks.daemon.observer")

    --- A fake observer carrying every method: records the owned calls, each
    --- running until the test ends it.
    local function fake_obs()
        local obs = { state = "connected", owned = {} }
        function obs:can_call() return true end
        function obs:refusal(method) return "the daemon does not carry " .. method end
        function obs:start_owned(method, args, h)
            self.owned[#self.owned + 1] = { method = method, args = args, h = h }
        end
        function obs:owned_calls() return {} end
        return obs
    end

    --- End the owned call `o`: accepted, then done with `exit_code`.
    local function finish(o, exit_code)
        o.h.on_reply({ outcome = "accepted", task_id = 7 })
        o.h.on_done({ exit_code = exit_code, error = exit_code ~= 0 and "clean failed" or nil })
    end

    local UNIT = { project = "App", configuration = "Debug", unit_id = "u:1", state = "built",
        build_dir = "/w/build/App/Debug" }
    local PROFILE = { id = "p:1", key = "dev", units = { UNIT } }

    local saved, notified, obs

    before_each(function()
        saved = { notify = vim.notify, confirm = actions._show_confirmation,
            current = observer._current, root = observer._attached_root }
        notified = {}
        vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
        actions._show_confirmation = function(_, on_confirm) on_confirm() end
        obs = fake_obs()
        observer._current, observer._attached_root = obs, "/w"
    end)

    after_each(function()
        vim.notify = saved.notify
        actions._show_confirmation = saved.confirm
        observer._current, observer._attached_root = saved.current, saved.root
    end)

    local function methods()
        local out = {}
        for _, o in ipairs(obs.owned) do out[#out + 1] = o.method end
        return out
    end

    it("unit rebuild does not start the build when the clean fails", function()
        actions.rebuild_configuration(UNIT, nil)()
        assert.same({ "clean" }, methods())
        finish(obs.owned[1], 2)

        assert.same({ "clean" }, methods(), "build must not run after a failed clean")
        local reported = false
        for _, n in ipairs(notified) do
            if n.level == vim.log.levels.ERROR and tostring(n.msg):find("[Rr]ebuild") then reported = true end
        end
        assert.is_true(reported, "the rebuild failure is reported")
    end)

    it("unit rebuild builds after a successful clean", function()
        actions.rebuild_configuration(UNIT, nil)()
        finish(obs.owned[1], 0)

        assert.same({ "clean", "build" }, methods())
        assert.same({ interactive = false, units = { { id = "u:1" } } }, obs.owned[2].args)
    end)

    it("the profile row's rebuild does not build when its clean fails", function()
        actions.rebuild(PROFILE, nil)()
        assert.same({ "clean" }, methods())
        finish(obs.owned[1], 1)

        assert.same({ "clean" }, methods(), "build must not run after a failed clean")
    end)

    it("the profile row's rebuild builds after a successful clean", function()
        actions.rebuild(PROFILE, nil)()
        finish(obs.owned[1], 0)

        assert.same({ "clean", "build" }, methods())
        assert.same({ interactive = false, profile = { id = "p:1" } }, obs.owned[2].args)
    end)
end)
