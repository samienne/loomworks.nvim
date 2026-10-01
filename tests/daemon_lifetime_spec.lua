-- The workspace daemon's lifetime in `runtime-mode daemon` (spec §19.1,
-- §19.10, §19.11, §19.19 step 2): runtime selection (`--no-daemon`,
-- LOOMWORKS_NO_DAEMON, CI), every workspace command keeping the daemon
-- running (launch or connect + ping; nothing routed), launch failure and hung
-- daemons reported in one line, the idle / keepalive / root-removed exits,
-- and the runtime log. Real processes are asserted by pid and start time;
-- none is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local runtime = require("loomworks.daemon.runtime")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local ensure = require("loomworks.daemon.ensure")
local handle = require("loomworks.daemon.handle")
local rlock = require("loomworks.daemon.rlock")
local rlog = require("loomworks.daemon.rlog")
local dpaths = require("loomworks.daemon.paths")
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local function env_of(t) return function(n) return t[n] end end

describe("runtime selection (§19.1)", function()
    local function sel(cfg, env, flag) return runtime.select(cfg, { getenv = env_of(env), flag = flag }) end
    it("uses the daemon only in daemon mode", function()
        assert.is_false(sel(nil, {}).daemon)
        assert.is_false(sel("in-process", {}).daemon)
        assert.is_true(sel("daemon", {}).daemon)
        assert.is_true(sel(nil, { LOOMWORKS_RUNTIME = "daemon" }).daemon)
    end)
    it("--no-daemon > LOOMWORKS_NO_DAEMON > CI select attached", function()
        assert.equals("--no-daemon", sel("daemon", { LOOMWORKS_NO_DAEMON = "0" }, true).reason)
        assert.equals("LOOMWORKS_NO_DAEMON=1", sel("daemon", { LOOMWORKS_NO_DAEMON = "1" }).reason)
        assert.equals("CI", sel("daemon", { CI = "true" }).reason)
        assert.is_true(sel("daemon", { CI = "true", LOOMWORKS_NO_DAEMON = "0" }).daemon)
        local s = sel("daemon", { LOOMWORKS_NO_DAEMON = "yes" })
        assert.is_true(s.daemon)
        assert.truthy(s.warning:find("LOOMWORKS_NO_DAEMON=yes", 1, true))
    end)
    it("parses the idle timeout", function()
        assert.equals(3600, runtime.idle_seconds({}))
        assert.equals(90, runtime.parse_duration("90s"))
        assert.equals(1800, runtime.parse_duration("30m"))
        assert.equals(7200, runtime.parse_duration("2h"))
        assert.equals(45, runtime.parse_duration("45"))
        assert.is_nil(runtime.parse_duration("0"))
        assert.is_nil(runtime.parse_duration("soon"))
        assert.equals(3600, runtime.idle_seconds({ ["daemon-idle-timeout"] = "nope" }))
    end)
end)

