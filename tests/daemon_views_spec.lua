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
