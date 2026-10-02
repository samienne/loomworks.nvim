--- loomworks/daemon/service.lua — the daemon's live workspace and the
--- `build` operation (spec §19.15, §19.19 step 3).
---
--- **Live workspace.** The daemon loads its workspace on the first operation
--- (through the host's loader — the same load as the in-process path, which
--- refuses a workspace exactly as `lw` does) and keeps it. Before accepting
--- each operation it applies every pending external change to its files
--- exactly as its file watcher would (`FileTracker:sync` →
--- `Workspace:_on_file_changed`, including a trust refusal, §17.4), completes
--- or refuses a commit journal (§19.4) by reloading, and reloads when the
--- requesting client's environment differs from the one the workspace was
--- loaded in (`envscope.signature`). The workspace's file tracker never polls
--- in the daemon: changes are applied only here, inside a client's
--- environment.
---
--- **Model segments.** Every piece of model work — the live sync or (re)load,
--- argument resolution, lock acquisition, planning, gates, cache write-back —
--- runs through `with_model`: serialized (one at a time, FIFO, also when a
--- segment pumps the event loop), on the main loop (never in a libuv fast
--- callback), with the process environment switched to the requesting
--- client's (`envscope.with`).
---
--- **Request** `{ kind = "build", args, interactive, env, command }` →
--- reply `ok` with `outcome`:
---   * "accepted" (`task_id`, `profile_key`, `pid`) — the build runs as a task
---     owned by this connection (loomworks.daemon.runner, .tasks);
---   * "refused" (`message`, `exit_code`) — before any side effect: the
---     workspace refused (trust, journal, newer schema), the profile argument
---     does not resolve; the client prints it as the in-process host would;
---   * "declined" (`reason`) — before any side effect: the daemon does not
---     carry this request (interactive profile onboarding; a different
---     environment while another build runs). The client runs in-process.

local build_run = require("loomworks.build_run")
local envscope = require("loomworks.daemon.envscope")
local protocol = require("loomworks.daemon.protocol")
local tasks_mod = require("loomworks.daemon.tasks")

local M = {}

--- How long a (re)load or a tool scan after a change may take.
M.LOAD_WAIT_MS = 45000

--- @class loomworks.daemon.BuildService
--- @field server loomworks.daemon.Server
--- @field host table { load(root, handlers) → ws|nil, err; unload(); current() → the loaded
---   workspace (nil while it (re)loads); settle(ms); setup_error() → refusal; unknown_target_hint? }
--- @field ws table|nil the live workspace
--- @field env_sig string|nil the environment signature `ws` was loaded in
local Service = {}
Service.__index = Service

--- Attach the build service to a server.
--- @param server loomworks.daemon.Server
--- @param host table
--- @return loomworks.daemon.BuildService
function M.attach(server, host)
    local self = setmetatable({ server = server, host = host, runs = {}, queue = {} }, Service)
    self.tasks = tasks_mod.new(server)
    self.tasks.on_change = function(s)
        local busy = s:busy()
        if server.busy ~= busy then
            server.busy = busy
            if not busy then server.idle_since = os.time() end
            server:_handle_changed()
        end
        if not busy then server:_maybe_retire() end
    end
    envscope.install()
    server.service = self
    return self
end

