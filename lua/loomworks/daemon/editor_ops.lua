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

local M = {}

local VERB = { build = "build", configure = "configure", clean = "clean" }

--- @alias loomworks.daemon.OpContinuation { resolve: fun(v: any), reject: fun(err: any), fallback: fun() }

--- The observer of `ws` when it carries `method` now, or nil. Only the
--- workspace's own observer carries its operations: a step chained from a
--- workspace the editor has since swapped away from is never sent to another
--- workspace's daemon.
--- @param method "build"|"configure"|"clean"
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
            on_reply = function(r)
                if r.outcome == "accepted" then return end
                if r.outcome == "declined" then
                    vim.notify(string.format("loomworks: the workspace daemon declined the %s (%s) — running it "
                        .. "in-process", verb, tostring(r.reason)), vim.log.levels.WARN)
                    return k.fallback()
                elseif r.outcome == "degraded" then
                    return k.fallback()
                elseif r.outcome == "refused" then
                    vim.notify("loomworks: " .. tostring(r.message), vim.log.levels.ERROR)
                    return k.reject(r.message)
                end
                vim.notify(string.format("loomworks: the %s failed: %s", verb, tostring(r.reason)),
                    vim.log.levels.ERROR)
                k.reject(r.reason)
            end,
            on_done = function(task, reason)
                if reason then return k.reject(reason) end
                if task and task.exit_code == 0 then return k.resolve(true) end
                k.reject(task and (task.error or (verb .. " failed (exit " .. tostring(task.exit_code) .. ")"))
                    or (verb .. " failed"))
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

--- The router a daemon-mode workspace carries (`ws._operation_router`): the
--- domain objects' cleans ask it, with no dependency on the editor.
M.router = {
    clean = function(scope, fallback) return require("loomworks.overseer").route_clean(scope, fallback) end,
}

return M
