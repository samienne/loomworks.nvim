--- loomworks/daemon/observer.lua — the editor as an OBSERVER of the workspace
--- daemon (spec §19.16, §19.19 step 4).
---
--- In `daemon` runtime mode every workspace the editor loads gets one
--- Observer (owned by the Workspace, `ws._daemon_observer`, stopped by
--- `Workspace:teardown`). It never runs an operation: the editor's own
--- operations stay on the in-process path. It
---
---   * resolves a host binary (loomworks.daemon.host_binary) and launches
---     `<binary> daemon run --root <root>` only when no daemon is live on
---     workspace load or on an explicit `:LoomworksDaemon connect` — never
---     after a connection dropped (`lw daemon stop` must stop it);
---   * watches the handle (WATCH_MS) and connects to a live daemon whose
---     protocol equals ours and whose schemas are not newer (the host
---     version may differ), as `client = "editor"`, `role = "observer"`, and
---     pings it every KEEPALIVE_MS (§19.11);
---   * skips a daemon that is `retiring` (broadcast or in `welcome`) or
---     incompatible, identified by pid + start time;
---   * on `model_change` applies the workspace files' pending changes at once
---     (the file tracker's `sync`, §19.12);
---   * turns observed `task` streams into RemoteTasks resolved to the
---     workspace's domain objects (loomworks.daemon.remote_task), which the
---     status page, fidget and the statusline show.
---
--- Every problem is the observer's one current NOTE (the status page's
--- Runtime line) — never a notification, never repeated.
---
--- Libuv callbacks (connection, timers) only schedule: all work runs on the
--- main loop.

local uv = vim.uv or vim.loop
local remote_task = require("loomworks.daemon.remote_task")

local M = {}

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- Keepalive interval (spec §19.11: about every 30 s).
M.KEEPALIVE_MS = env_ms("LW_TEST_DAEMON_KEEPALIVE_MS") or 30000
--- Handle watch interval (spec §19.16: about every 2 s).
M.WATCH_MS = env_ms("LW_TEST_OBSERVER_WATCH_MS") or 2000
--- Handshake timeout.
M.CONNECT_MS = env_ms("LW_TEST_DAEMON_STEP_MS") or 5000

--- @class loomworks.daemon.Observer
--- @field ws loomworks.Workspace
--- @field root string
--- @field state "idle"|"no-binary"|"launching"|"connecting"|"connected"|"waiting"|"stopped"
--- @field note string|nil the current Runtime note
--- @field conn loomworks.daemon.Conn|nil
--- @field daemon { pid: integer, start_time: string|nil, lw_version: string|nil }|nil the observed daemon
--- @field seq integer last model_change seq
--- @field generation any session generation of the observed daemon
--- @field skip table<string, boolean> daemons never connected to again ("pid:start")
--- @field _tasks table<integer, loomworks.RemoteTask> running remote tasks by daemon task id
--- @field _order integer[] task ids in start order
--- @field _child table|nil the daemon this observer launched (until it is live or exited): `{ pid, code }`
--- @field _binary string|nil the host binary it was launched from
--- @field _connecting table|nil the one connection attempt in flight (single-flight token)
--- @field _watch userdata|nil the handle-watch timer
--- @field _keepalive userdata|nil the keepalive ping timer
--- @field _dropped boolean|nil the last connection dropped (keeps its note while waiting)
--- @field _retired_note boolean|nil the connection is being closed because the daemon retires
--- @field opts table the attach options (test seams, see `attach`)
--- @field watch_ms integer handle-watch interval
--- @field keepalive_ms integer keepalive ping interval
--- @field warning string|nil an invalid runtime-mode value that was ignored (shown on the Runtime line)
local Observer = {}
Observer.__index = Observer

local function daemon_id(pid, start) return tostring(pid) .. ":" .. tostring(start) end

