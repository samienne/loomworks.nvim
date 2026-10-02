--- loomworks/daemon/client.lua — connect to a workspace daemon and authenticate
--- (spec §19.8), then send control requests.
---
--- The endpoint comes from the handle (clients never compute it). The client
--- sends `hello`, verifies the daemon's `server_proof` BEFORE sending anything
--- else — a process squatting the endpoint cannot prove knowledge of K, and
--- the client then closes and reports the endpoint as untrusted — answers
--- with its own proof, and waits for `welcome`.
---
--- Transport is a libuv pipe on both hosts. `connect` is asynchronous; the
--- `session` / `call` wrappers pump the event loop with `vim.wait` (the CLI).

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local auth = require("loomworks.daemon.auth")
local version = require("loomworks.daemon.version")

local M = {}

--- Handshake / request timeout.
M.TIMEOUT_MS = 5000

--- Errors a caller distinguishes.
M.ERR_UNTRUSTED = "untrusted"   -- the server's proof did not verify
M.ERR_CONNECT = "connect"       -- nothing accepted the connection
M.ERR_TIMEOUT = "timeout"       -- no answer in time
M.ERR_CLOSED = "closed"         -- the daemon closed the connection

--- @class loomworks.daemon.Conn
--- @field pipe userdata
--- @field challenge table the daemon's announced versions (protocol, lw_version, schemas, session_generation)
--- @field welcome table
--- @field closed boolean|nil
--- @field on_close fun(conn: loomworks.daemon.Conn)|nil called once when the connection closes
---   after it was established (either side; runs in a libuv callback)
local Conn = {}
Conn.__index = Conn

--- Send a request; `cb(reply|nil, err)` on its reply.
--- @param msg table
--- @param cb fun(reply: table|nil, err: string|nil)
function Conn:request(msg, cb)
    if self.closed then return cb(nil, M.ERR_CLOSED) end
    self._next = (self._next or 0) + 1
    msg.req_id = self._next
    self._pending[msg.req_id] = cb
    pcall(function() self.pipe:write(protocol.encode(msg)) end)
end

--- Stop reading from the daemon (test seam: a client blocked writing a
--- paused terminal stops reading its connection the same way).
function Conn:pause_reading()
    if self.closed or not self._reader then return end
    pcall(function() self.pipe:read_stop() end)
end

--- Read again after `pause_reading`.
function Conn:resume_reading()
    if self.closed or not self._reader then return end
    pcall(function() self.pipe:read_start(self._reader) end)
end

--- Close the connection (idempotent).
function Conn:close()
    if self.closed then return end
    self.closed = true
    pcall(function() if not self.pipe:is_closing() then self.pipe:close() end end)
    local p = self._pending
    self._pending = {}
    for _, cb in pairs(p) do pcall(cb, nil, M.ERR_CLOSED) end
    if self.on_close then pcall(self.on_close, self) end
end

