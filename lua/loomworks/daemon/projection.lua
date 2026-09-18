--- loomworks/daemon/projection.lua — the daemon projection CLIENT (DAEMON.md §2).
---
--- Connects to a running daemon, does the handshake, hydrates a LOCAL projection
--- Workspace from the wire snapshot (via the shared deserializer, §snapshot), and
--- keeps a correlated request/reply channel open for further queries, commands
--- (later phase), and unsolicited broadcasts. Reads run locally on the projection
--- (no per-query round-trip); only sync + commands cross the wire.
---
--- All I/O is async and never blocks the editor loop. A pipe disconnect rejects
--- every pending request with a typed `daemon_lost` error — the signal that trips
--- the in-process fallback (§4).

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local handle = require("loomworks.daemon.handle")
local snapshot = require("loomworks.daemon.snapshot")

--- @class loomworks.daemon.Projection
local Projection = {}
Projection.__index = Projection

local M = {}

M.REQUEST_TIMEOUT_MS = 5000

--- Connect to the workspace's daemon and hydrate a projection.
--- On success the callback receives `(projection, nil)`; on failure `(nil, err)`.
--- @param root string workspace root
--- @param opts? { core?: table, timeout_ms?: integer, on_broadcast?: fun(msg:table) }
--- @param callback fun(projection: loomworks.daemon.Projection|nil, err: string|nil)
function M.connect(root, opts, callback)
    opts = opts or {}
    local info = handle.read(root)
    if not info or not handle.is_live(info) or type(info.pipe) ~= "string" then
        callback(nil, "no live daemon for " .. root)
        return
    end
    if not protocol.compatible(info.protocol_version) then
        callback(nil, "daemon protocol " .. tostring(info.protocol_version) ..
            " is incompatible with this client")
        return
    end

    local self = setmetatable({}, Projection)
    self.root = root
    self.core = opts.core or require("loomworks.core").new()
    self.on_broadcast = opts.on_broadcast
    self.on_task = opts.on_task     -- fun(msg) for any task-stream event
    self.on_notify = opts.on_notify -- fun(msg) for notifications
    self.on_log = opts.on_log       -- fun(record) for device-log records (§6.2)
    self._task_observers = {}       -- task_id -> { on_output, on_progress, on_done }
    self.timeout_ms = opts.timeout_ms or M.REQUEST_TIMEOUT_MS
    self._pipe = uv.new_pipe(false)
    self._decoder = protocol.new_decoder()
    self._pending = {}      -- req_id -> { cb, timer }
    self._next_id = 0
    self._closed = false
    self.workspace = nil
    self.generation = nil
    self.seq = nil

    self._pipe:connect(info.pipe, function(cerr)
        if cerr then
            self:_fail_all("daemon_lost")
            callback(nil, "cannot connect: " .. tostring(cerr))
            return
        end
        self._pipe:read_start(function(rerr, chunk)
            if rerr or not chunk then
                self:_fail_all("daemon_lost")
                return
            end
            for _, payload in ipairs(self._decoder:push(chunk)) do
                local msg = protocol.decode(payload)
                if msg then self:_dispatch(msg) end
            end
        end)
        -- Handshake, then hydrate the projection from the first snapshot.
        self:request({ kind = protocol.KIND.hello, protocol_version = protocol.VERSION },
            function(welcome, herr)
                if herr then callback(nil, herr); return end
                self.generation = welcome.session_generation
                self:_hydrate(function(ok, serr)
                    if ok then callback(self, nil) else callback(nil, serr) end
                end)
            end)
    end)
end

--- Send a correlated request; the callback receives `(reply, nil)` on an `ok`/
--- `welcome` reply, or `(nil, err)` on an error reply, timeout, or disconnect.
--- @param msg table (a `req_id` is assigned here)
--- @param callback fun(reply: table|nil, err: string|nil)
function Projection:request(msg, callback)
    if self._closed then callback(nil, "daemon_lost"); return end
    self._next_id = self._next_id + 1
    local id = self._next_id
    msg.req_id = id
    local timer = uv.new_timer()
    self._pending[id] = { cb = callback, timer = timer }
    timer:start(self.timeout_ms, 0, function()
        local p = self._pending[id]
        if p then
            self._pending[id] = nil
            pcall(function() timer:stop(); timer:close() end)
            p.cb(nil, "request timed out")
        end
    end)
    pcall(function() self._pipe:write(protocol.encode(msg)) end)
end

function Projection:_dispatch(msg)
    if msg.req_id and self._pending[msg.req_id] then
        local p = self._pending[msg.req_id]
        self._pending[msg.req_id] = nil
        pcall(function() p.timer:stop(); p.timer:close() end)
        if msg.kind == protocol.KIND.error then
            p.cb(nil, msg.error or "daemon error")
        else
            p.cb(msg, nil)
        end
        return
    end
    -- Unsolicited broadcast: handle model-change invalidation internally first
    -- (coarse re-pull, §3.3), route task/notify to their observers, then hand
    -- the raw event to any generic observer.
    if msg.kind == protocol.KIND.model_change then
        self:_on_model_change(msg)
    elseif msg.kind == protocol.KIND.task then
        self:_on_task(msg)
    elseif msg.kind == protocol.KIND.notify then
        if self.on_notify then pcall(self.on_notify, msg) end
    elseif msg.kind == protocol.KIND.log then
        if self.on_log then pcall(self.on_log, msg.record) end
    end
    if self.on_broadcast then pcall(self.on_broadcast, msg) end
