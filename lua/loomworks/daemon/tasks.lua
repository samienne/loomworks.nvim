--- loomworks/daemon/tasks.lua — the workspace TASK STREAM (spec §19.15).
---
--- A running operation streams `task` events, separate from model changes:
---
---   { kind = "task", task_id, phase = "start", meta = { name, kind, steps } }
---   { kind = "task", task_id, phase = "line", stream = "out"|"note"|"err", text }
---       one of loomworks's own lines (status lines, notes) — the client prints
---       it exactly as the in-process host prints it (stdout line, stderr
---       line, stderr text)
---   { kind = "task", task_id, phase = "output", stream = "stdout"|"stderr", text }
---       raw bytes of a build step
---   { kind = "task", task_id, phase = "progress", pct }
---       coalesced: only when the integer percent advances
---   { kind = "task", task_id, phase = "done", exit_code, error? }
---       the end; `error` is the refusal / failure the client prints as
---       `lw: <error>` before exiting with `exit_code`
---
--- The client that started the task (its OWNER) receives every event,
--- unbounded and in order: the stream is its terminal. It is FLOW-CONTROLLED:
--- when more than `OWNER_HIGH` bytes wait in the owner's connection (a client
--- that stopped reading — `lw build | less`, paused), the task asks its step to
--- stop reading the build tool's output (`set_flow`: the tool then blocks on
--- its full pipe, as it would on a paused terminal in-process) and resumes it
--- once the queue drained below `OWNER_LOW`. The daemon's memory per build is
--- therefore bounded.
---
--- Every other authenticated client OBSERVES the task (a CLI build streams
--- into the editor): it gets at most `OBSERVER_CAP_BYTES` of a task's output,
--- then one truncation notice; an observer whose connection queues more than
--- `OBSERVER_QUEUE_MAX` bytes is dropped (it re-attaches by connecting again)
--- unless it owns a running task itself — then it only misses what it
--- observes. Model changes never travel here.

local protocol = require("loomworks.daemon.protocol")

local M = {}

--- Owner flow control: pause the step's output above this many queued bytes,
--- resume below `OWNER_LOW`.
M.OWNER_HIGH = 4 * 1024 * 1024
M.OWNER_LOW = 1024 * 1024
--- Output bytes of one task an OBSERVER receives before the truncation notice.
M.OBSERVER_CAP_BYTES = 4 * 1024 * 1024
--- An observer connection with more queued bytes than this is dropped.
M.OBSERVER_QUEUE_MAX = 16 * 1024 * 1024

--- Bytes waiting in a connection's write queue.
--- @param conn table
--- @return integer
local function queued(conn)
    local ok, n = pcall(function() return conn.sock:get_write_queue_size() end)
    return (ok and type(n) == "number") and n or 0
end
M._queued = queued

--- @class loomworks.daemon.Task
--- @field id integer
--- @field owner table the owning connection
--- @field finished boolean
--- @field paused boolean the step's output is paused for the owner to catch up
--- @field flow table|nil the running step's output control (`pause`, `resume`)
--- @field obs table<table, { bytes: integer, truncated: boolean }> per observer
local Task = {}
Task.__index = Task

--- @class loomworks.daemon.TaskStream
local Stream = {}
Stream.__index = Stream

--- @param server loomworks.daemon.Server
--- @return loomworks.daemon.TaskStream
function M.new(server)
    return setmetatable({ server = server, tasks = {}, next_id = 0, count = 0 }, Stream)
end

--- Create a task owned by `conn`.
--- @param conn table
--- @return loomworks.daemon.Task
function Stream:create(conn)
    self.next_id = self.next_id + 1
    local t = setmetatable({ id = self.next_id, owner = conn, stream = self, finished = false,
        paused = false, last_pct = -1, obs = setmetatable({}, { __mode = "k" }) }, Task)
    -- Called as each write to the owner completes: resume a paused step once
    -- the owner caught up.
    t._drained = function() t:_owner_drained() end
    self.tasks[t.id] = t
    self.count = self.count + 1
    if self.on_change then pcall(self.on_change, self) end
    return t
end

