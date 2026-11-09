-- The editor's observer of the workspace daemon (spec §19.11, §19.12,
-- §19.16) against a fake daemon world (frames as plain tables, shaped by
-- spec/protocol): the task stream (unresolved keys by name only),
-- keepalive, drop without relaunch, reconnect, incompatible and retiring
-- daemons, and in-process mode (the host-binary order:
-- tests/provision_select_spec.lua).

local observer = require("loomworks.daemon.observer")
local editor_ops = require("loomworks.daemon.editor_ops")
local binary_select = require("loomworks.provision.select")
local remote_task = require("loomworks.daemon.remote_task")
local version = require("loomworks.daemon.client.version")
local events = require("loomworks")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- `welcome.objects` / `describe().objects` (§19.20) offering `wants`
--- (entries of observer.ROOT / observer.FEATURES) at their versions.
local function objects_of(wants)
    local by, out = {}, {}
    for _, w in ipairs(wants) do
        local o = by[w.object]
        if not o then
            o = { path = w.object, interfaces = {} }
            by[w.object] = o
            out[#out + 1] = o
        end
        o.interfaces[#o.interfaces + 1] = { name = w.iface, versions = { w.v } }
    end
    return out
end

--- Everything the editor needs (the root and every feature).
local function all_wants() return require("loomworks.provision.needs").needed() end

local function refused() return { outcome = "refused", message = "stub", exit_code = 1 } end

--- A fake daemon world for the fake relay (`w.inspect`, `w.connect`): one
--- live daemon (`w.handle`) offering `w.objects` (`o.views == false`: the
--- root only) with stub answers; `w:emit` sends an interface signal to the
--- connections subscribed to it (per-object `seq`), `w:task` a task frame to
--- those subscribed to `/tasks`, `w:drop()` stops the
--- daemon (every connection closes).
local function new_world(o)
    o = o or {}
    local w = { conns = {}, live = true, launched = 0, delivery = "subscription", status_tasks = {},
        devices = {}, device_reads = 0, protocol = o.protocol, generation = 1, lw_version = "0.1.0",
        handle = { pid = 4242, start_time = "st:1", endpoint = "fake", exe = o.exe } }
    w.objects = objects_of(o.views == false and { observer.ROOT } or all_wants())
    w.views = {
        ["loomworks.view.Header"] = { root = o.root, pid = 4242, lw_version = "0.1.0", session_generation = 1,
            state = "unloaded" },
        ["loomworks.view.ProjectsIndex"] = { projects = {} },
        ["loomworks.view.Tests"] = { state = "unloaded", stale = false, units = {} },
        ["loomworks.view.Workspace"] = { published = false, modified = false, diagnostics = {}, suggestions = 0,
            profiles = {}, orphaned = {}, config_sets = {}, projects = {}, sdks = {}, sdk_providers = 0 },
    }

    local function offered(object, iface, v)
        for _, ob in ipairs(w.objects) do
            if ob.path == object then
                for _, i in ipairs(ob.interfaces) do
                    if i.name == iface and vim.tbl_contains(i.versions, v) then return true end
                end
            end
        end
        return false
    end

    --- The daemon's answer to `method` (`w.on_call(conn, call)` first: a
    --- non-nil first return answers instead; "noreply" never answers).
    local function answer(c, object, iface, v, method, args)
        if object == "/" and method == "describe" then
            return { objects = vim.deepcopy(w.objects), delivery = w.delivery }
        elseif object == "/" and method == "subscribe" then
            if not offered(args.object, args.iface, args.v) then
                return nil, { code = "not_found", message = "not offered" }
            end
            c.subs[#c.subs + 1] = { object = args.object, iface = args.iface, v = args.v }
            return { sub_id = #c.subs, seq = c.seq[args.object] or 0,
                initial = args.object == "/views" and w.views[args.iface] or nil }
        elseif object == "/devices" and method == "list" then
            w.device_reads = w.device_reads + 1
            return { devices = vim.deepcopy(w.devices) }
        elseif object == "/lsp" and method == "get" then
            return { state = "unloaded", ready = false, projects = {}, options = {} }
        elseif object == "/debug" then
            return { languages = {} }
        elseif object == "/tasks" and method == "list" then
            return { tasks = {} }
        elseif object == "/views" and method == "get" then
            return w.views[iface]
        end
        return refused()
    end

    function w.inspect()
        if w.live then return { kind = "live", handle = w.handle } end
        return w.st or { kind = "none" }
    end

    function w.launch()
        w.launched = w.launched + 1
        if w.next then
            w.handle, w.next = w.next, nil
            w.live, w.retiring = true, nil
        end
    end

    function w.connect(_, copts, cb)
        if not w.live then return vim.schedule(function() cb(nil, "refused") end) end
        local proto = w.protocol or version.PROTOCOL
        local c = { subs = {}, seq = {}, calls = {}, requests = {}, role = copts.role,
            on_message = copts.on_message, on_close = copts.on_close,
            challenge = { protocol = proto, protocol_min = o.protocol_min or proto,
                lw_version = w.lw_version, session_generation = w.generation },
            welcome = { seq = 0, retiring = w.retiring, objects = vim.deepcopy(w.objects) } }
        function c.call(self, object, iface, v, method, args, ccb, env)
            local call = { object = object, iface = iface, v = v, method = method, args = args, env = env }
            self.calls[#self.calls + 1] = call
            local res, err
            if w.on_call then res, err = w.on_call(self, call) end
            if res == "noreply" then return end
            if res == nil and err == nil then res, err = answer(self, object, iface, v, method, args) end
            vim.schedule(function() if ccb and not self.closed then ccb(res, err) end end)
        end
        function c.request(self, msg, rcb)
            self.requests[#self.requests + 1] = msg
            local reply = {}
            if msg.kind == "status" then reply = { tasks = vim.deepcopy(w.status_tasks) } end
            vim.schedule(function() if rcb and not self.closed then rcb(reply) end end)
        end
        function c.close(self)
            if self.closed then return end
            self.closed = true
            for i, x in ipairs(w.conns) do if x == self then table.remove(w.conns, i) break end end
            if self.on_close then self.on_close(self) end
        end
        w.conns[#w.conns + 1] = c
        vim.schedule(function() cb(c) end)
    end

    --- The observer's open connection (role "observer").
    function w.observer_conn()
        for _, c in ipairs(w.conns) do if c.role == "observer" and not c.closed then return c end end
    end
    function w.observer_count()
        local n = 0
        for _, c in ipairs(w.conns) do if c.role == "observer" and not c.closed then n = n + 1 end end
        return n
    end
    --- The objects the observer's connection is subscribed to, sorted.
    function w.subs_of()
        local out = {}
        for _, s in ipairs((w.observer_conn() or { subs = {} }).subs) do out[#out + 1] = s.object end
        table.sort(out)
        return out
    end

    --- A signal of `object` `iface`/`v` to each connection subscribed to it
    --- (the root's to every connection), with the per-object `seq`.
    function w.emit(object, iface, v, name, args)
        for _, c in ipairs(vim.list_slice(w.conns)) do
            local subbed = object == "/"
            for _, s in ipairs(c.subs) do
                if s.object == object and s.iface == iface and s.v == v then subbed = true end
            end
            if subbed then
                c.seq[object] = (c.seq[object] or 0) + 1
                c.on_message({ kind = "signal", object = object, iface = iface, v = v, name = name,
                    seq = c.seq[object], args = args or {} })
            end
        end
    end

    --- A task frame (PROTOCOL §14.2) to each connection subscribed to `/tasks`.
    function w.task(frame)
        for _, c in ipairs(vim.list_slice(w.conns)) do
            local subbed = false
            for _, s in ipairs(c.subs) do if s.object == "/tasks" then subbed = true end end
            if subbed then c.on_message(vim.deepcopy(frame)) end
        end
    end

    --- Offer `wants` too; the root's `objects_changed`.
    function w.mount(wants)
        for _, ob in ipairs(objects_of(wants)) do w.objects[#w.objects + 1] = ob end
        w.emit("/", "loomworks.Root", 1, "objects_changed", { added = {} })
    end
    --- Drop object `path` and its subscriptions; the root's `objects_changed`.
    function w.unmount(path)
        for i = #w.objects, 1, -1 do if w.objects[i].path == path then table.remove(w.objects, i) end end
        for _, c in ipairs(w.conns) do
            for i = #c.subs, 1, -1 do if c.subs[i].object == path then table.remove(c.subs, i) end end
        end
        w.emit("/", "loomworks.Root", 1, "objects_changed", { removed = { path } })
    end

    --- The daemon stops: not live, every connection closes.
    function w.drop()
        w.live = false
        for _, c in ipairs(vim.list_slice(w.conns)) do c:close() end
    end
    return w
end

describe("the editor client's version check (§19.9)", function()
    local cv = require("loomworks.daemon.client.version")
    it("needs overlapping transport ranges only; the host version and file formats may differ", function()
        assert.is_true((cv.compatible({ protocol = cv.PROTOCOL, lw_version = "9.9.9" })))
        assert.is_true((cv.compatible({ protocol = cv.PROTOCOL + 3, protocol_min = cv.PROTOCOL })))
        assert.is_true((cv.compatible({ protocol = cv.PROTOCOL, schemas = { user = 999, cache = 0 } })))
        local ok, what = cv.compatible({ protocol = cv.PROTOCOL + 1 })
        assert.is_false(ok); assert.equals("protocol", what)
        assert.is_false((cv.compatible({ protocol = cv.PROTOCOL_MIN - 1 })))
        assert.is_false((cv.compatible(nil)))
    end)

    it("speaks transport 1 only: a pre-0.2.0 daemon (transports up to 11) is incompatible", function()
        assert.equals(1, cv.PROTOCOL)
        assert.equals(1, cv.PROTOCOL_MIN)
        assert.equals(1, cv.negotiate(1, 1))
        assert.equals(1, cv.negotiate(3, 1))
        assert.is_nil(cv.negotiate(11, 10))
        assert.is_nil(cv.negotiate(11))
        local ok, what = cv.compatible({ protocol = 11, protocol_min = 10 })
        assert.is_false(ok); assert.equals("protocol", what)
    end)

    it("announces the plugin's own version, from its CHANGELOG", function()
        local pv = require("loomworks.version")
        assert.equals("0.2.0+dev", pv.parse("# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-01-01\n"))
        assert.equals("0.1.9", pv.parse("## v0.1.9\n## 0.1.8\n"))
        assert.is_nil(pv.parse("# nothing\n"))
        assert.equals(pv.get(), cv.identity())
        assert.truthy(pv.lua_root():match("/lua$"), pv.lua_root())
    end)
end)

describe("the observer (§19.16)", function()
    local root, W, ws, obs
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        -- The workspace root as the editor resolves it (its real path).
        ws = { root = vim.fs.normalize(vim.uv.fs_realpath(root)) }
    end)
    after_each(function()
        if obs then obs:stop() end
        observer.detach()
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        W = nil
        require("loomworks").shutdown()
    end)

    -- The observer over a fake relay (tests/daemon_fake_relay: `fr`), whose
    -- `inspect` / `connect` / `launch` / `manual` come from `extra`; a host
    -- binary "lw" is selected unless `extra.resolve` says otherwise.
    local fr
    local function attach(extra)
        extra = extra or {}
        -- (Default: the case's fake daemon world `W`, read when the relay
        -- polls; none yet: no daemon.)
        fr = FR.new({
            inspect = extra.inspect or function(r) return W and W.inspect(r) or { kind = "none" } end,
            connect = extra.connect or function(ep, co, cb)
                if W then return W.connect(ep, co, cb) end
                vim.schedule(function() cb(nil, "refused") end)
            end,
            launch = extra.launch or function(r) if W then W.launch(r) end end, manual = extra.manual })
        local o = { getenv = daemon_mode, keepalive_ms = 100, resolve = function() return "lw" end, relay = fr.relay }
        for k, v in pairs(extra) do
            if k ~= "connect" and k ~= "launch" and k ~= "manual" then o[k] = v end
        end
        return observer.attach(ws.root, o)
    end
    -- A relay seam that records what it is asked to spawn and does nothing.
    local function stub_relay(t)
        return function(ropts)
            t[#t + 1] = ropts
            return { close = function(r) r.closed = true end }
        end
    end

    local ALL_SUBS = { "/devices", "/lsp", "/tasks", "/tests", "/views", "/views", "/views", "/views", "/workspace" }

    --- The world's daemon connected and observed.
    local function connected()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" end, 10), obs:runtime_line())
    end

    it("subscribes to /tasks and /workspace when offered (step 5g.3) and observes through them", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        assert.equals("interfaces", obs.mode)
        assert.is_nil(obs.feature_note)
        local subs = {}
        for _, sub in ipairs(W.observer_conn().subs) do subs[#subs + 1] = sub.object .. " " .. sub.iface end
        table.sort(subs)
        assert.same({ "/devices loomworks.Devices", "/lsp loomworks.LspConfig", "/tasks loomworks.Tasks",
            "/tests loomworks.Tests",
            "/views loomworks.view.Header", "/views loomworks.view.ProjectsIndex", "/views loomworks.view.Tests",
            "/views loomworks.view.Workspace", "/workspace loomworks.Workspace" }, subs)
        -- A task another client owns reaches it through the subscription,
        -- with its opaque string id.
        W.task({ kind = "task", task_id = "tk-1", phase = "start", meta = { name = "dev", kind = "build" } })
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        assert.equals("tk-1", require("loomworks").get_daemon_tasks()[1].id)
        W.task({ kind = "task", task_id = "tk-1", phase = "done", exit_code = 0 })
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 0 end, 10))
    end)

    it("does not observe a pre-0.2.0 daemon (transports 10..11)", function()
        W = new_world({ root = ws.root, protocol = 11, protocol_min = 10 })
        obs = attach()
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        assert.truthy(obs:runtime_line():find("not observing it", 1, true), obs:runtime_line())
        assert.is_nil(obs.mode)
        assert.same({}, W.subs_of())
    end)

    it("a missing interface is one per-feature note; the connection stays (§19.16 Interface client)", function()
        W = new_world({ root = ws.root, views = false })
        obs = attach()
        connected()
        assert.equals("interfaces", obs.mode)
        -- The describe reports `delivery = "subscription"`: the daemon
        -- delivers by subscription only, so the editor really gets nothing.
        assert.is_true(obs._sub_only)
        assert.is_true(vim.wait(5000, function() return obs.feature_note ~= nil end, 10), obs:runtime_line())
        assert.equals("tasks: daemon offers no loomworks.Tasks, editor needs /1; "
            .. "model changes: daemon offers no loomworks.Workspace, editor needs /1; "
            .. "statusline: daemon offers no loomworks.view.Header, editor needs /1; "
            .. "project index: daemon offers no loomworks.view.ProjectsIndex, editor needs /1; "
            .. "tests: daemon offers no loomworks.view.Tests, editor needs /1; "
            .. "workspace view: daemon offers no loomworks.view.Workspace, editor needs /1; "
            .. "operations: daemon offers no loomworks.Build, editor needs /1; "
            .. "launch: daemon offers no loomworks.Launch, editor needs /1; "
            .. "debug adapters: daemon offers no loomworks.DebugConfig, editor needs /1; "
            .. "tests: daemon offers no loomworks.Tests, editor needs /1 — tests unavailable; "
            .. "devices: daemon offers no loomworks.Devices, editor needs /1 — devices unavailable; "
            .. "profiles: daemon offers no loomworks.Profiles, editor needs /1; "
            .. "configuration sets: daemon offers no loomworks.ConfigSets, editor needs /1; "
            .. "projects: daemon offers no loomworks.Projects, editor needs /1; "
            .. "toolchains: daemon offers no loomworks.Toolchains, editor needs /1; "
            .. "sdks: daemon offers no loomworks.Sdks, editor needs /1; "
            .. "maintenance: daemon offers no loomworks.Maintenance, editor needs /1",
            obs.feature_note)
        -- The LSP configuration is never run in-process: its own note
        -- (§19.16 "LSP configuration" Unavailable).
        assert.truthy(obs:runtime_line():find("lsp configuration: daemon offers no loomworks.LspConfig, "
            .. "editor needs /1 — language servers withheld", 1, true))
        assert.truthy(obs:runtime_line():find("observing the workspace daemon", 1, true))
        assert.truthy(obs:runtime_line():find("editor needs /1", 1, true))
        assert.equals("tasks: daemon offers loomworks.Tasks/2,/3, editor needs /1",
            observer.feature_note(observer.TASKS, { 2, 3 }))
    end)

    --- A connect that rewrites the connection the observer gets: `edit(conn)`
    --- before the observer sees it.
    local function connect_with(edit)
        return function(ep, o, cb)
            return W.connect(ep, o, function(conn, err)
                if conn then edit(conn) end
                cb(conn, err)
            end)
        end
    end

    it("re-describes on connect and subscribes from describe's objects (§19.16 Interface client)", function()
        W = new_world({ root = ws.root })
        -- welcome.objects without the views: only Root.describe offers them.
        -- (The root itself stays: a daemon without loomworks.Root/1 is
        -- incompatible, §19.16 "Retiring an incompatible daemon".)
        obs = attach({ connect = connect_with(function(conn)
            conn.welcome.objects = { { path = "/", interfaces = { { name = "loomworks.Root", versions = { 1 } } } } }
        end) })
        connected()
        assert.is_true(vim.wait(5000, function() return #W.subs_of() == 9 end, 10))
        assert.same(ALL_SUBS, W.subs_of())
        assert.is_nil(obs.feature_note)
    end)

    it("falls back to welcome.objects when describe fails", function()
        W = new_world({ root = ws.root })
        W.on_call = function(_, call)
            if call.method == "describe" then return nil, { code = "internal", message = "no" } end
        end
        obs = attach()
        connected()
        assert.same(ALL_SUBS, W.subs_of())
    end)

    it("falls back to welcome.objects when describe never answers (bounded)", function()
        W = new_world({ root = ws.root })
        W.on_call = function(_, call)
            if call.method == "describe" then return "noreply" end
        end
        obs = attach({ describe_ms = 100 })
        connected()
        assert.same(ALL_SUBS, W.subs_of())
    end)

    it("subscribes when /tasks and /workspace appear later (objects_changed); the note clears", function()
        W = new_world({ root = ws.root, views = false })
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.feature_note ~= nil end, 10), obs:runtime_line())
        local later = {}
        for _, want in ipairs(observer.FEATURES) do later[#later + 1] = want end
        W.mount(later)
        assert.is_true(vim.wait(5000, function() return #W.subs_of() == 9 end, 10))
        assert.is_true(vim.wait(5000, function() return obs.feature_note == nil end, 10), obs:runtime_line())
        assert.is_nil(obs:runtime_line():find("editor needs", 1, true))
    end)

    it("a refused subscription is retried once on the next objects_changed", function()
        W = new_world({ root = ws.root })
        local refusals = 0
        W.on_call = function(_, call)
            if call.method == "subscribe" and call.args.object == "/tasks" and refusals < 1 then
                refusals = refusals + 1
                return nil, { code = "internal", message = "busy" }
            end
        end
        obs = attach()
        connected()
        assert.same({ "/devices", "/lsp", "/tests", "/views", "/views", "/views", "/views", "/workspace" }, W.subs_of())
        assert.truthy((obs.feature_note or ""):find("tasks: loomworks.Tasks/1 refused (busy)", 1, true))
        W.mount({ { object = "/other", iface = "loomworks.Tasks", v = 1 } })
        assert.is_true(vim.wait(5000, function() return #W.subs_of() == 9 end, 10))
        assert.is_true(vim.wait(5000, function() return obs.feature_note == nil end, 10), obs:runtime_line())
    end)

    it("takes the views' initial state, applies each update, re-gets after a seq gap (step 5j)", function()
        local lw = require("loomworks")
        local store = require("loomworks.views")
        -- Nothing attached yet: no view, nothing built in-process.
        assert.is_nil(store.source("header"))
        assert.is_nil(lw.view_header())
        W = new_world({ root = ws.root })
        obs = attach()
        assert.is_true(vim.wait(10000, function()
            return store.source("header") == "daemon" and store.source("projects") == "daemon"
        end, 10), obs:runtime_line())
        assert.is_nil(obs.feature_note)
        -- The daemon's views are rendered as they are: it has not loaded the
        -- workspace, so no buffer has a project or a status.
        assert.equals("unloaded", lw.view_header().state)
        assert.is_nil(store.status_of(lw.view_header(), store.projects_index(), root .. "/App/main.c"))
        assert.is_nil(store.match(store.projects_index(), root .. "/App/main.c"))
        -- An update replaces the table (full state).
        local header = { root = root, state = "loaded", name = "dm", active_profile = "dev",
            active_profile_id = "p1", config_set = "dev", config_set_id = "c1", pid = 4242,
            lw_version = "0.1.0", session_generation = 1 }
        local function projects(state)
            return { projects = { { id = "x1", key = "App", label = "App", type = "shell",
                path = "App", abs_path = root .. "/App",
                active = { configuration = "Debug", unit_id = "u1", state = state } } } }
        end
        W.views["loomworks.view.Header"] = header
        W.views["loomworks.view.ProjectsIndex"] = projects("building")
        W.emit("/views", "loomworks.view.Header", 1, "update", header)
        W.emit("/views", "loomworks.view.ProjectsIndex", 1, "update", projects("building"))
        assert.is_true(vim.wait(5000, function()
            local idx = store.projects_index()
            return lw.view_header().state == "loaded" and #idx.projects == 1
        end, 10))
        local st = store.status_of(lw.view_header(), store.projects_index(), root .. "/App/main.c")
        assert.same({ profile_key = "dev", set_name = "dev", project = "App", configuration = "Debug",
            status = "building", profile_state = "building" }, st)
        -- A lost signal (a gap in the `/views` seq): both views are fetched
        -- again with `get`.
        local oc = W.observer_conn()
        oc.seq["/views"] = oc.seq["/views"] + 1
        W.views["loomworks.view.ProjectsIndex"] = projects("built")
        W.emit("/views", "loomworks.view.Header", 1, "update", header)
        assert.is_true(vim.wait(5000, function()
            local rec = store.projects_index().projects[1]
            return rec and rec.active.state == "built"
        end, 10))
        -- Stopping drops the daemon's tables; the root still attached,
        -- nothing is built in-process (step 6b-alpha): unloaded, no project
        -- index.
        obs:stop()
        assert.is_nil(store.source("header"))
        assert.is_nil(store.source("projects"))
        assert.equals("unloaded", lw.view_header().state)
        assert.equals(ws.root, lw.view_header().root)
        assert.is_nil(store.projects_index())
        -- Detached: no view at all.
        observer.detach()
        assert.is_nil(lw.view_header())
    end)

    it("a removed /views drops the daemon's views and re-renders the status page (daemon_view_changed)", function()
        local store = require("loomworks.views")
        W = new_world({ root = ws.root })
        obs = attach()
        assert.is_true(vim.wait(10000, function()
            return store.source("header") == "daemon" and store.source("projects") == "daemon"
        end, 10), obs:runtime_line())
        local seen = {}
        on("daemon_view_changed", function(d) seen[#seen + 1] = d and d.view or "all" end)
        W.unmount("/views")
        assert.is_true(vim.wait(5000, function()
            return store.source("header") == nil and store.source("projects") == nil
        end, 10))
        table.sort(seen)
        assert.same({ "header", "projects", "tests", "workspace" }, seen)
        -- Stopping with nothing held notifies nothing more.
        obs:stop()
        assert.equals(4, #seen)
    end)

    it("stopping while the daemon's views are held notifies the status page once", function()
        local store = require("loomworks.views")
        W = new_world({ root = ws.root })
        obs = attach()
        assert.is_true(vim.wait(10000, function()
            return store.source("header") == "daemon" and store.source("projects") == "daemon"
        end, 10), obs:runtime_line())
        local seen = 0
        on("daemon_view_changed", function() seen = seen + 1 end)
        obs:stop()
        assert.is_nil(store.source("header"))
        assert.equals(1, seen)
    end)

    it("a daemon offering neither view whose describe states no `delivery` gets no note", function()
        W = new_world({ root = ws.root, views = false })
        -- No `delivery` in the describe (PROTOCOL.md §10.1 `delivery?`).
        W.delivery = nil
        obs = attach()
        connected()
        vim.wait(300)
        assert.is_nil(obs._sub_only)
        assert.is_nil(obs.feature_note)
        -- Only the LSP configuration's own note (never run in-process).
        local line = obs:runtime_line():gsub(" — lsp configuration: .* — language servers withheld$", "")
        assert.is_nil(line:find("editor needs", 1, true))
    end)

    it("with no host binary: one note, no relay, and a daemon another client starts is not observed", function()
        obs = attach({ resolve = function() return nil end })
        assert.equals("no-binary", obs.state)
        assert.equals(binary_select.NONE_NOTE .. " — lsp configuration: no lw host binary — language servers withheld",
            obs:runtime_line())
        assert.same({}, fr.spawns)
        W = new_world({ root = ws.root })
        vim.wait(300)
        assert.equals("no-binary", obs.state)
        assert.same({}, fr.spawns)
        assert.equals(0, #W.conns)
    end)

    it("connects through an ordinary relay on load, from the selected binary (§19.16 Through the relay)", function()
        W = new_world({ root = ws.root })
        obs = attach()
        assert.same({ "ordinary" }, fr.spawns)
        local ro = fr.relays[1].ropts
        assert.same({ "lw" }, ro.argv)
        -- The workspace's root (its canonical form: on a Windows runner the
        -- temp dir may be an 8.3 short path such as RUNNER~1).
        assert.equals(ws.root, ro.root)
        assert.equals("editor", ro.client)
        assert.equals("observer", ro.role)
        connected()
        assert.equals(0, fr.launched)
        assert.equals(W.handle.pid, obs.daemon.pid)
        assert.equals(1, W.observer_count())
        -- Connected: an explicit connect spawns nothing more.
        obs:start(true)
        assert.same({ "ordinary" }, fr.spawns)
    end)

    --- Task frames (PROTOCOL §14.2) of task `id` through the world.
    local function frames(id)
        local t = {}
        function t.start(meta) W.task({ kind = "task", task_id = id, phase = "start", meta = meta }) end
        function t.line(stream, text) W.task({ kind = "task", task_id = id, phase = "line", stream = stream, text = text }) end
        function t.output(stream, text)
            W.task({ kind = "task", task_id = id, phase = "output", stream = stream, text = text })
        end
        function t.progress(pct) W.task({ kind = "task", task_id = id, phase = "progress", pct = pct }) end
        function t.done(code, err) W.task({ kind = "task", task_id = id, phase = "done", exit_code = code, error = err }) end
        return t
    end

    it("keeps observed tasks as display data and ids; nothing resolves to a model (step 6b-alpha)", function()
        W = new_world({ root = ws.root })
        local started, stopped = {}, {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        on("daemon_task_stopped", function(d) stopped[#stopped + 1] = d.task end)
        obs = attach()
        connected()
        local profile = { key = "default" }
        local pp = { project = "app", configuration = "Debug" }
        -- A task a CLI connection owns, streamed to the observer.
        local t = frames("tk-1")
        t.start({ name = "dev", kind = "build", profile = profile.key, origin = "cli", units = {
            { project = pp.project, configuration = pp.configuration },
            { project = "ghost", configuration = "Nope" },
        } })
        assert.is_true(vim.wait(5000, function() return #started == 1 end, 10))
        local rt = require("loomworks").get_daemon_tasks()[1]
        assert.equals(started[1], rt)
        -- Display data only (step 6b-α): nothing resolves to a model, which
        -- the `daemon`-mode editor does not hold.
        assert.is_nil(rt.profile)
        assert.equals(profile.key, rt.profile_name)
        assert.equals(pp.project, rt.units[1].project)
        assert.equals(pp.configuration, rt.units[1].configuration)
        assert.is_nil(rt.units[1].unit)
        assert.equals("ghost", rt.units[2].project)
        -- The origin is the owner's.
        assert.equals("cli", rt.origin)
        assert.equals("lw", rt:origin_label())
        t.line("out", "building profile: dev")
        t.output("stdout", "compiler says hi\n")
        t.progress(50)
        assert.is_true(vim.wait(5000, function() return rt.pct == 50 end, 10))
        assert.truthy(rt:output():find("compiler says hi", 1, true))
        t.done(0)
        assert.is_true(vim.wait(5000, function() return #stopped == 1 end, 10))
        assert.equals(0, rt.exit_code)
        assert.same({}, require("loomworks").get_daemon_tasks())
        assert.truthy(rt:outcome():find("^built in "), rt:outcome())
    end)

    it("joins late: adopts the tasks a status reply lists, with their start time and percent", function()
        W = new_world({ root = ws.root })
        local pp = { project = "app", configuration = "Debug" }
        -- A task already running (owned by a CLI connection) before the
        -- editor connects: its `status.tasks` entry (§19.11).
        W.status_tasks = { { task_id = "tk-7", name = "dev", kind = "test", profile = "default", origin = "cli",
            units = { { project = pp.project, configuration = pp.configuration } },
            started_at = os.time() - 75, percent = 30 } }
        local started = {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        obs = attach()
        assert.is_true(vim.wait(10000, function() return #started == 1 end, 10), obs:runtime_line())
        local rt = require("loomworks").get_daemon_tasks()[1]
        assert.equals("tk-7", rt.id)
        assert.equals("test", rt.kind)
        assert.equals("cli", rt.origin)
        assert.equals(30, rt.pct)
        assert.is_true(rt:elapsed(obs:_clock()) >= 74)
        assert.equals(pp.project, rt.units[1].project)
        assert.is_nil(rt.units[1].unit)
        -- Its output starts now; it ends on done like any other.
        local t = frames("tk-7")
        t.output("stdout", "later output\n")
        assert.is_true(vim.wait(5000, function() return rt:output():find("later output", 1, true) ~= nil end, 10))
        t.done(1, "tests failed")
        assert.is_true(vim.wait(5000, function() return rt.finished end, 10))
        assert.same({}, require("loomworks").get_daemon_tasks())
        assert.truthy(rt:outcome():find("test failed", 1, true), rt:outcome())
    end)

    it("a remote clean is a clean, ends cleaned / clean failed, titled Cleaning (lw)", function()
        -- fidget with a recording progress API (the title is the handle's message).
        local titles = {}
        local saved = package.loaded["fidget.progress"]
        package.loaded["fidget.progress"] = { handle = { create = function(o)
            titles[#titles + 1] = o.message
            return { report = function() end, finish = function() end, cancel = function() end }
        end } }
        require("loomworks.fidget").setup()
        package.loaded["fidget.progress"] = saved
        W = new_world({ root = ws.root })
        local stopped = {}
        on("daemon_task_stopped", function(d) stopped[#stopped + 1] = d.task end)
        obs = attach()
        connected()
        local meta = function(kind)
            return { name = "dev", kind = kind, profile = "default", origin = "cli",
                units = { { project = "app", configuration = "Debug" } } }
        end
        local t = frames("tk-1")
        t.start(meta("clean"))
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        local rt = require("loomworks").get_daemon_tasks()[1]
        assert.equals("clean", rt.action)
        assert.equals("Cleaning (lw)", titles[#titles])
        t.done(0)
        assert.is_true(vim.wait(5000, function() return #stopped == 1 end, 10))
        assert.truthy(rt:outcome():find("^cleaned in "), rt:outcome())
        local t2 = frames("tk-2")
        t2.start(meta("clean"))
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        local rt2 = require("loomworks").get_daemon_tasks()[1]
        t2.done(3, "clean failed (exit 3): app: clean Debug")
        assert.is_true(vim.wait(5000, function() return #stopped == 2 end, 10))
        assert.truthy(rt2:outcome():find("^clean failed in .*: clean failed %(exit 3%)"), rt2:outcome())
        -- A remote test or run is shown building.
        for i, kind in ipairs({ "test", "run" }) do
            local tk = frames("tk-k" .. i)
            tk.start(meta(kind))
            assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
            assert.equals("build", require("loomworks").get_daemon_tasks()[1].action, kind)
            tk.done(0)
            assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 0 end, 10))
        end
    end)

    it("a task both broadcast (`start`) and listed in the join-late status reply is adopted once", function()
        local profile = { key = "default" }
        local pp = { project = "app", configuration = "Debug" }
        local started = {}
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
        obs = attach({ relay = stub_relay({}) })
        local meta = { name = "dev", kind = "build", profile = profile.key, origin = "cli",
            units = { { project = pp.project, configuration = pp.configuration } } }
        -- A connection whose status reply is held until the test releases it.
        local function fake_conn()
            local c = { pending = nil }
            function c:request(_, cb) self.pending = cb end
            function c:close() end
            return c
        end
        local function reply(c, id)
            local entry = vim.tbl_extend("force", { task_id = id, started_at = os.time() }, meta)
            c.pending({ tasks = { entry } })
            vim.wait(50)
        end
        -- The broadcast first, then the reply listing the same task.
        local c1 = fake_conn()
        obs.conn = c1
        obs:_join_late(c1)
        obs:_on_message({ kind = "task", phase = "start", task_id = 7, meta = meta })
        reply(c1, 7)
        assert.equals(1, #started)
        assert.equals(1, #require("loomworks").get_daemon_tasks())
        -- The reply first, then a late-arriving broadcast of the same task.
        local c2 = fake_conn()
        obs.conn = c2
        obs:_join_late(c2)
        reply(c2, 8)
        obs:_on_message({ kind = "task", phase = "start", task_id = 8, meta = meta })
        assert.equals(2, #started)
        assert.equals(2, #require("loomworks").get_daemon_tasks())
        -- Each ends once; then nothing of either is left.
        obs:_on_message({ kind = "task", phase = "done", task_id = 7, exit_code = 0 })
        obs:_on_message({ kind = "task", phase = "done", task_id = 8, exit_code = 0 })
        assert.same({}, require("loomworks").get_daemon_tasks())
        obs.conn = nil
    end)

    local BUILD_META = { name = "dev", kind = "build", profile = "default", origin = "cli",
        units = { { project = "app", configuration = "Debug" } } }

    it("shutdown with a remote task running clears it without recording a failure", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        frames("tk-1").start(BUILD_META)
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        local rt = require("loomworks").get_daemon_tasks()[1]
        require("loomworks").shutdown()
        obs = nil
        assert.same({}, require("loomworks").get_daemon_tasks())
        -- Not an operation that ended: cleared, no end result recorded.
        assert.is_true(rt.cleared)
        assert.is_nil(rt.exit_code)
    end)

    it("a dropped connection ends the remote tasks at once", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        frames("tk-1").start(BUILD_META)
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        local rt = require("loomworks").get_daemon_tasks()[1]
        obs.conn:close()
        assert.is_true(vim.wait(5000, function() return rt.finished end, 10))
        assert.equals("the workspace daemon disconnected", rt:outcome())
        assert.same({}, require("loomworks").get_daemon_tasks())
    end)

    it("the device list is dropped with the connection and read again on reconnect (step 5n C2)", function()
        W = new_world({ root = ws.root })
        obs = attach()
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" and obs._devices ~= nil end, 10),
            obs:runtime_line())
        assert.equals(1, W.device_reads)
        assert.same({}, editor_ops.devices(nil))
        W.devices = { { id = "d-9", key = "SER9", label = "SER9", state = "online", provider = "stub" } }
        obs.conn:close()
        assert.is_true(vim.wait(5000, function() return obs.conn == nil end, 10))
        assert.is_nil(obs._devices)
        assert.is_nil(editor_ops.devices(nil))
        -- Reconnected: read again, the cache is the new read.
        assert.is_true(vim.wait(10000, function() return obs.state == "connected" and obs._devices ~= nil end, 10),
            obs:runtime_line())
        assert.equals(2, W.device_reads)
        assert.equals("SER9", editor_ops.devices(nil)[1].key)
    end)

    it("keeps the connection alive with pings; drops on stop and never relaunches", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        local conn = obs.conn
        local function pings()
            local n = 0
            for _, m in ipairs(conn.requests) do if m.kind == "ping" then n = n + 1 end end
            return n
        end
        -- Pinged every keepalive_ms (100 here), on the same connection.
        assert.is_true(vim.wait(5000, function() return pings() >= 3 end, 10))
        assert.equals("connected", obs.state)
        assert.equals(conn, obs.conn)
        -- A task running when the daemon goes away ends with it.
        frames("tk-1").start({ name = "dev", kind = "build" })
        assert.is_true(vim.wait(5000, function() return #require("loomworks").get_daemon_tasks() == 1 end, 10))
        local rt = require("loomworks").get_daemon_tasks()[1]
        W.drop()
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("disconnected", 1, true))
        assert.equals("the workspace daemon disconnected", rt.end_reason)
        assert.same({}, require("loomworks").get_daemon_tasks())
        vim.wait(500)
        -- The drop is followed through one relay that never launches.
        assert.same({ "ordinary", "no-launch" }, fr.spawns)
        assert.equals(0, fr.launched)
        assert.truthy(obs:runtime_line():find("none is launched", 1, true), obs:runtime_line())
    end)

    it("on `retiring` disconnects and follows through one ordinary relay, which launches the successor", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        -- The root's `retiring` signal (§19.20); the daemon outlives it for a
        -- while (a busy client), answering new connections with a retiring
        -- `welcome`.
        W.retiring = true
        W.emit("/", "loomworks.Root", 1, "retiring", {})
        assert.is_true(vim.wait(5000, function() return #fr.spawns == 2 end, 10), obs:runtime_line())
        assert.same({ "ordinary", "ordinary" }, fr.spawns)
        assert.truthy(obs:runtime_line():find("retiring", 1, true), obs:runtime_line())
        assert.is_not_nil(obs._episode)
        vim.wait(300)
        assert.is_nil(obs.conn)
        assert.equals(0, W.observer_count())
        assert.equals(0, fr.launched)
        -- The retired daemon is gone: that relay launches its successor.
        W.next = { pid = 4343, start_time = "st:2", endpoint = "fake" }
        W.drop()
        assert.is_true(vim.wait(5000, function() return fr.launched == 1 end, 10), obs:runtime_line())
        assert.equals(2, #fr.spawns)
        connected()
        assert.equals(4343, obs.daemon.pid)
    end)

    it("does not observe an incompatible daemon (note, closed, skipped through a skip relay)", function()
        -- The CLI (here: another process) started it: the handle names its
        -- executable, and the note carries that path (§19.6, §19.16).
        W = new_world({ root = ws.root, exe = "/other/lw" })
        local connects, closed = 0, 0
        obs = attach({ connect = function(_, _, cb)
            connects = connects + 1
            cb({ challenge = { protocol = version.PROTOCOL + 1, lw_version = "9.0.0" },
                welcome = {}, close = function() closed = closed + 1 end })
        end })
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10))
        assert.truthy(obs:runtime_line():find("not observing it", 1, true), obs:runtime_line())
        assert.truthy(obs:runtime_line():find("lw v9.0.0 at /other/lw", 1, true), obs:runtime_line())
        -- Step 5i PR G2: its relay is closed, and a successor is followed
        -- through one skip relay naming it (handle pid and start time),
        -- which never connects to it.
        local id = observer.instance_id(W.handle)
        assert.is_string(id, "the handle names an instance")
        assert.is_true(vim.wait(5000, function() return #fr.spawns == 2 end, 10), vim.inspect(fr.spawns))
        assert.same({ "ordinary", "skip " .. id }, fr.spawns, vim.inspect(fr.spawns))
        vim.wait(300)
        assert.equals(1, connects, "connections")
        assert.equals(1, closed, "closed")
        assert.equals("waiting", obs.state, obs:runtime_line())
        -- An explicit connect ends the skip relay and tries an ordinary one.
        obs:start(true)
        assert.is_true(fr.relays[2].ended, "skip relay ended")
        assert.same({ "ordinary", "skip " .. id, "ordinary" }, fr.spawns, vim.inspect(fr.spawns))
    end)

    it("relays are single-flight; a late answer of a replaced relay is closed", function()
        local asked = {}
        obs = attach({ relay = stub_relay(asked) })
        assert.equals(1, #asked)
        assert.equals("connecting", obs.state)
        -- `:LoomworksDaemon connect` while an ordinary relay is in flight.
        obs:start(true)
        obs:start(false)
        assert.equals(1, #asked)
        -- A late answer to a relay that is no longer in flight is closed.
        local stale = { closed = 0, welcome = {} }
        function stale.close() stale.closed = stale.closed + 1 end
        obs:_on_relay({}, stale)
        assert.equals(1, stale.closed)
        assert.is_nil(obs.conn)
    end)

    it("spawns the relay from the selected binary, names it and passes binary.source's environment", function()
        local asked, seen_opts = {}, nil
        obs = attach({ binary = { prefer = "managed" },
            resolve = function(_, o)
                seen_opts = o
                return "/m/lw", "managed", { path = "/m/lw", source = "managed", label = "plugin-managed lw",
                    candidates = {}, env = { LOOMWORKS_LUA = "/src/lua" } }
            end,
            relay = stub_relay(asked) })
        assert.equals("connecting", obs.state)
        assert.same({ prefer = "managed" }, seen_opts.setting)
        assert.same({ "/m/lw" }, asked[1].argv)
        assert.equals("ordinary", asked[1].form)
        assert.same({ LOOMWORKS_LUA = "/src/lua" }, asked[1].env)
        assert.equals("connecting to or starting the workspace daemon (/m/lw (plugin-managed lw) with the Lua "
            .. "source /src/lua) — lsp configuration: waiting for the workspace daemon — language servers held",
            obs:runtime_line())
        assert.equals("managed", obs.selection.source)
    end)

    describe("a relay that exits before welcome (§19.16 Exit before welcome)", function()
        local function exit(code, info)
            fr.last().exit(code, info)
            vim.wait(50)
        end

        it("10 / 11: one no-launch relay, then wait", function()
            obs = attach({ manual = true })
            exit(10, { line = "lw: could not start the workspace daemon (boom)" })
            assert.same({ "ordinary", "no-launch" }, fr.spawns)
            assert.equals("waiting", obs.state)
            assert.truthy(obs:runtime_line():find("could not start the workspace daemon; the editor runs degraded "
                .. "(lw: could not start the workspace daemon (boom))", 1, true), obs:runtime_line())
            assert.truthy(obs:runtime_line():find("none is launched", 1, true), obs:runtime_line())
            -- The no-launch relay answering a 10 exits 11: no second one.
            exit(11, { line = "lw: the workspace daemon (pid 9) is not responding" })
            assert.same({ "ordinary", "no-launch" }, fr.spawns)
            assert.equals("waiting", obs.state)
            assert.truthy(obs:runtime_line():find("the workspace daemon is not responding", 1, true),
                obs:runtime_line())
            -- Only an explicit connect spawns again.
            vim.wait(200)
            assert.equals(2, #fr.spawns)
            obs:start(true)
            assert.same({ "ordinary", "no-launch", "ordinary" }, fr.spawns)
        end)

        it("14 -> a retiring relay naming the instance; 16 -> the episode's one ordinary relay; then wait", function()
            obs = attach({ manual = true })
            exit(14, { line = "lw: the retiring workspace daemon (pid 42) still holds the workspace after 60 s",
                retiring = "42:win:7" })
            assert.same({ "ordinary", "retiring 42:win:7" }, fr.spawns)
            assert.truthy(obs:runtime_line():find("a retiring daemon is still busy", 1, true), obs:runtime_line())
            assert.truthy(obs:runtime_line():find("waiting for the retiring daemon to exit", 1, true),
                obs:runtime_line())
            assert.falsy(obs:runtime_line():find("retiring 42:", 1, true), obs:runtime_line())
            exit(16)
            assert.same({ "ordinary", "retiring 42:win:7", "ordinary" }, fr.spawns)
            -- The successor's relay meets a retiring daemon again, with no
            -- retiring line (an older pin): a plain no-launch relay.
            exit(14, { line = "lw: the retiring workspace daemon (pid 43) still holds the workspace after 60 s" })
            assert.equals("no-launch", fr.spawns[4])
            -- A second 16 in the same episode: a note and a wait.
            exit(16, { line = "lw: the retiring workspace daemon (pid 43) has exited and no other daemon is live" })
            assert.equals(4, #fr.spawns)
            assert.equals("waiting", obs.state)
            assert.truthy(obs:runtime_line():find("the retiring daemon has exited and no other is live", 1, true),
                obs:runtime_line())
            -- An explicit connect ends the episode and starts over.
            obs:start(true)
            assert.equals(5, #fr.spawns)
            assert.equals("ordinary", fr.spawns[5])
            assert.is_nil(obs._episode)
        end)

        it("12 / 13 / 15 / 0 / 1 / 3: a note and a wait", function()
            for _, c in ipairs({
                { 12, "another loomworks data dir" }, { 13, "runs on another host" },
                { 15, "internal error (protocol)" }, { 0, "kept its standard input open" },
                { 1, "internal error" }, { 3, "update the pin" }, { 99, "status 99" },
            }) do
                obs = attach({ manual = true })
                exit(c[1], { line = "lw: detail " .. c[1] })
                assert.same({ "ordinary" }, fr.spawns)
                assert.equals("waiting", obs.state)
                assert.truthy(obs:runtime_line():find(c[2], 1, true), obs:runtime_line())
                assert.truthy(obs:runtime_line():find("(lw: detail " .. c[1] .. ")", 1, true), obs:runtime_line())
                obs:stop(); obs = nil
            end
        end)

        it("2 from a relay given the editor's flags names the pinned version", function()
            local f = assert(io.open(root .. "/lw.pin", "w"))
            f:write("version = 0.1.40\n")
            f:close()
            obs = attach({ manual = true })
            -- An ordinary relay's 2: the plain internal-error note.
            exit(2, { line = "lw: --stdio needs --root <dir>" })
            assert.truthy(obs:runtime_line():find("internal error (usage)", 1, true), obs:runtime_line())
            -- A no-launch relay's 2 (spawned after a drop).
            obs:_spawn({ form = "no-launch" })
            exit(2, { line = "lw: unknown option --no-launch" })
            assert.truthy(obs:runtime_line():find("the pinned lw 0.1.40 does not support the editor relay flags", 1,
                true), obs:runtime_line())
            assert.truthy(obs:runtime_line():find("(lw: unknown option --no-launch)", 1, true), obs:runtime_line())
            assert.equals(2, #fr.spawns)
        end)

        it("a relay the editor ended is not mapped; connect replaces a waiting relay, not an ordinary one", function()
            obs = attach({ manual = true })
            local first = fr.last()
            obs:start(true)
            assert.equals(1, #fr.spawns)
            -- A waiting (no-launch) relay is replaced by an explicit connect.
            obs:_end_relay()
            assert.is_true(first.ended)
            first.exit(0) -- (ended: never reported)
            obs:_spawn({ form = "no-launch" })
            local waiting = fr.last()
            obs:start(true)
            assert.is_true(waiting.ended)
            assert.same({ "ordinary", "no-launch", "ordinary" }, fr.spawns)
            -- The stop ends the relay in flight.
            local last = fr.last()
            obs:stop()
            assert.is_true(last.ended)
            assert.equals(0, fr.running())
        end)
    end)

    describe("pre-launch probe (step 5h.5)", function()
        local binsel = require("loomworks.provision.select")
        local bad = { verdict = "incompatible", problems = { "transport 2..3 does not overlap ours" }, degraded = {} }

        --- An observer over the real selection with PATH /p/lw, managed /m/lw
        --- (and LOOMWORKS_LW when `explicit`); probes complete on `finish()`.
        local function probing(verdict, explicit, backstop_ms)
            local cache, t = {}, { probes = {}, spawned = {} }
            obs = attach({ probe_backstop_ms = backstop_ms,
                probe_cached = function(p) return cache[p] end,
                run_probe = function(p, _, cb)
                    t.probes[#t.probes + 1] = p
                    t.finish = function() cache[p] = verdict; cb(verdict) end
                end,
                resolve = function(root, o)
                    return binsel.resolve(root, vim.tbl_extend("force", o, { win = false,
                        getenv = function(n) return explicit and n == "LOOMWORKS_LW" and "/e/lw" or nil end,
                        exists = function() return true end,
                        on_path = function() return "/p/lw" end,
                        managed = function() return "/m/lw" end }))
                end,
                relay = function(ro) t.spawned[#t.spawned + 1] = ro.argv[1]; return { close = function() end } end })
            return t
        end

        it("probes an lw on PATH before spawning a relay; an incompatible one falls through to the managed lw", function()
            local t = probing(bad)
            assert.equals("probing", obs.state)
            assert.same({ "/p/lw" }, t.probes)
            assert.truthy(obs:runtime_line():find("checking /p/lw (lw version --json)", 1, true), obs:runtime_line())
            obs:start(false) -- a second start while probing starts no second probe
            assert.equals(1, #t.probes)
            t.finish()
            assert.same({ "/m/lw" }, t.spawned)
            assert.equals("managed", obs.selection.source)
            assert.truthy(obs:runtime_line():find("lw on PATH (/p/lw) is too old/incompatible", 1, true),
                obs:runtime_line())
        end)

        it("uses an lw on PATH whose verdict is unknown (the handshake decides)", function()
            local t = probing({ verdict = "unknown", problems = { "timeout" }, degraded = {} })
            t.finish()
            assert.same({ "/p/lw" }, t.spawned)
            assert.is_nil(obs.probe_note)
        end)

        it("never replaces an explicit lw: an incompatible verdict is only noted", function()
            local t = probing(bad, true)
            assert.same({ "/e/lw" }, t.probes)
            t.finish()
            assert.same({ "/e/lw" }, t.spawned)
            assert.truthy(obs:runtime_line():find("LOOMWORKS_LW /e/lw is incompatible", 1, true), obs:runtime_line())
        end)

        it("a probe that ends after a stop is ignored", function()
            local t = probing(bad)
            obs:stop()
            t.finish()
            assert.same({}, t.spawned)
            assert.equals("stopped", obs.state)
        end)

        it("a probe that never calls back ends as unknown after the backstop; a late callback is ignored", function()
            local t = probing(bad, false, 50)
            assert.equals("probing", obs.state)
            assert.is_true(vim.wait(2000, function() return obs.state ~= "probing" end, 10))
            assert.is_nil(obs._probing); assert.is_nil(obs._probe_backstop)
            assert.same({ "/p/lw" }, t.spawned) -- launched as unknown: the handshake decides
            t.finish() -- the late (incompatible) callback changes nothing
            assert.same({ "/p/lw" }, t.spawned)
            assert.equals(1, #t.probes)
        end)
    end)

    it("downloads a wanted plugin-managed lw first, then spawns the relay from it, pruning nothing (step 5h.3)", function()
        local want = { sha256 = string.rep("ab", 32), version = "0.1.50", asset = "lw-linux-x86_64" }
        local installed, fetches, pending, spawned, pruned = false, 0, nil, nil, nil
        -- Pruning the other managed binaries is paused (samienne/loomworks#101):
        -- the protocol does not name the binaries live daemons run.
        local cache = require("loomworks.provision.cache")
        local real_prune = cache.prune
        cache.prune = function(o) pruned = o end
        obs = attach({ binary = { release_url = "/mirror" },
            resolve = function()
                if installed then
                    return "/m/lw", "managed", { path = "/m/lw", source = "managed", label = "plugin-managed lw",
                        candidates = {} }
                end
                return nil, nil, { source = "managed", label = "plugin-managed lw", download = want, candidates = {} }
            end,
            fetch = function(w, o, cb)
                fetches = fetches + 1
                assert.equals(want, w)
                assert.equals("/mirror", o.release_url)
                pending = cb
                return { url = "/mirror/lw-linux-x86_64" }
            end,
            inspect = function() return { kind = "none" } end,
            relay = function(o) spawned = o; return { close = function() end } end })
        assert.equals("downloading", obs.state)
        assert.truthy(obs:runtime_line():find("downloading the plugin-managed lw v0.1.50 (lw-linux-x86_64) from "
            .. "/mirror/lw-linux-x86_64", 1, true), obs:runtime_line())
        -- A plain start while downloading starts no second download.
        obs:start(false)
        assert.equals(1, fetches)
        installed = true
        pending("/m/lw")
        assert.equals("connecting", obs.state)
        assert.same({ "/m/lw" }, spawned.argv)
        cache.prune = real_prune
        assert.is_nil(pruned)
    end)

    it("connect aborts a download in flight and starts over; a stop aborts it; a late callback is ignored", function()
        local want = { sha256 = string.rep("ef", 32), version = "0.1.50", asset = "lw-linux-x86_64" }
        local cbs, cancelled = {}, {}
        obs = attach({
            resolve = function()
                return nil, nil, { source = "managed", label = "plugin-managed lw", download = want, candidates = {} }
            end,
            fetch = function(_, _, cb) cbs[#cbs + 1] = cb; return { url = "u" } end,
            cancel_fetch = function(sha, why) cancelled[#cancelled + 1] = { sha, why } end,
            relay = function() error("must not spawn a relay") end })
        assert.equals("downloading", obs.state)
        obs:start(true)
        assert.equals(2, #cbs)
        assert.same({ { want.sha256, "restarted by :LoomworksDaemon connect" } }, cancelled)
        assert.equals("downloading", obs.state)
        cbs[1](nil, "cancelled") -- the aborted download reports: ignored
        assert.equals("downloading", obs.state)
        assert.equals(want.sha256, obs._downloading)
        obs:stop()
        assert.equals(2, #cancelled)
        assert.equals(want.sha256, cancelled[2][1])
    end)

    it("a failed download is one note, leaves the editor in-process and is retried only on connect", function()
        local want = { sha256 = string.rep("cd", 32), version = "0.1.50", asset = "lw-linux-x86_64" }
        local fetches = 0
        obs = attach({
            resolve = function()
                return nil, nil, { source = "managed", label = "plugin-managed lw", download = want, candidates = {} }
            end,
            fetch = function(_, _, cb)
                fetches = fetches + 1
                vim.schedule(function() cb(nil, "has SHA-256 00, expected " .. want.sha256) end)
                return { url = "u" }
            end,
            relay = function() error("must not spawn a relay") end })
        assert.is_true(vim.wait(2000, function() return obs.state == "no-binary" end, 10), obs:runtime_line())
        assert.truthy(obs:runtime_line():find("could not install the plugin-managed lw v0.1.50", 1, true))
        assert.truthy(obs:runtime_line():find("running degraded", 1, true))
        vim.wait(200) -- nothing retries by itself
        assert.equals(1, fetches)
        obs:start(false)
        assert.equals(1, fetches)
        obs:start(true)
        assert.equals(2, fetches)
    end)

    -- A fake daemon world for the relay's follow-ups: inspect says what is on
    -- disk, connect hands back a conn whose close reports the drop; its
    -- `welcome` says `retiring` while `f.retiring`; an ordinary relay that
    -- finds none launches `f.next`.
    local function fake_daemon()
        local f = { st = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "e" } },
            connects = 0 }
        f.opts = { inspect = function() return f.st end,
            launch = function() f.st = f.next or { kind = "starting" } end,
            connect = function(_, copts, cb)
                f.connects = f.connects + 1
                local conn = { challenge = { protocol = version.PROTOCOL,
                    lw_version = "0.1.0" }, welcome = { seq = 0, retiring = f.retiring } }
                function conn.close(c)
                    if c.closed then return end
                    c.closed = true
                    if c.on_close then c.on_close(c) end
                end
                function conn.request(_, _, rcb) rcb({}) end
                conn.on_close = copts.on_close
                if not f.retiring then f.conn = conn end
                cb(conn)
            end }
        return f
    end

    it("connecting to a daemon marks its binary used (a managed slot is not pruned while used)", function()
        local f = fake_daemon()
        f.st.handle.exe = "/d/loomworks/lw/x/lw"
        local touched
        f.opts.touch = function(p) touched = p end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals("/d/loomworks/lw/x/lw", touched)
    end)

    it("after `retiring`, the ordinary relay waits the daemon out, launches its successor and connects", function()
        local f = fake_daemon()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(0, fr.launched)
        -- Retiring (a version change): the observer disconnects; one
        -- ordinary relay follows it.
        f.retiring = true
        obs:_on_message({ kind = "signal", object = "/", iface = "loomworks.Root", v = 1, name = "retiring", args = {} })
        assert.is_true(vim.wait(5000, function() return #fr.spawns == 2 end, 10), obs:runtime_line())
        assert.same({ "ordinary", "ordinary" }, fr.spawns)
        vim.wait(200)
        assert.is_nil(obs.conn)
        assert.equals(0, fr.launched)
        -- The retired daemon exits: that relay launches the successor, and
        -- the editor connects to it.
        f.retiring = nil
        f.next = { kind = "live", handle = { pid = 4343, start_time = "u", endpoint = "e" } }
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(4343, obs.daemon.pid)
        assert.equals(1, fr.launched)
        assert.equals(2, #fr.spawns)
        assert.is_nil(obs._episode) -- the welcome ended the episode
    end)

    it("a daemon stopped by the user (no retirement) is followed by a no-launch relay, never relaunched", function()
        local f = fake_daemon()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        f.st = { kind = "none" }
        f.conn:close() -- `lw daemon stop`: the connection just drops
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        assert.truthy(obs:runtime_line():find("disconnected", 1, true), obs:runtime_line())
        vim.wait(400)
        assert.same({ "ordinary", "no-launch" }, fr.spawns)
        assert.equals(0, fr.launched)
        -- A daemon another client starts later is connected to.
        f.st = { kind = "live", handle = { pid = 4545, start_time = "v", endpoint = "e" } }
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(4545, obs.daemon.pid)
        assert.equals(0, fr.launched)
    end)

    it("a `welcome` without `via` (an older pin's attached --stdio) is observed without the check, never retired", function()
        local asked = {}
        obs = attach({ relay = function(ro, cb)
            asked[#asked + 1] = ro
            vim.schedule(function()
                local conn = { challenge = {}, welcome = { seq = 0 }, closed = false }
                function conn.close(c) c.closed = true end
                function conn.request(_, _, rcb) rcb({}) end
                cb(conn)
            end)
            return { close = function() end }
        end })
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.is_nil(obs._retire)
    end)

    it("a `retiring` with no connection does not mark the next drop as a retirement", function()
        obs = attach({ inspect = function() return { kind = "hung", lock = { pid = 5 } } end, manual = true })
        obs:_on_message({ kind = "signal", object = "/", iface = "loomworks.Root", v = 1, name = "retiring", args = {} })
        assert.is_nil(obs._retired_note)
    end)

    it("ignores a `Workspace.changed` whose revision is at or below the current one", function()
        obs = attach({ inspect = function() return { kind = "hung", lock = { pid = 5 } } end, manual = true })
        local fetched = 0
        obs._lsp_read = true
        obs._fetch_lsp = function() fetched = fetched + 1 end
        local function changed(revision)
            obs:_on_message({ kind = "signal", object = "/workspace", iface = "loomworks.Workspace", v = 1,
                name = "changed", args = { revision = revision } })
        end
        changed(5)
        assert.equals(1, fetched)
        assert.equals(5, obs.seq)
        changed(5) -- the same revision again
        changed(3) -- an older one
        assert.equals(1, fetched)
        assert.equals(5, obs.seq)
        changed(6)
        assert.equals(2, fetched)
        assert.equals(6, obs.seq)
    end)

    it("shutdown stops the observer and closes its connection", function()
        W = new_world({ root = ws.root })
        obs = attach()
        connected()
        local o = obs
        require("loomworks").shutdown()
        assert.equals("stopped", o.state)
        assert.is_true(vim.wait(5000, function() return W.observer_count() == 0 end, 10))
        -- Its relay ended with it (the connection closed through it).
        assert.equals(0, fr.running())
        obs = nil
    end)
end)

describe("remote task output cap (§19.16)", function()
    it("keeps about 1 MiB, then one truncation notice", function()
        local t = remote_task.new(1, { name = "x" }, 0)
        local chunk = string.rep("a", 64 * 1024)
        for _ = 1, 20 do t:append(chunk) end
        local out = t:output()
        assert.is_true(#out <= remote_task.OUTPUT_CAP_BYTES + 200)
        assert.truthy(out:find("truncated", 1, true))
    end)
end)

describe("status page Tasks section: remote tasks (spec/plugin.md UI §1.9)", function()
    local function render(remote)
        local rows = {}
        local tree = {
            leaf = function() end, blank = function() end,
            item = function(_, label, opts) rows[#rows + 1] = { label = label, opts = opts } end,
        }
        require("loomworks.ui.sections.tasks")(tree, { lw = {
            get_daemon_tasks = function() return remote end,
        } })
        return rows
    end
    local function text(label)
        if type(label) == "string" then return label end
        local t = {}
        for _, c in ipairs(label) do t[#t + 1] = c[1] end
        return table.concat(t)
    end
    local function now() return (vim.uv or vim.loop).hrtime() / 1e9 end

    it("one row per unit by name, the dim origin marker last", function()
        local t = remote_task.new(7, { name = "dev", kind = "build", profile = "dev", origin = "cli" }, now())
        t.units = { { project = "app", configuration = "Debug" },
            { project = "ghost", configuration = "Nope" } }
        t.pct = 40
        local rows = render({ t })
        assert.truthy(text(rows[1].label):find("^▸ app : Debug — build  40%%  %d+s  lw$"), text(rows[1].label))
        assert.truthy(text(rows[2].label):find("^▸ ghost : Nope — build"), text(rows[2].label))
        assert.same({ "  lw", "Comment" }, rows[1].label[#rows[1].label])
        local e = remote_task.new(8, { name = "p", kind = "test", profile = "p", origin = "editor" }, now())
        local erow = text(render({ e })[1].label)
        assert.truthy(erow:find("^▸ p — test  %d+s  editor$"), erow)
    end)

    it("orders tasks by start; Enter on another client's row offers Show output only", function()
        local n = now()
        local early = remote_task.new(1, { name = "dev", kind = "build", profile = "dev", origin = "cli" }, n - 100)
        local late = remote_task.new(2, { name = "rel", kind = "build", profile = "rel", origin = "cli" }, n - 1)
        local rows = render({ late, early })
        assert.truthy(text(rows[1].label):find("dev", 1, true))
        assert.truthy(text(rows[2].label):find("rel", 1, true))
        local offered
        local real = vim.ui.select
        vim.ui.select = function(items) offered = items end
        rows[1].opts.on_enter()
        vim.ui.select = real
        assert.same({ "Show output" }, offered)
    end)
end)

-- A refused reply to an owned call keeps the refusal's stream and notes: a
-- confirmed deletion that finds nothing to delete is reported as INFO, not
-- as an error (ui/actions.confirm_deletion).
describe("observer: start_owned refusal", function()
    it("passes the refusal's stream and notes through", function()
        local obs = setmetatable({ conn = {}, _owned = {} }, { __index = observer.Observer })
        function obs:_icall(_, _, cb)
            cb({ outcome = "refused", message = "nothing to delete", stream = "out", exit_code = 0,
                notes = { "n" }, note_roles = { "info" } })
        end
        local got
        obs:start_owned("Maintenance/1.execute_deletion", {}, {
            on_reply = function(r) got = r end,
            on_done = function() error("no task ran") end,
        })
        vim.wait(1000, function() return got ~= nil end)
        assert.same({ outcome = "refused", message = "nothing to delete", stream = "out",
            notes = { "n" }, note_roles = { "info" } }, got)
    end)
end)

-- Step 6b-alpha (spec §19.16 "End state"): in `daemon` mode the editor loads
-- no workspace model of its own; it attaches the observer by root.
describe("the editor's load (step 6b-alpha)", function()
    local lw, root, orig_attach, attached
    before_each(function()
        lw = require("loomworks")
        root = H.shell_workspace({ profile = true })
        orig_attach, attached = observer.attach, {}
        observer.attach = function(r, o)
            attached[#attached + 1] = { root = r, opts = o }
            return nil
        end
    end)
    after_each(function()
        observer.attach = orig_attach
        lw.shutdown()
    end)

    it("attaches by the root's real path", function()
        lw._load(root)
        assert.equals(1, #attached)
        assert.equals(lw.workspace_root(), attached[1].root)
        assert.equals(vim.fs.normalize(vim.uv.fs_realpath(root)), attached[1].root)
    end)
end)
