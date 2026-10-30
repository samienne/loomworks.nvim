--- loomworks/daemon/service.lua — the daemon's live workspace and the
--- routed operations: `build`, the batch `test`, the preparation of a run and
--- `clean` (spec §19.15, §19.19 steps 3, 5 and 5c).
---
--- **Live workspace.** The daemon loads its workspace on the first operation,
--- or when an editor attaches (`on_editor_attached`, §19.16 "Loaded on
--- attach") (through the host's loader — the same load as the in-process path, which
--- refuses a workspace exactly as `lw` does) and keeps it. Before accepting
--- each operation it applies every pending external change to its files
--- exactly as its file watcher would (`FileTracker:sync` →
--- `Workspace:_on_file_changed`, including a trust refusal, §17.4), completes
--- or refuses a commit journal (§19.4) by reloading, and reloads when the
--- requesting client's environment differs from the one the workspace was
--- loaded in (`envscope.signature`) — that reload keeps the model's ids,
--- each reloaded entity taking over the id of the one it replaces by kind
--- and key (`snapshot.ids_by_key` / `carry_ids`; API.md §1.2), so the
--- request's own ids, from the previous load, still resolve; a reload keeps the device registry and
--- neither cancels nor waits for device installs, launches and stops
--- (`_adopt`, `keeps_on_reload`, §19.16 "Devices"). The workspace's file tracker never polls
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
---     environment while another build runs — a device install, launch or
---     stop does not count). The client runs in-process.
---
--- **Request** `{ kind = "test", args = { profile?, junit?, extra?, no_build?, verbose? }, … }` —
--- the same outcomes (`no_build`: `lw test --no-build`, nothing built, §16.16); the plan checks (test_plan.precheck) refuse as in-process; "declined" when saved test targets would run on a device (§16.16).
---
--- **Request** `{ kind = "prepare_run", args = { profile?, target?, project?,
--- kind?, cwd?, extra?, no_build?, quiet?, verbose? }, … }` (§19.15 "Run") — the same
--- outcomes; also "declined" for a profile one of whose units builds with a
--- foreign kit (device runs stay in the client). The task builds, selects,
--- deploys and resolves the launch; its `done` carries the resolved `launch`
--- (or `device = true`) and the client executes the program.
---
--- **`Launch/1.prepare_debug`** (§19.15 "Debug"; an interface method only,
--- no protocol-10 alias) — the args of `prepare_run` minus `quiet` /
--- `prefix` / `verbose`, the same outcomes, never "declined" for a foreign kit: a device
--- or foreign target ends its task nonzero instead. Its `done.result` carries
--- the debug spec. Both preparations take `build_scope` ("profile", the
--- default, or "target": the launch flow's units instead of the profile,
--- §19.15 "Build scope of a launch").
--- Both take `force` (the artifact-conflict answer, §5.9; interface only).
---
--- **`Launch/1.build`** (§19.15 "Build of a launch target"; an interface
--- method only, op `target_build`) — addressed as `prepare_run` is, plus
--- `force`; the outcomes of `build`. Its task (`meta.kind = build`) runs the
--- target scope's phases up to the launch target's own unit and resolves no
--- launch; a device target ends it nonzero before the build.
---
--- **Request** `{ kind = "clean", args = { profile?, verbose? }, … }` (§19.15 "Clean")
--- — the same outcomes; also "refused" on stdout (`stream = "out"`) with the
--- in-process `nothing to clean …` line when there is nothing to clean,
--- decided after resolution and before any lock (as in-process).
---
--- **`Build/1.configure`** (§19.15 "Editor scopes and configure"; an
--- interface method only, no protocol-10 kind) — the outcomes of `build`: the
--- configure step of every unit of the scope, also one already configured.
--- **`units`** on build, configure and clean: the scope is those configuration
--- units (each `{ id }` or `{ project, configuration }`, resolved with the
--- ids; one that does not resolve is "refused") instead of a profile —
--- `profile_key` and `meta.profile` absent. **`jobs`** on build: the build
--- tool's parallelism. **`targets`** items may be `{ project, target }`.
--- **`verbose`** (`-v`) on build, clean, test and `prepare_run`: the task also
--- streams the command lines of §16.4 *Verbose* (role `command`), their env
--- line against the client's environment (`ctx.env`, before the daemon's own
--- adjustments; §19.15 "Roles and verbose").
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
---   error_state?() → { message, refused?, trust? }|nil, the failed load the welcome header and view.Header/1
---   report (`trust`: the file a trust refusal refused, `user` or `cache`); core?() → the workspace core (Workspace/1's
---   trust_accept / delete_user_prefs) }
--- @field ws table|nil the live workspace
--- @field env_sig string|nil the environment signature `ws` was loaded in
--- @field stopping boolean|nil the server is stopping (`on_stopping`): no new request starts
--- @field ids loomworks.daemon.IdRegistry the session's opaque-id registry (§19.12)
--- @field _device_registry table<string, loomworks.Device>|nil the device registry (serial → Device) every
---   workspace this daemon loads shares (`_adopt`, §19.16 "Devices")
--- @field _lsp_sig string|nil LspConfig/1 (§19.20): the state (the daemon's own environment) at the last
---   `changed`, the baseline the next check compares with; nil while /lsp has no subscriber
--- @field _lsp_seq integer|nil the `seq` of the last `changed` sent
--- @field _lsp_force boolean|nil an owned database was written during a model segment: the deferred check
---   sends `changed` even when the state is unchanged (a raised `db_rev`)
--- @field _lsp_listeners table<string, function> the `lsp_database_written` / `lsp_ready` / `tools_detected`
---   event handlers
--- @field _late_tools { ws: table, rows: table }|nil a toolchain detection a write started that did not finish
---   within its wait (`tools_late`): the model and its toolchain rows before the write
--- @field _attach_load boolean|nil an editor's attach queued a load (`on_editor_attached`) not yet run
---   (removed again when the service stops)
--- @field _carried table|nil the ids an environment reload took from the model it dropped
---   (`snapshot.ids_by_key`), kept until a load succeeds and they carry over (`_carry_ids`, API.md §1.2)
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
    -- A target-scoped task's step changed state (§19.15 "Steps of a task"):
    -- its `seq` is each frame's own envelope `seq`.
    self.tasks.on_step = function(t, index, state, err)
        if server.interfaces then
            core_ifaces.task_signal(server.interfaces, t, "step", function(_, seq)
                return { task_id = t.id, seq = seq, index = index, state = state,
                    error = type(err) == "string" and err or nil }
            end)
        end
    end
    envscope.install()
    server.service = self
    -- The core interfaces it serves (step 5g.2), once the registry exists.
    if server.interfaces then core_ifaces.mount(server.interfaces, self) end
    -- LspConfig/1's `changed` (§19.20): an owned LSP database written by
    -- this daemon's model (a raised `db_rev`), and the active profile's
    -- databases settled (`ready`) — both outside any model segment.
    local events = require("loomworks.events")
    self._lsp_listeners = {
        lsp_database_written = function(d)
            if type(d) == "table" and d.workspace ~= nil and d.workspace == (self:header_model()) then
                pcall(core_ifaces.lsp_check, self, true)
            end
        end,
        lsp_ready = function() pcall(core_ifaces.lsp_check, self) end,
        -- A toolchain detection that outran a write's wait finished
        -- (`tools_late`).
        tools_detected = function() pcall(self._tools_settled, self) end,
    }
    for ev, fn in pairs(self._lsp_listeners) do events.on(ev, fn) end
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

--- Before a request's acknowledgement from inside its model segment: what
--- the segment changed so far reaches the subscribers first
--- (`Workspace.header_changed` and the views' `update`, §19.13 "Views").
--- The check after the segment still runs; it sends only what changed since.
--- @param ctx table
function Service:_before_ack(ctx)
    if self.current ~= ctx then return end
    pcall(require("loomworks.daemon.core_interfaces").header_check, self)
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

--- Append a note to a request's reply notes with its role (API.md §4.1:
--- `note_roles[i]` is the LineRole of `notes[i]`), so the two never part.
--- @param c table the request context
--- @param text string
--- @param role string a Common/1 LineRole
local function add_note(c, text, role)
    c.notes, c.note_roles = c.notes or {}, c.note_roles or {}
    c.notes[#c.notes + 1] = text
    c.note_roles[#c.note_roles + 1] = role
end

--- A warm workspace's load warnings into the notes of request `c` (§19.13
--- "Load warnings"): the request that loaded it got them as they were raised
--- (`handlers().notify`); each later one that uses it carries them too, with
--- their roles, so every CLI command prints them as an in-process run (which
--- loads each time) does. Once per connection and workspace — a command's
--- later requests on its connection (a read's snapshot, then its query) do
--- not repeat them, as the in-process command loads once — and a note the
--- request already has (re-raised by this request's sync) is not repeated.
--- An editor's request is left out: the editor shows them in the views
--- (Workspace/1 `diagnostics`), and reads a `warn` note of a reply as that
--- command's failure (ui/model_calls.result).
--- @param c table the request context
--- @param ws table the live workspace
local function add_load_notes(c, ws)
    local conn = c.conn
    if conn and conn.observer then return end
    if conn then
        if conn.load_notes_of == ws then return end
        conn.load_notes_of = ws
    end
    if type(ws.load_notes) ~= "function" then return end
    local texts, roles = ws:load_notes()
    if #texts == 0 then return end
    local have = {}
    for _, n in ipairs(c.notes or {}) do have[n] = true end
    for i, t in ipairs(texts) do
        if not have[t] then add_note(c, t, roles[i]) end
    end
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
            if c and c.conn and c.conn.observer and require("loomworks.notify").in_load() then
                -- A load's warning on an editor's request (§19.13 "Load
                -- warnings"): the editor shows it in the views, and would
                -- read a `warn` note of the reply as the command's failure.
                c = nil
            end
            if c and c.task then
                -- (The in-process loader's roles: an error fails, a warning warns.)
                c.task:line("err", tostring(msg) .. "\n", (level or 0) >= vim.log.levels.ERROR and "fail" or "warn")
            elseif c then add_note(c, tostring(msg), (level or 0) >= vim.log.levels.ERROR and "fail" or "warn")
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
--- stopped (§19.15: the workspace was unloaded or reloaded under them). A
--- device install, launch or stop is not (`keeps_on_reload`, §19.16
--- "Devices").
function Service:_stop_stale_runs(why)
    for run in pairs(self.runs) do
        if run.ctx.ws ~= self.ws and not run.keeps_on_reload then run.cancel(why, 1) end
    end
end

--- Does a run bound to the live workspace run (one a reload would cancel)?
--- @return boolean
function Service:_workspace_runs()
    for run in pairs(self.runs) do
        if not run.keeps_on_reload then return true end
    end
    return false
end

--- Make `ws` the live workspace, loaded in the environment of signature
--- `sig`. Devices are runtime state (§19.16 "Devices"): the daemon's
--- registry is the first workspace's, and every workspace loaded after it
--- shares it, so a reload keeps the device list and its ids.
--- @param ws table
--- @param sig string
function Service:_adopt(ws, sig)
    if not self._device_registry then
        self._device_registry = ws._devices
    elseif ws._devices ~= self._device_registry then
        ws._devices = self._device_registry
    end
    self.ws, self.env_sig = ws, sig
end

--- Hand the ids an environment reload took from the model it dropped
--- (`self._carried`, API.md §1.2) to `ws`, the model the next successful
--- load produced, and forget them.
--- @param ws table
function Service:_carry_ids(ws)
    local carried = self._carried
    self._carried = nil
    if carried then snapshot.carry_ids(ws, self.ids, carried) end
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

--- After a command that put the core through setup again (Workspace/1's
--- trust_accept / delete_user_prefs, API.md §6): wait for that load, then
--- serve what it produced (its refusal is the header's). Runs bound to the
--- old workspace stop, and every id issued before is stale.
--- @param ctx table the request (its `env`)
function Service:_adopt_reload(ctx)
    self.host.settle(M.LOAD_WAIT_MS)
    self.ws, self.env_sig = nil, nil
    self._carried = nil -- (this load re-ids, API.md §1.2: nothing carries over)
    self:_stop_stale_runs("the workspace was reloaded")
    local now = self.host.current()
    if now then self:_adopt(now, envscope.signature(ctx.env)) end
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
        if self.ws then
            add_load_notes(ctx, self.ws)
            return self.ws
        end
        local ws, err = self.host.load(root, self:handlers(), { wait_tools = false })
        if not ws then return nil, err or "failed to load workspace" end
        self:_adopt(ws, sig)
        self:_carry_ids(ws)
        if ctx.conn then ctx.conn.load_notes_of = ws end -- (raised into its notes)
        return ws
    end
    -- An environment reload keeps the model's ids (API.md §1.2, §19.12): the
    -- ids of the model it drops, by kind and key, for the reloaded one. They
    -- wait on the service until a load succeeds (`_carry_ids`), so a load
    -- that fails or throws in between does not lose them.
    if self.ws and self.env_sig ~= sig then
        if self:_workspace_runs() then
            return nil, nil, "another build runs in the workspace daemon with a different environment"
        end
        self._carried = snapshot.ids_by_key(self.ws, self.ids)
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
            self:_adopt(now, sig)
        end
        -- A changed loomworks.json rescans tools: wait for it, as the load does.
        if self.ws._tool_state ~= "scanned" then
            vim.wait(M.LOAD_WAIT_MS, function() return self.ws._tool_state == "scanned" end, 25)
        end
        add_load_notes(ctx, self.ws)
        return self.ws
    end
    local ws, err = self.host.load(root, self:handlers())
    if not ws then return nil, err or "failed to load workspace" end
    self:_adopt(ws, sig)
    self:_carry_ids(ws)
    if ctx.conn then ctx.conn.load_notes_of = ws end -- (raised into its notes)
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

--- Apply another process's changes to the workspace files before the
--- header and the views are computed (§19.13 "Freshness of views"): the
--- loaded model's light sync (Workspace:sync_light) — never a load, never a
--- tool detection; what needs either waits for the next state-changing
--- request's sync (`live`). Not inside a model segment (its request synced
--- at its start and may be mid-change) and not reentrant.
function Service:check_files()
    if self.current or self._checking_files then return end
    local ws = self:header_model()
    if not (ws and ws.sync_light) then return end
    self._checking_files = true
    local ok, err = pcall(ws.sync_light, ws)
    self._checking_files = false
    if not ok then self.server:log("file check before the views failed: %s", tostring(err)) end
end

--- The model the header and the views (§19.13) report: the live workspace,
--- else the host's load failure. Never loads.
--- @return table|nil ws, loomworks.ViewLoadError|nil err
function Service:header_model()
    local ws = self.ws
    if ws and self.host.current and self.host.current() ~= ws then ws = nil end
    local err = (not ws and self.host.error_state) and self.host.error_state() or nil
    return ws, err
end

--- The `welcome` header's model fields (§19.13): the live workspace's name
--- and active profile, else the host's load failure. Never loads.
--- @return table
function Service:header()
    return snapshot.header(self:header_model())
end

--- A read-only model request (`snapshot`, `query`): validate it, then answer
--- it in a model segment against the live workspace, in the client's
--- environment. `answer(ws, ctx)` returns the reply's fields (`outcome`
--- defaults to "ok"); an answer that sets `ctx.deferred` replies later itself
--- with `ctx.reply` (a read that ends off the model queue), which adds the
--- segment's notes.
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
        self:_before_ack(ctx)
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
            return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
        if ctx.refused then
            return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
        local fields = answer(ws, ctx)
        if ctx.deferred then
            -- The later reply carries the notes the segment gathered (live()).
            local reply = ctx.reply
            function ctx.reply(f)
                f.notes = f.notes or ctx.notes
                f.note_roles = f.note_roles or ctx.note_roles
                return reply(f)
            end
            return
        end
        fields.outcome = fields.outcome or "ok"
        fields.notes = ctx.notes
        fields.note_roles = ctx.note_roles
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

--- Is `a` (a build, configure or clean's `units` / `jobs` / `targets`)
--- well-formed? `targets` items are names or `{ project, target }`; `units`
--- a non-empty list of `{ id }` or `{ project, configuration }`.
--- @param a table
--- @return boolean
local function scope_args_ok(a)
    if a.targets ~= nil then
        if type(a.targets) ~= "table" then return false end
        for _, v in ipairs(a.targets) do
            if type(v) == "table" then
                if type(v.project) ~= "string" or type(v.target) ~= "string" then return false end
            elseif type(v) ~= "string" then
                return false
            end
        end
    end
    if a.jobs ~= nil and not (type(a.jobs) == "number" and a.jobs >= 1 and math.floor(a.jobs) == a.jobs) then
        return false
    end
    if a.units ~= nil then
        if type(a.units) ~= "table" or #a.units == 0 then return false end
        if a.profile ~= nil or a.profile_id ~= nil then return false end
        for _, r in ipairs(a.units) do
            if type(r) ~= "table" then return false end
            if r.id ~= nil then
                if type(r.id) ~= "string" then return false end
            elseif type(r.project) ~= "string" or type(r.configuration) ~= "string" then
                return false
            end
        end
    end
    return true
end

--- Does `a` (a protocol-10 request's args) carry none of `Build/1`'s
--- editor-scope fields (`units`, `jobs`, `{ project, target }` items)?
--- @param a table
--- @return boolean
local function v0_args_ok(a)
    if a.units ~= nil or a.jobs ~= nil then return false end
    for _, v in ipairs(type(a.targets) == "table" and a.targets or {}) do
        if type(v) ~= "string" then return false end
    end
    return true
end

--- Is `a` (a `prepare_run` or, `op == "debug"`, a `prepare_debug` request's
--- args — or, `op == "target_build"`, a `Launch/1.build` request's)
--- well-formed? `force` only through the interface methods (`interface`).
--- @param a table
--- @param op "run"|"debug"|"target_build"
--- @param interface boolean
--- @return boolean
local function run_args_ok(a, op, interface)
    for _, k in ipairs({ "target", "project", "cwd" }) do
        if a[k] ~= nil and type(a[k]) ~= "string" then return false end
    end
    if a.kind ~= nil and a.kind ~= "target" and a.kind ~= "launch" then return false end
    for _, k in ipairs({ "no_build", "quiet", "prefix", "force" }) do
        if a[k] ~= nil and type(a[k]) ~= "boolean" then return false end
    end
    -- (The conflict question's answer, §5.9: not in the protocol-10 request.)
    if a.force ~= nil and not interface then return false end
    -- (No report and no wrapper for a debug launch.)
    if op ~= "run" and (a.quiet ~= nil or a.prefix ~= nil) then return false end
    -- (A launch target's build: no launch to resolve, always built, §19.15.)
    if op == "target_build" and (a.cwd ~= nil or a.extra ~= nil or a.no_build ~= nil or a.build_scope ~= nil) then
        return false
    end
    if a.build_scope ~= nil and a.build_scope ~= "profile" and a.build_scope ~= "target" then return false end
    return true
end

--- A routed operation's request: validate it, then accept it in a model
--- segment. The protocol-10 request and the task-streamed interface method
--- (Build/1, Tests/1.run, Launch/1.prepare_run; daemon/core_interfaces.lua)
--- are this one implementation: the method passes `deliver` (its reply) and
--- `call` (the task's interface identity and result, `Task.call`). `debug`
--- (Launch/1.prepare_debug) has no protocol-10 request.
--- @param op "build"|"test"|"run"|"debug"|"target_build"|"clean"|"reset"|"configure"
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
        self:_before_ack(ctx)
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
    if a.extra ~= nil and type(a.extra) ~= "table" then
        return ctx.reply({ outcome = "declined", reason = "malformed request" })
    end
    for _, v in ipairs(a.extra or {}) do
        if type(v) ~= "string" then return ctx.reply({ outcome = "declined", reason = "malformed request" }) end
    end
    -- (`units` only on build, configure and clean; `jobs` only on build;
    -- both, and `{ project, target }` items, only through Build/1 — the
    -- CLI's protocol-10 requests are unchanged, §19.15.)
    if not scope_args_ok(a) or (a.units ~= nil and op ~= "build" and op ~= "configure" and op ~= "clean")
        or (a.jobs ~= nil and op ~= "build") or (not deliver and not v0_args_ok(a)) then
        return ctx.reply({ outcome = "declined", reason = "malformed request" })
    end
    if (a.profile ~= nil and type(a.profile) ~= "string") or (a.junit ~= nil and type(a.junit) ~= "string")
        or (a.profile_id ~= nil and (type(a.profile_id) ~= "string" or a.profile ~= nil))
        or (a.project_id ~= nil and (type(a.project_id) ~= "string" or a.project ~= nil))
        or ((op == "run" or op == "debug" or op == "target_build") and not run_args_ok(a, op, deliver ~= nil))
        or (op == "test" and a.no_build ~= nil and type(a.no_build) ~= "boolean")
        -- (`verbose` only where its API defines it: build, clean, test,
        -- prepare_run — not reset, configure, prepare_debug or Launch/1.build.)
        or (a.verbose ~= nil and (type(a.verbose) ~= "boolean"
            or not (op == "build" or op == "clean" or op == "test" or op == "run")))
        or (op == "reset" and not reset_args_ok(a)) then
        return ctx.reply({ outcome = "declined", reason = "malformed request" })
    end
    self:with_model(ctx, function() self:_accept(ctx) end)
end

--- An interface call's references by id (`args.profile_id`,
--- `args.project_id`; §19.20 "References"): resolved once, in the model
--- segment, straight to the live objects, which the caller passes on. An id
--- is never turned into its key to be matched again (step 5o part 0): the
--- CLI's matcher (§16.9) reads a key as user input (a bare integer is a
--- profile number), so a key round-trip can name another entity.
--- @param ws table the live workspace
--- @param a table the operation's args
--- @return { profile?: loomworks.Profile, project?: loomworks.Project }|nil objs
--- @return string|nil refusal of a stale or unknown id
function Service:_resolve_ids(ws, a)
    local objs = {}
    for _, r in ipairs({ { "profile", ws._profiles }, { "project", ws._projects } }) do
        local name, list = r[1], r[2]
        local id = a[name .. "_id"]
        if id ~= nil then
            local obj = self.ids:find(id, list)
            if not obj then
                return nil, "no " .. name .. " with id " .. tostring(id) .. " (a stale reference)"
            end
            objs[name] = obj
        end
    end
    return objs
end

--- An operation's `units` (§19.15 "Editor scopes and configure") resolved
--- to the live configuration units, in order, duplicates dropped: `{ id }`
--- with the session's ids (a stale id refused as for a profile), `{ project,
--- configuration }` by the project key and configuration-unit key.
--- @param ws table the live workspace
--- @param refs table[]
--- @return table[]|nil units, string|nil refusal
function Service:_resolve_units(ws, refs)
    local out, seen = {}, {}
    for _, r in ipairs(refs) do
        local unit
        if r.id ~= nil then
            unit = self.ids:find(r.id, ws._config_units)
            if not unit then return nil, "no configuration unit with id " .. tostring(r.id) .. " (a stale reference)" end
        else
            for _, u in pairs(ws._config_units or {}) do
                local p = u._project
                if not u._removed and p and not p._removed and p.key == r.project
                        and u:config_key() == r.configuration then
                    unit = u
                end
            end
            if not unit then
                return nil, "no configuration unit " .. r.project .. "/" .. r.configuration
                    .. " (unknown project or configuration)"
            end
        end
        if not seen[unit] then seen[unit] = true; out[#out + 1] = unit end
    end
    return out
end

--- The model segment that accepts (or refuses / declines) a build, a test
--- run, a run's preparation, a clean or a configure (of a profile, or of
--- configuration units).
function Service:_accept(ctx)
    if ctx.conn.closed then return end
    local ws, refusal, decline = self:live(ctx)
    if not ws then
        if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
        return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if ctx.refused then
        return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local refs, stale = self:_resolve_ids(ws, ctx.args)
    if not refs then return ctx.reply({ outcome = "refused", message = stale, exit_code = 1,
        notes = ctx.notes, note_roles = ctx.note_roles }) end
    if ctx.op == "reset" then return self:_accept_reset(ctx, ws, refs) end
    local a = ctx.args
    local launching = ctx.op == "run" or ctx.op == "debug" or ctx.op == "target_build"
    local profile, units
    if a.units then
        local uerr
        units, uerr = self:_resolve_units(ws, a.units)
        if not units then return ctx.reply({ outcome = "refused", message = uerr, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles }) end
    elseif refs.profile then
        profile = refs.profile
    else
        local err, action, code
        profile, err, action, code = build_run.resolve_target(ws, a.profile, { interactive = ctx.interactive,
            -- (No `lw configure`: a configure's refusal names `lw build`.)
            usage = launching and "lw run <profile> <target>"
                or ("lw " .. (ctx.op == "configure" and "build" or ctx.op) .. " <profile>") })
        if action == "onboard" then
            return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
        end
        if not profile then
            return ctx.reply({ outcome = "refused", message = err, exit_code = code or 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
    end
    -- A test run's plan is checked before the build, as in-process (§16.16):
    -- its notes go with the reply; a refusal (a foreign kit's tests with no
    -- saved test target, §18.6; arguments after `--` for a mixed plan) is
    -- refused with the in-process message and exit code. Saved test targets
    -- a foreign kit builds run on a device, which stays in the client (as a
    -- device `lw run`): declined.
    local test_pre
    if ctx.op == "test" and profile then
        test_pre = require("loomworks.test_plan").precheck(profile, { extra = a.extra or {} })
        if test_pre.device_platform then
            return ctx.reply({ outcome = "declined", reason = "profile '" .. profile.key .. "' builds for "
                .. test_pre.device_platform .. "; device test runs stay in this process" })
        end
        if #test_pre.notes > 0 then
            for _, n in ipairs(test_pre.notes) do add_note(ctx, n, "plain") end
        end
        if test_pre.err then
            return ctx.reply({ outcome = "refused", message = test_pre.err, exit_code = test_pre.code or 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
    end
    -- A run of a profile built by a foreign kit is a device run: its device
    -- locks, staging and program liveness stay with the client (§19.15). (A
    -- debug launch is never declined for it: there is no device debug, so
    -- its task refuses a device or foreign target, runner.lua.)
    local platform = ctx.op == "run" and profile and require("loomworks.run_prep").kit_platform(profile) or nil
    if platform then
        return ctx.reply({ outcome = "declined", reason = "profile '" .. profile.key .. "' builds for "
            .. platform .. "; device runs stay in this process" })
    end
    -- Nothing to clean (no configured build directory on disk, or no module
    -- clean): refused with the in-process line, before any lock — on stdout
    -- (API.md §4.1), an ordinary result: the editor's rebuild goes on to
    -- its build.
    local clean_steps
    if ctx.op == "clean" then
        clean_steps = build_run.plan_clean(profile, units)
        if not clean_steps then
            return ctx.reply({ outcome = "refused", message = build_run.nothing_to_clean_message(profile,
                units and build_run.units_label(units) or nil), exit_code = 1, stream = "out",
                    notes = ctx.notes, note_roles = ctx.note_roles })
        end
    end
    local task = self.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.profile, ctx.units = task, ws, profile, units
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn),
        profile_key = profile and profile.key or nil, pid = self.server.pid,
            notes = ctx.notes, note_roles = ctx.note_roles })
    local runner = require("loomworks.daemon.runner")
    local extra = (a.extra and #a.extra > 0) and a.extra or nil
    local args
    if ctx.op == "test" then
        args = { extra = extra, junit = a.junit, no_build = a.no_build == true, verbose = a.verbose == true }
    elseif ctx.op == "clean" then
        args = { verbose = a.verbose == true }
    elseif ctx.op == "configure" then
        args = { reconfigure = a.reconfigure == true }
    elseif launching then
        -- (The program's arguments: an empty list is still a list.)
        -- (`force`: the artifact-conflict question's answer, §5.9.)
        -- (`project`: the Project an id named, else the key the CLI typed.)
        args = { target = a.target, project = refs.project or a.project, kind = a.kind, cwd = a.cwd,
            extra = a.extra or {},
            no_build = a.no_build == true, build_scope = a.build_scope, force = a.force == true }
        if ctx.op == "run" then
            args.quiet, args.prefix, args.verbose = a.quiet == true, a.prefix == true, a.verbose == true
        end
        -- A launch target's build is the target scope's build phases (§19.15
        -- "Build of a launch target").
        if ctx.op == "target_build" then args.build_scope = "target" end
    else
        args = { extra = extra, targets = (a.targets and #a.targets > 0) and a.targets or nil,
            force = a.force == true, reconfigure = a.reconfigure == true, verbose = a.verbose == true,
            jobs = a.jobs }
    end
    -- The run is this request's before any of its work: the runner takes the
    -- locks and plans inside this segment, and a throw there must find
    -- `ctx.run` to cancel (its end frees the locks and sends `done`).
    runner.run(self, {
        op = ctx.op, task = task, ws = ws, profile = profile, units = units, env = ctx.env, command = ctx.command,
        args = args, clean_steps = clean_steps, test_pre = test_pre,
        on_run = function(run)
            run.ctx = ctx
            ctx.run = run
            self.runs[run] = true
        end,
    })
    self.server:log("%s %s (task %s) accepted", ctx.op, units and build_run.units_label(units) or profile.key,
        task.id)
end

--- The model segment that answers a `reset` (see the header): plan before
--- any lock or side effect, then refuse, ask for the confirmation or accept.
--- @param ctx table
--- @param ws table the live workspace
--- @param refs table the objects the request's ids named (`_resolve_ids`)
function Service:_accept_reset(ctx, ws, refs)
    local reset_plan = require("loomworks.reset_plan")
    local a = ctx.args
    local scope
    if a.all then
        scope = { all = true }
    elseif refs.profile then
        scope = { profile = refs.profile }
    else
        local profile, err, action, code = build_run.resolve_target(ws, a.profile,
            { interactive = ctx.interactive, usage = "lw reset <profile>" })
        if action == "onboard" then
            return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
        end
        if not profile then
            return ctx.reply({ outcome = "refused", message = err, exit_code = code or 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
        scope = { profile = profile }
    end
    local plan = reset_plan.plan(ws, scope)
    local profile_key = plan.profile and plan.profile.key or nil
    -- Never remove a directory the user was not shown: a confirmed plan is
    -- compared first (as in-process, cli.cmd_reset), so a listed plan whose
    -- directories vanished is CHANGED (exit 1), not "nothing to reset".
    if a.plan ~= nil and a.plan ~= plan.token then
        return ctx.reply({ outcome = "refused", message = reset_plan.CHANGED, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if reset_plan.is_empty(plan) then
        return ctx.reply({ outcome = "refused", message = reset_plan.nothing_message(plan), exit_code = 0,
            stream = "out", notes = ctx.notes, note_roles = ctx.note_roles })
    end
    -- The client asks (§19.15 Confirmation): what the question shows, and a
    -- token of it; no lock, nothing changed.
    if not a.yes then
        return ctx.reply({ outcome = "confirm", lines = reset_plan.listing(plan), plan = plan.token,
            profile_key = profile_key, notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local task = self.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws = task, ws
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile_key,
        pid = self.server.pid, notes = ctx.notes, note_roles = ctx.note_roles })
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
    -- The profile's last result (view.Workspace/1 `last_result`, API.md
    -- §14.4): state of the daemon's session, kept while the next run runs
    -- and across reconnects; the view's `update` follows at the segment's
    -- header check (here, for a run that ended outside a segment).
    local t = run.task
    if run.profile and t and t.finished then
        local status = run.cancelled and "cancelled" or (t.exit_code == 0 and "ok" or "failed")
        local duration = t.started_at and t.ended_at and (t.ended_at - t.started_at) or nil
        run.profile:set_last_result(status, require("loomworks.operation").task_outcome(
            t.meta and t.meta.kind or run.op, t.exit_code, duration, t.error))
        if not self.current then pcall(require("loomworks.daemon.core_interfaces").header_check, self) end
    end
    -- A reset whose deletion outlived its task kept the server busy.
    if run.deleting then self:_update_busy() end
    -- The tests view: the units the run covered may no longer match their
    -- discovered trees (§19.13 "The tests view", `stale`).
    pcall(require("loomworks.daemon.test_store").on_run_done, self, run)
end

--- A toolchain detection a write started (Toolchains/1.rescan, Sdks/1.add /
--- remove) did not finish within the write's wait: it goes on in the
--- background, and Workspace/1 `changed` is signalled when it finishes
--- (`_tools_settled`), if the toolchains changed.
--- @param ws table the model the detection runs for
--- @param rows table the toolchain rows before the write (snapshot.tool_rows)
function Service:tools_late(ws, rows)
    local late = self._late_tools
    -- An earlier late detection's baseline is the older one: keep it.
    if late and late.ws == ws then return end
    self._late_tools = { ws = ws, rows = rows }
end

--- `tools_detected`: a late detection (`tools_late`) finished. It runs outside
--- any model segment, so outside the requester's environment scope
--- (daemon/envscope.lua): it only compares the toolchain rows and signals
--- `changed`; the detection's result was taken in by the workspace's own
--- callback, as a load's background detection is (§19.11).
function Service:_tools_settled()
    local late = self._late_tools
    if not late then return end
    local ws = late.ws
    if ws ~= self.ws or ws._torn_down then self._late_tools = nil; return end
    if ws._tool_state ~= "scanned" then return end
    self._late_tools = nil
    local rows = require("loomworks.daemon.snapshot").tool_rows(ws._tools_by_type)
    if not vim.deep_equal(late.rows, rows) then self.server:model_changed() end
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

--- An editor attached (an observer connection, hello `role = "observer"`,
--- §19.16 "Loaded on attach"): load the workspace when none is loaded, as a
--- read-only request does — in a model segment, in the daemon's own
--- environment, without waiting for tool detection — so an editor-only
--- session does not stay `unloaded`. Nothing when a model is loaded, a load
--- is already queued, or the daemon is stopping. A failed load is the header's
--- error state, as for any load. A CLI connection never calls this.
function Service:on_editor_attached()
    if self.ws or self._attach_load or self.stopping or self.server.stopped then return end
    self._attach_load = true
    local ctx = { op = "attach", env = envscope.capture(), args = {} }
    self:with_model(ctx, function()
        self._attach_load = nil
        if self.ws or self.stopping then return end
        local ws, refusal = self:live(ctx, true)
        if not ws then self.server:log("loading the workspace for an editor failed: %s", tostring(refusal)) end
        for _, n in ipairs(ctx.notes or {}) do self.server:log("%s", n) end
    end)
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
    -- Its prepared test debug sessions are dropped (§19.15 "Tests").
    pcall(require("loomworks.daemon.test_runs").on_conn_closed, self, conn)
    -- Its device launches can no longer be stopped through it (§19.16 "Devices").
    pcall(require("loomworks.daemon.devices").on_conn_closed, self, conn)
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
    local events = require("loomworks.events")
    for ev, fn in pairs(self._lsp_listeners or {}) do events.off(ev, fn) end
    self._lsp_listeners = nil
    pcall(require("loomworks.daemon.test_runs").on_stopping, self)
    for run in pairs(self.runs) do
        if not run.finished then
            run.cancel("the workspace daemon stopped (" .. tostring(reason) .. ")", 1)
        elseif run.deleting and not run.deletion_settled then
            -- A reset or delete run whose task ended (e.g. a reset timed
            -- out) while its deletion still runs: stop it between entries
            -- (what was not removed stays, its cache entries `unknown`).
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
