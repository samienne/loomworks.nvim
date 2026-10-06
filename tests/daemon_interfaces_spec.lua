-- Transport 11 and the root object (spec §19.8, §19.9, §19.20; step 5g.1):
-- the transport range, `welcome.objects`, the envelope, `loomworks.Root/1`
-- (describe, schema, subscribe, unsubscribe, objects_changed, retiring) over
-- the real socket and the loopback, and the v0 aliases of the protocol-10
-- request kinds through the dispatch table.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local version = require("loomworks.daemon.version")
local interfaces = require("loomworks.daemon.interfaces")
local documents = require("loomworks.proto.documents")
local envelope = require("loomworks.proto.envelope")
local auth = require("loomworks.daemon.auth")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local ROOT, RIF = "/", "loomworks.Root"

--- A test interface: one method, a signal with an initial state, another
--- without, and subscription args (`subscribe_args`).
local function test_doc(extra)
    local doc = {
        interface = "lwtest.Echo", version = 1, status = "draft",
        methods = {
            echo = {
                params = { type = "object", required = { "text" }, properties = { text = { type = "string" } } },
                result = { type = "object", required = { "text" }, properties = { text = { type = "string" } } },
            },
        },
        signals = {
            ticked = {
                args = { type = "object", required = { "n" }, properties = { n = { type = "integer" } } },
                initial = true,
            },
            tocked = {
                args = { type = "object", required = { "n" }, properties = { n = { type = "integer" } } },
            },
        },
        subscribe_args = { type = "object", additionalProperties = false, properties = { only = { type = "integer" } } },
    }
    for k, v in pairs(extra or {}) do doc[k] = v end
    return doc
end

local function echo_impl(over)
    local impl = {
        doc = test_doc(),
        methods = { echo = function(_, args) return { text = args.text } end },
        initial = function() return { n = 0 } end,
    }
    for k, v in pairs(over or {}) do impl[k] = v end
    return impl
end

