-- The editor's observer of the workspace daemon (spec §19.11, §19.12,
-- §19.16) against an in-process server: the observer role and retirement,
-- `model_change`, the task stream resolved to domain objects (unresolved keys
-- by name only), keepalive, drop without relaunch, reconnect, incompatible
-- and retiring daemons, the host-binary order, and in-process mode.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local tasks_mod = require("loomworks.daemon.tasks")
local observer = require("loomworks.daemon.observer")
local host_binary = require("loomworks.daemon.host_binary")
local remote_task = require("loomworks.daemon.remote_task")
local version = require("loomworks.daemon.version")
local events = require("loomworks.events")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000
observer.CONNECT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

local function new_server(root)
    local s = { exited = nil }
    s.srv = server_mod.new(root, { exit = function(c) s.exited = c end, tick_ms = 100, auth_timeout_ms = 30000 })
    assert(s.srv:start())
    return s
end

describe("server: observers, retirement and model_change (§19.11, §19.12)", function()
    local root, s
    before_each(function()
        root = H.workspace()
        s = new_server(root)
    end)
    after_each(function()
        if not s.srv.stopped then s.srv:stop("test end", 0) end
    end)

    it("an observer never holds off a retirement and is told it retires", function()
        local got = {}
        local obs = assert(client.session(s.srv.address, { client = "editor", role = "observer",
            on_message = function(m) got[#got + 1] = m end }))
        local cli = assert(client.session(s.srv.address))
        local st = assert(client.request(cli, { kind = "status" }))
        assert.equals(2, st.clients)
        assert.equals(1, st.observers)
        assert(client.request(cli, { kind = "retire" }))
        assert.is_true(vim.wait(5000, function() return #got > 0 end, 10))
        assert.equals("retiring", got[1].kind)
        assert.is_nil(s.exited)
        cli:close()
        -- Only the observer is left: the daemon exits.
        assert.is_true(vim.wait(5000, function() return s.exited ~= nil end, 10))
        assert.equals(0, s.exited)
        obs:close()
    end)

    it("welcome says a daemon retires; model_change reaches every client with an advancing seq", function()
        local a, b = {}, {}
        local c1 = assert(client.session(s.srv.address, { on_message = function(m) a[#a + 1] = m end }))
        local c2 = assert(client.session(s.srv.address, { client = "editor", role = "observer",
            on_message = function(m) b[#b + 1] = m end }))
        assert.is_false(c2.welcome.retiring)
        s.srv:model_changed()
        s.srv:model_changed()
        assert.is_true(vim.wait(5000, function() return #a == 2 and #b == 2 end, 10))
        assert.equals("model_change", b[2].kind)
        assert.equals(2, b[2].seq)
        assert.equals(s.srv.generation, b[2].session_generation)
        assert(client.request(c1, { kind = "retire" }))
        local c3 = assert(client.session(s.srv.address, { client = "editor", role = "observer" }))
        assert.is_true(c3.welcome.retiring)
        assert.equals(2, c3.welcome.seq)
        c1:close(); c2:close(); c3:close()
    end)
end)

describe("version.observer_compatible (§19.9)", function()
    it("needs an equal protocol and schemas no newer; the host version may differ", function()
        local me = version.schemas()
        assert.is_true((version.observer_compatible({ protocol = version.PROTOCOL, lw_version = "9.9.9", schemas = me })))
        assert.is_true((version.observer_compatible({ protocol = version.PROTOCOL,
            schemas = { user = me.user - 1, cache = me.cache } })))
        local ok, what = version.observer_compatible({ protocol = version.PROTOCOL + 1, schemas = me })
        assert.is_false(ok); assert.equals("protocol", what)
        ok, what = version.observer_compatible({ protocol = version.PROTOCOL, schemas = { user = me.user + 1, cache = me.cache } })
        assert.is_false(ok); assert.equals("schemas", what)
    end)
end)

describe("host binary (§19.16)", function()
    it("LOOMWORKS_LW, then the provisioned pin, then PATH; none is nil", function()
        local f = H.tmp() .. "/my-lw"
        local h = assert(io.open(f, "w")); h:write("x"); h:close()
        local function env(v) return function(n) if n == "LOOMWORKS_LW" then return v end end end
        local bin, src = host_binary.resolve("/r", { getenv = env(f), pinned = function() return "/p" end,
            on_path = function() return "/path/lw" end })
        assert.equals(f, bin); assert.equals("LOOMWORKS_LW", src)
        bin, src = host_binary.resolve("/r", { getenv = env(H.tmp() .. "/missing"), pinned = function() return "/p" end,
            on_path = function() return "/path/lw" end })
        assert.equals("/p", bin); assert.equals("pin", src)
        bin, src = host_binary.resolve("/r", { getenv = env(nil), pinned = function() end,
            on_path = function() return "/path/lw" end })
        assert.equals("/path/lw", bin); assert.equals("PATH", src)
        assert.is_nil(host_binary.resolve("/r", { getenv = env(nil), pinned = function() end, on_path = function() end }))
    end)

    it("the pin resolves only to a binary already provisioned in the per-user pinned cache", function()
        local root = H.tmp()
        local asset = require("boot.pin").detect_asset()
        if not asset then return end
        local f = assert(io.open(root .. "/lw.pin", "w")); f:write("version = 0.0.7\n"); f:close()
        assert.is_nil(host_binary.pinned(root))
        local dir = require("boot.paths").data_dir() .. "/pinned"
        vim.fn.mkdir(dir, "p")
        local bin = dir .. "/lw-0.0.7-" .. asset
        f = assert(io.open(bin, "w")); f:write("x"); f:close()
        assert.equals(bin, host_binary.pinned(root))
        os.remove(bin)
    end)
end)

describe("the observer (§19.16)", function()
    local root, s, core, ws, obs
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
    end)
    after_each(function()
        if obs then obs:stop() end
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        if s and not s.srv.stopped then s.srv:stop("test end", 0) end
        s = nil
        pcall(function() core:shutdown() end)
    end)

    local function attach(extra)
        local o = { getenv = daemon_mode, watch_ms = 50, keepalive_ms = 100,
            resolve = function() return nil end }
        for k, v in pairs(extra or {}) do o[k] = v end
        return observer.attach(ws, o)
    end

    it("does nothing in in-process mode", function()
        assert.is_nil(observer.attach(ws, { getenv = function() return nil end }))
        assert.is_nil(ws._daemon_observer)
        assert.same({}, ws:get_daemon_tasks())
    end)

    it("with no daemon and no host binary: one note, nothing launched, then observes a daemon that appears", function()
        local spawned = 0
        obs = attach({ spawn = function() spawned = spawned + 1 end })
        assert.equals("no-binary", obs.state)
        assert.equals(host_binary.NONE_NOTE, obs:runtime_line())
        assert.equals(0, spawned)
        s = new_server(root)
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(1, s.srv:observer_count())
    end)

    it("resolves observed tasks to the editor's domain objects; unresolved keys by name only", function()
        s = new_server(root)
        local started, stopped = {}, {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        on("daemon_task_stopped", function(d) stopped[#stopped + 1] = d.task end)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        -- An owner (a CLI connection) and its task, streamed to the observer.
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local stream = tasks_mod.new(s.srv)
        local t = stream:create(owner)
        t:start({ name = "dev", kind = "build", profile = profile.key, units = {
            { project = pp:project_key(), configuration = pp:config_key() },
            { project = "ghost", configuration = "Nope" },
        } })
        assert.is_true(vim.wait(5000, function() return #started == 1 end, 10))
        local rt = ws:get_daemon_tasks()[1]
        assert.equals(started[1], rt)
        assert.equals(profile, rt.profile)
        assert.equals(unit, rt.units[1].unit)
        assert.is_nil(rt.units[2].unit)
        assert.equals("ghost", rt.units[2].project)
        assert.equals("building", unit:state())
        t:line("out", "building profile: dev")
        t:output("stdout", "compiler says hi\n")
        t:progress(0.5)
        assert.is_true(vim.wait(5000, function() return rt.pct == 50 end, 10))
        assert.truthy(rt:output():find("compiler says hi", 1, true))
        t:done(0)
        assert.is_true(vim.wait(5000, function() return #stopped == 1 end, 10))
        assert.equals(0, rt.exit_code)
        assert.same({}, ws:get_daemon_tasks())
        assert.is_true(unit:state() ~= "building")
        owner_client:close()
    end)

    it("model_change applies the files' pending changes at once; an old seq is ignored", function()
        s = new_server(root)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local syncs = 0
        local tr = ws._tracker
        local real = tr.sync
        tr.sync = function(self) syncs = syncs + 1; return real(self) end
        s.srv:model_changed()
        assert.is_true(vim.wait(5000, function() return syncs == 1 end, 10))
        for c in pairs(s.srv.conns) do
            if c.observer then s.srv:_send(c, { kind = "model_change", seq = 1, session_generation = s.srv.generation }) end
        end
        vim.wait(300)
        assert.equals(1, syncs)
        tr.sync = real
    end)

    it("keeps the connection alive with pings; drops on stop and never relaunches", function()
        s = new_server(root)
        -- Silent for 3 s: dropped. (Not shorter: the whole suite runs at once,
        -- and on a saturated runner one loop iteration of this process — which
        -- serves both the server and the observer — can take longer than a
        -- sub-second window; the observer was then dropped, reconnected, and
        -- missed the task started meanwhile.)
        s.srv.keepalive_ms = 1000
        local silent = assert(client.session(s.srv.address, { client = "editor", role = "observer" }))
        local spawned = 0
        obs = attach({ spawn = function() spawned = spawned + 1 end, resolve = function() return "lw" end })
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local conn = obs.conn
        -- The silent observer is dropped; the pinging one stays, on the same
        -- connection.
        assert.is_true(vim.wait(20000, function() return silent.closed end, 20))
        assert.equals("connected", obs.state)
        assert.equals(conn, obs.conn)
        assert.equals(1, s.srv:observer_count())
        -- A task running when the daemon goes away ends with it.
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        tasks_mod.new(s.srv):create(owner):start({ name = "dev", kind = "build" })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        local rt = ws:get_daemon_tasks()[1]
        s.srv:stop("stop requested", 0)
        owner_client:close()
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("disconnected", 1, true))
        assert.equals("the workspace daemon disconnected", rt.end_reason)
        assert.same({}, ws:get_daemon_tasks())
        vim.wait(500)
        assert.equals(0, spawned)
        -- (Reconnecting to a new daemon is covered with real processes in
        -- tests/daemon_editor_observer_spec: an in-process server cannot bind
        -- the same Windows pipe name again within one process.)
    end)

    it("disconnects from a retiring daemon and does not reconnect to it", function()
        s = new_server(root)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local cli = assert(client.session(s.srv.address))
        assert(client.request(cli, { kind = "retire" }))
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("retiring", 1, true))
        vim.wait(300)
        assert.equals("waiting", obs.state)
        assert.equals(0, s.srv:observer_count())
        cli:close()
        assert.is_true(vim.wait(5000, function() return s.exited ~= nil end, 10))
    end)

    it("does not observe an incompatible daemon (note, closed, skipped)", function()
        s = new_server(root)
        local connects, closed = 0, 0
        obs = attach({ connect = function(_, _, cb)
            connects = connects + 1
            cb({ challenge = { protocol = version.PROTOCOL + 1, lw_version = "9.0.0", schemas = version.schemas() },
                welcome = {}, close = function() closed = closed + 1 end })
        end })
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("not observing it", 1, true), obs:runtime_line())
        vim.wait(300)
        assert.equals(1, connects)
        assert.equals(1, closed)
    end)

    it("connect and launch are single-flight; a superseded connection is closed", function()
        local cbs = {}
        local live = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "e" } }
        obs = attach({ inspect = function() return live end, check = function() return true end,
            connect = function(_, _, cb) cbs[#cbs + 1] = cb end })
        assert.equals(1, #cbs)
        obs:start(true) -- `:LoomworksDaemon connect` while connecting
        obs:start(true)
        vim.wait(200)
        assert.equals(1, #cbs)
        -- A late answer to an attempt that is no longer in flight is closed.
        local stale = { closed = 0 }
        function stale.close() stale.closed = stale.closed + 1 end
        obs:_on_connected({ pid = 1 }, stale)
        assert.equals(1, stale.closed)
        assert.is_nil(obs.conn)
        obs:stop(); obs = nil
        -- Launching: a second connect does not start a second daemon.
        local spawned = 0
        obs = attach({ inspect = function() return { kind = "none" } end, resolve = function() return "lw" end,
            spawn = function() spawned = spawned + 1; return { pid = 1 } end })
        assert.equals("launching", obs.state)
        obs:start(true)
        assert.equals(1, spawned)
    end)

    it("a launched daemon that exits because an lw command holds the runtime is a note, not 'starting'", function()
        local child = { pid = 1 }
        local st = { kind = "none" }
        obs = attach({ inspect = function() return st end, resolve = function() return "lw" end,
            spawn = function() return child end })
        assert.equals("launching", obs.state)
        st = { kind = "attached", lock = { pid = 77 } }
        child.code = server_mod.EXIT_HELD
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("held by an lw command (pid 77)", 1, true), obs:runtime_line())
        assert.is_nil(obs._child)
    end)

    it("a `retiring` with no connection does not mark the next drop as a retirement", function()
        obs = attach({ inspect = function() return { kind = "hung", lock = { pid = 5 } } end })
        obs:_on_message({ kind = "retiring" })
        assert.is_nil(obs._retired_note)
    end)

    it("workspace teardown stops the observer and closes its connection", function()
        s = new_server(root)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local o = obs
        core:shutdown()
        assert.equals("stopped", o.state)
        assert.is_true(vim.wait(5000, function() return s.srv:observer_count() == 0 end, 10))
        obs = nil
    end)
end)

describe("remote task output cap (§19.16)", function()
    it("keeps about 1 MiB, then one truncation notice", function()
        local t = remote_task.new(nil, 1, { name = "x" }, 0)
        local chunk = string.rep("a", 64 * 1024)
        for _ = 1, 20 do t:append(chunk) end
        local out = t:output()
        assert.is_true(#out <= remote_task.OUTPUT_CAP_BYTES + 200)
        assert.truthy(out:find("truncated", 1, true))
    end)
end)

describe("status page Tasks section: remote tasks (spec/ui.md §1.9)", function()
    it("one row per unit marked (daemon); resolved units by their objects, unresolved by name", function()
        local unit = { _project = { key = "app" }, config_key = function() return "Debug" end }
        local t = remote_task.new(nil, 7, { name = "dev", kind = "build", profile = "dev" }, 0)
        t.units = { { unit = unit, project = "app", configuration = "Debug" },
            { project = "ghost", configuration = "Nope" } }
        t.pct = 40
        local rows = {}
        local tree = {
            leaf = function() end, blank = function() end,
            item = function(_, label) rows[#rows + 1] = label end,
        }
        require("loomworks.ui.sections.tasks")(tree, { lw = {
            get_active_tasks = function() return {} end,
            get_daemon_tasks = function() return { t } end,
            get_build_dir_locks_info = function() return {} end,
        } })
        -- rows[1] is the reset action.
        assert.truthy(rows[2]:find("app : Debug — build (daemon)  40%", 1, true), rows[2])
        assert.truthy(rows[3]:find("ghost : Nope — build (daemon)", 1, true), rows[3])
    end)
end)
