--- loomworks/daemon/editor_ops.lua — the editor's operations as daemon
--- calls (spec §19.16 "Editor operations", §19.15 "The editor as owner";
--- step 5k part C1).
---
--- In `daemon` runtime mode, while the observer (loomworks.daemon.observer)
--- is connected to a compatible daemon that carries the method, a build, a
--- configure or a module clean — of a profile or of configuration units, a
--- module target's build included — is sent as a `loomworks.Build/1` call
--- whose task the editor owns, instead of running in-process. The entry
--- points (overseer.run_profile_action, run_configuration_action,
--- launch_single_task; the clean of Profile / ConfigUnit through the
--- workspace's `_operation_router`) ask `overseer.route` / `route_clean`,
--- which wrap `M.run` / `M.clean` in a Future: not routed → they run
--- in-process exactly as before — in `in-process` mode always (no observer),
--- and in `daemon` mode while the operation cannot be carried (§19.16
--- "Availability"). This module keeps no Future of its own: it ends an
--- operation through its continuation `k` ({ resolve, reject, fallback }).
---
--- The availability rule (§19.16):
---   not carried now (no connection, a feature or method degraded)
---                     → not routed: in-process; the observer's Runtime-line
---                       note
---   `declined`        → in-process, the reason as one notification line
---   degraded on call  → in-process; the observer notes the method
---   `refused`         → the operation fails with the refusal's message
---   accepted          → one owned task; the operation ends with it: exit 0
---                       resolves, anything else rejects; the connection lost
---                       → fails ("the workspace daemon disconnected"), never
---                       re-run in-process
---   an internal error → fails, never re-run
---
--- A confirmation the in-process operation asks — the artifact-conflict
--- question of a build (§5.9) — is asked before the call when its answer
--- can be known then (configured units), and travels as `force`.
---
--- Step 5k part C2: the preparation of a run or debug launch of a non-device
--- target is a `loomworks.Launch/1` call (`prepare_run` / `prepare_debug`,
--- `build_scope = "target"`, M.prepare) under the same rule; the session
--- tracker then starts the returned program itself. The debug adapters
--- section reads and writes `loomworks.DebugConfig/1` (M.debug_adapters,
--- M.set_debug_adapter), in-process while that is not carried.

local M = {}

local VERB = { build = "build", configure = "configure", clean = "clean",
    prepare_run = "launch", prepare_debug = "debug launch" }

--- The calls whose task-runner restart is not sent again (§19.16 "Tasks in
--- the task runner", step 5k C2): a launch's preparation ends in a program
--- the editor starts after the call, which a restart of the task alone
--- would never start.
M.NO_RESTART = { prepare_run = true, prepare_debug = true }

--- @alias loomworks.daemon.OpContinuation { resolve: fun(v: any), reject: fun(err: any, notified: boolean|nil), fallback: fun() }

--- The observer of `ws` when it carries `method` now, or nil. Only the
--- workspace's own observer carries its operations: a step chained from a
--- workspace the editor has since swapped away from is never sent to another
--- workspace's daemon.
--- @param method "build"|"configure"|"clean"|"prepare_run"|"prepare_debug"
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
function M.carrier(method, ws)
    local obs = require("loomworks.daemon.observer").of(ws)
    if obs and obs.state ~= "stopped" and obs:can_call(method) then return obs end
    return nil
end

--- Is the editor in `daemon` mode (an observer attached)? Its in-process
--- operations then say so in their progress title (§19.16 "Availability").
--- @return boolean
function M.daemon_mode()
    return require("loomworks.daemon.observer").current() ~= nil
end

--- A configuration unit as a `units` item (§19.15: by project key and
--- configuration-unit key).
--- @param unit loomworks.ConfigUnit
--- @return { project: string, configuration: string }
function M.unit_ref(unit)
    local p = unit._project
    return { project = p and p.key or unit._init_project_key, configuration = unit:config_key() }
end

--- The workspace a scope belongs to.
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @return loomworks.Workspace|nil
function M.scope_workspace(scope)
    local owner = scope.profile or (scope.units and scope.units[1])
    return owner and owner._workspace or nil
end

--- The configuration units of a scope.
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @return loomworks.ConfigUnit[]
local function scope_units(scope)
    if scope.units then return scope.units end
    local out = {}
    for _, pp in ipairs(scope.profile and scope.profile:projects() or {}) do
        if pp._config_unit then out[#out + 1] = pp._config_unit end
    end
    return out
end

--- The call's arguments.
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @param opts table { jobs?, force?, targets? }
--- @return table
function M.args(scope, opts)
    local a = { interactive = false }
    if scope.units then
        a.units = {}
        for i, u in ipairs(scope.units) do a.units[i] = M.unit_ref(u) end
    else
        a.profile = { key = scope.profile.key }
    end
    if opts.jobs then a.jobs = tonumber(opts.jobs) end
    if opts.force then a.force = true end
    if opts.targets and #opts.targets > 0 then a.targets = opts.targets end
    return a
end

--- The artifact-conflict question of a build (§5.9), asked before the call
--- for units whose artifacts are known (the in-process build asks it after
--- its configure; a routed build never prompts mid-task). `cb(force|nil,
--- err)`: `force` true after a Yes, false when nothing conflicts.
--- @param ws loomworks.Workspace
--- @param units loomworks.ConfigUnit[]
--- @param cb fun(force: boolean|nil, err: string|nil)
local function ask_conflict(ws, units, cb)
    local block
    for _, unit in ipairs(units) do
        block = ws and ws.artifact_conflict_block and ws:artifact_conflict_block(unit, false) or nil
        if block then break end
    end
    if not block then return cb(false) end
    vim.ui.select({ "Yes", "No" }, {
        prompt = string.format(
            "loomworks: build would overwrite an artifact owned by built "
                .. "profile '%s':\n  %s\nOverwrite it (that profile will be "
                .. "marked stale)?",
            block.profile or "?", block.path or "?"),
    }, function(choice)
        if choice == "Yes" then return cb(true) end
        cb(nil, "build cancelled — would overwrite profile '" .. (block.profile or "?") .. "'")
    end)
end

--- The reply of an owned call, under the availability rule (see the
--- header): accepted → its `on_done` follows; declined → in-process with
--- the reason as one notification; degraded → in-process (noted by the
--- observer); refused → fails with its message; anything else fails (both
--- notified here: `k.reject(message, true)`).
--- @param verb string
--- @param k loomworks.daemon.OpContinuation
--- @return fun(r: table)
local function on_reply(verb, k)
    return function(r)
        if r.outcome == "accepted" then return end
        if r.outcome == "declined" then
            vim.notify(string.format("loomworks: the workspace daemon declined the %s (%s) — running it "
                .. "in-process", verb, tostring(r.reason)), vim.log.levels.WARN)
            return k.fallback()
        elseif r.outcome == "degraded" then
            return k.fallback()
        elseif r.outcome == "refused" then
            vim.notify("loomworks: " .. tostring(r.message), vim.log.levels.ERROR)
            return k.reject(r.message, true)
        end
        vim.notify(string.format("loomworks: the %s failed: %s", verb, tostring(r.reason)),
            vim.log.levels.ERROR)
        k.reject(r.reason, true)
    end
end

--- Why an owned task failed (nil: it ended with exit 0).
--- @param verb string
--- @param task loomworks.RemoteTask|table|nil its task (or its `done`)
--- @param reason string|nil it ended without `done`
--- @return string|nil
local function failure(verb, task, reason)
    if reason then return reason end
    if task and task.exit_code == 0 then return nil end
    return task and (task.error or (verb .. " failed (exit " .. tostring(task.exit_code) .. ")"))
        or (verb .. " failed")
end

--- Run an operation through the daemon when it can be carried (see the
--- header). False when it is not routed — the caller runs it in-process.
--- Otherwise true, and the operation ends through `k`: `k.resolve(true)`,
--- `k.reject(message)`, or `k.fallback()` (run it in-process after all: a
--- `declined`, a method found missing, the connection gone before the call).
--- @param method "build"|"configure"|"clean"
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @param opts? { jobs?: integer, force?: boolean, targets?: table[] }
--- @param k loomworks.daemon.OpContinuation
--- @return boolean routed
function M.run(method, scope, opts, k)
    local obs = M.carrier(method, M.scope_workspace(scope))
    if not obs then return false end
    opts = opts or {}
    local verb = VERB[method] or method

    local function send(force)
        -- Still carried? (A deletion waited for, or a question asked, may
        -- have outlived the connection: nothing ran yet, so in-process.)
        if not obs:can_call(method) then return k.fallback() end
        local args = M.args(scope, { jobs = opts.jobs, force = opts.force or force, targets = opts.targets })
        obs:start_owned(method, args, {
            units = scope_units(scope),
            on_reply = on_reply(verb, k),
            on_done = function(task, reason)
                local err = failure(verb, task, reason)
                if err then return k.reject(err) end
                k.resolve(true)
            end,
        })
    end

    local function go()
        if method ~= "build" or opts.force then return send(false) end
        ask_conflict(obs.ws, scope_units(scope), function(force, err)
            if err then
                vim.notify("loomworks: " .. err, vim.log.levels.WARN)
                return k.reject(err)
            end
            send(force)
        end)
    end

    local lw = require("loomworks")
    if lw.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        lw.after_deletions(go)
    else
        go()
    end
    return true
end

--- The arguments of a launch's preparation (§19.15 "Run", "Debug", "Build
--- scope of a launch"): the launch target by its profile, project, name and
--- kind (`target` for a module target, `launch` for a launch
--- configuration), built as the editor's in-process launch builds it
--- (`build_scope = "target"`), and a module target's descriptor
--- `working_dir` as the `cwd` override (expanded by the daemon in the same
--- launch context, LaunchTarget:_effective_cwd).
--- @param target loomworks.LaunchTarget
--- @return table
function M.launch_args(target)
    local a = { interactive = false, build_scope = "target" }
    if target._profile then a.profile = { key = target._profile.key } end
    if target._project then a.project = { key = target._project.key } end
    if target._launch_name then
        a.target, a.kind = target._launch_name, "launch"
    elseif target._target_id then
        a.target, a.kind = target._target_id, "target"
        if target._working_dir and target._working_dir ~= "" then a.cwd = target._working_dir end
    end
    return a
end

--- Would a launch's preparation (`mode` "launch" | "debug") be routed now?
--- (The editor checks the debug adapter before the call, §8.9.6.)
--- @param mode "launch"|"debug"
--- @param target loomworks.LaunchTarget
--- @return boolean
function M.can_prepare(mode, target)
    local method = mode == "debug" and "prepare_debug" or "prepare_run"
    return M.carrier(method, M.scope_workspace({ profile = target._profile })) ~= nil
end

--- Prepare a run (`mode` "launch") or debug launch of a non-device launch
--- target through the daemon (`Launch/1.prepare_run` / `prepare_debug`,
--- §19.16 "Editor operations"), under the availability rule of the header.
--- False when not routed — the caller runs the in-process chain. Otherwise
--- true, and it ends through `k`: `k.resolve(done)` with the task result
--- (`launch`, or `device = true` for a foreign artifact; `debug`) once the
--- preparation ended with exit 0 — the caller then starts the program — or
--- `k.reject(message)` (no program is started), or `k.fallback()`.
--- @param mode "launch"|"debug"
--- @param target loomworks.LaunchTarget
--- @param k { resolve: fun(done: table), reject: fun(err: any, notified: boolean|nil), fallback: fun() }
--- @return boolean routed
function M.prepare(mode, target, k)
    local method = mode == "debug" and "prepare_debug" or "prepare_run"
    local obs = M.carrier(method, M.scope_workspace({ profile = target._profile }))
    if not obs then return false end
    local verb = VERB[method]
    local function send()
        if not obs:can_call(method) then return k.fallback() end
        obs:start_owned(method, M.launch_args(target), {
            on_reply = on_reply(verb, k),
            on_done = function(task, reason, done)
                local err = failure(verb, task, reason)
                if err then return k.reject(err) end
                k.resolve(type(done) == "table" and done or {})
            end,
        })
    end
    local lw = require("loomworks")
    if lw.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        lw.after_deletions(send)
    else
        send()
    end
    return true
end

--- A module clean through the daemon (Profile:clean / ConfigUnit:clean, via
--- the workspace's `_operation_router` and overseer.route_clean). False when
--- not routed; otherwise it ends through `k` as `M.run`. Before the call, the
--- editor's own tasks on the same units are cancelled (`Tasks/1.cancel`,
--- waiting for their end, §19.15 "The editor as owner") — accepted ones whose
--- task has not started yet included — and, as the in-process clean
--- pre-empts them, its in-process operations on them cancelled
--- (`cancel_conflicting_operations`) and its local tasks on them stopped; another
--- client's task is never cancelled — the clean meets its build-directory
--- locks. Nothing to clean resolves at once, as in-process.
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @param k loomworks.daemon.OpContinuation
--- @return boolean routed
function M.clean(scope, k)
    local obs = M.carrier("clean", M.scope_workspace(scope))
    if not obs then return false end
    local overseer = require("loomworks.overseer")
    local units = scope_units(scope)
    local steps
    if scope.units then steps = overseer.plan_units_clean(units) else steps = overseer.plan_profile_clean(scope.profile) end
    if not steps then
        k.resolve(true)
        return true
    end

    local ws = obs.ws
    local mine = {}
    for _, u in ipairs(units) do mine[u] = true end
    local pending = {}
    for _, call in ipairs(obs:owned_calls()) do
        for _, u in ipairs(call.task and call.task:config_units() or call.units or {}) do
            if mine[u] then pending[#pending + 1] = call.id; break end
        end
    end
    -- An in-process operation chain on these units (a fallback build after a
    -- declined call or a disconnect) stops here, not after the clean (D5).
    if ws and ws.cancel_conflicting_operations then ws:cancel_conflicting_operations(units) end
    local items = {}
    for _, u in ipairs(units) do items[#items + 1] = { unit = u } end
    local local_ids = {}
    local running = ws and ws.find_running_tasks_for_items and ws:find_running_tasks_for_items(items) or {}
    for task_id in pairs(running) do local_ids[#local_ids + 1] = task_id end

    local function start()
        local function send()
            if not M.run("clean", scope, {}, k) then k.fallback() end
        end
        if #local_ids == 0 or not (ws and ws.stop_tasks_then) then return send() end
        ws:stop_tasks_then(local_ids):next(send, function(e) k.reject(e) end)
    end
    local left = #pending
    if left == 0 then
        start()
    else
        for _, id in ipairs(pending) do
            obs:cancel_owned_id(id, function()
                left = left - 1
                if left == 0 then start() end
            end)
        end
    end
    return true
end

--- Send an owned task's call again (its task-runner restart, §19.16 "Tasks in
--- the task runner"; loomworks.daemon.task_runner): the same method and
--- arguments — a build's `force` as answered the first time — after pending
--- deletions, as `M.run`. `h.accepted(task_id)` once the daemon accepted it
--- (its `start` then binds to `h.runner`); `h.failed(why)` when it does not
--- run: not carried now, declined, refused, or failed. A restart never falls
--- back to in-process: the task-runner task fails with the reason. A
--- launch's preparation (M.NO_RESTART) is never sent again: its restart
--- fails with the reason at once (step 5k C2).
--- @param obs loomworks.daemon.Observer
--- @param call { method: string, args: table, units: loomworks.ConfigUnit[]|nil }
--- @param h { runner: loomworks.daemon.RunnerStrategy, accepted: fun(id: any), failed: fun(why: string) }
function M.rerun(obs, call, h)
    if M.NO_RESTART[call.method] then
        return h.failed("a launch is not restarted here — start it again from the editor")
    end
    local function go()
        if not (obs and obs.state ~= "stopped" and obs:can_call(call.method)) then
            return h.failed("the workspace daemon cannot run it now")
        end
        obs:start_owned(call.method, call.args, {
            units = call.units,
            runner = h.runner,
            on_reply = function(r)
                if r.outcome == "accepted" then return h.accepted(r.task_id) end
                h.failed(tostring(r.message or r.reason or r.outcome))
            end,
            on_done = function() end,
        })
    end
    local lw = require("loomworks")
    if lw.has_pending_deletions() then lw.after_deletions(go) else go() end
end

--- Cancel a running task the editor owns (the status page's Cancel):
--- `Tasks/1.cancel`. False when it is not the editor's (another client's
--- task is cancelled there, §19.15).
--- @param task loomworks.RemoteTask
--- @return boolean
function M.cancel(task)
    local obs = require("loomworks.daemon.observer").current()
    if not (obs and task and task.owned) then return false end
    obs:cancel_owned(task)
    return true
end

--- Cancel every running task the editor owns that counts as `profile`'s
--- operation. Returns how many were asked to stop.
--- @param profile loomworks.Profile
--- @return integer
function M.cancel_for_profile(profile)
    local obs = require("loomworks.daemon.observer").of(profile and M.scope_workspace({ profile = profile }))
    if not obs then return 0 end
    local n = 0
    for _, task in ipairs(obs:owned_tasks()) do
        local hit = false
        for _, p in ipairs(task.profiles or {}) do if p == profile then hit = true end end
        if hit then
            obs:cancel_owned(task)
            n = n + 1
        end
    end
    return n
end

--- The debug adapters section's records (§19.16 "Editor operations"):
--- `DebugConfig/1.adapters` while carried and read on this connection,
--- otherwise the in-process mapping (debug_config.adapter_records — the same
--- working copy) — also while the first read is in flight.
--- @param ws loomworks.Workspace
--- @return { language: string, adapter?: string, default?: string, known: string[], overridden: boolean }[]
function M.debug_adapters(ws)
    local obs = require("loomworks.daemon.observer").of(ws)
    local records = obs and obs.state ~= "stopped" and obs:debug_adapters() or nil
    if records then return records end
    return require("loomworks.debug_config").adapter_records(ws)
end

--- Set a language's debug adapter (`adapter` nil: back to the default) in
--- the working copy: `DebugConfig/1.set_adapter` while carried (a
--- `refused` notified as the in-process refusal; `declined` or degraded →
--- in-process), otherwise `Workspace:set_debug_adapter` in-process.
--- `cb(ok, err)` on the main loop.
--- @param ws loomworks.Workspace
--- @param language string
--- @param adapter string|nil
--- @param cb? fun(ok: boolean, err: string|nil)
function M.set_debug_adapter(ws, language, adapter, cb)
    cb = cb or function() end
    local function in_process()
        local ok, err = ws:set_debug_adapter(language, adapter)
        if not ok then
            vim.notify("loomworks: debug adapter not saved: " .. tostring(err), vim.log.levels.ERROR)
        end
        cb(ok, err)
    end
    local obs = require("loomworks.daemon.observer").of(ws)
    if not (obs and obs.state ~= "stopped" and obs:can_call("set_adapter")) then return in_process() end
    obs:request("set_adapter", { language = language, adapter = adapter }, function(r)
        if r.outcome == "degraded" then return in_process() end
        local res = type(r.result) == "table" and r.result or {}
        if r.outcome == "ok" and res.outcome == "declined" then
            vim.notify("loomworks: the workspace daemon declined the debug adapter change ("
                .. tostring(res.reason) .. ") — saving it in-process", vim.log.levels.WARN)
            return in_process()
        end
        local err = r.outcome ~= "ok" and r.reason or (res.outcome ~= "ok" and (res.message or res.outcome)) or nil
        if err then
            vim.notify("loomworks: debug adapter not saved: " .. tostring(err), vim.log.levels.ERROR)
            return cb(false, err)
        end
        obs:_refetch_debug_adapters()
        cb(true)
    end)
end

--- The router a daemon-mode workspace carries (`ws._operation_router`): the
--- domain objects' cleans ask it, with no dependency on the editor.
M.router = {
    clean = function(scope, fallback) return require("loomworks.overseer").route_clean(scope, fallback) end,
}

return M