--- Connect to `endpoint` and authenticate. `cb(conn|nil, err, detail)`.
--- opts: { client = "cli"|"editor", role = "observer"|nil (§19.16), timeout_ms,
---         key (tests: K override), on_message = fun(msg) for broadcasts,
---         on_close = fun(conn) once an established connection closes }
--- @param endpoint string
--- @param opts table|nil
--- @param cb fun(conn: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
function M.connect(endpoint, opts, cb)
    opts = opts or {}
    local key, kerr = opts.key, nil
    if not key then key, kerr = auth.key() end
    if not key then return cb(nil, M.ERR_CONNECT, kerr) end
    local nc = auth.nonce()
    if not nc then return cb(nil, M.ERR_CONNECT, "no random source") end
    -- Built before going asynchronous: the editor host forbids vim.fn (the
    -- version fingerprint's sha256) inside libuv callbacks.
    local hello = protocol.encode({ kind = protocol.KIND.hello, protocol = protocol.VERSION,
        lw_version = version.identity(), schemas = version.schemas(),
        client = opts.client or "cli", role = opts.role, nonce = nc })
    local pipe = uv.new_pipe(false)
    local conn = setmetatable({ pipe = pipe, _pending = {}, endpoint = endpoint }, Conn)
    local done = false
    local timer = uv.new_timer()
    local function finish(c, err, detail)
        if done then return end
        done = true
        pcall(function() timer:stop(); timer:close() end)
        if not c then conn:close() end
        cb(c, err, detail)
    end
    timer:start(opts.timeout_ms or M.TIMEOUT_MS, 0, function() finish(nil, M.ERR_TIMEOUT) end)
    local decoder = protocol.new_decoder(protocol.MAX_FRAME)
    local state = "hello"
    local ok_c = pcall(function()
        pipe:connect(endpoint, function(cerr)
            if cerr then return finish(nil, M.ERR_CONNECT, tostring(cerr)) end
            conn._reader = function(rerr, chunk)
                if rerr or not chunk then
                    if not done then return finish(nil, M.ERR_CLOSED) end
                    return conn:close()
                end
                local msgs, derr = decoder:push(chunk)
                if not msgs then
                    if not done then return finish(nil, M.ERR_CLOSED, derr) end
                    return conn:close()
                end
                for _, msg in ipairs(msgs) do
                    if state == "hello" then
                        if msg.kind ~= protocol.KIND.challenge or not auth.valid_nonce(msg.server_nonce)
                            or not auth.equal(msg.server_proof,
                                auth.server_proof(key, endpoint, nc, msg.server_nonce)) then
                            -- Close without sending anything else (§19.8).
                            return finish(nil, M.ERR_UNTRUSTED)
                        end
                        conn.challenge = msg
                        state = "auth"
                        pcall(function()
                            pipe:write(protocol.encode({ kind = protocol.KIND.auth,
                                client_proof = auth.client_proof(key, endpoint, nc, msg.server_nonce) }))
                        end)
                    elseif state == "auth" then
                        if msg.kind ~= protocol.KIND.welcome then return finish(nil, M.ERR_CLOSED) end
                        conn.welcome = msg
                        conn.on_close = opts.on_close
                        state = "ready"
                        finish(conn)
                    else
                        local p = msg.req_id and conn._pending[msg.req_id]
                        if p then
                            conn._pending[msg.req_id] = nil
                            if msg.kind == protocol.KIND.error then p(nil, tostring(msg.error)) else p(msg) end
                        elseif opts.on_message then
                            pcall(opts.on_message, msg)
                        end
                    end
                end
            end
            pipe:read_start(conn._reader)
            pcall(function() pipe:write(hello) end)
        end)
    end)
    if not ok_c then finish(nil, M.ERR_CONNECT, "bad endpoint") end
end

--- Connect synchronously (pumping the event loop). Returns the conn, or nil
--- + error + detail.
--- @param endpoint string
--- @param opts? table as for `connect`
--- @return loomworks.daemon.Conn|nil, string|nil, string|nil
function M.session(endpoint, opts)
    local res
    M.connect(endpoint, opts, function(c, e, d) res = { c, e, d } end)
    -- The connect callback reports a timeout itself; the extra margin only
    -- covers its own scheduling.
    vim.wait((opts and opts.timeout_ms or M.TIMEOUT_MS) + 200, function() return res ~= nil end, 5)
    if not res then return nil, M.ERR_TIMEOUT end
    return res[1], res[2], res[3]
end

--- Send one request on an open conn synchronously. Returns the reply, or nil
--- + error.
--- @param conn loomworks.daemon.Conn
--- @param msg table
--- @param timeout_ms? integer
--- @return table|nil reply, string|nil err
function M.request(conn, msg, timeout_ms)
    local res
    conn:request(msg, function(r, e) res = { r, e } end)
    vim.wait(timeout_ms or M.TIMEOUT_MS, function() return res ~= nil end, 5)
    if not res then return nil, M.ERR_TIMEOUT end
    return res[1], res[2]
end

--- Connect, send one request, close. Returns (reply|nil, err, conn_info) —
--- conn_info is the daemon's challenge (its versions) when the handshake
--- got that far.
--- @param endpoint string
--- @param kind string
--- @param opts? table
--- @return table|nil, string|nil, table|nil
function M.call(endpoint, kind, opts)
    local conn, err, detail = M.session(endpoint, opts)
    if not conn then return nil, err .. (detail and (": " .. detail) or "") end
    local reply, rerr = M.request(conn, { kind = kind }, opts and opts.timeout_ms)
    local info = conn.challenge
    conn:close()
    return reply, rerr, info
end

return M
