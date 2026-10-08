--- loomworks/daemon/service.lua — the daemon's live workspace and the
--- routed operations: `build`, the batch `test`, the preparation of a run and
--- `clean` (spec §19.15, §19.19 steps 3, 5 and 5c).
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
---
--- **Request** `{ kind = "test", args = { profile?, junit?, extra? }, … }` —
--- the same outcomes; also "refused" for a foreign kit's profile (§18.6).
---
--- **Request** `{ kind = "prepare_run", args = { profile?, target?, project?,
--- kind?, cwd?, extra?, no_build?, quiet? }, … }` (§19.15 "Run") — the same
--- outcomes; also "declined" for a profile one of whose units builds with a
--- foreign kit (device runs stay in the client). The task builds, selects,
--- deploys and resolves the launch; its `done` carries the resolved `launch`
--- (or `device = true`) and the client executes the program.
---
--- **Request** `{ kind = "clean", args = { profile? }, … }` (§19.15 "Clean")
--- — the same outcomes; also "refused" with the in-process `nothing to clean
--- …` line when the profile has no configured build directory to clean,
--- decided after resolution and before any lock (as in-process).
---
--- **Request** `{ kind = "reset", args = { profile?, all?, yes?, plan? }, … }`
--- (§19.15 "Reset") — the outcomes of `build`, plus "confirm" (`lines`,
--- `plan`, `profile_key`): the reset is planned (loomworks.reset_plan, as
--- in-process) after resolution and before any lock or side effect. Nothing
--- to reset: "refused" with the in-process line, exit code 0 and `stream =
--- "out"` (printed on standard output). Without `yes`: "confirm" — the
--- listing and the plan token; no lock taken, nothing changed. With `yes`
--- and a `plan` the token differs from: "refused" (`reset_plan.CHANGED`,
--- exit 1). Otherwise "accepted" (`profile_key` absent for `--all`); the task
--- prints the listing first only when no `plan` was sent (`-y`).
---
--- **Request** `{ kind = "snapshot", scope?, env }` (§19.13) → reply `ok`
--- with `outcome = "ok"`, the scope's tables, `tools`, `shared_ignored`,
--- `index`, `seq` and `session_generation` (loomworks.daemon.snapshot); or
--- "refused" / "declined" as for `build`. No task, no lock. A loaded model is
--- served as it is (`live` with `as_is`: no reload for another environment,
--- no file check, no tool wait); with none loaded, it is loaded in the
--- request's environment without waiting for tool detection.
---
--- **Request** `{ kind = "query", name, args?, env }` (§19.14) → reply `ok`
--- with `outcome = "ok"` and `result`; "refused" (`message`) for an unknown
--- query or a failed one; "declined" as for `build`. Read-only: it runs in
--- the request's environment (its model segment) against the model as it is,
--- loaded as for `snapshot`, and never unloads it.

local build_run = require("loomworks.build_run")
local envscope = require("loomworks.daemon.envscope")
local protocol = require("loomworks.daemon.protocol")
local snapshot = require("loomworks.daemon.snapshot")
local tasks_mod = require("loomworks.daemon.tasks")

local M = {}

--- How long a (re)load or a tool scan after a change may take.
M.LOAD_WAIT_MS = 45000

--- @class loomworks.daemon.BuildService
--- @field server loomworks.daemon.Server
--- @field host table { load(root, handlers, opts?: { wait_tools?: boolean }) → ws|nil, err; unload(); current() → the loaded
---   workspace (nil while it (re)loads); settle(ms); setup_error() → refusal; unknown_target_hint?;
---   error_state?() → { message, refused? }|nil, the failed load the welcome header reports }
--- @field ws table|nil the live workspace
--- @field env_sig string|nil the environment signature `ws` was loaded in
--- @field stopping boolean|nil the server is stopping (`on_stopping`): no new request starts
--- @field ids loomworks.daemon.IdRegistry the session's opaque-id registry (§19.12)
local Service = {}
Service.__index = Service

