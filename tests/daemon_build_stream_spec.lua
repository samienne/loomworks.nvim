-- Build delegation + task stream: a build launched by one client streams into
-- EVERY connected client (DAEMON.md §3.4 — a CLI `lw build` shows in the editor
-- identically), and the launching client observes its own output/done. Uses an
-- injected build runner so the stream is deterministic (no real toolchain).

local helpers = require("tests.helpers")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local projection = require("loomworks.daemon.projection")
local cli = (function() _G.LOOMWORKS_CLI_NO_AUTORUN = true; return require("loomworks.cli") end)()
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
        ["loomworks.json"] = helpers.make_config_json({ projects = { App = { cmake = {} } } }),
        ["loomworks.user.json"] = helpers.make_user_json({ active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } },
            configuration_sets = { dev = { App = "Debug" } } }),
        ["loomworks.cache.json"] = helpers.make_cache_json(),
    }
end
local function build_ws(f, root, events)
    local core = Core.new(helpers.make_test_deps(f, { events = events }))
    core:setup({ root = root })
    vim.wait(3000, function() return core._state == "initialized" or core._state == "uninitialized" end, 5)
    return core:get_workspace(), core
end

-- A deterministic fake build runner that drives the task stream.
local function fake_run_build(srv, args, task_id)
    srv.tasks:start(task_id, { name = args.profile_key })
    srv.tasks:output(task_id, "stdout", "compiling " .. tostring(args.profile_key) .. "\n")
    srv.tasks:progress(task_id, 1.0)
    srv.tasks:done(task_id, 0)
    srv:notify_model_change({ "build_state" })
end

describe("daemon build stream (observable by any client)", function()
    local server
    after_each(function() if server and not server:is_stopped() then server:stop("cleanup") end; server = nil end)

    it("streams a client-launched build into a second observing client", function()
        local f = files()
        local root = fresh_root()
        local ws = build_ws(f, root, new_events())
        server = server_mod.new(root)
        service.attach(server, { workspace = ws, core = ws._core, run_build = fake_run_build })
        assert.is_true((server:start()))

        -- Observer client B collects task events.
        local b_events = {}
        local projB
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)),
            on_task = function(m) b_events[#b_events + 1] = m end },
            function(p) projB = p end)
        assert.is_true(vim.wait(4000, function() return projB end, 10))

        -- Launcher client A builds and observes its own output/done.
        local a_output, a_code = {}, nil
        local projA
        projection.connect(root, { core = Core.new(helpers.make_test_deps(f)) },
            function(p) projA = p end)
        assert.is_true(vim.wait(4000, function() return projA end, 10))
        projA:build({ profile_key = "dev" }, {
            on_output = function(_s, t) a_output[#a_output + 1] = t end,
            on_done = function(c) a_code = c end,
        })

        assert.is_true(vim.wait(3000, function() return a_code ~= nil end, 10),
            "launcher never saw done")
        assert.equals(0, a_code)
        assert.is_truthy(table.concat(a_output):find("compiling dev"))

        -- B (who never issued the build) saw the SAME stream: an output + a done.
        local b_out, b_done = false, false
        for _, m in ipairs(b_events) do
            if m.phase == "output" and m.text:find("compiling dev") then b_out = true end
            if m.phase == "done" then b_done = true end
        end
        assert.is_true(b_out, "observer did not see build output")
        assert.is_true(b_done, "observer did not see build completion")

        projA:close(); projB:close()
    end)
end)

describe("cli build delegation seam", function()
    it("returns nil (in-process) when runtime mode is in-process", function()
        assert.is_nil(cli._maybe_delegate_build("/ws", { "build" }, { mode = "in-process" }))
    end)

    it("delegates and streams when a daemon is reachable", function()
        local out_chunks = {}
        local fake_proj = {
            build = function(_self, _args, cbs)
                cbs.on_accept(1)
                cbs.on_output("stdout", "hi\n")
                cbs.on_done(0)
            end,
            close = function() end,
        }
        local code = cli._maybe_delegate_build("/ws", { "build" }, {
            mode = "daemon",
            detect = function() return { present = true, live = true, compatible = true } end,
            connect = function(_root, _opts, cb) cb(fake_proj, nil) end,
        })
        assert.equals(0, code)
    end)

    it("falls back (nil) when no daemon is reachable and none can be spawned", function()
        local code = cli._maybe_delegate_build("/ws", { "build" }, {
            mode = "daemon",
            detect = function() return { present = false } end,
            spawn = function() return false end,
        })
        assert.is_nil(code)
    end)
end)
