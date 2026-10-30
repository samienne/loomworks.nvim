-- The editor views (spec §19.13 "Views", step 5j part B): the shared builder
-- (loomworks.view_state, both sources) and the daemon's `/views` updates
-- (loomworks.daemon.views): full state, only on a change per subscription,
-- before the acknowledgement of the segment that changed it.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local view_state = require("loomworks.view_state")
local views = require("loomworks.daemon.views")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local H = require("tests.daemon_helpers")

--- A model stand-in: projects `app` (cmake, mapped by the active profile,
--- with a unit), `lib` (no declared path, mapped, no unit yet) and `odd`
--- (an unknown type: no module).
local function fake_ws(root)
    local unit = { key = "unit" }
    local tool = { key = "ninja-gcc" }
    local pps = {
        app = { _config_unit = unit, variant_name = function() return "Debug" end,
            status = function() return "built" end, tool_object = function() return tool end },
        lib = { variant_name = function() return "Release" end,
            status = function() return "unconfigured" end, tool_object = function() return nil end },
    }
    local cs = { name = "dev-set" }
    local profile = { key = "dev", _config_set_ref = cs, project = function(_, k) return pps[k] end }
    return {
        name = "ws", root = root, _active_profile = profile,
        _projects = {
            { key = "odd", type = "rust", path = "odd" },
            { key = "lib", type = "meson", _module = {} },
            { key = "app", type = "cmake", path = "src/app", _module = {} },
        },
        diagnostics = function() return { { severity = "warn" } } end,
        _unit = unit, _profile = profile, _cs = cs, _pps = pps,
    }
end

local function ids()
    local n, by = 0, {}
    return function(obj)
        if not by[obj] then n = n + 1; by[obj] = "id" .. n end
        return by[obj]
    end
end

