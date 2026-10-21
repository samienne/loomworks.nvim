--- loomworks/daemon/maintenance.lua — `loomworks.Maintenance/1` on
--- `/maintenance` (API.md §22; step 5o part B5): `execute_deletion { target,
--- plan?, yes? }`, task-streamed (`meta.kind = "delete"`).
---
--- The method is the in-process command (loomworks.model_commands
--- `deletion_request` / `deletion_run`) in a model segment of the caller's
--- environment: the target's ids resolve to the live objects once, here (the
--- input boundary), the deletion is planned (loomworks.deletion_plan) after
--- resolution and before any lock, and answered with `reset`'s outcomes
--- (§8.5, §8.6): `refused` (a stale target, a stray dir outside the
--- workspace or not in the current stray set, a changed plan, nothing to
--- delete), `confirm { lines, plan }` without `yes`, else `accepted` with
--- the task.
---
--- Deletion safety (project CLAUDE.md): this module removes nothing itself
--- and adds no deletion path. The accepted task runs `deletion_run`, which
--- takes the workspace operation lock and every build-directory lock of the
--- plan through `Workspace:_locked_deletion`, plans again under them (a
--- changed plan is refused before any removal) and executes the plan through
--- the Workspace's deletion paths (`_validate_build_dir` on every path, the
--- cache `unknown` before a tree is removed, shared and live directories
--- kept). A cancel is the deletion's stop predicate: it stops between
--- entries (`delete stopped: <reason>`). The run stays registered — the
--- daemon busy — until the deletion and its locks have settled, also after
--- its task ended.

local envscope = require("loomworks.daemon.envscope")
local tasks_mod = require("loomworks.daemon.tasks")

local M = {}

M.WHERE = { path = "/maintenance", iface = "loomworks.Maintenance", v = 1 }

--- The deletion target a call names, resolved to the live objects, or nil +
--- the refusal (a stale id, an unknown key). `profile` and `project` are a
--- reference (`{ id }` or `{ key }`); `unit` an id from the views
--- (`view.Workspace/1`) or `{ project, configuration }` (the `snapshot.index`
--- config_units shape); `build_dir` an id or `{ key }` (the orphan row's cache
--- key); `stray_dir` a path; `orphans` `true`. Keys resolve here, once.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param t table the wire target
--- @return table|nil target, string|nil err
function M.resolve_target(service, ws, t)
    local function by_ref(ref, list, what)
        if ref.id ~= nil then
            local o = service.ids:find(ref.id, list)
            if not o then return nil, "no " .. what .. " with id " .. tostring(ref.id) .. " (a stale reference)" end
            return o
        end
        for _, o in pairs(list or {}) do
            if not o._removed and o.key == ref.key then return o end
        end
        return nil, "no " .. what .. " '" .. tostring(ref.key) .. "'"
    end
    local function by_id(ref, list, what)
        local o = service.ids:find(ref.id, list)
        if not o then return nil, "no " .. what .. " with id " .. tostring(ref.id) .. " (a stale reference)" end
        return o
    end
    local o, err
    if t.profile ~= nil then
        o, err = by_ref(t.profile, ws._profiles, "profile")
        return o and { profile = o } or nil, err
    elseif t.project ~= nil then
        o, err = by_ref(t.project, ws._projects, "project")
        return o and { project = o } or nil, err
    elseif t.unit ~= nil then
        if t.unit.id == nil and t.unit.project ~= nil then
            -- `{ project, configuration }`: the `snapshot.index` config_units shape.
            for _, u in pairs(ws._config_units or {}) do
                local p = u._project
                if not u._removed and p and not p._removed and p.key == t.unit.project
                        and u.config_key and u:config_key() == t.unit.configuration then
                    return { unit = u }
                end
            end
            return nil, "no configuration unit '" .. tostring(t.unit.project) .. "/"
                .. tostring(t.unit.configuration) .. "'"
        end
        o, err = by_id(t.unit, ws._config_units, "configuration unit")
        return o and { unit = o } or nil, err
    elseif t.build_dir ~= nil then
        if t.build_dir.id == nil and t.build_dir.key ~= nil then
            -- `{ key }`: the view.Workspace/1 orphan row's cache key.
            for _, oc in ipairs(ws:get_orphaned_configs()) do
                if oc.build_dir_obj and (oc.build_dir_key or oc.config_key) == t.build_dir.key then
                    return { build_dir = oc.build_dir_obj }
                end
            end
            return nil, "no build directory '" .. tostring(t.build_dir.key) .. "'"
        end
        o, err = by_id(t.build_dir, ws._build_dirs, "build directory")
        return o and { build_dir = o } or nil, err
    elseif t.stray_dir ~= nil then
        return { stray_dir = t.stray_dir }
    elseif t.orphans == true then
        return { orphans = true }
    end
    return nil, "a deletion target is exactly one of profile, unit, build_dir, stray_dir, orphans, project"
end

