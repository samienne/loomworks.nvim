--- loomworks/daemon/editor_ops.lua — the editor's operations as daemon
--- calls (spec §19.16 "Editor operations", §19.15 "The editor as owner";
--- step 5k part C1).
---
--- In `daemon` runtime mode, while the observer (loomworks.daemon.observer)
--- is connected to a compatible daemon that carries the method, a build, a
--- configure or a module clean — of a profile or of configuration units, a
--- module target's build included — is sent as a `loomworks.Build/1` call
--- whose task the editor owns. The entry points (overseer.run_profile_action,
--- run_configuration_action, launch_single_task; the clean of Profile /
--- ConfigUnit through the workspace's `_operation_router`) ask
--- `overseer.route` / `route_clean`, which wrap `M.run` / `M.clean` in a
--- Future: not routed — only in the deprecated `in-process` mode (no
--- observer) — they run in-process. In `daemon` mode an operation is never
--- run in-process (§19.16 "Availability", step 5s): one the daemon cannot
--- carry is refused. This module keeps no Future of its own: it ends an
--- operation through its continuation `k` ({ resolve, reject }).
---
--- The availability rule (§19.16):
---   not carried now (no connection, a feature or method degraded)
---                     → refused: the observer's Runtime-line note as one
---                       notification line
---   `declined`        → fails, the reason as one notification line
---   degraded on call  → refused; the observer notes the method
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
--- M.set_debug_adapter); while that is not carried the section is
--- unavailable and its writes fail.
---
--- Step 5t part C: the build of a non-device launch target is one
--- `Launch/1.build` the editor owns (M.build_target) — no dependency build
--- or deploy in the editor; it and the preparations ask the
--- artifact-conflict question before the call, its Yes sent as `force`.

local M = {}

local VERB = { build = "build", configure = "configure", clean = "clean",
    prepare_run = "launch", prepare_debug = "debug launch", launch_build = "build", discover = "test discovery",
    run_cases = "test run", prepare_test_debug = "test debug preparation" }

--- The calls whose task-runner restart is not sent again (§19.16 "Tasks in
--- the task runner", step 5k C2): a launch's preparation ends in a program
--- the editor starts after the call, which a restart of the task alone
--- would never start.
M.NO_RESTART = { prepare_run = true, prepare_debug = true, prepare_test_debug = true }

--- @alias loomworks.daemon.OpContinuation { resolve: fun(v: any), reject: fun(err: any, notified: boolean|nil) }

--- The observer of `ws` when it carries `method` now, or nil. Only the
--- workspace's own observer carries its operations: a step chained from a
--- workspace the editor has since swapped away from is never sent to another
--- workspace's daemon.
--- @param method "build"|"configure"|"clean"|"prepare_run"|"prepare_debug"|"launch_build"|"discover"|"run_cases"|"prepare_test_debug"|"collect"|"result"
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
function M.carrier(method, ws)
    local obs = require("loomworks.daemon.observer").of(ws)
    if obs and obs.state ~= "stopped" and obs:can_call(method) then return obs end
    return nil
end

--- Is `ws` run in `daemon` mode — its operations then never run
--- in-process (§19.16 "Availability") — and its observer. False in the
--- deprecated `in-process` mode. A workspace selected for `daemon` whose
--- observer has stopped (swapped away) still counts: `obs` is then nil and
--- its operations are refused.
--- @param ws loomworks.Workspace|nil
--- @return boolean daemon, loomworks.daemon.Observer|nil obs
function M.daemon_of(ws)
    local obs = require("loomworks.daemon.observer").of(ws)
    if obs then return true, obs end
    local sel = ws and ws._runtime_selection
    return sel ~= nil and sel.daemon == true, nil
end

--- Refuse an operation the daemon cannot carry now (§19.16 "Availability"):
--- the observer's Runtime-line note as one notification line, then
--- `k.reject(message, true)`. Nothing runs in-process.
--- @param method string
--- @param obs loomworks.daemon.Observer|nil
--- @param k { reject: fun(err: any, notified: boolean|nil) }
function M.refuse(method, obs, k)
    local why = obs and obs.state ~= "stopped" and obs:refusal(method) or "the workspace is no longer loaded"
    local msg = (VERB[method] or method) .. ": " .. why
    vim.notify("loomworks: " .. msg, vim.log.levels.WARN)
    k.reject(msg, true)
end

--- In `daemon` mode, the refusal of a build of `ws` the daemon cannot carry
--- now (M.refuse's message, notified), or nil — carried, or the `in-process`
--- mode. A device target's build (still the editor's until step 5n) asks it
--- first, so that nothing of it (its pre-build deploy) runs in the editor
--- when its build would be refused.
--- @param ws loomworks.Workspace|nil
--- @return string|nil
function M.build_refusal(ws)
    local daemon, obs = M.daemon_of(ws)
    if not daemon or M.carrier("build", ws) then return nil end
    local msg
    M.refuse("build", obs, { reject = function(m) msg = m end })
    return msg
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
--- header): accepted → its `on_done` follows; declined → fails with the
--- reason as one notification; degraded → refused with the observer's note
--- of the method; refused → fails with its message; anything else fails
--- (all notified here: `k.reject(message, true)`).
--- @param method string
--- @param obs loomworks.daemon.Observer
--- @param k loomworks.daemon.OpContinuation
--- @return fun(r: table)
local function on_reply(method, obs, k)
    local verb = VERB[method] or method
    return function(r)
        if r.outcome == "accepted" then return end
        if r.outcome == "declined" then
            local msg = string.format("the workspace daemon declined the %s (%s)", verb, tostring(r.reason))
            vim.notify("loomworks: " .. msg, vim.log.levels.WARN)
            return k.reject(msg, true)
        elseif r.outcome == "degraded" then
            return M.refuse(method, obs, k)
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

