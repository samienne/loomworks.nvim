-- Commands (mutations): a client command mutates the daemon's authoritative
-- model and persists it; the projection updates from the resulting broadcast
-- (not the ack), and the daemon's own serialized state reflects the change.

local helpers = require("tests.helpers")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local projection = require("loomworks.daemon.projection")
local commands = require("loomworks.daemon.commands")
local Core = require("loomworks.core")

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

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
            configuration_sets = { dev = { App = "Debug" }, rel = { App = "Release" } },
        }),
        ["loomworks.user.json"] = helpers.make_user_json({
            active_profile = "dev",
            configuration_sets = { dev = { App = "Debug" }, rel = { App = "Release" } },
            profiles = { dev = { configuration_set = "dev" }, rel = { configuration_set = "rel" } },
        }),
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

describe("daemon.commands registry", function()
    it("errors on an unknown command", function()
        local outcome, err = commands.apply({}, "no.such.command", {})
        assert.is_nil(outcome)
        assert.is_truthy(err:find("unknown command"))
    end)

    it("errors (not crashes) when a handler raises", function()
        local outcome, err = commands.apply({ _profiles = {} }, "profile.activate", { profile_key = "ghost" })
        assert.is_nil(outcome)
        assert.is_truthy(err:find("no such profile"))
    end)
end)

describe("daemon command over the wire", function()
    local server
    after_each(function()
        if server and not server:is_stopped() then server:stop("cleanup") end
        server = nil
    end)

    it("activate-profile command mutates the daemon and updates the projection", function()
        local f = files()
        local root = fresh_root()
        local daemon_events = new_events()
        local ws = build_ws(f, root, daemon_events)
        -- Guard: the fixture must actually yield two resolvable profiles.
        assert.is_true(#ws._profiles >= 2, "fixture must define two profiles")

        server = server_mod.new(root)
        service.attach(server, { workspace = ws, core = ws._core })
        assert.is_true((server:start()))

        local proj, err
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)) },
            function(p, e) proj = p; err = e end)
        assert.is_true(vim.wait(4000, function() return proj or err end, 10))
        assert.is_nil(err)
        assert.equals("dev", proj.workspace._active_profile_key)

        -- Fire the command from the client. The projection must reflect the
        -- change via the broadcast, and the ack must report ok.
        local outcome, cmderr
        proj:command("profile.activate", { profile_key = "rel" },
            function(o, e) outcome = o; cmderr = e end)

        assert.is_true(vim.wait(3000, function()
            return proj.workspace._active_profile_key == "rel"
        end, 10), "projection did not reflect the activation")
        -- The daemon's authoritative model changed too.
        assert.equals("rel", ws._active_profile_key)
        -- The ack arrived with an ok outcome.
        assert.is_true(vim.wait(1000, function() return outcome ~= nil or cmderr ~= nil end, 10))
        assert.is_nil(cmderr)
        assert.equals("ok", outcome)

        proj:close()
    end)

    it("an unknown command replies with an error ack", function()
        local f = files()
        local root = fresh_root()
        local ws = build_ws(f, root, new_events())
        server = server_mod.new(root)
        service.attach(server, { workspace = ws, core = ws._core })
        server:start()

        local proj
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)) },
            function(p) proj = p end)
        assert.is_true(vim.wait(4000, function() return proj end, 10))

        local outcome, cmderr
        proj:command("bogus.command", {}, function(o, e) outcome = o; cmderr = e end)
        assert.is_true(vim.wait(1500, function() return cmderr ~= nil end, 10))
        assert.is_nil(outcome)
        assert.is_truthy(cmderr:find("unknown command"))

        proj:close()
    end)
end)
