--- loomworks/daemon/server.lua — the daemon run loop (spec §19.2, §19.6–§19.11).
---
--- `lw daemon run` creates one `Server` for its workspace and starts it:
---
---   1. acquire the runtime lock R (§19.2) — held by a live or hung holder:
---      exit without side effects (`EXIT_HELD`), the launching client then
---      connects to that one; a dead holder's lock is reclaimed and its stale
---      handle removed;
---   2. bind the endpoint (§19.7, owner-only; Windows DACL) and publish the
---      handle (§19.6);
---   3. serve: every connection must authenticate first (§19.8 — only
---      `hello` / `auth`, 64 KiB frame cap, ~5 s, no broadcast before
---      `welcome`); then the frozen control requests `ping`, `status`, `stop`,
---      `retire` (nothing else is routed in step 2 of §19.19);
---   4. heartbeat (about 5 s): R's own timer refreshes the lock; the server
---      refreshes the handle (rewriting it if it was removed) and checks that
---      R still carries its record — a replaced record means the lock was
---      reclaimed while this process was suspended: it exits at once, nonzero,
---      touching no workspace file (§19.2).
---
--- Every exit (stop request, lost lock, and — §19.11 — idle, root removed)
--- cancels running work, closes the clients and the endpoint, removes the
--- handle and (POSIX) the socket while still holding R, releases R, and ENDS
--- THE PROCESS through `opts.exit` (default `os.exit`) — no timer or handle
--- may keep it alive (DAEMON.md §6: daemons that never exited).
---
--- Host-neutral: `start()` returns at once; the CLI then pumps the event loop
--- until the process exits. Tests drive a server in-process with an injected
--- `exit`.

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local auth = require("loomworks.daemon.auth")
local endpoint = require("loomworks.daemon.endpoint")
local handle = require("loomworks.daemon.handle")
local rlock = require("loomworks.daemon.rlock")
local version = require("loomworks.daemon.version")
local lock_record = require("loomworks.lock_record")

local M = {}

--- Exit status of a daemon that found the runtime lock held (§19.10: the
--- launching client connects to the holder instead of failing).
M.EXIT_HELD = 3

--- Heartbeat period of the handle / lost-lock check.
M.TICK_MS = 5000
--- An unauthenticated connection is closed after this long (§19.8).
M.AUTH_TIMEOUT_MS = 5000

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- @class loomworks.daemon.Server
local Server = {}
Server.__index = Server

