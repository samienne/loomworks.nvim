-- The daemon-mode editor end to end, one smoke run (step 5k part D; spec
-- §19.16 "Public API", "Editor operations", §19.13 "Load warnings"): a real
-- spawned daemon (through a real `--stdio` relay from this checkout) and the
-- editor's public paths, in order — attach (the status page from the views),
-- pick_profile, build_profile, pick_target + build_target + launch_target (the
-- launch configuration's working_dir honoured), an environment change then a
-- build (#351: it succeeds the first time), a user.json edit that introduces
-- and then fixes a stale configuration-set mapping (#350: the load warning
-- appears in the views' diagnostics, then goes), a clean, and lw.shutdown()
-- (no daemon process left behind). The editor holds no workspace model at any
-- point (step 6b-alpha): `lw.get_workspace()` stays nil throughout.
--
-- The scenarios share one workspace and one daemon and run in order; each
-- builds on the state the previous one left.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local inspect = require("loomworks.daemon.inspect")
local client = require("loomworks.daemon.client")
local relay_client = require("loomworks.daemon.client").relay
local events = require("loomworks.events")
local trust = require("loomworks.trust")
local Tree = require("loomworks.ui.tree")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- Real relays from this checkout run by nvim (as the specs' `lw`).
local function real_relays()
    return function(ro, cb)
        ro.argv = { vim.v.progpath, "--headless", "-u", "NONE", "--cmd",
            "lua vim.opt.rtp:prepend(" .. string.format("%q", H.REPO) .. ")", "-l", H.CLI }
        return relay_client.connect(ro, cb)
    end
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Edit the signed working copy (the trust key is this spec file's data
--- dir's, which the spawned daemon shares).
local function edit_user(root, fn)
    local path = root .. "/.nvim/loomworks.user.json"
    local status, body = trust.verify("user", assert(read(path)))
    assert.equals("valid", status)
    local user = vim.json.decode(body)
    fn(user)
    local signed, serr = trust.sign("user", trust.encode(user))
    if not signed then error(serr) end
    local f = assert(io.open(path, "wb")); f:write(signed); f:close()
end

--- The launch program: writes its working directory and LW_TEST_FOO to the
--- file named by its first argument.
local WHERE = [[
local f = io.open(arg[1], "w")
f:write(vim.uv.cwd() .. string.char(10) .. tostring(os.getenv("LW_TEST_FOO")))
f:close()
]]

local function norm(p)
    p = (vim.uv.fs_realpath(p) or p):gsub("\\", "/")
    return (vim.fn.has("win32") == 1) and p:lower() or p
end

describe("daemon-mode editor smoke run against a real daemon (step 5k D)", function()
    local lw = require("loomworks")
    local root, env, obs, daemon
    local started = {}
    local notes = {}
    local handlers = {}
    local orig_notify, orig_select = vim.notify, vim.ui.select

    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    local function no_model()
        assert.is_nil(lw.get_workspace(), "the daemon-mode editor loaded a workspace model")
    end

    local function view() return obs:workspace_view() end

    --- The (only) profile row of the workspace view.
    local function row() return assert(view()).profiles[1] end

    --- Wait until the profile row's unit state satisfies `pred`.
    local function wait_unit(pred, ms)
        local state
        local ok = vim.wait(ms or 60000, function()
            local v = view()
            local p = v and v.profiles and v.profiles[1]
            local u = p and (p.units or {})[1]
            state = u and u.state
            return pred(state)
        end, 20)
        return ok, state
    end

    --- Wait for the next task the editor saw start (after `n` were seen) to end.
    local function next_task(n, ms)
        assert.is_true(vim.wait(ms or 120000, function()
            local t = started[n + 1]
            return t ~= nil and t.exit_code ~= nil
        end, 20), obs:runtime_line() .. "\n" .. vim.inspect(notes))
        return started[n + 1]
    end

    local function diag_count(needle)
        local n = 0
        for _, d in ipairs((view() or {}).diagnostics or {}) do
            if tostring(d.message):find(needle, 1, true) then n = n + 1 end
        end
        return n
    end

    local function warnings()
        local out = {}
        for _, n in ipairs(notes) do
            if (n.level or 0) >= vim.log.levels.WARN then out[#out + 1] = n.msg end
        end
        return out
    end

    --- Restore the editor and stop/kill whatever this run started.
    --- Idempotent; run by test 8 and, whatever happened, after the last test.
    local function teardown()
        vim.notify = orig_notify
        vim.ui.select = orig_select
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        if observer.current() then pcall(lw.shutdown) end
        if root then
            if inspect.state(root).kind == "live" then pcall(H.stop_daemon, root, env) end
            H.track_root(root)
        end
        H.cleanup()
    end

    -- plenary's busted has no `teardown`: count the tests run and tear down
    -- after the last one, whichever tests failed.
    local TESTS, ran = 8, 0
    after_each(function()
        ran = ran + 1
        vim.ui.select = orig_select
        if ran >= TESTS then teardown() end
        no_model()
    end)

    it("1. attach: the status page renders from the daemon's views; no model is loaded", function()
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        root = H.shell_workspace({ profile = true, launch = {
            run = { command = vim.v.progpath, args = { "--headless", "-u", "NONE", "-l",
                "${workspace_root}/where.lua", "${workspace_root}/where.txt" }, working_dir = "app/sub" },
        } })
        vim.fn.mkdir(root .. "/app/sub", "p")
        local f = assert(io.open(root .. "/where.lua", "w")); f:write(WHERE); f:close()
        -- A short idle timeout: once the editor detaches, the daemon exits.
        local cfg = assert(vim.env.APPDATA or vim.env.XDG_CONFIG_HOME) .. "/loomworks"
        vim.fn.mkdir(cfg, "p")
        f = assert(io.open(cfg .. "/config.json", "w"))
        f:write(vim.json.encode({ ["daemon-idle-timeout"] = "5s" })); f:close()
        env = H.env({ LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR, LOOMWORKS_RUNTIME = "daemon",
            APPDATA = vim.env.APPDATA, XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME })
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)

        -- The observer with this checkout's relay, then the editor's own
        -- load (setup's path): it keeps that observer, loads no model.
        lw._core():set_pending_root(root)
        local wroot = lw.workspace_root()
        obs = observer.attach(wroot, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_not_nil(obs)
        lw._load(root)
        assert.equals(obs, observer.current())
        assert.equals("daemon", (lw.runtime_mode()))
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        daemon = H.track_root(root)
        assert.is_not_nil(daemon)
        no_model()
        assert.is_true(vim.wait(60000, function()
            local v = view()
            return v ~= nil and #(v.profiles or {}) > 0
        end, 20), obs:runtime_line())
        assert.is_true(require("loomworks.daemon.facade").active())

        -- Every section from the views (Debug Adapters is read by its own
        -- call once attached: "unavailable — reading ..." until it answers).
        local text
        local function render()
            local tree = Tree.new(require("loomworks.ui.status")._render_fn)
            setmetatable(tree._folds, { __index = function() return true end })
            text = table.concat(tree:render(), "\n")
            return text
        end
        vim.wait(30000, function() return not render():find("unavailable", 1, true) end, 50)
        -- The profile row: a line under the Profiles header naming `dev`.
        assert.equals("dev", row().key)
        local in_profiles, profile_line = false, nil
        for line in vim.gsplit(text, "\n", { plain = true }) do
            if line:find("Profiles", 1, true) then
                in_profiles = true
            elseif in_profiles and line:find("%f[%w_]dev%f[^%w_]") then
                profile_line = line
                break
            end
        end
        assert.is_not_nil(profile_line, text)
        assert.truthy(text:find("app", 1, true), text)
        assert.falsy(text:find("unavailable", 1, true), text)
        no_model()
    end)

    it("2. pick_profile activates the profile row (Profiles/1.set_active)", function()
        assert.is_not_true(row().active)
        local id = row().id
        vim.ui.select = function(items, _, cb)
            for _, it in ipairs(items) do
                if it.row.id == id then return cb(it) end
            end
            cb(nil)
        end
        lw.pick_profile()
        assert.is_true(vim.wait(30000, function() return row().active == true end, 20), vim.inspect(notes))
        assert.equals(id, row().id)
    end)

    it("3. build_profile: an owned task, exit 0, the unit row built", function()
        local n = #started
        lw.build_profile()
        local task = next_task(n)
        assert.equals("build", task.kind)
        assert.is_true(task.owned)
        assert.equals(row().id, task.profile_id)
        assert.equals(0, task.exit_code, task:output())
        assert.truthy(task:output():find("step build", 1, true), task:output())
        local ok, state = wait_unit(function(s) return s == "built" end)
        assert.is_true(ok, tostring(state))
        assert.same({}, warnings())
    end)

    -- BUG (not daemon-specific, in-process too): the shell project's
    -- `build_dir` template is ignored. shell.info() puts it in each
    -- configuration's `module_config`, and Configuration:_apply copies every
    -- non-generic key — `module_config` included — into its own
    -- `module_config`, so it lands at `module_config.module_config.build_dir`
    -- and shell.resolve_build_dir falls back to `<root>/.nvim/build/app/Debug`.
    -- Enable once fixed.
    it("3b. the unit's build dir is the shell project's build_dir template's", function()
        assert.equals(norm(root .. "/out/Debug"), norm(row().units[1].build_dir), vim.inspect(row().units[1]))
    end)

    it("4. pick_target, build_target, launch_target: the run executes in its working_dir", function()
        -- pick_target stores `run` as the default target.
        local picked
        vim.ui.select = function(items, _, cb)
            for _, it in ipairs(items) do
                if it.ref and it.ref.name == "run" then picked = it; return cb(it) end
            end
            cb(nil)
        end
        lw.pick_target()
        assert.is_true(vim.wait(30000, function()
            return row().default_target ~= nil and row().default_target_valid ~= false
        end, 20), vim.inspect({ row = row(), notes = notes }))
        assert.is_not_nil(picked)
        assert.equals("app: run", row().default_target)
        assert.is_true(row().default_target_valid)
        vim.ui.select = function() error("no picker expected: the default target is stored") end

        -- build_target: Launch/1.build of the default target, a task the editor owns.
        local n = #started
        lw.build_target()
        local task = next_task(n)
        assert.equals("build", task.kind)
        assert.is_true(task.owned)
        assert.equals(row().id, task.profile_id)
        assert.equals(0, task.exit_code, task:output())

        -- launch_target: prepared in the daemon, started here. The task
        -- runner's start is replaced by running the prepared program directly
        -- (no overseer in the test host), asynchronously: the stub returns at
        -- once and the event loop keeps serving the daemon connection.
        local ov = require("loomworks.overseer")
        local orig = ov.launch_run_task
        local launched = {}
        ov.launch_run_task = function(spec)
            launched[#launched + 1] = spec
            local cmd = { spec.cmd }
            for _, a in ipairs(spec.args or {}) do cmd[#cmd + 1] = a end
            vim.system(cmd, { cwd = spec.cwd, env = spec.env }, function(r) spec.result = r end)
            return nil
        end
        local ok, err = pcall(function()
            lw.launch_target()
            assert.is_true(vim.wait(120000, function() return #launched > 0 end, 20),
                obs:runtime_line() .. "\n" .. vim.inspect(notes))
            assert.is_true(vim.wait(60000, function() return launched[1].result ~= nil end, 20),
                vim.inspect(launched[1]))
        end)
        ov.launch_run_task = orig
        assert(ok, err)
        local spec = launched[1]
        assert.equals(0, spec.result.code, vim.inspect(spec.result))
        local out = read(root .. "/where.txt")
        assert.is_not_nil(out, vim.inspect(spec))
        local cwd = out:match("^([^\r\n]*)")
        assert.equals(norm(root .. "/app/sub"), norm(cwd), vim.inspect(spec))
        assert.same({}, warnings())
    end)

    it("5. an environment change, then a build: it succeeds the first time (#351)", function()
        vim.env.LW_TEST_FOO = "smoke-" .. tostring(vim.uv.hrtime())
        local want = vim.env.LW_TEST_FOO
        local before = #notes
        local n = #started
        local ok, err = pcall(function()
            lw.build_profile()
            local task = next_task(n)
            assert.equals(0, task.exit_code, task:output())
            assert.truthy(task:output():find("FOO=" .. want, 1, true), task:output())
        end)
        vim.env.LW_TEST_FOO = nil
        assert(ok, err)
        for i = before + 1, #notes do
            assert.is_true((notes[i].level or 0) < vim.log.levels.WARN, vim.inspect(notes[i]))
        end
        local okb, state = wait_unit(function(s) return s == "built" end)
        assert.is_true(okb, tostring(state))
    end)

    it("6. a user.json edit introduces a stale mapping, then fixes it: the views' diagnostic comes and goes (#350)", function()
        local STALE = "references unknown configuration"
        assert.equals(0, diag_count(STALE), vim.inspect(view().diagnostics))
        edit_user(root, function(u) u.configuration_sets = { bad = { app = "Nope" } } end)
        assert.is_true(vim.wait(60000, function() return diag_count("Nope") > 0 end, 50),
            vim.inspect(view().diagnostics))
        edit_user(root, function(u) u.configuration_sets = nil end)
        assert.is_true(vim.wait(60000, function() return diag_count("Nope") == 0 end, 50),
            vim.inspect(view().diagnostics))
        -- The profile row is still the same and still active.
        assert.is_true(row().active)
    end)

    it("7. clean: the unit row goes back to not built", function()
        local done
        require("loomworks.ui.model_calls").call(nil, "Build/1.clean", { profile = row() }, function(r) done = r end)
        assert.is_true(vim.wait(120000, function() return done ~= nil end, 20), obs:runtime_line())
        assert.equals("ok", done.outcome, vim.inspect(done))
        local ok, state = wait_unit(function(s) return s ~= nil and s ~= "built" end)
        assert.is_true(ok, tostring(state))
    end)

    it("8. lw.shutdown() leaves no daemon process behind", function()
        -- Everything that can fail runs first and the assertions come last,
        -- so the daemon is stopped (or killed) whatever happens.
        local ok_shutdown, shutdown_err = pcall(lw.shutdown)
        local current = observer.current()
        local had_model = lw.get_workspace() ~= nil
        -- Detached, the daemon is idle: it exits on its idle timeout (5 s here).
        local gone = daemon ~= nil and vim.wait(90000, function()
            return not H.alive(daemon.pid, daemon.start_time)
        end, 200)
        local stopped_by_test = not gone and root ~= nil and inspect.state(root).kind == "live"
        teardown()
        assert(ok_shutdown, shutdown_err)
        assert.is_not_nil(daemon)
        assert.is_nil(current)
        assert.is_false(had_model, "the daemon-mode editor loaded a workspace model")
        assert.is_true(gone, "the daemon was still running after lw.shutdown()"
            .. (stopped_by_test and " (stopped by the test)" or ""))
        assert.equals(0, H.survivors)
    end)
end)