--- Attach an observer to a freshly loaded workspace when the runtime mode
--- selects the daemon (spec §19.1). Returns the observer, or nil (in-process
--- mode: nothing happens).
--- opts (tests inject):
---   configured  the setup option `runtime.mode`
---   getenv      replaces os.getenv for the selection and LOOMWORKS_LW
---   resolve     fun(root) → binary|nil, source (loomworks.daemon.host_binary.resolve)
---   spawn       fun(root, opts) → child|nil, err (loomworks.daemon.launch.spawn)
---   inspect     fun(root) → state (loomworks.daemon.inspect.state)
---   connect     fun(endpoint, opts, cb) (loomworks.daemon.client.connect)
---   check       fun(root, endpoint) → ok, why (loomworks.daemon.endpoint.check)
---   watch_ms, keepalive_ms
--- @param ws loomworks.Workspace
--- @param opts? table
--- @return loomworks.daemon.Observer|nil
function M.attach(ws, opts)
    opts = opts or {}
    if not ws or ws._torn_down then return nil end
    local runtime = require("loomworks.daemon.runtime")
    local sel = runtime.select(opts.configured, { getenv = opts.getenv })
    if not sel.daemon then return nil end
    if ws._daemon_observer then return ws._daemon_observer end
    local self = setmetatable({
        ws = ws, root = ws.root, opts = opts, state = "idle", seq = 0, skip = {},
        _tasks = {}, _order = {},
        watch_ms = opts.watch_ms or M.WATCH_MS,
        keepalive_ms = opts.keepalive_ms or M.KEEPALIVE_MS,
    }, Observer)
    ws._daemon_observer = self
    if sel.warning then self.warning = sel.warning end
    self:start(false)
    return self
end

--- The observer of `ws`, if any.
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
function M.of(ws) return ws and ws._daemon_observer or nil end

function Observer:_emit(event, data)
    local core = self.ws and self.ws._core
    local events = core and core._deps and core._deps.events
    if events then pcall(events.emit, event, data) end
end

--- Set the state and the note; the status page re-renders.
function Observer:_set(state, note)
    if self.state == state and self.note == note then return end
    self.state, self.note = state, note
    self:_emit("daemon_runtime_changed", self)
end

function Observer:_inspect()
    return (self.opts.inspect or require("loomworks.daemon.inspect").state)(self.root)
end

--- Start observing: connect to a live daemon, or launch one (spec §19.16:
--- only here — on workspace load, or `explicit` from `:LoomworksDaemon
--- connect` — never after a drop), then keep watching the handle.
--- @param explicit boolean
function Observer:start(explicit)
    if self.state == "stopped" then return end
    if explicit then self.skip = {} end
    self:_start_watch()
    -- Single-flight: one connection, one attempt, one launch at a time.
    if self.conn or self._connecting then return end
    if self._child and self._child.code == nil then return end
    local st = self:_inspect()
    if st.kind == "live" then return self:_connect(st) end
    if st.kind == "none" or st.kind == "stale" or st.kind == "unreadable" then
        return self:_launch()
    end
    self:_set("waiting", M.state_note(st))
end

--- The note for a daemon state the observer does not launch over.
--- @param st table
--- @return string
function M.state_note(st)
    local pid = st.lock and st.lock.pid or (st.handle and st.handle.pid) or "?"
    if st.kind == "starting" then return "the workspace daemon (pid " .. tostring(pid) .. ") is starting" end
    if st.kind == "hung" then
        return "the workspace daemon (pid " .. tostring(pid) .. ") is not responding — lw daemon stop --force"
    end
    if st.kind == "foreign" then
        return "the workspace daemon runs on " .. tostring(st.lock and st.lock.host or "another host")
    end
    if st.kind == "attached" then return "the workspace runtime is held by an lw command (pid " .. tostring(pid) .. ")" end
    return "no workspace daemon — waiting for one"
end

function Observer:_launch()
    local resolve = self.opts.resolve or require("loomworks.daemon.host_binary").resolve
    local bin = resolve(self.root, { getenv = self.opts.getenv })
    if not bin then
        return self:_set("no-binary", require("loomworks.daemon.host_binary").NONE_NOTE)
    end
    local spawn = self.opts.spawn or require("loomworks.daemon.launch").spawn
    local child, err = spawn(self.root, { argv = { bin } })
    if not child then
        return self:_set("waiting", "could not start the workspace daemon (" .. tostring(err) .. ")")
    end
    self._child = child
    self._binary = bin
    self:_set("launching", "starting the workspace daemon (" .. bin .. ")")
end

function Observer:_start_watch()
    if self._watch then return end
    local t = uv.new_timer()
    self._watch = t
    t:start(self.watch_ms, self.watch_ms, vim.schedule_wrap(function()
        if self.state == "stopped" then return end
        local ok, err = pcall(self._on_watch, self)
        if not ok then self:_set("waiting", "internal error: " .. tostring(err)) end
    end))
end