--- Run `fn` as a model segment of request `ctx` (see the header). Queued
--- behind the running segment, if any.
--- @param ctx table { env }
--- @param fn fun()
function Service:with_model(ctx, fn)
    self.queue[#self.queue + 1] = { ctx = ctx, fn = fn }
    if self.draining or self.scheduled then return end
    self.scheduled = true
    vim.schedule(function()
        self.scheduled = false
        self:_drain()
    end)
end

function Service:_drain()
    if self.draining then return end
    self.draining = true
    while #self.queue > 0 do
        local item = table.remove(self.queue, 1)
        self.current = item.ctx
        local ok, err = pcall(envscope.with, item.ctx.env, item.fn)
        self.current = nil
        if not ok then
            self.server:log("internal error in a build: %s", tostring(err))
            local c = item.ctx
            if c.run and not c.run.finished then
                pcall(c.run.cancel, "internal error: " .. tostring(err), 1)
            elseif c.reply and not c.replied then
                c.reply({ outcome = "declined", reason = "internal error" })
            end
        end
    end
    self.draining = false
end

--- The handlers the host's loader installs on the workspace core: they report
--- into the request whose segment is running (a notification is printed on
--- that client's stderr, a refused save ends its build), else the runtime log.
--- @return table
function Service:handlers()
    return {
        notify = function(msg, level)
            if level and level < vim.log.levels.WARN then return end
            local c = self.current
            if c and c.task then c.task:line("err", tostring(msg) .. "\n")
            elseif c then c.notes = c.notes or {}; c.notes[#c.notes + 1] = tostring(msg)
            else self.server:log("%s", tostring(msg)) end
        end,
        refused = function(msg)
            local c = self.current
            if c then c.refused = c.refused or tostring(msg) end
            self.server:log("refused: %s", tostring(msg))
        end,
        -- A committed write of a state file: tell the clients (§19.12).
        written = function() self.server:model_changed() end,
    }
end

--- Running builds bound to a workspace that is no longer the live one are
--- stopped (§19.15: the workspace was unloaded or reloaded under them).
function Service:_stop_stale_runs(why)
    for run in pairs(self.runs) do
        if run.ctx.ws ~= self.ws then run.cancel(why, 1) end
    end
end

--- Drop the live workspace (teardown through the host).
function Service:_unload()
    if self.ws then
        self.ws = nil
        self.env_sig = nil
        pcall(self.host.unload)
        self:_stop_stale_runs("the workspace was reloaded")
    end
end

--- The live workspace for request `ctx`, re-validated (see the header).
--- Returns ws; or nil + refusal message; or nil, nil, decline reason.
--- @param ctx table
--- @return table|nil ws, string|nil refusal, string|nil decline
function Service:live(ctx)
    local root = self.server.root
    local sig = envscope.signature(ctx.env)
    if self.ws and self.host.current() ~= self.ws then
        -- Unloaded under us (a refusal during an earlier sync).
        self.ws, self.env_sig = nil, nil
        self:_stop_stale_runs("the workspace was unloaded (refused or reloaded .nvim files)")
    end
    if self.ws and self.env_sig ~= sig then
        if next(self.runs) then
            return nil, nil, "another build runs in the workspace daemon with a different environment"
        end
        self:_unload()
    end
    -- A commit journal (§19.4): a full load completes or refuses it.
    if self.ws and require("loomworks.txn").read_journal(root) ~= nil then self:_unload() end
    if self.ws then
        local tr = self.ws._tracker
        if tr and tr.sync then tr:sync() end
        if self.host.current() ~= self.ws then
            -- A refused file put the core back through setup (§17.4): wait for
            -- it, then use what it produced — or report its refusal.
            self.host.settle(M.LOAD_WAIT_MS)
            self.ws, self.env_sig = nil, nil
            self:_stop_stale_runs("the workspace was unloaded (refused or reloaded .nvim files)")
            local now = self.host.current()
            if not now then
                return nil, self.host.setup_error()
            end
            self.ws, self.env_sig = now, sig
        end
        -- A changed loomworks.json rescans tools: wait for it, as the load does.
        if self.ws._tool_state ~= "scanned" then
            vim.wait(M.LOAD_WAIT_MS, function() return self.ws._tool_state == "scanned" end, 25)
        end
        return self.ws
    end
    local ws, err = self.host.load(root, self:handlers())
    if not ws then return nil, err or "failed to load workspace" end
    self.ws, self.env_sig = ws, sig
    return ws
end

--- Handle a `build` request on an authenticated connection.
--- @param conn table
--- @param msg table
function Service:on_build(conn, msg)
    local srv = self.server
    local env, eerr = envscope.validate(msg.env)
    local ctx = { conn = conn, env = env, args = type(msg.args) == "table" and msg.args or {},
        interactive = msg.interactive == true, command = type(msg.command) == "string" and msg.command or "lw build" }
    function ctx.reply(fields)
        ctx.replied = true
        fields.kind = protocol.KIND.ok
        fields.req_id = msg.req_id
        srv:_send(conn, fields)
    end
    if not env then return ctx.reply({ outcome = "declined", reason = eerr }) end
    if srv.retiring then return ctx.reply({ outcome = "declined", reason = "the daemon is retiring" }) end
    local a = ctx.args
    for _, list in ipairs({ "targets", "extra" }) do
        if a[list] ~= nil and type(a[list]) ~= "table" then
            return ctx.reply({ outcome = "declined", reason = "malformed request" })
        end
        for _, v in ipairs(a[list] or {}) do
            if type(v) ~= "string" then return ctx.reply({ outcome = "declined", reason = "malformed request" }) end
        end
    end
    if a.profile ~= nil and type(a.profile) ~= "string" then
        return ctx.reply({ outcome = "declined", reason = "malformed request" })
    end
    self:with_model(ctx, function() self:_accept(ctx) end)
end

--- The model segment that accepts (or refuses / declines) a build.
function Service:_accept(ctx)
    if ctx.conn.closed then return end
    local ws, refusal, decline = self:live(ctx)
    if not ws then
        if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
        return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1, notes = ctx.notes })
    end
    if ctx.refused then
        return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1, notes = ctx.notes })
    end
    local a = ctx.args
    local profile, err, action = build_run.resolve_target(ws, a.profile, { interactive = ctx.interactive })
    if action == "onboard" then
        return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
    end
    if not profile then
        return ctx.reply({ outcome = "refused", message = err, exit_code = 1, notes = ctx.notes })
    end
    local task = self.tasks:create(ctx.conn)
    ctx.task, ctx.ws, ctx.profile = task, ws, profile
    ctx.reply({ outcome = "accepted", task_id = task.id, profile_key = profile.key, pid = self.server.pid,
        notes = ctx.notes })
    local runner = require("loomworks.daemon.runner")
    local run = runner.run(self, {
        task = task, ws = ws, profile = profile, env = ctx.env, command = ctx.command,
        args = { extra = (a.extra and #a.extra > 0) and a.extra or nil,
            targets = (a.targets and #a.targets > 0) and a.targets or nil,
            force = a.force == true, reconfigure = a.reconfigure == true, verbose = a.verbose == true },
    })
    self.server:log("build %s (task %d) accepted", profile.key, task.id)
    if run and not run.finished then
        run.ctx = ctx
        self.runs[run] = true
    end
end

--- A run ended (runner callback).
function Service:on_run_done(run)
    self.runs[run] = nil
    if run.task then
        self.server:log("build task %d ended%s", run.task.id,
            run.cancelled and (": " .. tostring(run.cancel_reason)) or "")
    end
end

--- Does `conn` own a running build? (The keepalive rule never drops it.)
--- @param conn table
--- @return boolean
function Service:owns_task(conn)
    return #self.tasks:owned_by(conn) > 0
end

--- The owning client disconnected: cancel its builds (§19.15). Called from
--- the connection's read callback, so the cancellation — which kills the
--- step's process tree and waits for it to go — runs on the main loop
--- afterwards, never inside the callback.
--- @param conn table
function Service:on_conn_closed(conn)
    local mine = {}
    for run in pairs(self.runs) do
        if run.ctx.conn == conn then mine[#mine + 1] = run end
    end
    if #mine == 0 then return end
    vim.schedule(function()
        for _, run in ipairs(mine) do run.cancel("the client that started it disconnected", 130) end
    end)
end

--- The daemon is stopping: cancel every build, synchronously (kill the step,
--- release the locks), before the process ends.
--- @param reason string
function Service:on_stopping(reason)
    for run in pairs(self.runs) do
        if not run.finished then
            run.cancel("the workspace daemon stopped (" .. tostring(reason) .. ")", 1)
        end
    end
    -- A run without a child finishes in a model segment: drain now (the
    -- process ends right after).
    if #self.queue > 0 and not self.draining then self:_drain() end
    -- Whatever still holds a lock releases it here.
    local build_lock = require("loomworks.build_lock")
    for run in pairs(self.runs) do
        for _, h in ipairs(run.held or {}) do build_lock.release(h) end
        if run.task then run.task:done(run.cancel_code or 1, "build stopped: the workspace daemon stopped") end
    end
end

M.Service = Service
return M
