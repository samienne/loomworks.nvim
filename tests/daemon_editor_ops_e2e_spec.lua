-- The editor's operations as daemon calls, end to end (spec §19.16 "Editor
-- operations", §19.15 "The editor as owner"; step 5k part C1, the plan's
-- real-daemon check): the editor (this process: the plugin's core with the
-- shell workspace loaded, plus its Observer connected through a real
-- `--stdio` relay to a real shared daemon) builds its profile. The build is
-- a `Build/1.build` call: nothing runs in-process, the daemon's task is the
-- editor's own (no origin marker), the operation's Future resolves on the
-- task's `done`, and the unit is `built` from the daemon's committed cache.
-- A unit build is a `units` call the same way. Then the editor is unloaded
-- in the middle of a slow build: closing its connection cancels the task it
-- owns. No daemon process is left behind.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local inspect = require("loomworks.daemon.inspect")
local client = require("loomworks.daemon.client")
local relay_client = require("loomworks.daemon.client").relay
local events = require("loomworks.events")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- Real relays from this checkout run by nvim (as the specs' `lw`).
local function real_relays()
    return function(ro, cb)
        ro.argv = { vim.v.progpath, "--headless", "-u", "NONE", "--cmd",
            "lua vim.opt.rtp:prepend(" .. string.format("%q", H.REPO) .. ")", "-l", H.CLI }
        return relay_client.connect(ro, cb)
    end
end

-- TODO(A1b): the daemon-mode cases below drive the routing from model
-- objects (Profile, ConfigUnit, LaunchTarget), which the `daemon`-mode editor
-- no longer holds (step 6b-alpha A1a: it loads no workspace). They are
-- pending until the facade acts by calls and view-row ids (A1b), which
-- restores them on that path.
describe("editor operations through a real daemon (§19.16, step 5k C1)", function()
    local root, env, core, obs, seen
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        env = H.env({ LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR, LOOMWORKS_RUNTIME = "daemon" })
        seen = { started = {}, stopped = {} }
        on("daemon_task_started", function(d) seen.started[#seen.started + 1] = d.task end)
        on("daemon_task_stopped", function(d) seen.stopped[#seen.stopped + 1] = d.task end)
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
    end)

    after_each(function()
        vim.env.LW_TEST_SLEEP = nil
        if obs then obs:stop() end
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        pcall(function() core:shutdown() end)
        if inspect.state(root).kind == "live" then H.stop_daemon(root, env) end
        H.track_root(root)
        H.cleanup()
    end)

    pending("builds the profile and a unit as calls the editor owns; unloading cancels its running task", function()
        local ws = core:get_workspace()
        obs = observer.attach(ws.root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_not_nil(obs)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.is_true(vim.wait(10000, function() return obs:can_call("build") end, 20), obs:runtime_line())
        local profile = ws:get_profiles()[1]
        local unit = profile:projects()[1]._config_unit

        local f = require("loomworks.overseer").run_profile_action(profile, "build")
        assert.is_true(f.routed)
        local st = {}
        f:next(function(v) st.ok = v end, function(e) st.err = e end)
        assert.is_true(vim.wait(120000, function() return st.ok ~= nil or st.err ~= nil end, 20), obs:runtime_line())
        assert.is_true(st.ok, tostring(st.err))
        local task = seen.started[1]
        assert.is_true(task.owned)
        assert.equals("editor", task.origin)
        assert.is_nil(task:origin_label())
        assert.equals(profile, task.profile)
        assert.equals(0, task.exit_code)
        assert.truthy(task:output():find("step build", 1, true), task:output())
        assert.is_true(vim.wait(30000, function() return unit:state() == "built" end, 20), unit:state())
        assert.is_false(obs:owns_tasks())

        -- A unit build: `units`, no profile.
        local f2 = require("loomworks.overseer").run_configuration_action(unit, "build")
        assert.is_true(f2.routed)
        local st2 = {}
        f2:next(function(v) st2.ok = v end, function(e) st2.err = e end)
        assert.is_true(vim.wait(120000, function() return st2.ok ~= nil or st2.err ~= nil end, 20))
        assert.is_true(st2.ok, tostring(st2.err))
        assert.is_nil(seen.started[2].profile_name)
        assert.equals(unit, seen.started[2]:config_units()[1])

        -- A slow build, then the editor unloads: its connection closes and
        -- the daemon cancels the task it owns (§19.15 "Task ownership").
        vim.env.LW_TEST_SLEEP = "20000"
        local f3 = require("loomworks.overseer").run_profile_action(profile, "build")
        local st3 = {}
        f3:next(function(v) st3.ok = v end, function(e) st3.err = e end)
        assert.is_true(vim.wait(60000, function() return obs:owns_tasks() and #seen.started >= 3 end, 20))
        local id = seen.started[3].id
        obs:stop()
        assert.is_true(vim.wait(5000, function() return st3.err ~= nil end, 20))
        -- Seen from another client: the task is gone well before its sleep ends.
        local cli = assert(client.session(inspect.state(root).handle.endpoint))
        assert.is_true(vim.wait(15000, function()
            local s = client.request(cli, { kind = "status" })
            for _, t in ipairs(s and s.tasks or {}) do
                if t.task_id == id then return false end
            end
            return s ~= nil
        end, 100))
        cli:close()
    end)

    -- Step 5k C2: a launch of a non-device target is prepared by the daemon
    -- (`Launch/1.prepare_run`, `build_scope = "target"`): its unit is built
    -- there, by a task the editor owns, and the returned launch is started
    -- here, in the editor's task runner.
    pending("prepares an editor launch in the daemon and starts its program here", function()
        core:shutdown()
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        local ws = core:get_workspace()
        obs = observer.attach(ws.root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.is_true(vim.wait(10000, function() return obs:can_call("prepare_run") end, 20), obs:runtime_line())
        local profile = ws:get_profiles()[1]
        local unit = profile:projects()[1]._config_unit
        local ov = require("loomworks.overseer")
        local orig = ov.launch_run_task
        local launched = {}
        ov.launch_run_task = function(spec) launched[#launched + 1] = spec; return nil end
        local target = require("loomworks.launch_target").new(ws, profile, { project = "app", launch = "run" })
        -- Refused while the daemon has not loaded the workspace (§19.16
        -- "Editor operations", step 5l): a read the editor carries loads it.
        local views = require("loomworks.views")
        if not (views.header() and views.header().state == "loaded") then
            assert.truthy(require("loomworks.session_tracker").launch_refusal(target))
            obs:request("adapters", {}, function() end)
        end
        assert.is_true(vim.wait(30000, function()
            local h = views.header()
            return h and h.state == "loaded"
        end, 20), obs:runtime_line())
        assert.is_nil(require("loomworks.session_tracker").launch_refusal(target))
        require("loomworks.session_tracker").start(target, "launch")
        local ok = vim.wait(120000, function() return #launched > 0 end, 20)
        ov.launch_run_task = orig
        assert.is_true(ok, obs:runtime_line())
        assert.equals("tool", launched[1].cmd)
        assert.same({ "-v" }, launched[1].args)
        local task = seen.started[1]
        assert.equals("run", task.kind)
        assert.is_true(task.owned)
        assert.equals(0, task.exit_code)
        assert.is_true(vim.wait(30000, function() return unit:state() == "built" end, 20), unit:state())
        assert.is_false(obs:owns_tasks())
    end)

    -- Step 5k C1b (§19.16 "Tasks in the task runner"), with the specs' fake
    -- overseer (tests/fake_overseer.lua): the editor's own build is one
    -- overseer task whose stop is `Tasks/1.cancel`; a CLI `lw build` is
    -- listed read-only as `[lw] …`, its stop refused.
    pending("lists daemon tasks in overseer: the editor's own stops by cancel, a CLI one is read-only", function()
        local saved = { package.loaded["overseer"], package.loaded["overseer.strategy"],
            package.loaded["overseer.util"] }
        local created = {}
        local ov, strat = require("tests.fake_overseer")(created)
        package.loaded["overseer"], package.loaded["overseer.strategy"] = ov, strat
        package.loaded["overseer.util"] = nil
        local ok, err = pcall(function()
            local ws = core:get_workspace()
            obs = observer.attach(ws.root, { getenv = daemon_mode, resolve = function() return "lw" end,
                relay = real_relays(), keepalive_ms = 500 })
            assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
            H.track_root(root)
            assert.is_true(vim.wait(10000, function() return obs:can_call("build") end, 20), obs:runtime_line())
            local profile = ws:get_profiles()[1]

            vim.env.LW_TEST_SLEEP = "20000"
            local f = require("loomworks.overseer").run_profile_action(profile, "build")
            local st = {}
            f:next(function(v) st.ok = v end, function(e) st.err = e end)
            assert.is_true(vim.wait(60000, function() return #created >= 1 end, 20))
            local t = created[1]
            assert.equals(seen.started[1].name, t.name)
            assert.equals("RUNNING", t.status)
            local id = seen.started[1].id
            t:stop()
            assert.equals("CANCELED", t.status)
            assert.is_true(vim.wait(15000, function() return st.err ~= nil end, 20))
            assert.equals("CANCELED", t.status)
            local cli = assert(client.session(inspect.state(root).handle.endpoint))
            assert.is_true(vim.wait(15000, function()
                local s = client.request(cli, { kind = "status" })
                for _, x in ipairs(s and s.tasks or {}) do
                    if x.task_id == id then return false end
                end
                return s ~= nil
            end, 100))
            cli:close()
            vim.env.LW_TEST_SLEEP = nil

            -- Another client's build: read-only, its origin marker in its name.
            local vars = vim.deepcopy(env.vars)
            vars.LW_TEST_SLEEP, vars.LW_TEST_SLEEP_STEP = "3000", "build"
            local p = H.lw_start({ "--no-input", "build", profile.key }, { env = { vars = vars }, cwd = root })
            H.track(p.pid, p.start)
            assert.is_true(vim.wait(60000, function() return #created >= 2 end, 20), p.stderr())
            local c = created[2]
            assert.equals("[lw] " .. seen.started[#seen.started].name, c.name)
            assert.is_false(c:stop())
            assert.equals("RUNNING", c.status)
            assert.is_true(vim.wait(60000, function() return c.status ~= "RUNNING" end, 20))
            assert.equals("SUCCESS", c.status)
            assert.is_true(vim.wait(60000, function() return p.code ~= nil end, 20))
            assert.equals(0, p.code, p.stderr())
        end)
        package.loaded["overseer"], package.loaded["overseer.strategy"], package.loaded["overseer.util"] =
            saved[1], saved[2], saved[3]
        assert(ok, err)
    end)
end)