--- Run an operation through the daemon (see the header). False only in
--- the `in-process` mode — the caller runs it in-process. Otherwise true,
--- and the operation ends through `k`: `k.resolve(true)` or
--- `k.reject(message, notified)` — refused at once when the daemon cannot
--- carry it now, never run in-process.
--- @param method "build"|"configure"|"clean"
--- @param scope { profile?: loomworks.Profile, units?: loomworks.ConfigUnit[] }
--- @param opts? { jobs?: integer, force?: boolean, targets?: table[] }
--- @param k loomworks.daemon.OpContinuation
--- @return boolean routed
function M.run(method, scope, opts, k)
    local ws = M.scope_workspace(scope)
    local daemon, mode_obs = M.daemon_of(ws)
    if not daemon then return false end
    local obs = M.carrier(method, ws)
    if not obs then
        M.refuse(method, mode_obs, k)
        return true
    end
    opts = opts or {}
    local verb = VERB[method] or method

    local function send(force)
        -- Still carried? (A deletion waited for, or a question asked, may
        -- have outlived the connection: nothing ran yet — refused.)
        if not obs:can_call(method) then return M.refuse(method, obs, k) end
        local args = M.args(scope, { jobs = opts.jobs, force = opts.force or force, targets = opts.targets })
        obs:start_owned(method, args, {
            units = scope_units(scope),
            on_reply = on_reply(method, obs, k),
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

--- Is a launch's preparation the daemon's — `daemon` mode, carried or
--- refused (M.prepare) — rather than the in-process chain's (the
--- `in-process` mode)? (The editor checks the debug adapter before the
--- call, §8.9.6.)
--- @param target loomworks.LaunchTarget
--- @return boolean
function M.prepares(target)
    return (M.daemon_of(M.scope_workspace({ profile = target._profile })))
end

--- Why the editor refuses now a launch it runs itself — a device target's
--- (§19.16 "Editor operations": only while connected) — in `daemon` mode:
--- not connected, the observer's Runtime-line note; nil while connected,
--- and always in the `in-process` mode.
--- @param target loomworks.LaunchTarget
--- @return string|nil
function M.device_launch_refusal(target)
    local daemon, obs = M.daemon_of(M.scope_workspace({ profile = target._profile }))
    if not daemon then return nil end
    if obs and obs.state == "connected" and obs.conn and not obs.conn.closed and not obs._lost then return nil end
    return "launch: " .. (obs and obs.state ~= "stopped" and obs:refusal("build") or "the workspace is no longer loaded")
end

--- A `Launch/1` call the editor owns on a non-device launch target (§19.16
--- "Editor operations"): the preparation of a run or debug launch
--- (`prepare_run` / `prepare_debug`) or, step 5t, the target's build
--- (`launch_build`, sent as `build`), under the availability rule of the
--- header; the artifact-conflict question asked first, its Yes sent as
--- `force` (step 5t). False only in the `in-process` mode — the caller runs the in-process
--- chain. Otherwise true, and it ends through `k`: `k.resolve(done)` with
--- the task result (`launch`, or `device = true` for a foreign artifact;
--- `debug`) once the preparation ended with exit 0 — the caller then starts
--- the program — or `k.reject(message, notified)` (refused when the daemon
--- cannot carry it now; no program is started).
--- The second return value cancels the preparation (a stop, or a second
--- launch replacing it, while it runs): nothing more reaches `k`, so no
--- program is started — a call not yet sent is never sent, one not yet
--- answered is cancelled once accepted, an accepted one at once
--- (`Tasks/1.cancel` of the owned task, Observer:cancel_owned_id).
--- @param method "prepare_run"|"prepare_debug"|"launch_build"
--- @param target loomworks.LaunchTarget
--- @param k { resolve: fun(done: table), reject: fun(err: any, notified: boolean|nil) }
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil preparation (routed, not refused at once)
local function launch_call(method, target, k)
    local ws = M.scope_workspace({ profile = target._profile })
    local daemon, mode_obs = M.daemon_of(ws)
    if not daemon then return false end
    local obs = M.carrier(method, ws)
    if not obs then
        M.refuse(method, mode_obs, k)
        return true
    end
    local verb = VERB[method]
    --- @class loomworks.daemon.Preparation
    --- @field cancelled boolean|nil cancelled: nothing more reaches its continuation
    --- @field task_id any|nil its owned task, once accepted
    --- @field cancel fun(self: loomworks.daemon.Preparation)
    local p = {}
    function p.cancel(self)
        if self.cancelled then return end
        self.cancelled = true
        if self.task_id ~= nil then obs:cancel_owned_id(self.task_id) end
    end
    -- Every outcome is dropped once cancelled (a refusal or failure is not
    -- notified either: the user stopped it).
    local function live(fn) return function(...) if not p.cancelled then return fn(...) end end end
    local kk = { resolve = live(k.resolve), reject = live(k.reject) }
    local reply = on_reply(method, obs, kk)
    local function send(force)
        if p.cancelled then return end
        if not obs:can_call(method) then return M.refuse(method, obs, kk) end
        local args = method == "launch_build" and M.target_build_args(target) or M.launch_args(target)
        if force then args.force = true end
        obs:start_owned(method, args, {
            on_reply = function(r)
                if r.outcome == "accepted" then
                    p.task_id = r.task_id
                    if p.cancelled then obs:cancel_owned_id(r.task_id) end
                end
                if p.cancelled then return end
                reply(r)
            end,
            on_done = function(task, reason, done)
                local err = failure(verb, task, reason)
                if err then return kk.reject(err) end
                kk.resolve(type(done) == "table" and done or {})
            end,
        })
    end
    -- The artifact-conflict question (§5.9) over the units the launch's
    -- build builds, before the call; its Yes travels as `force` (step 5t).
    local function go()
        if p.cancelled then return end
        ask_conflict(obs.ws, target:existing_build_units(), function(force, err)
            if err then
                if p.cancelled then return end
                vim.notify("loomworks: " .. err, vim.log.levels.WARN)
                return kk.reject(err, true)
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
    return true, p
end

--- Prepare a run (`mode` "launch") or debug launch of a non-device launch
--- target through the daemon (see launch_call).
--- @param mode "launch"|"debug"
--- @param target loomworks.LaunchTarget
--- @param k { resolve: fun(done: table), reject: fun(err: any, notified: boolean|nil) }
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil preparation (routed, not refused at once)
function M.prepare(mode, target, k)
    return launch_call(mode == "debug" and "prepare_debug" or "prepare_run", target, k)
end

--- The arguments of a launch target's build (`Launch/1.build`, §19.15
--- "Build of a launch target"): the launch target addressed as a
--- preparation addresses it (M.launch_args) — no `build_scope`, `cwd`,
--- `extra` or `no_build`, which the build does not take.
--- @param target loomworks.LaunchTarget
--- @return table
function M.target_build_args(target)
    local a = M.launch_args(target)
    a.build_scope, a.cwd = nil, nil
    return a
end

--- Build a non-device launch target through the daemon (step 5t, §19.16
--- "Editor operations"): ONE `Launch/1.build` the editor owns — the
--- daemon builds its dependencies, runs its pre-build deploy and builds its
--- own unit, reporting each as a step; nothing of it runs in the editor.
--- The artifact-conflict question is asked before the call, its Yes sent as
--- `force`. False only in the `in-process` mode — the caller builds
--- in-process. Otherwise true, and it ends through `k` as M.prepare does:
--- `k.resolve(done)` once the task ended with exit 0, else
--- `k.reject(message, notified)` (refused when the daemon cannot carry it
--- now — never built in the editor).
--- @param target loomworks.LaunchTarget
--- @param k { resolve: fun(done: table), reject: fun(err: any, notified: boolean|nil) }
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil handle (routed, not refused at once)
function M.build_target(target, k)
    return launch_call("launch_build", target, k)
end

--- The discovery of the active profile's tests through the daemon (step 5m
--- C1, §19.16 "Tests" Discovery): one `Tests/1.discover` the editor owns
--- (one overseer row, cancellable), carrying its environment. False when it
--- cannot be carried now — the caller shows the tests' status; there is
--- **no** in-process fallback, so a `declined`, a degraded method, a refusal
--- and a failure all end through `k.reject` with one notification line. The
--- tree itself arrives as the view's `update` (it precedes `done`).
--- @param ws loomworks.Workspace|nil
--- @param opts? { force?: boolean }
--- @param k { resolve: fun(done: table), reject: fun(err: any) }
--- @return boolean routed
function M.discover_tests(ws, opts, k)
    local obs = M.carrier("discover", ws)
    if not obs then return false end
    local args = {}
    if opts and opts.force then args.force = true end
    obs:start_owned("discover", args, {
        on_reply = function(r)
            if r.outcome == "accepted" then return end
            local why
            if r.outcome == "refused" then
                why = tostring(r.message)
            elseif r.outcome == "declined" then
                why = "the workspace daemon declined the test discovery (" .. tostring(r.reason) .. ")"
            else
                why = "the test discovery failed: " .. tostring(r.reason)
            end
            vim.notify("loomworks: " .. why, vim.log.levels.WARN)
            k.reject(why)
        end,
        on_done = function(task, reason, done)
            local err = failure(VERB.discover, task, reason)
            if err then return k.reject(err) end
            k.resolve(type(done) == "table" and done or {})
        end,
    })
    return true