--- One watch tick: a launched daemon that exited early is a note; a live
--- daemon we are not connected to is connected to (unless skipped).
function Observer:_on_watch()
    if self.conn or self._connecting then return end
    local st = self:_inspect()
    local child = self._child
    -- The launched daemon exited without becoming the live one. EXIT_HELD
    -- means some runtime holds R — another daemon (then it is live or
    -- starting and is picked up below) or an attached lw command (noted).
    if child and child.code ~= nil and st.kind ~= "live" and st.kind ~= "starting" then
        self._child = nil
        if child.code == require("loomworks.daemon.server").EXIT_HELD then
            return self:_set("waiting", M.state_note(st))
        end
        return self:_set("waiting", "could not start the workspace daemon (it exited with status "
            .. tostring(child.code) .. ")")
    end
    if st.kind == "live" then
        local h = st.handle or {}
        if self.skip[daemon_id(h.pid, h.start_time)] then return end
        return self:_connect(st)
    end
    if self.state ~= "launching" and self.state ~= "no-binary" then
        local note = M.state_note(st)
        if self.state ~= "waiting" or not self._dropped then self:_set("waiting", note) end
    end
end

--- Connect to the live daemon of `st`.
function Observer:_connect(st)
    local h = st.handle or {}
    local check = self.opts.check or require("loomworks.daemon.endpoint").check
    local eok, why = check(self.root, h.endpoint)
    if not eok then
        self.skip[daemon_id(h.pid, h.start_time)] = true
        return self:_set("waiting", tostring(why))
    end
    local connect = self.opts.connect or require("loomworks.daemon.client").connect
    self:_set("connecting", "connecting to the workspace daemon (pid " .. tostring(h.pid) .. ")")
    local target = { pid = h.pid, start_time = h.start_time }
    self._connecting = target
    connect(h.endpoint, {
        client = "editor", role = "observer", timeout_ms = M.CONNECT_MS,
        on_message = function(msg) vim.schedule(function() self:_on_message(msg) end) end,
        on_close = function(c) vim.schedule(function() self:_on_closed(c) end) end,
    }, function(conn, err)
        vim.schedule(function() self:_on_connected(target, conn, err) end)
    end)
end

function Observer:_on_connected(target, conn, err)
    -- Only the attempt in flight counts; anything else (stopped meanwhile,
    -- superseded) closes the connection it got.
    if self.state == "stopped" or self._connecting ~= target or self.conn then
        if conn then conn.on_close = nil; conn:close() end
        return
    end
    self._connecting = nil
    if not conn then
        if err == "untrusted" then self.skip[daemon_id(target.pid, target.start_time)] = true end
        return self:_set("waiting", "could not reach the workspace daemon (pid " .. tostring(target.pid)
            .. ", " .. tostring(err) .. ")")
    end
    local ch = conn.challenge or {}
    local version = require("loomworks.daemon.version")
    local ok, what = version.observer_compatible(ch)
    if not ok then
        self.skip[daemon_id(target.pid, target.start_time)] = true
        conn.on_close = nil
        conn:close()
        local why = what == "protocol"
            and ("protocol " .. tostring(ch.protocol) .. ", this plugin " .. version.PROTOCOL)
            or "newer file formats"
        return self:_set("waiting", "the workspace daemon runs lw v" .. tostring(ch.lw_version) .. " (" .. why
            .. ") — not observing it; running in-process")
    end
    if conn.welcome and conn.welcome.retiring then
        self.skip[daemon_id(target.pid, target.start_time)] = true
        conn.on_close = nil
        conn:close()
        return self:_set("waiting", "the workspace daemon (pid " .. tostring(target.pid)
            .. ") is retiring — waiting for its successor")
    end
    self.conn = conn
    self._child = nil
    self._dropped = nil
    self.daemon = { pid = target.pid, start_time = target.start_time, lw_version = ch.lw_version }
    self.generation = ch.session_generation
    self.seq = tonumber(conn.welcome and conn.welcome.seq) or 0
    self:_start_keepalive()
    self:_set("connected", "observing the workspace daemon (pid " .. tostring(target.pid) .. ")")
    -- What the daemon wrote before we connected: catch up now.
    self:_reload()
end

function Observer:_start_keepalive()
    self:_stop_timer("_keepalive")
    local t = uv.new_timer()
    self._keepalive = t
    t:start(self.keepalive_ms, self.keepalive_ms, vim.schedule_wrap(function()
        local c = self.conn
        if c and not c.closed then c:request({ kind = "ping" }, function() end) end
    end))
end