--- Run an accepted deletion as task `ctx.task` (see the header).
--- @param svc loomworks.daemon.BuildService
--- @param ctx table { task, ws, deletion, listing }
--- @return table run
function M.run(svc, ctx)
    local mc = require("loomworks.model_commands")
    local task, ws, deletion = ctx.task, ctx.ws, ctx.deletion
    local run = { task = task, op = "delete", cancelled = false, held = {} }
    ctx.run = run

    -- The run is reported done once its task ended AND the deletion (and
    -- its locks, `_locked_deletion`) settled.
    local function maybe_release()
        if run.released or not run.finished or (run.deleting and not run.deletion_settled) then return end
        run.released = true
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function finish(code, err)
        if run.finished then return end
        run.finished = true
        -- The task's writes' `changed` and the views' update precede `done`.
        pcall(require("loomworks.daemon.core_interfaces").header_check, svc)
        task:done(code, err)
        maybe_release()
    end

    --- Stop the deletion (idempotent): a running deletion stops between
    --- entries, its end finishing the task.
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.deleting and not run.deletion_settled then return end
        svc:with_model(ctx, function() finish(run.cancel_code, "delete stopped: " .. run.cancel_reason) end)
    end

    task:start({ name = deletion.label, kind = "delete" })
    for _, line in ipairs(ctx.listing or {}) do task:line("out", line, "plain") end

    run.deleting = true
    local f = mc.deletion_run(ws, deletion, {
        stop = function() return run.cancelled end,
        stop_reason = function() return run.cancel_reason end,
    }, function(outcome)
        svc:with_model(ctx, function()
            if outcome.outcome == "ok" then
                for _, n in ipairs(outcome.notes or {}) do task:line("out", n, "warn") end
                task:line("out", "DELETE OK: " .. deletion.label, "ok")
                return finish(0)
            end
            local code = outcome.exit_code or 1
            if run.cancelled and run.cancel_code then code = run.cancel_code end
            finish(code, outcome.message)
        end)
    end)
    local function settled()
        svc:with_model(ctx, function()
            run.deletion_settled = true
            maybe_release()
        end)
    end
    f:next(settled, settled)
    return run
end

--- The model segment that answers the call: resolve, plan, then refuse,
--- confirm or accept.
--- @param svc loomworks.daemon.BuildService
--- @param ctx table
function M.accept(svc, ctx)
    if ctx.conn.closed then return end
    local ws, refusal, decline = svc:live(ctx)
    local function refuse(msg, code, stream)
        return ctx.reply({ outcome = "refused", message = msg, exit_code = code or 1, stream = stream,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if not ws then
        if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
        return refuse(refusal)
    end
    if ctx.refused then return refuse(ctx.refused) end
    -- A change another process wrote is taken in first (§2.7).
    if ws._tracker and ws._tracker.sync then ws._tracker:sync() end
    if svc.host.current() ~= ws then
        return refuse("the workspace was reloaded (refused or changed .nvim files); try again")
    end
    local a = ctx.args
    local target, terr = M.resolve_target(svc, ws, a.target or {})
    if not target then return refuse(terr) end
    local r = require("loomworks.model_commands").deletion_request(ws, target, a.plan, a.yes == true)
    if r.outcome == "refused" then return refuse(r.message, r.exit_code, r.stream) end
    if r.outcome == "confirm" then
        return ctx.reply({ outcome = "confirm", lines = r.lines, plan = r.plan,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local task = svc.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.deletion, ctx.listing = task, ws, r.deletion, r.listing
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), pid = svc.server.pid,
        notes = ctx.notes, note_roles = ctx.note_roles })
    local run = M.run(svc, ctx)
    svc.server:log("delete %s (task %s) accepted", r.deletion.label, task.id)
    if not run.released then
        run.ctx = ctx
        svc.runs[run] = true
        if run.deleting and not run.deletion_settled then svc:_update_busy() end
    end
end

--- The `Maintenance/1.execute_deletion` handler.
--- @param service loomworks.daemon.BuildService
--- @return function
function M.execute_deletion_method(service)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(cctx, args)
        local srv = service.server
        local env, eerr = envscope.validate(cctx.env)
        local ctx = { op = "delete", conn = cctx.conn, env = env, args = args or {},
            call = require("loomworks.daemon.core_interfaces").task_call(cctx.registry, M.WHERE,
                "execute_deletion") }
        function ctx.reply(fields)
            ctx.replied = true
            service:_before_ack(ctx)
            return cctx.reply(fields)
        end
        if not env then
            ctx.reply({ outcome = "declined", reason = eerr })
        elseif service.stopping or srv.stopped then
            ctx.reply({ outcome = "declined", reason = "the workspace runtime is stopping" })
        elseif srv.retiring then
            ctx.reply({ outcome = "declined", reason = "the daemon is retiring" })
        else
            service:with_model(ctx, function() M.accept(service, ctx) end)
        end
        return interfaces.ASYNC
    end
end

--- The `loomworks.Maintenance/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.impl(service)
    return { methods = { execute_deletion = M.execute_deletion_method(service) } }
end

return M
