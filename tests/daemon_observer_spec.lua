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
        -- The same runtime state as a local operation (§19.16 Running state):
        -- the profile has an active operation, but nothing the editor could
        -- cancel; the unit's project shows it running; the origin is the owner's.
        assert.equals("cli", rt.origin)
        assert.equals("lw", rt:origin_label())
        assert.is_true(profile:has_active_operation())
        assert.equals(rt, profile:remote_tasks()[1])
        assert.is_false(profile:is_running())
        assert.is_nil(unit:running_action())
        assert.equals("build", unit:shown_action())
        assert.equals("build", unit._project:running_action())
        assert.is_number(profile:operation_elapsed())
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
        assert.is_false(profile:has_active_operation())
        assert.is_nil(unit:shown_action())
        -- Its end message is the profile's last operation, as a local one's.
        assert.truthy(profile:operation().message:find("^built in "), profile:operation().message)
        assert.is_true(profile:operation().success)
        owner_client:close()
    end)

    it("joins late: adopts the tasks a status reply lists, with their start time and percent", function()
        s = new_server(root)
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        -- A task already running (owned by a CLI connection) before the editor connects.
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local stream = tasks_mod.new(s.srv)
        s.srv.service = { tasks = stream, owns_task = function() return false end,
            on_conn_closed = function() end, on_stopping = function() end }
        local t = stream:create(owner)
        t:start({ name = "dev", kind = "test", profile = profile.key, units = {
            { project = pp:project_key(), configuration = pp:config_key() } } })
        t.started_at = os.time() - 75
        t:progress(0.3)
        local started = {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return #started == 1 end, 10), obs:runtime_line())
        local rt = ws:get_daemon_tasks()[1]
        assert.equals(t.id, rt.id)
        assert.equals("test", rt.kind)
        assert.equals("cli", rt.origin)
        assert.equals(30, rt.pct)
        assert.is_true(rt:elapsed(obs:_clock()) >= 74)
        assert.equals(unit, rt.units[1].unit)
        assert.equals("building", unit:state())
        assert.is_true(profile:has_active_operation())
        -- Its output starts now; it ends on done like any other.
        t:output("stdout", "later output\n")
        assert.is_true(vim.wait(5000, function() return rt:output():find("later output", 1, true) ~= nil end, 10))
        t:done(1, "tests failed")
        assert.is_true(vim.wait(5000, function() return rt.finished end, 10))
        assert.same({}, ws:get_daemon_tasks())
        assert.is_false(profile:has_active_operation())
        assert.truthy(rt:outcome():find("test failed", 1, true), rt:outcome())
        s.srv.service = nil
        owner_client:close()
    end)

    it("a remote clean shows its units cleaning, ends cleaned / clean failed, titled Cleaning (lw)", function()
        -- fidget with a recording progress API (the title is the handle's message).
        local titles = {}
        local saved = package.loaded["fidget.progress"]
        package.loaded["fidget.progress"] = { handle = { create = function(o)
            titles[#titles + 1] = o.message
            return { report = function() end, finish = function() end, cancel = function() end }
        end } }
        require("loomworks.fidget").setup()
        package.loaded["fidget.progress"] = saved
        s = new_server(root)
        local stopped = {}
        on("daemon_task_stopped", function(d) stopped[#stopped + 1] = d.task end)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        local before = unit:local_state()
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local stream = tasks_mod.new(s.srv)
        local units = { { project = pp:project_key(), configuration = pp:config_key() } }
        local t = stream:create(owner)
        t:start({ name = "dev", kind = "clean", profile = profile.key, units = units })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        local rt = ws:get_daemon_tasks()[1]
        -- The display of the transient clean state, as a local clean's.
        assert.equals("deleting", unit:state())
        assert.equals("cleaning", unit:deleting_reason())
        assert.equals("cleaning", (require("loomworks.ui.helpers").resolve_unit_status(unit)))
        assert.is_nil(unit:shown_action())
        assert.is_false(unit:is_deleting())
        assert.equals(before, unit:local_state())
        assert.is_true(profile:has_active_operation())
        assert.equals("Cleaning (lw)", titles[#titles])
        t:done(0)
        assert.is_true(vim.wait(5000, function() return #stopped == 1 end, 10))
        assert.truthy(rt:outcome():find("^cleaned in "), rt:outcome())
        assert.truthy(profile:operation().message:find("^cleaned in "), profile:operation().message)
        assert.is_nil(unit:deleting_reason())
        assert.equals(before, unit:state())
        local t2 = stream:create(owner)
        t2:start({ name = "dev", kind = "clean", profile = profile.key, units = units })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        local rt2 = ws:get_daemon_tasks()[1]
        t2:done(3, "clean failed (exit 3): app: clean Debug")
        assert.is_true(vim.wait(5000, function() return #stopped == 2 end, 10))
        assert.truthy(rt2:outcome():find("^clean failed in .*: clean failed %(exit 3%)"), rt2:outcome())
        -- A remote test or run shows its units building.
        for _, kind in ipairs({ "test", "run" }) do
            local tk = stream:create(owner)
            tk:start({ name = "dev", kind = kind, profile = profile.key, units = units })
            assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
            assert.equals("building", unit:state(), kind)
            tk:done(0)
            assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 0 end, 10))
        end
        owner_client:close()
    end)

    it("a remote task never blocks an editor build or launch (the build-dir locks do)", function()
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        -- Build it for real first, so the editor's build is a plain build
        -- (no configure in front of it).
        local cli = require("loomworks.cli")
        local orig_write = io.write
        io.write = function() end
        local ok, err = pcall(cli.cmd_build, ws, { "build", profile.key })
        io.write = orig_write
        assert.is_true(ok, tostring(err))
        assert.equals("built", unit:state())
        assert.is_nil(unit:configure_reason(false, profile))
        s = new_server(root)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local t = tasks_mod.new(s.srv):create(owner)
        t:start({ name = "dev", kind = "build", profile = profile.key, units = {
            { project = pp:project_key(), configuration = pp:config_key() } } })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        -- Shown building, yet nothing the editor runs is gated on it.
        assert.equals("building", unit:state())
        assert.equals("built", unit:local_state())
        local created = {}
        local orig_overseer = package.loaded["overseer"]
        package.loaded["overseer"] = {
            new_task = function(spec)
                created[#created + 1] = spec
                return { id = #created, subscribe = function() end, start = function() end,
                    stop = function() end, is_complete = function() return false end }
            end,
        }
        local settled = nil
        local okc, cerr = pcall(function()
            require("loomworks.overseer").run_profile_action(profile, "build")
                :next(function() settled = "resolved" end, function(e) settled = "rejected: " .. tostring(e) end)
            -- The build starts (it meets the build-dir lock (§16.6) of a
            -- real `lw build`); it is not skipped and resolved as done.
            assert.is_true(vim.wait(5000, function() return #created > 0 end, 10),
                "editor build was skipped: " .. tostring(settled))
            assert.is_nil(settled)
        end)
        -- A single build task is not rejected because of the remote task either.
        local single = nil
        local oks, serr = pcall(function()
            local f = require("loomworks.overseer").launch_single_task({
                name = "single", builder = function() return { cmd = { vim.v.progpath, "--version" } } end,
                loomworks = { unit = unit, action = "build" },
            }, unit)
            f:next(function() single = "resolved" end, function(e) single = "rejected: " .. tostring(e) end)
            vim.wait(200, function() return single ~= nil end, 10)
            assert.is_nil(single)
        end)
        package.loaded["overseer"] = orig_overseer
        assert.is_true(okc, tostring(cerr))
        assert.is_true(oks, tostring(serr))
        t:done(0)
        owner_client:close()
    end)

    it("a task both broadcast (`start`) and listed in the join-late status reply is adopted once", function()
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        local started = {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        obs = attach({ spawn = function() end })
        local meta = { name = "dev", kind = "build", profile = profile.key, origin = "cli",
            units = { { project = pp:project_key(), configuration = pp:config_key() } } }
        -- A connection whose status reply is held until the test releases it.
        local function fake_conn()
            local c = { pending = nil }
            function c:request(_, cb) self.pending = cb end
            function c:close() end
            return c
        end
        local function reply(c, id)
            local entry = vim.tbl_extend("force", { task_id = id, started_at = os.time() }, meta)
            c.pending({ tasks = { entry } })
            vim.wait(50)
        end
        -- The broadcast first, then the reply listing the same task.
        local c1 = fake_conn()
        obs.conn = c1
        obs:_join_late(c1)
        obs:_on_message({ kind = "task", phase = "start", task_id = 7, meta = meta })
        reply(c1, 7)
        assert.equals(1, #started)
        assert.equals(1, #ws:get_daemon_tasks())
        assert.equals(1, #profile:remote_tasks())
        -- The reply first, then a late-arriving broadcast of the same task.
        local c2 = fake_conn()
        obs.conn = c2
        obs:_join_late(c2)
        reply(c2, 8)
        obs:_on_message({ kind = "task", phase = "start", task_id = 8, meta = meta })
        assert.equals(2, #started)
        assert.equals(2, #ws:get_daemon_tasks())
        assert.equals(2, #profile:remote_tasks())
        -- Each ends once; then nothing of either is left.
        obs:_on_message({ kind = "task", phase = "done", task_id = 7, exit_code = 0 })
        obs:_on_message({ kind = "task", phase = "done", task_id = 8, exit_code = 0 })
        assert.same({}, ws:get_daemon_tasks())
        assert.same({}, profile:remote_tasks())
        assert.is_nil(unit:shown_action())
        obs.conn = nil
    end)

    it("workspace teardown with a remote task running clears it without recording a failure", function()
        s = new_server(root)
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local t = tasks_mod.new(s.srv):create(owner)
        t:start({ name = "dev", kind = "build", profile = profile.key, units = {
            { project = pp:project_key(), configuration = pp:config_key() } } })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        local before = profile:operation()
        assert.equals("building", unit:state())
        core:shutdown()
        obs = nil
        assert.same({}, profile:remote_tasks())
        assert.is_false(profile:has_active_operation())
        assert.is_nil(unit:shown_action())
        assert.is_true(unit:state() ~= "building")
        -- Not an operation that ended: the last result is what it was before.
        assert.equals(before, profile:operation())
        owner_client:close()
    end)

    it("a dropped connection clears the remote tasks' running state at once", function()
        s = new_server(root)
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        local owner_client = assert(client.session(s.srv.address))
        local owner
        for c in pairs(s.srv.conns) do if c.authed and not c.observer then owner = c end end
        local t = tasks_mod.new(s.srv):create(owner)
        t:start({ name = "dev", kind = "build", profile = profile.key, units = {
            { project = pp:project_key(), configuration = pp:config_key() } } })
        assert.is_true(vim.wait(5000, function() return #ws:get_daemon_tasks() == 1 end, 10))
        local rt = ws:get_daemon_tasks()[1]
        assert.equals("building", unit:state())
        obs.conn:close()
        assert.is_true(vim.wait(5000, function() return rt.finished end, 10))
        assert.equals("the workspace daemon disconnected", rt:outcome())
        assert.is_true(unit:state() ~= "building")
        assert.is_false(profile:has_active_operation())
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
        -- The CLI (here: another process) started it: the handle names its
        -- executable, and the note carries that path (§19.6, §19.16).
        local h = assert(require("loomworks.daemon.handle").read(root))
        assert.is_string(h.exe)
        assert.truthy(obs:runtime_line():find("lw v9.0.0 at " .. h.exe, 1, true), obs:runtime_line())
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

    -- A fake daemon session for the relaunch tests: inspect says what is on
    -- disk, connect hands back a conn whose close reports the drop.
    local function fake_daemon()
        local f = { st = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "e" } },
            spawned = 0, connects = 0 }
        f.opts = { inspect = function() return f.st end, check = function() return true end,
            resolve = function() return "lw" end,
            spawn = function() f.spawned = f.spawned + 1; f.child = { pid = 99 }; return f.child end,
            connect = function(_, copts, cb)
                f.connects = f.connects + 1
                local conn = { challenge = { protocol = version.PROTOCOL, schemas = version.schemas(),
                    lw_version = "0.1.0" }, welcome = { seq = 0 } }
                function conn.close(c)
                    if c.closed then return end
                    c.closed = true
                    if copts.on_close then copts.on_close(c) end
                end
                f.conn = conn
                cb(conn)
            end }
        return f
    end

    it("after a retired daemon exits, launches one successor (once) and connects to it", function()
        local f = fake_daemon()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(0, f.spawned)
        -- Retiring (a version change): the observer disconnects and waits.
        f.st = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "e" } }
        obs:_on_message({ kind = "retiring" })
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(200)
        assert.equals(0, f.spawned)
        -- The retired daemon exits: the editor launches one daemon itself.
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        assert.equals("launching", obs.state)
        -- It comes up: the observer connects to it.
        f.st = { kind = "live", handle = { pid = 4343, start_time = "u", endpoint = "e" } }
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(4343, obs.daemon.pid)
        assert.equals(1, f.spawned)
    end)

    it("after a retired daemon exits, a successor that fails is not launched again", function()
        local f = fake_daemon()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        obs:_on_message({ kind = "retiring" })
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        f.child.code = 1
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(400)
        assert.equals(1, f.spawned)
    end)

    it("a daemon stopped by the user (no retirement) is never relaunched", function()
        local f = fake_daemon()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        f.conn:close() -- `lw daemon stop`: the connection just drops
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(400)
        assert.equals(0, f.spawned)
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
    local function render(local_tasks, remote)
        local rows = {}
        local tree = {
            leaf = function() end, blank = function() end,
            item = function(_, label, opts) rows[#rows + 1] = { label = label, opts = opts } end,
        }
        require("loomworks.ui.sections.tasks")(tree, { lw = {
            get_active_tasks = function() return local_tasks end,
            get_daemon_tasks = function() return remote end,
            get_build_dir_locks_info = function() return {} end,
        } })
        return rows
    end
    local function text(label)
        if type(label) == "string" then return label end
        local t = {}
        for _, c in ipairs(label) do t[#t + 1] = c[1] end
        return table.concat(t)
    end
    local function now() return (vim.uv or vim.loop).hrtime() / 1e9 end

    it("rows in a local task's format with the dim origin marker last; unresolved units by name", function()
        local unit = { _project = { key = "app" }, config_key = function() return "Debug" end }
        local t = remote_task.new(nil, 7, { name = "dev", kind = "build", profile = "dev", origin = "cli" }, now())
        t.units = { { unit = unit, project = "app", configuration = "Debug" },
            { project = "ghost", configuration = "Nope" } }
        t.pct = 40
        local rows = render({}, { t })
        -- rows[1] is the reset action.
        assert.truthy(text(rows[2].label):find("^▸ app : Debug — build  40%%  %d+s  lw$"), text(rows[2].label))
        assert.truthy(text(rows[3].label):find("^▸ ghost : Nope — build"), text(rows[3].label))
        assert.same({ "  lw", "Comment" }, rows[2].label[#rows[2].label])
        local e = remote_task.new(nil, 8, { name = "p", kind = "test", profile = "p", origin = "editor" }, now())
        local erow = text(render({}, { e })[2].label)
        assert.truthy(erow:find("^▸ p — test  %d+s  editor$"), erow)
    end)

    it("orders local and remote tasks by start; Enter on a remote row offers Show output only", function()
        local n = now()
        local early = remote_task.new(nil, 1, { name = "dev", kind = "build", profile = "dev", origin = "cli" }, n - 100)
        local late = remote_task.new(nil, 2, { name = "rel", kind = "build", profile = "rel", origin = "cli" }, n - 1)
        local loc = { task_id = 9, project_key = "app", config_key = "Debug", action = "build", start_time = n - 50 }
        local rows = render({ loc }, { early, late })
        assert.truthy(text(rows[2].label):find("dev", 1, true))
        assert.truthy(text(rows[3].label):find("app : Debug", 1, true))
        assert.truthy(text(rows[4].label):find("rel", 1, true))
        local offered
        local real = vim.ui.select
        vim.ui.select = function(items) offered = items end
        rows[2].opts.on_enter()
        vim.ui.select = real
        assert.same({ "Show output" }, offered)
    end)
end)

describe("lw status running-task lines (§19.6)", function()
    local running = require("loomworks.daemon.running")
    local live = { kind = "live", handle = { valid = true, busy = true, endpoint = "x", key_id = "k",
        lw_version = "0.1.44" } }

    it("asks only a live, busy daemon with this lw's key", function()
        assert.is_true(running.should_query(live, "k"))
        assert.is_false(running.should_query(live, "other"))
        assert.is_false(running.should_query(live, false))
        local idle = { kind = "live", handle = { valid = true, busy = false, endpoint = "x", key_id = "k" } }
        assert.is_false(running.should_query(idle, "k"))
        assert.is_false(running.should_query({ kind = "starting", handle = live.handle }, "k"))
        local asked = 0
        assert.same({}, running.lines("/r", { state = idle, own_key_id = "k",
            query = function() asked = asked + 1 end }))
        assert.equals(0, asked)
    end)

    it("one line per task: operation, profile, origin, elapsed, percent", function()
        local lines = running.lines("/r", { state = live, own_key_id = "k", now = 1000, query = function()
            return { tasks = {
                { task_id = 1, kind = "build", profile = "Debug:ninja-gcc", origin = "cli", started_at = 928, percent = 43 },
                { task_id = 2, kind = "test", profile = "Release:msvc-17", origin = "editor", started_at = 992 },
            } }
        end })
        assert.same({
            "  build  Debug:ninja-gcc  (lw)      1m12s  43%",
            "  test   Release:msvc-17  (editor)  8s",
        }, lines)
    end)

    it("an old daemon or a failed query is one line; no tasks, no lines", function()
        assert.same({ "  running tasks: not reported by daemon lw 0.1.42" },
            running.lines("/r", { state = live, own_key_id = "k", query = function()
                return { _lw_version = "0.1.42" } end }))
        assert.same({ "  running tasks: unavailable (timeout)" },
            running.lines("/r", { state = live, own_key_id = "k", query = function() return nil, "timeout" end }))
        assert.same({}, running.lines("/r", { state = live, own_key_id = "k", query = function()
            return { tasks = {} } end }))
    end)

    it("queries a real daemon's status", function()
        local root = H.workspace()
        local s = new_server(root)
        local reply = running.query(s.srv.address, { timeout_ms = 30000 })
        assert.is_not_nil(reply)
        assert.same({}, reply.tasks)
        assert.is_string(reply._lw_version)
        s.srv:stop("test end", 0)
    end)
end)
