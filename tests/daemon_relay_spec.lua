-- The `lw daemon run --stdio` relay (spec §19.8 "Relay handshake", §19.10
-- "Connections", "No launch", "Skip an instance", "Relay buffering", "Relay
-- exit status", step 5i): loomworks.daemon.relay. The relay itself runs in
-- this process over in-memory ends (the client's standard input and output)
-- against an in-process server; the last block runs real `lw` processes.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local relay = require("loomworks.daemon.relay")
local connect = require("loomworks.daemon.connect")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local protocol = require("loomworks.daemon.protocol")
local version = require("loomworks.daemon.version")
local handle = require("loomworks.daemon.handle")
local dpaths = require("loomworks.daemon.paths")
local inspect = require("loomworks.daemon.inspect")
local loopback = require("loomworks.daemon.loopback")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

-- The suite runs every spec file at once: an in-process handshake can take
-- seconds on a loaded runner.
client.TIMEOUT_MS = 30000
local STEP = 30000

local function hello(extra)
    return vim.tbl_extend("force", { kind = "hello", protocol = protocol.VERSION, protocol_min = protocol.VERSION_MIN,
        lw_version = version.identity(), schemas = version.schemas(), client = "editor", role = "observer",
        nonce = string.rep("ab", 16) }, extra or {})
end

local function write_lock(root, rec)
    local f = assert(io.open(dpaths.lock_path(root), "w"))
    f:write(vim.json.encode(rec))
    f:close()
end

describe("relay arguments (§19.10 \"Relay exit status\": usage)", function()
    local function args(...) return { "daemon", "run", ... } end
    local env1 = function(k) return k == relay.PRIVATE_ENV and "1" or nil end
    local env0 = function() return nil end

    it("accepts the relay forms", function()
        local o = assert(relay.parse(args("--root", "/w/", "--stdio"), env0))
        assert.same({ stdio = true, private = false, no_launch = false, root = "/w" }, o)
        o = assert(relay.parse(args("--stdio", "--root=C:\\w", "--no-launch"), env0))
        assert.is_true(o.no_launch)
        assert.equals("C:/w", o.root)
        o = assert(relay.parse(args("--root", "/w", "--stdio", "--no-launch", "--skip-instance", "12:win:99"), env0))
        assert.same({ pid = 12, start_time = "win:99" }, o.skip)
        o = assert(relay.parse(args("--root", "/w", "--stdio", "--no-launch", "--skip-instance=7:linux:b:1"), env0))
        assert.same({ pid = 7, start_time = "linux:b:1" }, o.skip)
        o = assert(relay.parse(args("--root", "/w", "--stdio", "--private"), env1))
        assert.is_true(o.private)
    end)

    it("refuses each usage error", function()
        local cases = {
            { args("--stdio"), env0, "--root" },
            { args("--root", "/w", "--stdio", "--private"), env0, "--private is for tests only" },
            { args("--root", "/w", "--stdio", "--private"), function() return "0" end, "for tests only" },
            { args("--root", "/w", "--private"), env1, "--private needs --stdio" },
            { args("--root", "/w", "--no-launch"), env0, "--no-launch needs --stdio" },
            { args("--root", "/w", "--stdio", "--no-launch", "--private"), env1, "--private" },
            { args("--root", "/w", "--stdio", "--skip-instance", "1:win:1"), env0, "needs --no-launch" },
            { args("--root", "/w", "--stdio", "--no-launch", "--skip-instance", "garbage"), env0, "<pid>:<start_time>" },
            { args("--root", "/w", "--stdio", "--no-launch", "--skip-instance", "12"), env0, "<pid>:<start_time>" },
            { args("--root", "/w", "--stdio", "--no-launch", "--skip-instance"), env0, "<pid>:<start_time>" },
            { args("--root", "/w", "--stdio", "--no-launch", "--skip-instance", "1:win:1", "--skip-instance", "2:win:2"),
                env0, "at most one" },
        }
        for _, c in ipairs(cases) do
            local o, err = relay.parse(c[1], c[2])
            assert.is_nil(o, table.concat(c[1], " "))
            assert.truthy(err and err:find(c[3], 1, true), table.concat(c[1], " ") .. ": " .. tostring(err))
        end
    end)

    it("only the options before `--` select a standard-I/O form", function()
        local command = require("loomworks.daemon.command")
        assert.is_true(command.relay_form(args("--root", "/w", "--stdio")))
        assert.is_true(command.relay_form(args("--skip-instance=1:win:1")))
        assert.is_false(command.relay_form(args("--root", "/w", "--", "--stdio")))
        assert.is_false(command.relay_form(args("--", "--private", "--no-launch", "--skip-instance", "1:win:1")))
        -- `lw daemon run -- --stdio` is the ordinary foreground server, never the relay.
        local saved_serve = relay.serve
        local relayed = false
        relay.serve = function() relayed = true; return 0 end
        local ok, err = pcall(command.run_server, nil, args("--", "--stdio"), {
            note = function() end, die = function(m) error("die: " .. m, 0) end })
        relay.serve = saved_serve
        assert.is_false(ok)
        assert.truthy(tostring(err):find("no loomworks.json", 1, true), tostring(err))
        assert.is_false(relayed)
    end)
end)

describe("relay hardening", function()
    it("honours the timing test hooks only behind the private-stdio gate, within bounds", function()
        local function env(vars) return function(k) return vars[k] end end
        local name = "LW_TEST_RELAY_POLL_MS"
        assert.equals(2000, relay._test_ms(env({ [name] = "50" }), name, 2000, 10))
        local gate = relay.PRIVATE_ENV
        assert.equals(50, relay._test_ms(env({ [gate] = "1", [name] = "50" }), name, 2000, 10))
        assert.equals(10, relay._test_ms(env({ [gate] = "1", [name] = "0" }), name, 2000, 10))
        assert.equals(2000, relay._test_ms(env({ [gate] = "1", [name] = "-5" }), name, 2000, 10))
        assert.equals(2000, relay._test_ms(env({ [gate] = "1", [name] = "soon" }), name, 2000, 10))
        assert.equals(2000, relay._test_ms(env({ [gate] = "1", [name] = "inf" }), name, 2000, 10))
        assert.equals(2000, relay._test_ms(env({ [gate] = "1" }), name, 2000, 10))
        assert.equals(0, relay._test_ms(env({ [gate] = "1", LW_TEST_RELAY_RETIRE_MS = "0" }),
            "LW_TEST_RELAY_RETIRE_MS", 60000, 0))
        assert.equals(60000, relay._test_ms(env({ [gate] = "0", LW_TEST_RELAY_RETIRE_MS = "0" }),
            "LW_TEST_RELAY_RETIRE_MS", 60000, 0))
    end)

    it("validates the client's hello before forwarding it", function()
        assert.is_true(relay.valid_hello(hello()))
        assert.is_true(relay.valid_hello({ kind = "hello" }))
        assert.is_true(relay.valid_hello(hello({ schemas = {} })))
        for _, bad in ipairs({
            hello({ protocol = "11" }), hello({ protocol_min = true }), hello({ lw_version = 3 }),
            hello({ schemas = "x" }), hello({ schemas = { 1, 2 } }), hello({ client = {} }), hello({ role = 1 }),
            hello({ protocol = 0 / 0 }), hello({ protocol = math.huge }),
            hello({ lw_version = string.rep("x", protocol.PREAUTH_MAX) }),
            { kind = "ping" },
        }) do
            local ok, why = relay.valid_hello(bad)
            assert.is_false(ok, vim.inspect(bad):sub(1, 200))
            assert.is_string(why)
        end
    end)

    it("does not resume standard input once closed; an unreadable one counts as EOF", function()
        local calls = 0
        local inp = { read_start = function() calls = calls + 1; error("EBADF") end }
        local r = relay.new("/w", inp, {}, {})
        r.closed = true
        r:_resume_stdin()
        assert.equals(0, calls)
        assert.is_false(r.eof)
        r.closed = false
        r:_resume_stdin()
        assert.equals(1, calls)
        assert.is_true(r.eof)
    end)
end)

describe("relay buffering (§19.10 \"Relay buffering\")", function()
    it("stops reading the source past the high water mark and resumes below half", function()
        local a, b = loopback.pair()
        local paused, resumed = 0, 0
        local f = relay.flow(a, 1000, function() paused = paused + 1 end, function() resumed = resumed + 1 end)
        -- The reader is not reading: the writer's queue grows.
        for _ = 1, 3 do f.push(string.rep("x", 400)) end
        assert.equals(1, paused)
        assert.is_true(f.paused)
        assert.equals(0, resumed)
        -- One more chunk while paused does not pause twice.
        f.push(string.rep("y", 10))
        assert.equals(1, paused)
        -- The reader drains it: the source resumes once.
        local got = {}
        b:read_start(function(_, c) if c then got[#got + 1] = c end end)
        assert.is_true(vim.wait(5000, function() return resumed == 1 end, 5))
        assert.is_false(f.paused)
        assert.equals(1210, #table.concat(got))
    end)

    it("reports a failed write (the other side went away)", function()
        local a, b = loopback.pair()
        b:close()
        local errs = {}
        local f = relay.flow(a, 1000, function() end, function() end, function(e) errs[#errs + 1] = e end)
        f.push("abc")
        assert.is_true(vim.wait(2000, function() return #errs > 0 end, 5))
    end)
end)

describe("relay welcome (§19.8 \"Relay handshake\" step 4)", function()
    local ch = { protocol = 11, protocol_min = 10, lw_version = "0.1.44", schemas = { ["x/1"] = "abc" },
        session_generation = 5 }

    it("adds `daemon` and `via` to the daemon's welcome, keeping every field byte for byte", function()
        local payload = '{"kind":"welcome","objects":[],"header":{},"seq":3}'
        local frame = relay.welcome_frame(payload, ch, { pid = 42, start_time = "win:7", exe = "C:/lw.exe" })
        local len, body = frame:match("^(%d+)\n(.*)$")
        assert.equals(#body, tonumber(len))
        assert.truthy(body:find('"objects":[]', 1, true))
        assert.truthy(body:find('"header":{}', 1, true))
        local w = vim.json.decode(body)
        assert.equals("relay", w.via)
        assert.equals(3, w.seq)
        assert.same({ protocol = 11, protocol_min = 10, lw_version = "0.1.44", schemas = { ["x/1"] = "abc" },
            session_generation = 5, pid = 42, start_time = "win:7", exe = "C:/lw.exe" }, w.daemon)
    end)

    it("leaves start_time and exe out when the handle has none", function()
        local frame = relay.welcome_frame('{"kind":"welcome"}', ch, { pid = 42 })
        local w = vim.json.decode(frame:match("\n(.*)$"))
        assert.equals(42, w.daemon.pid)
        assert.is_nil(w.daemon.start_time)
        assert.is_nil(w.daemon.exe)
        assert.is_nil(connect.instance_id(w.daemon))
    end)
end)

describe("relay instances", function()
    it("matches a daemon by lock or live handle; exactly for --skip-instance", function()
        local st = { kind = "live", lock = { state = "live", pid = 5, start_time = "win:1" },
            handle = { pid = 5, start_time = "win:1" } }
        assert.is_true(relay.present(st, { pid = 5, start_time = "win:1" }, true))
        assert.is_false(relay.present(st, { pid = 5, start_time = "win:2" }, true))
        assert.is_false(relay.present(st, { pid = 5 }, true))
        -- Following a retiring daemon whose start time is unknown: by pid.
        assert.is_true(relay.present(st, { pid = 5 }))
        assert.is_false(relay.present({ kind = "none" }, { pid = 5, start_time = "win:1" }))
        assert.is_false(relay.present({ kind = "stale", lock = { state = "dead", pid = 5, start_time = "win:1" } },
            { pid = 5, start_time = "win:1" }))
    end)
end)

describe("the relay against an in-process daemon", function()
    local root, srv, saved
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = nil
        saved = { relay.HELLO_MS, relay.POLL_MS, relay.RETIRE_WAIT_MS, inspect.state }
        relay.POLL_MS = 100
    end)
    after_each(function()
        relay.HELLO_MS, relay.POLL_MS, relay.RETIRE_WAIT_MS, inspect.state = unpack(saved)
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)
    local function start_server(r)
        srv = server_mod.new(r or root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
        return srv
    end
    local function stop_server()
        srv:stop("test end", 0)
        assert.is_true(vim.wait(5000, function() return handle.read(root) == nil end, 20))
    end

    -- A relay on in-memory standard input/output. `on_frame(msg, h)` sees
    -- every frame the client reads.
    local function harness(o)
        o = o or {}
        local cin, rin = loopback.pair()
        local rout, cout = loopback.pair()
        local h = { frames = {}, notes = {}, out = {} }
        local dec = protocol.new_decoder(protocol.MAX_FRAME)
        cout:read_start(function(_, chunk)
            if not chunk then h.out_eof = true; return end
            h.out[#h.out + 1] = chunk
            for _, m in ipairs(dec:push(chunk) or {}) do
                h.frames[#h.frames + 1] = m
                if o.on_frame then o.on_frame(m, h) end
            end
        end)
        h.relay = relay.new(root, rin, rout, vim.tbl_extend("force", {
            note = function(l) h.notes[#h.notes + 1] = l end, step_ms = o.step_ms or STEP,
            launch = o.launch or function() error("must not launch") end,
        }, o.relay or {}))
        function h.send(msg) cin:write(protocol.encode(msg)) end
        function h.raw(s) cin:write(s) end
        function h.close() cin:close() end
        function h.run()
            local code = h.relay:run()
            h.relay:close()
            return code
        end
        function h.note() return table.concat(h.notes, "\n") end
        return h
    end
    -- Ping through the relay after welcome, then close standard input.
    local function ping_then_close(m, h)
        if m.kind == "welcome" then h.send({ kind = "ping", req_id = 1 })
        elseif m.req_id == 1 then h.pong = m; h.close() end
    end

    it("reads hello first, then connects, forwards welcome with daemon and via, relays both ways", function()
        start_server()
        local h = harness({ on_frame = ping_then_close })
        h.send(hello())
        assert.equals(0, h.run(), h.note())
        local w = h.frames[1]
        assert.equals("welcome", w.kind)
        assert.equals("relay", w.via)
        assert.equals(srv.pid, w.daemon.pid)
        assert.equals(srv.start_time, w.daemon.start_time)
        assert.equals(srv.identity, w.daemon.lw_version)
        assert.equals(srv.generation, w.daemon.session_generation)
        assert.is_table(w.header)
        assert.equals("ok", h.pong.kind)
        -- No challenge or auth reaches the client.
        for _, m in ipairs(h.frames) do assert.is_true(m.kind ~= "challenge" and m.kind ~= "auth") end
        -- Closing standard input closed only that connection.
        assert.is_true(vim.wait(5000, function() return srv:client_count() == 0 end, 20))
        assert.is_false(srv.stopped)
        assert.equals("", h.note())
    end)

    it("forwards the client's versions, client and role in its own hello", function()
        start_server()
        local seen
        local h = harness({ on_frame = function(m, hh)
            if m.kind == "welcome" then
                for c in pairs(srv.conns) do if c.authed then seen = c.peer end end
                hh.close()
            end
        end })
        h.send(hello({ client = "editor", role = "observer", lw_version = "9.9.9-test" }))
        assert.equals(0, h.run(), h.note())
        assert.equals("editor", seen.client)
        assert.equals("observer", seen.role)
        assert.equals("9.9.9-test", seen.lw_version)
    end)

    it("bytes the client pipelined after hello reach the daemon after welcome", function()
        start_server()
        local h = harness({ on_frame = function(m, hh) if m.req_id == 7 then hh.pong = m; hh.close() end end })
        h.raw(protocol.encode(hello()) .. protocol.encode({ kind = "ping", req_id = 7 }))
        assert.equals(0, h.run(), h.note())
        assert.equals("welcome", h.frames[1].kind)
        assert.equals("ok", h.pong.kind)
    end)

    it("the daemon closing the connection after welcome ends the relay with 0", function()
        start_server()
        local h = harness({ on_frame = function(m) if m.kind == "welcome" then srv:stop("test", 0) end end })
        h.send(hello())
        assert.equals(0, h.run(), h.note())
        assert.is_true(vim.wait(5000, function() return h.out_eof end, 20))
    end)

    it("15: no hello within the bound; nothing connected, launched or written", function()
        relay.HELLO_MS = 300
        start_server()
        local h = harness()
        assert.equals(15, h.run())
        assert.equals(0, srv:client_count())
        assert.equals(0, #h.out)
        assert.truthy(h.note():find("^lw: no hello"), h.note())
    end)

    it("15: anything other than hello first", function()
        start_server()
        local h = harness()
        h.send({ kind = "ping", req_id = 1 })
        assert.equals(15, h.run())
        assert.truthy(h.note():find("did not send hello first", 1, true), h.note())
        h = harness()
        h.raw("garbage-without-a-length-prefix")
        assert.equals(15, h.run())
        h = harness()
        h.close()
        assert.equals(15, h.run())
        assert.equals(0, #h.out)
    end)

    it("15: a hello whose forwarded fields are not of their types; nothing connected or written", function()
        start_server()
        for _, bad in ipairs({ hello({ protocol = "11" }), hello({ schemas = { 1 } }), hello({ client = 7 }) }) do
            local h = harness()
            h.send(bad)
            assert.equals(15, h.run(), h.note())
            assert.truthy(h.note():find("did not send hello first", 1, true), h.note())
            assert.equals(0, #h.out)
        end
        assert.equals(0, srv:client_count())
    end)

    it("15: more than HIGH_WATER pipelined before welcome, while standard input stays open", function()
        local saved_hw = relay.HIGH_WATER
        relay.HIGH_WATER = 1024
        local h = harness({ relay = { no_launch = true } })
        h.raw(protocol.encode(hello()) .. string.rep("x", 2048))
        local code = h.run()
        relay.HIGH_WATER = saved_hw
        assert.equals(15, code, h.note())
        assert.truthy(h.note():find("more than 1024 bytes before welcome", 1, true), h.note())
        assert.equals(0, #h.out)
        assert.is_nil(inspect.state(root).lock)
    end)

    it("no daemon: launches one, then connects", function()
        local calls = 0
        local h = harness({ on_frame = ping_then_close, launch = function()
            calls = calls + 1
            start_server()
            return true, inspect.state(root)
        end })
        h.send(hello())
        assert.equals(0, h.run(), h.note())
        assert.equals(1, calls)
        assert.equals("relay", h.frames[1].via)
    end)

    it("10: the launch failed", function()
        local h = harness({ launch = function() return false, "it exited with status 1" end })
        h.send(hello())
        assert.equals(10, h.run())
        assert.truthy(h.note():find("could not start the workspace daemon (it exited with status 1)", 1, true), h.note())
        assert.equals(0, #h.out)
    end)

    it("11: a hung daemon, a daemon still starting, an unreachable endpoint", function()
        start_server()
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        local h = harness()
        h.send(hello())
        assert.equals(11, h.run())
        assert.truthy(h.note():find("not responding", 1, true), h.note())
        local now = os.time()
        uv.fs_utime(dpaths.lock_path(root), now, now)
        stop_server()

        root = H.workspace()
        write_lock(root, require("loomworks.lock_record").new("daemon", { mode = "daemon" }))
        h = harness({ step_ms = 300 })
        h.send(hello())
        assert.equals(11, h.run())
        assert.truthy(h.note():find("still starting", 1, true), h.note())
        os.remove(dpaths.lock_path(root))

        root = H.workspace()
        start_server()
        local st = inspect.state(root)
        stop_server()
        inspect.state = function() return st end
        h = harness({ step_ms = 3000 })
        h.send(hello())
        assert.equals(11, h.run())
        assert.truthy(h.note():find("not responding", 1, true), h.note())
        assert.equals(0, #h.out)
    end)

    it("12: another data dir's key_id, a failed endpoint check, a failed server_proof — nothing sent", function()
        start_server()
        local real = inspect.state
        local function with_handle(f)
            inspect.state = function(r)
                local st = real(r)
                if st.handle then st.handle = vim.tbl_extend("force", st.handle, f(st.handle)) end
                return st
            end
        end
        with_handle(function() return { key_id = "0000000000000000" } end)
        local h = harness()
        h.send(hello())
        assert.equals(12, h.run())
        assert.truthy(h.note():find("another loomworks data dir", 1, true), h.note())
        assert.equals(0, srv:client_count())

        with_handle(function() return { endpoint = "planted-endpoint" } end)
        h = harness()
        h.send(hello())
        assert.equals(12, h.run())
        assert.truthy(h.note():find("endpoint", 1, true), h.note())

        -- The handle says nothing about its key; the daemon's proof does not
        -- verify against this lw's key.
        with_handle(function() return { key_id = vim.NIL } end)
        trust._set_key_path(H.tmp() .. "/other.key")
        h = harness()
        h.send(hello())
        assert.equals(12, h.run())
        assert.truthy(h.note():find("did not prove this lw's daemon key", 1, true), h.note())
        assert.equals(0, #h.out)
    end)

    it("13: the workspace daemon runs on another host", function()
        local rec = require("loomworks.lock_record").new("daemon", { mode = "daemon" })
        rec.host, rec.kind = "OTHERHOST", "daemon"
        write_lock(root, rec)
        local h = harness()
        h.send(hello())
        assert.equals(13, h.run())
        assert.truthy(h.note():find("OTHERHOST", 1, true), h.note())
        os.remove(dpaths.lock_path(root))
    end)

    it("an attached run's lock: waits without a bound, then connects or starts", function()
        write_lock(root, require("loomworks.lock_record").new("build", { mode = "attached" }))
        local launched = 0
        local h = harness({ on_frame = ping_then_close, launch = function()
            launched = launched + 1
            start_server()
            return true, inspect.state(root)
        end })
        h.send(hello())
        -- The run ends a while later (several polls).
        vim.defer_fn(function() os.remove(dpaths.lock_path(root)) end, 800)
        assert.equals(0, h.run(), h.note())
        assert.equals(1, launched)
        assert.equals("relay", h.frames[1].via)
    end)

    it("an attached run's lock: EOF while waiting is 0, nothing launched", function()
        write_lock(root, require("loomworks.lock_record").new("build", { mode = "attached" }))
        local h = harness()
        h.send(hello())
        vim.defer_fn(function() h.close() end, 500)
        assert.equals(0, h.run(), h.note())
        assert.equals(0, #h.out)
        os.remove(dpaths.lock_path(root))
    end)

    it("retiring: waits for the lock to go, then launches the successor", function()
        start_server()
        srv.busy = true
        srv.retiring = true
        local launched_after_stop
        local h = harness({ launch = function()
            launched_after_stop = srv.stopped
            return false, "test: no successor"
        end })
        h.send(hello())
        -- The retiring daemon becomes idle a while later and exits.
        vim.defer_fn(function() srv.busy = false; srv:_maybe_retire() end, 600)
        assert.equals(10, h.run())
        assert.is_true(launched_after_stop)
        -- The retiring welcome was never forwarded.
        assert.equals(0, #h.out)
    end)

    it("14: the retiring daemon still holds the lock after RELAY_RETIRE_WAIT", function()
        relay.RETIRE_WAIT_MS = 500
        start_server()
        srv.busy = true
        srv.retiring = true
        local h = harness()
        h.send(hello())
        assert.equals(14, h.run())
        assert.truthy(h.note():find("retiring", 1, true), h.note())
        assert.equals(0, #h.out)
        assert.is_true(vim.wait(5000, function() return srv:client_count() == 0 end, 20))
    end)

    describe("--no-launch", function()
        it("waits without launching; EOF while waiting is 0", function()
            local h = harness({ relay = { no_launch = true } })
            h.send(hello())
            vim.defer_fn(function() h.close() end, 600)
            assert.equals(0, h.run(), h.note())
            assert.equals(0, #h.out)
            assert.is_nil(inspect.state(root).lock)
        end)

        it("connects once a daemon appears", function()
            local h = harness({ relay = { no_launch = true }, on_frame = ping_then_close })
            h.send(hello())
            vim.defer_fn(function() start_server() end, 500)
            assert.equals(0, h.run(), h.note())
            assert.equals("relay", h.frames[1].via)
            assert.equals("ok", h.pong.kind)
        end)

        it("waits on a daemon still starting (no 11)", function()
            write_lock(root, require("loomworks.lock_record").new("daemon", { mode = "daemon" }))
            local h = harness({ step_ms = 300, relay = { no_launch = true } })
            h.send(hello())
            vim.defer_fn(function() h.close() end, 1000)
            assert.equals(0, h.run(), h.note())
            os.remove(dpaths.lock_path(root))
        end)

        it("16: the retiring daemon it waited on exited and none other is live", function()
            start_server()
            srv.busy = true
            srv.retiring = true
            local h = harness({ relay = { no_launch = true } })
            h.send(hello())
            vim.defer_fn(function() srv.busy = false; srv:_maybe_retire() end, 600)
            -- (A safety net: a relay that never exits would hang the file.)
            vim.defer_fn(function() h.close() end, 60000)
            assert.equals(16, h.run())
            assert.truthy(h.note():find("has exited", 1, true), h.note())
            assert.equals(0, #h.out)
        end)

        it("--skip-instance: never connects to the named daemon, and no 16 when it goes", function()
            start_server()
            local inst = { pid = srv.pid, start_time = srv.start_time }
            local h = harness({ relay = { no_launch = true, skip = inst } })
            h.send(hello())
            local max_clients = 0
            local t = uv.new_timer()
            t:start(20, 20, vim.schedule_wrap(function()
                if srv and not srv.stopped then max_clients = math.max(max_clients, srv:client_count()) end
            end))
            vim.defer_fn(function() srv:stop("test", 0) end, 600)
            vim.defer_fn(function() h.close() end, 1400)
            assert.equals(0, h.run(), h.note())
            t:stop(); t:close()
            assert.equals(0, max_clients)
            assert.equals(0, #h.out)
        end)

        it("--skip-instance naming another instance does not skip the live daemon", function()
            start_server()
            local h = harness({ relay = { no_launch = true, skip = { pid = srv.pid, start_time = "win:0" } },
                on_frame = ping_then_close })
            h.send(hello())
            assert.equals(0, h.run(), h.note())
            assert.equals("relay", h.frames[1].via)
        end)
    end)
end)

describe("the relay as a real process", function()
    local env
    before_each(function() env = H.env() end)
    after_each(function() H.cleanup() end)

    local function start(root, extra_args, extra_env)
        local args = { "daemon", "run", "--root", root, "--stdio" }
        for _, a in ipairs(extra_args or {}) do args[#args + 1] = a end
        local e = env
        if extra_env then e = vim.deepcopy(env); for k, v in pairs(extra_env) do e.vars[k] = v end end
        return H.lw_start(args, { env = e, cwd = root, stdin = true })
    end
    -- The frames on a process's standard output so far.
    local function frames(p)
        local dec = protocol.new_decoder(protocol.MAX_FRAME)
        return dec:push(p.stdout()) or {}
    end
    local function first_frame(p, ms)
        local f
        vim.wait(ms or 120000, function()
            f = frames(p)[1]
            return f ~= nil or p.code ~= nil
        end, 20)
        return f
    end

    it("usage errors are status 2, nothing on standard output", function()
        local root = H.workspace()
        for _, a in ipairs({
            { "daemon", "run", "--root", root, "--stdio", "--private" },
            { "daemon", "run", "--root", root, "--no-launch" },
            { "daemon", "run", "--root", root, "--stdio", "--skip-instance", "1:win:1" },
            { "daemon", "run", "--root", root, "--stdio", "--no-launch", "--skip-instance", "nope" },
        }) do
            local r = H.lw(a, { env = env, cwd = root })
            assert.equals(2, r.code, table.concat(a, " ") .. "\n" .. r.stderr)
            assert.equals("", r.stdout)
            assert.truthy(r.stderr:find("^lw: "), r.stderr)
        end
        local r = H.lw({ "daemon", "run", "--root", root, "--stdio", "--private" }, { env = env, cwd = root })
        assert.truthy(r.stderr:find("lw: --private is for tests only", 1, true), r.stderr)
    end)

    it("--private with the gate: the attached runtime on standard I/O (welcome without via)", function()
        local root = H.workspace()
        local p = start(root, { "--private" }, { LOOMWORKS_TEST_PRIVATE_STDIO = "1" })
        p.write(protocol.encode(hello()))
        local w = first_frame(p)
        assert.is_table(w, p.stderr())
        assert.equals("welcome", w.kind)
        assert.is_nil(w.via)
        assert.is_nil(w.daemon)
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, p.code, p.stderr())
    end)

    it("15: no hello within about 5 s", function()
        local root = H.workspace()
        local p = start(root)
        assert.is_true(p.wait(120000), p.stderr())
        assert.equals(15, p.code, p.stderr())
        assert.equals("", p.stdout())
        assert.truthy(p.stderr():find("lw: no hello", 1, true), p.stderr())
        -- Nothing was started.
        assert.is_nil(inspect.state(root).lock)
        p.close_stdin()
    end)

    it("starts the shared daemon, relays, and leaves it running when the client goes", function()
        local root = H.workspace()
        local p = start(root)
        p.write(protocol.encode(hello()))
        local w = first_frame(p)
        H.track_root(root)
        assert.is_table(w, p.stderr())
        assert.equals("welcome", w.kind)
        assert.equals("relay", w.via)
        local lk = require("loomworks.daemon.rlock").read(root)
        assert.equals(lk.pid, w.daemon.pid)
        assert.is_true(connect.same_instance(w.daemon, lk))
        p.write(protocol.encode({ kind = "ping", req_id = 1 }))
        assert.is_true(vim.wait(60000, function() return frames(p)[2] ~= nil end, 20), p.stderr())
        assert.equals("ok", frames(p)[2].kind)
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, p.code, p.stderr())
        -- The daemon keeps running (§19.10 "Closing a connection").
        assert.equals("live", inspect.state(root).kind)
        assert.equals(0, H.stop_daemon(root, env).code)
    end)

    it("--no-launch waits without launching, connects once a daemon is started, 0 on EOF", function()
        local root = H.workspace()
        local p = start(root, { "--no-launch" })
        p.write(protocol.encode(hello()))
        vim.wait(3000, function() return p.code ~= nil end, 50)
        assert.is_nil(p.code, p.stderr())
        assert.is_nil(inspect.state(root).lock)
        assert.is_nil(handle.read(root))
        local r = H.lw({ "daemon", "restart" }, { env = env, cwd = root })
        H.track_root(root)
        assert.equals(0, r.code, r.stderr)
        local w = first_frame(p)
        assert.is_table(w, p.stderr())
        assert.equals("relay", w.via)
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, p.code, p.stderr())
        assert.equals(0, H.stop_daemon(root, env).code)
    end)

    it("--skip-instance: the named daemon is never connected to; the relay keeps waiting", function()
        local root = H.workspace()
        local r = H.lw({ "daemon", "restart" }, { env = env, cwd = root })
        local lk = H.track_root(root)
        assert.equals(0, r.code, r.stderr)
        local p = start(root, { "--no-launch", "--skip-instance", connect.instance_id(lk) })
        p.write(protocol.encode(hello()))
        vim.wait(5000, function() return p.code ~= nil end, 50)
        assert.is_nil(p.code, p.stderr())
        assert.equals("", p.stdout())
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, p.code, p.stderr())
        assert.equals(0, H.stop_daemon(root, env).code)
    end)
end)

describe("daemon processes", function()
    it("none was left running by any test of this file", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a daemon process survived the cleanup")
    end)
end)
