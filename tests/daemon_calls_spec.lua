-- The CLI's requests as interface calls (spec §19.20, step 5g.2 part B,
-- loomworks.daemon.calls): over transport 11 the protocol-10 request kinds
-- go as their interface methods and their replies come back in the
-- protocol-10 shape; a connection of transport 10 still sends the kinds.
-- An attached server with the build service, loopback client sessions.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local calls = require("loomworks.daemon.calls")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 60000

local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

describe("calls.frame", function()
    it("maps each request kind to its interface method, entities to references by key", function()
        local f = assert(calls.frame({ kind = "build", args = { profile = "dev", targets = { "a" } },
            interactive = false, command = "lw build", env = { A = "1" } }))
        assert.same({ "call", "/build", "loomworks.Build", 1, "build" }, { f.kind, f.object, f.iface, f.v, f.method })
        assert.same({ key = "dev" }, f.args.profile)
        assert.same({ "a" }, f.args.targets)
        assert.equals(false, f.args.interactive)
        assert.equals("lw build", f.args.command)
        assert.same({ A = "1" }, f.env)
        f = assert(calls.frame({ kind = "prepare_run", args = { project = "app", target = "t" } }))
        assert.same({ "/launch", "prepare_run" }, { f.object, f.method })
        assert.same({ key = "app" }, f.args.project)
        assert.equals("run", assert(calls.frame({ kind = "test", args = {} })).method)
        assert.equals("clean", assert(calls.frame({ kind = "clean", args = {} })).method)
        assert.equals("reset", assert(calls.frame({ kind = "reset", args = { all = true } })).method)
        assert.equals("get", assert(calls.frame({ kind = "snapshot", scope = "all" })).method)
        assert.equals("list", assert(calls.frame({ kind = "query", name = "tools" })).method)
        f = assert(calls.frame({ kind = "query", name = "profile_cache", args = { profile = "dev", project = "app" } }))
        assert.same({ profile = { key = "dev" }, project = { key = "app" } }, f.args)
        assert.is_nil(calls.frame({ kind = "ping" }))
        assert.is_nil(calls.frame({ kind = "query", name = "no_such_query" }))
    end)
end)

