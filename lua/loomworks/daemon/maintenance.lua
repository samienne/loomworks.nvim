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
--- delete), `confirm { lines, plan, unit_ids }` without `yes` (`unit_ids`
--- the ids of the units whose build state the plan removes, by the same
--- issuer as the view's — a matcher for the client's own tasks only), else
--- `accepted` with the task.
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
---
--- `nuke { plan?, yes? }` (part B6), task-streamed (`meta.kind = "nuke"`):
--- the in-process nuke (`Core:nuke_check` / `_nuke_begin` / `_nuke_run`,
--- `lw nuke`'s) in a model segment. Refused while any task of this daemon
--- runs (listed; none is passed over or stopped) and when a lock is held
--- (its holder named) — both checked before the listing, also without
--- `yes`, and again in the task under the locks, where the plan (the build
--- directories it locks, the owned LSP database areas) is compared too.
--- The task then unloads the model, removes and loads the workspace again;
--- a cancel once the removal started is ignored (it runs to its end). Served
--- also while the workspace load is refused (as trust_accept is).
--- Deletion safety: no deletion path here; every path is `_nuke_begin`'s
--- (`_safe_nvim_path`, the area checks aborting the whole nuke first).

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
        local unit_ids = {}
        for _, u in ipairs(r.units or {}) do unit_ids[#unit_ids + 1] = svc.ids:id(u) end
        return ctx.reply({ outcome = "confirm", lines = r.lines, plan = r.plan, unit_ids = unit_ids,
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

-- ---------------------------------------------------------------------------
-- nuke (step 5o part B6)
-- ---------------------------------------------------------------------------

--- The token family of a nuke plan, the header of its listing, its plan and
--- its listing: the command layer's (loomworks.model_commands, shared with
--- the in-process nuke the status page runs, step 5o C2c-2).
local mc_nuke = require("loomworks.model_commands")
M.NUKE_KIND = mc_nuke.NUKE_KIND
M.NUKE_HEADER = mc_nuke.NUKE_HEADER
M.nuke_plan = mc_nuke.nuke_plan
M.nuke_listing = mc_nuke.nuke_listing

--- The workspace core the nuke runs on (the host's, else the model's).
--- @param svc loomworks.daemon.BuildService
--- @param ws table|nil
--- @return table|nil
local function nuke_core(svc, ws)
    local c = svc.host.core and svc.host.core() or nil
    return c or (ws and ws._core) or nil
end

--- A core nuke message without core's own `loomworks: ` prefix.
--- @param msg any
--- @return string
local function nuke_message(msg)
    return (tostring(msg or "nuke failed"):gsub("^loomworks: ", ""))
end

--- The daemon's own running work a nuke refuses on (API.md §22, spec §19.3:
--- the daemon's nuke passes over none of its own tasks): every task not
--- ended but `except` (the nuke's own), in start order, and every deletion
--- run whose task ended while its removal still settles. One display string
--- each; empty when nothing runs.
--- @param svc loomworks.daemon.BuildService
--- @param except? table the nuke's own task
--- @return string[]
function M.nuke_busy(svc, except)
    local list = {}
    for _, t in pairs(svc.tasks.tasks or {}) do
        if t ~= except and not t.finished then list[#list + 1] = t end
    end
    table.sort(list, function(a, b) return a.n < b.n end)
    local out = {}
    for _, t in ipairs(list) do
        local m = t.meta or {}
        local what = m.kind or "task"
        if m.name and m.name ~= "" then what = what .. " " .. tostring(m.name) end
        out[#out + 1] = what .. " (task " .. tostring(t.id) .. ")"
    end
    for run in pairs(svc.runs or {}) do
        if run.deleting and not run.deletion_settled and (not run.task or run.task.finished) then
            out[#out + 1] = (run.op or "delete") .. " still removing (task "
                .. tostring(run.task and run.task.id or "?") .. ")"
        end
    end
    return out
end

--- The refusal for `busy` (M.nuke_busy).
--- @param busy string[]
--- @return string
local function busy_refusal(busy)
    return "cannot nuke: tasks are running in the workspace daemon — wait for them, or cancel them: "
        .. table.concat(busy, ", ")
end

--- `fn()` with `lock_break.requested` cleared: the daemon's nuke never
--- breaks a holder (it has no `--break-locks`).
--- @param fn function
--- @return any ...
local function no_break(fn)
    local lock_break = require("loomworks.lock_break")
    local requested = lock_break.requested
    lock_break.requested = nil
    local r = { pcall(fn) }
    lock_break.requested = requested
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, table.maxn(r))
end

--- Run an accepted nuke as task `ctx.task`: in its own model segment (a
--- cancel that arrives before the removal ends it `nuke stopped: <reason>`
--- with nothing removed; one that arrives after is ignored), the daemon's
--- own tasks and the locks are checked again —
--- `Core:_nuke_begin` takes the workspace operation lock and every build
--- lock, a held one ends the task naming its holder — the plan is compared
--- under them, the model is unloaded, `Core:_nuke_run` removes, and the
--- workspace is loaded again (`header_changed`, every id stale). This adds
--- no deletion path: every path is `_nuke_begin`'s (`_safe_nvim_path`, the
--- area checks, which abort the whole nuke before anything is removed).
--- @param svc loomworks.daemon.BuildService
--- @param ctx table { task, ws, plan?, listing? }
--- @return table run
function M.nuke_run(svc, ctx)
    local task = ctx.task
    -- `keeps_on_reload`: the nuke's own unload must not cancel it.
    local run = { task = task, op = "nuke", cancelled = false, held = {}, keeps_on_reload = true }
    ctx.run = run
    local st -- the `_nuke_begin` state while it is held
    local core

    local function maybe_release()
        if run.released or not run.finished or run.executing then return end
        run.released = true
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function finish(code, err)
        if run.finished then return end
        run.finished = true
        -- The reload's `header_changed` and the views' update precede `done`.
        pcall(require("loomworks.daemon.core_interfaces").header_check, svc)
        task:done(code, err)
        maybe_release()
    end
    local function stopped()
        return "nuke stopped: " .. tostring(run.cancel_reason or "cancelled")
    end
    --- Release what `_nuke_begin` took (idempotent; `Service:on_stopping`).
    function run.release_all()
        if st and core then pcall(core._nuke_release, core, st) end
    end

    --- Stop the nuke (idempotent). Before it executes it ends at once; while
    --- it executes it stops at the next check, before the removal. Once the
    --- removal started (the model is unloaded) a cancel is ignored: the
    --- removal runs to its end (the operation lock is held until it has,
    --- spec §19.3) and the nuke ends as it would without the cancel.
    function run.cancel(reason, code)
        if run.cancelled or run.finished or run.removing then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.executing then return end
        svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
    end

    task:start({ name = "nuke", kind = "nuke" })
    for _, line in ipairs(ctx.listing or {}) do task:line("out", line, "plain") end

    local function execute()
        core = nuke_core(svc, ctx.ws)
        if not core then return finish(1, "cannot nuke: the workspace core is not available") end
        local root = svc.server.root
        local norm_root = core._deps.normalize(root)
        -- The daemon's own tasks again (one may have started since the call).
        local busy = M.nuke_busy(svc, task)
        if #busy > 0 then return finish(1, busy_refusal(busy)) end
        -- The safety checks of every path, then the locks, taken and held:
        -- O, then every build lock in canonical order.
        local why
        st, why = no_break(function() return core:_nuke_begin(root) end)
        if not st then return finish(1, nuke_message(why)) end
        -- Plan again under the locks: a different one is refused, nothing removed.
        if ctx.plan ~= nil and M.nuke_plan(core, norm_root, st.areas).token ~= ctx.plan then
            run.release_all()
            return finish(1, require("loomworks.deletion_plan").CHANGED)
        end
        if run.cancelled then
            run.release_all()
            return finish(run.cancel_code, stopped())
        end
        -- From here on the removal runs to its end; a cancel is ignored.
        run.removing = true
        -- Unload the model (a late save of it writes nothing), then remove.
        if svc.ws then svc.ws._no_write = "the workspace is being nuked" end
        svc:_unload()
        local errors = {}
        local saved_notify = core._deps.notify
        core._deps.notify = function(msg, level)
            if level and level >= vim.log.levels.ERROR then
                errors[#errors + 1] = nuke_message(msg)
                task:line("err", nuke_message(msg), "fail")
            elseif level and level >= vim.log.levels.WARN then
                task:line("err", nuke_message(msg), "warn")
            end
        end
        local rok, done = pcall(core._nuke_run, core, st)
        core._deps.notify = saved_notify
        run.release_all()
        -- Load the workspace again (`header_changed`; every id is stale).
        local ws2, lerr = svc:live(ctx)
        if not ws2 and lerr then
            task:line("err", "the workspace did not load again: " .. tostring(lerr), "warn")
        end
        if not rok then return finish(1, "nuke failed: " .. tostring(done)) end
        if not done or #errors > 0 then
            if #errors == 1 and errors[1]:find("^cannot nuke: ") then return finish(1, errors[1]) end
            return finish(1, #errors == 0 and "nuke failed" or ("nuke failed: " .. table.concat(errors, "; ")))
        end
        return finish(0)
    end

    svc:with_model(ctx, function()
        if run.finished then return maybe_release() end
        run.executing = true
        local ok, err = pcall(execute)
        run.executing = false
        if not ok then
            run.release_all()
            finish(1, "nuke failed: " .. tostring(err))
        end
        maybe_release()
    end)
    return run
end

--- The model segment that answers a nuke: the daemon's own tasks, then the
--- locks (checked, not held), then the plan: `refused`, `confirm { lines,
--- plan }` without `yes`, else `accepted` with the task. Like
--- `Workspace/1.trust_accept` it is served while the workspace load is
--- refused (an invalid build cache, spec §17.4: nuke is its remedy): with no
--- model it acts on the core alone, through the same checks
--- (`_nuke_begin`'s safety checks and locks, the busy check, the plan).
--- @param svc loomworks.daemon.BuildService
--- @param ctx table
function M.nuke_accept(svc, ctx)
    if ctx.conn.closed then return end
    local ws, refusal, decline = svc:live(ctx)
    local function refuse(msg, code)
        return ctx.reply({ outcome = "refused", message = msg, exit_code = code or 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
    if ws then
        if ctx.refused then return refuse(ctx.refused) end
        if ws._tracker and ws._tracker.sync then ws._tracker:sync() end
        if svc.host.current() ~= ws then
            return refuse("the workspace was reloaded (refused or changed .nvim files); try again")
        end
    end
    -- No model (the load refused or failed): the core alone (as trust_accept).
    local core = nuke_core(svc, ws)
    if not core then return refuse(refusal or "cannot nuke: the workspace core is not available") end
    -- The daemon's own tasks are neither passed over nor stopped.
    local busy = M.nuke_busy(svc)
    if #busy > 0 then return refuse(busy_refusal(busy)) end
    -- The locks before the listing, also without `yes` (spec §19.3):
    -- taken and released, never breaking a holder.
    local root = svc.server.root
    local ok, why, areas = no_break(function() return core:nuke_check(root) end)
    if not ok then return refuse(nuke_message(why)) end
    local a = ctx.args
    local plan = M.nuke_plan(core, core._deps.normalize(root), areas)
    if a.plan ~= nil and a.plan ~= plan.token then
        return refuse(require("loomworks.deletion_plan").CHANGED)
    end
    local listing = M.nuke_listing(core, root, areas)
    if a.yes ~= true then
        return ctx.reply({ outcome = "confirm", lines = listing, plan = plan.token,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local task = svc.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.plan = task, ws, a.plan
    ctx.listing = a.plan == nil and listing or nil
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), pid = svc.server.pid,
        notes = ctx.notes, note_roles = ctx.note_roles })
    local run = M.nuke_run(svc, ctx)
    svc.server:log("nuke (task %s) accepted", task.id)
    if not run.released then
        run.ctx = ctx
        svc.runs[run] = true
    end
end

--- The `Maintenance/1.nuke` handler.
--- @param service loomworks.daemon.BuildService
--- @return function
function M.nuke_method(service)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(cctx, args)
        local srv = service.server
        local env, eerr = envscope.validate(cctx.env)
        local ctx = { op = "nuke", conn = cctx.conn, env = env, args = args or {},
            call = require("loomworks.daemon.core_interfaces").task_call(cctx.registry, M.WHERE, "nuke") }
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
            service:with_model(ctx, function() M.nuke_accept(service, ctx) end)
        end
        return interfaces.ASYNC
    end
end

--- The `loomworks.Maintenance/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.impl(service)
    return { methods = { execute_deletion = M.execute_deletion_method(service), nuke = M.nuke_method(service) } }
end

return M
