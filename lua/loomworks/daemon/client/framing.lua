--- loomworks/daemon/client/framing.lua — the editor's side of the frozen
--- framing of the daemon wire protocol (spec/protocol/PROTOCOL.md): what the
--- relay client needs to send `hello` and read the replies.
---
--- A message is a JSON object prefixed by its decimal byte length and a
--- newline: `<len>\n<json>`. The decoder enforces the frame cap on the
--- LENGTH PREFIX, before any payload is buffered. This framing and the
--- message kinds below belong to the frozen control subset: they never change
--- shape across versions.

local M = {}

--- Frame cap after authentication (the relay forwards an authenticated
--- connection: the editor never sees a pre-authentication frame).
M.MAX_FRAME = 16 * 1024 * 1024

--- The frozen message kinds the editor's relay client sends or reads.
M.KIND = {
    hello = "hello",
    welcome = "welcome",
    error = "error",
}

--- Encode a message table as a frame.
--- @param msg table
--- @return string
function M.encode(msg)
    local payload = vim.json.encode(msg)
    return tostring(#payload) .. "\n" .. payload
end

--- @class loomworks.daemon.client.Decoder
--- @field _buf string
--- @field max integer the frame cap
local Decoder = {}
Decoder.__index = Decoder

--- @param max integer the frame cap
--- @return loomworks.daemon.client.Decoder
function M.new_decoder(max)
    return setmetatable({ _buf = "", max = max }, Decoder)
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

return M
