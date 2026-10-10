--- loomworks/daemon/interfaces.lua — the daemon's interface registry and the
--- root object (spec §19.20 "Interfaces", step 5g.1).
---
--- The registry maps object paths to the interface versions mounted on them,
--- each with its schema document (loomworks.proto.documents), the digest of
--- that document, and one handler per method. Mounting checks registry and
--- schema agreement: every method in the schema has a handler and every
--- handler a method in the schema, else that interface version is refused.
---
--- `Registry:call(conn, msg)` serves a `call` frame of the envelope
--- (loomworks.proto.envelope): it resolves the object, interface and version
--- (the transport's error codes otherwise), validates `args` against the
--- method's parameter schema (`invalid_args` naming the first violation), runs
--- the handler and replies `ok { result }`; the result is validated against
--- its schema in a development build (a violation is an `internal` error the
--- tests see) and only logged in a release build. A handler returns the
--- result, or nil + an error object; or `M.ASYNC` after taking `ctx.reply` /
--- `ctx.fail` to answer later.
---
--- Object `/` always implements `loomworks.Root/1` (frozen, §19.8):
--- `describe`, `schema`, `subscribe`, `unsubscribe`. Its signals
--- (`objects_changed`, `retiring`) reach every connection of transport 11
--- without a subscription; other interfaces' signals reach only the
--- connections subscribed to them, stamped with the `sub_id` and a `seq` per
--- object and connection: it counts only the signals of that object the
--- connection is actually sent, so a gap means a lost signal, never one
--- filtered out (§19.12, §19.20); `subscribe` returns the value it starts
--- from. A connection's subscriptions are dropped when it closes.

local envelope = require("loomworks.proto.envelope")
local schema = require("loomworks.proto.schema")
local documents = require("loomworks.proto.documents")
local version = require("loomworks.daemon.version")

local M = {}

local ERR = envelope.ERR

--- A handler's "I will answer later" return.
M.ASYNC = setmetatable({}, { __tostring = function() return "interfaces.ASYNC" end })

--- The root's methods, as `describe().root_methods` lists them.
M.ROOT_METHODS = { "describe", "schema", "subscribe", "unsubscribe" }

--- How this daemon delivers to a transport-11 connection, as
--- `describe().delivery` reports it (§19.20): only by subscription.
M.DELIVERY = "subscription"

--- The implementation name `describe().binary.impl` reports.
M.IMPL = "lua"

--- Interface documents that are only shared types: served by
--- `Root.schema`, mounted on no object.
M.TYPE_DOCUMENTS = { { "loomworks.Common", 1 } }

local function sha256(text)
    local ok, h = pcall(function() return vim.fn.sha256(text) end)
    if ok and type(h) == "string" then return h end
    local okl, openssl = pcall(require, "openssl")
    if okl and type(openssl) == "table" and openssl.digest then
        local okd, d = pcall(openssl.digest.digest, "sha256", text, false)
        if okd and type(d) == "string" then return d end
    end
    return nil
end

--- @class loomworks.daemon.InterfaceImpl
--- @field methods table<string, fun(ctx: loomworks.daemon.CallContext, args: table): any, loomworks.proto.ErrorObject|nil>
--- @field initial? fun(ctx: loomworks.daemon.CallContext, args: table, signals: string[], sub: loomworks.daemon.Subscription): any the full state on subscribe
--- @field doc? table an inline schema document (tests; else loaded from the protocol directory)
--- @field same_build? boolean callable only by a client of the daemon's own lw_version
--- @field internal? boolean not a stable contract
--- @field deprecated? boolean announced in describe().deprecated

--- @class loomworks.daemon.MountedInterface
--- @field name string
--- @field v integer
--- @field doc table the schema document
--- @field rel string the document's path in the registry's document set
--- @field digest string|nil sha256 of the document's bytes
--- @field impl loomworks.daemon.InterfaceImpl

--- @class loomworks.daemon.CallContext
--- @field server loomworks.daemon.Server
--- @field conn table the calling connection
--- @field registry loomworks.daemon.Registry
--- @field env table<string, string>|nil the envelope's environment
--- @field reply fun(result: any) answer an ASYNC call
--- @field fail fun(e: loomworks.proto.ErrorObject) fail an ASYNC call

--- @class loomworks.daemon.Subscription
--- @field id string the opaque, session-scoped `sub_id` (protocol.session_id)
--- @field n integer the per-session counter (the subscriptions' order)
--- @field conn table
--- @field object string
--- @field iface string
--- @field v integer
--- @field signals table<string, true>|nil nil: every signal of the interface
--- @field args table the subscription's `args` (valid against the interface's `subscribe_args`)
--- @field view_sig string|nil a view's state last sent on it (loomworks.daemon.views)

--- @class loomworks.daemon.Registry
--- @field server loomworks.daemon.Server
--- @field objects table<string, { path: string, owner: string, ifaces: table<string, table<integer, loomworks.daemon.MountedInterface>> }>
--- @field docs loomworks.proto.DocumentSet
--- @field types table<string, table<integer, { doc: table, rel: string }>> types-only documents
--- @field subs table<string, loomworks.daemon.Subscription> by `sub_id`
--- @field seq table<table, table<string, integer>> per connection, per object: the last `seq` sent
--- @field validate_out boolean validate results and signals (development builds and tests)
local Registry = {}
Registry.__index = Registry

--- A registry for `server`, with the root mounted.
--- opts: { docs = DocumentSet (default: the protocol directory), validate_out = boolean }
--- @param server loomworks.daemon.Server
--- @param opts? table
--- @return loomworks.daemon.Registry
function M.new(server, opts)
    opts = opts or {}
    local self = setmetatable({ server = server, objects = {}, docs = opts.docs or documents.set(),
        types = {}, subs = {}, seq = setmetatable({}, { __mode = "k" }), _next_sub = 0, _digests = {} }, Registry)
    if opts.validate_out ~= nil then
        self.validate_out = opts.validate_out
    else
        self.validate_out = version.is_dev(server and server.identity) or os.getenv("LW_TEST_VALIDATE_PROTOCOL") == "1"
    end
    for _, t in ipairs(M.TYPE_DOCUMENTS) do
        local doc, rel = self.docs:interface(t[1], t[2])
        if doc then
            self.types[t[1]] = self.types[t[1]] or {}
            self.types[t[1]][t[2]] = { doc = doc, rel = rel }
        end
    end
    local ok, err = self:mount("/", "core", envelope.ROOT_IFACE, envelope.ROOT_V, M.root_impl())
    if not ok then self:_log("the root interface is not available: %s", tostring(err)) end
    return self
end

function Registry:_log(fmt, ...)
    if self.server and self.server.log then self.server:log(fmt, ...) end
end

--- The digest of a loaded document (memoized: computed where vim.fn may run).
function Registry:_digest(rel)
    local d = self._digests[rel]
    if d == nil then
        local text = self.docs.texts[rel]
        d = text and sha256(text) or false
        if d then self._digests[rel] = d end
    end
    return d or nil
end

--- Mount interface version `name`/`v` on object `path`. Refused (nil + why)
--- when its document is missing or invalid, or its methods and handlers
--- disagree. A new path sends `objects_changed` to every connection.
--- @param path string
--- @param owner string `core` or the module id
--- @param name string
--- @param v integer
--- @param impl loomworks.daemon.InterfaceImpl
--- @return boolean|nil ok, string|nil err
function Registry:mount(path, owner, name, v, impl)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil, "malformed object path" end
    local doc, rel
    if impl.doc then
        rel = documents.interface_path(name, v) or (name .. "." .. tostring(v))
        doc = impl.doc
        self.docs.docs[rel] = doc
        self.docs.texts[rel] = self.docs.texts[rel] or vim.json.encode(doc)
    else
        local err
        doc, err = self.docs:interface(name, v)
        if not doc then return nil, err end
        rel = err
    end
    if doc.interface ~= name or doc.version ~= v then
        return nil, string.format("%s declares %s/%s", rel, tostring(doc.interface), tostring(doc.version))
    end
    local methods = impl.methods or {}
    for m in pairs(doc.methods or {}) do
        if type(methods[m]) ~= "function" then return nil, string.format("%s/%d: no handler for method %s", name, v, m) end
    end
    for m in pairs(methods) do
        if not (doc.methods and doc.methods[m]) then
            return nil, string.format("%s/%d: handler %s has no method in the schema", name, v, m)
        end
    end
    local o = self.objects[path]
    local added = o == nil
    if not o then
        o = { path = path, owner = owner, ifaces = {} }
        self.objects[path] = o
    end
    o.ifaces[name] = o.ifaces[name] or {}
    o.ifaces[name][v] = { name = name, v = v, doc = doc, rel = rel, impl = impl,
        same_build = impl.same_build or doc.same_build == true, internal = impl.internal or doc.internal == true }
    self:_digest(rel)
    if added then self:root_signal("objects_changed", { added = { path }, removed = {} }) end
    return true
end

--- Unmount one interface version, every version of an interface, or (no
--- name) the whole object. An object left with no interface is removed and
--- `objects_changed` sent; its subscriptions are dropped.
--- @param path string
--- @param name? string
--- @param v? integer
function Registry:unmount(path, name, v)
    local o = self.objects[path]
    if not o or path == "/" then return end
    if name and v then
        if o.ifaces[name] then o.ifaces[name][v] = nil end
        if o.ifaces[name] and next(o.ifaces[name]) == nil then o.ifaces[name] = nil end
    elseif name then
        o.ifaces[name] = nil
    else
        o.ifaces = {}
    end
    for id, s in pairs(self.subs) do
        local gone = s.object == path and not (o.ifaces[s.iface] and o.ifaces[s.iface][s.v])
        if gone then self.subs[id] = nil end
    end
    if next(o.ifaces) == nil then
        self.objects[path] = nil
        self:root_signal("objects_changed", { added = {}, removed = { path } })
    end
end

--- The subscriptions in the order they were made.
local function subs_in_order(subs)
    local list = {}
    for _, sub in pairs(subs) do list[#list + 1] = sub end
    table.sort(list, function(a, b) return a.n < b.n end)
    return list
end

local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return ks
end

--- The objects list of `describe` (with digests) or of `welcome` (without).
--- @param with_digests boolean
--- @return table[]
function Registry:object_list(with_digests)
    local out = {}
    for _, path in ipairs(sorted_keys(self.objects)) do
        local o = self.objects[path]
        local ifs = {}
        for _, name in ipairs(sorted_keys(o.ifaces)) do
            local versions, deprecated, digests = {}, {}, {}
            local info = { name = name }
            for _, v in ipairs(sorted_keys(o.ifaces[name])) do
                local e = o.ifaces[name][v]
                versions[#versions + 1] = v
                if e.impl.deprecated then deprecated[#deprecated + 1] = v end
                if e.same_build then info.same_build = true end
                if e.internal then info.internal = true end
                local d = with_digests and self:_digest(e.rel) or nil
                if d then digests[tostring(v)] = d end
            end
            info.versions = versions
            if #deprecated > 0 then info.deprecated = deprecated end
            if with_digests then info.schema_digest = next(digests) and digests or envelope.empty() end
            ifs[#ifs + 1] = info
        end
        out[#out + 1] = { path = path, owner = o.owner, interfaces = ifs }
    end
    return out
end

--- Resolve object / interface / version to its mounted entry, or nil + the
--- transport error.
--- @return loomworks.daemon.MountedInterface|nil, loomworks.proto.ErrorObject|nil
function Registry:resolve(object, iface, v)
    local o = self.objects[object]
    if not o then return nil, envelope.err(ERR.unknown_object, "no object " .. tostring(object)) end
    local vs = o.ifaces[iface]
    if not vs then
        return nil, envelope.err(ERR.unknown_interface, tostring(object) .. " does not implement " .. tostring(iface))
    end
    local e = vs[v]
    if not e then
        return nil, envelope.err(ERR.unsupported_version,
            string.format("%s is not served at version %s", tostring(iface), tostring(v)),
            { versions = sorted_keys(vs) })
    end
    return e
end

--- Validate a value against a schema node of a mounted document.
function Registry:_validate(e, node, value)
    if node == nil then return true end
    return schema.validate(node, value, { doc = e.doc, base = e.rel, resolve_doc = self.docs:resolver() })
end

--- Bring a value a handler built to the wire shape of a schema node of a
--- mounted document (an empty table the schema types as an object encodes
--- as `{}`, any other as `[]`).
function Registry:_shape(e, node, value)
    if node == nil then return value end
    return schema.shape(node, value, { doc = e.doc, base = e.rel, resolve_doc = self.docs:resolver() })
end

--- Is the connection on transport 11 or later (it understands envelope frames)?
--- @param conn table
--- @return boolean
function M.speaks_envelope(conn)
    return type(conn.transport) == "number" and conn.transport >= 11
end

--- Serve a `call` frame on `conn`.
--- @param conn table
--- @param msg table
function Registry:call(conn, msg)
    local server = self.server
    local req_id = msg.req_id
    local function send(frame) server:_send(conn, frame) end
    local function fail(e) send(envelope.error(req_id, e)) end
    local bad = envelope.check_call(msg)
    if bad then return fail(bad) end
    local e, rerr = self:resolve(msg.object, msg.iface, msg.v)
    if not e then return fail(rerr) end
    local mdoc = e.doc.methods and e.doc.methods[msg.method]
    local handler = e.impl.methods[msg.method]
    if not mdoc or not handler then
        return fail(envelope.err(ERR.unknown_method,
            string.format("%s/%d has no method %s", msg.iface, msg.v, tostring(msg.method))))
    end
    if e.same_build and not (conn.peer and conn.peer.lw_version == server.identity) then
        return fail(envelope.err(ERR.same_build_required,
            string.format("%s/%d needs a client of lw %s", msg.iface, msg.v, tostring(server.identity))))
    end
    local args = msg.args or envelope.empty()
    local ok, verr = self:_validate(e, mdoc.params, args)
    if not ok then return fail(envelope.err(ERR.invalid_args, verr)) end
    local env
    if mdoc.needs_env then
        local eerr
        env, eerr = require("loomworks.daemon.envscope").validate(msg.env)
        if not env then return fail(envelope.err(ERR.invalid_args, "env: " .. tostring(eerr))) end
    end
    local answered = false
    local ctx = { server = server, conn = conn, registry = self, env = env }
    function ctx.reply(result)
        if answered then return end
        answered = true
        result = self:_shape(e, mdoc.result, result == nil and envelope.empty() or result)
        local okr, rverr = self:_validate(e, mdoc.result, result)
        if not okr then
            local what = string.format("%s/%d.%s result does not match its schema: %s", msg.iface, msg.v,
                msg.method, tostring(rverr))
            self:_log("%s", what)
            -- Development builds and tests make a non-mutating method's bad
            -- result an error. A mutating method's reply is sent as it is:
            -- it may say what already started (an accepted task), and an
            -- error would let the client run the operation a second time.
            if self.validate_out and not mdoc.mutates then return fail(envelope.err(ERR.internal, what)) end
        end
        send(envelope.ok(req_id, result))
    end
    function ctx.fail(err)
        if answered then return end
        answered = true
        fail(err)
    end
    local okh, result, herr = pcall(handler, ctx, args)
    if not okh then
        self:_log("handler error for %s/%d.%s: %s", msg.iface, msg.v, msg.method, tostring(result))
        return ctx.fail(envelope.err(ERR.internal, "internal error"))
    end
    if result == M.ASYNC then return end
    if result == nil and herr then return ctx.fail(herr) end
    ctx.reply(result)
end

-- ---------------------------------------------------------------------------
-- Signals and subscriptions
-- ---------------------------------------------------------------------------

--- Send a root signal to every authenticated connection of transport 11.
--- @param name string
--- @param args table
function Registry:root_signal(name, args)
    local server = self.server
    if not server or not server.conns then return end
    local root = self.objects["/"] and self.objects["/"].ifaces[envelope.ROOT_IFACE]
    local e = root and root[envelope.ROOT_V]
    local sdoc = e and e.doc.signals and e.doc.signals[name]
    if e then args = self:_shape(e, sdoc and sdoc.args, args) end
    if e and self.validate_out then
        local ok, verr = self:_validate(e, sdoc and sdoc.args, args)
        if not ok then self:_log("root signal %s does not match its schema: %s", name, tostring(verr)) end
    end
    local frame = envelope.signal("/", envelope.ROOT_IFACE, envelope.ROOT_V, name, args)
    for conn in pairs(server.conns) do
        if conn.authed and not conn.closed and M.speaks_envelope(conn) then server:_send(conn, frame) end
    end
end

--- Emit a signal of an interface version mounted on `object` to the
--- connections subscribed to it (filtered by `accept(sub_args, sub)` when
--- given; it is asked right before that subscription's frame is sent).
--- @param object string
--- @param iface string
--- @param v integer
--- @param name string
--- @param args table
--- @param accept? fun(sub_args: table, sub: loomworks.daemon.Subscription): boolean
--- @return integer delivered
function Registry:emit(object, iface, v, name, args, accept)
    local e = self:resolve(object, iface, v)
    if not e then return 0 end
    local sdoc = e.doc.signals and e.doc.signals[name]
    args = self:_shape(e, sdoc and sdoc.args, args)
    if self.validate_out then
        local ok, verr = self:_validate(e, sdoc and sdoc.args, args)
        if not ok then
            self:_log("signal %s/%d.%s does not match its schema: %s", iface, v, name, tostring(verr))
        end
    end
    local n = 0
    for _, s in ipairs(subs_in_order(self.subs)) do
        if s.object == object and s.iface == iface and s.v == v and (not s.signals or s.signals[name])
            and not s.conn.closed and (not accept or accept(s.args, s)) then
            self.server:_send(s.conn,
                envelope.signal(object, iface, v, name, args, s.id, self:_next_seq(s.conn, object)))
            n = n + 1
        end
    end
    return n
end

--- Does any open connection subscribe to signal `name` of an interface
--- version on `object`? (A signal whose state is costly to build is built
--- only then.)
--- @param object string
--- @param iface string
--- @param v integer
--- @param name string
--- @return boolean
function Registry:has_subscribers(object, iface, v, name)
    for _, s in pairs(self.subs) do
        if s.object == object and s.iface == iface and s.v == v and (not s.signals or s.signals[name])
            and not s.conn.closed then
            return true
        end
    end
    return false
end

--- The `seq` of the next signal of `object` sent to `conn` (counted per
--- connection and object, only for signals actually sent).
--- @param conn table
--- @param object string
--- @return integer
function Registry:_next_seq(conn, object)
    local per = self.seq[conn]
    if not per then
        per = {}
        self.seq[conn] = per
    end
    per[object] = (per[object] or 0) + 1
    return per[object]
end

--- The last `seq` of `object` sent to `conn` (0: none yet).
--- @param conn table
--- @param object string
--- @return integer
function Registry:last_seq(conn, object)
    local per = self.seq[conn]
    return per and per[object] or 0
end

--- Drop a closed connection's subscriptions.
--- @param conn table
function Registry:drop_conn(conn)
    for id, s in pairs(self.subs) do
        if s.conn == conn then self.subs[id] = nil end
    end
    self.seq[conn] = nil
end

--- The subscriptions of a connection (tests, status).
--- @param conn table
--- @return loomworks.daemon.Subscription[]
function Registry:subscriptions_of(conn)
    local out = {}
    for _, s in ipairs(subs_in_order(self.subs)) do
        if s.conn == conn then out[#out + 1] = s end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The root object (loomworks.Root/1)
-- ---------------------------------------------------------------------------

--- The handlers of `loomworks.Root/1`.
--- @return loomworks.daemon.InterfaceImpl
function M.root_impl()
    local methods = {}

    function methods.describe(ctx)
        local server, reg = ctx.server, ctx.registry
        local identity = server.identity or version.identity()
        return {
            binary = { lw_version = identity, impl = M.IMPL, dev = version.is_dev(identity) },
            transport = { min = version.PROTOCOL_MIN, max = version.PROTOCOL },
            session_generation = server.generation,
            objects = reg:object_list(true),
            root_methods = M.ROOT_METHODS,
            -- A transport-11 connection gets task frames and changes only
            -- through its subscriptions (§19.20, step 5g.3).
            delivery = M.DELIVERY,
        }
    end

    function methods.schema(ctx, args)
        local reg = ctx.registry
        local found
        for _, o in pairs(reg.objects) do
            local vs = o.ifaces[args.iface]
            if vs then
                found = found or {}
                for v, e in pairs(vs) do found[v] = e.doc end
            end
        end
        local t = reg.types[args.iface]
        if t then
            found = found or {}
            for v, d in pairs(t) do found[v] = d.doc end
        end
        if not found then return nil, envelope.err(ERR.unknown_interface, "no interface " .. tostring(args.iface)) end
        if not found[args.v] then
            return nil, envelope.err(ERR.unsupported_version,
                string.format("%s is not served at version %s", args.iface, tostring(args.v)),
                { versions = sorted_keys(found) })
        end
        return found[args.v]
    end

    function methods.subscribe(ctx, args)
        local reg = ctx.registry
        local e, err = reg:resolve(args.object, args.iface, args.v)
        if not e then return nil, err end
        if e.same_build and not (ctx.conn.peer and ctx.conn.peer.lw_version == ctx.server.identity) then
            return nil, envelope.err(ERR.same_build_required,
                string.format("%s/%d needs a client of lw %s", args.iface, args.v, tostring(ctx.server.identity)))
        end
        local declared = e.doc.signals or {}
        local names, set
        if args.signals ~= nil then
            set, names = {}, {}
            for _, s in ipairs(args.signals) do
                if not declared[s] then
                    return nil, envelope.err(ERR.invalid_args,
                        string.format("/signals: %s/%d has no signal %s", args.iface, args.v, tostring(s)))
                end
                set[s] = true
                names[#names + 1] = s
            end
        else
            names = sorted_keys(declared)
        end
        -- The subscription's args are always checked: against the
        -- interface's `subscribe_args`, or empty when it declares none.
        local sub_args = args.args or envelope.empty()
        if e.doc.subscribe_args ~= nil then
            local ok, verr = reg:_validate(e, e.doc.subscribe_args, sub_args)
            if not ok then return nil, envelope.err(ERR.invalid_args, "/args" .. verr) end
        elseif next(sub_args) ~= nil then
            return nil, envelope.err(ERR.invalid_args,
                string.format("/args: %s/%d takes no subscription args", args.iface, args.v))
        end
        local want_initial = false
        for _, s in ipairs(names) do
            if declared[s].initial then want_initial = true end
        end
        reg._next_sub = reg._next_sub + 1
        local sub = { id = require("loomworks.daemon.protocol").session_id(ctx.server.generation, reg._next_sub),
            n = reg._next_sub, conn = ctx.conn, object = args.object, iface = args.iface,
            v = args.v, signals = set, args = sub_args }
        reg.subs[sub.id] = sub
        local result = { sub_id = sub.id, seq = reg:last_seq(ctx.conn, args.object) }
        if want_initial and e.impl.initial then
            local ok, initial = pcall(e.impl.initial, ctx, sub_args, names, sub)
            if not ok then
                reg.subs[sub.id] = nil
                reg:_log("initial state of %s/%d failed: %s", args.iface, args.v, tostring(initial))
                return nil, envelope.err(ERR.internal, "internal error")
            end
            result.initial = initial
        end
        return result
    end

    function methods.unsubscribe(ctx, args)
        local reg = ctx.registry
        local s = reg.subs[args.sub_id]
        if s and s.conn == ctx.conn then reg.subs[args.sub_id] = nil end
        return envelope.empty()
    end

    return { methods = methods }
end

M.Registry = Registry
return M
