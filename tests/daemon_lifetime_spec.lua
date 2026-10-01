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

-- The suite runs every spec file at once: an in-process handshake can take
-- seconds on a loaded runner.
client.TIMEOUT_MS = 30000

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
        opts.auth_timeout_ms = 30000 -- a real handshake on a loaded runner
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
        -- A connection still authenticating already counts (it is not idle).
        local conn = assert(client.session(srv.address))
        vim.wait(2000, function() return exited ~= nil end, 20)
        assert.is_nil(exited)
        conn:close()
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
        assert.equals(0, exited)
    end)

    -- The keepalive rule is checked by calling the tick's `lifetime()` on a
    -- connection whose last traffic is set back in time (deterministic on a
    -- loaded runner); the timer drives the same function.
    local function age_conns(ms)
        for conn in pairs(srv.conns) do conn.last_seen = uv.now() - ms end
    end

    it("drops a connection silent for three keepalive intervals", function()
        start({ keepalive_ms = 1000 })
        local conn = assert(client.session(srv.address))
        assert.equals(1, srv:client_count())
        age_conns(2500)
        srv:lifetime()
        assert.equals(1, srv:client_count()) -- not yet three intervals
        age_conns(3500)
        srv:lifetime()
        assert.equals(0, srv:client_count())
        assert.is_true(vim.wait(10000, function() return conn.closed end, 20))
        assert.is_nil(exited)
    end)

    it("a ping counts as traffic", function()
        start({ keepalive_ms = 1000 })
        local conn = assert(client.session(srv.address))
        age_conns(3500)
        assert(client.request(conn, { kind = "ping" }))
        srv:lifetime()
        assert.equals(1, srv:client_count())
        conn:close()
    end)

    it("a connection still authenticating holds off the idle exit", function()
        start({ idle_seconds = 1 })
        local p = uv.new_pipe(false)
        local closed = false
        p:connect(srv.address, function(err)
            if err then closed = true; return end
            p:read_start(function(_, chunk) if not chunk then closed = true end end)
        end)
        vim.wait(2500, function() return exited ~= nil end, 20)
        assert.is_nil(exited)
        pcall(function() p:close() end)
        assert.is_true(vim.wait(8000, function() return exited ~= nil end, 20))
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
        srv = server_mod.new(root, { exit = function(code) exited = code end, tick_ms = 100,
            auth_timeout_ms = 30000 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)
    local function run(extra)
        local notes, logs = {}, {}
        local o = { config = { ["runtime-mode"] = "daemon" }, note = function(l) notes[#notes + 1] = l end,
            log = function(l) logs[#logs + 1] = l end, launch = function() error("must not launch") end,
            getenv = function() return nil end } -- never the runner's CI / LOOMWORKS_* variables
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
        H.cleanup()
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

describe("review hardening of the ensure path (§19.7, §19.10)", function()
    local LH = require("tests.lock_helpers")
    local root
    before_each(function() root = H.workspace() end)
    after_each(function()
        LH.cleanup() -- lock-holder helpers (they hold R in these tests)
        if not uv.fs_stat(dpaths.lock_path(root)) then return end
        H.track_root(root)
        H.cleanup()
    end)

    local function run(extra)
        local notes = {}
        local o = { config = { ["runtime-mode"] = "daemon" }, note = function(l) notes[#notes + 1] = l end,
            log = function() end, launch = function() error("must not launch") end,
            getenv = function() return nil end }
        for k, v in pairs(extra or {}) do o[k] = v end
        local t0 = uv.hrtime()
        local out = ensure.ensure(root, o)
        return out, notes, (uv.hrtime() - t0) / 1e6
    end

    it("never connects to a handle naming a foreign endpoint", function()
        local holder = LH.hold(dpaths.lock_path(root), "daemon", "daemon")
        handle.write(root, { pid = holder.pid, host = require("loomworks.lock_record").this_host(),
            endpoint = H.is_win and [[\\attacker-host\pipe\x]] or "/tmp/elsewhere.sock", protocol = 2 })
        local connects = 0
        local real = client.connect
        client.connect = function(...) connects = connects + 1; return real(...) end
        local out, notes = run()
        client.connect = real
        assert.equals("failed", out)
        assert.equals(0, connects)
        assert.equals(1, #notes)
        assert.truthy(notes[1]:find("untrusted handle", 1, true), notes[1])
    end)

    it("a daemon stuck starting costs a command about a second, once, with one line", function()
        local holder = LH.hold(dpaths.lock_path(root), "daemon", "daemon")
        local out, notes, ms = run()
        assert.equals("starting", out)
        assert.equals(1, #notes)
        assert.truthy(notes[1]:find("still starting", 1, true), notes[1])
        assert.truthy(ms < 2500, ms .. " ms")
    end)

    it("a daemon alive but not answering costs a command about a second", function()
        local env = H.env({ LW_TEST_HEARTBEAT_MS = "300", LW_TEST_DAEMON_TICK_MS = "300" })
        assert.equals(0, H.lw({ "daemon", "restart" }, { env = env, cwd = root }).code)
        local lk = H.track_root(root)
        assert.is_true(proc._suspend(lk.pid))
        trust._set_key_path(env.data .. "/trust.key")
        local out, notes, ms = run()
        trust._set_key_path(nil)
        proc.kill_tree(lk.pid, lk.start_time) -- the suspended daemon (not a leftover)
        assert.equals("failed", out)
        assert.equals(1, #notes)
        assert.truthy(ms < 2500, ms .. " ms")
    end)

    it("trust, nuke and unlock never start a daemon", function()
        local env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
        for _, args in ipairs({ { "unlock", "--workspace" }, { "unlock", "--journal" }, { "nuke", "-y" },
            { "--no-input", "trust" } }) do
            H.lw(args, { env = env, cwd = root })
            assert.is_nil(rlock.read(root), table.concat(args, " ") .. " started a daemon")
        end
    end)

    if not H.is_win then
        it("on root removal only the socket it bound is removed, not a successor's", function()
            trust._set_key_path(H.tmp() .. "/trust.key")
            local exited
            local srv = server_mod.new(root, { exit = function(c) exited = c end, tick_ms = 100,
                auth_timeout_ms = 30000 })
            assert(srv:start())
            local addr = srv.address
            srv.timer:stop()
            -- A successor's socket at the same path.
            pcall(function() srv.listener:close() end)
            os.remove(addr)
            local other = uv.new_pipe(false)
            assert(other:bind(addr))
            vim.fn.delete(root, "rf")
            srv:stop("test: root removed", 0)
            assert.equals(0, exited)
            assert.equals("socket", (uv.fs_lstat(addr) or {}).type)
            other:close()
            os.remove(addr)
            trust._set_key_path(nil)
            root = H.workspace()
        end)
    end
end)

describe("daemon processes", function()
    it("none was left running by any test of this file", function()
        H.cleanup()
        assert.equals(0, H.leftovers, "a test left a daemon process running")
    end)
end)