describe("view_state (§19.13 Views, two sources one shape)", function()
    it("builds the project index ordered by key, with paths, active records and ids", function()
        local ws = fake_ws("C:\\w\\root")
        local idx = view_state.projects_index(ws, { id = ids() })
        local keys = {}
        for _, r in ipairs(idx.projects) do keys[#keys + 1] = r.key end
        assert.same({ "app", "lib", "odd" }, keys)
        local app, lib, odd = idx.projects[1], idx.projects[2], idx.projects[3]
        assert.equals("src/app", app.path)
        assert.equals("C:/w/root/src/app", app.abs_path)
        assert.equals("app", app.label)
        assert.equals("cmake", app.type)
        assert.is_string(app.id)
        assert.same({ configuration = "Debug", state = "built", tool_key = "ninja-gcc", unit_id = app.active.unit_id },
            app.active)
        assert.is_string(app.active.unit_id)
        -- No declared path: the key; no unit yet: unconfigured, no unit_id.
        assert.equals("lib", lib.path)
        assert.same({ configuration = "Release", state = "unconfigured" }, lib.active)
        -- An unknown type: listed with its declared type, without `active`.
        assert.equals("rust", odd.type)
        assert.is_nil(odd.active)
    end)

    it("leaves every id out in-process and lists nothing when not loaded", function()
        local idx = view_state.projects_index(fake_ws("/r"))
        for _, r in ipairs(idx.projects) do
            assert.is_nil(r.id)
            if r.active then assert.is_nil(r.active.unit_id) end
        end
        assert.same({ projects = {} }, view_state.projects_index(nil))
    end)

    it("omits `active` with no active profile", function()
        local ws = fake_ws("/r")
        ws._active_profile = nil
        for _, r in ipairs(view_state.projects_index(ws).projects) do assert.is_nil(r.active) end
    end)

    it("builds the header: active profile and its set, ids only from the daemon, diagnostics", function()
        local ws = fake_ws("/r")
        local h = view_state.header(ws, nil, { root = "/r", id = ids(),
            session = { pid = 7, lw_version = "v", session_generation = 3 } })
        assert.equals("loaded", h.state)
        assert.equals("dev", h.active_profile)
        assert.equals("dev-set", h.config_set)
        assert.is_string(h.active_profile_id)
        assert.is_string(h.config_set_id)
        assert.equals("warn", h.diagnostics)
        assert.equals(7, h.pid)
        local p = view_state.header(ws, nil)
        assert.equals("/r", p.root)
        assert.is_nil(p.active_profile_id)
        assert.is_nil(p.config_set_id)
        assert.is_nil(p.pid)
        assert.is_nil(p.session_generation)
        ws.diagnostics = function() return { { severity = "warn" }, { severity = "error" } } end
        assert.equals("error", view_state.header(ws, nil).diagnostics)
    end)

    it("names the active profile and its set only when they resolve, so ids always come with them", function()
        -- A dangling active key (no live profile object): no profile, no set.
        local ws = fake_ws("/r")
        ws._active_profile = nil
        ws._active_profile_key = "gone"
        local h = view_state.header(ws, nil, { id = ids() })
        assert.equals("loaded", h.state)
        assert.is_nil(h.active_profile)
        assert.is_nil(h.active_profile_id)
        assert.is_nil(h.config_set)
        assert.is_nil(h.config_set_id)
        -- Workspace/1.header keeps its own fallback (unchanged by the view).
        assert.equals("gone", view_state.base_header(ws, nil).active_profile)
        -- A removed profile object: the same.
        ws = fake_ws("/r")
        ws._profile._removed = true
        h = view_state.header(ws, nil, { id = ids() })
        assert.is_nil(h.active_profile)
        assert.is_nil(h.active_profile_id)
        assert.is_nil(h.config_set)
        -- A profile whose configuration set does not resolve: no set, no set id.
        for _, broken in ipairs({ "missing", "removed" }) do
            ws = fake_ws("/r")
            if broken == "missing" then ws._profile._config_set_ref = nil else ws._cs._removed = true end
            ws._profile._configuration_set_name = "dev-set"
            h = view_state.header(ws, nil, { id = ids() })
            assert.equals("dev", h.active_profile)
            assert.is_string(h.active_profile_id)
            assert.is_nil(h.config_set)
            assert.is_nil(h.config_set_id)
        end
    end)

    it("treats a removed unit as no unit: no unit_id, state unconfigured", function()
        local ws = fake_ws("/r")
        ws._unit._removed = true
        local app = view_state.projects_index(ws, { id = ids() }).projects[1]
        assert.equals("app", app.key)
        assert.same({ configuration = "Debug", state = "unconfigured", tool_key = "ninja-gcc" }, app.active)
    end)

    it("reports a trust refusal's file,and nothing of a profile when not loaded", function()
        local h = view_state.header(nil, { message = "refused", refused = true, trust = "user" }, { root = "/r" })
        assert.same({ root = "/r", state = "refused", error = "refused", trust = "user" }, h)
        local n = view_state.header(nil, { message = "newer", refused = true }, { root = "/r" })
        assert.is_nil(n.trust)
        assert.same({ root = "/r", state = "unloaded" }, view_state.header(nil, nil, { root = "/r" }))
        -- The builder's caller supplies the running version (§19.13 `version`).
        assert.same({ root = "/r", state = "unloaded", version = "0.1.43" },
            view_state.header(nil, nil, { root = "/r", version = "0.1.43" }))
    end)

    it("signs equal states equally whatever their construction order", function()
        assert.equals(view_state.signature({ a = 1, b = { c = "x" } }), view_state.signature({ b = { c = "x" }, a = 1 }))
        assert.are_not.equal(view_state.signature({ a = 1 }), view_state.signature({ a = "1" }))
    end)
end)

describe("daemon /views (§19.13 Views)", function()
    local srv, svc, sent, conn, ws

    before_each(function()
        local root = H.workspace()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, log = function() end })
        srv:registry()
        svc = service.attach(srv, { load = function() end, unload = function() end,
            current = function() return ws end })
        sent = {}
        conn = { authed = true, transport = 11 }
        srv._send = function(_, c, frame) if c == conn then sent[#sent + 1] = frame end end
    end)

    after_each(function()
        ws = nil
        if srv and not srv.stopped then pcall(srv.stop, srv, "test end", 0) end
    end)

    local function subscribe(where)
        local reg = srv.interfaces
        local root = reg:resolve("/", "loomworks.Root", 1)
        local r = assert(root.impl.methods.subscribe({ registry = reg, server = srv, conn = conn },
            { object = where.path, iface = where.iface, v = where.v }))
        return r
    end

    local function updates()
        local out = {}
        for _, f in ipairs(sent) do
            if f.kind == "signal" and f.name == "update" then out[#out + 1] = f end
        end
        return out
    end

    it("mounts both views on /views, the initial state baselining the subscription", function()
        local h = subscribe(views.HEADER)
        local p = subscribe(views.PROJECTS)
        assert.equals("unloaded", h.initial.state)
        -- The daemon's running version survives the schema's shaping.
        assert.is_truthy(require("loomworks.save_guard").version())
        assert.equals(require("loomworks.save_guard").version(), h.initial.version)
        assert.same({}, p.initial.projects)
        views.check(svc)
        assert.equals(0, #updates())
    end)

    it("sends the full state once per change, before the acknowledgement of the segment", function()
        subscribe(views.HEADER)
        subscribe(views.PROJECTS)
        ws = fake_ws(srv.root)
        svc.ws = ws
        local ctx = {}
        svc.current = ctx
        svc:_before_ack(ctx)
        local u = updates()
        assert.equals(2, #u)
        assert.equals("loomworks.view.Header", u[1].iface)
        assert.equals("dev", u[1].args.active_profile)
        assert.is_string(u[1].args.active_profile_id)
        assert.equals("loomworks.view.ProjectsIndex", u[2].iface)
        assert.equals(3, #u[2].args.projects)
        -- Unchanged: none; outside the segment: none either.
        views.check(svc)
        svc:_before_ack({})
        assert.equals(2, #updates())
        -- A unit's state change: the index only, with the whole state.
        ws._pps.app.status = function() return "building" end
        views.check(svc)
        u = updates()
        assert.equals(3, #u)
        assert.equals("loomworks.view.ProjectsIndex", u[3].iface)
        assert.equals(3, #u[3].args.projects)
        assert.equals("building", u[3].args.projects[1].active.state)
        svc.current = nil
    end)

    it("writes the view update before the request's acknowledgement on the real reply path (D8)", function()
        subscribe(views.HEADER)
        ws = fake_ws(srv.root)
        ws._active_profile = nil
        svc.ws = ws
        sent = {}
        -- A model request whose segment changes the header, answered through
        -- ctx.reply -> Server:_send (the loopback stand-in records frame order).
        svc:_on_model_request(conn, { kind = "query", req_id = 42, env = { PATH = "/bin" } }, function(w)
            w._active_profile = w._profile
            return {}
        end)
        assert.is_true(vim.wait(2000, function()
            for _, f in ipairs(sent) do if f.req_id == 42 then return true end end
            return false
        end, 10))
        local upd, ack
        for i, f in ipairs(sent) do
            if not upd and f.kind == "signal" and f.name == "update" and f.args.active_profile == "dev" then upd = i end
            if f.req_id == 42 then ack = ack or i end
        end
        assert.is_number(upd)
        assert.is_number(ack)
        assert.equals("ok", sent[ack].kind)
        assert.is_true(upd < ack, "the update must be written before the acknowledgement")
    end)
end)

describe("daemon view.Workspace/1 (§19.13 The workspace view)", function()
    local uv = vim.uv or vim.loop
    local trust = require("loomworks.trust")
    _G.LW_CONFORMANCE_LIB = true
    local runner = dofile(H.REPO .. "/scripts/conformance.lua")
    local s

    --- A loopback daemon on a fresh `shell` fixture, handshaken, subscribed
    --- to the workspace view (`s.initial` its initial state).
    local function session()
        local key = (vim.fn.tempname():gsub("\\", "/")) .. "/trust.key"
        vim.fn.mkdir(vim.fn.fnamemodify(key, ":h"), "p")
        local root = runner.fixture("shell", key)
        trust._set_key_path(key)
        local d = runner.loopback_driver(root)
        local o = { d = d, root = root, env = runner.wire_env(uv.os_environ()), inbox = {}, req = 0 }
        function o.wait(pred, ms)
            local deadline = uv.now() + (ms or 30000)
            while true do
                for i, f in ipairs(o.inbox) do
                    if pred(f) then table.remove(o.inbox, i); return f end
                end
                local left = deadline - uv.now()
                assert(left > 0, "timed out waiting for a frame")
                local f = d.recv(math.min(left, 50))
                if f then o.inbox[#o.inbox + 1] = f end
            end
        end
        --- Every frame that arrives within `ms`, into the inbox.
        function o.drain(ms)
            local deadline = uv.now() + ms
            while uv.now() < deadline do
                local f = d.recv(math.max(1, math.min(50, deadline - uv.now())))
                if f then o.inbox[#o.inbox + 1] = f end
            end
        end
        function o.call(object, iface, method, args, env)
            o.req = o.req + 1
            local id = o.req
            assert(d.send({ kind = "call", req_id = id, object = object, iface = iface, v = 1, method = method,
                args = args or vim.empty_dict(), env = env }))
            local f = o.wait(function(m) return m.req_id == id end)
            assert.equals("ok", f.kind, vim.inspect(f))
            return f.result
        end
        --- The workspace view's `update`s received so far (taken out of the inbox).
        function o.updates()
            local out, keep = {}, {}
            for _, f in ipairs(o.inbox) do
                if f.kind == "signal" and f.iface == "loomworks.view.Workspace" and f.name == "update" then
                    out[#out + 1] = f.args
                else
                    keep[#keep + 1] = f
                end
            end
            o.inbox = keep
            return out
        end
        function o.view() return o.call("/views", "loomworks.view.Workspace", "get") end
        function o.load() o.call("/toolchains", "loomworks.Toolchains", "list", nil, o.env) end
        function o.build()
            local r = o.call("/build", "loomworks.Build", "build", { profile = { key = "dev" } }, o.env)
            assert.equals("accepted", r.outcome, vim.inspect(r))
            local f = o.wait(function(m) return m.kind == "task" and m.task_id == r.task_id and m.phase == "done" end,
                120000)
            assert.equals(0, f.exit_code)
        end
        function o.close()
            pcall(d.close)
            trust._set_key_path(nil)
        end
        assert(d.send({ kind = "hello", protocol = 11, client = "editor",
            lw_version = require("loomworks.daemon.version").identity() }))
        o.wait(function(m) return m.kind == "welcome" end)
        o.initial = o.call("/", "loomworks.Root", "subscribe", { object = "/views",
            iface = "loomworks.view.Workspace", v = 1, signals = { "update" } }).initial
        return o
    end

    after_each(function()
        if s then s.close(); s = nil end
    end)

    local function profile(v, key)
        for _, p in ipairs(v.profiles) do if p.key == key then return p end end
    end

    it("is empty before the load; a load sends one update, with the daemon's ids", function()
        s = session()
        assert.same({}, s.initial.profiles)
        assert.same({}, s.initial.projects)
        assert.same({}, s.view().profiles)
        s.load()
        s.drain(200)
        local u = s.updates()
        assert.equals(1, #u)
        local v = u[1]
        local p = assert(profile(v, "dev"))
        assert.is_string(p.id)
        assert.is_string(v.config_sets[1].id)
        -- The profile names its set by id; each mapping names its project
        -- and configuration by the ids their rows carry.
        local set
        for _, cs in ipairs(v.config_sets) do if cs.name == p.config_set then set = cs end end
        assert.equals(set.id, p.config_set_id)
        local ids = {}
        for _, proj in ipairs(v.projects) do
            assert.is_string(proj.id)
            ids[proj.id] = {}
            for _, c in ipairs(proj.configurations or {}) do assert.is_string(c.id); ids[proj.id][c.id] = true end
        end
        assert.is_true(#set.mappings > 0)
        for _, m in ipairs(set.mappings) do
            assert.is_false(m.missing)
            assert.is_true(ids[m.project.id][m.configuration.id], vim.inspect(m))
        end
        -- The same objects, the same ids; nothing changed: no update.
        local again = s.view()
        assert.equals(p.id, profile(again, "dev").id)
        assert.same(v, again)
        s.load()
        s.drain(200)
        assert.equals(0, #s.updates())
    end)

    it("a build sends updates only on a change, without progress, ending with the last result", function()
        s = session()
        s.load()
        s.drain(200)
        s.updates()
        s.build()
        s.drain(300)
        local u = s.updates()
        assert.is_true(#u >= 1)
        for i, v in ipairs(u) do
            if i > 1 then
                assert.are_not.equal(view_state.signature(u[i - 1]), view_state.signature(v))
            end
            local p = profile(v, "dev")
            for _, k in ipairs({ "pct", "elapsed", "message" }) do assert.is_nil(p[k], k) end
            for _, unit in ipairs(p.units) do
                assert.is_nil(unit.progress)
                assert.is_nil(unit.elapsed)
            end
        end
        local p = profile(u[#u], "dev")
        assert.equals("built", p.units[1].state)
        assert.is_string(p.units[1].unit_id)
        assert.equals("ok", p.last_result.status)
        assert.truthy(p.last_result.message:find("^built in "), p.last_result.message)
        assert.same(p.last_result, profile(s.view(), "dev").last_result)
    end)

    it("reports a unit's artifact-conflict block on its row, from the daemon's gate without force (5o C2d)", function()
        s = session()
        s.load()
        s.drain(200)
        s.updates()
        local ws = assert(s.d.server.service.ws)
        local p0 = assert(profile(s.view(), "dev"))
        assert.is_string(p0.units[1].unit_id)
        for _, u in ipairs(p0.units) do assert.is_nil(u.artifact_block) end
        -- The §5.9 gate (Workspace:artifact_conflict_block) blocks the first
        -- unit: asked without force, its answer on that row only.
        local blocked = ws._profiles[1]:projects()[1]._config_unit
        local asked = {}
        ws.artifact_conflict_block = function(_, unit, force)
            asked[#asked + 1] = force
            if unit == blocked then return { unit = {}, profile = "rel", path = "/w/bin/app" } end
        end
        local ok, err = pcall(function()
            -- (A `get` checks the view again: the next view shows it.)
            local p = assert(profile(s.view(), "dev"))
            assert.same({ profile = "rel", path = "/w/bin/app" }, p.units[1].artifact_block)
            for i = 2, #p.units do assert.is_nil(p.units[i].artifact_block) end
            assert.is_true(#asked > 0)
            for _, f in ipairs(asked) do assert.is_false(f) end
        end)
        ws.artifact_conflict_block = nil
        assert(ok, err)
    end)

    --- Rewrite the working copy as another process would (signed, as an
    --- in-process editor writes it), changing it with `fn`.
    local function edit_user(fn)
        local path = s.root .. "/.nvim/loomworks.user.json"
        local f = assert(io.open(path, "rb"))
        local status, body = trust.verify("user", f:read("*a"))
        f:close()
        assert.equals("valid", status)
        local user = vim.json.decode(body)
        fn(user)
        local signed = assert(trust.sign("user", trust.encode(user)))
        f = assert(io.open(path, "wb"))
        f:write(signed)
        f:close()
    end

    it("reports a real artifact conflict between two built profiles on the unit rows; it follows the built state, not in-process (5o C2d)",
        function()
        s = session()
        s.load()
        s.drain(200)
        -- A second profile `rel` over the same project's Release: a distinct
        -- unit (its own build dir) whose artifact is the same path as dev's.
        edit_user(function(user)
            user.projects.app.shell.configurations.Release = vim.empty_dict()
            user.configuration_sets = user.configuration_sets or {}
            user.configuration_sets.rel = { app = "Release" }
            user.profiles.rel = { configuration_set = "rel" }
        end)
        assert(profile(s.view(), "rel"), "the rel profile")
        s.drain(200)
        s.updates()
        local ws = assert(s.d.server.service.ws)
        local shell = ws._core._deps.modules.get("shell")
        local shared = s.root .. "/out/app.bin"
        shell.resolve_artifacts = function() return { shared } end
        local function build(key)
            local r = s.call("/build", "loomworks.Build", "build", { profile = { key = key }, force = true }, s.env)
            assert.equals("accepted", r.outcome, vim.inspect(r))
            local f = s.wait(function(m) return m.kind == "task" and m.task_id == r.task_id and m.phase == "done" end,
                120000)
            assert.equals(0, f.exit_code)
        end
        local function block(v, key) return assert(profile(v, key)).units[1].artifact_block end
        local ok, err = pcall(function()
            build("dev")
            local v = s.view()
            assert.equals("built", profile(v, "dev").units[1].state)
            -- rel not built: no built artifact for either build to overwrite.
            assert.is_nil(block(v, "dev"))
            assert.is_nil(block(v, "rel"))
            -- rel builds over dev's artifact (forced): dev is overwritten, so
            -- a dev build now would overwrite rel's built artifact.
            build("rel")
            v = s.view()
            assert.same({ profile = "rel", path = shared }, block(v, "dev"))
            assert.is_nil(block(v, "rel"))
            -- The in-process status source's view has no artifact_block.
            local inproc = ws:view_workspace({ bind = require("loomworks.status_source").bind })
            for _, p in ipairs(inproc.profiles) do
                for _, u in ipairs(p.units) do assert.is_nil(u.artifact_block) end
            end
            -- dev builds again (forced): rel is overwritten now; an update
            -- carries dev's block cleared and rel's.
            s.updates()
            build("dev")
            s.wait(function(m)
                if m.kind == "signal" and m.iface == "loomworks.view.Workspace" and m.name == "update" then
                    local p = profile(m.args, "dev")
                    return p ~= nil and p.units[1].artifact_block == nil
                end
            end, 30000)
            v = s.view()
            assert.is_nil(block(v, "dev"))
            assert.same({ profile = "dev", path = shared }, block(v, "rel"))
        end)
        shell.resolve_artifacts = nil
        assert(ok, err)
    end)

    it("applies another process's working-copy write before a get, and the update follows (freshness)", function()
        s = session()
        s.load()
        s.drain(200)
        s.updates()
        local function launch(v, key)
            for _, l in ipairs(v.projects[1].launches) do if l.key == key then return l end end
        end
        assert.is_nil(launch(s.view(), "extra"))
        edit_user(function(user) user.projects.app.launch.extra = { command = "echo" } end)
        -- No request changed the model: the view's get checks the files first.
        assert.equals("echo", launch(s.view(), "extra").command)
        s.drain(200)
        local u = s.updates()
        assert.equals(1, #u)
        assert.is_table(launch(u[1], "extra"))
    end)

    it("leaves a loomworks.json change to the next request: a view check runs no tool detection", function()
        s = session()
        s.load()
        s.drain(200)
        s.updates()
        local svc = s.d.server.service
        local detections = 0
        local scan = svc.ws._scan_tools_async
        svc.ws._scan_tools_async = function(self, ...)
            detections = detections + 1
            return scan(self, ...)
        end
        local path = s.root .. "/loomworks.json"
        local f = assert(io.open(path, "rb"))
        local cfg = vim.json.decode(f:read("*a"))
        f:close()
        cfg.configuration_sets.more = { app = "Debug" }
        f = assert(io.open(path, "wb"))
        f:write(vim.json.encode(cfg))
        f:close()
        local v = s.view()
        assert.equals(0, detections)
        assert.equals(1, #v.config_sets)
        -- A state-changing request's sync applies it (and rescans tools).
        s.build()
        assert.equals(1, detections)
        assert.equals(2, #s.view().config_sets)
    end)

    it("leaves the files changed with a loomworks.json change to the next request too: never half-applied", function()
        s = session()
        s.load()
        s.drain(200)
        s.updates()
        local function launch(v, key)
            for _, l in ipairs(v.projects[1].launches) do if l.key == key then return l end end
        end
        local path = s.root .. "/loomworks.json"
        local f = assert(io.open(path, "rb"))
        local cfg = vim.json.decode(f:read("*a"))
        f:close()
        cfg.configuration_sets.more = { app = "Debug" }
        f = assert(io.open(path, "wb"))
        f:write(vim.json.encode(cfg))
        f:close()
        edit_user(function(user) user.projects.app.launch.extra = { command = "echo" } end)
        -- The view check applies neither file.
        local v = s.view()
        assert.equals(1, #v.config_sets)
        assert.is_nil(launch(v, "extra"))
        -- A state-changing request's sync applies both.
        s.build()
        v = s.view()
        assert.equals(2, #v.config_sets)
        assert.equals("echo", launch(v, "extra").command)
    end)
end)
