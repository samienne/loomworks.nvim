-- Scope snapshots, the client's read-only projection, the welcome header and
-- host-probing queries (spec §19.13, §19.14): an attached server with the
-- build service (the host is the CLI's own workspace load), loopback client
-- sessions, a real workspace on disk.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local snapshot = require("loomworks.daemon.snapshot")
local io_mod = require("loomworks.io")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 60000

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- A signed working copy with the `dev` profile active.
local function write_user(root)
    local user = { _meta = { version = 2 }, active_profile = "dev",
        profiles = { dev = { configuration_set = "dev" } } }
    local signed, serr = trust.sign("user", trust.encode(user))
    if not signed then error(serr) end
    write(root .. "/.nvim/loomworks.user.json", signed)
end

--- The daemon's live workspace.
local function daemon_ws() return require("loomworks")._core():get_workspace() end

describe("daemon snapshot and projection (§19.13, §19.14)", function()
    local root, srv, svc
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        write_user(root)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100 })
        svc = service.attach(srv, cli._daemon_build_host())
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("a projection serializes byte-identically to the daemon's model, scope by scope", function()
        local events = {}
        local conn = assert(client.loopback_session(srv, { on_message = function(m) events[#events + 1] = m end }))
        -- A build first, so the cache holds real build state.
        local done
        local reply = client.request(conn, { kind = "build", args = { profile = "dev" }, interactive = false,
            env = envscope.capture(), command = "lw build" })
        assert.equals("accepted", reply and reply.outcome, vim.inspect(reply))
        assert.is_true(vim.wait(60000, function()
            for _, m in ipairs(events) do if m.kind == "task" and m.phase == "done" then done = m end end
            return done ~= nil
        end, 10))
        assert.equals(0, done.exit_code)

        local snap = assert(snapshot.fetch(conn))
        assert.equals("ok", snap.outcome)
        assert.equals("all", snap.scope)
        assert.equals(srv.generation, snap.session_generation)
        assert.truthy(next(snap.cache.build_dirs), "the cache holds the build")
        local proj = assert(snapshot.project(root, snap))
        local dws = assert(daemon_ws())
        assert.are_not.equal(dws, proj)
        assert.equals(snapshot.READ_ONLY, proj._no_write)
        local enc = io_mod.encode_sorted
        -- The model's own serializations ...
        assert.equals(enc(dws:_serialize_user()), enc(proj:_serialize_user()))
        assert.equals(enc(dws:_serialize_cache()), enc(proj:_serialize_cache()))
        assert.equals(enc(dws:_serialize_config()), enc(proj:_serialize_config()))
        assert.equals(enc(dws._shared_baseline), enc(proj._shared_baseline))
        -- ... and each scope's snapshot, the projection's against the daemon's.
        local mine = snapshot.build(proj, "all", snapshot.registry())
        for _, scope in ipairs(snapshot.SCOPES) do
            local one = assert(snapshot.fetch(conn, { scope = scope }))
            assert.equals(scope, one.scope)
            assert.equals(enc(one[scope]), enc(mine[scope]), scope)
            for _, other in ipairs(snapshot.SCOPES) do
                if other ~= scope then assert.is_nil(one[other], scope .. " carries " .. other) end
            end
        end
        assert.equals(enc(snap.tools), enc(snapshot.tool_rows(proj._tools_by_type)))
        assert.equals("dev", proj._active_profile and proj._active_profile.key)
        conn:close()
    end)

    it("carries a current-key -> id index whose ids follow the objects across snapshots", function()
        local conn = assert(client.loopback_session(srv))
        local a = assert(snapshot.fetch(conn))
        local b = assert(snapshot.fetch(conn))
        assert.is_string(a.index.projects.app)
        assert.is_string(a.index.config_sets.dev)
        assert.is_string(a.index.profiles.dev)
        assert.same(a.index, b.index)
        -- Config units by structured key, not an internal formatted id.
        assert.is_true(#a.index.config_units > 0)
        for _, row in ipairs(a.index.config_units) do
            assert.is_string(row.project)
            assert.is_string(row.configuration)
        end
        local ids = {}
        local function seen(id)
            assert.is_string(id)
            assert.is_nil(ids[id], "an id is unique")
            ids[id] = true
        end
        for _, kind in ipairs({ "projects", "config_sets", "profiles" }) do
            for _, id in pairs(a.index[kind]) do seen(id) end
        end
        for _, row in ipairs(a.index.config_units) do seen(row.id) end
        conn:close()
    end)

    it("serves a loaded model as it is to another environment, and a query never unloads it", function()
        local conn = assert(client.loopback_session(srv))
        local a = assert(snapshot.fetch(conn))
        local dws = assert(daemon_ws())
        local user_before = read(root .. "/.nvim/loomworks.user.json")
        local cache_before = read(root .. "/.nvim/loomworks.cache.json")
        local other = envscope.capture()
        other.LW_TEST_ANOTHER_ENV = "1"
        local b = assert(snapshot.fetch(conn, { env = other }))
        assert.equals(dws, daemon_ws(), "the model was reloaded for a snapshot")
        assert.same(a.index, b.index)
        assert(snapshot.query(conn, "tools", {}, { env = other }))
        assert.equals(dws, daemon_ws(), "the model was reloaded for a query")
        local c = assert(snapshot.fetch(conn))
        assert.same(a.index, c.index)
        assert.equals(user_before, read(root .. "/.nvim/loomworks.user.json"))
        assert.equals(cache_before, read(root .. "/.nvim/loomworks.cache.json"))
        conn:close()
    end)

    it("a projection's events never reach the process's subscribers", function()
        local events = require("loomworks.events")
        local heard = 0
        local function on() heard = heard + 1 end
        for _, e in ipairs({ "workspace_changed", "active_set_changed", "workspace_initializing" }) do events.on(e, on) end
        local conn = assert(client.loopback_session(srv))
        local snap = assert(snapshot.fetch(conn))
        conn:close()
        heard = 0
        local proj = assert(snapshot.project(root, snap))
        proj._active_profile:activate()
        for _, e in ipairs({ "workspace_changed", "active_set_changed", "workspace_initializing" }) do events.off(e, on) end
        assert.equals(0, heard)
    end)

    it("profile_cache answers structured fields the CLI formats", function()
        local conn = assert(client.loopback_session(srv))
        assert(snapshot.fetch(conn))
        local pkey
        for _, pp in ipairs(daemon_ws()._active_profile:projects()) do pkey = pkey or pp:project_key() end
        local r = assert(snapshot.query(conn, "profile_cache", { profile = "dev", project = pkey }))
        assert.is_table(r.cache)
        assert.is_string(r.cache.policy)
        assert.is_nil(r.cache.text)
        local text = require("loomworks.profile").compiler_cache_text(r.cache)
        local st = daemon_ws()._active_profile:compiler_cache_status()
        assert.equals(st.text, text)
        conn:close()
    end)

    it("refuses an unknown scope as malformed", function()
        local conn = assert(client.loopback_session(srv))
        local snap, err = snapshot.fetch(conn, { scope = "everything" })
        assert.is_nil(snap)
        assert.equals("malformed request", err)
        conn:close()
    end)

    it("the projection never saves the working copy or the cache", function()
        local conn = assert(client.loopback_session(srv))
        local proj = assert(snapshot.projection(conn, root))
        conn:close()
        local user_before = read(root .. "/.nvim/loomworks.user.json")
        local cache_before = read(root .. "/.nvim/loomworks.cache.json")
        assert.is_false(proj:_save_cache())
        local ok, why = proj:_save_user()
        assert.is_false(ok)
        assert.equals(snapshot.READ_ONLY, why)
        assert.equals(user_before, read(root .. "/.nvim/loomworks.user.json"))
        assert.equals(cache_before, read(root .. "/.nvim/loomworks.cache.json"))
        assert.is_nil(proj._tracker, "a projection tracks no files")
    end)

    it("round-trips a host-probing query over loopback", function()
        local conn = assert(client.loopback_session(srv))
        local result = assert(snapshot.query(conn, "tools"))
        assert.is_table(result.tools)
        -- The detection the live model holds (the shell module's one default
        -- toolchain), detected again in this client's environment.
        local live = daemon_ws()._tools_by_type
        assert.equals(#live.shell, #result.tools.shell)
        assert.same(live.shell[1].tool_data, result.tools.shell[1].tool_data)
        local none, err = snapshot.query(conn, "nope")
        assert.is_nil(none)
        assert.equals("unknown query: nope", err)
        local bad, berr = client.request(conn, { kind = "query", name = 7, env = envscope.capture() })
        assert.equals("declined", bad and bad.outcome)
        assert.is_nil(berr)
        conn:close()
    end)

    it("the welcome header carries the workspace name, the active profile and the load state", function()
        local c1 = assert(client.loopback_session(srv))
        -- Nothing loaded yet: the header says so (welcome never loads).
        assert.equals("unloaded", c1.welcome.header.state)
        assert.equals(srv.generation, c1.welcome.header.session_generation)
        assert(snapshot.fetch(c1))
        c1:close()
        local c2 = assert(client.loopback_session(srv))
        local h = c2.welcome.header
        assert.equals("loaded", h.state)
        assert.equals(daemon_ws().name, h.name)
        assert.equals("dev", h.active_profile)
        assert.is_nil(h.error)
        c2:close()
    end)

    it("the service header never overwrites the session fields", function()
        svc.header = function() return { root = "elsewhere", pid = -1, lw_version = "x", session_generation = -1,
            state = "loaded" } end
        local c = assert(client.loopback_session(srv))
        local h = c.welcome.header
        assert.equals(srv.root, h.root)
        assert.equals(srv.pid, h.pid)
        assert.equals(srv.identity, h.lw_version)
        assert.equals(srv.generation, h.session_generation)
        assert.equals("loaded", h.state)
        c:close()
    end)

    it("the welcome header reports a refused load", function()
        -- A working copy not signed by this machine is refused (§17.4).
        write(root .. "/.nvim/loomworks.user.json", vim.json.encode({ _meta = { version = 2 } }))
        local c1 = assert(client.loopback_session(srv))
        local snap, err = snapshot.fetch(c1)
        assert.is_nil(snap)
        assert.is_string(err)
        c1:close()
        local c2 = assert(client.loopback_session(srv))
        assert.equals("refused", c2.welcome.header.state)
        assert.equals(err, c2.welcome.header.error)
        assert.is_nil(c2.welcome.header.active_profile)
        c2:close()
    end)
end)
