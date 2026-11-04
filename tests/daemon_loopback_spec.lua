-- The loopback transport of an attached run (spec §19.1 "Loopback"): the
-- in-memory pair, an attached server holding R in `attached` mode, and a
-- loopback client session against a real Server through the same frames,
-- encoder/decoder and handlers as the pipe.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local protocol = require("loomworks.daemon.protocol")
local loopback = require("loomworks.daemon.loopback")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local rlock = require("loomworks.daemon.rlock")
local handle = require("loomworks.daemon.handle")
local tasks_mod = require("loomworks.daemon.tasks")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

--- A stub build service: answers `build` with an ok reply and a task stream.
local function stub_service(srv)
    local svc = { closed = {}, stopping = nil }
    function svc:on_build(conn, msg)
        srv:_send(conn, { kind = protocol.KIND.ok, req_id = msg.req_id, task_id = 7 })
        srv:_send(conn, { kind = protocol.KIND.task, task_id = 7, phase = "line", stream = "out",
            text = "hello " .. tostring(msg.args and msg.args.profile) })
        srv:_send(conn, { kind = protocol.KIND.task, task_id = 7, phase = "done", exit_code = 0 })
    end
    function svc:owns_task() return false end
    function svc:on_conn_closed(conn) self.closed[#self.closed + 1] = conn end
    function svc:on_stopping(reason) self.stopping = reason end
    srv.service = svc
    return svc
end

--- The server side of the (only) connection.
local function server_conn(srv)
    for c in pairs(srv.conns) do return c end
end

describe("loopback pair (§19.1)", function()
    it("round-trips frames through the real encoder, in order and never inline", function()
        local a, b = loopback.pair()
        local dec = protocol.new_decoder(protocol.MAX_FRAME)
        local got = {}
        b:read_start(function(err, chunk)
            assert.is_nil(err)
            for _, m in ipairs(assert(dec:push(chunk))) do got[#got + 1] = m end
        end)
        local wrote = 0
        a:write(protocol.encode({ kind = "ping", req_id = 1 }), function(e) if not e then wrote = wrote + 1 end end)
        a:write(protocol.encode({ kind = "status", req_id = 2, text = string.rep("x", 1000) }))
        -- Asynchronous: nothing is delivered inside the write.
        assert.equals(0, #got)
        assert.is_true(vim.wait(2000, function() return #got == 2 and wrote == 1 end, 5))
        assert.equals("ping", got[1].kind)
        assert.equals("status", got[2].kind)
        assert.equals(1000, #got[2].text)
        assert.equals(0, a:get_write_queue_size())
    end)

    it("delivers EOF after the written bytes on close, in both directions", function()
        for _, closer in ipairs({ "a", "b" }) do
            local ends = { loopback.pair() }
            local x = closer == "a" and ends[1] or ends[2]
            local y = closer == "a" and ends[2] or ends[1]
            local chunks, eof = {}, false
            y:read_start(function(_, chunk)
                if chunk then chunks[#chunks + 1] = chunk else eof = true end
            end)
            x:write("last words")
            x:close()
            assert.is_true(x:is_closing())
            assert.is_true(vim.wait(2000, function() return eof end, 5))
            assert.same({ "last words" }, chunks)
            -- Writing to a closed end fails; writing to a closed peer says EPIPE.
            assert.is_nil((x:write("more")))
            local perr
            y:write("into the void", function(e) perr = e end)
            assert.is_true(vim.wait(2000, function() return perr ~= nil end, 5))
            assert.equals("EPIPE", perr)
        end
    end)

    it("holds bytes in the writer's queue while the reader is paused", function()
        local a, b = loopback.pair()
        local n = 0
        local function reader(_, chunk) if chunk then n = n + #chunk end end
        b:read_start(reader)
        b:read_stop()
        a:write(string.rep("a", 100))
        vim.wait(50, function() return false end, 5)
        assert.equals(100, a:get_write_queue_size())
        a:write(string.rep("b", 50))
        assert.equals(150, a:get_write_queue_size())
        assert.equals(0, n)
        b:read_start(reader)
        assert.is_true(vim.wait(2000, function() return n == 150 end, 5))
        assert.equals(0, a:get_write_queue_size())
    end)
end)

describe("attached runtime (§19.1, §19.2)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { tick_ms = 100 })
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("holds R in attached mode with its command, and releases it on stop without exiting", function()
        assert(srv:start_attached({ command = "build" }))
        local info = assert(rlock.read(root))
        assert.equals("attached", info.mode)
        assert.equals("build", info.command)
        assert.equals("lw build", rlock.holder_text(info))
        -- No endpoint, no handle.
        assert.is_nil(srv.address)
        assert.is_nil(srv.listener)
        assert.is_nil(handle.read(root))
        srv:stop("done", 0)
        assert.is_true(srv.stopped)
        assert.equals(0, srv.exit_code)
        assert.is_nil(rlock.read(root))
    end)

    it("is refused while another attached run holds R", function()
        assert(srv:start_attached({ command = "build" }))
        local other = server_mod.new(root, {})
        local ok, err, code = other:start_attached({ command = "test" })
        assert.is_nil(ok)
        assert.equals(server_mod.EXIT_HELD, code)
        assert.truthy(err:find("lw build", 1, true))
        -- Nor can a daemon start.
        local d = server_mod.new(root, { exit = function() end })
        local dok, _, dcode = d:start()
        assert.is_nil(dok)
        assert.equals(server_mod.EXIT_HELD, dcode)
    end)

    it("is refused while a live daemon holds R", function()
        local daemon = server_mod.new(root, { exit = function() end, tick_ms = 100 })
        assert(daemon:start())
        local ok, err, code = srv:start_attached({ command = "clean" })
        assert.is_nil(ok)
        assert.equals(server_mod.EXIT_HELD, code)
        assert.truthy(err:find("the workspace daemon", 1, true))
        daemon:stop("test end", 0)
        assert.is_nil(rlock.read(root))
    end)

    it("serves a request over a loopback session, with the pipe session's shape", function()
        assert(srv:start_attached({ command = "build" }))
        local svc = stub_service(srv)
        local events = {}
        local conn, err = client.loopback_sessioner(srv)(nil, {
            timeout_ms = 5000,
            on_message = function(m) events[#events + 1] = m end,
        })
        assert.is_not_nil(conn, err)
        assert.is_true(conn.loopback)
        assert.equals("welcome", conn.welcome.kind)
        assert.equals(srv.generation, conn.challenge.session_generation)
        assert.equals(1, srv:client_count())
        -- A frozen control request, then a routed one through the stub.
        local st = assert(client.request(conn, { kind = "status" }))
        assert.equals(srv.pid, st.pid)
        local reply = assert(client.request(conn, { kind = "build", args = { profile = "dev" } }))
        assert.equals(7, reply.task_id)
        assert.is_true(vim.wait(2000, function()
            return events[#events] and events[#events].phase == "done"
        end, 5))
        assert.equals("hello dev", events[1].text)
        -- The client closes: the server sees EOF and drops the connection.
        conn:close()
        assert.is_true(vim.wait(2000, function() return srv:client_count() == 0 end, 5))
        assert.equals(1, #svc.closed)
    end)

    it("closes the client (pending requests told) when the runtime stops", function()
        assert(srv:start_attached({ command = "build" }))
        local svc = stub_service(srv)
        svc.on_build = function() end -- never answers
        local closed = false
        local conn = assert(client.loopback_session(srv, { on_close = function() closed = true end }))
        local rerr
        conn:request({ kind = "build", args = {} }, function(_, e) rerr = e end)
        vim.wait(50, function() return false end, 5)
        srv:stop("command done", 0)
        assert.is_true(vim.wait(2000, function() return closed end, 5))
        assert.is_true(conn.closed)
        assert.equals(client.ERR_CLOSED, rerr)
        assert.equals("command done", svc.stopping)
        assert.is_nil(rlock.read(root))
    end)

    it("a lost lock freezes workspace writes BEFORE the running operation is cancelled (§19.2)", function()
        assert(srv:start_attached({ command = "clean" }))
        local svc = stub_service(srv)
        local ws, order = {}, {}
        svc.ws = ws
        function svc:freeze_writes() order[#order + 1] = "freeze"; ws._no_write = "lost" end
        function svc:on_stopping() order[#order + 1] = "stopping, frozen=" .. tostring(ws._no_write ~= nil) end
        -- Replaced by another runtime (our record gone).
        assert.is_true(os.remove(rlock.path(root)) ~= nil)
        srv:_tick()
        assert.same({ "freeze", "stopping, frozen=true" }, order)
        assert.is_true(srv.stopped)
        assert.equals(server_mod.LOST_LOCK, srv.stop_reason)
        assert.equals(1, srv.exit_code)
        -- A frozen workspace saves neither the cache nor the working copy.
        local Workspace = require("loomworks.workspace").Workspace
        assert.is_false(Workspace._save_cache(ws))
        local uok, uerr = Workspace._save_user(ws)
        assert.is_false(uok)
        assert.equals("lost", uerr)
    end)

    it("a stopping service declines a queued request instead of starting it", function()
        assert(srv:start_attached({ command = "build" }))
        local service = require("loomworks.daemon.service")
        local svc = service.attach(srv, { current = function() return nil end, unload = function() end })
        local ran, replied = false, nil
        local ctx = { env = {} }
        function ctx.reply(f) ctx.replied = true; replied = f end
        svc:with_model(ctx, function() ran = true end)
        svc:on_stopping("the runtime lock was taken over")
        assert.is_false(ran)
        assert.equals("declined", replied and replied.outcome)
        vim.wait(50, function() return false end, 5)
        assert.is_false(ran)
    end)

    it("grows the server's write queue while the client stops reading", function()
        assert(srv:start_attached({ command = "build" }))
        local got = 0
        local conn = assert(client.loopback_session(srv, { on_message = function() got = got + 1 end }))
        local sconn = assert(server_conn(srv))
        conn:pause_reading()
        local before = tasks_mod._queued(sconn)
        for i = 1, 5 do
            srv:_send(sconn, { kind = protocol.KIND.task, task_id = 1, phase = "line", stream = "out",
                text = string.rep("z", 1000) .. i })
        end
        vim.wait(50, function() return false end, 5)
        local after = tasks_mod._queued(sconn)
        assert.is_true(after > before + 5000)
        assert.equals(0, got)
        conn:resume_reading()
        assert.is_true(vim.wait(2000, function() return got == 5 end, 5))
        assert.equals(0, tasks_mod._queued(sconn))
        conn:close()
    end)

    it("delivers broadcasts to a loopback observer of protocol 10", function()
        assert(srv:start_attached({ command = "build" }))
        local seen
        local conn = assert(client.loopback_session(srv, { role = "observer", protocol = 10,
            on_message = function(m) if m.kind == protocol.KIND.model_change then seen = m end end }))
        assert.equals(1, srv:observer_count())
        assert.equals(0, srv:active_clients())
        srv:model_changed()
        assert.is_true(vim.wait(2000, function() return seen ~= nil end, 5))
        assert.equals(srv.generation, seen.session_generation)
        conn:close()
    end)

    it("refuses a loopback session once the runtime stopped", function()
        assert(srv:start_attached({ command = "build" }))
        srv:stop("done", 0)
        local conn, err = client.loopback_session(srv, { timeout_ms = 1000 })
        assert.is_nil(conn)
        assert.equals(client.ERR_CONNECT, err)
    end)
end)
