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
--- the user typed, §19.20 "References"). A transport error of the call is
--- answered by its code (M.on_error):
---
---   unknown_object, unknown_interface,    nothing ran: the protocol-10 request
---   unknown_method, unsupported_version   is sent instead (a daemon of step
---                                         5g.1 speaks transport 11 without
---                                         these interfaces)
---   invalid_args, same_build_required,    `declined` with the error: the CLI
---   stopping, retiring                    runs the command in-process
---   internal or an unknown code           a mutating method (it may have
---                                         started): `refused`, exit 1, never
---                                         run a second time in-process; any
---                                         other method: `declined`
---
--- A request with no interface form (`ping`, an unknown query) is sent as it
--- is.

local M = {}

local VERSION = 1

--- The interface of each protocol-10 operation kind: object, iface, method;
--- `mutates` as the method's schema declares it.
M.OPERATIONS = {
    build = { "/build", "loomworks.Build", "build", mutates = true },
    clean = { "/build", "loomworks.Build", "clean", mutates = true },
    reset = { "/build", "loomworks.Build", "reset", mutates = true },
    test = { "/tests", "loomworks.Tests", "run", mutates = true },
    prepare_run = { "/launch", "loomworks.Launch", "prepare_run", mutates = true },
}

--- Transport error codes after which nothing ran and the protocol-10
--- request is sent instead.
M.RETRY_V0 = { unknown_object = true, unknown_interface = true, unknown_method = true,
    unsupported_version = true }
--- Transport error codes after which nothing ran and the CLI runs in-process.
M.DECLINE = { invalid_args = true, same_build_required = true, stopping = true, retiring = true }

--- What the CLI does after a transport error `code` of a call:
--- "retry_v0" (send the protocol-10 request), "declined" (run in-process) or
--- "failed" (a mutating method that may have started: exit 1, never run it
--- again).
--- @param code any
--- @param mutates boolean
--- @return "retry_v0"|"declined"|"failed"
function M.on_error(code, mutates)
    if M.RETRY_V0[code] then return "retry_v0" end
    if M.DECLINE[code] then return "declined" end
    return mutates and "failed" or "declined"
end

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
--- protocol-10 reply's fields; the third is whether the method mutates.
--- @param msg table
--- @return table|nil frame, (fun(result: table): table)|nil to_reply, boolean|nil mutates
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
        return envelope.call(op[1], op[2], VERSION, op[3], args, msg.env), function(r) return r end,
            op.mutates == true
    end
    if msg.kind == "snapshot" then
        return envelope.call("/internal", "lw.internal.Snapshot", VERSION, "get", { scope = msg.scope }, msg.env),
            function(r) return r end, false
    end
    local q = msg.kind == "query" and M.QUERIES[msg.name]
    if q then
        return envelope.call(q[1], q[2], VERSION, q[3], q.args(type(msg.args) == "table" and msg.args or {}), msg.env),
            function(r)
                if r.outcome ~= "ok" then return r end
                return { outcome = "ok", result = q.result(r), notes = r.notes }
            end, false
    end
    return nil
end

--- The protocol-10 reply of a call's reply frame; nil for an error after
--- which the protocol-10 request is sent instead (M.on_error).
--- @param reply table the `ok` / `error` frame
--- @param to_reply fun(result: table): table
--- @param mutates? boolean the method mutates
--- @param what? string the operation, for the message of a failed call
--- @return table|nil
function M.reply(reply, to_reply, mutates, what)
    if reply.kind == "error" then
        local e = type(reply.error) == "table" and reply.error or {}
        local text = string.format("%s: %s", tostring(e.code or "error"), tostring(e.message or ""))
        local action = M.on_error(e.code, mutates == true)
        if action == "retry_v0" then return nil end
        if action == "failed" then
            return { kind = "ok", req_id = reply.req_id, outcome = "refused", exit_code = 1,
                message = string.format("the workspace daemon failed the %s (%s); it may have started, so it is"
                    .. " not run again without the daemon", what or "operation", text) }
        end
        return { kind = "ok", req_id = reply.req_id, outcome = "declined", reason = text }
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
    local frame, to_reply, mutates
    if M.speaks_calls(conn) then frame, to_reply, mutates = M.frame(msg) end
    if not frame then return conn:request(msg, cb) end
    local what = msg.kind == "prepare_run" and "run" or msg.kind
    local function answer(r)
        -- Nothing ran: the protocol-10 request instead.
        if r == nil then return conn:request(msg, cb) end
        cb(r, nil)
    end
    conn:request(frame, function(reply, err)
        -- (The session hands an `error` frame over as its error object.)
        if not reply and type(err) == "table" and err.code ~= nil then
            return answer(M.reply({ kind = "error", req_id = frame.req_id, error = err }, to_reply, mutates, what))
        end
        if not reply then return cb(nil, err) end
        answer(M.reply(reply, to_reply, mutates, what))
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