end

--- Why an owned test call did not run (step 5m C2): its reply's outcome as
--- one line — never a fallback, the tests are not run in-process.
--- @param verb string
--- @param r table the reply (`refused`, `declined`, `degraded`, `failed`)
--- @return string
local function test_refusal(verb, r)
    if r.outcome == "refused" then return tostring(r.message) end
    if r.outcome == "declined" then
        return "the workspace daemon declined the " .. verb .. " (" .. tostring(r.reason) .. ")"
    elseif r.outcome == "degraded" then
        return "the workspace daemon cannot carry the " .. verb .. " (" .. tostring(r.reason) .. ")"
    end
    return "the " .. verb .. " failed: " .. tostring(r.reason)
end

--- An owned `Tests/1` task (`run_cases`, `prepare_test_debug`) of the
--- workspace `ws`'s daemon (step 5m C2, §19.16 "Tests" Runs, Debug): one
--- overseer row the editor owns. False when it cannot be carried now — the
--- caller refuses with the tests' status; nothing runs in-process. Otherwise
--- true and a handle whose `cancel` stops it (`Tasks/1.cancel` once
--- accepted; nothing more reaches `k` then), and it ends through `k`:
--- `k.resolve(done, err)` with the task result once it ended with a
--- `done` frame — `err` nil after exit 0, else why it failed; the caller
--- reads its result either way — or
--- `k.reject(message)` (not accepted: refused, declined, degraded, failed;
--- or the task ended without `done`: the connection lost). Nothing is
--- notified here.
--- @param method "run_cases"|"prepare_test_debug"
--- @param ws loomworks.Workspace|nil
--- @param args table
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string), accepted?: fun(task_id: any) } (`accepted` once the reply accepted it)
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil handle (routed only)
local function owned_test_call(method, ws, args, k)
    local obs = M.carrier(method, ws)
    if not obs then return false end
    local verb = VERB[method]
    local p = {}
    function p.cancel(self)
        if self.cancelled then return end
        self.cancelled = true
        if self.task_id ~= nil then obs:cancel_owned_id(self.task_id) end
    end
    local function live(fn) return function(...) if not p.cancelled then return fn(...) end end end
    local resolve, reject = live(k.resolve), live(k.reject)
    obs:start_owned(method, args, {
        on_reply = function(r)
            if r.outcome == "accepted" then
                p.task_id = r.task_id
                if p.cancelled then return obs:cancel_owned_id(r.task_id) end
                if k.accepted then k.accepted(r.task_id) end
                return
            end
            reject(test_refusal(verb, r))
        end,
        on_done = function(task, reason, done)
            if reason or type(done) ~= "table" then return reject(failure(verb, task, reason)) end
            resolve(done, failure(verb, task, nil))
        end,
    })
    return true, p
