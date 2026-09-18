-- Projection client: the shared-deserializer wire path (DAEMON.md §2). A
-- workspace built from in-memory files is serialized to the wire snapshot and
-- re-hydrated into an identical projection Workspace — first directly
-- (round-trip), then across a real daemon server + pipe (two-client path).

local helpers = require("tests.helpers")
local snapshot = require("loomworks.daemon.snapshot")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local projection = require("loomworks.daemon.projection")
local Core = require("loomworks.core")

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

--- Files for a two-project workspace with a couple of profiles + an active one.
local function sample_files()
    return {
        ["loomworks.json"] = helpers.make_config_json({
            projects = { App = { cmake = {} }, Lib = { cmake = {} } },
            configuration_sets = { dev = { App = "Debug", Lib = "Debug" } },
        }),
        ["loomworks.user.json"] = helpers.make_user_json({
            active_profile = "dev",
            configuration_sets = { dev = { App = "Debug", Lib = "Debug" } },
            profiles = { dev = { configuration_set = "dev" } },
        }),
        ["loomworks.cache.json"] = helpers.make_cache_json(),
    }
end

--- Build a real remerged Workspace from in-memory files, rooted at a real dir
--- (so a daemon can write its handle/lock/socket there).
local function build_ws(files, root)
    local core = Core.new(helpers.make_test_deps(files))
    core:setup({ root = root })
    vim.wait(3000, function()
        return core._state == "initialized" or core._state == "uninitialized"
    end, 5)
    return core:get_workspace(), core
end

describe("daemon.snapshot round-trip", function()
    it("hydrates an identical model from a serialized snapshot", function()
        local files = sample_files()
        local root = fresh_root()
        local ws = assert(build_ws(files, root))

        local snap = snapshot.serialize(ws)
        assert.is_table(snap.user)
        assert.is_table(snap.cache)

        -- Hydrate into a fresh Core with the SAME deps (no re-detection, no disk).
        local client_core = Core.new(helpers.make_test_deps(files))
        local hydrated = snapshot.hydrate(client_core, root, snap)

        -- The projection serializes byte-identically (the parity property).
        local re = snapshot.serialize(hydrated)
        assert.is_true(vim.deep_equal(snap.user, re.user), "user tables differ")
        assert.is_true(vim.deep_equal(snap.cache, re.cache), "cache tables differ")
        assert.is_true(vim.deep_equal(snap.config, re.config), "config tables differ")

        -- Display-facing accessors work on the projection.
        assert.equals("dev", hydrated._active_profile_key)
        assert.equals(#ws._profiles, #hydrated._profiles)
        assert.equals(#ws._projects, #hydrated._projects)
    end)
end)

describe("daemon.projection over a live server (two-client path)", function()
    local server
    after_each(function()
        if server and not server:is_stopped() then server:stop("test cleanup") end
        server = nil
    end)

    it("a projection client hydrates from the daemon's authoritative model", function()
        local files = sample_files()
        local root = fresh_root()
        local ws, core = build_ws(files, root)

        server = server_mod.new(root)
        assert.is_not_nil(service.attach(server, { workspace = ws, core = core }))
        assert.is_true((server:start()))

        local proj, err
        projection.connect(root, {
            core = Core.new(helpers.make_test_deps(files)),
        }, function(p, e) proj = p; err = e end)
        assert.is_true(vim.wait(4000, function() return proj ~= nil or err ~= nil end, 10),
            "connect timed out")
        assert.is_nil(err)
        assert.is_not_nil(proj)

        -- The client received the handshake generation + a seq watermark.
        assert.equals(server.generation, proj.generation)
        assert.is_number(proj.seq)

        -- The projection Workspace matches the daemon's authoritative one.
        local a = snapshot.serialize(ws)
        local b = snapshot.serialize(proj.workspace)
        assert.is_true(vim.deep_equal(a.user, b.user), "user differs across the wire")
        assert.is_true(vim.deep_equal(a.cache, b.cache), "cache differs across the wire")
        assert.equals(ws._active_profile_key, proj.workspace._active_profile_key)
        assert.equals(#ws._profiles, #proj.workspace._profiles)

        proj:close()
    end)

    it("refuses to connect when no daemon is running", function()
        local root = fresh_root()
        local proj, err
        projection.connect(root, {}, function(p, e) proj = p; err = e end)
        assert.is_true(vim.wait(1000, function() return err ~= nil end, 10))
        assert.is_nil(proj)
        assert.is_truthy(err:find("no live daemon"))
    end)
end)