describe("lifetime rules (§19.11, in-process server)", function()
    local root, srv, exited
    local function start(opts)
        opts = opts or {}
        opts.exit = function(code) exited = code end
        opts.tick_ms = 100
        srv = server_mod.new(root, opts)
        assert(srv:start())
    end
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        exited = nil
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("exits after the idle timeout with no client", function()
        start({ idle_seconds = 1 })
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
        assert.equals(0, exited)
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
    end)

    it("a connected client keeps it alive past the idle timeout; the clock restarts after it leaves", function()
        start({ idle_seconds = 1 })
        local conn = assert(client.session(srv.address))
        vim.wait(2000, function() return exited ~= nil end, 20)
        assert.is_nil(exited)
        conn:close()
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
        assert.equals(0, exited)
    end)

    it("drops a connection silent for three keepalive intervals", function()
        start({ keepalive_ms = 100 })
        local conn = assert(client.session(srv.address))
        assert.equals(1, srv:client_count())
        assert.is_true(vim.wait(6000, function() return srv:client_count() == 0 end, 20))
        assert.is_true(vim.wait(1000, function() return conn.closed end, 20))
        assert.is_nil(exited)
    end)

    it("pings keep a connection alive", function()
        -- Dropped after 3 x 500 ms of silence; pinged every ~250 ms for 3 s.
        start({ keepalive_ms = 500 })
        local conn = assert(client.session(srv.address))
        for _ = 1, 12 do
            assert(client.request(conn, { kind = "ping" }))
            vim.wait(250, function() return false end, 10)
        end
        assert.equals(1, srv:client_count())
        conn:close()
    end)

    it("exits when the workspace root is removed", function()
        start()
        local addr = srv.address
        vim.fn.delete(root, "rf")
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
        assert.equals(0, exited)
        if not H.is_win then assert.is_nil(uv.fs_lstat(addr)) end
    end)

    it("writes its lifecycle to the runtime log", function()
        local d = H.tmp()
        local lines = {}
        start({ log = function(l) lines[#lines + 1] = l end, idle_seconds = 1 })
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
        local all = table.concat(lines, "\n")
        assert.truthy(all:find("serving", 1, true))
        assert.truthy(all:find("stopping: idle", 1, true))
        -- The file writer: one file per workspace, rotated past the cap.
        local saved = os.getenv("LOOMWORKS_DATA_DIR")
        vim.env.LOOMWORKS_DATA_DIR = d
        local saved_max = rlog.MAX_BYTES
        rlog.MAX_BYTES = 100
        for i = 1, 5 do rlog.write(root, "line " .. i .. string.rep("x", 40)) end
        local p = rlog.path(root)
        assert.truthy(p:find(d, 1, true) == 1)
        assert.truthy(p:find(dpaths.root_hash(root) .. ".log", 1, true))
        assert.truthy(uv.fs_stat(p .. ".1"))
        assert.truthy(uv.fs_stat(p).size <= 200)
        rlog.MAX_BYTES = saved_max
        vim.env.LOOMWORKS_DATA_DIR = saved
    end)
end)

describe("ensure (§19.9 through a workspace command)", function()
    local root, srv, exited
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        exited = nil
        srv = server_mod.new(root, { exit = function(code) exited = code end, tick_ms = 100 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)
    local function run(extra)
        local notes, logs = {}, {}
        local o = { config = { ["runtime-mode"] = "daemon" }, note = function(l) notes[#notes + 1] = l end,
            log = function(l) logs[#logs + 1] = l end, launch = function() error("must not launch") end }
        for k, v in pairs(extra or {}) do o[k] = v end
        return ensure.ensure(root, o), table.concat(notes, "\n"), table.concat(logs, "\n")
    end

    it("connects to a matching daemon and pings it (no output)", function()
        local before = srv.last_request
        vim.wait(1100, function() return false end, 50)
        local out, notes = run()
        assert.equals("used", out)
        assert.equals("", notes)
        assert.truthy(srv.last_request > before)
    end)
    it("does nothing in in-process mode or with --no-daemon", function()
        assert.equals("off", (run({ config = {} })))
        assert.equals("off", (run({ flag = true })))
    end)
    it("a busy daemon of another version: retire + the bypass line", function()
        srv.identity = "0.1.0"
        local other = assert(client.session(srv.address))
        local out, notes = run()
        assert.equals("bypass", out)
        assert.truthy(notes:find("runs lw v0.1.0 and is busy", 1, true))
        other:close()
        assert.is_true(vim.wait(2000, function() return exited ~= nil end, 10))
    end)
    it("an idle daemon of another version is replaced", function()
        srv.identity = "0.1.0"
        local launched = false
        local out = run({ launch = function() launched = true; return true, {} end })
        assert.equals("restarted", out)
        assert.is_true(launched)
        assert.equals(0, exited)
    end)
end)

describe("runtime-mode daemon with real processes", function()
    local root, env
    before_each(function()
        root = H.workspace()
        env = H.env({ LOOMWORKS_RUNTIME = "daemon", LW_TEST_HEARTBEAT_MS = "300", LW_TEST_DAEMON_TICK_MS = "300" })
    end)
    after_each(function()
        H.track_root(root)
        assert.equals(0, H.cleanup(), "a daemon process was left running")
    end)
    local function lw(args, e) return H.lw(args, { env = e or env, cwd = root }) end

    it("a workspace command starts the daemon and returns at once; the next one reuses it", function()
        local r = lw({ "profiles" })
        assert.equals(0, r.code, r.stderr)
        assert.equals("", r.stderr)
        local lk = H.track_root(root)
        assert.truthy(lk, "no daemon started")
        -- lw's pipes reached EOF although the daemon keeps running.
        assert.truthy(r.ms < 15000, r.ms)
        assert.is_true(H.alive(lk.pid, lk.start_time))
        r = lw({ "profiles" })
        assert.equals(0, r.code, r.stderr)
        assert.equals(lk.pid, rlock.read(root).pid)
        -- The runtime log names the launch.
        local log = assert(io.open(env.data .. "/daemon/logs/" .. dpaths.root_hash(root) .. ".log")):read("*a")
        assert.truthy(log:find("launched the workspace daemon (pid " .. lk.pid, 1, true), log)
        assert.truthy(log:find("serving", 1, true), log)
        assert.equals(0, lw({ "daemon", "stop" }).code)
        assert.is_true(vim.wait(5000, function() return not H.alive(lk.pid, lk.start_time) end, 50))
    end)

    it("--no-daemon, LOOMWORKS_NO_DAEMON=1 and CI never start one; LOOMWORKS_NO_DAEMON=0 overrides CI", function()
        assert.equals(0, lw({ "--no-daemon", "profiles" }).code)
        assert.is_nil(rlock.read(root))
        env.vars.LOOMWORKS_NO_DAEMON = "1"
        assert.equals(0, lw({ "profiles" }).code)
        assert.is_nil(rlock.read(root))
        env.vars.LOOMWORKS_NO_DAEMON = nil
        env.vars.CI = "true"
        assert.equals(0, lw({ "profiles" }).code)
        assert.is_nil(rlock.read(root))
        env.vars.LOOMWORKS_NO_DAEMON = "0"
        assert.equals(0, lw({ "profiles" }).code)
        assert.truthy(H.track_root(root))
        assert.equals(0, lw({ "daemon", "stop" }).code)
    end)

    it("a launch failure is one line and the command still runs", function()
        local bad = H.tmp() .. "/not-a-dir"
        local f = assert(io.open(bad, "w")); f:write("x"); f:close()
        env.vars.LOOMWORKS_DATA_DIR = bad
        local r = lw({ "profiles" })
        assert.equals(0, r.code)
        assert.truthy(r.stderr:find("could not start the workspace daemon (", 1, true), r.stderr)
        assert.truthy(r.stderr:find("); running without it", 1, true), r.stderr)
        assert.truthy(r.stdout:find("no profiles", 1, true))
        assert.is_nil(rlock.read(root))
    end)

    it("a hung daemon is reported in one line, never killed, and the command runs", function()
        assert.equals(0, lw({ "daemon", "restart" }).code)
        local lk = H.track_root(root)
        assert.is_true(proc._suspend(lk.pid))
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        local r = lw({ "profiles" })
        assert.equals(0, r.code)
        assert.truthy(r.stderr:find("is not responding — recover with: lw daemon stop --force", 1, true), r.stderr)
        assert.is_true(H.alive(lk.pid, lk.start_time))
        assert.equals(0, lw({ "daemon", "kill" }).code)
        local log = assert(io.open(env.data .. "/daemon/logs/" .. dpaths.root_hash(root) .. ".log")):read("*a")
        assert.truthy(log:find("killed", 1, true), log)
    end)

    it("--break-locks recovers a hung daemon (§19.5) and a fresh one starts", function()
        assert.equals(0, lw({ "daemon", "restart" }).code)
        local lk = H.track_root(root)
        assert.is_true(proc._suspend(lk.pid))
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        local r = lw({ "publish", "--break-locks=now" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find("killing the workspace daemon (pid " .. lk.pid, 1, true), r.stderr)
        assert.is_false(H.alive(lk.pid, lk.start_time))
        local now = H.track_root(root)
        assert.truthy(now, "no fresh daemon")
        assert.are_not.equal(lk.pid, now.pid)
        assert.is_true(H.alive(now.pid, now.start_time))
        assert.equals(0, lw({ "daemon", "stop" }).code)
    end)

    it("the daemon exits by itself after the idle timeout", function()
        H.settings(env, { ["daemon-idle-timeout"] = "2s" })
        assert.equals(0, lw({ "profiles" }).code)
        local lk = H.track_root(root)
        assert.truthy(lk)
        assert.is_true(vim.wait(20000, function() return not H.alive(lk.pid, lk.start_time) end, 100),
            "the idle daemon kept running")
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
    end)

    it("the daemon exits when the workspace directory is removed", function()
        assert.equals(0, lw({ "profiles" }).code)
        local lk = H.track_root(root)
        vim.fn.delete(root, "rf")
        assert.is_true(vim.wait(20000, function() return not H.alive(lk.pid, lk.start_time) end, 100),
            "the daemon outlived its workspace")
        root = H.workspace() -- after_each needs a root
    end)

    it("lw unlock --force records the forced unlock in the runtime log", function()
        local rec = require("loomworks.lock_record").new("publish")
        rec.pid, rec.host = 4242, "OTHERHOST"
        local f = assert(io.open(root .. "/.nvim/loomworks.op.lock", "w")); f:write(vim.json.encode(rec)); f:close()
        local r = lw({ "--no-daemon", "unlock", "--workspace", "--force" })
        assert.equals(0, r.code, r.stderr)
        local log = assert(io.open(env.data .. "/daemon/logs/" .. dpaths.root_hash(root) .. ".log")):read("*a")
        assert.truthy(log:find("lw unlock --force: removed the workspace operation lock held by pid 4242", 1, true), log)
    end)
end)
