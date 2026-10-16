--- loomworks/daemon/task_runner.lua — the workspace daemon's tasks in the
--- editor's task runner (overseer) (spec §19.16 "Tasks in the task runner";
--- step 5k part C1b).
---
--- Every daemon task the observer (loomworks.daemon.observer) knows becomes
--- ONE overseer task — one per daemon task, not one per step — run by the
--- overseer strategy `loomworks_daemon` registered here:
---
---   editor-owned (`task.owned`, the editor's own call, §19.15 "The editor as
---   owner"): start = the call (the first start attaches to the task the
---   call already started), stop = `Tasks/1.cancel` (graceful; the overseer
---   task is CANCELED at once, its output follows until the daemon's end),
---   restart = the same call sent again (`editor_ops.rerun`); its end sets
---   SUCCESS / FAILURE by exit code, CANCELED when the editor cancelled it.
---   observed (another client's, `meta.origin`): listed read-only, its
---   origin marker in its name (`[lw] build dev`); stop and restart only say
---   `started by lw (cli) — cancel it there`. Its output starts when the editor
---   joined.
---
--- Output is the task's frames written to a terminal buffer
--- (`nvim_open_term` + `nvim_chan_send`), so colours and overseer's own
--- output actions (open output in quickfix) work as for a local task. It is
--- batched: frames only queue text, a timer writes it at most every FLUSH_MS
--- (flow control, §19.15: the editor's loop never writes per frame). While
--- the terminal cannot be opened (not in normal mode, or a floating window
--- has focus) it is retried every BLOCKED_MS and the queue is coalesced and
--- capped at QUEUE_CAP_BYTES (the oldest output dropped, with a marker).
---
--- When overseer cannot host such tasks (not installed, or its strategy
--- extension point missing) the tasks stay out of its list — remote tasks
--- only (status page) — and the observer's Runtime line notes it once
--- (`Observer.runner_note`).

local M = {}

M.STRATEGY = "loomworks_daemon"

--- Output is written to the terminal at most this often (ms).
M.FLUSH_MS = 30

--- While the terminal cannot be opened, the flush is retried this often (ms).
M.BLOCKED_MS = 250

--- At most this much output is queued while the terminal cannot be opened.
M.QUEUE_CAP_BYTES = 1024 * 1024

M.NOTE = "task runner: overseer cannot host daemon tasks — they are shown on the status page only"

--- @class loomworks.daemon.RunnerBinding
--- @field obs loomworks.daemon.Observer
--- @field owned boolean the editor's own task (stop/restart by calls)
--- @field call { method: string, args: table, units: loomworks.ConfigUnit[]|nil }|nil an owned task's call (restart)
--- @field remote loomworks.RemoteTask|nil the daemon task the first start attaches to

--- @class loomworks.daemon.RunnerStrategy
--- @field name string set by overseer
--- @field binding loomworks.daemon.RunnerBinding
--- @field task table|nil the overseer task
--- @field remote loomworks.RemoteTask|nil the daemon task it follows now
--- @field bufnr integer|nil
--- @field chan integer|nil the terminal channel
--- @field _queue string[] output not written yet
--- @field _qbytes integer bytes in `_queue`
--- @field _dropped_out boolean output was dropped from the queue (cap)
--- @field _timer boolean a flush is scheduled
--- @field _unfollow fun()|nil
--- @field _call_id any an owned restart's accepted task id, before its `start`
--- @field _gen integer bumped by reset/dispose, and by a stop while a restart's call awaits its reply: that reply's task is cancelled
--- @field _awaiting boolean a restart's call awaits its reply
--- @field _superseded table<any, true> task ids of restarts superseded before their reply (cancelled, never listed)
--- @field _stop fun(task: table)|nil the overseer Task's own stop (observed tasks override it)
local Strategy = {}
Strategy.__index = Strategy

--- overseer's strategy constructor: `{ "loomworks_daemon", binding = … }`.
--- @param opts table|nil
--- @return loomworks.daemon.RunnerStrategy
function Strategy.new(opts)
    opts = opts or {}
    return setmetatable({ binding = opts.binding or {}, _queue = {}, _qbytes = 0, _timer = false, _gen = 0,
        _awaiting = false, _superseded = {} }, Strategy)
end

function Strategy:get_bufnr() return self.bufnr end

--- overseer util, when the installed overseer has it.
local function ov_util()
    local ok, util = pcall(require, "overseer.util")
    return ok and type(util) == "table" and util or nil
end

local function delete_buf(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    local util = ov_util()
    if util and util.soft_delete_buf then return util.soft_delete_buf(bufnr) end
    if not pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) then vim.bo[bufnr].bufhidden = "wipe" end
end

--- Stop following the daemon task it follows.
function Strategy:_detach()
    if self._unfollow then self._unfollow() end
    if self.remote and self.remote._runner == self then self.remote._runner = nil end
    self._unfollow = nil
    self.remote = nil
    self._call_id = nil
end

function Strategy:reset()
    self._gen = self._gen + 1
    self._awaiting = false
    self:_detach()
    delete_buf(self.bufnr)
    self.bufnr, self.chan, self._queue, self._qbytes, self._dropped_out = nil, nil, {}, 0, false
end

function Strategy:dispose()
    self:reset()
end

--- Queue output; written by the next flush.
--- @param text string
function Strategy:_write(text)
    if text == "" then return end
    self._queue[#self._queue + 1] = text
    self._qbytes = self._qbytes + #text
    if self.chan == nil and (#self._queue > 64 or self._qbytes > M.QUEUE_CAP_BYTES) then self:_coalesce() end
    self:_schedule()
end

--- Output not written yet (no terminal): one piece of at most
--- QUEUE_CAP_BYTES, the newest output kept.
function Strategy:_coalesce()
    local text = table.concat(self._queue)
    if #text > M.QUEUE_CAP_BYTES then
        text = text:sub(#text - M.QUEUE_CAP_BYTES + 1)
        self._dropped_out = true
    end
    self._queue, self._qbytes = { text }, #text
end

--- @param ms? integer
function Strategy:_schedule(ms)
    if self._timer then return end
    self._timer = true
    vim.defer_fn(function()
        self._timer = false
        self:_flush()
    end, ms or M.FLUSH_MS)
end

--- Open the terminal (in a full-editor window, as overseer's own strategy,
--- so lines are not wrapped at a default width). Only in normal mode
--- outside a floating window — creating it would close a dialog otherwise.
function Strategy:_open_term()
    if self.chan or not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then return end
    local mode = vim.api.nvim_get_mode().mode
    local util = ov_util()
    if mode ~= "n" or (util and util.is_floating_win and util.is_floating_win(0)) then return end
    local function open()
        self.chan = vim.api.nvim_open_term(self.bufnr, {})
        pcall(function() vim.bo[self.bufnr].scrollback = 100000 end)
    end
    if util and util.run_in_fullscreen_win then util.run_in_fullscreen_win(self.bufnr, open) else open() end
end

--- Write the queued output to the terminal.
function Strategy:_flush()
    if #self._queue == 0 or not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then return end
    self:_open_term()
    if not self.chan then return self:_schedule(M.BLOCKED_MS) end
    local text = table.concat(self._queue)
    if self._dropped_out then
        text = "[loomworks: earlier output dropped while the terminal could not be opened]\n" .. text
        self._dropped_out = false
    end
    text = text:gsub("\r?\n", "\r\n")
    self._queue, self._qbytes = {}, 0
    pcall(vim.api.nvim_chan_send, self.chan, text)
    local util = ov_util()
    if util and util.terminal_tail_hack then pcall(util.terminal_tail_hack, self.bufnr) end
end

--- Follow daemon task `remote`: its kept output, then its stream, then its end.
--- @param remote loomworks.RemoteTask
function Strategy:_attach(remote)
    self:_detach()
    self.remote = remote
    remote._runner = self
    self:_write(remote:output())
    if remote.finished then return self:_ended(remote) end
    self._unfollow = remote:follow(function(t, text)
        if t ~= self.remote then return end
        if text == nil then return self:_ended(t) end
        self:_write(text)
    end)
end

--- The daemon task ended (its `done`, the connection lost, or teardown).
--- @param remote loomworks.RemoteTask
function Strategy:_ended(remote)
    self:_write("\n[" .. remote:outcome() .. "]\n")
    self:_flush()
    local task = self.task
    if self._unfollow then self._unfollow() end
    self._unfollow = nil
    if not (task and task.is_running and task:is_running()) then return end
    if remote.cleared or (remote.cancelling and remote.exit_code ~= 0) then
        -- Cleared by teardown, or cancelled from the editor: CANCELED, as a
        -- local task the editor stops (never a cancel sent: it has ended).
        -- One that completed anyway (exit 0) despite the cancel is SUCCESS.
        self.remote = nil
        return (self._stop or task.stop)(task)
    end
    task:on_exit(remote.exit_code or 1)
end

--- Start: an owned or observed task's first start attaches to the daemon
--- task that already runs; an owned task's restart sends its call again.
--- @param task table the overseer task
function Strategy:start(task)
    self.task = task
    if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
        self.bufnr = vim.api.nvim_create_buf(false, true)
    end
    local b = self.binding
    local remote = b.remote
    b.remote = nil
    if remote then return self:_attach(remote) end
    self:_rerun()
end

--- An owned task's restart: the same call again (§19.16). Its reply binds
--- the new daemon task to this overseer task (the observer passes this
--- strategy on to the task's `start`); a call that cannot run fails the
--- overseer task with the reason — nothing runs in-process from a restart.
function Strategy:_rerun()
    local b = self.binding
    local gen = self._gen
    local function fail(why)
        vim.schedule(function()
            if gen ~= self._gen then return end
            self:_write("[not restarted: " .. tostring(why) .. "]\n")
            self:_flush()
            local task = self.task
            if task and task:is_running() then task:on_exit(1) end
        end)
    end
    if not (b.owned and b.call) then return fail("a task of another client is restarted there") end
    self._awaiting = true
    require("loomworks.daemon.editor_ops").rerun(b.obs, b.call, {
        runner = self,
        accepted = function(id)
            if gen ~= self._gen then
                -- Stopped, restarted again, reset or disposed before the
                -- reply: its task is cancelled, and never listed (M.add).
                self._superseded[id] = true
                return b.obs:cancel_owned_id(id)
            end
            self._awaiting = false
            self._call_id = id
        end,
        failed = function(why)
            if gen == self._gen then self._awaiting = false end
            fail(why)
        end,
    })
end

function Strategy:stop()
    local b = self.binding
    if not b.owned then return end
    local remote = self.remote
    if remote and not remote.finished then
        remote.cancelling = true
        b.obs:cancel_owned(remote)
    elseif self._call_id ~= nil then
        b.obs:cancel_owned_id(self._call_id)
    elseif self._awaiting then
        -- The restart's call awaits its reply: the task it starts is
        -- cancelled when the reply arrives (`_rerun`).
        self._awaiting = false
        self._gen = self._gen + 1
    end
end

--- Can overseer host daemon tasks? Registers the strategy on first use.
--- @return table|nil overseer
local function host()
    local ok, ov = pcall(require, "overseer")
    if not ok or type(ov) ~= "table" or type(ov.new_task) ~= "function" then return nil end
    local name = "overseer.strategy." .. M.STRATEGY
    if not package.loaded[name] and not package.preload[name] then
        local okl, strat = pcall(require, "overseer.strategy")
        if not okl or type(strat) ~= "table" or type(strat.load) ~= "function" then return nil end
        package.preload[name] = function() return Strategy end
    end
    return ov
end

--- The read-only message of an observed task's stop / restart.
--- @param remote loomworks.RemoteTask
--- @return string
function M.read_only_message(remote)
    local who = remote.origin == "cli" and "lw (cli)" or remote:origin_label() or "another client"
    return "loomworks: started by " .. who .. " — cancel it there"
end

--- The overseer task name of a daemon task: its name, an observed task's
--- with its origin marker (`[lw] build dev`); a task carrying steps (step
--- 5t, §19.15 "Steps of a task") with its current step (`dev — dependency
--- lib (1/3)`).
--- @param remote loomworks.RemoteTask
--- @return string
function M.task_name(remote)
    local who = remote:origin_label()
    local name = who and ("[" .. who .. "] " .. remote.name) or remote.name
    local step = remote.step_text and remote:step_text()
    if step then name = name .. " — " .. step end
    return name
end

--- The task's current step moved (step 5t): its one overseer row follows it
--- (§19.16 "Tasks in the task runner") — renamed and re-rendered.
--- @param remote loomworks.RemoteTask
function M.step(remote)
    local task = M.overseer_task(remote)
    if not task then return end
    task.name = M.task_name(remote)
    local ok, list = pcall(require, "overseer.task_list")
    if ok and type(list) == "table" and type(list.touch) == "function" then pcall(list.touch, task) end
end

--- A daemon task the observer started tracking: its overseer task. `runner`:
--- the strategy of an owned task's restart, which this task continues.
--- @param obs loomworks.daemon.Observer
--- @param remote loomworks.RemoteTask
--- @param runner loomworks.daemon.RunnerStrategy|nil
function M.add(obs, remote, runner)
    -- The restart's own call (not one a reset or dispose has since dropped):
    -- the task continues that overseer task, stopped meanwhile or not.
    if runner and runner._call_id ~= nil and runner._call_id == remote.id then
        return runner:_attach(remote)
    end
    -- A restart superseded before its reply (stopped, restarted again,
    -- reset or disposed): being cancelled, it is never a task of its own.
    if runner and runner._superseded and runner._superseded[remote.id] then
        runner._superseded[remote.id] = nil
        return
    end
    local ov = host()
    if not ov then
        if not obs.runner_note then
            obs.runner_note = M.NOTE
            if obs._connected_note then pcall(obs._connected_note, obs) end
        end
        return
    end
    local o = obs._owned and obs._owned[remote.id]
    local binding = {
        obs = obs, owned = remote.owned == true, remote = remote,
        call = o and { method = o.method, args = o.args, units = o.units } or nil,
    }
    local ok, task = pcall(ov.new_task, {
        name = M.task_name(remote),
        cmd = { "lw", remote.kind },
        cwd = obs.root,
        strategy = { M.STRATEGY, binding = binding },
        components = { "default" },
        metadata = { loomworks_daemon_task = remote.id },
    })
    if not ok or type(task) ~= "table" then return end
    if not binding.owned then
        -- Read-only: another client's task is stopped and restarted there
        -- (§19.15). The strategy keeps overseer's own stop for teardown; a
        -- forced dispose uses it too, quietly (no cancel is sent).
        local strategy = task.strategy
        local own_stop, own_dispose = task.stop, task.dispose
        if type(strategy) == "table" then strategy._stop = own_stop end
        local disposing = false
        local function refuse()
            vim.notify(M.read_only_message(remote), vim.log.levels.WARN)
            return false
        end
        task.stop = function(self)
            if disposing then return own_stop(self) end
            return refuse()
        end
        task.restart = refuse
        if type(own_dispose) == "function" then
            task.dispose = function(self, ...)
                disposing = true
                local okd, r = pcall(own_dispose, self, ...)
                disposing = false
                if not okd then error(r, 0) end
                return r
            end
        end
    end
    pcall(task.start, task)
end

--- The overseer task of daemon task `remote`, if it has one.
--- @param remote loomworks.RemoteTask
--- @return table|nil
function M.overseer_task(remote)
    local s = remote and remote._runner
    local task = s and s.task
    if not task or task.status == "DISPOSED" then return nil end
    return task
end

--- Open overseer's task list (the status page's `Open overseer` on a
--- daemon task's row, as on a local task's).
--- @param remote loomworks.RemoteTask
--- @return boolean opened
function M.open(remote)
    if not M.overseer_task(remote) then return false end
    local ok, ov = pcall(require, "overseer")
    if not (ok and type(ov) == "table" and ov.open) then return false end
    ov.open({ enter = true })
    return true
end

M.Strategy = Strategy
return M
