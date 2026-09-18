--- loomworks/daemon/protocol.lua — the daemon wire protocol (Phase 0 surface).
---
--- The daemon and its clients are shipped at *independently-chosen* versions
--- (a released `lw` daemon driven by an editor at a different version), so the
--- wire protocol is versioned as a **supported range** `MIN_SUPPORTED..VERSION`
--- and a peer is accepted when its version falls inside the local range. This is
--- deliberately unlike the strict-equality module/SDK doctrine in
--- `api_versions.lua` (both sides built together there); see DAEMON.md §5.3.
---
--- Framing: each message is a compact-JSON payload prefixed by its byte length
--- and a newline — `"<len>\n<payload>"`. `vim.json.encode` emits no embedded
--- newlines, but the length prefix keeps framing robust regardless. A streaming
--- `Decoder` buffers partial reads off the pipe and yields whole payloads.
---
--- Phase 0 uses only a tiny slice of this: the client stub connects and sends a
--- `shutdown` request, reads one reply. The handshake (`hello`/`welcome`) and
--- the model/task broadcast kinds (DAEMON.md §3) land with the daemon server in
--- Phase 1; the message-kind constants are declared here so both lines agree on
--- the vocabulary.

local M = {}

--- Current wire protocol version implemented by this build.
M.VERSION = 1

--- Oldest peer protocol version this build can still talk to. A peer whose
--- version is within `MIN_SUPPORTED..VERSION` is compatible (DAEMON.md §5.3).
M.MIN_SUPPORTED = 1

--- Message kinds. Phase 0 exercises only `shutdown` / `ok` / `error`; the rest
--- are reserved so the branch and mainline share one vocabulary (DAEMON.md §3).
M.KIND = {
    -- handshake (§4)
    hello = "hello",
    welcome = "welcome",
    -- lifecycle command
    shutdown = "shutdown",
    -- replies
    ok = "ok",
    error = "error",
    -- broadcasts (§3.3 / §3.4) — reserved, unused in Phase 0
    model_change = "model_change",
    task = "task",
    notify = "notify",
}

--- Is a peer's protocol version compatible with this build's supported range?
--- @param peer_version integer|nil
--- @return boolean
function M.compatible(peer_version)
    if type(peer_version) ~= "number" then return false end
    return peer_version >= M.MIN_SUPPORTED and peer_version <= M.VERSION
end

--- Frame a payload string for the wire: length header + newline + payload.
--- @param payload string
--- @return string
function M.frame(payload)
    return tostring(#payload) .. "\n" .. payload
end

--- Encode a message table to a framed wire string.
--- @param msg table
--- @return string
function M.encode(msg)
    return M.frame(vim.json.encode(msg))
end

--- Decode a single payload string into a message table.
--- @param payload string
--- @return table|nil msg, string|nil err
function M.decode(payload)
    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok or type(decoded) ~= "table" then
        return nil, "malformed message"
    end
    return decoded, nil
end

--- @class loomworks.daemon.Decoder
--- @field _buf string bytes received but not yet framed
local Decoder = {}
Decoder.__index = Decoder

--- Create a streaming frame decoder.
--- @return loomworks.daemon.Decoder
function M.new_decoder()
    return setmetatable({ _buf = "" }, Decoder)
end

--- Push a chunk of bytes; return an array of any complete payload strings that
--- became available (may be empty). Partial trailing bytes are buffered.
--- @param chunk string
--- @return string[] payloads
function Decoder:push(chunk)
    self._buf = self._buf .. chunk
    local out = {}
    while true do
        local nl = self._buf:find("\n", 1, true)
        if not nl then break end
        local len = tonumber(self._buf:sub(1, nl - 1))
        if not len then
            -- Corrupt header; drop the buffer to avoid a wedged stream.
            self._buf = ""
            break
        end
        local total = nl + len
        if #self._buf < total then break end -- payload not fully arrived yet
        out[#out + 1] = self._buf:sub(nl + 1, total)
        self._buf = self._buf:sub(total + 1)
    end
    return out
end

M.Decoder = Decoder

return M
