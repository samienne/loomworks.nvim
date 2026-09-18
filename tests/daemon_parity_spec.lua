-- Parity / differential testing (DAEMON.md §7, the gold standard). The same
-- operation run through the IN-PROCESS backend and through the DAEMON (as a
-- command over the wire) must leave a byte-identical serialized workspace — and
-- the client projection must match too. Because both backends share data_model +
-- serialization, "the daemon is correct" == "it produces the same model state as
-- in-process for the same inputs".

local helpers = require("tests.helpers")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local projection = require("loomworks.daemon.projection")
local commands = require("loomworks.daemon.commands")
local snapshot = require("loomworks.daemon.snapshot")
local Core = require("loomworks.core")

local function fresh_root()
    local d = vim.fn.tempname(); vim.fn.mkdir(d, "p"); return d
end
local function new_events()
    local L = {}
    return { on = function(e, f) L[e] = L[e] or {}; L[e][#L[e] + 1] = f end, off = function() end,
        emit = function(e, d) for _, f in ipairs(L[e] or {}) do pcall(f, d) end end }
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
    vim.wait(3000, function() return core._state == "initialized" or core._state == "uninitialized" end, 5)
    return core:get_workspace(), core
end

describe("daemon parity (differential test)", function()
    local server
    after_each(function() if server and not server:is_stopped() then server:stop("cleanup") end; server = nil end)

    it("an activate-profile op yields the same serialized model in-process and via the daemon", function()
        local op = { name = "profile.activate", args = { profile_key = "rel" } }

        -- In-process backend: apply the op directly (the same command code path).
        local ws_ip = build_ws(files(), fresh_root())
        assert.is_true(#ws_ip._profiles >= 2)
        local outcome, err = commands.apply(ws_ip, op.name, op.args)
        assert.is_nil(err); assert.equals("ok", outcome)
        local ref = snapshot.serialize(ws_ip)

        -- Daemon backend: apply the SAME op as a command over the wire.
        local root_d = fresh_root()
        local ws_d = build_ws(files(), root_d, new_events())
        server = server_mod.new(root_d)
        service.attach(server, { workspace = ws_d, core = ws_d._core })
        assert.is_true((server:start()))

        local proj
        projection.connect(root_d, { core = Core.new(helpers.make_test_deps(files())) },
            function(p) proj = p end)
        assert.is_true(vim.wait(4000, function() return proj end, 10))

        proj:command(op.name, op.args)
        assert.is_true(vim.wait(3000, function()
            return proj.workspace._active_profile_key == "rel"
        end, 10), "projection never converged")

        local daemon_side = snapshot.serialize(ws_d)          -- daemon authoritative
        local projected = snapshot.serialize(proj.workspace)  -- client projection

        -- The three serialized models are byte-identical (user + cache).
        assert.is_true(vim.deep_equal(ref.user, daemon_side.user),
            "in-process vs daemon user differ")
        assert.is_true(vim.deep_equal(ref.cache, daemon_side.cache),
            "in-process vs daemon cache differ")
        assert.is_true(vim.deep_equal(ref.user, projected.user),
            "in-process vs projection user differ")
        assert.is_true(vim.deep_equal(ref.cache, projected.cache),
            "in-process vs projection cache differ")

        proj:close()
    end)

    it("a no-op load (no operation) is identical across backends", function()
        local ws_ip = build_ws(files(), fresh_root())
        local ref = snapshot.serialize(ws_ip)

        local root_d = fresh_root()
        local ws_d = build_ws(files(), root_d, new_events())
        server = server_mod.new(root_d)
        service.attach(server, { workspace = ws_d, core = ws_d._core })
        server:start()
        local proj
        projection.connect(root_d, { core = Core.new(helpers.make_test_deps(files())) },
            function(p) proj = p end)
        assert.is_true(vim.wait(4000, function() return proj end, 10))

        assert.is_true(vim.deep_equal(ref.user, snapshot.serialize(proj.workspace).user))
        assert.is_true(vim.deep_equal(ref.cache, snapshot.serialize(proj.workspace).cache))
        proj:close()
    end)
end)