--- Attach the build service to a server.
--- @param server loomworks.daemon.Server
--- @param host table
--- @return loomworks.daemon.BuildService
function M.attach(server, host)
    local self = setmetatable({ server = server, host = host, runs = {}, queue = {},
        ids = snapshot.registry(server.generation) }, Service)
    self.tasks = tasks_mod.new(server)
    self.tasks.on_change = function() self:_update_busy() end
    -- The task signals of loomworks.Tasks/1 (§19.20), to /tasks subscribers.
    local core_ifaces = require("loomworks.daemon.core_interfaces")
    self.tasks.on_started = function(t, info)
        if server.interfaces then core_ifaces.task_signal(server.interfaces, t, "started", { task = info }) end
    end
    self.tasks.on_ended = function(t, exit_code, err)
        if server.interfaces then
            core_ifaces.task_signal(server.interfaces, t, "ended",
                { task_id = t.id, exit_code = exit_code, error = type(err) == "string" and err or nil })
        end
    end
    envscope.install()
    server.service = self
    -- The core interfaces it serves (step 5g.2), once the registry exists.
    if server.interfaces then core_ifaces.mount(server.interfaces, self) end
    -- The header `header_changed` compares with (unloaded: never loads).
    core_ifaces.header_check(self)
    return self
end

--- The run a task belongs to (nil: none, or it already ended).
--- @param task loomworks.daemon.Task
--- @return table|nil
function Service:run_of_task(task)
    for run in pairs(self.runs) do
        if run.task == task then return run end
    end
    return nil
end

--- Is a reset's deletion still running after its task ended (a timeout,
--- spec §19.15 "Reset")? Its locks are still held and its subprocesses run.
--- @return boolean
function Service:_deletion_unsettled()
    for run in pairs(self.runs) do
        if run.deleting and not run.deletion_settled then return true end
    end
    return false
end

--- The server is busy while a task runs or a reset's deletion is unsettled:
--- never idle (no idle stop, no retirement) mid-deletion.
function Service:_update_busy()
    local server = self.server
    local busy = self.tasks:busy() or self:_deletion_unsettled()
    if server.busy ~= busy then
        server.busy = busy
        if not busy then server.idle_since = os.time() end
        server:_handle_changed()
    end
    if not busy then server:_maybe_retire() end
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
        local ok, err = true, nil
        if self.stopping and not item.ctx.run then
            -- Stopping: a request not yet accepted is declined, never started
            -- (onboarding would write the working copy, steps would spawn).
            -- An accepted run's segment still runs: it finishes the run.
            if item.ctx.reply and not item.ctx.replied then
                pcall(item.ctx.reply, { outcome = "declined", reason = "the workspace runtime is stopping" })
            end
        else
            ok, err = pcall(envscope.with, item.ctx.env, item.fn)
        end
        self.current = nil
        -- A segment may have loaded, reloaded or failed to load the
        -- workspace: Workspace/1's `header_changed` (§19.20).
        pcall(require("loomworks.daemon.core_interfaces").header_check, self)
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
--- `as_is` (the read-only `snapshot` and `query` requests): a loaded model is
--- returned as it is — never reloaded for another environment, no commit
--- journal or file check (they may write), no wait for tool detection — and
--- with none loaded, the load does not wait for tool detection either.
--- @param ctx table
--- @param as_is? boolean
--- @return table|nil ws, string|nil refusal, string|nil decline
function Service:live(ctx, as_is)
    local root = self.server.root
    local sig = envscope.signature(ctx.env)
    if self.ws and self.host.current() ~= self.ws then
        -- Unloaded under us (a refusal during an earlier sync).
        self.ws, self.env_sig = nil, nil
        self:_stop_stale_runs("the workspace was unloaded (refused or reloaded .nvim files)")
    end
    if as_is then
        if self.ws then return self.ws end
        local ws, err = self.host.load(root, self:handlers(), { wait_tools = false })
        if not ws then return nil, err or "failed to load workspace" end
        self.ws, self.env_sig = ws, sig
        return ws
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
    return self:_on_operation("build", conn, msg)
end

--- Handle a `test` request (the batch `lw test`, spec §19.15) on an
--- authenticated connection.
--- @param conn table
--- @param msg table
function Service:on_test(conn, msg)
    return self:_on_operation("test", conn, msg)
end

--- Handle a `prepare_run` request (the preparation of `lw run`, spec §19.15
--- "Run") on an authenticated connection.
--- @param conn table
--- @param msg table
function Service:on_run(conn, msg)
    return self:_on_operation("run", conn, msg)
end

--- Handle a `clean` request (`lw clean`, spec §19.15 "Clean") on an
--- authenticated connection.
--- @param conn table
--- @param msg table
function Service:on_clean(conn, msg)
    return self:_on_operation("clean", conn, msg)
end

