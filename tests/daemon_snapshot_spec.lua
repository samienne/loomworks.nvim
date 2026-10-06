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
        assert.equals(enc(snap.tools), enc(proj._tools_by_type))
        assert.equals("dev", proj._active_profile and proj._active_profile.key)
        conn:close()
    end)

    it("carries a current-key -> id index whose ids follow the objects across snapshots", function()
        local conn = assert(client.loopback_session(srv))
        local a = assert(snapshot.fetch(conn))
        local b = assert(snapshot.fetch(conn))
        assert.is_number(a.index.projects.app)
        assert.is_number(a.index.config_sets.dev)
        assert.is_number(a.index.profiles.dev)
        assert.same(a.index, b.index)
        local ids = {}
        for _, kind in pairs(a.index) do
            for _, id in pairs(kind) do
                assert.is_nil(ids[id], "an id is unique")
                ids[id] = true
            end
        end
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
