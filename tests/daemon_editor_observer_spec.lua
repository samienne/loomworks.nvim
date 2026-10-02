-- The editor observes the workspace daemon (spec §19.16, §19.19 step 4),
-- end to end with real processes: the editor (this process: the plugin's core
-- with the workspace loaded, plus its Observer) launches the daemon on load,
-- a real `lw build` from a "terminal" (another process) is routed to it, and
-- the editor shows that build — the remote task resolved to its own
-- ConfigUnit, the unit `building` — and reloads the daemon's committed cache
-- on `model_change`. Then `lw daemon stop`: the observer drops and never
-- relaunches. No daemon process is left behind.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local launch = require("loomworks.daemon.launch")
local inspect = require("loomworks.daemon.inspect")
local client = require("loomworks.daemon.client")
local events = require("loomworks.events")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000
observer.CONNECT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("the editor observes the workspace daemon (§19.16)", function()
    local root, env, core, obs, seen
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        -- The same data dir (machine key) as this process: the editor and the
        -- `lw` processes authenticate with the same K, as on one machine.
        env = H.env({ LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR, LOOMWORKS_RUNTIME = "daemon",
            LW_TEST_SLEEP = "1500" })
        seen = { started = 0, stopped = 0 }
        on("daemon_task_started", function() seen.started = seen.started + 1 end)
        on("daemon_task_stopped", function(d) seen.stopped = seen.stopped + 1; seen.last = d.task end)
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
    end)

    after_each(function()
        if obs then obs:stop() end
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        pcall(function() core:shutdown() end)
        if inspect.state(root).kind == "live" then H.stop_daemon(root, env) end
        H.track_root(root)
        H.cleanup()
    end)

    it("launches on load, shows a terminal `lw build` and reloads on model_change; never relaunches", function()
        local ws = core:get_workspace()
        local launched = 0
        obs = observer.attach(ws, {
            getenv = daemon_mode,
            -- The host binary here is this checkout run by nvim (as the specs'
            -- `lw`): launch it the way `lw` launches itself.
            resolve = function() return "lw" end,
            spawn = function(r, o)
                launched = launched + 1
                assert.same({ "lw" }, o.argv)
                return launch.spawn(r, { argv = { vim.v.progpath, "--headless", "-u", "NONE", "--cmd",
                    "lua vim.opt.rtp:prepend(" .. string.format("%q", H.REPO) .. ")", "-l", H.CLI } })
            end,
            watch_ms = 100, keepalive_ms = 500,
        })
        assert.is_not_nil(obs)
        assert.equals(1, launched)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.truthy(obs:runtime_line():find("observing the workspace daemon", 1, true))

        local unit = ws:get_profiles()[1]:projects()[1]._config_unit
        assert.is_not_nil(unit)

        -- A build from a terminal, routed to the daemon (§19.15).
        local b = H.lw_start({ "build", "dev" }, { env = env, cwd = root })
        assert.is_true(vim.wait(60000, function() return #ws:get_daemon_tasks() == 1 end, 20), b.stderr())
        local task = ws:get_daemon_tasks()[1]
        assert.equals("dev", task.profile_name)
        assert.equals(ws:get_profiles()[1], task.profile)
        -- Resolved to the editor's own ConfigUnit, by reference.
        assert.equals(unit, task.units[1].unit)
        assert.equals("building", unit:state())
        assert.equals(1, seen.started)

        assert.is_true(b.wait(120000))
        assert.equals(0, b.code, b.stderr())
        assert.truthy(b.stderr():find("building through the workspace daemon", 1, true), b.stderr())
        assert.is_true(vim.wait(30000, function() return seen.stopped == 1 end, 20))
        assert.equals(0, seen.last.exit_code)
        assert.equals(0, #ws:get_daemon_tasks())
        assert.truthy(seen.last:output():find("step build", 1, true))
        -- The daemon's committed cache reached the editor (model_change).
        assert.is_true(obs.seq > 0)
        assert.is_true(vim.wait(30000, function() return unit:state() == "built" end, 20), unit:state())

        -- `lw daemon stop`: the observer drops and never launches again.
        local r = H.stop_daemon(root, env)
        assert.equals(0, r.code, r.stderr)
        assert.is_true(vim.wait(30000, function() return obs.state == "waiting" end, 20))
        assert.truthy(obs:runtime_line():find("disconnected", 1, true))
        vim.wait(1000)
        assert.equals(1, launched)
        assert.equals("none", inspect.state(root).kind)

        -- A daemon another client starts is observed again.
        r = H.lw({ "daemon", "restart" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        H.track_root(root)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        assert.equals(1, launched)
    end)

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