--- Handle a `reset` request (`lw reset`, spec §19.15 "Reset") on an
--- authenticated connection.
--- @param conn table
--- @param msg table
function Service:on_reset(conn, msg)
    return self:_on_operation("reset", conn, msg)
end

--- The `welcome` header's model fields (§19.13): the live workspace's name
--- and active profile, else the host's load failure. Never loads.
--- @return table
function Service:header()
    local ws = self.ws
    if ws and self.host.current and self.host.current() ~= ws then ws = nil end
    local err = (not ws and self.host.error_state) and self.host.error_state() or nil
    return snapshot.header(ws, err)
end

--- A read-only model request (`snapshot`, `query`): validate it, then answer
--- it in a model segment against the live workspace, in the client's
--- environment. `answer(ws, ctx)` returns the reply's fields (`outcome`
--- defaults to "ok").
--- @param conn table
--- @param msg table
--- @param answer fun(ws: table, ctx: table): table
--- @param bad string|nil a validation failure: declined as malformed
--- @param deliver? fun(fields: table) answer an interface call instead of a v0 reply
function Service:_on_model_request(conn, msg, answer, bad, deliver)
    local srv = self.server
    local env, eerr = envscope.validate(msg.env)
    local ctx = { op = msg.kind, conn = conn, env = env, args = {} }
    function ctx.reply(fields)
        ctx.replied = true
        -- An interface method's adapter takes the fields as its result.
        if deliver then return deliver(fields) end
        fields.kind = protocol.KIND.ok
        fields.req_id = msg.req_id
        srv:_send(conn, fields)
    end
    if not env then return ctx.reply({ outcome = "declined", reason = eerr }) end
    if bad then return ctx.reply({ outcome = "declined", reason = bad }) end
    if self.stopping or srv.stopped then
        return ctx.reply({ outcome = "declined", reason = "the workspace runtime is stopping" })
    end
    self:with_model(ctx, function()
        if ctx.conn.closed then return end
        -- Tests: a slow model segment (the client's read deadline, §19.1).
        local delay = tonumber(env.LW_TEST_MODEL_DELAY_MS or "")
        if delay then vim.wait(delay, function() return ctx.conn.closed end, 10) end
        local ws, refusal, decline = self:live(ctx, true)
        if not ws then
            if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
            return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1, notes = ctx.notes })
        end
        if ctx.refused then
            return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1, notes = ctx.notes })
        end
        local fields = answer(ws, ctx)
        fields.outcome = fields.outcome or "ok"
        fields.notes = ctx.notes
        ctx.reply(fields)
    end)
end

--- Handle a `snapshot` request (§19.13): the scope's tables of the live
--- model, its toolchain detection and the current-key → id index.
--- @param conn table
--- @param msg table
function Service:on_snapshot(conn, msg)
    local bad = not snapshot.valid_scope(msg.scope) and "malformed request" or nil
    return self:_on_model_request(conn, msg, self:_snapshot_answer(conn, msg.scope), bad)
end

--- The model segment's answer to a snapshot of `scope` (the `snapshot`
--- request and lw.internal.Snapshot/1.get).
--- @param conn table
--- @param scope string|nil
--- @return fun(ws: table): table
function Service:_snapshot_answer(conn, scope)
    return function(ws)
        local snap = snapshot.build(ws, scope, self.ids)
        snap.seq, snap.session_generation = self.server.seq, self.server.generation
        self.server:log("snapshot (scope %s) for %s", tostring(snap.scope), self.server:_peer_text(conn))
        return snap
    end
end

--- Handle a `query` request (§19.14): a registered host-probing query run
--- against the live model in the client's environment.
--- @param conn table
--- @param msg table
function Service:on_query(conn, msg)
    local bad = (type(msg.name) ~= "string" or (msg.args ~= nil and type(msg.args) ~= "table"))
        and "malformed request" or nil
    return self:_on_model_request(conn, msg, function(ws)
        return self:_query(conn, ws, msg.name, msg.args or {})
    end, bad)
end

--- Run registered query `name` against the live model (the `query` request
--- and its interface methods, Toolchains/1.list and Profiles/1.compiler_cache):
--- `{ result }`, or a refusal.
--- @param conn table
--- @param ws table
--- @param name string
--- @param args table
--- @return table
function Service:_query(conn, ws, name, args)
    local fn = snapshot.QUERIES[name]
    if not fn then return { outcome = "refused", message = "unknown query: " .. name, exit_code = 1 } end
    self.server:log("query %s for %s", name, self.server:_peer_text(conn))
    local ok, result, err = pcall(fn, ws, args)
    if not ok or result == nil then
        return { outcome = "refused", message = "query " .. name .. " failed: "
            .. tostring(ok and err or result), exit_code = 1 }
    end
    return { result = result }
