--- loomworks/daemon/core_interfaces.lua — the core interfaces the build
--- service serves (spec §19.20 "Interface catalogue", step 5g.2):
---
---   /workspace   loomworks.Workspace/1    header, publish, publish_one, revert_one, revert_to_baseline,
---                                         set_intent, set_description, trust_accept, delete_user_prefs
---                                         (changed, header_changed)
---   /tasks       loomworks.Tasks/1        list, cancel (started, ended, step)
---   /internal    lw.internal.Snapshot/1   get (same_build)
---   /build       loomworks.Build/1        build T, configure T, clean T, reset T
---   /tests       loomworks.Tests/1        run T, discover T, run_cases T, prepare_debug T, collect,
---                                         result (results; loomworks.daemon.test_discover,
---                                         loomworks.daemon.test_runs)
---   /launch      loomworks.Launch/1       prepare_run T, prepare_debug T, build T, targets,
---                                         device_log T (log; loomworks.daemon.devices)
---   /debug       loomworks.DebugConfig/1  adapters, set_adapter, known_languages
---   /lsp         loomworks.LspConfig/1    get, set_option (changed)
---   /toolchains  loomworks.Toolchains/1   list, rescan
---   /toolchains  loomworks.Sdks/1         detect, add, remove
---   /profiles    loomworks.Profiles/1     compiler_cache, set_device, clear_device, set_active, create,
---                                         tool_choices, add_tool, remove_tool, set_default_target
---   /projects    loomworks.Projects/1     candidates, add, declaration, configuration_save,
---                                         configuration_remove, options_save, launch_save, launch_remove,
---                                         deploy_save, variable_save, variable_remove, type_config_set,
---                                         expand_preview, unit_options
---   /projects    loomworks.ConfigSets/1   candidates, add, update, remove, generate_defaults
---   /maintenance loomworks.Maintenance/1 execute_deletion T, nuke T (loomworks.daemon.maintenance)
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
M.SDKS = { path = "/toolchains", iface = "loomworks.Sdks", v = 1 }
M.PROFILES = { path = "/profiles", iface = "loomworks.Profiles", v = 1 }
M.DEBUG = { path = "/debug", iface = "loomworks.DebugConfig", v = 1 }
M.LSP = { path = "/lsp", iface = "loomworks.LspConfig", v = 1 }
M.PROJECTS = { path = "/projects", iface = "loomworks.Projects", v = 1 }
M.CONFIG_SETS = { path = "/projects", iface = "loomworks.ConfigSets", v = 1 }

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

--- The item an `ItemRef` (API.md §1.2) names: a profile, configuration set,
--- project, configuration or launch configuration of `ws`, by its id alone
--- (ids are unique across kinds), or nil + the stale-reference refusal.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param ref { id: string }
--- @return table|nil item, string|nil err
local function item_of(service, ws, ref)
    local candidates = {}
    local function add(list)
        for _, o in pairs(list or {}) do candidates[#candidates + 1] = o end
    end
    add(ws._profiles)
    add(ws._config_sets)
    add(ws._projects)
    for _, p in pairs(ws._projects or {}) do
        if not p._removed then
            add(p._configurations)
            add(p._launches)
        end
    end
    local item = service.ids:find(ref.id, candidates)
    if not item then return nil, "no item with id " .. tostring(ref.id) .. " (a stale reference)" end
    return item
end

--- The entity fields a command's result may carry (`{ id, key }` each, made
--- by the handler from the created or kept object).
local ENTITY_FIELDS = { "project", "configuration", "launch", "profile", "config_set", "sdk" }

