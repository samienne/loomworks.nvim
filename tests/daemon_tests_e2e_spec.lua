-- The editor's test runs and test debug end to end (step 5m part C2;
-- daemon.md §19.16 "Tests", §19.20 `Tests/1`; LOOMTEST.md §13.1): the daemon
-- side is real — an in-process server with the real build service
-- (cli._daemon_build_host) on the conformance runner's `tests` fixture (the
-- harness-only teststub module) — and the editor side is the real observer
-- subscription feeding loomworks.test_source and the loomtest adapter. A run
-- from loomtest is one `Tests/1.run_cases` whose `results` and view updates
-- move the nodes; a node's output comes from `Tests/1.result`; a debug is
-- `prepare_debug` → the editor's debugger (stubbed: no nvim-dap here) →
-- `collect`. Nothing is discovered, built or run in the editor's model.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local test_source = require("loomworks.test_source")
local adapter_mod = require("loomworks.loomtest_adapter")
local loomtest = require("loomtest")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- One gtest-like program `fake`: Math.Add passes, Math.Sub fails at
--- math.cpp:7.
local TESTS_JSON = {
    targets = { { name = "fake", cases = { "Math.Add", "Math.Sub" }, file = "math.cpp", line = 3 } },
    results = { ["Math.Sub"] = "failed" },
    failures = { ["Math.Sub"] = "math.cpp:7" },
}

describe("editor test runs and debug through a real daemon /tests (§19.16 Tests, step 5m C2)", function()
    local root, srv, core, obs, sess
    local notes, orig_notify
    local dbg = require("loomworks.debug")
    local orig_installed, orig_run, dap_runs

    before_each(function()
        local key = H.tmp() .. "/trust.key"
        trust._set_key_path(key)
        root = runner.fixture("tests", key)
        runner.register_teststub()
        local f = assert(io.open(root .. "/app/tests.json", "wb"))
        f:write(vim.json.encode(TESTS_JSON))
        f:close()
        trust._set_key_path(key)
        core = Core.new()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        test_source._facade = setmetatable({
            get_workspace = function() return core:get_workspace() end,
        }, { __index = require("loomworks") })
        notes = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        orig_installed, orig_run = dbg.adapter_installed, dbg.run
        dap_runs = {}
        dbg.adapter_installed = function(a) return a ~= nil end
        dbg.run = function(spec, cb)
            dap_runs[#dap_runs + 1] = { spec = spec, cb = cb }
            return true
        end
        adapter_mod._reset()
        loomtest.clear()
    end)

    after_each(function()
        vim.notify = orig_notify
        dbg.adapter_installed, dbg.run = orig_installed, orig_run
        loomtest.unregister_adapter("loomworks")
        loomtest.clear()
        adapter_mod._reset()
        if obs then obs:stop() end
        obs = nil
        if sess then sess:close() end
        sess = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        srv = nil
        test_source._facade = nil
        pcall(function() core:shutdown() end)
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    local function errors()
        local out = {}
        for _, n in ipairs(notes) do
            if n.level == vim.log.levels.ERROR then out[#out + 1] = n.msg end
        end
        return out
    end

    --- The loomtest node named `name` (a case's display name), or nil.
    local function node_named(name)
        for _, n in ipairs(loomtest.nodes()) do
            if n.type == "test" and (n.name == name or n.name:match("%.?" .. vim.pesc(name) .. "$")) then
                return n
            end
        end
        return nil
    end

    it("runs, reads a failed node's output and debugs through Tests/1", function()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function() end })
        srv:registry()
        service.attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start())
        -- Built beforehand by a CLI client (the unit is configured here).
        sess = assert(client.session(srv.address))
        local env = require("loomworks.daemon.envscope").capture()
        local res, cerr = client.call_sync(sess, "/build", "loomworks.Build", 1, "build",
            { profile = { key = "dev" } }, { env = env })
        assert.is_not_nil(res, cerr and cerr.message)
        assert.is_true(vim.wait(120000, function() return not srv.service.tasks:busy() end, 20))

        local fr = FR.new({})
        obs = observer.attach(core:get_workspace(), { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(60000, function()
            local v = test_source.daemon_view()
            return type(v) == "table" and v.state == "loaded" and test_source.daemon_status() == nil
        end, 20), obs:runtime_line() .. " " .. vim.inspect(test_source.daemon_status()))
        assert.equals("daemon", test_source.mode())

        -- The adapter's first ask discovers the stale view (Tests/1.discover).
        adapter_mod.setup()
        adapter_mod.register()
        loomtest.discover()
        assert.is_true(vim.wait(120000, function() return node_named("Sub") ~= nil end, 20),
            vim.inspect(test_source.daemon_view()))
        local sub = node_named("Sub")
        local add = node_named("Add")
        assert.is_not_nil(add)

        -- A run of the failing case: one owned run_cases; the node fails.
        local results_seen = 0
        require("loomworks").on("daemon_test_results", function() results_seen = results_seen + 1 end)
        loomtest.run(sub.id)
        assert.is_true(vim.wait(120000, function()
            local n = loomtest.get_node(sub.id)
            return n ~= nil and n.status == "failed" and not srv.service.tasks:busy()
        end, 20), vim.inspect(loomtest.get_node(sub.id)))
        assert.is_true(results_seen >= 1)
        assert.same({}, errors())

        -- Its output and error location come from Tests/1.result.
        local got
        loomtest.load_result(sub.id, function(n) got = n end)
        assert.is_true(vim.wait(30000, function() return got ~= nil end, 20))
        assert.is_true(got._result_loaded)
        assert.is_table(got._errors)
        assert.equals(7, got._errors[1] and got._errors[1].line, vim.inspect(got._errors))

        -- Debugging the passing case: prepare_debug, the spec to the
        -- debugger, collect when it ends.
        loomtest.debug(add.id)
        assert.is_true(vim.wait(120000, function() return #dap_runs == 1 end, 20), vim.inspect(errors()))
        local spec = dap_runs[1].spec
        assert.is_string(spec.program)
        assert.is_string(spec.adapter)
        assert.is_table(spec.args)
        dap_runs[1].cb.on_terminated()
        assert.is_true(vim.wait(30000, function()
            local n = loomtest.get_node(add.id)
            return n ~= nil and n.status ~= "pending"
        end, 20))
        assert.same({}, errors())
    end)
end)