end

--- Is `a` (a `reset` request's args) well-formed?
--- @param a table
--- @return boolean
local function reset_args_ok(a)
    for _, k in ipairs({ "all", "yes" }) do
        if a[k] ~= nil and type(a[k]) ~= "boolean" then return false end
    end
    if a.plan ~= nil and type(a.plan) ~= "string" then return false end
    -- (`--all` with a profile: cmd_reset refuses it; never sent.)
    if a.all and (a.profile ~= nil or a.profile_id ~= nil) then return false end
    return true
end

--- Is `a` (a `prepare_run` request's args) well-formed?
--- @param a table
--- @return boolean
local function run_args_ok(a)
    for _, k in ipairs({ "target", "project", "cwd" }) do
        if a[k] ~= nil and type(a[k]) ~= "string" then return false end
    end
    if a.kind ~= nil and a.kind ~= "target" and a.kind ~= "launch" then return false end
    for _, k in ipairs({ "no_build", "quiet", "prefix" }) do
        if a[k] ~= nil and type(a[k]) ~= "boolean" then return false end
    end
    return true
end

--- A routed operation's request: validate it, then accept it in a model
--- segment. The protocol-10 request and the task-streamed interface method
--- (Build/1, Tests/1.run, Launch/1.prepare_run; daemon/core_interfaces.lua)
--- are this one implementation: the method passes `deliver` (its reply) and
--- `call` (the task's interface identity and result, `Task.call`).
--- @param op "build"|"test"|"run"|"clean"|"reset"
--- @param conn table
--- @param msg table
--- @param deliver? fun(fields: table) answer an interface call instead of a v0 reply
--- @param call? loomworks.daemon.TaskCall
function Service:_on_operation(op, conn, msg, deliver, call)
    local srv = self.server
    local env, eerr = envscope.validate(msg.env)
    local ctx = { op = op, conn = conn, env = env, args = type(msg.args) == "table" and msg.args or {},
        interactive = msg.interactive == true, call = call,
        command = type(msg.command) == "string" and msg.command or ("lw " .. op) }
    function ctx.reply(fields)
        ctx.replied = true
        if deliver then return deliver(fields) end
        fields.kind = protocol.KIND.ok
        fields.req_id = msg.req_id
        srv:_send(conn, fields)
    end
    if not env then return ctx.reply({ outcome = "declined", reason = eerr }) end
    if self.stopping or srv.stopped then
        return ctx.reply({ outcome = "declined", reason = "the workspace runtime is stopping" })
    end
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
    if (a.profile ~= nil and type(a.profile) ~= "string") or (a.junit ~= nil and type(a.junit) ~= "string")
        or (a.profile_id ~= nil and (type(a.profile_id) ~= "string" or a.profile ~= nil))
        or (a.project_id ~= nil and (type(a.project_id) ~= "string" or a.project ~= nil))
        or (op == "run" and not run_args_ok(a)) or (op == "reset" and not reset_args_ok(a)) then
        return ctx.reply({ outcome = "declined", reason = "malformed request" })
    end
    self:with_model(ctx, function() self:_accept(ctx) end)
end

--- An interface call's references by id (`args.profile_id`,
--- `args.project_id`; §19.20 "References"): resolved to the entity's key in
--- `args.profile` / `args.project`, as the CLI's key would be. Returns the
--- refusal of a stale or unknown id.
--- @param ws table the live workspace
--- @param a table the operation's args
--- @return string|nil refusal
function Service:_resolve_ids(ws, a)
    for _, r in ipairs({ { "profile", ws._profiles }, { "project", ws._projects } }) do
        local name, list = r[1], r[2]
        local id = a[name .. "_id"]
        if id ~= nil then
            local obj = self.ids:find(id, list)
            if not obj then return "no " .. name .. " with id " .. tostring(id) .. " (a stale reference)" end
            a[name], a[name .. "_id"] = obj.key, nil
        end
    end
    return nil
end

--- The model segment that accepts (or refuses / declines) a build, a test
--- run, a run's preparation or a clean.
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
    local stale = self:_resolve_ids(ws, ctx.args)
    if stale then return ctx.reply({ outcome = "refused", message = stale, exit_code = 1, notes = ctx.notes }) end
    if ctx.op == "reset" then return self:_accept_reset(ctx, ws) end
    local a = ctx.args
    local profile, err, action = build_run.resolve_target(ws, a.profile, { interactive = ctx.interactive,
        usage = ctx.op == "run" and "lw run <profile> <target>" or ("lw " .. ctx.op .. " <profile>") })
    if action == "onboard" then
        return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
    end
    if not profile then
        return ctx.reply({ outcome = "refused", message = err, exit_code = 1, notes = ctx.notes })
    end
    -- A foreign kit's registered tests cannot run on this host (§18.6).
    local foreign = ctx.op == "test" and build_run.foreign_batch_refusal(profile) or nil
    if foreign then
        return ctx.reply({ outcome = "refused", message = foreign, exit_code = 1, notes = ctx.notes })
    end
    -- A run of a profile built by a foreign kit is a device run: its device
    -- locks, staging and program liveness stay with the client (§19.15).
    local platform = ctx.op == "run" and require("loomworks.run_prep").kit_platform(profile) or nil
    if platform then
        return ctx.reply({ outcome = "declined", reason = "profile '" .. profile.key .. "' builds for "
            .. platform .. "; device runs stay in this process" })
    end
    -- Nothing to clean: refused with the in-process line, before any lock.
    local clean_steps
    if ctx.op == "clean" then
        clean_steps = build_run.plan_clean(profile)
        if not clean_steps then
            return ctx.reply({ outcome = "refused", message = build_run.nothing_to_clean_message(profile),
                exit_code = 1, notes = ctx.notes })
        end
    end
    local task = self.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.profile = task, ws, profile
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile.key,
        pid = self.server.pid, notes = ctx.notes })
    local runner = require("loomworks.daemon.runner")
    local extra = (a.extra and #a.extra > 0) and a.extra or nil
    local args
    if ctx.op == "test" then
        args = { extra = extra, junit = a.junit }
    elseif ctx.op == "clean" then
        args = {}
    elseif ctx.op == "run" then
        -- (The program's arguments: an empty list is still a list.)
        args = { target = a.target, project = a.project, kind = a.kind, cwd = a.cwd, extra = a.extra or {},
            no_build = a.no_build == true, quiet = a.quiet == true, prefix = a.prefix == true }
    else
        args = { extra = extra, targets = (a.targets and #a.targets > 0) and a.targets or nil,
            force = a.force == true, reconfigure = a.reconfigure == true, verbose = a.verbose == true }
    end
    local run = runner.run(self, {
        op = ctx.op, task = task, ws = ws, profile = profile, env = ctx.env, command = ctx.command, args = args,
        clean_steps = clean_steps,
    })
    self.server:log("%s %s (task %s) accepted", ctx.op, profile.key, task.id)
    if run and not run.finished then
        run.ctx = ctx
        self.runs[run] = true
    end
end

--- The model segment that answers a `reset` (see the header): plan before
--- any lock or side effect, then refuse, ask for the confirmation or accept.
--- @param ctx table
--- @param ws table the live workspace
function Service:_accept_reset(ctx, ws)
    local reset_plan = require("loomworks.reset_plan")
    local a = ctx.args
    local scope
    if a.all then
        scope = { all = true }
    else
        local profile, err, action = build_run.resolve_target(ws, a.profile,
            { interactive = ctx.interactive, usage = "lw reset <profile>" })
        if action == "onboard" then
            return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
        end
        if not profile then
            return ctx.reply({ outcome = "refused", message = err, exit_code = 1, notes = ctx.notes })
        end
        scope = { profile = profile }
    end
    local plan = reset_plan.plan(ws, scope)
    local profile_key = plan.profile and plan.profile.key or nil
    -- Never remove a directory the user was not shown: a confirmed plan is
    -- compared first (as in-process, cli.cmd_reset), so a listed plan whose
    -- directories vanished is CHANGED (exit 1), not "nothing to reset".
    if a.plan ~= nil and a.plan ~= plan.token then
        return ctx.reply({ outcome = "refused", message = reset_plan.CHANGED, exit_code = 1, notes = ctx.notes })
    end
    if reset_plan.is_empty(plan) then
        return ctx.reply({ outcome = "refused", message = reset_plan.nothing_message(plan), exit_code = 0,
            stream = "out", notes = ctx.notes })
    end
    -- The client asks (§19.15 Confirmation): what the question shows, and a
    -- token of it; no lock, nothing changed.
    if not a.yes then
        return ctx.reply({ outcome = "confirm", lines = reset_plan.listing(plan), plan = plan.token,
            profile_key = profile_key, notes = ctx.notes })
    end
    local task = self.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws = task, ws
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile_key,
        pid = self.server.pid, notes = ctx.notes })
    local run = require("loomworks.daemon.runner").reset(self, {
        op = "reset", task = task, ws = ws, plan = plan, env = ctx.env, command = ctx.command,
        listing = a.plan == nil,
    })
    self.server:log("reset %s (task %s) accepted", profile_key or "--all", task.id)
    if run and not run.released then
        run.ctx = ctx
        self.runs[run] = true
    end
end

--- A run ended (runner callback).
function Service:on_run_done(run)
    self.runs[run] = nil
    if run.task then
        self.server:log("%s task %s ended%s", run.op or "build", run.task.id,
            run.cancelled and (": " .. tostring(run.cancel_reason)) or "")
    end
    -- A reset whose deletion outlived its task kept the server busy.
    if run.deleting then self:_update_busy() end
end

--- Is the daemon's own background work running (§19.11)? The loaded model's
--- tool detection: a `snapshot` or `query` load does not wait for it, so it
--- may outlive the connection that asked. (A run settling without its owner
--- is the server's `busy`.)
--- @return boolean
function Service:background_work()
    return self.ws ~= nil and self.ws._tool_state == "scanning"
end

--- Is a request's model segment running (`_drain`)? A lifetime tick can run
--- inside one (e.g. during its wait for the model to load); the background
--- work cap does not act then (§19.11 "Background work cap").
--- @return boolean
function Service:in_segment()
    return self.draining == true or self.current ~= nil
end

--- Abandon the model's tool detection past BACKGROUND_MAX_DURATION (§19.11
--- "Background work cap"): it has no handle to cancel, so with no run active
--- the model is unloaded — the torn-down workspace never applies or saves the
--- late result; the probe subprocesses run to completion on their own. The
--- next request loads the model afresh. False when a run is active (the
--- server stops instead) or a model segment is running (the server defers
--- the cap while `in_segment`; never unload under a segment's feet).
--- @return boolean abandoned
function Service:abandon_background()
    if next(self.runs) or self:in_segment() then return false end
    if self.ws then self:_unload() end
    return true
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

--- The runtime lost its authority (§19.2): the workspace — and the one of
--- every run still settling — writes no file again (`_no_write`, honoured by
--- its cache and working-copy saves).
function Service:freeze_writes()
    local why = "the workspace runtime lost its lock"
    if self.ws then self.ws._no_write = why end
    for run in pairs(self.runs) do
        if run.ctx and run.ctx.ws then run.ctx.ws._no_write = why end
    end
end

--- The daemon is stopping: cancel every build, synchronously (kill the step,
--- release the locks), before the process ends. From here on no new request
--- starts (`stopping`: `_drain` declines those not yet accepted).
--- @param reason string
function Service:on_stopping(reason)
    self.stopping = true
    for run in pairs(self.runs) do
        if not run.finished then
            run.cancel("the workspace daemon stopped (" .. tostring(reason) .. ")", 1)
        elseif run.deleting and not run.deletion_settled then
            -- A reset whose task ended (timed out) while its deletion still
            -- runs: stop it between entries (the cache stays `unknown`).
            run.cancelled = true
            run.cancel_reason = run.cancel_reason or ("the workspace daemon stopped (" .. tostring(reason) .. ")")
        end
    end
    -- A run without a child finishes in a model segment: drain now (the
    -- process ends right after).
    if #self.queue > 0 and not self.draining then self:_drain() end
    -- Whatever still holds a lock releases it here.
    local build_lock = require("loomworks.build_lock")
    for run in pairs(self.runs) do
        if run.release_all then
            run.release_all() -- build-dir locks and a clean's operation lock
        else
            for _, h in ipairs(run.held or {}) do build_lock.release(h) end
        end
        if run.task then
            run.task:done(run.cancel_code or 1, (run.op or "build") .. " stopped: the workspace daemon stopped")
        end
    end
end

M.Service = Service
return M