--- Collects the broadcasts a session receives.
local function inbox()
    local box = { msgs = {} }
    function box.on_message(m) box.msgs[#box.msgs + 1] = m end
    function box.signals(name)
        local out = {}
        for _, m in ipairs(box.msgs) do
            if m.kind == "signal" and (not name or m.name == name) then out[#out + 1] = m end
        end
        return out
    end
    return box
end

local function read_doc(rel)
    local f = assert(io.open(documents.dir() .. "/" .. rel, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

describe("transport range (§19.8, §19.9)", function()
    it("is 11 with protocol_min 10, and negotiates the highest common version", function()
        assert.equals(11, version.PROTOCOL)
        assert.equals(10, version.PROTOCOL_MIN)
        assert.equals(11, version.negotiate(11, 10))
        assert.equals(11, version.negotiate(12, 9))
        assert.equals(10, version.negotiate(10))       -- a protocol-10 client states no minimum
        assert.equals(11, version.negotiate(11))
        assert.is_nil(version.negotiate(9))
        assert.is_nil(version.negotiate(13, 12))
        assert.is_nil(version.negotiate(nil))
    end)

    it("lets an editor observe a daemon whose range overlaps, not one whose range does not", function()
        local me = version.schemas()
        assert.is_true((version.observer_compatible({ protocol = 10, schemas = me })))
        assert.is_true((version.observer_compatible({ protocol = 12, protocol_min = 11, schemas = me })))
        local ok, what = version.observer_compatible({ protocol = 13, protocol_min = 12, schemas = me })
        assert.is_false(ok)
        assert.equals("protocol", what)
    end)

    it("the envelope treats an unknown error code as internal unless the interface declares it", function()
        assert.equals("invalid_args", envelope.code_of({ code = "invalid_args" }))
        assert.equals("internal", envelope.code_of({ code = "brand_new" }))
        assert.equals("brand_new", envelope.code_of({ code = "brand_new" }, { brand_new = {} }))
        assert.equals("internal", envelope.code_of("a string"))
    end)
end)

describe("root object over the socket (§19.20)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("announces the range in the challenge and the objects in welcome", function()
        local conn = assert(client.session(srv.address))
        assert.equals(11, conn.challenge.protocol)
        assert.equals(10, conn.challenge.protocol_min)
        local objs = conn.welcome.objects
        assert.equals(1, #objs)
        assert.equals("/", objs[1].path)
        assert.equals("core", objs[1].owner)
        assert.equals(RIF, objs[1].interfaces[1].name)
        assert.same({ 1 }, objs[1].interfaces[1].versions)
        assert.is_nil(objs[1].interfaces[1].schema_digest)
        -- The header's session fields are untouched beside it.
        assert.equals(srv.pid, conn.welcome.header.pid)
        local sc
        for c in pairs(srv.conns) do sc = c end
        assert.equals(11, sc.transport)
        conn:close()
    end)

    it("describe: binary, transport range, generation, objects with digests, root methods", function()
        local conn = assert(client.session(srv.address))
        local d, err = client.call_sync(conn, ROOT, RIF, 1, "describe", {})
        assert.is_nil(err)
        assert.equals(srv.identity, d.binary.lw_version)
        assert.equals("lua", d.binary.impl)
        assert.is_true(d.binary.dev) -- a source tree
        assert.same({ min = 10, max = 11 }, d.transport)
        assert.equals(srv.generation, d.session_generation)
        assert.same({ "describe", "schema", "subscribe", "unsubscribe" }, d.root_methods)
        local info = d.objects[1].interfaces[1]
        assert.equals(vim.fn.sha256(read_doc("interfaces/loomworks/Root.1.json")), info.schema_digest["1"])
        -- The result is valid against the Root schema.
        local set = documents.set()
        assert.is_true(set:validate("interfaces/loomworks/Root.1.json", "/methods/describe/result", d))
        conn:close()
    end)

    it("schema: serves Root/1 and the types-only Common/1; unknown name and version are typed errors", function()
        local conn = assert(client.session(srv.address))
        local doc = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 1 }))
        assert.same(vim.json.decode(read_doc("interfaces/loomworks/Root.1.json")), doc)
        local common = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = "loomworks.Common", v = 1 }))
        assert.equals("loomworks.Common", common.interface)
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = "loomworks.Nope", v = 1 })
        assert.equals("unknown_interface", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 2 })
        assert.equals("unsupported_version", e.code)
        assert.same({ 1 }, e.data.versions)
        conn:close()
    end)

    it("routing errors: unknown object / interface / version / method, invalid args, malformed call", function()
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, "/nowhere", RIF, 1, "describe", {})
        assert.equals("unknown_object", e.code)
        _, e = client.call_sync(conn, ROOT, "loomworks.Build", 1, "build", {})
        assert.equals("unknown_interface", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 3, "describe", {})
        assert.equals("unsupported_version", e.code)
        assert.same({ 1 }, e.data.versions)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "explode", {})
        assert.equals("unknown_method", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { v = 1 })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("missing required property 'iface'", 1, true), e.message)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = "1" })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("/v", 1, true), e.message)
        local reply, rerr = client.request(conn, { kind = "call", object = ROOT, iface = RIF, method = "describe" })
        assert.is_nil(reply)
        assert.equals("invalid_args", rerr.code)
        conn:close()
    end)

    it("subscribe: initial state, stamped signals with seq, filters, unsubscribe, dropped on close", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        local box = inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        local other = assert(client.session(srv.address))
        local r = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "ticked" }, args = { only = 2 } }))
        assert.is_number(r.sub_id)
        assert.equals(0, r.seq)
        assert.same({ n = 0 }, r.initial)
        local echo = assert(client.call_sync(other, "/echo", "lwtest.Echo", 1, "echo", { text = "hi" }))
        assert.equals("hi", echo.text)
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 1 }))
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 2 },
            function(a) return a.only == 3 end))
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 1 end, 10))
        local s = box.signals("ticked")[1]
        assert.equals(r.sub_id, s.sub_id)
        assert.equals("/echo", s.object)
        assert.equals(1, s.v)
        assert.equals(r.seq + 1, s.seq)
        -- Signals this connection is never sent use up no seq: emitted to
        -- nobody, refused by the filter, a signal it did not subscribe to,
        -- the other connection's.
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 9 },
            function(a) return a.only == 7 end))
        local r2 = assert(client.call_sync(other, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "tocked" } }))
        assert.equals(0, r2.seq)
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "tocked", { n = 1 }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "tocked", { n = 2 }))
        assert(client.call_sync(other, ROOT, RIF, 1, "unsubscribe", { sub_id = r2.sub_id }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 10 }))
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 2 end, 10))
        assert.equals(s.seq + 1, box.signals("ticked")[2].seq)
        -- A later subscription of the same connection starts from the last
        -- seq it was sent on that object.
        local r3 = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "tocked" } }))
        assert.equals(s.seq + 1, r3.seq)
        assert(client.call_sync(conn, ROOT, RIF, 1, "unsubscribe", { sub_id = r3.sub_id }))
        -- Subscription args are checked against subscribe_args.
        local _, ae = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, args = { only = "x" } })
        assert.equals("invalid_args", ae.code)
        assert.truthy(ae.message:find("/args/only", 1, true), ae.message)
        -- An unknown signal name is invalid_args.
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "nope" } })
        assert.equals("invalid_args", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 2 })
        assert.equals("unsupported_version", e.code)
        -- Another connection cannot drop it; its owner can.
        assert(client.call_sync(other, ROOT, RIF, 1, "unsubscribe", { sub_id = r.sub_id }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 3 }))
        local u = assert(client.call_sync(conn, ROOT, RIF, 1, "unsubscribe", { sub_id = r.sub_id }))
        assert.same({}, u)
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 4 }))
        -- Closing drops a connection's subscriptions.
        assert(client.call_sync(other, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        other:close()
        assert.is_true(vim.wait(5000, function() return next(srv.interfaces.subs) == nil end, 10))
        conn:close()
    end)

    it("an interface without subscribe_args refuses subscription args", function()
        local doc = test_doc()
        doc.subscribe_args = nil
        assert(srv.interfaces:mount("/plain", "core", "lwtest.Echo", 1, echo_impl({ doc = doc })))
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/plain", iface = "lwtest.Echo", v = 1, args = { only = 2 } })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("takes no subscription args", 1, true), e.message)
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/plain", iface = "lwtest.Echo", v = 1 }))
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/plain", iface = "lwtest.Echo", v = 1, args = vim.empty_dict() }))
        conn:close()
    end)

    it("an empty result goes out as its schema types it: [] for an array, {} for an object", function()
        local doc = test_doc()
        doc.methods.list = { params = { type = "object" }, result = { type = "array", items = { type = "string" } } }
        doc.methods.nested = { params = { type = "object" }, result = { type = "object", properties = {
            items = { type = "array" }, meta = { type = "object" } } } }
        assert(srv.interfaces:mount("/lists", "core", "lwtest.Echo", 1, echo_impl({ doc = doc, methods = {
            echo = function(_, a) return { text = a.text } end,
            list = function() return {} end,
            nested = function() return { items = {}, meta = {} } end,
        } })))
        local conn = assert(client.session(srv.address))
        local l, e = client.call_sync(conn, "/lists", "lwtest.Echo", 1, "list", {})
        assert.is_nil(e)
        assert.same({}, l)
        assert.is_nil(getmetatable(l)) -- decoded from [], not {}
        local nres = assert(client.call_sync(conn, "/lists", "lwtest.Echo", 1, "nested", {}))
        assert.is_nil(getmetatable(nres.items))
        assert.equals(vim._empty_dict_mt, getmetatable(nres.meta))
        conn:close()
    end)

    it("describe lists versions in numeric order", function()
        for _, v in ipairs({ 10, 9 }) do
            local doc = test_doc({ version = v })
            assert(srv.interfaces:mount("/multi", "core", "lwtest.Echo", v, echo_impl({ doc = doc })))
        end
        local conn = assert(client.session(srv.address))
        local d = assert(client.call_sync(conn, ROOT, RIF, 1, "describe", {}))
        local found
        for _, o in ipairs(d.objects) do if o.path == "/multi" then found = o end end
        assert.same({ 9, 10 }, found.interfaces[1].versions)
        local _, e = client.call_sync(conn, "/multi", "lwtest.Echo", 3, "echo", { text = "x" })
        assert.same({ 9, 10 }, e.data.versions)
        conn:close()
    end)

    it("stop drops every connection's subscriptions", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        local conn = assert(client.session(srv.address))
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        assert.is_not_nil(next(srv.interfaces.subs))
        srv:stop("test", 0)
        assert.is_nil(next(srv.interfaces.subs))
        conn:close()
    end)

    it("the client records the agreed transport and refuses an interface call below 11 at once", function()
        local conn = assert(client.session(srv.address))
        assert.equals(11, conn.transport)
        conn.transport = 10 -- as against a daemon of protocol 10
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "describe", {})
        assert.equals(client.ERR_TRANSPORT, e.code)
        assert.truthy(e.message:find("need 11", 1, true), e.message)
        conn:close()
    end)

    it("objects_changed reaches every transport-11 connection on mount and unmount; welcome lists the object", function()
        local box = inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 1 end, 10))
        local s = box.signals("objects_changed")[1]
        assert.equals("/", s.object)
        assert.equals(RIF, s.iface)
        assert.same({ "/echo" }, s.args.added)
        local late = assert(client.session(srv.address))
        assert.equals(2, #late.welcome.objects)
        assert.equals("/echo", late.welcome.objects[2].path)
        srv.interfaces:unmount("/echo")
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 2 end, 10))
        assert.same({ "/echo" }, box.signals("objects_changed")[2].args.removed)
        late:close()
        conn:close()
    end)

    it("refuses an interface whose methods and handlers disagree", function()
        local ok, err = srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({ methods = {} }))
        assert.is_nil(ok)
        assert.truthy(err:find("no handler for method echo", 1, true))
        ok, err = srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() end, extra = function() end } }))
        assert.is_nil(ok)
        assert.truthy(err:find("handler extra has no method", 1, true))
        assert.is_nil(srv.interfaces.objects["/echo"])
    end)

    it("same_build interfaces need the daemon's lw_version", function()
        assert(srv.interfaces:mount("/internal", "core", "lwtest.Echo", 1, echo_impl({ same_build = true })))
        local conn = assert(client.session(srv.address))
        assert(client.call_sync(conn, "/internal", "lwtest.Echo", 1, "echo", { text = "x" }))
        for c in pairs(srv.conns) do c.peer.lw_version = "0.0.1" end
        local _, e = client.call_sync(conn, "/internal", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("same_build_required", e.code)
        conn:close()
    end)

    it("a development build fails a result that does not match its schema", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() return { text = 42 } end } })))
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, "/echo", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("internal", e.code)
        assert.truthy(e.message:find("does not match its schema", 1, true), e.message)
        -- A handler error is internal, never a crash.
        assert(srv.interfaces:mount("/boom", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() error("boom") end } })))
        _, e = client.call_sync(conn, "/boom", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("internal", e.code)
        assert(client.request(conn, { kind = "ping" }))
        conn:close()
    end)

    it("retire sends the root's retiring signal to transport-11 connections, v0 retiring to observers", function()
        local box, obox = inbox(), inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        local obs = assert(client.session(srv.address, { on_message = obox.on_message, role = "observer" }))
        assert(client.request(conn, { kind = "retire" }))
        assert.is_true(vim.wait(5000, function() return #box.signals("retiring") == 1 end, 10))
        assert.is_true(vim.wait(5000, function()
            for _, m in ipairs(obox.msgs) do if m.kind == "retiring" then return true end end
            return false
        end, 10))
        obs:close()
        conn:close()
    end)

    it("a protocol-10 client is served at 10: v0 requests unchanged, no envelope signals", function()
        -- A hand-rolled protocol-10 handshake (no protocol_min).
        local key = assert(auth.key())
        local nc = assert(auth.nonce())
        local pipe = uv.new_pipe(false)
        local dec = protocol.new_decoder(protocol.MAX_FRAME)
        local got = {}
        pipe:connect(srv.address, function(cerr)
            assert(not cerr)
            pipe:read_start(function(_, chunk)
                if not chunk then return end
                for _, m in ipairs(dec:push(chunk) or {}) do
                    got[#got + 1] = m
                    if m.kind == "challenge" then
                        pipe:write(protocol.encode({ kind = "auth",
                            client_proof = auth.client_proof(key, srv.address, nc, m.server_nonce) }))
                    end
                end
            end)
            pipe:write(protocol.encode({ kind = "hello", protocol = 10, lw_version = "0.1.43",
                schemas = version.schemas(), client = "cli", nonce = nc }))
        end)
        local function has(kind)
            for _, m in ipairs(got) do if m.kind == kind then return m end end
        end
        assert.is_true(vim.wait(5000, function() return has("welcome") ~= nil end, 10))
        local sc
        for c in pairs(srv.conns) do sc = c end
        assert.equals(10, sc.transport)
        pipe:write(protocol.encode({ kind = "ping", req_id = 1 }))
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        pipe:write(protocol.encode({ kind = "build", req_id = 2 }))
        assert.is_true(vim.wait(5000, function() return #got >= 4 end, 10))
        assert.equals("ok", got[3].kind)
        assert.equals(1, got[3].req_id)
        assert.equals("error", got[4].kind)
        assert.equals("unknown request kind: build", got[4].error)
        for _, m in ipairs(got) do assert.not_equals("signal", m.kind) end
        pipe:close()
    end)
end)

describe("root object over the loopback (§19.1, §19.20)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { tick_ms = 100 })
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("welcomes with the objects and serves describe, schema and subscribe", function()
        local box = inbox()
        local conn = assert(client.loopback_session(srv, { on_message = box.on_message }))
        assert.equals(10, conn.challenge.protocol_min)
        assert.equals("/", conn.welcome.objects[1].path)
        local d = assert(client.call_sync(conn, ROOT, RIF, 1, "describe", {}))
        assert.same({ min = 10, max = 11 }, d.transport)
        local doc = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 1 }))
        assert.equals(RIF, doc.interface)
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 1 end, 10))
        local r = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 5 })
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 1 end, 10))
        assert.equals(r.sub_id, box.signals("ticked")[1].sub_id)
        conn:close()
    end)
