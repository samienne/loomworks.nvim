--- loomworks/daemon/calls.lua — the CLI's requests as interface calls (spec
--- §19.20, step 5g.2: "the CLI calls them").
---
--- The CLI builds its daemon requests in the protocol-10 shape (`build`,
--- `test`, `prepare_run`, `clean`, `reset`, `snapshot`, `query`), which stay
--- the v0 aliases older clients use. On a connection whose negotiated
--- transport is 11 or later, `M.request` sends the interface call instead and
--- hands the caller the reply in the protocol-10 shape, so the CLI's handling
--- (outcomes, notes, the task stream) is one code path for both:
---
---   build / clean / reset   /build       loomworks.Build/1       build / clean / reset
---   test                    /tests       loomworks.Tests/1       run
---   prepare_run             /launch      loomworks.Launch/1      prepare_run
---   snapshot                /internal    lw.internal.Snapshot/1  get
---   query tools             /toolchains  loomworks.Toolchains/1  list
---   query profile_cache     /profiles    loomworks.Profiles/1    compiler_cache
---
--- Entity arguments become references by key (`{ key }`: the CLI sends what
--- the user typed, §19.20 "References"). A transport error of the call (the
--- daemon does not serve the interface, invalid arguments) is answered as
--- `declined` with the error's message: the CLI then runs the command
--- in-process, as for any declined request. A request with no interface form
--- (`ping`, an unknown query) is sent as it is.

local M = {}

local VERSION = 1

--- The interface of each protocol-10 operation kind: object, iface, method.
M.OPERATIONS = {
    build = { "/build", "loomworks.Build", "build" },
    clean = { "/build", "loomworks.Build", "clean" },
    reset = { "/build", "loomworks.Build", "reset" },
    test = { "/tests", "loomworks.Tests", "run" },
    prepare_run = { "/launch", "loomworks.Launch", "prepare_run" },
}

--- The interface of each registered query: object, iface, method, and the
--- mapping of its args and of its result to the `query` reply's `result`.
M.QUERIES = {
    tools = { "/toolchains", "loomworks.Toolchains", "list",
        args = function() return {} end,
        result = function(r) return { tools = r.tools } end },
    profile_cache = { "/profiles", "loomworks.Profiles", "compiler_cache",
        args = function(a) return { profile = { key = a.profile }, project = { key = a.project } } end,
        result = function(r) return { cache = r.cache } end },
}

--- Does `conn` speak interface calls (transport 11 or later)?
--- @param conn table
--- @return boolean
function M.speaks_calls(conn)
    return type(conn) == "table" and type(conn.transport) == "number" and conn.transport >= 11
end

--- The call frame of protocol-10 request `msg`, or nil when it has no
--- interface form. The second value maps the call's `ok` result back to the
--- protocol-10 reply's fields.
--- @param msg table
--- @return table|nil frame, (fun(result: table): table)|nil to_reply
function M.frame(msg)
    local envelope = require("loomworks.proto.envelope")
    local op = M.OPERATIONS[msg.kind]
    if op then
        local args = {}
        for k, v in pairs(type(msg.args) == "table" and msg.args or {}) do args[k] = v end
        for _, name in ipairs({ "profile", "project" }) do
            if args[name] ~= nil then args[name] = { key = args[name] } end
        end
        if msg.interactive ~= nil then args.interactive = msg.interactive == true end
        if type(msg.command) == "string" then args.command = msg.command end
        return envelope.call(op[1], op[2], VERSION, op[3], args, msg.env), function(r) return r end
    end
    if msg.kind == "snapshot" then
        return envelope.call("/internal", "lw.internal.Snapshot", VERSION, "get", { scope = msg.scope }, msg.env),
            function(r) return r end
    end
    local q = msg.kind == "query" and M.QUERIES[msg.name]
    if q then
        return envelope.call(q[1], q[2], VERSION, q[3], q.args(type(msg.args) == "table" and msg.args or {}), msg.env),
            function(r)
                if r.outcome ~= "ok" then return r end
                return { outcome = "ok", result = q.result(r), notes = r.notes }
            end
    end
    return nil
end

--- The protocol-10 reply of a call's reply frame.
--- @param reply table the `ok` / `error` frame
--- @param to_reply fun(result: table): table
--- @return table
function M.reply(reply, to_reply)
    if reply.kind == "error" then
        local e = type(reply.error) == "table" and reply.error or {}
        return { kind = "ok", req_id = reply.req_id, outcome = "declined",
            reason = string.format("%s: %s", tostring(e.code or "error"), tostring(e.message or "")) }
    end
    local fields = to_reply(type(reply.result) == "table" and reply.result or {})
    local out = {}
    for k, v in pairs(fields) do out[k] = v end
    out.kind, out.req_id = "ok", reply.req_id
    return out
end

--- Send protocol-10 request `msg` on `conn`: as its interface call when the
--- connection speaks transport 11 and the request has one, else as it is.
--- `cb(reply|nil, err)` gets the reply in the protocol-10 shape.
--- @param conn table a client session (loomworks.daemon.client)
--- @param msg table
--- @param cb fun(reply: table|nil, err: any)
function M.request(conn, msg, cb)
    local frame, to_reply
    if M.speaks_calls(conn) then frame, to_reply = M.frame(msg) end
    if not frame then return conn:request(msg, cb) end
    conn:request(frame, function(reply, err)
        -- (The session hands an `error` frame over as its error object.)
        if not reply and type(err) == "table" and err.code ~= nil then
            return cb(M.reply({ kind = "error", req_id = frame.req_id, error = err }, to_reply), nil)
        end
        if not reply then return cb(nil, err) end
        cb(M.reply(reply, to_reply), nil)
    end)
end

--- `M.request` synchronously (pumping the event loop): the reply, or nil +
--- the error (`client.ERR_TIMEOUT` when none came in time).
--- @param conn table
--- @param msg table
--- @param timeout_ms? integer
--- @return table|nil reply, any err
function M.request_sync(conn, msg, timeout_ms)
    local client = require("loomworks.daemon.client")
    local res
    M.request(conn, msg, function(r, e) res = { r, e } end)
    vim.wait(timeout_ms or client.TIMEOUT_MS, function() return res ~= nil end, 5)
    if not res then return nil, client.ERR_TIMEOUT end
    return res[1], res[2]
end

return M
