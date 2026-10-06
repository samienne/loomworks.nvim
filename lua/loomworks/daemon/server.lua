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
---      `welcome`, which lists the objects, §19.20); then, through one
---      dispatch table (`M.DISPATCH`), the frozen control requests `ping`,
---      `status`, `stop`, `retire`, the interface envelope's `call` (the
---      registry loomworks.daemon.interfaces, with the root object `/`), and
---      — with a build service attached (`lw daemon run`,
---      loomworks.daemon.service) — the protocol-10 request kinds as v0
---      aliases (§19.8, §19.15);
---   4. heartbeat (about 5 s): R's own timer refreshes the lock; the server
---      refreshes the handle (rewriting it if it was removed) and checks that
---      R still carries its record — a replaced record means the lock was
---      reclaimed while this process was suspended: it exits at once, nonzero,
---      touching no workspace file (§19.2).
---
--- Broadcasts (§19.11, §19.12, §19.16): `model_change { seq,
--- session_generation }` to every authenticated client after each committed
--- write of a state file (`model_changed`, called by the build service), and
--- `retiring` to OBSERVER connections (hello `role = "observer"`, the editor)
--- when the daemon is retired — observers then disconnect, and never hold off
--- the retirement (`active_clients` excludes them).
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

--- `stop_reason` of a runtime whose lock was taken over (§19.2), and of one
--- whose workspace root was removed (§19.11).
M.LOST_LOCK = "the runtime lock was taken over"
M.ROOT_REMOVED = "the workspace root was removed"

--- Heartbeat period of the handle / lost-lock / lifetime checks.
M.TICK_MS = 5000
--- Keepalive interval (§19.11): a connection silent for three is dropped.
M.KEEPALIVE_MS = 30000
--- Idle timeout default (§19.11, setting `daemon-idle-timeout`).
M.IDLE_SECONDS = 3600
--- An unauthenticated connection is closed after this long (§19.8).
M.AUTH_TIMEOUT_MS = 5000

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- @class loomworks.daemon.Server
--- @field attached boolean|nil an attached runtime (§19.1): no endpoint, handle or idle stop
--- @field exit_code integer|nil an attached runtime's exit status, recorded when it stopped
--- @field stop_reason string|nil why it stopped (`LOST_LOCK`, `ROOT_REMOVED`, or the `stop` reason)
--- @field interfaces loomworks.daemon.Registry|nil the interface registry with the root object (§19.20), created on start
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
    self.keepalive_ms = opts.keepalive_ms or env_ms("LW_TEST_DAEMON_KEEPALIVE_MS") or M.KEEPALIVE_MS
    self.idle_seconds = opts.idle_seconds or M.IDLE_SECONDS
    self.conns = {}
    self.n_clients = 0
    self.seq = 0
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
        -- Which data directory's key this daemon authenticates with (§19.6).
        key_id = self.key and auth.key_id(self.key) or nil,
        -- The executable this daemon runs (display only: the editor's
        -- version-mismatch note names it, §19.16).
        exe = self:_exe(),
    }
end

--- This daemon's executable path (forward slashes), nil when unknown.
function Server:_exe()
    if self._exe_path == nil then
        local uv = vim.uv or vim.loop
        local ok, exe = pcall(uv.exepath)
        self._exe_path = (ok and type(exe) == "string" and exe ~= "") and exe:gsub("\\", "/") or false
    end
    return self._exe_path or nil
end

--- The handle rewrite (§19.6): how long one rewrite may retry a rename that
--- a reader blocks while the loop waits (ms), the backoff of the later
--- retries (ms; the last value repeats until it succeeds), and how long it
--- may keep failing before the runtime log says so (ms).
M.HANDLE_SYNC_MS = 250
M.HANDLE_RETRY_MS = { 50, 100, 250, 500, 1000 }
M.HANDLE_LOG_AFTER_MS = 5000

