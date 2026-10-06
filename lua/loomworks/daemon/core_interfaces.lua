--- loomworks/daemon/core_interfaces.lua — the core interfaces the build
--- service serves (spec §19.20 "Interface catalogue", step 5g.2):
---
---   /workspace   loomworks.Workspace/1    header (changed, header_changed)
---   /tasks       loomworks.Tasks/1        list, cancel (started, ended)
---   /internal    lw.internal.Snapshot/1   get (same_build)
---   /build       loomworks.Build/1        build T, clean T, reset T
---   /tests       loomworks.Tests/1        run T
---   /launch      loomworks.Launch/1       prepare_run T
---   /toolchains  loomworks.Toolchains/1   list
---   /profiles    loomworks.Profiles/1     compiler_cache
---
--- Each method adapts the handler the protocol-10 request kind already uses
--- (loomworks.daemon.service), so the v0 alias and the interface method are
--- one implementation (§19.20 "Versions and deprecation"). None of them needs
--- a loaded workspace at mount time — `header` reports the state, the others
--- load as their v0 requests do — so they are mounted when the service is
--- attached, before any load, and no `objects_changed` follows a load.
---
--- T = task-streamed (§19.15 "Tasks of interface methods"): the method
--- replies with the operation's outcome (`accepted` with the `task_id`, or
--- `refused` / `declined` / `confirm`) and the task's frames follow on the
--- transport's task stream; the start meta names the method (`object`,
--- `iface`, `v`, `method`) and `done.result` carries the task result its
--- schema declares (`Task.call`, loomworks.daemon.tasks).
---
--- References (§19.20): an entity argument is `{ key }` (the CLI) or `{ id }`
--- (an id from a snapshot's index); an id is resolved against the live model
--- in the request's model segment, and a stale one is the refused result.
---
--- Signals: `Workspace.changed` with every committed state-file write (beside
--- the protocol-10 `model_change` broadcast, §19.12);
--- `Workspace.header_changed` when the header's state, name, active profile
--- or error changed (checked after every model segment and every write);
--- `Tasks.started` / `Tasks.ended` as a task starts and ends, to the
--- subscribers of `/tasks` (filtered by the subscription's `task_id`). The
--- task frames themselves still reach every authenticated connection as in
--- protocol 10 (§19.15) until the observer subscribes (step 5g.3).

local envelope = require("loomworks.proto.envelope")

local M = {}

M.WORKSPACE = { path = "/workspace", iface = "loomworks.Workspace", v = 1 }
M.TASKS = { path = "/tasks", iface = "loomworks.Tasks", v = 1 }
M.SNAPSHOT = { path = "/internal", iface = "lw.internal.Snapshot", v = 1 }
M.BUILD = { path = "/build", iface = "loomworks.Build", v = 1 }
M.TESTS = { path = "/tests", iface = "loomworks.Tests", v = 1 }
M.LAUNCH = { path = "/launch", iface = "loomworks.Launch", v = 1 }
M.TOOLCHAINS = { path = "/toolchains", iface = "loomworks.Toolchains", v = 1 }
M.PROFILES = { path = "/profiles", iface = "loomworks.Profiles", v = 1 }

--- The header of `Workspace/1` (the welcome header's fields, §19.13), never
--- loading.
--- @param service loomworks.daemon.BuildService
--- @return table
function M.header(service)
    local srv = service.server
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

--- Emit `Workspace.header_changed { header }` when the header's model fields
--- differ from the last ones seen (the first call only records them).
--- @param service loomworks.daemon.BuildService
function M.header_check(service)
    local h = M.header(service)
    local sig = table.concat({ tostring(h.state), tostring(h.name), tostring(h.active_profile),
        tostring(h.error) }, "\n")
    local last = service._header_sig
    service._header_sig = sig
    if last == nil or last == sig then return end
    local reg = service.server.interfaces
    if reg then reg:emit(M.WORKSPACE.path, M.WORKSPACE.iface, M.WORKSPACE.v, "header_changed", { header = h }) end
end

--- The `loomworks.Workspace/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.workspace_impl(service)
    local methods = {}
    function methods.header() return M.header(service) end
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

-- ---------------------------------------------------------------------------
-- The operations (task-streamed) and the queries
-- ---------------------------------------------------------------------------

--- @class loomworks.daemon.TaskCall
--- The interface method a task runs for (`Task.call`).
--- @field object string
--- @field iface string
--- @field v integer
--- @field method string
--- @field result fun(exit_code: integer, err: string|nil, fields: table, extra: table|nil): table

--- The `Task.call` of a task-streamed method: its interface identity and the
--- builder of its `done.result` (shaped to, and in development builds and
--- tests validated against, the method's task result schema; a violation is
--- logged).
--- @param registry loomworks.daemon.Registry
--- @param where { path: string, iface: string, v: integer }
--- @param method string
--- @return loomworks.daemon.TaskCall
function M.task_call(registry, where, method)
    local e = registry:resolve(where.path, where.iface, where.v)
    local tdoc = e and e.doc.methods and e.doc.methods[method] and e.doc.methods[method].task
    return { object = where.path, iface = where.iface, v = where.v, method = method,
        result = function(exit_code, err, fields, extra)
            local r = { exit_code = exit_code, error = type(err) == "string" and err or nil }
            if fields.launch ~= nil then r.launch = fields.launch end
            if fields.device then r.device = true end
            for k, v in pairs(type(extra) == "table" and extra or {}) do r[k] = v end
            if not (e and tdoc) then return r end
            r = registry:_shape(e, tdoc.result, r)
            if registry.validate_out then
                local ok, verr = registry:_validate(e, tdoc.result, r)
                if not ok then
                    registry:_log("%s/%d.%s task result does not match its schema: %s", where.iface, where.v,
                        method, tostring(verr))
                end
            end
            return r
        end }
end

--- An operation's wire args → the protocol-10 request's args: a reference
--- `profile` / `project` becomes its key (`{ key }`) or the id to resolve
--- (`profile_id` / `project_id`, Service:_resolve_ids); `interactive` and
--- `command` are the request's own fields.
--- @param args table
--- @return table
function M.operation_args(args)
    local a = {}
    for k, v in pairs(args) do
        if k ~= "interactive" and k ~= "command" and k ~= "profile" and k ~= "project" then a[k] = v end
    end
    for _, name in ipairs({ "profile", "project" }) do
        local r = args[name]
        if type(r) == "table" then
            if r.key ~= nil then a[name] = r.key else a[name .. "_id"] = r.id end
        end
    end
    return a
end

--- The handler of a task-streamed operation method.
--- @param service loomworks.daemon.BuildService
--- @param op "build"|"test"|"run"|"clean"|"reset"
--- @param where table
--- @param method string
--- @return function
local function operation(service, op, where, method)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(ctx, args)
        service:_on_operation(op, ctx.conn, { args = M.operation_args(args), interactive = args.interactive == true,
            command = args.command, env = ctx.env }, function(fields) ctx.reply(fields) end,
            M.task_call(ctx.registry, where, method))
        return interfaces.ASYNC
    end
end

--- The `loomworks.Build/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.build_impl(service)
    return { methods = {
        build = operation(service, "build", M.BUILD, "build"),
        clean = operation(service, "clean", M.BUILD, "clean"),
        reset = operation(service, "reset", M.BUILD, "reset"),
    } }
end

--- The `loomworks.Tests/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.tests_impl(service)
    return { methods = { run = operation(service, "test", M.TESTS, "run") } }
end

--- The `loomworks.Launch/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.launch_impl(service)
    return { methods = { prepare_run = operation(service, "run", M.LAUNCH, "prepare_run") } }
end

--- A query method: registered query `name` (snapshot.QUERIES) in a model
--- segment with `query_args(resolved args)`, its result mapped to the
--- method's by `map`; a stale reference is the refused result.
--- @param service loomworks.daemon.BuildService
--- @param name string
--- @param map fun(result: table): table
--- @param query_args? fun(a: table): table
--- @return function
local function query(service, name, map, query_args)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(ctx, args)
        service:_on_model_request(ctx.conn, { kind = "query", env = ctx.env }, function(ws)
            local qa = M.operation_args(args)
            local stale = service:_resolve_ids(ws, qa)
            if stale then return { outcome = "refused", message = stale, exit_code = 1 } end
            local f = service:_query(ctx.conn, ws, name, query_args and query_args(qa) or {})
            if f.outcome then return f end
            return map(f.result)
        end, nil, function(fields) ctx.reply(fields) end)
        return interfaces.ASYNC
    end
end

--- The `loomworks.Toolchains/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.toolchains_impl(service)
    return { methods = {
        list = query(service, "tools", function(r) return { tools = r.tools or {} } end),
    } }
end

--- The `loomworks.Profiles/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.profiles_impl(service)
    return { methods = {
        compiler_cache = query(service, "profile_cache", function(r) return { cache = r.cache } end,
            function(a) return { profile = a.profile, project = a.project } end),
    } }
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
        { M.BUILD, M.build_impl },
        { M.TESTS, M.tests_impl },
        { M.LAUNCH, M.launch_impl },
        { M.TOOLCHAINS, M.toolchains_impl },
        { M.PROFILES, M.profiles_impl },
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
