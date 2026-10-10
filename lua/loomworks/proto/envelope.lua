--- loomworks/proto/envelope.lua — the message envelope of transport 11
--- (spec §19.8, §19.20 "Message envelope"):
---
---   call   { kind = "call",   req_id, object, iface, v, method, args, env? }
---   ok     { kind = "ok",     req_id, result }
---   error  { kind = "error",  req_id, error = { code, message, data? } }
---   signal { kind = "signal", object, iface, v, name, sub_id?, seq?, args }
---   task   { kind = "task",   task_id, phase, ... }     -- §19.15
---
--- The routing fields and the transport error codes are frozen (§19.8): new
--- codes may be added; a client treats one it does not know as `internal`.
--- Shared by the daemon and its clients; pure Lua (`vim.empty_dict` only, so
--- an empty object encodes as `{}`).

local M = {}

M.KIND = { call = "call", ok = "ok", error = "error", signal = "signal", task = "task" }

--- The transport's error codes (spec §19.20 "Errors and domain results").
M.ERR = {
    unknown_object = "unknown_object",
    unknown_interface = "unknown_interface",
    unsupported_version = "unsupported_version",
    unknown_method = "unknown_method",
    invalid_args = "invalid_args",
    same_build_required = "same_build_required",
    not_loaded = "not_loaded",
    stopping = "stopping",
    retiring = "retiring",
    forbidden = "forbidden",
    internal = "internal",
}

--- The root object and its interface (spec §19.20 "The root object").
M.ROOT = "/"
M.ROOT_IFACE = "loomworks.Root"
M.ROOT_V = 1

--- An empty JSON object (encodes as `{}`, never `[]`).
--- @return table
function M.empty()
    local v = rawget(_G, "vim")
    return (v and v.empty_dict) and v.empty_dict() or {}
end

local function obj(t)
    if t == nil or (type(t) == "table" and next(t) == nil) then return M.empty() end
    return t
end

--- @class loomworks.proto.ErrorObject
--- @field code string a transport code (M.ERR) or an interface's own
--- @field message string
--- @field data any|nil

--- An error object.
--- @param code string
--- @param message string
--- @param data? any
--- @return loomworks.proto.ErrorObject
function M.err(code, message, data)
    return { code = code, message = message, data = data }
end

--- A `call` frame (the client assigns `req_id` when it sends it).
--- @param object string
--- @param iface string
--- @param v integer
--- @param method string
--- @param args? table
--- @param env? table<string, string>
--- @return table
function M.call(object, iface, v, method, args, env)
    return { kind = M.KIND.call, object = object, iface = iface, v = v, method = method,
        args = obj(args), env = env }
end

--- An `ok` reply to a call. `result` goes out as given (nil: `{}`): an empty
--- table encodes as `[]` unless it carries the empty-dict marker, so a
--- server brings it to its schema's shape first (loomworks.proto.schema
--- `shape`).
--- @param req_id any
--- @param result any
--- @return table
function M.ok(req_id, result)
    if result == nil then result = M.empty() end
    return { kind = M.KIND.ok, req_id = req_id, result = result }
end

--- An `error` reply to a call.
--- @param req_id any
--- @param e loomworks.proto.ErrorObject
--- @return table
function M.error(req_id, e)
    return { kind = M.KIND.error, req_id = req_id, error = e }
end

--- A `signal` frame.
--- @param object string
--- @param iface string
--- @param v integer
--- @param name string
--- @param args? table
--- @param sub_id? integer
--- @param seq? integer
--- @return table
function M.signal(object, iface, v, name, args, sub_id, seq)
    return { kind = M.KIND.signal, object = object, iface = iface, v = v, name = name,
        args = obj(args), sub_id = sub_id, seq = seq }
end

--- Check a call's routing fields. Returns nil when well-formed, else an
--- `invalid_args` error object naming the first bad field.
--- @param msg table
--- @return loomworks.proto.ErrorObject|nil
function M.check_call(msg)
    local function bad(what) return M.err(M.ERR.invalid_args, "malformed call: " .. what) end
    if type(msg.object) ~= "string" or msg.object:sub(1, 1) ~= "/" then return bad("object") end
    if type(msg.iface) ~= "string" or msg.iface == "" then return bad("iface") end
    if type(msg.v) ~= "number" or msg.v < 1 or msg.v % 1 ~= 0 then return bad("v") end
    if type(msg.method) ~= "string" or msg.method == "" then return bad("method") end
    if msg.args ~= nil and type(msg.args) ~= "table" then return bad("args") end
    if msg.env ~= nil and type(msg.env) ~= "table" then return bad("env") end
    return nil
end

local KNOWN = {}
for _, c in pairs(M.ERR) do KNOWN[c] = true end

--- The code a client acts on: a code it does not know is `internal`
--- (§19.8). `declared` is the set of codes the called interface version's
--- schema declares (its `errors`).
--- @param e any the reply's `error`
--- @param declared? table<string, any>
--- @return string
function M.code_of(e, declared)
    local c = type(e) == "table" and e.code or nil
    if type(c) ~= "string" then return M.ERR.internal end
    if KNOWN[c] or (declared and declared[c]) then return c end
    return M.ERR.internal
end

return M
