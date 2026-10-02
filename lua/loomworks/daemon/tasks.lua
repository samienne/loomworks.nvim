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
--- unbounded: the stream is its terminal. Every other authenticated client
--- observes the task too (a CLI build streams into the editor); for them
--- output is bounded per task — past `OUTPUT_CAP` chunks it is dropped with a
--- single truncation notice. Model changes never travel here.

local protocol = require("loomworks.daemon.protocol")

local M = {}

--- Output chunks broadcast to OBSERVERS per task before truncation.
M.OUTPUT_CAP = 5000

--- @class loomworks.daemon.Task
--- @field id integer
--- @field owner table the owning connection
--- @field finished boolean
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
        out_count = 0, truncated = false, last_pct = -1 }, Task)
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

--- Send `msg` to the owner (always) and to observers (`observe` false: none;
--- a function: called per observer and returns false to skip).
function Task:_emit(msg, observe)
    msg.kind = protocol.KIND.task
    msg.task_id = self.id
    local srv = self.stream.server
    if self.owner and not self.owner.closed then srv:_send(self.owner, msg) end
    if observe == false then return end
    for conn in pairs(srv.conns or {}) do
        if conn ~= self.owner and conn.authed and not conn.closed then
            srv:_send(conn, msg)
        end
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

--- Raw output of a step. Observers see at most OUTPUT_CAP chunks.
--- @param stream "stdout"|"stderr"
--- @param text string
function Task:output(stream, text)
    if self.finished then return end
    local msg = { phase = "output", stream = stream, text = text }
    msg.kind, msg.task_id = protocol.KIND.task, self.id
    local srv = self.stream.server
    if self.owner and not self.owner.closed then srv:_send(self.owner, msg) end
    if self.out_count >= M.OUTPUT_CAP then
        if not self.truncated then
            self.truncated = true
            local notice = { kind = protocol.KIND.task, task_id = self.id, phase = "output", stream = "stderr",
                text = "[loomworks: task output truncated after " .. M.OUTPUT_CAP .. " chunks]\n" }
            for conn in pairs(srv.conns or {}) do
                if conn ~= self.owner and conn.authed and not conn.closed then srv:_send(conn, notice) end
            end
        end
        return
    end
    self.out_count = self.out_count + 1
    for conn in pairs(srv.conns or {}) do
        if conn ~= self.owner and conn.authed and not conn.closed then srv:_send(conn, msg) end
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