--- @param root string workspace root
--- @param opts? { exit?: fun(code: integer), tick_ms?: integer, auth_timeout_ms?: integer, log?: fun(line: string), idle_seconds?: number, keepalive_ms?: integer }
--- @return loomworks.daemon.Server
function M.new(root, opts)
    opts = opts or {}
    local self = setmetatable({}, Server)
    self.root = require("loomworks.daemon.paths").norm_root(root)
    self.opts = opts
    self.pid = lock_record.this_pid()
    self.start_time = require("loomworks.proc").self_start_time()
    self.generation = os.time() * 1000 + math.random(0, 999)
    self.started_at = os.time()
    self.idle_since = os.time()
    self.last_request = os.time()
    self.tick_ms = opts.tick_ms or env_ms("LW_TEST_DAEMON_TICK_MS") or M.TICK_MS
    -- Test seam (the lock helpers' too): a faster heartbeat of R.
    local hb = env_ms("LW_TEST_HEARTBEAT_MS")
    if hb then require("loomworks.build_lock").HEARTBEAT_MS = hb end
    self.auth_timeout_ms = opts.auth_timeout_ms or env_ms("LW_TEST_DAEMON_AUTH_MS") or M.AUTH_TIMEOUT_MS
    self.conns = {}
    self.n_clients = 0
    self.busy = false
    self.retiring = false
    self.stopped = false
    self.exit = opts.exit or function(code)
        pcall(function() io.stdout:flush() end)
        os.exit(code)
    end
    return self
end

--- Log a line (the runtime log, §19.10, when the host gave one).
function Server:log(fmt, ...)
    if self.opts.log then pcall(self.opts.log, string.format(fmt, ...)) end
end

--- The handle record this daemon publishes.
function Server:_handle_record()
    return {
        pid = self.pid,
        host = lock_record.this_host(),
        os = (jit and jit.os) or "?",
        start_time = self.start_time,
        endpoint = self.address,
        protocol = protocol.VERSION,
        lw_version = self.identity or version.identity(),
        schemas = self.schemas or version.schemas(),
        session_generation = self.generation,
        started_at = self.started_at,
        clients = self.n_clients,
        busy = self.busy,
        idle_since = (self.n_clients == 0 and not self.busy) and self.idle_since or nil,
        lock_nonce = self.R and self.R.record and self.R.record.lock_nonce or nil,
    }
end

--- Rewrite the handle soon (client count changed): coalesced on a 0 ms
--- timer so a slow filesystem (a virus scanner holding the staged file)
--- never delays a handshake or a reply.
function Server:_handle_changed()
    if self.stopped or self._handle_pending then return end
    self._handle_pending = true
    local t = uv.new_timer()
    t:start(0, 0, function()
        pcall(function() t:close() end)
        self._handle_pending = false
        self:_write_handle()
    end)
end

function Server:_write_handle()
    if self.stopped or not self.address then return end
    local ok, err = handle.write(self.root, self:_handle_record())
    if not ok then self:log("could not write the handle: %s", tostring(err)) end
end

--- Start serving. Returns true, or nil + message + exit status (EXIT_HELD
--- when another runtime holds the lock).
--- @return boolean|nil ok, string|nil err, integer|nil code
function Server:start()
    lock_record.set_holder_kind("daemon")
    -- Computed here, outside any libuv callback: the editor host forbids
    -- vim.fn (the fingerprint's sha256) in fast callbacks.
    self.identity = version.identity()
    self.schemas = version.schemas()
    local st = uv.fs_stat(self.root)
    if not st or st.type ~= "directory" then
        return nil, "workspace root " .. self.root .. " does not exist", 1
    end
    local R, holder = rlock.try_acquire(self.root)
    if not R then
        holder = holder or {}
        return nil, string.format("the runtime lock is held by %s (pid %s on %s, %s)",
            rlock.holder_text(holder), tostring(holder.pid or "?"), tostring(holder.host or "?"),
            tostring(holder.state or "?")), M.EXIT_HELD
    end
    self.R = R
    if R.reclaimed then
        self:log("reclaimed the runtime lock of %s (pid %s, %s)", rlock.holder_text(R.reclaimed),
            tostring(R.reclaimed.pid), tostring(R.reclaimed.state))
    end
    -- Holding R, any handle present is a predecessor's (stale): remove it.
    handle.remove(self.root)
    local key, kerr = auth.key()
    if not key then
        rlock.release(R)
        return nil, "no machine key for authentication: " .. tostring(kerr), 1
    end
    self.key = key
    local server, addr = endpoint.listen(self.root, function(err) self:_guard(self._on_connection, err) end)
    if not server then
        rlock.release(R)
        return nil, addr, 1
    end
    self.listener, self.address = server, addr
    self.candidates = endpoint._posix_candidates(self.root)
    self:_write_handle()
    self.timer = uv.new_timer()
    self.timer:start(self.tick_ms, self.tick_ms, function() self:_guard(self._tick) end)
    if package.config:sub(1, 1) ~= "\\" and uv.new_signal then
        pcall(function()
            self.sigterm = uv.new_signal()
            self.sigterm:start("sigterm", function() self:stop("terminated", 0) end)
        end)
    end
    self:log("daemon pid %d serving %s on %s (lw %s, protocol %d)", self.pid, self.root, addr,
        self.identity, protocol.VERSION)
    return true
end

--- Run a callback of the event loop; a Lua error in it is fatal for the
--- daemon but still takes the stop path (handle and socket removed, the
--- runtime lock released, the process ended) — never a daemon that keeps R
--- while its loop is broken.
function Server:_guard(fn, ...)
    local ok, err = pcall(fn, self, ...)
    if ok then return end
    self:log("internal error: %s", tostring(err))
    if not self.stopped then pcall(self.stop, self, "internal error: " .. tostring(err), 1) end
end

--- The heartbeat (§19.2, §19.6; lifetime checks of §19.11 via `lifetime`).
function Server:_tick()
    if self.stopped then return end
    if not rlock.still_ours(self.R) then
        return self:_lost_lock()
    end
    if not handle.touch(self.root) then self:_write_handle() end
    if self.lifetime then self:lifetime() end
end

--- R was reclaimed or removed while this process held it: it has lost
--- authority — stop at once, write nothing, exit nonzero (§19.2).
function Server:_lost_lock()
    if self.stopped then return end
    self.stopped = true
    self:log("the runtime lock was taken over; exiting without touching the workspace")
    for conn in pairs(self.conns) do pcall(function() conn.sock:close() end) end
    self.conns = {}
    for _, h in ipairs({ self.timer, self.sigterm, self.listener }) do
        pcall(function() if not h:is_closing() then h:close() end end)
    end
    if self.R then self.R.released = true; pcall(function() self.R.timer:stop(); self.R.timer:close() end) end
    self.exit(1)
end

--- Stop: close clients and the endpoint, remove the handle and socket while
--- still holding R, release R, end the process (§19.11). Idempotent.
--- @param reason string
--- @param code? integer exit status (default 0)
function Server:stop(reason, code)
    if self.stopped then return end
    self.stopped = true
    self:log("stopping: %s", tostring(reason))
    for conn in pairs(self.conns) do pcall(function() if not conn.sock:is_closing() then conn.sock:close() end end) end
    self.conns = {}
    for _, h in ipairs({ self.timer, self.sigterm, self.listener }) do
        pcall(function() if h and not h:is_closing() then h:close() end end)
    end
    if rlock.still_ours(self.R) then
        handle.remove(self.root, { pid = self.pid, start_time = self.start_time })
        endpoint.cleanup(self.root, self.address, self.candidates)
    end
    rlock.release(self.R)
    self.exit(code or 0)
end

-- ---------------------------------------------------------------------------
-- Connections
-- ---------------------------------------------------------------------------

function Server:_send(conn, msg, cb)
    if conn.closed or conn.sock:is_closing() then return end
    pcall(function() conn.sock:write(protocol.encode(msg), cb) end)
end

function Server:_close(conn, why)
    if conn.closed then return end
    conn.closed = true
    if conn.auth_timer then pcall(function() conn.auth_timer:stop(); conn.auth_timer:close() end) end
    pcall(function() if not conn.sock:is_closing() then conn.sock:close() end end)
    self.conns[conn] = nil
    if why then self:log("closed a connection: %s", why) end
    if conn.authed then
        self.n_clients = self.n_clients - 1
        if self.n_clients == 0 then self.idle_since = os.time() end
        self:_handle_changed()
        if self.retiring and self.n_clients == 0 and not self.busy then
            self:stop("retired (idle after a version mismatch)", 0)
        end
    end
end

function Server:_on_connection(err)
    if err or self.stopped then return end
    local sock = uv.new_pipe(false)
    if not pcall(function() assert(self.listener:accept(sock) == 0) end) then
        pcall(function() sock:close() end)
        return
    end
    local conn = { sock = sock, decoder = protocol.new_decoder(protocol.PREAUTH_MAX), state = "new",
        last_seen = uv.now() }
    self.conns[conn] = true
    conn.auth_timer = uv.new_timer()
    conn.auth_timer:start(self.auth_timeout_ms, 0, function()
        if not conn.authed then self:_close(conn, "not authenticated in time") end
    end)
    sock:read_start(function(rerr, chunk)
        local ok, err = pcall(self._on_read, self, conn, rerr, chunk)
        if not ok then
            self:log("internal error on a connection: %s", tostring(err))
            pcall(self._close, self, conn)
        end
    end)
end

--- Bytes (or EOF / an error) arrived on a connection.
function Server:_on_read(conn, rerr, chunk)
    do
        if rerr or not chunk then return self:_close(conn) end
        conn.last_seen = uv.now()
        local msgs, derr = conn.decoder:push(chunk)
        if not msgs then
            -- Before authentication: closed with no detail (§19.8).
            if conn.authed then self:_send(conn, { kind = protocol.KIND.error, error = derr }) end
            return self:_close(conn, derr)
        end
        for _, msg in ipairs(msgs) do
            if conn.closed then return end
            if conn.authed then
                self:_dispatch(conn, msg)
            else
                self:_handshake(conn, msg)
            end
        end
    end
end

--- The pre-authentication state machine: only `hello`, then `auth`.
function Server:_handshake(conn, msg)
    local K = protocol.KIND
    if conn.state == "new" and msg.kind == K.hello and auth.valid_nonce(msg.nonce) then
        local ns = auth.nonce()
        if not ns then return self:_close(conn, "no random source") end
        conn.nc, conn.ns, conn.state = msg.nonce, ns, "challenged"
        conn.peer = { protocol = msg.protocol, lw_version = msg.lw_version, schemas = msg.schemas,
            client = msg.client }
        self:_send(conn, {
            kind = K.challenge, protocol = protocol.VERSION, lw_version = self.identity,
            schemas = self.schemas, session_generation = self.generation,
            server_nonce = ns, server_proof = auth.server_proof(self.key, self.address, conn.nc, ns),
        })
        return
    end
    if conn.state == "challenged" and msg.kind == K.auth
        and auth.equal(msg.client_proof, auth.client_proof(self.key, self.address, conn.nc, conn.ns)) then
        conn.authed, conn.state = true, "authed"
        conn.decoder.max = protocol.MAX_FRAME
        pcall(function() conn.auth_timer:stop(); conn.auth_timer:close() end)
        conn.auth_timer = nil
        self.n_clients = self.n_clients + 1
        self.last_request = os.time()
        self:_send(conn, {
            kind = K.welcome, seq = 0, clients = self.n_clients, busy = self.busy,
            header = { root = self.root, pid = self.pid, lw_version = self.identity,
                session_generation = self.generation },
        })
        self:_handle_changed()
        return
    end
    -- Anything else before authentication, or a failed proof: closed, no detail.
    self:_close(conn, "authentication failed")
end

--- The status a `status` request returns (frozen shape: only additions).
function Server:status()
    local r = self:_handle_record()
    r.root = self.root
    r.retiring = self.retiring
    return r
end

--- Authenticated requests: the frozen control subset.
--- An authenticated request: a handler error is a typed error reply (§19.8),
--- never a crash.
function Server:_dispatch(conn, msg)
    local ok, err = pcall(self._dispatch_request, self, conn, msg)
    if not ok then
        self:log("handler error for %s: %s", tostring(msg.kind), tostring(err))
        self:_send(conn, { kind = protocol.KIND.error, req_id = msg.req_id, error = "internal error" })
    end
end

function Server:_dispatch_request(conn, msg)
    local K = protocol.KIND
    self.last_request = os.time()
    local function reply(fields, cb)
        fields = fields or {}
        fields.kind = fields.kind or K.ok
        fields.req_id = msg.req_id
        self:_send(conn, fields, cb)
    end
    if msg.kind == K.ping then
        return reply({})
    elseif msg.kind == K.status then
        local st = self:status()
        st.kind = K.ok
        return reply(st)
    elseif msg.kind == K.stop then
        return reply({}, function() self:stop("stop requested", 0) end)
    elseif msg.kind == K.retire then
        self.retiring = true
        self:log("retiring: a client of another version asked; exits when idle")
        return reply({})
    end
    reply({ kind = K.error, error = "unknown request kind: " .. tostring(msg.kind) })
end

--- Authenticated client count (tests).
function Server:client_count() return self.n_clients end

M.Server = Server
return M