--- Rewrite the handle in `delay_ms` (default 0): coalesced on one timer so a
--- slow filesystem (a virus scanner holding the staged file) never delays a
--- handshake or a reply; the rewrite publishes the record as it is then.
--- @param delay_ms? integer
function Server:_handle_changed(delay_ms)
    if self.stopped or self.attached or self._handle_pending then return end
    self._handle_pending = true
    local t = uv.new_timer()
    t:start(delay_ms or 0, 0, function()
        pcall(function() t:close() end)
        self._handle_pending = false
        self:_guard(self._write_handle)
    end)
end

--- Publish the handle record (§19.6). Skipped when this daemon last wrote
--- exactly this record and the file is still there (the heartbeat refreshes
--- its time): every rewrite is a rename a reader can block. A rename a
--- reader keeps blocking (Windows) is retried for HANDLE_SYNC_MS, then again
--- on a backoff (HANDLE_RETRY_MS) and on every heartbeat until it succeeds:
--- clients never keep reading an outdated record because one rewrite lost
--- the race. The runtime log says so once when it has failed for
--- HANDLE_LOG_AFTER_MS (at once for an error a retry cannot cure).
--- @return boolean|nil written (nil while it is failing)
function Server:_write_handle()
    if self.stopped or not self.address then return nil end
    local rec = self:_handle_record()
    local data = handle.encode(rec)
    if data == self._handle_data and not self._handle_dirty
            and uv.fs_stat(require("loomworks.daemon.paths").handle_path(self.root)) then
        return true
    end
    local ok, err, code = handle.write(self.root, rec, { budget_ms = M.HANDLE_SYNC_MS })
    uv.update_time()
    if ok then
        if self._handle_logged then
            self:log("wrote the handle after %d ms of failures", uv.now() - self._handle_failing_since)
        end
        self._handle_data, self._handle_dirty = data, false
        self._handle_failing_since, self._handle_logged, self._handle_retries = nil, nil, 0
        return true
    end
    self._handle_dirty = true
    self._handle_failing_since = self._handle_failing_since or uv.now()
    self._handle_retries = (self._handle_retries or 0) + 1
    local transient = handle.transient(code)
    if not self._handle_logged
            and (not transient or uv.now() - self._handle_failing_since >= M.HANDLE_LOG_AFTER_MS) then
        self._handle_logged = true
        self:log("could not write the handle: %s (retrying)", tostring(err))
    end
    self:_handle_changed(M.HANDLE_RETRY_MS[math.min(self._handle_retries, #M.HANDLE_RETRY_MS)])
    return nil
end

--- The part of starting both runtimes share (§19.1, §19.2): the versions
--- computed, the root checked, R acquired in `mode` (a predecessor's stale
--- handle removed). Returns true, or nil + message + exit status (EXIT_HELD
--- when another runtime holds the lock).
--- @param lock_opts { mode?: string, command?: string }
--- @return boolean|nil ok, string|nil err, integer|nil code
function Server:_acquire(lock_opts)
    -- Computed here, outside any libuv callback: the editor host forbids
    -- vim.fn (the fingerprint's sha256) in fast callbacks.
    self.identity = version.identity()
    self.schemas = version.schemas()
    -- The interface registry with the root object (§19.20); its schema
    -- digests are computed here too, outside any callback.
    self:registry()
    local st = uv.fs_stat(self.root)
    if not st or st.type ~= "directory" then
        return nil, "workspace root " .. self.root .. " does not exist", 1
    end
    local R, holder = rlock.try_acquire(self.root, lock_opts)
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
    return true
end

--- Start the heartbeat timer (§19.2).
function Server:_start_tick()
    self.timer = uv.new_timer()
    self.timer:start(self.tick_ms, self.tick_ms, function() self:_guard(self._tick) end)
end

--- Start serving. Returns true, or nil + message + exit status (EXIT_HELD
--- when another runtime holds the lock).
--- @return boolean|nil ok, string|nil err, integer|nil code
function Server:start()
    lock_record.set_holder_kind("daemon")
    local aok, aerr, acode = self:_acquire({ mode = "daemon" })
    if not aok then return nil, aerr, acode end
    local R = self.R
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
    -- The socket file this daemon bound (POSIX): removed on exit only while
    -- it is still that file.
    local sst = uv.fs_lstat(addr)
    self.sock_ino = sst and sst.type == "socket" and sst.ino or nil
    self:_write_handle()
    self:_start_tick()
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

--- Start an attached runtime (§19.1 "Loopback"): the daemon's code inside
--- the client process for the length of one command. R is held in `attached`
--- mode with the command; there is no endpoint, no authentication key, no
--- handle and no idle stop — its clients are loopback connections handed to
--- `adopt`. Its tick only checks that the root still exists and R is still
--- its own. `stop` (and a lost R) release R and return to the caller: unless
--- the host injected `opts.exit`, the exit status is only recorded
--- (`exit_code`), never `os.exit`. Returns true, or nil + message + exit
--- status (EXIT_HELD when another runtime holds the lock).
--- @param opts { command: string }
--- @return boolean|nil ok, string|nil err, integer|nil code
function Server:start_attached(opts)
    opts = opts or {}
    self.attached = true
    if not self.opts.exit then
        self.exit = function(code) self.exit_code = code end
    end
    local aok, aerr, acode = self:_acquire({ mode = "attached", command = opts.command })
    if not aok then return nil, aerr, acode end
    self:_start_tick()
    self:log("attached run of %s (pid %d) on %s (lw %s, protocol %d)", tostring(opts.command), self.pid,
        self.root, self.identity, protocol.VERSION)
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
    -- Root removed (§19.11): checked first — its lock went with it.
    local rst = uv.fs_stat(self.root)
    if not rst or rst.type ~= "directory" then
        return self:stop(M.ROOT_REMOVED, 0)
    end
    if not rlock.still_ours(self.R) then
        return self:_lost_lock()
    end
    -- An attached runtime publishes no handle and never stops for idleness:
    -- it ends with its command (§19.1).
    if self.attached then return end
    -- The heartbeat keeps the published handle fresh even while a rewrite is
    -- still failing; a failing rewrite (or a removed handle) is retried here.
    local touched = handle.touch(self.root)
    if self._handle_dirty or not touched then self:_write_handle() end
    self:lifetime()
end

--- The lifetime rules of §19.11 checked on every tick: a connection silent
--- for three keepalive intervals is dropped as half-open; with no connection,
--- no running task and no request for the idle timeout, the daemon exits.
function Server:lifetime()
    local now = uv.now()
    for conn in pairs(self.conns) do
        -- A connection that owns a running operation is its terminal: it is
        -- never dropped for silence (its client pings anyway, §19.15).
        if conn.authed and now - conn.last_seen > 3 * self.keepalive_ms
                and not (self.service and self.service:owns_task(conn)) then
            self:_close(conn, "silent for three keepalive intervals")
        end
    end
    if self.stopped then return end
    -- Idle only with no connection at all: one still authenticating (bounded
    -- by the authentication timeout) is a client on its way in.
    if self.n_clients == 0 and not self.busy and next(self.conns) == nil then
        local since = math.max(self.idle_since or 0, self.last_request or 0)
        if os.time() - since >= self.idle_seconds then
            self:stop(string.format("idle for %ds", self.idle_seconds), 0)
        end
    end
end

--- R was reclaimed or removed while this process held it: it has lost
--- authority — stop at once, write nothing, exit nonzero (§19.2).
function Server:_lost_lock()
    if self.stopped then return end
    self.stop_reason = M.LOST_LOCK
    if self.service then
        -- No workspace file is written from here on (§19.2): a clean's wipe or
        -- a reset's deletion still settling, a segment drained below, never
        -- save the cache or the working copy. (What a deletion wrote before
        -- it started — its entries `unknown` — stays: crash safety.)
        if self.service.freeze_writes then pcall(self.service.freeze_writes, self.service) end
        -- An attached runtime's running operation is this command's (§19.2):
        -- it is cancelled as on Ctrl-C — its steps' process trees killed —
        -- before the command ends; its clients (the loopback) are told.
        if self.attached then
            pcall(self.service.on_stopping, self.service, "the runtime lock was taken over")
        end
    end
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
--- still holding R, release R, end the process (§19.11). Idempotent. An
--- attached runtime has no endpoint or handle: it closes its loopback
--- connections, releases R and returns to its caller (`exit` records the
--- status, §19.1).
--- @param reason string
--- @param code? integer exit status (default 0)
function Server:stop(reason, code)
    if self.stopped then return end
    self.stop_reason = self.stop_reason or reason
    -- Running operations end first (§19.11, §19.15): their step processes
    -- are killed and their build locks released while this process still
    -- holds R; their clients are told before the connections close.
    if self.service then pcall(self.service.on_stopping, self.service, reason) end
    self.stopped = true
    self:log("stopping: %s", tostring(reason))
    for conn in pairs(self.conns) do
        pcall(function() if not conn.sock:is_closing() then conn.sock:close() end end)
        -- Its subscriptions end with it (§19.20), as on any close.
        if self.interfaces then self.interfaces:drop_conn(conn) end
    end
    self.conns = {}
    for _, h in ipairs({ self.timer, self.sigterm, self.listener }) do
        pcall(function() if h and not h:is_closing() then h:close() end end)
    end
    if self.attached then
        -- Nothing published: only R to release.
    elseif rlock.still_ours(self.R) then
        handle.remove(self.root, { pid = self.pid, start_time = self.start_time })
        endpoint.cleanup(self.root, self.address, self.candidates, self.sock_ino)
    elseif not uv.fs_stat(self.root) then
        -- The workspace (and R with it) is gone: remove the socket this
        -- daemon bound — only while the file at its path is still that one
        -- (the inode recorded at bind), never a successor's.
        endpoint.cleanup(self.root, self.address, self.candidates, self.sock_ino)
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

--- Authenticated clients other than observers: the ones that hold off a
--- retirement (§19.11).
--- @return integer
function Server:active_clients()
    local n = 0
    for conn in pairs(self.conns) do
        if conn.authed and not conn.closed and not conn.observer then n = n + 1 end
    end
    return n
end

--- Authenticated observer connections (§19.16).
--- @return integer
function Server:observer_count()
    local n = 0
    for conn in pairs(self.conns) do
        if conn.authed and not conn.closed and conn.observer then n = n + 1 end
    end
    return n
end

--- Retiring and idle (no running build, no client but observers): exit
--- (§19.11).
function Server:_maybe_retire()
    if self.retiring and not self.stopped and not self.busy and self:active_clients() == 0 then
        self:stop("retired (idle after a version mismatch)", 0)
    end
end

--- A committed write of a state file (§19.12): advance the sequence number
--- and tell every authenticated client (the protocol-10 `model_change`
--- broadcast), and the subscribers of loomworks.Workspace/1 (`changed`).
function Server:model_changed()
    if self.stopped then return end
    self.seq = self.seq + 1
    local msg = { kind = protocol.KIND.model_change, seq = self.seq, session_generation = self.generation }
    for conn in pairs(self.conns) do
        if conn.authed and not conn.closed then self:_send(conn, msg) end
    end
    if self.interfaces then
        local core_ifaces = require("loomworks.daemon.core_interfaces")
        core_ifaces.changed(self.interfaces, self.seq, self.generation)
        -- (A write may change the header: the active profile, the name.)
        if self.service then pcall(core_ifaces.header_check, self.service) end
    end
end

--- The interface registry with the root object (§19.20), created on first
--- use, with the core interfaces of the attached build service mounted
--- (loomworks.daemon.core_interfaces; a service attached later mounts them
--- itself).
--- @return loomworks.daemon.Registry
function Server:registry()
    if not self.interfaces then
        self.interfaces = require("loomworks.daemon.interfaces").new(self)
        if self.service then require("loomworks.daemon.core_interfaces").mount(self.interfaces, self.service) end
    end
    return self.interfaces
end

--- "cli client" / "editor observer": who a connection is, for the log.
function Server:_peer_text(conn)
    local p = conn.peer or {}
    return tostring(p.client or "unknown") .. " " .. (conn.observer and "observer" or "client")
end

function Server:_close(conn, why)
    if conn.closed then return end
    conn.closed = true
    if conn.auth_timer then pcall(function() conn.auth_timer:stop(); conn.auth_timer:close() end) end
    pcall(function() if not conn.sock:is_closing() then conn.sock:close() end end)
    self.conns[conn] = nil
    if why then self:log("closed a connection: %s", why) end
    -- Its subscriptions end with it (§19.20).
    if self.interfaces then self.interfaces:drop_conn(conn) end
    -- Its operations belong to it: cancelled (§19.15).
    if conn.authed and self.service then pcall(self.service.on_conn_closed, self.service, conn) end
    if conn.authed then
        self.n_clients = self.n_clients - 1
        self:log("%s disconnected (%d client(s))", self:_peer_text(conn), self.n_clients)
        if self.n_clients == 0 then self.idle_since = os.time() end
        self:_handle_changed()
        self:_maybe_retire()
    end
    if conn.on_close then pcall(conn.on_close) end
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
    self.last_request = os.time()
    self.conns[conn] = true
    conn.auth_timer = uv.new_timer()
    conn.auth_timer:start(self.auth_timeout_ms, 0, function()
        if not conn.authed then self:_close(conn, "not authenticated in time") end
    end)
    self:_read(conn)
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
        conn.peer = { protocol = msg.protocol, protocol_min = msg.protocol_min, lw_version = msg.lw_version,
            schemas = msg.schemas, client = msg.client, role = msg.role }
        -- The transport both sides agree on (§19.9 "From protocol 11"); nil
        -- with no overlap — the frozen control subset still serves it.
        conn.transport = version.negotiate(msg.protocol, msg.protocol_min)
        -- An observer (§19.16) never holds off a retirement.
        conn.observer = msg.role == "observer"
        self:_send(conn, {
            kind = K.challenge, protocol = protocol.VERSION, protocol_min = protocol.VERSION_MIN,
            lw_version = self.identity,
            schemas = self.schemas, session_generation = self.generation,
            server_nonce = ns, server_proof = auth.server_proof(self.key, self.address, conn.nc, ns),
        })
        return
    end
    if conn.state == "challenged" and msg.kind == K.auth
        and auth.equal(msg.client_proof, auth.client_proof(self.key, self.address, conn.nc, conn.ns)) then
        pcall(function() conn.auth_timer:stop(); conn.auth_timer:close() end)
        conn.auth_timer = nil
        return self:_authed(conn)
    end
    -- A private pipe (`adopt_pipe`: standard I/O, a loopback end): `hello`
    -- alone, answered by `welcome` — no challenge, no proof.
    -- Only `adopt_pipe` sets `private`: a socket connection can never take
    -- this path, whatever its state.
    if conn.private == true and conn.state == "hello" and msg.kind == K.hello and type(msg.protocol) == "number" then
        conn.peer = { protocol = msg.protocol, protocol_min = msg.protocol_min, lw_version = msg.lw_version,
            schemas = msg.schemas, client = msg.client, role = msg.role }
        conn.transport = version.negotiate(msg.protocol, msg.protocol_min)
        conn.observer = msg.role == "observer"
        return self:_authed(conn)
    end
    -- Anything else before authentication, or a failed proof: closed, no detail.
    self:_close(conn, "authentication failed")
end

--- A connection became authenticated: counted, logged and welcomed.
--- @param conn table
function Server:_authed(conn)
    conn.authed, conn.state = true, "authed"
    conn.decoder.max = protocol.MAX_FRAME
    self.n_clients = self.n_clients + 1
    self.last_request = os.time()
    self:log("%s connected (lw %s, %d client(s))", self:_peer_text(conn), tostring(conn.peer and conn.peer.lw_version),
        self.n_clients)
    local header = { root = self.root, pid = self.pid, lw_version = self.identity,
        session_generation = self.generation }
    -- The always-warm header (§19.13): the model's name, active profile
    -- and error state, from the service when one is attached. Its fields
    -- are only ever added: the session fields above are never overwritten.
    if self.service and self.service.header then
        local ok, h = pcall(self.service.header, self.service)
        if ok and type(h) == "table" then
            for k, v in pairs(h) do
                if header[k] == nil then header[k] = v end
            end
        end
    end
    -- Transport fields beside the header (protocol 11, §19.8): the objects
    -- (describe().objects without digests, §19.20).
    local objects = self.interfaces and self.interfaces:object_list(false) or nil
    self:_send(conn, {
        kind = protocol.KIND.welcome, seq = self.seq, clients = self.n_clients, busy = self.busy,
        retiring = self.retiring, header = header, objects = objects,
    })
    self:_handle_changed()
end

--- Start reading a connection's bytes into `_on_read`.
--- @param conn table
function Server:_read(conn)
    conn.sock:read_start(function(rerr, chunk)
        local ok, err = pcall(self._on_read, self, conn, rerr, chunk)
        if not ok then
            self:log("internal error on a connection: %s", tostring(err))
            pcall(self._close, self, conn)
        end
    end)
end

--- Register a connection that needs no authentication — the loopback end of
--- an attached run (§19.1): in the state `_handshake` leaves an authenticated
--- connection in, welcomed over the connection itself. `peer` is what a
--- `hello` announces (`protocol`, `lw_version`, `schemas`, `client`, `role`).
--- Returns the connection, or nil + error once the server stopped.
--- @param sock table a stream with the pipe methods (loomworks.daemon.loopback)
--- @param peer table
--- @return table|nil conn, string|nil err
function Server:adopt(sock, peer)
    if self.stopped then return nil, "the runtime has stopped" end
    peer = peer or {}
    local conn = { sock = sock, decoder = protocol.new_decoder(protocol.MAX_FRAME), state = "new",
        last_seen = uv.now(), loopback = true,
        peer = { protocol = peer.protocol, protocol_min = peer.protocol_min, lw_version = peer.lw_version,
            schemas = peer.schemas, client = peer.client, role = peer.role } }
    conn.transport = version.negotiate(peer.protocol, peer.protocol_min)
    conn.observer = peer.role == "observer"
    self.conns[conn] = true
    self:_authed(conn)
    self:_read(conn)
    return conn
end

--- Register a connection over a private pipe that needs no authentication
--- — the standard input and output of `lw daemon run --stdio` (§19.16), or
--- a loopback end (the conformance runner, §19.20): its first frame must be
--- `hello` (whose `nonce` is ignored), answered directly by `welcome`;
--- anything else closes it. `on_close` runs once it closed.
--- @param sock table a stream with the pipe methods (loomworks.daemon.loopback)
--- @param on_close? fun()
--- @return table|nil conn, string|nil err
function Server:adopt_pipe(sock, on_close)
    if self.stopped then return nil, "the runtime has stopped" end
    local conn = { sock = sock, decoder = protocol.new_decoder(protocol.PREAUTH_MAX), state = "hello",
        last_seen = uv.now(), loopback = true, private = true, on_close = on_close }
    self.conns[conn] = true
    self:_read(conn)
    return conn
end

--- The status a `status` request returns (frozen shape: only additions).
--- @param conn? table the asking connection (its tasks' `task_id` form, tasks.wire_id)
function Server:status(conn)
    local r = self:_handle_record()
    r.root = self.root
    r.retiring = self.retiring
    r.observers = self:observer_count()
    -- The running tasks (protocol 7, §19.11): each one's `start` meta, when it
    -- started and its last percent.
    r.tasks = self.service and self.service.tasks and self.service.tasks:snapshot(conn) or {}
    return r
end

--- An authenticated request: a handler error is a typed error reply (§19.8),
--- never a crash.
function Server:_dispatch(conn, msg)
    local ok, err = pcall(self._dispatch_request, self, conn, msg)
    if not ok then
        self:log("handler error for %s: %s", tostring(msg.kind), tostring(err))
        -- An interface call gets the structured error; a v0 request the string.
        local e = "internal error"
        if msg.kind == protocol.KIND.call then e = { code = "internal", message = "internal error" } end
        self:_send(conn, { kind = protocol.KIND.error, req_id = msg.req_id, error = e })
    end
end

--- The dispatch table (spec §19.20, step 5g.1): one entry per request kind.
--- `call` is the interface envelope, served by the registry
--- (loomworks.daemon.interfaces); the frozen control subset answers itself;
--- the request kinds of protocol 10 are v0 ALIASES, served unchanged by the
--- build service's handlers — the same handlers the interface methods of
--- step 5g.2 adapt — and only when a service is attached (else, as before,
--- an unknown kind). A v0 request gets a v0 reply: `error` is a string.
---   control = fun(server, conn, msg, reply)
---   v0      = the build service's method name
--- @type table<string, { control?: fun(server: loomworks.daemon.Server, conn: table, msg: table, reply: fun(fields: table|nil, cb: function|nil)), v0?: string }>
M.DISPATCH = {
    [protocol.KIND.ping] = { control = function(_, _, _, reply) return reply({}) end },
    [protocol.KIND.status] = {
        control = function(server, conn, _, reply)
            local st = server:status(conn)
            st.kind = protocol.KIND.ok
            return reply(st)
        end,
    },
    [protocol.KIND.stop] = {
        control = function(server, _, _, reply)
            return reply({}, function() server:stop("stop requested", 0) end)
        end,
    },
    [protocol.KIND.retire] = { control = function(server, _, _, reply) server:_retire(); return reply({}) end },
    [protocol.KIND.call] = {
        control = function(server, conn, msg)
            return server:registry():call(conn, msg)
        end,
    },
    -- Routed operations (§19.15): `build` (step 3), the batch `test` (step
    -- 5), the preparation of `lw run` (the program runs in the client), `lw
    -- clean` (step 5c), `lw reset` (step 5d).
    [protocol.KIND.build] = { v0 = "on_build" },
    [protocol.KIND.test] = { v0 = "on_test" },
    [protocol.KIND.prepare_run] = { v0 = "on_run" },
    [protocol.KIND.clean] = { v0 = "on_clean" },
    [protocol.KIND.reset] = { v0 = "on_reset" },
    -- The model: a scope snapshot for the client's projection (§19.13); a
    -- host-probing query in the client's environment (§19.14).
    [protocol.KIND.snapshot] = { v0 = "on_snapshot" },
    [protocol.KIND.query] = { v0 = "on_query" },
}

--- Mark the daemon retiring (§19.11): observers are told with the v0
--- `retiring` broadcast (they disconnect on it and never hold the retirement
--- off), every connection of transport 11 with the root's `retiring` signal.
function Server:_retire()
    local first = not self.retiring
    self.retiring = true
    if not first then return end
    self:log("retiring: a client of another version asked; exits when idle")
    for c in pairs(self.conns) do
        if c.authed and not c.closed and c.observer then self:_send(c, { kind = protocol.KIND.retiring }) end
    end
    if self.interfaces then self.interfaces:root_signal("retiring", {}) end
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
    local entry = type(msg.kind) == "string" and M.DISPATCH[msg.kind] or nil
    if entry and entry.control then return entry.control(self, conn, msg, reply) end
    if entry and entry.v0 and self.service then return self.service[entry.v0](self.service, conn, msg) end
    reply({ kind = K.error, error = "unknown request kind: " .. tostring(msg.kind) })
end

--- Authenticated client count (tests).
function Server:client_count() return self.n_clients end

M.Server = Server
return M
