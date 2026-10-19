--- loomworks/daemon/core_interfaces.lua — the core interfaces the build
--- service serves (spec §19.20 "Interface catalogue", step 5g.2):
---
---   /workspace   loomworks.Workspace/1    header (changed, header_changed)
---   /tasks       loomworks.Tasks/1        list, cancel (started, ended, step)
---   /internal    lw.internal.Snapshot/1   get (same_build)
---   /build       loomworks.Build/1        build T, configure T, clean T, reset T
---   /tests       loomworks.Tests/1        run T, discover T, run_cases T, prepare_debug T, collect,
---                                         result (results; loomworks.daemon.test_discover,
---                                         loomworks.daemon.test_runs)
---   /launch      loomworks.Launch/1       prepare_run T, prepare_debug T, build T,
---                                         device_log T (log; loomworks.daemon.devices)
---   /debug       loomworks.DebugConfig/1  adapters, set_adapter, known_languages
---   /lsp         loomworks.LspConfig/1    get, set_option (changed)
---   /toolchains  loomworks.Toolchains/1   list
---   /profiles    loomworks.Profiles/1     compiler_cache, set_device, clear_device
---   /devices     loomworks.Devices/1      list, scan T, install T, launch T, stop (changed;
---                                         loomworks.daemon.devices)
---   /views       loomworks.view.Header/1, loomworks.view.ProjectsIndex/1, loomworks.view.Tests/1
---                                         get (update; loomworks.daemon.views)
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
--- or error changed (checked after every model segment and every write, and
--- before the acknowledgement of a request answered inside its segment);
--- the views' `update` at the same point (loomworks.daemon.views.check);
--- `LspConfig.changed` at the same point when the LSP state (computed with
--- the daemon's own environment) differs from the one at its last
--- `changed`, and whenever an owned LSP database was written (`lsp_check`);
--- `Tasks.started` / `Tasks.ended` as a task starts and ends, to the
--- subscribers of `/tasks` (filtered by the subscription's `task_id`). The
--- task frames themselves reach a connection of transport 11 only for a task
--- its `/tasks` subscription matches (or that it owns), and every
--- connection below 11 as in protocol 10 (§19.15 "Observation", step 5g.3;
--- loomworks.daemon.tasks). Likewise the protocol-10 `model_change` and
--- `retiring` broadcasts reach only connections below transport 11.

local envelope = require("loomworks.proto.envelope")

local M = {}

M.WORKSPACE = { path = "/workspace", iface = "loomworks.Workspace", v = 1 }
M.TASKS = { path = "/tasks", iface = "loomworks.Tasks", v = 1 } -- (tasks.TASKS_PATH / TASKS_IFACE / TASKS_V)
M.SNAPSHOT = { path = "/internal", iface = "lw.internal.Snapshot", v = 1 }
M.BUILD = { path = "/build", iface = "loomworks.Build", v = 1 }
M.TESTS = { path = "/tests", iface = "loomworks.Tests", v = 1 }
M.LAUNCH = { path = "/launch", iface = "loomworks.Launch", v = 1 }
M.TOOLCHAINS = { path = "/toolchains", iface = "loomworks.Toolchains", v = 1 }
M.PROFILES = { path = "/profiles", iface = "loomworks.Profiles", v = 1 }
M.DEBUG = { path = "/debug", iface = "loomworks.DebugConfig", v = 1 }
M.LSP = { path = "/lsp", iface = "loomworks.LspConfig", v = 1 }

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
--- differ from the last ones seen (the first call only records them), then
--- the views' `update` where a view changed (§19.13 "Views") — after
--- applying the file changes another process made (Service:check_files).
--- @param service loomworks.daemon.BuildService
function M.header_check(service)
    -- Another process's file changes first (§19.13 "Freshness of views").
    if service.check_files then service:check_files() end
    local h = M.header(service)
    local sig = table.concat({ tostring(h.state), tostring(h.name), tostring(h.active_profile),
        tostring(h.error) }, "\n")
    local last = service._header_sig
    service._header_sig = sig
    local reg = service.server.interfaces
    if reg and last ~= nil and last ~= sig then
        reg:emit(M.WORKSPACE.path, M.WORKSPACE.iface, M.WORKSPACE.v, "header_changed", { header = h })
    end
    local ok, err = pcall(require("loomworks.daemon.views").check, service)
    if not ok and reg then reg:_log("view update failed: %s", tostring(err)) end
    ok, err = pcall(M.lsp_check, service)
    if not ok and reg then reg:_log("LspConfig changed check failed: %s", tostring(err)) end
    ok, err = pcall(require("loomworks.daemon.devices").check, service)
    if not ok and reg then reg:_log("Devices changed check failed: %s", tostring(err)) end
end

--- `LspConfig/1.get`'s state (§19.20): `env_key` names the environment it is
--- computed in (the caller's, or nil for the daemon's own). Never loads: in
--- any state but `loaded` it is that state with nothing else.
--- @param service loomworks.daemon.BuildService
--- @param env_key? string
--- @return loomworks.LspConfigState
function M.lsp_state(service, env_key)
    local lsp_config = require("loomworks.lsp_config")
    local ws, err = service:header_model()
    if not ws then
        return lsp_config.state(nil, { state = require("loomworks.view_state").base_header(nil, err).state })
    end
    return lsp_config.state(ws, { env_key = env_key,
        id_of = function(project) return service.ids:id(project) end })
end

--- Send `LspConfig.changed { seq }` when the LSP state the daemon computes
--- with its own environment differs from the one at the last `changed`, or
--- always with `force` (an owned database was written: a raised `db_rev`).
--- Built only while someone subscribes; without subscribers the baseline is
--- dropped, and the first subscription records it (`lsp_impl`'s
--- `subscribed`) without sending anything (a client reads `get` after
--- subscribing, §19.20).
--- @param service loomworks.daemon.BuildService
--- @param force? boolean
function M.lsp_check(service, force)
    local reg = service.server and service.server.interfaces
    if not reg or not reg:has_subscribers(M.LSP.path, M.LSP.iface, M.LSP.v, "changed") then
        service._lsp_sig = nil
        return
    end
    -- Inside a model segment the process has the client's environment: the
    -- check after the segment (in the daemon's own) decides, `force` kept.
    -- A subscription made inside a segment (a slow load spans event-loop
    -- turns) records no baseline, and its `get` may have read the state
    -- before the segment's change: the check after the segment then sends
    -- `changed` (a re-read), never only records.
    if service.current ~= nil then
        if force or service._lsp_sig == nil then service._lsp_force = true end
        return
    end
    force = force or service._lsp_force
    service._lsp_force = nil
    local sig = require("loomworks.lsp_config").signature(M.lsp_state(service, nil))
    local last = service._lsp_sig
    service._lsp_sig = sig
    if force or (last ~= nil and last ~= sig) then
        service._lsp_seq = (service._lsp_seq or 0) + 1
        reg:emit(M.LSP.path, M.LSP.iface, M.LSP.v, "changed", { seq = service._lsp_seq })
    end
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
        -- (With a target-scoped task's steps and their current states.)
        local rows = service.tasks:snapshot(ctx.conn, true)
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
                string.format("task %s belongs to another client", tostring(args.task_id)))
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
--- `units` (Build/1 build, configure, clean; spec §19.15 "Editor scopes and
--- configure") is a non-empty list, exclusive with `profile`: otherwise
--- `invalid_args`, before anything is resolved.
--- @param op "build"|"test"|"run"|"debug"|"target_build"|"clean"|"reset"|"configure"
--- @param where table
--- @param method string
--- @return function
local function operation(service, op, where, method)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(ctx, args)
        if args.units ~= nil then
            if #args.units == 0 then
                return nil, envelope.err(envelope.ERR.invalid_args, "/units: an empty list (name a unit or omit units)")
            end
            if args.profile ~= nil then
                return nil, envelope.err(envelope.ERR.invalid_args, "/units: not with profile (one scope)")
            end
        end
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
        configure = operation(service, "configure", M.BUILD, "configure"),
        clean = operation(service, "clean", M.BUILD, "clean"),
        reset = operation(service, "reset", M.BUILD, "reset"),
    } }
end

--- The `loomworks.Tests/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.tests_impl(service)
    local methods = {
        run = operation(service, "test", M.TESTS, "run"),
        discover = require("loomworks.daemon.test_discover").handler(service, M.TESTS),
    }
    -- The editor's runs, debug preparations and results (step 5m part B2).
    for name, fn in pairs(require("loomworks.daemon.test_runs").methods(service)) do methods[name] = fn end
    return { methods = methods }
end

--- The `loomworks.Launch/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.launch_impl(service)
    return { methods = {
        prepare_run = operation(service, "run", M.LAUNCH, "prepare_run"),
        prepare_debug = operation(service, "debug", M.LAUNCH, "prepare_debug"),
        -- The build of a launch target (§19.15 "Build of a launch target").
        build = operation(service, "target_build", M.LAUNCH, "build"),
        -- The log stream of a device launch (API.md §9.5, step 5n B3): its
        -- records are this interface's `log` signal.
        device_log = require("loomworks.daemon.devices").device_log_method(service),
    } }
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

--- A working-copy write in a model segment of the caller's environment (as
--- DebugConfig/1.set_adapter): after the tracker took in any pending file
--- change, `write(ws)` returns the result (`ok`, or `refused` when the write
--- was refused or failed — nothing written, the model unchanged).
--- @param service loomworks.daemon.BuildService
--- @param ctx table the call
--- @param kind string the segment's request kind
--- @param write fun(ws: table): table
--- @return any interfaces.ASYNC
local function write_segment(service, ctx, kind, write)
    service:_on_model_request(ctx.conn, { kind = kind, env = ctx.env }, function(ws)
        -- A change another process wrote is taken in first: the write then
        -- never refuses as stale for it (§2.7).
        local tr = ws._tracker
        if tr and tr.sync then tr:sync() end
        if service.host.current() ~= ws then
            return { outcome = "refused", exit_code = 1,
                message = "the workspace was reloaded (refused or changed .nvim files); try again" }
        end
        return write(ws)
    end, nil, function(fields) ctx.reply(fields) end)
    return require("loomworks.daemon.interfaces").ASYNC
end

--- The profile a `Profiles/1` write names (`{ id }` or `{ key }`), or nil +
--- the refusal.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param ref table
--- @return table|nil profile, string|nil err
local function profile_of(service, ws, ref)
    if ref.id ~= nil then
        local p = service.ids:find(ref.id, ws._profiles)
        if not p then return nil, "no profile with id " .. tostring(ref.id) .. " (a stale reference)" end
        return p
    end
    for _, p in pairs(ws._profiles or {}) do
        if not p._removed and p.key == ref.key then return p end
    end
    return nil, "no profile '" .. tostring(ref.key) .. "'"
end

--- The `loomworks.Profiles/1` handlers. `set_device` / `clear_device`
--- (API.md §11) write the profile's device to the working copy as the
--- in-process Profile:set_device / clear_device do; `set_device`'s device
--- is one of the registry's (Devices/1.list), by id or serial. The write's
--- `model_change` (Workspace/1 `changed`) precedes the reply.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.profiles_impl(service)
    local methods = {
        compiler_cache = query(service, "profile_cache", function(r) return { cache = r.cache } end,
            function(a) return { profile = a.profile, project = a.project } end),
    }
    local function refused(msg) return { outcome = "refused", message = tostring(msg), exit_code = 1 } end
    function methods.set_device(ctx, args)
        return write_segment(service, ctx, "profile_device", function(ws)
            local profile, perr = profile_of(service, ws, args.profile)
            if not profile then return refused(perr) end
            local d = args.device
            local device = d.id ~= nil and service.ids:find(d.id, ws._devices) or (d.key ~= nil and ws:find_device(d.key))
            if not device then
                return refused(d.id ~= nil and ("no device with id " .. tostring(d.id) .. " (a stale reference)")
                    or ("no device '" .. tostring(d.key) .. "' — scan for devices first (Devices/1.scan)"))
            end
            local ok, err = profile:set_device(device.serial)
            if not ok then return refused(err or "user.json was not written") end
            return { outcome = "ok" }
        end)
    end
    function methods.clear_device(ctx, args)
        return write_segment(service, ctx, "profile_device", function(ws)
            local profile, perr = profile_of(service, ws, args.profile)
            if not profile then return refused(perr) end
            local ok, err = profile:clear_device()
            if not ok then return refused(err or "user.json was not written") end
            return { outcome = "ok" }
        end)
    end
    return { methods = methods }
end

--- The `loomworks.DebugConfig/1` handlers (§19.20 `DebugConfig/1`): the
--- workspace's debug-adapter mapping, read in a model segment of the
--- requesting client's environment as a query is (loaded as for `snapshot`
--- when none is). `set_adapter` is a command: in its model segment, after
--- the tracker took in any pending file change, the working copy is written
--- as the in-process Workspace:set_debug_adapter writes it; the committed
--- write's `model_change` (and `Workspace.changed`) precedes the reply. A
--- write that is refused or fails changes neither user.json nor the model:
--- the refused result.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.debug_impl(service)
    local interfaces = require("loomworks.daemon.interfaces")
    local debug_config = require("loomworks.debug_config")
    local function segment(ctx, answer)
        service:_on_model_request(ctx.conn, { kind = "debug_config", env = ctx.env }, answer, nil,
            function(fields) ctx.reply(fields) end)
        return interfaces.ASYNC
    end
    local methods = {}
    function methods.adapters(ctx)
        return segment(ctx, function(ws) return { languages = debug_config.adapter_records(ws) } end)
    end
    function methods.known_languages(ctx)
        return segment(ctx, function(ws) return { languages = debug_config.workspace_languages(ws) } end)
    end
    function methods.set_adapter(ctx, args)
        return segment(ctx, function(ws)
            -- A change another process wrote is taken in first: the write
            -- then never refuses as stale for it (§2.7).
            local tr = ws._tracker
            if tr and tr.sync then tr:sync() end
            if service.host.current() ~= ws then
                return { outcome = "refused", exit_code = 1,
                    message = "the workspace was reloaded (refused or changed .nvim files); try again" }
            end
            local ok, err = ws:set_debug_adapter(args.language, args.adapter)
            if not ok then
                return { outcome = "refused", message = tostring(err or "user.json was not written"), exit_code = 1 }
            end
            return { outcome = "ok" }
        end)
    end
    return { methods = methods }
