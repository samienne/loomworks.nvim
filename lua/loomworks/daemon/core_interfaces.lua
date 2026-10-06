--- loomworks/daemon/core_interfaces.lua — the core interfaces the build
--- service serves (spec §19.20 "Interface catalogue", step 5g.2 part A):
---
---   /workspace  loomworks.Workspace/1    header (changed)
---   /tasks      loomworks.Tasks/1        list, cancel (started, ended)
---   /internal   lw.internal.Snapshot/1   get (same_build)
---
--- Each method adapts the handler the protocol-10 request kind already uses
--- (loomworks.daemon.service), so the v0 alias and the interface method are
--- one implementation (§19.20 "Versions and deprecation"). None of them needs
--- a loaded workspace — `header` reports the state, `Snapshot.get` loads as
--- the `snapshot` request does — so they are mounted when the service is
--- attached, before any load, and no `objects_changed` follows a load.
---
--- Signals: `Workspace.changed` with every committed state-file write (beside
--- the protocol-10 `model_change` broadcast, §19.12); `Tasks.started` /
--- `Tasks.ended` as a task starts and ends, to the subscribers of `/tasks`
--- (filtered by the subscription's `task_id`). The task frames themselves
--- still reach every authenticated connection as in protocol 10 (§19.15)
--- until the observer subscribes (step 5g.3).

local envelope = require("loomworks.proto.envelope")

local M = {}

M.WORKSPACE = { path = "/workspace", iface = "loomworks.Workspace", v = 1 }
M.TASKS = { path = "/tasks", iface = "loomworks.Tasks", v = 1 }
M.SNAPSHOT = { path = "/internal", iface = "lw.internal.Snapshot", v = 1 }

--- The `loomworks.Workspace/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.workspace_impl(service)
    local methods = {}
    --- The welcome header's fields (§19.13), never loading.
    function methods.header(ctx)
        local srv = ctx.server
        local h = { root = srv.root, pid = srv.pid, lw_version = srv.identity,
            session_generation = srv.generation }
        local ok, model = pcall(service.header, service)
        if ok and type(model) == "table" then
            for k, v in pairs(model) do
                if h[k] == nil then h[k] = v end
            end
        end
        h.state = h.state or "unloaded"
        return h
    end
    return { methods = methods }
end

--- The `loomworks.Tasks/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.tasks_impl(service)
    local methods = {}
    function methods.list(ctx)
        local rows = service.tasks:snapshot()
        for _, r in ipairs(rows) do
            local t = service.tasks.tasks[r.task_id]
            r.owned = t ~= nil and t.owner == ctx.conn
        end
        return { tasks = rows }
    end
    function methods.cancel(ctx, args)
        local t = service.tasks.tasks[args.task_id]
        if not t or t.finished then
            return { outcome = "refused", message = "no running task " .. tostring(args.task_id), exit_code = 1 }
        end
        if t.owner ~= ctx.conn then
            return nil, envelope.err(envelope.ERR.forbidden,
                string.format("task %d belongs to another client", args.task_id))
        end
        local run = service:run_of_task(t)
        if not run then
            return { outcome = "refused", message = "task " .. tostring(args.task_id) .. " cannot be cancelled",
                exit_code = 1 }
        end
        -- As a disconnect does (§19.15): on the main loop, after the reply.
        vim.schedule(function()
            if not run.finished then run.cancel("cancelled by the client that started it", 130) end
        end)
        return { outcome = "ok" }
    end
    return { methods = methods }
end

--- The `lw.internal.Snapshot/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.snapshot_impl(service)
    local interfaces = require("loomworks.daemon.interfaces")
    local methods = {}
    function methods.get(ctx, args)
        service:_on_model_request(ctx.conn, { kind = "snapshot", env = ctx.env },
            service:_snapshot_answer(ctx.conn, args.scope), nil, function(fields) ctx.reply(fields) end)
        return interfaces.ASYNC
    end
    return { methods = methods, same_build = true, internal = true }
end

--- Mount the core interfaces of `service` on `registry`. A refused mount (a
--- missing or invalid document) is logged; the others still mount.
--- @param registry loomworks.daemon.Registry
--- @param service loomworks.daemon.BuildService
function M.mount(registry, service)
    for _, m in ipairs({
        { M.WORKSPACE, M.workspace_impl },
        { M.TASKS, M.tasks_impl },
        { M.SNAPSHOT, M.snapshot_impl },
    }) do
        local where, make = m[1], m[2]
        local ok, err = registry:mount(where.path, "core", where.iface, where.v, make(service))
        if not ok then registry:_log("interface %s/%d not mounted: %s", where.iface, where.v, tostring(err)) end
    end
end

--- The `Tasks.started` / `Tasks.ended` signals of a task (the stream's hooks).
--- @param registry loomworks.daemon.Registry
--- @param task loomworks.daemon.Task
--- @param name "started"|"ended"
--- @param args table
function M.task_signal(registry, task, name, args)
    registry:emit(M.TASKS.path, M.TASKS.iface, M.TASKS.v, name, args, function(sub_args)
        return sub_args.task_id == nil or sub_args.task_id == task.id
    end)
end

--- The `Workspace.changed` signal of a model change (§19.12).
--- @param registry loomworks.daemon.Registry
--- @param seq integer
--- @param generation integer
function M.changed(registry, seq, generation)
    registry:emit(M.WORKSPACE.path, M.WORKSPACE.iface, M.WORKSPACE.v, "changed",
        { seq = seq, session_generation = generation })
end

return M
