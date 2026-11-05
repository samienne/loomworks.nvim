-- The editor observes the workspace daemon (spec §19.16, §19.19 step 4),
-- end to end with real processes (the lw of LOOMWORKS_LW,
-- tests/daemon_helpers.lua): the editor (this process: its Observer) connects
-- through a real
-- `--stdio` relay (loomworks.daemon.client.relay, step 5i PR G1), which
-- launches the shared daemon on load; a real `lw build` from a "terminal"
-- (another process) is routed to it, and the editor shows that build — the
-- remote task as display data and ids (it holds no model, step 6b-alpha) —
-- and follows the daemon's `model_change`. Then `lw daemon
-- stop`: the observer drops, follows through a no-launch relay and never
-- relaunches; a daemon the CLI starts later is observed again. The daemon
-- survives its relay and the editor (a real editor process quitting), holds
-- none of the relay's pipes, and no relay is left (`lw daemon list`). No
-- daemon process is left behind.

local observer = require("loomworks.daemon.observer")
local relay_client = require("loomworks.daemon.client.relay")
local events = require("loomworks")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- The relay seam with real relays: the host binary is the lw under test
--- (LOOMWORKS_LW).
--- Each relay's form goes to `t.forms`, the relay to `t.relays`.
local function real_relays(t)
    t.forms, t.relays = {}, {}
    return function(ro, cb)
        assert.same({ "lw" }, ro.argv)
        ro.argv = { H.lw_path() }
        t.forms[#t.forms + 1] = ro.form
        local r, err = relay_client.connect(ro, cb)
        if r then t.relays[#t.relays + 1] = r end
        return r, err
    end
end

--- `lw daemon list --json` entries of `root`'s daemon.
local function listed(root, env)
    local r = H.lw({ "daemon", "list", "--json" }, { env = env, cwd = root })
    assert.equals(0, r.code, r.stderr)
    local out = {}
    -- Compared in canonical form: the daemon lists its root resolved (long
    -- names on Windows), while a test root may be an 8.3 short path (a
    -- Windows runner's temp dir under RUNNER~1).
    local function canon(p) return vim.fs.normalize(uv.fs_realpath(p) or p):lower() end
    local want = canon(root)
    for _, d in ipairs(vim.json.decode(r.stdout).daemons) do
        if type(d.root) == "string" and canon(d.root) == want then out[#out + 1] = d end
    end
    return out
end

describe("the editor observes the workspace daemon (§19.16)", function()
    local root, env, obs, seen
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        -- The same data dir (machine key) as this process: the editor and the
        -- `lw` processes authenticate with the same K, as on one machine.
        env = H.env({ LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR, LOOMWORKS_RUNTIME = "daemon",
            LW_TEST_SLEEP = "1500" })
        seen = { started = 0, stopped = 0 }
        on("daemon_task_started", function(d) seen.started = seen.started + 1; seen.task = d.task end)
        on("daemon_task_stopped", function(d) seen.stopped = seen.stopped + 1; seen.last = d.task end)
    end)

    after_each(function()
        if obs then obs:stop() end
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        if H.daemon(root, env) then H.stop_daemon(root, env) end
        H.track_root(root, env)
        H.cleanup()
    end)

    it("connects through a relay that launches on load, shows a terminal `lw build`; a stop is not relaunched", function()
        local t = {}
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(t), keepalive_ms = 500 })
        assert.is_not_nil(obs)
        assert.same({ "ordinary" }, t.forms)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.truthy(obs:runtime_line():find("observing the workspace daemon", 1, true))
        -- Through the relay: `welcome.via`, and the daemon is not the relay.
        assert.equals("relay", obs.conn.welcome.via)
        local relay = obs.conn.relay
        assert.not_equals(relay.pid, obs.daemon.pid)
        -- `lw daemon list` shows the relay as a connection of its daemon.
        local l = listed(root, env)
        assert.equals(1, #l)
        assert.equals(obs.daemon.pid, l[1].pid)
        assert.equals(1, #l[1].relays)
        assert.equals(relay.pid, l[1].relays[1].pid)

        -- A build from a terminal, routed to the daemon (§19.15).
        local b = H.lw_start({ "build", "dev" }, { env = env, cwd = root })
        -- (The event, not a poll of the running tasks: a fast build can be
        -- over between two polls.)
        assert.is_true(vim.wait(60000, function() return seen.started == 1 end, 20), b.stderr())
        local task = seen.task
        assert.equals("dev", task.profile_name)
        -- Display data and ids only: resolved to no model (step 6b-alpha).
        assert.is_nil(task.profile)
        assert.equals("app", task.units[1].project)
        assert.is_nil(task.units[1].unit)

        assert.is_true(b.wait(120000))
        assert.equals(0, b.code, b.stderr())
        assert.truthy(b.stderr():find("building through the workspace daemon", 1, true), b.stderr())
        assert.is_true(vim.wait(30000, function() return seen.stopped == 1 end, 20))
        assert.equals(0, seen.last.exit_code)
        assert.equals(0, #require("loomworks").get_daemon_tasks())
        assert.truthy(seen.last:output():find("step build", 1, true))
        -- The daemon's committed change reached the editor (model_change).
        assert.is_true(obs.seq > 0)

        -- `lw daemon stop`: the observer drops, follows through one relay
        -- that never launches, and nothing is relaunched.
        local r = H.stop_daemon(root, env)
        assert.equals(0, r.code, r.stderr)
        assert.is_true(vim.wait(30000, function() return obs.state == "waiting" end, 20))
        assert.truthy(obs:runtime_line():find("disconnected", 1, true), obs:runtime_line())
        assert.truthy(obs:runtime_line():find("none is launched", 1, true), obs:runtime_line())
        vim.wait(3000)
        -- Followed through one no-launch relay — plus, on a loaded machine,
        -- its one answer relay when that relay met the stopping daemon not
        -- yet gone and no longer answering (status 10 / 11, §19.16 "Exit
        -- before `welcome`"). Never an ordinary (launching) one.
        local function followed()
            assert.equals("ordinary", t.forms[1])
            assert.is_true(#t.forms == 2 or #t.forms == 3, vim.inspect(t.forms))
            for i = 2, #t.forms do assert.equals("no-launch", t.forms[i], vim.inspect(t.forms)) end
        end
        followed()
        assert.is_nil(H.daemon(root, env))
        -- The first relay ended with its connection.
        assert.is_true(vim.wait(10000, function() return relay.code ~= nil end, 20))

        -- A daemon another client starts is observed again (through the
        -- waiting no-launch relay).
        r = H.lw({ "daemon", "restart" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        H.track_root(root)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        followed()
    end)

    -- The exit criterion of step 5g.3 (§19.9 "Busy", §19.16 "Interface
    -- client"): a CLI of another version meets the idle daemon the editor
    -- observes. The editor (an observer, subscribed) never makes it busy, so
    -- the CLI stops it and launches its own; the editor reconnects to the
    -- new daemon, re-subscribes and shows the CLI's build from it.
    -- TODO(step3) GAP: the daemon of "another release" was this checkout run
    -- with LW_TEST_IDENTITY, a seam a release lw never honours (lw's
    -- daemon/version.lua). Needs two real lw releases (or a CLI way to claim
    -- another version) to run against LOOMWORKS_LW again.
    pending("survives a CLI-driven restart of an idle daemon (step 5g.3)", function()
        local t = {}
        -- The daemon the editor's relay launches claims another release (the
        -- relay and the daemon it launches inherit the variable).
        vim.env.LW_TEST_IDENTITY = "0.0.1+test.old"
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(t), keepalive_ms = 500 })
        vim.env.LW_TEST_IDENTITY = nil
        assert.is_not_nil(obs)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.equals("interfaces", obs.mode)
        assert.equals("0.0.1+test.old", obs.daemon.lw_version)
        local old_pid = obs.daemon.pid

        -- `lw build` from a terminal: its version differs, the daemon is idle
        -- (only the editor observes it) -> stopped and replaced, then the
        -- build is routed to the new daemon. Its steps are held until the
        -- editor shows the task: the editor reconnects to the new daemon on
        -- its own schedule (through a no-launch relay), and a build over
        -- before that would never reach it (a loaded runner's race).
        local gate = root .. "/gate"
        local benv = vim.deepcopy(env)
        benv.vars.LW_TEST_GATE = gate
        local b = H.lw_start({ "build", "dev" }, { env = benv, cwd = root })
        assert.is_true(vim.wait(120000, function() return seen.started == 1 end, 20), b.stderr())
        local gf = assert(io.open(gate, "w")); gf:close()
        assert.is_true(b.wait(120000))
        assert.equals(0, b.code, b.stderr())
        assert.falsy(b.stderr():find("is busy", 1, true), b.stderr())
        assert.truthy(b.stderr():find("building through the workspace daemon", 1, true), b.stderr())
        assert.is_true(vim.wait(30000, function() return seen.stopped == 1 end, 20))
        assert.equals(0, seen.last.exit_code)
        -- The editor is connected to the new daemon, subscribed again; it
        -- never launched one itself.
        assert.equals("connected", obs.state)
        assert.equals("interfaces", obs.mode)
        assert.not_equals(old_pid, obs.daemon.pid)
        assert.not_equals("0.0.1+test.old", obs.daemon.lw_version)
        -- Followed through the no-launch relay of the drop — plus, on a
        -- loaded machine, its one answer relay when that relay met the
        -- replacement daemon not yet responding (status 10 / 11, §19.16
        -- "Exit before `welcome`"). Never an ordinary (launching) one.
        assert.equals("ordinary", t.forms[1])
        assert.is_true(#t.forms == 2 or #t.forms == 3, vim.inspect(t.forms))
        for i = 2, #t.forms do assert.equals("no-launch", t.forms[i], vim.inspect(t.forms)) end
        assert.equals(seen.task, seen.last)
    end)

    -- §19.16 "The relay process": the daemon never inherits the relay's
    -- pipes and outlives its relay; ending a relay (EOF, or a plain kill of
    -- its own pid — on Windows the daemon is the relay's child) never
    -- reaches the daemon; no relay is left behind.
    it("the daemon outlives its relay and holds none of its pipes; no relay is left", function()
        local t = {}
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(t), keepalive_ms = 500 })
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        local lk = H.track_root(root)
        local dpid = obs.daemon.pid
        local relay = obs.conn.relay
        -- Teardown: the relay is ended by EOF on its standard input — it
        -- exits 0 (not killed), and its standard output reaches EOF while
        -- the daemon it launched keeps running.
        obs:stop(); obs = nil
        assert.is_true(vim.wait(20000, function() return relay.code ~= nil and relay.eof end, 20))
        assert.equals(0, relay.code)
        assert.is_not_nil(H.daemon(root, env))
        assert.is_true(H.alive(dpid, lk.start_time))
        assert.same({}, listed(root, env)[1].relays)

        -- A relay ended by a plain kill of its own pid (the editor's
        -- backstop): the daemon lives on, and the editor follows it again
        -- through a no-launch relay.
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(t), keepalive_ms = 500 })
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        assert.equals(dpid, obs.daemon.pid)
        local r2 = obs.conn.relay
        assert.equals(0, uv.kill(r2.pid, "sigkill"))
        assert.is_true(vim.wait(20000, function() return r2.code ~= nil and r2.eof end, 20))
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" and obs.conn.relay ~= r2 end, 20),
            obs:runtime_line())
        assert.same({ "ordinary", "no-launch" }, t.forms)
        assert.equals(dpid, obs.daemon.pid)
        assert.is_true(H.alive(dpid, lk.start_time))
        obs:stop(); obs = nil
        assert.is_true(vim.wait(20000, function()
            for _, r in ipairs(t.relays) do if r.code == nil then return false end end
            return true
        end, 20))
        assert.same({}, listed(root, env)[1].relays)
    end)

    it("a real editor quitting leaves the daemon running and no relay", function()
        local dir = H.tmp()
        local script, out = dir .. "/editor.lua", dir .. "/editor.out"
        local f = assert(io.open(script, "w"))
        f:write([==[
local root, out = os.getenv("LW_TEST_EDITOR_ROOT"), os.getenv("LW_TEST_EDITOR_OUT")
local okr, err = pcall(function()
-- (A `daemon`-mode editor loads no model, step 6b-alpha: it attaches by root.)
local rc = require("loomworks.daemon.client.relay")
local relay
local obs = require("loomworks.daemon.observer").attach(root, {
    resolve = function() return "lw" end,
    relay = function(ro, cb)
        ro.argv = { os.getenv("LOOMWORKS_LW") }
        local r, e = rc.connect(ro, cb)
        relay = r
        return r, e
    end })
local ok = obs and vim.wait(60000, function() return obs.state == "connected" end, 20)
local o = io.open(out, "w")
o:write(string.format("%s %s %s\n", ok and "ok" or "fail", tostring(relay and relay.pid),
    tostring(obs and obs.daemon and obs.daemon.pid)))
o:write(obs and obs:runtime_line() or "no observer")
o:close()
end)
if not okr then
    local o = io.open(out, "w")
    o:write("error 0 0\n" .. tostring(err))
    o:close()
end
vim.cmd("qa!")
]==])
        f:close()
        local e = vim.deepcopy(env)
        e.vars.LW_TEST_EDITOR_ROOT = root
        e.vars.LW_TEST_EDITOR_OUT = out
        local code
        local h, pid = uv.spawn(vim.v.progpath, {
            args = { "--headless", "-u", "NONE", "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", H.REPO) .. ")",
                "-c", "luafile " .. script },
            cwd = root, env = H.env_list(e.vars), stdio = { nil, nil, nil },
        }, function(c) code = c end)
        assert.is_not_nil(h)
        local quit = vim.wait(120000, function() return code ~= nil end, 20)
        if not quit then pcall(uv.kill, pid, "sigkill") end
        pcall(function() h:close() end)
        local fo = io.open(out, "r")
        local text = fo and fo:read("*a") or "(no output)"
        if fo then fo:close() end
        assert.is_true(quit, "the editor did not quit: " .. text)
        local line = text:match("^[^\n]*")
        local ok, rpid, dpid = line:match("^(%S+) (%S+) (%S+)$")
        assert.equals("ok", ok, text)
        local lk = H.track_root(root)
        rpid, dpid = tonumber(rpid), tonumber(dpid)
        -- Its relay saw EOF when the editor went and exited; the daemon runs on.
        assert.is_true(vim.wait(20000, function()
            local okk, rr = pcall(uv.kill, rpid, 0)
            return not (okk and rr == 0)
        end, 50), "the relay is still running")
        assert.is_not_nil(H.daemon(root, env))
        assert.equals(dpid, lk.pid)
        assert.is_true(H.alive(dpid, lk.start_time))
        assert.same({}, listed(root, env)[1].relays)
    end)

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