end

--- Run test nodes through the daemon (step 5m C2, §19.16 "Tests" Runs): one
--- `Tests/1.run_cases` the editor owns (`select` the nodes' view ids, none
--- for run-all; `no_build`). Ends through `k` as owned_test_call: a run
--- that ran (its result carries `cases`, failed tests included) resolves.
--- @param ws loomworks.Workspace|nil
--- @param select string[]|nil
--- @param opts { no_build?: boolean }|nil
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string), accepted?: fun(task_id: any) }
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil handle
function M.run_tests(ws, select, opts, k)
    local args = {}
    if select and #select > 0 then
        args.select = {}
        for i, id in ipairs(select) do args.select[i] = { id = id } end
    end
    if opts and opts.no_build then args.no_build = true end
    return owned_test_call("run_cases", ws, args, k)
end

--- Prepare debugging one test node through the daemon (step 5m C2, §19.16
--- "Tests" Debug): one `Tests/1.prepare_debug` the editor owns (`select` one
--- node, an object), resolving with its result (`debug`, `prepared`) or the
--- failure's `error` as owned_test_call ends.
--- @param ws loomworks.Workspace|nil
--- @param id string the node's view id
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string) }
--- @return boolean routed
--- @return loomworks.daemon.Preparation|nil handle
function M.prepare_test_debug(ws, id, k)
    return owned_test_call("prepare_test_debug", ws, { select = { id = id } }, k)