--- The running tasks owned by `conn`.
--- @param conn table
--- @return loomworks.daemon.Task[]
function Stream:owned_by(conn)
    local out = {}
    for _, t in pairs(self.tasks) do
        if t.owner == conn then out[#out + 1] = t end
    end
    return out
end

--- Any task running?
--- @return boolean
function Stream:busy() return self.count > 0 end

--- Send `msg` to the owner, flow-controlled (see the header).
function Task:_to_owner(msg)
    local o = self.owner
    if not o or o.closed then return end
    self.stream.server:_send(o, msg, self._drained)
    if not self.paused and queued(o) > M.OWNER_HIGH then
        self.paused = true
        if self.flow then pcall(self.flow.pause, self.flow) end
    end
end

--- A write to the owner completed: resume the step when the owner's queue
--- drained (or the owner is gone — its builds are being cancelled).
function Task:_owner_drained()
    if not self.paused then return end
    local o = self.owner
    if o and not o.closed and queued(o) > M.OWNER_LOW then return end
    self.paused = false
    if self.flow then pcall(self.flow.resume, self.flow) end
end

--- The running step's output control (nil between steps): `flow:pause()`
--- stops reading the step's output, `flow:resume()` reads again.
--- @param flow table|nil
function Task:set_flow(flow)
    self.flow = flow
    if flow and self.paused then pcall(flow.pause, flow) end
end

--- May `conn` be sent an observed event? A connection too far behind is
--- dropped — unless it owns a running task (its own terminal): then it only
--- misses this event.
function Task:_observer_ok(conn)
    if queued(conn) <= M.OBSERVER_QUEUE_MAX then return true end
    local srv = self.stream.server
    if not (srv.service and srv.service:owns_task(conn)) then
        srv:_close(conn, "an observer fell too far behind (it can connect again)")
    end
    return false
end

--- The observers of this task (authenticated, open, not the owner).
function Task:_observers()
    local list = {}
    for conn in pairs(self.stream.server.conns or {}) do
        if conn ~= self.owner and conn.authed and not conn.closed then list[#list + 1] = conn end
    end
    return list
end

--- Send `msg` to the owner (always) and to observers (`observe` false: none).
function Task:_emit(msg, observe)
    msg.kind = protocol.KIND.task
    msg.task_id = self.id
    self:_to_owner(msg)
    if observe == false then return end
    local srv = self.stream.server
    for _, conn in ipairs(self:_observers()) do
        if self:_observer_ok(conn) then srv:_send(conn, msg) end
    end
end

--- Announce the task.
--- @param meta table
function Task:start(meta) self:_emit({ phase = "start", meta = meta }) end

--- One of loomworks's own lines.
--- @param stream "out"|"note"|"err"
--- @param text string
function Task:line(stream, text)
    if self.finished then return end
    self:_emit({ phase = "line", stream = stream, text = text })
end

--- Raw output of a step. Each observer sees at most OBSERVER_CAP_BYTES of it.
--- @param stream "stdout"|"stderr"
--- @param text string
function Task:output(stream, text)
    if self.finished then return end
    local msg = { kind = protocol.KIND.task, task_id = self.id, phase = "output", stream = stream, text = text }
    self:_to_owner(msg)
    local srv = self.stream.server
    for _, conn in ipairs(self:_observers()) do
        local st = self.obs[conn]
        if not st then st = { bytes = 0, truncated = false }; self.obs[conn] = st end
        if not st.truncated and self:_observer_ok(conn) then
            if st.bytes + #text > M.OBSERVER_CAP_BYTES then
                st.truncated = true
                srv:_send(conn, { kind = protocol.KIND.task, task_id = self.id, phase = "output",
                    stream = "stderr", text = "[loomworks: task output truncated after "
                        .. math.floor(st.bytes / 1024) .. " KiB]\n" })
            else
                st.bytes = st.bytes + #text
                srv:_send(conn, msg)
            end
        end
    end
end

--- Progress in [0, 1], coalesced to integer-percent advances.
--- @param fraction number
function Task:progress(fraction)
    if self.finished then return end
    local pct = math.max(0, math.min(100, math.floor((fraction or 0) * 100 + 0.5)))
    if pct == self.last_pct then return end
    self.last_pct = pct
    self:_emit({ phase = "progress", pct = pct })
end

--- End the task (idempotent).
--- @param exit_code integer
--- @param err? string the refusal / failure (printed as `lw: <err>`)
function Task:done(exit_code, err)
    if self.finished then return end
    self.finished = true
    self:_emit({ phase = "done", exit_code = exit_code, error = err })
    local s = self.stream
    if s.tasks[self.id] then
        s.tasks[self.id] = nil
        s.count = s.count - 1
    end
    if s.on_change then pcall(s.on_change, s) end
end

M.Task = Task
M.Stream = Stream
return M
