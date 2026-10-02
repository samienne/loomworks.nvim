-- A build/clean/test step that a signal ended is a FAILURE (spec §16.7): its
-- exit status is 128 + the signal number, its failure line names the signal,
-- and the step is never recorded as done. On POSIX libuv reports such a
-- process as exit code 0 + the signal, which every path used to read as
-- success (`BUILD OK` after an OOM-killed or `kill -9`ed ninja). Windows has
-- no such signals: libuv reports a nonzero exit code (TerminateProcess) and
-- signal 0, except for its own emulated kills, which keep their exit code.
--
-- Covered here with the spawn stubbed, so it runs on every platform: the
-- mapping itself, the in-process `lw build` (run_spec over vim.system) and
-- the daemon-routed build (the runner's spawn). Real self-killing steps are
-- in daemon_build_cli_spec (both paths, real processes), the standalone
-- suite (the shim's vim.system and the runner's spawn under luvi) and
-- scripts/ci/cli-e2e.sh (the fused host on Linux/macOS).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local build_run = require("loomworks.build_run")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local runner = require("loomworks.daemon.runner")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

describe("build_run.exit_status", function()
    it("maps a signal-ended process (libuv: code 0 + signal) to 128 + signal", function()
        assert.same({ 137, 9 }, { build_run.exit_status(0, 9) })
        assert.same({ 143, 15 }, { build_run.exit_status(0, 15) })
        assert.same({ 130, 2 }, { build_run.exit_status(nil, 2) })
        -- Already mapped (the shim's vim.system, nvim's jobstart): unchanged.
        assert.same({ 137, 9 }, { build_run.exit_status(137, 9) })
    end)

    it("leaves a plain exit status alone", function()
        assert.same({ 0 }, { build_run.exit_status(0, 0) })
        assert.same({ 0 }, { build_run.exit_status(0, nil) })
        assert.same({ 3 }, { build_run.exit_status(3, 0) })
        assert.same({ 137 }, { build_run.exit_status(137, 0) })
        -- Windows: libuv's emulated kill (TerminateProcess) keeps its exit code.
        assert.same({ 1 }, { build_run.exit_status(1, 15) })
        assert.same({ 1 }, { build_run.exit_status(1, 9) })
    end)

    it("names the signal", function()
        assert.equals("killed by signal 9 (SIGKILL)", build_run.exit_text(137, 9))
        assert.equals("killed by signal 15 (SIGTERM)", build_run.exit_text(143, 15))
        assert.equals("killed by signal 64", build_run.exit_text(192, 64))
        assert.equals("exit 2", build_run.exit_text(2))
    end)

    it("the failure line names the signal", function()
        assert.equals("build failed (killed by signal 9 (SIGKILL)): App/Debug",
            build_run.failure_message({ kind = "build", name = "App/Debug" }, 137, nil, 9))
        assert.equals("configure failed (exit 137): App/Debug",
            build_run.failure_message({ kind = "configure", name = "App/Debug" }, 137))
    end)
end)

--- Replace vim.system for the duration of `fn` with one whose result is `res`.
local function with_system(res, fn)
    local orig = vim.system
    local seen = {}
    vim.system = function(cmd)
        seen[#seen + 1] = cmd
        local r = vim.tbl_extend("force", { stdout = "", stderr = "" }, res)
        return { wait = function() return r end }
    end
    local ok, err = pcall(fn, seen)
    vim.system = orig
    if not ok then error(err, 0) end
end

describe("in-process step (run_spec)", function()
    local step = { cmd = { vim.v.progpath, "--version" } }

    it("a signal-ended step returns 128 + signal and the signal", function()
        with_system({ code = 0, signal = 9 }, function()
            assert.same({ 137, 9 }, { cli._run_spec(step, H.REPO) })
        end)
        with_system({ code = 0, signal = 0 }, function()
            assert.equals(0, (cli._run_spec(step, H.REPO)))
        end)
        -- Windows: a TerminateProcess'd step fails exactly as before.
        with_system({ code = 1, signal = 15 }, function()
            assert.same({ 1 }, { cli._run_spec(step, H.REPO) })
        end)
    end)

    it("`lw build`: a SIGKILLed build step fails the build, exit 137, nothing recorded as built", function()
        local overseer = require("loomworks.overseer")
        local recorded = {}
        local unit = {}
        local profile = { key = "p", assert_buildable = function() return true end, projects = function() return {} end }
        local ws = { root = H.REPO, record_task_result = function(_, r) recorded[#recorded + 1] = r end }
        local orig_plan = overseer.plan_profile_build
        overseer.plan_profile_build = function()
            return { { kind = "build", name = "App/Debug", unit = unit, cmd = { vim.v.progpath, "--version" } } }
        end
        local err_buf, out_buf, rs, rex, rw = {}, {}, io.stderr, os.exit, io.write
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
        io.write = function(s) out_buf[#out_buf + 1] = s end
        local code
        os.exit = function(c) code = c; error({ __exit = true }, 0) end
        local ok, e
        with_system({ code = 0, signal = 9 }, function()
            ok, e = pcall(function() cli._run_build_steps(profile, ws, {}) end)
        end)
        io.stderr, os.exit, io.write = rs, rex, rw
        overseer.plan_profile_build = orig_plan
        assert.is_true(ok == false and type(e) == "table" and e.__exit, "the build did not fail: " .. tostring(e))
        assert.equals(137, code)
        assert.truthy(table.concat(err_buf):find("lw: build failed (killed by signal 9 (SIGKILL)): App/Debug", 1, true),
            table.concat(err_buf))
        assert.equals(1, #recorded)
        assert.is_false(recorded[1].success)
    end)
end)

--- A build request through an authenticated connection (as in
--- daemon_build_service_spec).
local function build(srv, args)
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    conn:request({ kind = "build", args = args or { profile = "dev" }, interactive = false,
        env = envscope.capture(), command = "lw build" }, function(r, e) rec.reply = r or { error = e } end)
    function rec.done()
        for _, m in ipairs(rec.events) do if m.phase == "done" then return m end end
    end
    function rec.wait_done() return vim.wait(60000, function() return rec.done() ~= nil end, 10) end
    function rec.lines()
        local t = {}
        for _, m in ipairs(rec.events) do if m.phase == "line" then t[#t + 1] = tostring(m.text) end end
        return table.concat(t, "\n")
    end
    return rec
end

describe("daemon-routed step (runner)", function()
    local root, srv, orig_spawn
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        orig_spawn = runner.spawn
    end)
    after_each(function()
        runner.spawn = orig_spawn
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    --- The build step exits as libuv reports `code`, `signal`; the configure
    --- step runs for real.
    local function build_step_exits(code, signal)
        runner.spawn = function(spec, sink)
            if spec.cmd[#spec.cmd] ~= "build" then return orig_spawn(spec, sink) end
            vim.schedule(function() sink.done(code, signal) end)
            return { pid = nil, kill = function() end, pause = function() end,
                resume = function() end, abandon = function() end }
        end
    end

    it("a SIGKILLed build step fails the build, exit 137, nothing recorded as built", function()
        build_step_exits(0, 9)
        local r = build(srv)
        assert.is_true(r.wait_done())
        assert.equals(137, r.done().exit_code, vim.inspect(r.done()))
        assert.equals("build failed (killed by signal 9 (SIGKILL)): app: build Debug", r.done().error)
        assert.is_nil(r.lines():find("BUILD OK", 1, true))
        local cache = read(root .. "/.nvim/loomworks.cache.json") or ""
        assert.is_nil(cache:find('"built"', 1, true), cache)
        r.conn:close()
    end)

    it("Windows' emulated kill (exit 1, signal 15) fails as before", function()
        build_step_exits(1, 15)
        local r = build(srv)
        assert.is_true(r.wait_done())
        assert.equals(1, r.done().exit_code)
        assert.equals("build failed (exit 1): app: build Debug", r.done().error)
        r.conn:close()
    end)
end)