end

--- The `loomworks.LspConfig/1` handlers (§19.20 `LspConfig/1`). `get` is
--- answered in a model segment of the caller's environment (an entry's server
--- binary resolves in it, §19.15 "Environment") against the loaded model,
--- never loading one: in any other state it answers that state at once.
--- `set_option` is a command like DebugConfig/1.set_adapter: in its model
--- segment (loaded as for a query when none is), after the tracker took in
--- any pending file change, the working copy is written as the in-process
--- Workspace:set_lsp_option writes it; the committed write's `model_change`
--- (and `Workspace.changed`, then this interface's `changed`) precedes the
--- reply. A refused or failed write (a stale or untrusted working copy, a
--- refused load) changes neither user.json nor the model: the refused result.
--- An unknown server or key or a mistyped value is `invalid_args`, before
--- anything runs.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.lsp_impl(service)
    local interfaces = require("loomworks.daemon.interfaces")
    local envscope = require("loomworks.daemon.envscope")
    local methods = {}
    function methods.get(ctx)
        if not service:header_model() then return M.lsp_state(service) end
        if service.stopping or service.server.stopped then
            return { outcome = "declined", reason = "the workspace runtime is stopping" }
        end
        local env_key = envscope.signature(ctx.env)
        local seg = { op = "lsp_config", conn = ctx.conn, env = ctx.env, args = {} }
        function seg.reply(fields)
            seg.replied = true
            service:_before_ack(seg)
            ctx.reply(fields)
        end
        service:with_model(seg, function()
            if ctx.conn.closed then return end
            seg.reply(M.lsp_state(service, env_key))
        end)
        return interfaces.ASYNC
    end
    function methods.set_option(ctx, args)
        local value = args.value
        if value == vim.NIL then value = nil end
        -- An unknown server or key, or a mistyped value, is an invalid call
        -- (§19.20): refused before any segment, nothing loaded or written.
        local problem = require("loomworks.workspace").lsp_option_problem(args.server, args.key, value)
        if problem then
            return nil, envelope.err(envelope.ERR.invalid_args, "set_option: " .. problem)
        end
        service:_on_model_request(ctx.conn, { kind = "lsp_config", env = ctx.env }, function(ws)
            -- A change another process wrote is taken in first: the write
            -- then never refuses as stale for it (§2.7).
            local tr = ws._tracker
            if tr and tr.sync then tr:sync() end
            if service.host.current() ~= ws then
                return { outcome = "refused", exit_code = 1,
                    message = "the workspace was reloaded (refused or changed .nvim files); try again" }
            end
            local ok, err = ws:set_lsp_option(args.server, args.key, value)
            if not ok then
                return { outcome = "refused", message = tostring(err or "user.json was not written"), exit_code = 1 }
            end
            -- (As the editor's handler of `lsp_options_changed`: every memoized
            -- entry is recomputed.)
            require("loomworks.lsp_config").bump_generation()
            return { outcome = "ok" }
        end, nil, function(fields) ctx.reply(fields) end)
        return interfaces.ASYNC
    end
    -- The first subscriber records the baseline `changed` compares with, so
    -- a change right after subscribing (a load, a write) is signalled.
    local function subscribed()
        if service._lsp_sig == nil then M.lsp_check(service) end
    end
    return { methods = methods, subscribed = subscribed }
end

--- Mount the core interfaces of `service` on `registry`. A refused mount (a
--- missing or invalid document) is logged; the others still mount.
--- @param registry loomworks.daemon.Registry
--- @param service loomworks.daemon.BuildService
function M.mount(registry, service)
    local mounts = {
        { M.WORKSPACE, M.workspace_impl },
        { M.TASKS, M.tasks_impl },
        { M.SNAPSHOT, M.snapshot_impl },
        { M.BUILD, M.build_impl },
        { M.TESTS, M.tests_impl },
        { M.LAUNCH, M.launch_impl },
        { M.TOOLCHAINS, M.toolchains_impl },
        { M.PROFILES, M.profiles_impl },
        { M.DEBUG, M.debug_impl },
        { M.LSP, M.lsp_impl },
        { require("loomworks.daemon.devices").WHERE, require("loomworks.daemon.devices").impl },
    }
    vim.list_extend(mounts, require("loomworks.daemon.views").MOUNTS)
    for _, m in ipairs(mounts) do
        local where, make = m[1], m[2]
        local ok, err = registry:mount(where.path, "core", where.iface, where.v, make(service))
        if not ok then registry:_log("interface %s/%d not mounted: %s", where.iface, where.v, tostring(err)) end
    end
end

--- The `Tasks.started` / `Tasks.ended` / `Tasks.step` signals of a task (the
--- stream's hooks); `args` may be a function of the frame's `seq` (Registry:emit).
--- @param registry loomworks.daemon.Registry
--- @param task loomworks.daemon.Task
--- @param name "started"|"ended"|"step"
--- @param args table|fun(sub: table, seq: integer): table
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
