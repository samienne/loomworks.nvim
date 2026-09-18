--- loomworks/daemon/tasks.lua — the workspace-scoped TASK STREAM (DAEMON.md §3.4).
---
--- High-frequency `progress` / `output` for a running build/op, kept SEPARATE
--- from model-change batches (progress ticks must not churn the model). The
--- stream is workspace-scoped and observable by ANY connected client, so a
--- CLI-launched `lw build` streams into the editor's status page identically to
--- an editor-launched build. The DURABLE outcome arrives separately as a
--- `model_change` (build_state) when the task completes.
---
--- Backpressure (§3.4): the task stream is high-volume, so this stream
--- **coalesces** progress — only the latest fraction per task matters, so a
--- progress tick is broadcast only when its integer percent changes — and
--- **bounds** `output` to a cap per task, after which further output is dropped
--- with a single truncation notice. Model-change batches are never on this path
--- and are never dropped. (Monitoring a slow client's libuv write buffer to drop
--- it and force a reconnect is a further refinement noted in the design.)

local protocol = require("loomworks.daemon.protocol")

--- @class loomworks.daemon.TaskStream
local TaskStream = {}
TaskStream.__index = TaskStream

local M = {}

--- Max `output` events broadcast per task before further output is dropped.
M.OUTPUT_CAP = 5000

--- @param server loomworks.daemon.Server
--- @return loomworks.daemon.TaskStream
function M.new(server)
    return setmetatable({
        _server = server,
        _tasks = {}, -- task_id -> { last_pct, out_count, truncated }
    }, TaskStream)
end

function TaskStream:_state(task_id)
    local s = self._tasks[task_id]
    if not s then s = { last_pct = -1, out_count = 0, truncated = false }; self._tasks[task_id] = s end
    return s
end

--- Announce the start of a task.
--- @param task_id integer|string
--- @param meta? table { name?, kind?, total_steps? }
function TaskStream:start(task_id, meta)
    self:_state(task_id)
    self._server:broadcast({ kind = protocol.KIND.task, task_id = task_id,
        phase = "start", meta = meta })
end

--- Report fractional progress [0,1]. Coalesced: broadcast only when the integer
--- percent advances, so a burst of ticks collapses.
--- @param task_id integer|string
--- @param fraction number
function TaskStream:progress(task_id, fraction)
    local s = self:_state(task_id)
    local pct = math.max(0, math.min(100, math.floor((fraction or 0) * 100 + 0.5)))
    if pct == s.last_pct then return end
    s.last_pct = pct
    self._server:broadcast({ kind = protocol.KIND.task, task_id = task_id,
        phase = "progress", fraction = fraction, pct = pct })
end

--- Emit a chunk of task output. Bounded per task; after the cap, output is
--- dropped and a single truncation notice is broadcast.
--- @param task_id integer|string
--- @param stream "stdout"|"stderr"
--- @param text string
function TaskStream:output(task_id, stream, text)
    local s = self:_state(task_id)
    if s.out_count >= M.OUTPUT_CAP then
        if not s.truncated then
            s.truncated = true
            self._server:broadcast({ kind = protocol.KIND.task, task_id = task_id,
                phase = "output", stream = "stderr",
                text = "[loomworks: task output truncated after " .. M.OUTPUT_CAP .. " chunks]\n" })
        end
        return
    end
    s.out_count = s.out_count + 1
    self._server:broadcast({ kind = protocol.KIND.task, task_id = task_id,
        phase = "output", stream = stream, text = text })
end

--- Mark a task complete. The durable model outcome is a separate model_change;
--- this only closes the ephemeral stream.
--- @param task_id integer|string
--- @param exit_code integer
function TaskStream:done(task_id, exit_code)
    self._tasks[task_id] = nil
    self._server:broadcast({ kind = protocol.KIND.task, task_id = task_id,
        phase = "done", exit_code = exit_code })
end

--- Broadcast a notification (rendered as vim.notify / stderr, §3.4).
--- @param level "info"|"warn"|"error"
--- @param title string
--- @param message string
--- @param task_id? integer|string
function TaskStream:notify(level, title, message, task_id)
    self._server:broadcast({ kind = protocol.KIND.notify, level = level,
        title = title, message = message, task_id = task_id })
end

M.TaskStream = TaskStream
return M
