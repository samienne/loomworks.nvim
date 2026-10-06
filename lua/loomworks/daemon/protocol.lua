--- loomworks/daemon/protocol.lua — framing and message kinds of the daemon
--- wire protocol (spec §19.8).
---
--- A message is a JSON object prefixed by its decimal byte length and a
--- newline: `<len>\n<json>`. Every request carries a `req_id` its reply
--- echoes; broadcasts carry none. The decoder enforces a frame cap on the
--- LENGTH PREFIX, before any payload is buffered: 64 KiB until the connection
--- has authenticated, `MAX_FRAME` after.
---
--- The **frozen control subset** — this framing, `hello` / `challenge` /
--- `auth` / `welcome`, `ping`, `status`, `stop` and `retire`, and the `ok` /
--- `error` replies — never changes shape across versions, so any two
--- versions can always authenticate, inspect and retire each other (§19.8).

local M = {}

--- The wire protocol version (loomworks.daemon.version.PROTOCOL).
M.VERSION = require("loomworks.daemon.version").PROTOCOL
--- The oldest transport still spoken (loomworks.daemon.version.PROTOCOL_MIN).
M.VERSION_MIN = require("loomworks.daemon.version").PROTOCOL_MIN

--- Frame cap before authentication (spec §19.8).
M.PREAUTH_MAX = 64 * 1024
--- Frame cap after authentication.
M.MAX_FRAME = 16 * 1024 * 1024

M.KIND = {
    -- handshake (frozen)
    hello = "hello",
    challenge = "challenge",
    auth = "auth",
    welcome = "welcome",
    -- control requests (frozen)
    ping = "ping",
    status = "status",
    stop = "stop",
    retire = "retire",
    -- replies (frozen)
    ok = "ok",
    error = "error",
    -- routed operations (§19.15): a request and its task stream
    build = "build",
    test = "test",
    prepare_run = "prepare_run",
    clean = "clean",
    reset = "reset",
    task = "task",
    -- the model (§19.13, §19.14): a scope snapshot for a client's
    -- projection; a read-only query that probes the host in the client's
    -- environment
    snapshot = "snapshot",
    query = "query",
    -- broadcasts (§19.11, §19.12): a committed write of a state file; the
    -- daemon was retired (observers disconnect)
    model_change = "model_change",
    retiring = "retiring",
    -- the message envelope of protocol 11 (§19.20, loomworks.proto.envelope):
    -- an interface call and an interface signal (replies are `ok` / `error`,
    -- the error then a structured object)
    call = "call",
    signal = "signal",
}

--- Encode a message table as a frame.
--- @param msg table
--- @return string
function M.encode(msg)
    local payload = vim.json.encode(msg)
    return tostring(#payload) .. "\n" .. payload
end

--- @class loomworks.daemon.Decoder
--- @field _buf string
--- @field max integer current frame cap
local Decoder = {}
Decoder.__index = Decoder

--- @param max? integer frame cap (default PREAUTH_MAX)
--- @return loomworks.daemon.Decoder
function M.new_decoder(max)
    return setmetatable({ _buf = "", max = max or M.PREAUTH_MAX }, Decoder)
end

--- Push received bytes. Returns the decoded messages that became complete,
--- or nil + an error ("frame too large", "malformed frame", "malformed
--- message") — the stream is then unusable and the caller closes it.
--- @param chunk string
--- @return table[]|nil msgs, string|nil err
function Decoder:push(chunk)
    self._buf = self._buf .. chunk
    local out = {}
    while true do
        local nl = self._buf:find("\n", 1, true)
        if not nl then
            -- A length prefix is at most a few digits; a long run of bytes
            -- without a newline is no frame at all.
            if #self._buf > 16 then return nil, "malformed frame" end
            break
        end
        local head = self._buf:sub(1, nl - 1)
        if not head:match("^%d+$") or #head > 12 then return nil, "malformed frame" end
        local len = tonumber(head)
        if len > self.max then return nil, "frame too large" end
        local total = nl + len
        if #self._buf < total then break end
        local payload = self._buf:sub(nl + 1, total)
        self._buf = self._buf:sub(total + 1)
        local ok, msg = pcall(vim.json.decode, payload)
        if not ok or type(msg) ~= "table" or type(msg.kind) ~= "string" then
            return nil, "malformed message"
        end
        out[#out + 1] = msg
    end
    return out
end

M.Decoder = Decoder

return M
