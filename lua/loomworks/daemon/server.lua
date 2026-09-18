--- loomworks/daemon/server.lua — the daemon run loop (DAEMON.md §4, spec §17).
---
--- One long-lived process per workspace that owns the authoritative model +
--- files + execution and serves the editor and the CLI. This module is the
--- transport/lifecycle core: acquire the single-writer lock, listen on the
--- owner-restricted pipe, publish the discovery handle, run the handshake, route
--- correlated requests, broadcast unsolicited events, and idle-time-out.
---
--- It is host-agnostic: `start()` sets up the libuv listeners and returns
--- WITHOUT blocking. A CLI host (`lw daemon run`) then calls `uv.run()`; a test
--- drives the same server in-process by pumping the loop with `vim.wait`.
---
--- Model ownership, commands, broadcasts, and the task stream layer on top via
--- the handler registry (`:handle`) and `:broadcast` — see later phases.

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local handle = require("loomworks.daemon.handle")
local lock = require("loomworks.daemon.lock")
local pipe = require("loomworks.daemon.pipe")

--- @class loomworks.daemon.Server
local Server = {}
Server.__index = Server

local M = {}

--- Idle timeout: no connected clients and no recent activity for this long ⇒ the
--- daemon releases the lock and exits (DAEMON.md §4). ~10 minutes by default.
M.IDLE_SECONDS = 600

--- Fresh session generation for a daemon start. Session-local; a restart
--- reassigns it, so a client that sees a new generation flushes its id-map and
--- re-hydrates (DAEMON.md §3.2). Time-based (monotonic across restarts) plus a
--- random low word to avoid a within-second collision.
local function new_generation()
    return os.time() * 1000 + math.random(0, 999)
end

local function lw_version()
    local ok, lw = pcall(require, "loomworks")
    return (ok and lw._version) or "0.0.0"
end

--- Create a daemon server for a workspace root (not yet started).
--- @param root string workspace root
--- @param opts? { idle_seconds?: integer, generation?: integer }
--- @return loomworks.daemon.Server
function M.new(root, opts)
    opts = opts or {}
    local self = setmetatable({}, Server)
    self.root = (root:gsub("\\", "/"):gsub("/+$", ""))
    self.opts = opts
    self.generation = opts.generation or new_generation()
    self.seq = 0
    self.idle_seconds = opts.idle_seconds or M.IDLE_SECONDS
    self._conns = {}         -- conn -> true (connected clients)
    self._n_conns = 0
    self._handlers = {}      -- kind -> fun(self, conn, msg)
    self._last_activity = os.time()
    self._stopped = false
    self:_install_core_handlers()
    return self
end

--- Register a request handler for a message kind. A handler receives
--- `(server, conn, msg)` and typically replies with `conn:reply(...)`.
--- @param kind string
--- @param fn fun(server: loomworks.daemon.Server, conn: table, msg: table)
function Server:handle(kind, fn)
    self._handlers[kind] = fn
end

--- The monotonic per-workspace sequence counter that stamps snapshots and
--- broadcasts (DAEMON.md §3.3). Advance and return the new value.
--- @return integer
function Server:next_seq()
    self.seq = self.seq + 1
    return self.seq
end

--- A fresh task id for the task stream (§3.4). Monotonic within the session.
--- @return integer
function Server:next_task_id()
    self._task_seq = (self._task_seq or 0) + 1
    return self._task_seq
end

function Server:_touch() self._last_activity = os.time() end

--- Acquire write authority, bind the pipe, publish the handle, arm the timers.
--- @return boolean|nil ok, string|nil err
function Server:start()
    local h, reason = lock.acquire(self.root, { generation = self.generation })
    if not h then return nil, reason end
    self._lock = h

    local server, addr = pipe.listen(self.root, 64, function(err)
        self:_on_connection(err)
    end)
    if not server then
        lock.release(self._lock); self._lock = nil
        return nil, addr
    end
    self._server = server
    self.address = addr

    local ok, herr = handle.write(self.root, {
        pid = (uv.os_getpid and uv.os_getpid()) or 0,
        pipe = addr,
        protocol_version = protocol.VERSION,
        lw_version = lw_version(),
        session_generation = self.generation,
        started_at = os.time(),
    })
    if not ok then
        self:_teardown()
        return nil, "handle write failed: " .. tostring(herr)
    end

    -- Heartbeat the handle + lock mtime so liveness stays fresh (§17.2).
    self._hb = uv.new_timer()
    self._hb:start(lock.HEARTBEAT_MS, lock.HEARTBEAT_MS, function()
        handle.heartbeat(self.root)
        lock.heartbeat(self.root)
    end)

    -- Idle check: fires when no clients are attached and activity has lapsed.
    self._idle = uv.new_timer()
    local check_ms = math.min(self.idle_seconds * 1000, 30000)
    self._idle:start(check_ms, check_ms, function()
        if self._n_conns == 0
            and (os.time() - self._last_activity) >= self.idle_seconds then
            self:stop("idle timeout")
        end
    end)

    return true
end

--- Wrap an accepted pipe as a connection with reply/close helpers.
local function make_conn(server, sock)
    local conn = {
        sock = sock,
        decoder = protocol.new_decoder(),
        alive = true,
    }
    function conn.reply(msg) -- send a framed message to this client
        if conn.alive and not sock:is_closing() then
            pcall(function() sock:write(protocol.encode(msg)) end)
        end
    end
    function conn.close()
        if not conn.alive then return end
        conn.alive = false
        server:_drop_conn(conn)
        pcall(function() if not sock:is_closing() then sock:close() end end)
    end
    return conn
