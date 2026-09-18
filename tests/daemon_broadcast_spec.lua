-- Live invalidation: a change on the daemon's authoritative model broadcasts a
-- `model_change`, and every connected projection client re-pulls and reflects it
-- (coarse invalidation, DAEMON.md §3.3). Also covers the id-map hydration and
-- the snapshot's seq watermark.

local helpers = require("tests.helpers")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local projection = require("loomworks.daemon.projection")
local Core = require("loomworks.core")

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

--- A standalone events instance so the daemon's change stream is isolated from
--- any other in-process workspace (production has one workspace per daemon).
local function new_events()
    local L = {}
    return {
        on = function(e, f) L[e] = L[e] or {}; L[e][#L[e] + 1] = f end,
        off = function() end,
        emit = function(e, d) for _, f in ipairs(L[e] or {}) do pcall(f, d) end end,
    }
end

local function files()
    return {
        ["loomworks.json"] = helpers.make_config_json({
            projects = { App = { cmake = {} } },
        }),
        ["loomworks.user.json"] = helpers.make_user_json({ active_profile = "dev" }),
        ["loomworks.cache.json"] = helpers.make_cache_json(),
    }
end

local function build_ws(f, root, events)
    local core = Core.new(helpers.make_test_deps(f, { events = events }))
    core:setup({ root = root })
    vim.wait(3000, function()
        return core._state == "initialized" or core._state == "uninitialized"
    end, 5)
    return core:get_workspace(), core
end

describe("daemon broadcast → projection auto-refresh", function()
    local server
    after_each(function()
        if server and not server:is_stopped() then server:stop("cleanup") end
        server = nil
    end)

    it("propagates a daemon model change to a connected projection", function()
        local f = files()
        local root = fresh_root()
        local daemon_events = new_events()
        local ws = build_ws(f, root, daemon_events)

        server = server_mod.new(root)
        service.attach(server, { workspace = ws, core = ws._core })
        assert.is_true((server:start()))

        local proj, err
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)) },
            function(p, e) proj = p; err = e end)
        assert.is_true(vim.wait(4000, function() return proj or err end, 10))
        assert.is_nil(err)
        assert.equals("dev", proj.workspace._active_profile_key)
        -- The id-map (subscription set) hydrated from the snapshot.
        assert.is_table(proj.id_map)
        assert.is_table(proj.id_map.projects)
        local seq0 = proj.seq

        -- The daemon's model changes and it notifies (a remerge/activation emits
        -- active_set_changed; simulated here by mutating + emitting).
        ws._active_profile_key = "release"
        daemon_events.emit("active_set_changed", {})

        -- The projection re-pulls and reflects the change, with an advanced seq.
        assert.is_true(vim.wait(3000, function()
            return proj.workspace._active_profile_key == "release"
        end, 10), "projection did not auto-refresh")
        assert.is_true(proj.seq > seq0)

        proj:close()
    end)

    it("does not re-pull for a stale (already-seen) seq", function()
        local f = files()
        local root = fresh_root()
        local daemon_events = new_events()
        local ws = build_ws(f, root, daemon_events)
        server = server_mod.new(root)
        service.attach(server, { workspace = ws, core = ws._core })
        server:start()

        local proj
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)) },
            function(p) proj = p end)
        assert.is_true(vim.wait(4000, function() return proj end, 10))

        local refreshes = 0
        local orig = proj._hydrate
        proj._hydrate = function(self, cb) refreshes = refreshes + 1; return orig(self, cb) end
        -- A model_change carrying a seq we've already passed must be ignored.
        proj:_on_model_change({ kind = "model_change", seq = 0, session_generation = proj.generation })
        vim.wait(200)
        assert.equals(0, refreshes)

        proj:close()
    end)
end)
