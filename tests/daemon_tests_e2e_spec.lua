-- The editor's test runs and test debug end to end (step 5m part C2;
-- daemon.md §19.16 "Tests", §19.20 `Tests/1`; LOOMTEST.md §13.1): the daemon
-- is the real lw of LOOMWORKS_LW (tests/daemon_helpers.lua), with the
-- harness-only `teststub` module (tests/fixtures/teststub) installed as an
-- acquired module in this editor's data dir (`<data>/modules/teststub`,
-- where `lw module install` puts one), and the editor side is the real
-- observer (through a real `--stdio` relay) feeding loomworks.test_source
-- and the loomtest adapter. A run from loomtest is one `Tests/1.run_cases`
-- whose `results` and view updates move the nodes; a node's output comes
-- from `Tests/1.result`; a debug is `prepare_debug` → the editor's debugger
-- (stubbed: no nvim-dap here) → `collect`. Nothing is discovered, built or
-- run in the editor.

local observer = require("loomworks.daemon.observer")
local test_source = require("loomworks.test_source")
local adapter_mod = require("loomworks.loomtest_adapter")
local loomtest = require("loomtest")
local H = require("tests.daemon_helpers")

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

--- The `tests` fixture: the shell workspace's project `app` as a `teststub`
--- project with tests, the profile `dev` active (signed by lw).
local function tests_workspace()
    local root = H.shell_workspace()
    local f = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = vim.json.decode(f:read("*a")); f:close()
    cfg.projects.app = { path = "app", teststub = cfg.projects.app.shell }
    f = assert(io.open(root .. "/loomworks.json", "wb")); f:write(vim.json.encode(cfg)); f:close()
    f = assert(io.open(root .. "/app/tests.json", "wb")); f:write(vim.json.encode(TESTS_JSON)); f:close()
    local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } },
        projects = { app = cfg.projects.app }, active_profile = "dev" }
    local signed = H.signed_user(root, user)
    f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb")); f:write(signed); f:close()
    return root
end

describe("editor test runs and debug through a real daemon /tests (§19.16 Tests, step 5m C2)", function()
    local root, env, obs
    local notes, orig_notify
    local dbg = require("loomworks.debug")
    local orig_installed, orig_run, dap_runs

    before_each(function()
        H.install_stub_module("teststub")
        env = H.editor_env({ LOOMWORKS_RUNTIME = "daemon" })
        root = tests_workspace()
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
        observer.detach()
        H.track_root(root, env)
        if H.daemon(root, env) then H.stop_daemon(root, env) end
        H.cleanup()
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

    --- Does the daemon of `root` run no task (`lw daemon list --json`)?
    local function daemon_idle()
        local d = H.daemon(root, env)
        return d ~= nil and d.busy == false
    end

    it("runs, reads a failed node's output and debugs through Tests/1", function()
        -- Built beforehand by a CLI client (the unit is configured here).
        local r = H.lw({ "--no-input", "build", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr .. r.stdout)

        obs = observer.attach(root, { getenv = daemon_mode, keepalive_ms = 500,
            resolve = function() return "lw" end, relay = H.real_relay() })
        H.track_root(root, env)
        assert.is_true(vim.wait(60000, function()
            local v = test_source.daemon_view()
            return type(v) == "table" and v.state == "loaded" and test_source.daemon_status() == nil
        end, 20), obs:runtime_line() .. " " .. vim.inspect(test_source.daemon_status()))
        assert.is_true(test_source.attached())

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
            return n ~= nil and n.status == "failed" and not obs:owns_tasks()
        end, 20), vim.inspect(loomtest.get_node(sub.id)))
        assert.is_true(results_seen >= 1)
        assert.same({}, errors())
        assert.is_true(vim.wait(30000, daemon_idle, 200))

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

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