end

function Server:_on_connection(err)
    if err or self._stopped then return end
    local sock = uv.new_pipe(false)
    local ok = pcall(function() self._server:accept(sock) end)
    if not ok then pcall(function() sock:close() end); return end
    if not pipe.check_peer(sock) then
        pcall(function() sock:close() end)
        return
    end
    local conn = make_conn(self, sock)
    self._conns[conn] = true
    self._n_conns = self._n_conns + 1
    self:_touch()
    sock:read_start(function(rerr, chunk)
        if rerr or not chunk then
            conn.close()
            return
        end
        self:_touch()
        for _, payload in ipairs(conn.decoder:push(chunk)) do
            local msg, derr = protocol.decode(payload)
            if msg then
                self:_route(conn, msg)
            elseif derr then
                conn.reply({ kind = protocol.KIND.error, error = derr })
            end
        end
    end)
end

function Server:_drop_conn(conn)
    if self._conns[conn] then
        self._conns[conn] = nil
        self._n_conns = self._n_conns - 1
    end
end

function Server:_route(conn, msg)
    local h = self._handlers[msg.kind]
    if not h then
        conn.reply({ kind = protocol.KIND.error, req_id = msg.req_id,
            error = "unknown message kind: " .. tostring(msg.kind) })
        return
    end
    local ok, err = pcall(h, self, conn, msg)
    if not ok then
        conn.reply({ kind = protocol.KIND.error, req_id = msg.req_id,
            error = "handler error: " .. tostring(err) })
    end
end

--- Send a message to every connected client (unsolicited broadcast, §3.3/§3.4).
--- @param msg table
function Server:broadcast(msg)
    for conn in pairs(self._conns) do
        conn.reply(msg)
    end
end

--- Announce a model change to all clients: advance the seq and broadcast a
--- `model_change` invalidation stamped with the seq + session generation
--- (DAEMON.md §3.3). Clients re-pull the scope snapshot (coarse invalidation).
--- @param kinds? string[] the changed event kinds (e.g. { "active_set" })
function Server:notify_model_change(kinds)
    if self._stopped then return end
    self:_touch()
    self:broadcast({
        kind = protocol.KIND.model_change,
        seq = self:next_seq(),
        session_generation = self.generation,
        kinds = kinds,
    })
end

--- The number of connected clients (test/introspection).
--- @return integer
function Server:client_count() return self._n_conns end

--- Broadcast a normalized device-log record to all clients (§6.2). The record is
--- normalized here so a producer can hand over a raw platform record; the general
--- log viewer renders it without platform knowledge.
--- @param raw table a raw log record (see daemon.log_record)
function Server:emit_log(raw)
    local record = require("loomworks.daemon.log_record").normalize(raw)
    self:broadcast({ kind = protocol.KIND.log, record = record })
end

function Server:_install_core_handlers()
    -- Handshake (§4): the client announces its protocol; we answer with the
    -- session generation, the seq watermark to base hydration on, and the
    -- always-warm header (a later phase fills header_snapshot).
    self:handle(protocol.KIND.hello, function(server, conn, msg)
        local compatible = protocol.compatible(msg.protocol_version)
        conn.reply({
            kind = protocol.KIND.welcome,
            req_id = msg.req_id,
            session_generation = server.generation,
            protocol_version = protocol.VERSION,
            min_supported = protocol.MIN_SUPPORTED,
            compatible = compatible,
            current_seq = server.seq,
            lw_version = lw_version(),
            header_snapshot = server._header_snapshot and server:_header_snapshot() or nil,
        })
    end)

    -- Keepalive: resets the idle timer, holds the daemon alive (§4).
    self:handle("ping", function(_server, conn, msg)
        conn.reply({ kind = protocol.KIND.ok, req_id = msg.req_id })
    end)

    -- Graceful shutdown.
    self:handle(protocol.KIND.shutdown, function(server, conn, msg)
        conn.reply({ kind = protocol.KIND.ok, req_id = msg.req_id })
        -- Let the ack flush before we tear the pipe down.
        local t = uv.new_timer()
        t:start(20, 0, function()
            pcall(function() t:stop(); t:close() end)
            server:stop("shutdown requested")
        end)
    end)
end

function Server:_teardown()
    for conn in pairs(self._conns) do conn.close() end
    self._conns = {}
    self._n_conns = 0
    for _, name in ipairs({ "_hb", "_idle" }) do
        local timer = self[name]
        if timer then pcall(function() timer:stop(); timer:close() end); self[name] = nil end
    end
    if self._server then
        pcall(function() if not self._server:is_closing() then self._server:close() end end)
        self._server = nil
    end
    handle.remove(self.root)
    pipe.cleanup(self.address)
    if self._lock then lock.release(self._lock); self._lock = nil end
end

--- Stop the daemon: close clients + listener, drop the handle, release the lock.
--- Idempotent; invokes `opts.on_stop(reason)` once.
--- @param reason? string
function Server:stop(reason)
    if self._stopped then return end
    self._stopped = true
    self:_teardown()
    if self.opts.on_stop then pcall(self.opts.on_stop, reason) end
end

--- True once the server has stopped (test convenience).
--- @return boolean
function Server:is_stopped() return self._stopped end

M.Server = Server
return M