describe("calls error policy (§19.20)", function()
    it("declares mutates as the methods' schemas do", function()
        local set = require("loomworks.proto.documents").set()
        for kind, op in pairs(calls.OPERATIONS) do
            local doc = assert(set:interface(op[2], 1), op[2])
            assert.equals(doc.methods[op[3]].mutates == true, op.mutates == true, kind)
        end
        for name, q in pairs(calls.QUERIES) do
            local doc = assert(set:interface(q[2], 1), q[2])
            assert.is_false(doc.methods[q[3]].mutates, name)
        end
    end)

    it("maps each transport error code to retry, decline or fail", function()
        for _, code in ipairs({ "unknown_object", "unknown_interface", "unknown_method", "unsupported_version" }) do
            assert.equals("retry_v0", calls.on_error(code, true), code)
            assert.equals("retry_v0", calls.on_error(code, false), code)
        end
        for _, code in ipairs({ "invalid_args", "same_build_required", "stopping", "retiring" }) do
            assert.equals("declined", calls.on_error(code, true), code)
            assert.equals("declined", calls.on_error(code, false), code)
        end
        for _, code in ipairs({ "internal", "not_loaded", "forbidden", "some_future_code" }) do
            assert.equals("failed", calls.on_error(code, true), code)
            assert.equals("declined", calls.on_error(code, false), code)
        end
    end)

    --- A transport-11 connection whose interface calls fail with `code`;
    --- its protocol-10 requests are answered `accepted`.
    local function failing_conn(code)
        local conn = { transport = 11, sent = {} }
        function conn.request(_, msg, cb)
            conn.sent[#conn.sent + 1] = msg.kind
            if msg.kind == "call" then return cb(nil, { code = code, message = "boom" }) end
            cb({ kind = "ok", outcome = "accepted", task_id = 3 })
        end
        return conn
    end

    local function ask(conn, msg)
        local got
        calls.request(conn, msg, function(r, e) got = { r, e } end)
        return got[1], got[2]
    end

    it("sends the protocol-10 request when the daemon does not serve the interface", function()
        for _, code in ipairs({ "unknown_object", "unknown_interface", "unknown_method", "unsupported_version" }) do
            local conn = failing_conn(code)
            local r = ask(conn, { kind = "build", args = { profile = "dev" } })
            assert.equals("accepted", r.outcome, code)
            assert.same({ "call", "build" }, conn.sent, code)
        end
    end)

    it("declines (runs in-process) when the call was not processed", function()
        for _, code in ipairs({ "invalid_args", "same_build_required", "stopping", "retiring" }) do
            local conn = failing_conn(code)
            local r = ask(conn, { kind = "test", args = {} })
            assert.equals("declined", r.outcome, code)
            assert.truthy(r.reason:find(code, 1, true), r.reason)
            assert.same({ "call" }, conn.sent, code)
        end
    end)

    it("fails a mutating call on internal or an unknown code, never running it again", function()
        for _, code in ipairs({ "internal", "some_future_code" }) do
            for _, kind in ipairs({ "build", "clean", "reset", "test", "prepare_run" }) do
                local conn = failing_conn(code)
                local r = ask(conn, { kind = kind, args = {} })
                assert.equals("refused", r.outcome, kind)
                assert.equals(1, r.exit_code)
                assert.truthy(r.message:find(code, 1, true), r.message)
                assert.same({ "call" }, conn.sent, kind)
            end
        end
    end)

    it("declines a non-mutating call on internal", function()
        local conn = failing_conn("internal")
        local r = ask(conn, { kind = "snapshot", scope = "config" })
        assert.equals("declined", r.outcome)
        conn = failing_conn("internal")
        r = ask(conn, { kind = "query", name = "tools", args = {} })
        assert.equals("declined", r.outcome)
        assert.same({ "call" }, conn.sent)
    end)
end)

describe("the CLI's requests over transport 11 (§19.20)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        local signed = assert(trust.sign("user", trust.encode({ _meta = { version = 2 }, active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } } })))
        write(root .. "/.nvim/loomworks.user.json", signed)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    --- A loopback session recording the kind of every frame it sends.
    local function session(events)
        local conn = assert(client.loopback_session(srv, { on_message = function(m) events[#events + 1] = m end }))
        conn.sent = {}
        local request = conn.request
        function conn.request(self, msg, cb)
            self.sent[#self.sent + 1] = msg.kind
            return request(self, msg, cb)
        end
        return conn
    end

    it("go as interface calls and answer in the protocol-10 shape, the task done with its result", function()
        local events = {}
        local conn = session(events)
        assert.equals(11, conn.transport)
        local snap = assert(calls.request_sync(conn, { kind = "snapshot", scope = "config", env = envscope.capture() }))
        assert.equals("ok", snap.outcome)
        assert.equals("config", snap.scope)
        assert.is_string(snap.index.profiles.dev)
        local q = assert(calls.request_sync(conn, { kind = "query", name = "tools", args = {}, env = envscope.capture() }))
        assert.equals("ok", q.outcome)
        assert.is_table(q.result.tools)
        q = assert(calls.request_sync(conn, { kind = "query", name = "profile_cache",
            args = { profile = "dev", project = "nope" }, env = envscope.capture() }))
        assert.equals("refused", q.outcome)
        local r = assert(calls.request_sync(conn, { kind = "build", args = { profile = "dev" }, interactive = false,
            command = "lw build", env = envscope.capture() }))
        assert.equals("accepted", r.outcome, vim.inspect(r))
        assert.equals("dev", r.profile_key)
        local done
        assert.is_true(vim.wait(60000, function()
            for _, m in ipairs(events) do
                if m.kind == "task" and m.task_id == r.task_id and m.phase == "done" then done = m end
            end
            return done ~= nil
        end, 10))
        assert.equals(0, done.exit_code)
        assert.same({ exit_code = 0 }, done.result)
        assert.same({ "call", "call", "call", "call" }, conn.sent)
        -- An error of the call is a declined reply: the CLI runs in-process.
        r = assert(calls.request_sync(conn, { kind = "build", args = { bogus = true }, env = envscope.capture() }))
        assert.equals("declined", r.outcome)
        assert.truthy(r.reason:find("invalid_args", 1, true), r.reason)
        conn:close()
    end)

    it("a daemon without the interface (step 5g.1) gets the protocol-10 request", function()
        srv.interfaces:unmount("/build")
        local events = {}
        local conn = session(events)
        assert.equals(11, conn.transport)
        local r = assert(calls.request_sync(conn, { kind = "build", args = { profile = "dev" }, interactive = false,
            command = "lw build", env = envscope.capture() }))
        assert.equals("accepted", r.outcome, vim.inspect(r))
        assert.same({ "call", "build" }, conn.sent)
        assert.is_true(vim.wait(60000, function()
            for _, m in ipairs(events) do
                if m.kind == "task" and m.task_id == r.task_id and m.phase == "done" then return true end
            end
            return false
        end, 10))
        conn:close()
    end)

    it("a connection of transport 10 sends the protocol-10 kinds, answered alike", function()
        local events = {}
        local conn = session(events)
        conn.transport = 10
        local snap = assert(calls.request_sync(conn, { kind = "snapshot", scope = "config", env = envscope.capture() }))
        assert.equals("ok", snap.outcome)
        assert.is_string(snap.index.profiles.dev)
        local q = assert(calls.request_sync(conn, { kind = "query", name = "tools", args = {}, env = envscope.capture() }))
        assert.is_table(q.result.tools)
        local r = assert(calls.request_sync(conn, { kind = "build", args = { profile = "dev" }, interactive = false,
            command = "lw build", env = envscope.capture() }))
        assert.equals("accepted", r.outcome)
        local done
        assert.is_true(vim.wait(60000, function()
            for _, m in ipairs(events) do
                if m.kind == "task" and m.task_id == r.task_id and m.phase == "done" then done = m end
            end
            return done ~= nil
        end, 10))
        assert.equals(0, done.exit_code)
        -- (A protocol-10 task's done frame carries no interface result.)
        assert.is_nil(done.result)
        assert.same({ "snapshot", "query", "build" }, conn.sent)
        conn:close()
    end)
end)