--- The reply of a command outcome: only the protocol's fields; a refused
--- write reports the lock or save refusal the host recorded (it names
--- the holder), without repeating it as a note.
local function reply_of(r, seg)
    local out = { outcome = r.outcome, message = r.message, exit_code = r.exit_code,
        lines = r.lines, plan = r.plan, notes = r.notes, note_roles = r.note_roles }
    if r.outcome == "ok" then
        for _, f in ipairs(ENTITY_FIELDS) do out[f] = r[f] end
    end
    if r.outcome == "refused" and seg and seg.refused then
        out.message = seg.refused
        local notes, roles = {}, {}
        for i, n in ipairs(seg.notes or {}) do
            if not n:find(seg.refused, 1, true) then
                notes[#notes + 1] = n
                roles[#roles + 1] = (seg.note_roles or {})[i]
            end
        end
        seg.notes = #notes > 0 and notes or nil
        seg.note_roles = #roles > 0 and roles or nil
    end
    return out
end

--- A command on the loaded model, in a model segment of the caller's
--- environment (request kind `workspace_command`): `fn(ws)` → a
--- model_commands outcome, after the tracker took in any pending change.
local function command(service, ctx, fn)
    service:_on_model_request(ctx.conn, { kind = "workspace_command", env = ctx.env }, function(ws, seg)
        -- A change another process wrote is taken in first: the write
        -- then never refuses as stale for it (§2.7).
        local tr = ws._tracker
        if tr and tr.sync then tr:sync() end
        if service.host.current() ~= ws then
            return { outcome = "refused", exit_code = 1,
                message = "the workspace was reloaded (refused or changed .nvim files); try again" }
        end
        local out = reply_of(fn(ws), seg)
        -- The outcome's own notes follow the segment's (the request
        -- replies with the segment's list).
        for i, n in ipairs(out.notes or {}) do
            seg.notes, seg.note_roles = seg.notes or {}, seg.note_roles or {}
            seg.notes[#seg.notes + 1] = n
            seg.note_roles[#seg.notes] = (out.note_roles or {})[i] or "plain"
        end
        out.notes, out.note_roles = nil, nil
        return out
    end, nil, function(fields) ctx.reply(fields) end)
    return require("loomworks.daemon.interfaces").ASYNC
end

--- The `loomworks.Workspace/1` handlers (API.md §6). The commands run in a
--- model segment of the caller's environment (as `write_segment`): ids
--- resolve to the live objects once, here, and the write is the shared
--- loomworks.model_commands function the in-process editor calls. A publish
--- takes the workspace operation lock O (Workspace:publish / publish_one are
--- guarded, spec §19.3); a refusal of a lock or a save names its cause (the
--- holder). `trust_accept` / `delete_user_prefs` act on the core's working
--- copy, also while the load is refused, and the daemon then serves the
--- load they started.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.workspace_impl(service)
    local interfaces = require("loomworks.daemon.interfaces")
    local envscope = require("loomworks.daemon.envscope")
    local mc = require("loomworks.model_commands")
    local methods = {}
    function methods.header() return M.header(service) end

    --- A command naming one item.
    local function item_command(ctx, args, fn)
        return command(service, ctx, function(ws)
            local item, err = item_of(service, ws, args.item)
            if not item then return mc.refused(err) end
            return fn(item)
        end)
    end

    function methods.publish(ctx) return command(service, ctx, mc.publish) end
    function methods.revert_to_baseline(ctx) return command(service, ctx, mc.revert_to_baseline) end
    function methods.publish_one(ctx, args) return item_command(ctx, args, mc.publish_one) end
    function methods.revert_one(ctx, args) return item_command(ctx, args, mc.revert_one) end
    function methods.set_intent(ctx, args)
        return item_command(ctx, args, function(item) return mc.set_intent(item, args.intent) end)
    end
    function methods.set_description(ctx, args)
        local text = args.text
        if text == vim.NIL then text = nil end
        return item_command(ctx, args, function(item) return mc.set_description(item, text) end)
    end

    --- A command on the working copy itself (served while the load is
    --- refused): the load is tried first, so the core is this daemon's
    --- (its handlers installed) whatever the outcome; `act(core, root)` then
    --- runs, and a load it started is adopted.
    local function prefs_command(ctx, act)
        if service.stopping or service.server.stopped then
            return { outcome = "declined", reason = "the workspace runtime is stopping" }
        end
        local env, eerr = envscope.validate(ctx.env)
        if not env then return { outcome = "declined", reason = eerr } end
        local seg = { op = "workspace_prefs", conn = ctx.conn, env = env, args = {} }
        function seg.reply(fields)
            seg.replied = true
            service:_before_ack(seg)
            ctx.reply(fields)
        end
        service:with_model(seg, function()
            if ctx.conn.closed then return end
            local _, _, decline = service:live(seg)
            if decline then return seg.reply({ outcome = "declined", reason = decline }) end
            local r = act(service.host.core(), service.server.root)
            if r.reloaded then service:_adopt_reload(seg) end
            local out = reply_of(r)
            -- What the core reported meanwhile (a lock refusal, a failed
            -- deletion) precedes the outcome's own notes.
            if seg.notes then
                local notes, roles = vim.list_extend({}, seg.notes), vim.list_extend({}, seg.note_roles or {})
                for i, n in ipairs(out.notes or {}) do
                    notes[#notes + 1] = n
                    roles[#notes] = (out.note_roles or {})[i] or "plain"
                end
                out.notes, out.note_roles = notes, roles
            end
            seg.reply(out)
        end)
        return interfaces.ASYNC
    end

    function methods.trust_accept(ctx, args)
        return prefs_command(ctx, function(core, root) return mc.trust_accept(core, root, args.plan) end)
    end
    function methods.delete_user_prefs(ctx, args)
        return prefs_command(ctx, function(core, root) return mc.delete_user_prefs(core, root, args.plan) end)
    end
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

--- `Launch/1.targets` (API.md §9.6), defined below with the reference
--- resolvers it uses.
local launch_targets

--- The `loomworks.Launch/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.launch_impl(service)
    return { methods = {
        -- The profile's launchable targets (step 6b-α): a read.
        targets = function(ctx, args) return launch_targets(service, ctx, args) end,
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
--- segment with `query_args(args, refs)` (`refs` the objects the args' ids
--- resolved to, `Service:_resolve_ids`), its result mapped to the method's by
--- `map`; a stale reference is the refused result.
--- @param service loomworks.daemon.BuildService
--- @param name string
--- @param map fun(result: table): table
--- @param query_args? fun(a: table, refs: table): table
--- @return function
local function query(service, name, map, query_args)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(ctx, args)
        service:_on_model_request(ctx.conn, { kind = "query", env = ctx.env }, function(ws)
            local qa = M.operation_args(args)
            local refs, stale = service:_resolve_ids(ws, qa)
            if not refs then return { outcome = "refused", message = stale, exit_code = 1 } end
            local f = service:_query(ctx.conn, ws, name, query_args and query_args(qa, refs) or {})
            if f.outcome then return f end
            return map(f.result)
        end, nil, function(fields) ctx.reply(fields) end)
        return interfaces.ASYNC
    end
end

--- A read in a model segment of the caller's environment: `fn(ws)` → a
--- model_commands outcome (its fields the result; a refusal the refused
--- result). Nothing is written.
--- @param service loomworks.daemon.BuildService
--- @param ctx table the call
--- @param fn fun(ws: table): table
--- @return any interfaces.ASYNC
local function read_segment(service, ctx, fn)
    service:_on_model_request(ctx.conn, { kind = "query", env = ctx.env }, function(ws)
        local r = fn(ws)
        if r.outcome ~= "ok" then
            return { outcome = "refused", message = r.message, exit_code = r.exit_code or 1 }
        end
        return r
    end, nil, function(fields) ctx.reply(fields) end)
    return require("loomworks.daemon.interfaces").ASYNC
end

--- The refusal while a toolchain detection is running (the in-process path's
--- `_tool_state == "scanning"`), else nil. It never waits: the request runs in
--- the serial model queue, and a wait there would stall every other model
--- request past the clients' timeout. The refusal is transient (exit code 1);
--- the caller tries again.
--- @param ws table
--- @return table|nil refusal
local function settled_tools(ws)
    if ws._tool_state ~= "scanning" then return nil end
    return require("loomworks.model_commands").refused("toolchains are still being detected")
end

--- The toolchains before a write that detects them again
--- (model_commands.tools_rescan, sdk_add, sdk_remove): the `changed`
--- sequence number and the toolchain rows. Taken before the write, so the
--- write's own `changed` (a saved working copy) is the only one when the
--- detection then changes nothing more.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @return { seq: integer, rows: table }
local function tools_before(service, ws)
    return { seq = service.server.seq,
        rows = require("loomworks.daemon.snapshot").tool_rows(ws._tools_by_type) }
end

--- Wait, as a load waits for its detection (service.LOAD_WAIT_MS), until the
--- model took in the detection a write started. A changed toolchain list
--- signals Workspace/1 `changed` (before the reply), unless a write since
--- `before` already did. A detection that does not finish in time goes on in
--- the background: the daemon signals `changed` when it finishes
--- (Service:tools_late), outside the requester's environment scope.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param before { seq: integer, rows: table } tools_before
--- @return boolean finished false: the detection did not finish in time
local function await_tools(service, ws, before)
    local snapshot = require("loomworks.daemon.snapshot")
    vim.wait(require("loomworks.daemon.service").LOAD_WAIT_MS, function()
        return ws._tool_state == "scanned" or ws._torn_down == true
    end, 25)
    if ws._torn_down then return false end
    if ws._tool_state ~= "scanned" then
        service:tools_late(ws, before.rows)
        return false
    end
    if service.server.seq == before.seq and not vim.deep_equal(before.rows, snapshot.tool_rows(ws._tools_by_type)) then
        service.server:model_changed()
    end
    return true
end

--- The warn note of a write whose detection did not finish within the wait
--- (the reply stays `ok`: the write is done, API.md §11).
local RESCAN_UNFINISHED = "toolchain detection did not finish in time; it goes on in the background"

--- The `loomworks.Toolchains/1` handlers. `rescan` (API.md §11, step 5o
--- part B4) is a command: in a model segment of the caller's environment it
--- detects the toolchains again, as the status page's `L` does in-process,
--- every module type afresh (no machine-level cached result reused,
--- spec §16.43), and replies once the model took them in, or `ok` with a
--- warn note when that did not happen within the wait.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.toolchains_impl(service)
    return { methods = {
        list = query(service, "tools", function(r) return { tools = r.tools or {} } end),
        rescan = function(ctx)
            return command(service, ctx, function(ws)
                local before = tools_before(service, ws)
                require("loomworks.model_commands").tools_rescan(ws)
                if not await_tools(service, ws, before) then
                    return { outcome = "ok", notes = { RESCAN_UNFINISHED }, note_roles = { "warn" } }
                end
                return { outcome = "ok" }
            end)
        end,
    } }
end

--- The SDK a `Sdks/1` call names (`{ id }`, or `{ key }` matched exactly),
--- or nil + the refusal.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param ref table
--- @return loomworks.SDK|nil, string|nil err
local function sdk_of(service, ws, ref)
    if ref.id ~= nil then
        local sdk = service.ids:find(ref.id, ws._sdks)
        if not sdk then return nil, "no SDK with id " .. tostring(ref.id) .. " (a stale reference)" end
        return sdk
    end
    for _, sdk in ipairs(ws._sdks or {}) do
        if not sdk._removed and sdk.key == ref.key then return sdk end
    end
    return nil, "no SDK '" .. tostring(ref.key) .. "'"
end

--- The `loomworks.Sdks/1` handlers (API.md §21, step 5o part B4). `detect`
--- is a read in a model segment of the caller's environment (the providers'
--- detection probes it); `add` and `remove` are commands as Workspace/1's
--- (`command`), the write the shared loomworks.model_commands function the
--- in-process editor calls, which also starts detecting the toolchains
--- again; the daemon waits for that detection (as Toolchains/1.rescan) before
--- it replies, so the SDK's kits are offered (or gone). `list` is deferred
--- (step 5o D9: view.Workspace/1 carries the SDKs).
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.sdks_impl(service)
    local mc = require("loomworks.model_commands")
    local methods = {}

    function methods.detect(ctx, args)
        return read_segment(service, ctx, function() return mc.sdk_detect(args.provider) end)
    end

    function methods.add(ctx, args)
        return command(service, ctx, function(ws)
            -- The daemon's cwd is not the caller's: a relative path would
            -- resolve against the wrong directory (API.md §21). An unknown
            -- provider is refused first (by sdk_add).
            if type(args.path) == "string" and require("loomworks.sdks").get(args.provider)
                and not require("loomworks.exe").is_absolute(args.path) then
                return mc.refused("SDK path '" .. args.path .. "' is not absolute")
            end
            local before = tools_before(service, ws)
            local r = mc.sdk_add(ws, args.provider, args.path)
            if r.outcome ~= "ok" then return r end
            local sdk = r.sdk
            r.sdk = { id = service.ids:id(sdk), key = sdk.key }
            if not await_tools(service, ws, before) then
                r.notes, r.note_roles = { "SDK '" .. sdk.key .. "' added; " .. RESCAN_UNFINISHED }, { "warn" }
            end
            return r
        end)
    end

    function methods.remove(ctx, args)
        return command(service, ctx, function(ws)
            local sdk, err = sdk_of(service, ws, args.sdk)
            if not sdk then return mc.refused(err) end
            local before = tools_before(service, ws)
            local key = sdk.key
            local r = mc.sdk_remove(ws, sdk)
            if r.outcome == "ok" and not await_tools(service, ws, before) then
                r.notes, r.note_roles = { "SDK '" .. key .. "' removed; " .. RESCAN_UNFINISHED }, { "warn" }
            end
            return r
        end)
    end
    return { methods = methods }
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

--- The project a call names (defined with the Projects/1 handlers below;
--- Profiles/1.set_default_target resolves its target's project with it).
local project_of

--- The configuration set a call names (`{ id }` or `{ key }`, its name),
--- or nil + the refusal.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param ref table
--- @return loomworks.ConfigurationSet|nil, string|nil err
local function config_set_of(service, ws, ref)
    if ref.id ~= nil then
        local cs = service.ids:find(ref.id, ws._config_sets)
        if not cs then return nil, "no configuration set with id " .. tostring(ref.id) .. " (a stale reference)" end
        return cs
    end
    for _, cs in pairs(ws._config_sets or {}) do
        if not cs._removed and cs.name == ref.key then return cs end
    end
    return nil, "no configuration set '" .. tostring(ref.key) .. "'"
end

--- The set `Profiles/1.create` / `tool_choices` name: a reference, or
--- `{ candidate }` (an automatic set's token from ConfigSets/1.candidates,
--- passed on as it is); or nil + the refusal.
local function set_or_candidate(service, ws, ref)
    if ref.candidate ~= nil then return { candidate = ref.candidate } end
    return config_set_of(service, ws, ref)
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
            function(a, refs)
                return { profile = refs.profile or a.profile, project = refs.project or a.project }
            end),
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

    -- Step 5o part B2 (API.md §11): the commands run as Workspace/1's do
    -- (`command`), the references resolved to the live objects once, here;
    -- the write is the shared loomworks.model_commands function the
    -- in-process editor calls. A toolchain change re-derives the profile's
    -- key under the workspace operation lock (model_commands).
    local mc = require("loomworks.model_commands")

    --- A command on the profile `args.profile` names.
    local function on_profile(ctx, args, fn)
        return command(service, ctx, function(ws)
            local profile, err = profile_of(service, ws, args.profile)
            if not profile then return mc.refused(err) end
            return fn(profile, ws)
        end)
    end

    --- The wire form of a toolchain entry: a module's `{ module, key?,
    --- label }`, an SDK's `{ sdk = true, key, label }` (API.md §11).
    local function tool_wire(e)
        if e.sdk then return { sdk = true, key = e.sdk.key, label = e.tool_label or e.sdk.key } end
        return { module = e.tool_mod_type, key = e.tool_key, label = e.tool_label or e.tool_key }
    end

    --- The entry among `choices` (tool_choices') that the wire `tool` names
    --- — `{ module, key? }` or `{ sdk = <key> }`, matched exactly — or nil +
    --- the refusal.
    local function tool_entry_of(choices, tool)
        if tool.sdk ~= nil then
            for _, e in ipairs(choices) do
                if e.sdk and e.sdk.key == tool.sdk then return e end
            end
            return nil, "no SDK toolchain '" .. tostring(tool.sdk)
                .. "' for this configuration set (see Profiles/1.tool_choices)"
        end
        local key = tool.key ~= vim.NIL and tool.key or nil
        for _, e in ipairs(choices) do
            if not e.sdk and e.tool_mod_type == tool.module and e.tool_key == key then return e end
        end
        return nil, "no " .. tostring(tool.module) .. " toolchain '" .. tostring(key)
            .. "' for this configuration set (see Profiles/1.tool_choices)"
    end

    function methods.set_active(ctx, args)
        return on_profile(ctx, args, function(profile) return mc.profile_set_active(profile) end)
    end

    -- Step 6b-α (API.md §11): the profile's default launch target, `target`
    -- `{ kind, project, name }` (`project` a reference, resolved here) one of
    -- Launch/1.targets' records; no `target` removes the stored choice.
    function methods.set_default_target(ctx, args)
        return on_profile(ctx, args, function(profile, ws)
            local t = args.target
            if t == nil or t == vim.NIL then
                return mc.profile_set_default_target(ws, profile, nil)
            end
            local project, perr = project_of(service, ws, t.project)
            if not project then return mc.refused(perr) end
            return mc.profile_set_default_target(ws, profile, { kind = t.kind, project = project, name = t.name },
                { refresh = true })
        end)
    end

    function methods.tool_choices(ctx, args)
        return read_segment(service, ctx, function(ws)
            local set, err = set_or_candidate(service, ws, args.config_set)
            if not set then return mc.refused(err) end
            local wait = settled_tools(ws)
            if wait then return wait end
            local r = mc.profile_tool_choices(ws, set)
            if r.outcome ~= "ok" then return r end
            local tools = {}
            for _, e in ipairs(r.tools) do tools[#tools + 1] = tool_wire(e) end
            return { outcome = "ok", tools = tools }
        end)
    end

    function methods.create(ctx, args)
        return command(service, ctx, function(ws)
            local set, err = set_or_candidate(service, ws, args.config_set)
            if not set then return mc.refused(err) end
            local wait = settled_tools(ws)
            if wait then return wait end
            local entry
            if args.tool ~= nil then
                -- One of tool_choices' toolchains (a value: module + key,
                -- or an SDK's key), resolved to its entry here, once.
                local choices = mc.profile_tool_choices(ws, set)
                if choices.outcome ~= "ok" then return choices end
                local terr
                entry, terr = tool_entry_of(choices.tools, args.tool)
                if not entry then return mc.refused(terr) end
            end
            local r = mc.profile_create(ws, set, entry, args.activate == true)
            if r.outcome == "ok" then
                r.profile = r.profile and { id = service.ids:id(r.profile), key = r.profile.key } or nil
                -- The automatic set a candidate added is a created entity:
                -- returned as { id, key } (API.md §4.1), also when the
                -- profile could not be saved (the warn result).
                local cs = set.candidate ~= nil and r.config_set or nil
                r.config_set = cs and { id = service.ids:id(cs), key = cs.name } or nil
            end
            return r
        end)
    end

    function methods.add_tool(ctx, args)
        return on_profile(ctx, args, function(profile) return mc.profile_add_tool(profile, args.tool) end)
    end

    function methods.remove_tool(ctx, args)
        return on_profile(ctx, args, function(profile) return mc.profile_remove_tool(profile, args.tool) end)
    end
    return { methods = methods }
end

--- The project a `Projects/1` call names (`{ id }` or `{ key }`), or nil +
--- the refusal.
--- @param service loomworks.daemon.BuildService
--- @param ws table
--- @param ref table
--- @return table|nil project, string|nil err
project_of = function(service, ws, ref)
    if ref.id ~= nil then
        local p = service.ids:find(ref.id, ws._projects)
        if not p then return nil, "no project with id " .. tostring(ref.id) .. " (a stale reference)" end
        return p
    end
    for _, p in pairs(ws._projects or {}) do
        if not p._removed and p.key == ref.key then return p end
    end
    return nil, "no project '" .. tostring(ref.key) .. "'"
end

--- `Launch/1.targets { profile }` (API.md §9.6): the profile's launchable
--- targets, in a model segment of the caller's environment, each record's
--- project as `{ id, key }`; the units' targets re-read first (a build since
--- they were parsed). Nothing is written.
--- @param service loomworks.daemon.BuildService
--- @param ctx table the call
--- @param args table
--- @return any interfaces.ASYNC
launch_targets = function(service, ctx, args)
    local mc = require("loomworks.model_commands")
    return read_segment(service, ctx, function(ws)
        local profile, err = profile_of(service, ws, args.profile)
        if not profile then return mc.refused(err) end
        local r = mc.launch_targets(ws, profile, { refresh = true })
        if r.outcome ~= "ok" then return r end
        for _, t in ipairs(r.targets) do
            t.project = { id = service.ids:id(t.project), key = t.project.key }
        end
        return r
    end)
end

--- Every live project's objects of one kind (`field`: `_configurations` or
--- `_launches`), for resolving an id among all of them.
local function owned_objects(ws, field)
    local out = {}
    for _, p in pairs(ws._projects or {}) do
        if not p._removed then
            for _, o in pairs(p[field] or {}) do out[#out + 1] = o end
        end
    end
    return out
end

--- The configuration of `project` a call names: its id (refused when it is
--- another project's), or `{ key }` its name in `project`; or nil + the
--- refusal.
--- @param service loomworks.daemon.BuildService
--- @param project loomworks.Project
--- @param ref table
--- @return loomworks.Configuration|nil, string|nil err
local function configuration_of(service, project, ref)
    if ref.id ~= nil then
        local c = service.ids:find(ref.id, owned_objects(project._workspace, "_configurations"))
        if not c then return nil, "no configuration with id " .. tostring(ref.id) .. " (a stale reference)" end
        if c._project ~= project then
            return nil, "configuration '" .. c.name .. "' is not of project '" .. project.key .. "'"
        end
        return c
    end
    local c = project:get_configuration(ref.key)
    if not c or c._removed then
        return nil, "no configuration '" .. tostring(ref.key) .. "' in project '" .. project.key .. "'"
    end
    return c
end

--- The launch configuration of `project` a call names (API.md §1.2): its id
--- (refused when it is another project's), or `{ key }` its name in
--- `project`; or nil + the refusal.
--- @param service loomworks.daemon.BuildService
--- @param project loomworks.Project
--- @param ref table
--- @return loomworks.LaunchConfiguration|nil, string|nil err
local function launch_of(service, project, ref)
    if ref.id ~= nil then
        local l = service.ids:find(ref.id, owned_objects(project._workspace, "_launches"))
        if not l then return nil, "no launch configuration with id " .. tostring(ref.id) .. " (a stale reference)" end
        if l._project ~= project then
            return nil, "launch configuration '" .. l._project.key .. ":" .. l.name .. "' is not of project '"
                .. project.key .. "'"
        end
        return l
    end
    local l = project:find_launch(ref.key)
    if not l or l:is_removed() then
        return nil, "no launch config '" .. tostring(ref.key) .. "' on project '" .. project.key .. "'"
    end
    return l
end

--- A wire value with JSON nulls (vim.NIL) dropped, recursively.
local function plain(v)
    if v == vim.NIL then return nil end
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do
        if x ~= vim.NIL then out[k] = plain(x) end
    end
    return out
end

--- The `loomworks.Projects/1` handlers (API.md §19). The commands run as
--- Workspace/1's do (`command`): references resolve to the live objects once,
--- here (a project, configuration or launch configuration by id or by key,
--- a variable, deploy declaration or `type_config` field by its project and
--- name), and the write is the shared loomworks.model_commands function the
--- in-process editor calls. A configuration rename propagates under the
--- workspace operation lock O (Project:rename_configuration is guarded, spec
--- §19.3), as does `add`'s profile upgrade (Workspace:upgrade_profiles_for_tool);
--- a launch rename writes only the working copy and takes no O. The reads
--- (`candidates`, `declaration`, `expand_preview`, `unit_options`) run in a model segment of
--- the caller's environment and change nothing.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.projects_impl(service)
    local mc = require("loomworks.model_commands")
    local methods = {}

    --- `{ id, key }` of a created or kept object.
    local function entity(obj, key)
        if obj == nil then return nil end
        return { id = service.ids:id(obj), key = key }
    end

    --- A read: `fn(ws)` → a model_commands outcome (its fields the result).
    local function read(ctx, fn) return read_segment(service, ctx, fn) end

    --- A command or read on the project `args.project` names: `fn(project,
    --- ws)` → a model_commands outcome.
    local function on_project(run, ctx, args, fn)
        return run(service, ctx, function(ws)
            local project, err = project_of(service, ws, args.project)
            if not project then return mc.refused(err) end
            return fn(project, ws)
        end)
    end
    local function cmd(ctx, args, fn) return on_project(command, ctx, args, fn) end
    local function rd(ctx, args, fn) return on_project(function(_, c, f) return read(c, f) end, ctx, args, fn) end

    --- `go(detected)` once the keyed toolchains a request needs are known.
    --- A read segment of the caller's environment asks `needs(ws)` for the
    --- keyed module type whose toolchains the workspace has not detected
    --- (model_commands.keyed_tools_needed); they are then detected without
    --- blocking (model_commands.detect_keyed_tools_async: started in that
    --- segment, its probes go on while the daemon serves other requests, as
    --- the workspace's own detection does, §19.11) and `go` gets them as
    --- `{ [mod_type] = list }`; with none needed, `go(nil)`. `go` runs the
    --- request's own segment, which replies. Only the detection's start runs
    --- in the client's environment: its later probes (after the first async
    --- step) see the daemon's, as load/rescan detection does (BACKLOG). A
    --- detection that throws is answered here, refused.
    local function with_keyed_tools(ctx, needs, go)
        service:_on_model_request(ctx.conn, { kind = "query", env = ctx.env }, function(ws, mctx)
            local mod_type = needs(ws)
            -- Deferred, not yet replied: a throw until `go` takes the
            -- request over is still answered by the model queue.
            mctx.deferred = true
            if not mod_type then
                mctx.replied = true
                go(nil)
                return {}
            end
            mc.detect_keyed_tools_async(mod_type, function(list, err)
                if ctx.conn.closed then return end
                if not list then
                    return mctx.reply({ outcome = "refused", exit_code = 1,
                        message = "detecting the " .. mod_type .. " toolchains failed: " .. tostring(err) })
                end
                -- The reply is now `go`'s segment's.
                mctx.replied = true
                go({ [mod_type] = list })
            end)
            return {}
        end, nil, function(fields) ctx.reply(fields) end)
        return require("loomworks.daemon.interfaces").ASYNC
    end

    function methods.candidates(ctx, args)
        return with_keyed_tools(ctx, function(ws)
            local t = mc.candidate_type(ws, args.path, args.type)
            return mc.keyed_tools_needed(ws, t) and t or nil
        end, function(detected)
            read(ctx, function(ws) return mc.project_candidates(ws, args.path, args.type, detected) end)
        end)
    end

    function methods.add(ctx, args)
        local tool_key = type(args.tool) == "table" and args.tool.key or nil
        return with_keyed_tools(ctx, function(ws)
            return tool_key ~= nil and mc.keyed_tools_needed(ws, args.type, tool_key) and args.type or nil
        end, function(detected) return command(service, ctx, function(ws)
            if not require("loomworks.modules").get(args.type) then
                return mc.refused("unknown project type '" .. tostring(args.type) .. "'", 2)
            end
            -- The directory (`path`, else the one named by the key) must be
            -- under the root (exit 2) and exist; it is stored relative to it.
            local rel, refusal = mc.project_dir(ws.root, plain(args.path) or args.key)
            if not rel then return refusal end
            local path = rel == "" and "." or rel
            local tool_entry
            if args.tool ~= nil then
                tool_entry, refusal = mc.project_tool_entry(ws, args.type, args.tool.key, detected)
                if not tool_entry then return refusal end
            end
            local r = mc.project_add(ws, args.key, args.type, path, plain(args.mappings), tool_entry)
            if r.outcome == "ok" then r.project = entity(r.project, r.project and r.project.key) end
            return r
        end) end)
    end

    function methods.declaration(ctx, args)
        return rd(ctx, args, function(project)
            return mc.project_declaration(project, function(o) return service.ids:id(o) end)
        end)
    end

    function methods.configuration_save(ctx, args)
        return cmd(ctx, args, function(project)
            local cfg
            if args.configuration ~= nil then
                local err
                cfg, err = configuration_of(service, project, args.configuration)
                if not cfg then return mc.refused(err) end
            end
            local r = mc.configuration_save(project, cfg, args.name, plain(args.fields))
            if r.outcome == "ok" then
                r.configuration = entity(r.configuration, r.configuration and r.configuration.name)
            end
            return r
        end)
    end

    function methods.configuration_remove(ctx, args)
        return cmd(ctx, args, function(project)
            local cfg, err = configuration_of(service, project, args.configuration)
            if not cfg then return mc.refused(err) end
            return mc.configuration_remove(project, cfg)
        end)
    end

    function methods.options_save(ctx, args)
        return cmd(ctx, args, function(project) return mc.options_save(project, plain(args.options)) end)
    end

    function methods.launch_save(ctx, args)
        return cmd(ctx, args, function(project)
            local launch
            if args.launch ~= nil then
                local err
                launch, err = launch_of(service, project, args.launch)
                if not launch then return mc.refused(err) end
            end
            local r = mc.launch_save(project, launch, args.name, plain(args.data))
            if r.outcome == "ok" then r.launch = entity(r.launch, r.launch and r.launch.name) end
            return r
        end)
    end

    function methods.launch_remove(ctx, args)
        return cmd(ctx, args, function(project)
            local launch, err = launch_of(service, project, args.launch)
            if not launch then return mc.refused(err) end
            return mc.launch_remove(project, launch)
        end)
    end

    function methods.deploy_save(ctx, args)
        return cmd(ctx, args, function(project) return mc.deploy_save(project, plain(args.deploy)) end)
    end

    function methods.variable_save(ctx, args)
        return cmd(ctx, args, function(project)
            if args.variable ~= nil and not (project.variables and project.variables[args.variable]) then
                return mc.refused("no variable '" .. tostring(args.variable) .. "' in project '" .. project.key .. "'")
            end
            return mc.variable_save(project, args.variable, args.name, plain(args.data))
        end)
    end

    function methods.variable_remove(ctx, args)
        return cmd(ctx, args, function(project)
            if not (project.variables and project.variables[args.variable]) then
                return mc.refused("no variable '" .. tostring(args.variable) .. "' in project '" .. project.key .. "'")
            end
            return mc.variable_remove(project, args.variable)
        end)
    end

    function methods.type_config_set(ctx, args)
        return cmd(ctx, args, function(project)
            if not mc.editable_type_config_field(project, args.field) then
                return mc.refused("'" .. tostring(args.field) .. "' is not an editable type_config field of project '"
                    .. project.key .. "'", 2)
            end
            return mc.type_config_set(project, args.field, plain(args.value))
        end)
    end

    function methods.expand_preview(ctx, args)
        return rd(ctx, args, function(project, ws)
            local profile
            if args.profile ~= nil then
                local err
                profile, err = profile_of(service, ws, args.profile)
                if not profile then return mc.refused(err) end
            end
            return mc.expand_preview(project, profile, args.templates)
        end)
    end

    -- The build options of a configured configuration unit (API.md §19; step
    -- 5o C2d): the unit is checked and its build directory taken in a model
    -- segment; the module's read (ConfigUnit:options_async, spec §8
    -- `get_options_async`) then runs off the model queue, so a slow meson
    -- does not hold the other requests, and the reply follows when it ends.
    -- Its programs spawn in the client's environment. Read-only, no lock.
    function methods.unit_options(ctx, args)
        local envscope = require("loomworks.daemon.envscope")
        local exe = require("loomworks.exe")
        service:_on_model_request(ctx.conn, { kind = "query", env = ctx.env }, function(ws, mctx)
            local function refused(message) return { outcome = "refused", message = message, exit_code = 1 } end
            local id = args.unit and args.unit.id
            local unit = service.ids:find(id, ws._config_units)
            if not unit then
                return refused("no configuration unit with id " .. tostring(id) .. " (a stale reference)")
            end
            local label = (unit._project and unit._project.key or "?") .. "/" .. tostring(unit:config_key())
            -- A unit being deleted or cleaned: its build dir may be mid
            -- rm-rf, so it is not read.
            if unit:is_deleting() then
                return refused("configuration unit " .. label .. " is being deleted")
            end
            if not unit:_was_configured() then
                return refused("configuration unit " .. label .. " is not configured")
            end
            local env = mctx.env
            --- A program of the read: `vim.system`'s signature, in the
            --- client's environment (plus the call's own variables).
            local function system(cmd, so, on_exit)
                so = vim.tbl_extend("force", {}, so or {})
                if env then
                    so.env = envscope.with_overlay(env, so.env)
                    so.clear_env = true
                end
                so.env = exe.with_no_cwd_env(so.env)
                return exe.system(cmd, so, on_exit)
            end
            mctx.deferred = true
            unit:options_async(function(options)
                if mctx.conn.closed then return end
                if not options or #options == 0 then
                    return mctx.reply(refused("configuration unit " .. label .. " has no build options"))
                end
                mctx.reply({ outcome = "ok", options = options })
            end, { system = system })
            return {}
        end, nil, function(fields) ctx.reply(fields) end)
        return require("loomworks.daemon.interfaces").ASYNC
    end
    return { methods = methods }
end

--- The `loomworks.ConfigSets/1` handlers (API.md §20; step 5o part B2), on
--- `/projects` beside Projects/1. `candidates` is a read; the others are
--- commands run as Workspace/1's (`command`): the references (a set by id or
--- name; a mapping's project by key and configuration by name in it)
--- resolve to the live objects once, here, and the write is the shared
--- loomworks.model_commands function the in-process editor calls. A rename
--- propagates under the workspace operation lock O
--- (Workspace:rename_configuration_set is guarded, spec §19.3).
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.config_sets_impl(service)
    local mc = require("loomworks.model_commands")
    local methods = {}

    --- `mappings` (project key → configuration name) as objects, or nil +
    --- the refusal. A project absent is unmapped.
    local function mappings_of(ws, raw)
        local out = {}
        for key, name in pairs(plain(raw) or {}) do
            local project, perr = project_of(service, ws, { key = key })
            if not project then return nil, mc.refused(perr) end
            local cfg = project:get_configuration(name)
            if not cfg or cfg._removed then
                return nil, mc.refused("no configuration '" .. tostring(name) .. "' in project '" .. key .. "'")
            end
            out[project] = cfg
        end
        return out
    end

    function methods.candidates(ctx)
        return read_segment(service, ctx, function(ws)
            local r = mc.config_set_candidates(ws)
            local sets = {}
            for _, s in ipairs(r.sets) do
                sets[#sets + 1] = { config_set = s.config_set and service.ids:id(s.config_set) or nil,
                    name = s.name, auto = s.auto, description = s.description, candidate = s.candidate }
            end
            return { outcome = "ok", sets = sets }
        end)
    end

    function methods.add(ctx, args)
        return command(service, ctx, function(ws)
            local mappings, refusal = mappings_of(ws, args.mappings)
            if not mappings then return refusal end
            local r = mc.config_set_add(ws, args.name, mappings)
            if r.outcome == "ok" then r.config_set = { id = service.ids:id(r.config_set), key = r.config_set.name } end
            return r
        end)
    end

    function methods.update(ctx, args)
        return command(service, ctx, function(ws)
            local cs, err = config_set_of(service, ws, args.config_set)
            if not cs then return mc.refused(err) end
            local mappings, refusal = mappings_of(ws, args.mappings)
            if not mappings then return refusal end
            return mc.config_set_update(cs, plain(args.name), mappings)
        end)
    end

    function methods.remove(ctx, args)
        return command(service, ctx, function(ws)
            local cs, err = config_set_of(service, ws, args.config_set)
            if not cs then return mc.refused(err) end
            return mc.config_set_remove(cs)
        end)
    end

    function methods.generate_defaults(ctx)
        return command(service, ctx, function(ws)
            local r = mc.config_set_generate_defaults(ws)
            r.config_sets = nil
            return r
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
        { M.SDKS, M.sdks_impl },
        { M.PROFILES, M.profiles_impl },
        { M.PROJECTS, M.projects_impl },
        { M.CONFIG_SETS, M.config_sets_impl },
        { M.DEBUG, M.debug_impl },
        { M.LSP, M.lsp_impl },
        { require("loomworks.daemon.maintenance").WHERE, require("loomworks.daemon.maintenance").impl },
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