end

--- Route a task-stream event to its per-task observer (if any) and the generic
--- on_task hook. A `done` phase resolves + retires the observer.
function Projection:_on_task(msg)
    if self.on_task then pcall(self.on_task, msg) end
    local obs = msg.task_id and self._task_observers[msg.task_id]
    if not obs then return end
    if msg.phase == "output" and obs.on_output then
        pcall(obs.on_output, msg.stream, msg.text)
    elseif msg.phase == "progress" and obs.on_progress then
        pcall(obs.on_progress, msg.fraction, msg.pct)
    elseif msg.phase == "done" then
        self._task_observers[msg.task_id] = nil
        if obs.on_done then pcall(obs.on_done, msg.exit_code) end
    end
end

--- Delegate a build to the daemon and observe its task stream. `args` is
--- `{ profile_key, extra_args? }`; `cbs` may carry `on_accept(task_id|nil, err)`,
--- `on_output(stream, text)`, `on_progress(fraction, pct)`, `on_done(code)`.
--- @param args table
--- @param cbs? table
function Projection:build(args, cbs)
    cbs = cbs or {}
    self:request({ kind = "command", name = "build", args = args }, function(reply, err)
        if err then
            if cbs.on_accept then cbs.on_accept(nil, err) end
            return
        end
        local task_id = reply.task_id
        if task_id then self._task_observers[task_id] = cbs end
        if cbs.on_accept then cbs.on_accept(task_id, nil) end
    end)
end

--- React to a `model_change` broadcast. A new session generation means the
--- daemon restarted → discard and re-hydrate; otherwise a higher seq means the
--- model advanced → re-pull the snapshot. Re-pulls coalesce: one in flight, and
--- a newer seq arriving mid-refresh schedules exactly one more (closing the
--- snapshot/stream race, §3.3).
function Projection:_on_model_change(msg)
    if self._closed then return end
    if msg.session_generation and self.generation
        and msg.session_generation ~= self.generation then
        self.generation = msg.session_generation
    end
    if type(msg.seq) == "number" and self.seq and msg.seq <= self.seq then
        return -- already at or past this change
    end
    self._target_seq = msg.seq or (self.seq and self.seq + 1)
    if self._refreshing then self._refresh_again = true; return end
    self:_pump_refresh()
end

function Projection:_pump_refresh()
    self._refreshing = true
    self:_hydrate(function()
        self._refreshing = false
        if self._refresh_again then
            self._refresh_again = false
            if not self._closed then self:_pump_refresh() end
        end
    end)
end

--- Send a mutation COMMAND to the daemon (§3.1). Fire-and-forget in effect: the
--- projection updates from the resulting `model_change` broadcast (auto-refresh),
--- not from this reply — the callback only reports the ack outcome
--- (`ok` / `rolled-back` / `partially-applied`) or an error.
--- @param name string command name (e.g. "profile.activate")
--- @param args table|nil command arguments (wire-serializable keys)
--- @param callback? fun(outcome: string|nil, err: string|nil)
function Projection:command(name, args, callback)
    callback = callback or function() end
    self:request({ kind = "command", name = name, args = args }, function(reply, err)
        if err then callback(nil, err) else callback(reply.outcome or "ok", nil) end
    end)
end

--- Request a fresh snapshot and rebuild the projection Workspace in place.
--- @param callback fun(ok: boolean, err: string|nil)
function Projection:_hydrate(callback)
    self:request({ kind = "snapshot" }, function(reply, err)
        if err then callback(false, err); return end
        self.seq = reply.seq
        if reply.session_generation then self.generation = reply.session_generation end
        local ok, ws = pcall(snapshot.hydrate, self.core, self.root, reply.snapshot)
        if not ok then callback(false, "hydrate failed: " .. tostring(ws)); return end
        self.workspace = ws
        -- The id↔key map: the transport-layer router that is also the
        -- subscription set (§3.2/§3.3). Rebuilt each hydrate from the stamped
        -- index; used for id-addressed routing when deltas land.
        self.id_map = reply.snapshot and reply.snapshot.ids or nil
        callback(true, nil)
    end)
end

--- Re-pull the scope snapshot and refresh the projection (used on a model-change
--- broadcast — the coarse invalidation strategy, §3.3). Public alias of _hydrate.
--- @param callback fun(ok: boolean, err: string|nil)
function Projection:refresh(callback)
    self:_hydrate(callback or function() end)
end

function Projection:_fail_all(err)
    for id, p in pairs(self._pending) do
        self._pending[id] = nil
        pcall(function() p.timer:stop(); p.timer:close() end)
        pcall(p.cb, nil, err)
    end
end

--- Close the connection (rejects any pending requests).
function Projection:close()
    if self._closed then return end
    self._closed = true
    self:_fail_all("daemon_lost")
    pcall(function() if not self._pipe:is_closing() then self._pipe:close() end end)
end

M.Projection = Projection
return M