function Observer:_stop_timer(field)
    local t = self[field]
    if not t then return end
    self[field] = nil
    pcall(function() t:stop(); if not t:is_closing() then t:close() end end)
end

--- The connection closed (the daemon stopped, crashed, retired, or dropped
--- this observer). Never relaunch: watch for the next live daemon.
function Observer:_on_closed(c)
    if c ~= self.conn then return end
    self.conn = nil
    self.daemon = nil
    self:_stop_timer("_keepalive")
    self:_end_tasks("the workspace daemon disconnected")
    if self.state == "stopped" then return end
    self._dropped = true
    if self._retired_note then
        self._retired_note = nil
        return self:_set("waiting", "the workspace daemon is retiring — waiting for its successor")
    end
    self:_set("waiting", "the workspace daemon disconnected — waiting for it")
end

--- Apply the workspace files' pending changes now (spec §19.12).
function Observer:_reload()
    local ws = self.ws
    if not ws or ws._torn_down then return end
    local tr = ws._tracker
    if tr and tr.sync then pcall(tr.sync, tr) end
end

function Observer:_clock() return uv.hrtime() / 1e9 end

--- A broadcast or task event from the daemon.
--- @param msg table
function Observer:_on_message(msg)
    if self.state == "stopped" or type(msg) ~= "table" then return end
    if msg.kind == "model_change" then
        if msg.session_generation ~= self.generation then
            self.generation = msg.session_generation
            self.seq = tonumber(msg.seq) or 0
        elseif (tonumber(msg.seq) or 0) <= self.seq then
            return
        else
            self.seq = tonumber(msg.seq) or self.seq
        end
        return self:_reload()
    elseif msg.kind == "retiring" then
        local d = self.daemon
        if d then self.skip[daemon_id(d.pid, d.start_time)] = true end
        local c = self.conn
        if c then
            self._retired_note = true
            c:close() -- _on_closed (scheduled) records the drop
        end
        return
    elseif msg.kind == "task" then
        return self:_on_task(msg)
    end
end

--- A task-stream event (spec §19.15).
function Observer:_on_task(msg)
    local id = msg.task_id
    if id == nil then return end
    local task = self._tasks[id]
    if msg.phase == "start" then
        if task then return end
        task = remote_task.new(self.ws, id, msg.meta, self:_clock())
        self._tasks[id] = task
        self._order[#self._order + 1] = id
        task:attach_units()
        self:_emit("daemon_task_started", { task = task })
        return
    end
    if not task then return end -- started before we connected: not shown
    if msg.phase == "line" or msg.phase == "output" then
        task:append(tostring(msg.text or ""))
    elseif msg.phase == "progress" then
        task.pct = tonumber(msg.pct)
        self:_emit("daemon_task_progress", { task = task })
    elseif msg.phase == "done" then
        task:finish(tonumber(msg.exit_code), msg.error)
        self:_forget(id)
        self:_emit("daemon_task_stopped", { task = task })
    end
end

function Observer:_forget(id)
    self._tasks[id] = nil
    for i, v in ipairs(self._order) do
        if v == id then table.remove(self._order, i); break end
    end
end

--- End every running remote task (`reason`).
function Observer:_end_tasks(reason)
    local ids = vim.list_extend({}, self._order)
    for _, id in ipairs(ids) do
        local task = self._tasks[id]
        if task then
            task:finish(nil, nil, reason)
            self:_forget(id)
            self:_emit("daemon_task_stopped", { task = task })
        end
    end
end

--- The running remote tasks, in start order.
--- @return loomworks.RemoteTask[]
function Observer:tasks()
    local out = {}
    for _, id in ipairs(self._order) do out[#out + 1] = self._tasks[id] end
    return out
end

--- The status page's Runtime line text.
--- @return string
function Observer:runtime_line()
    local t = self.note or self.state
    if self.warning then t = t .. " (" .. self.warning .. ")" end
    return t
end

--- Stop observing (workspace teardown): timers stop, the connection closes,
--- remote tasks are cleared. The daemon keeps running (§19.11).
function Observer:stop()
    if self.state == "stopped" then return end
    self.state = "stopped"
    self:_stop_timer("_watch")
    self:_stop_timer("_keepalive")
    local c = self.conn
    self.conn = nil
    if c then c.on_close = nil; c:close() end
    self:_end_tasks("the workspace was unloaded")
    if self.ws and self.ws._daemon_observer == self then self.ws._daemon_observer = nil end
end

M.Observer = Observer
return M