end

--- A plain `Tests/1` call (`collect`, `result`) of `ws`'s daemon: `cb(result,
--- err)` once on the main loop — the reply (a `refused` / `declined` one as
--- the daemon sent it, `err` its message), or nil and why. False when not
--- carried now (`cb` is not called).
--- @param method "collect"|"result"
--- @param ws loomworks.Workspace|nil
--- @param args table
--- @param cb fun(result: table|nil, err: string|nil)
--- @return boolean sent
local function test_request(method, ws, args, cb)
    local obs = M.carrier(method, ws)
    if not obs then return false end
    obs:request(method, args, function(r)
        if r.outcome ~= "ok" then return cb(nil, tostring(r.reason)) end
        local res = type(r.result) == "table" and r.result or {}
        if res.outcome == "refused" then return cb(nil, tostring(res.message)) end
        if res.outcome == "declined" then return cb(nil, tostring(res.reason)) end
        cb(res, nil)
    end)
    return true
end

--- After a prepared test debug session (or instead of one: the adapter was
--- not installed): `Tests/1.collect { prepared }` — the daemon reads the
--- results the program wrote, records them and drops the token
--- (§19.16 "Tests" Debug). `cb(cases|nil, err)`.
--- @param ws loomworks.Workspace|nil
--- @param prepared string
--- @param cb fun(cases: table[]|nil, err: string|nil)
--- @return boolean sent
function M.collect_tests(ws, prepared, cb)
    return test_request("collect", ws, { prepared = prepared }, function(res, err)
        if not res then return cb(nil, err) end
        cb(type(res.cases) == "table" and res.cases or {}, nil)
    end)
end

--- A node's last result with its output and error locations
--- (`Tests/1.result { id }`, §19.16 "Tests" Output). `cb(result|nil, err)`.
--- @param ws loomworks.Workspace|nil
--- @param id string
--- @param cb fun(result: table|nil, err: string|nil)
--- @return boolean sent
function M.test_result(ws, id, cb)
    return test_request("result", ws, { id = id }, cb)
end

--- A module clean through the daemon (Profile:clean / ConfigUnit:clean, via
--- the workspace's `_operation_router` and overseer.route_clean). False only
--- in the `in-process` mode; otherwise it ends through `k` as `M.run` —
--- refused at once when the daemon cannot carry it now. Before the call, the
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
    local scope_ws = M.scope_workspace(scope)
    local daemon, mode_obs = M.daemon_of(scope_ws)
    if not daemon then return false end
    local obs = M.carrier("clean", scope_ws)
    if not obs then
        M.refuse("clean", mode_obs, k)
        return true
    end
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
    -- An in-process operation chain on these units (a device launch's, the
    -- one operation the editor still runs itself) stops here, not after the
    -- clean (D5).
    if ws and ws.cancel_conflicting_operations then ws:cancel_conflicting_operations(units) end
    local items = {}
    for _, u in ipairs(units) do items[#items + 1] = { unit = u } end
    local local_ids = {}
    local running = ws and ws.find_running_tasks_for_items and ws:find_running_tasks_for_items(items) or {}
    for task_id in pairs(running) do local_ids[#local_ids + 1] = task_id end

    local function start()
        local function send() M.run("clean", scope, {}, k) end
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

--- The debug adapters section's records (§19.16 "Editor operations"): in
--- `daemon` mode `DebugConfig/1.adapters` as read on this connection —
--- nil and why while it is not carried (the section is unavailable), and
--- while its first read is in flight or after it failed; never the
--- in-process mapping. In the `in-process` mode the working copy's
--- (debug_config.adapter_records).
--- @param ws loomworks.Workspace
--- @return { language: string, adapter?: string, default?: string, known: string[], overridden: boolean }[]|nil records
--- @return string|nil why
function M.debug_adapters(ws)
    local daemon, obs = M.daemon_of(ws)
    if not daemon then return require("loomworks.debug_config").adapter_records(ws) end
    if not (obs and obs.state ~= "stopped") then return nil, "the workspace is no longer loaded" end
    if not obs:can_call("adapters") then return nil, obs:refusal("adapters") end
    local records = obs:debug_adapters()
    if records then return records end
    if obs._debug_fetch then return nil, "reading them from the workspace daemon" end
    return nil, "the workspace daemon did not answer DebugConfig/1.adapters"
end

--- The language → adapter mapping a debug launch the daemon prepares is
--- checked against before the call (§8.9.6, §19.16 "Editor operations"):
--- the daemon's own (`DebugConfig/1.adapters`, the cached read, else a read
--- now) while it is carried — the in-process copy lags a `set_adapter` made
--- through the daemon until its file change arrives. `cb(resolve)` on the
--- main loop, `resolve(language)` → adapter|nil, named (the records name
--- the language); `cb(nil)` when DebugConfig/1 is not carried, or its read
--- failed or was declined: no check before the call (debug.run checks the
--- prepared adapter). Never the editor's in-process mapping — a language the
--- daemon's records do not name resolves to nil, not named (unchecked too).
--- @param target loomworks.LaunchTarget the launch (its profile's workspace)
--- @param cb fun(resolve: (fun(language: string): string|nil, boolean)|nil)
function M.debug_adapter_resolver(target, cb)
    local ws = M.scope_workspace({ profile = target._profile })
    local obs = ws and require("loomworks.daemon.observer").of(ws)
    if not (obs and obs.state ~= "stopped" and obs:can_call("adapters")) then return cb(nil) end
    obs:with_debug_adapters(function(records)
        if not records then return cb(nil) end
        local by = {}
        for _, r in ipairs(records) do
            if type(r) == "table" and type(r.language) == "string" then by[r.language] = r end
        end
        cb(function(language)
            local r = by[language]
            if not r then return nil, false end
            return type(r.adapter) == "string" and r.adapter or nil, true
        end)
    end)
end

--- Set a language's debug adapter (`adapter` nil: back to the default) in
--- the working copy: in `daemon` mode **only** `DebugConfig/1.set_adapter`
--- — not carried, degraded, `declined`, `refused` or failed, the write
--- fails with why as one notification line and nothing is written
--- (§19.16 "Availability"); in the `in-process` mode
--- `Workspace:set_debug_adapter`. `cb(ok, err)` on the main loop.
--- @param ws loomworks.Workspace
--- @param language string
--- @param adapter string|nil
--- @param cb? fun(ok: boolean, err: string|nil)
function M.set_debug_adapter(ws, language, adapter, cb)
    cb = cb or function() end
    local function fail(err)
        vim.notify("loomworks: debug adapter not saved: " .. tostring(err), vim.log.levels.ERROR)
        cb(false, err)
    end
    local daemon, obs = M.daemon_of(ws)
    if not daemon then
        local ok, err = ws:set_debug_adapter(language, adapter)
        if not ok then return fail(err) end
        return cb(ok, err)
    end
    if not (obs and obs.state ~= "stopped") then return fail("the workspace is no longer loaded") end
    if not obs:can_call("set_adapter") then return fail(obs:refusal("set_adapter")) end
    obs:request("set_adapter", { language = language, adapter = adapter }, function(r)
        if r.outcome == "degraded" then return fail(obs:refusal("set_adapter")) end
        local res = type(r.result) == "table" and r.result or {}
        if r.outcome == "ok" and res.outcome == "declined" then
            return fail("the workspace daemon declined it (" .. tostring(res.reason) .. ")")
        end
        local err = r.outcome ~= "ok" and r.reason or (res.outcome ~= "ok" and (res.message or res.outcome)) or nil
        if err then return fail(err) end
        obs:_refetch_debug_adapters()
        cb(true)
    end)
end

--- Set a language server's option (`value` nil: removes the key) in the
--- working copy, in `daemon` mode (§19.16 "LSP configuration" Options):
--- **only** through `LspConfig/1.set_option` — the editor never writes
--- user.json `lsp` itself, and applies the option only from the state it
--- reads back, not from its own write. Every other outcome is an error,
--- notified with what happened, and nothing is written: the interface not
--- carried, a `refused` result (the daemon's message), an `invalid_args`
--- (an unknown server or key, a value its schema rejects), a `declined`
--- one, or a call that failed or got no answer (a timeout, the connection
--- lost). `cb(ok, err)` on the main loop.
--- @param ws loomworks.Workspace|nil
--- @param server string
--- @param key string
--- @param value any
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean sent false when it failed at once (notified, `cb` called)
--- @return string|nil err
function M.set_lsp_option(ws, server, key, value, cb)
    cb = cb or function() end
    local function fail(err)
        vim.notify("loomworks: LSP option not saved — " .. err, vim.log.levels.ERROR)
        cb(false, err)
        return false, err
    end
    local obs = require("loomworks.daemon.observer").of(ws)
    if not (obs and obs.state ~= "stopped" and obs:can_call("set_option")) then
        local note = obs and obs:lsp_note() or nil
        return fail("the workspace daemon does not carry the LSP configuration"
            .. (note and (" (" .. note .. ")") or ""))
    end
    obs:request("set_option", { server = server, key = key, value = value }, function(r)
        if r.outcome == "invalid" then return fail("invalid: " .. tostring(r.reason)) end
        if r.outcome ~= "ok" then
            return fail("the call to the workspace daemon failed: " .. tostring(r.reason or r.outcome))
        end
        local res = type(r.result) == "table" and r.result or {}
        if res.outcome == "refused" then
            return fail("the workspace daemon refused it: " .. tostring(res.message or "refused"))
        end
        if res.outcome == "declined" then
            return fail("the workspace daemon declined it" .. (res.reason and (" (" .. tostring(res.reason) .. ")") or ""))
        end
        if res.outcome ~= nil and res.outcome ~= "ok" then
            return fail("the workspace daemon answered " .. tostring(res.message or res.outcome))
        end
        -- Applied from the read back (its `model_change` reads it too).
        obs:_fetch_lsp()
        cb(true)
    end)
    return true
end

--- The router a daemon-mode workspace carries (`ws._operation_router`): the
--- domain objects' cleans ask it, with no dependency on the editor.
M.router = {
    clean = function(scope) return require("loomworks.overseer").route_clean(scope) end,
}

return M