end)

describe("v0 aliases through the dispatch table (§19.8)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { tick_ms = 100 })
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("names every protocol-10 request kind, each served by the build service's handler", function()
        local want = { build = "on_build", test = "on_test", prepare_run = "on_run", clean = "on_clean",
            reset = "on_reset", snapshot = "on_snapshot", query = "on_query" }
        for kind, method in pairs(want) do
            assert.equals(method, server_mod.DISPATCH[kind].v0, kind)
        end
        for _, kind in ipairs({ "ping", "status", "stop", "retire", "call" }) do
            assert.is_function(server_mod.DISPATCH[kind].control, kind)
        end
    end)

    it("an old-style request gets the same reply as before", function()
        local calls = {}
        local svc = {}
        for _, m in ipairs({ "on_build", "on_test", "on_run", "on_clean", "on_reset", "on_snapshot", "on_query" }) do
            svc[m] = function(_, conn, msg)
                calls[#calls + 1] = m
                srv:_send(conn, { kind = "ok", req_id = msg.req_id, outcome = "declined", reason = m })
            end
        end
        function svc.on_conn_closed() end
        function svc.on_stopping() end
        srv.service = svc
        local conn = assert(client.loopback_session(srv))
        for _, kind in ipairs({ "build", "test", "prepare_run", "clean", "reset", "snapshot", "query" }) do
            local r = assert(client.request(conn, { kind = kind, args = {} }))
            assert.equals("ok", r.kind)
            assert.equals("declined", r.outcome)
            assert.is_nil(r.result) -- a v0 reply, not an envelope reply
        end
        assert.same({ "on_build", "on_test", "on_run", "on_clean", "on_reset", "on_snapshot", "on_query" }, calls)
        local _, err = client.request(conn, { kind = "frobnicate" })
        assert.equals("unknown request kind: frobnicate", err)
        -- A v0 handler that throws is the v0 string error.
        svc.on_build = function() error("x") end
        _, err = client.request(conn, { kind = "build" })
        assert.equals("internal error", err)
        conn:close()
    end)

    it("without a service the v0 kinds stay unknown", function()
        srv.service = nil
        local conn = assert(client.loopback_session(srv))
        local _, err = client.request(conn, { kind = "snapshot" })
        assert.equals("unknown request kind: snapshot", err)
        conn:close()
    end)
end)

describe("interfaces registry", function()
    it("validates outgoing results only in development builds by default", function()
        local reg = interfaces.new({ identity = "0.1.43", conns = {}, log = function() end })
        assert.is_false(reg.validate_out)
        reg = interfaces.new({ identity = "0.1.44+dev.abc", conns = {}, log = function() end })
        assert.is_true(reg.validate_out)
    end)
end)
