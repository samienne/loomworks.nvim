-- The workspace daemon's test run in-process (spec §19.15, §16.16): an
-- in-process server with the build service attached, a real authenticated
-- client, a real `shell` workspace running real processes. Covers what the
-- saved-test plan does on the daemon's event loop: a step's framework probe
-- and a launch's deploy never block it (other clients are served meanwhile),
-- a cancel during a probe or a saved step kills it and releases the locks,
-- and two test runs of one build directory (the second fails fast, as two
-- builds do).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_lock = require("loomworks.build_lock")
local gtest = require("loomworks.gtest")
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000
require("loomworks.daemon.running").TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

--- A request (`test` by default) through an authenticated connection.
--- Returns a recorder: { reply, events, done(), wait_done(), text(phase) }.
local function request(srv, kind, args, opts)
    opts = opts or {}
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    local env = envscope.capture()
    for k, v in pairs(opts.env or {}) do env[k] = v or nil end
    conn:request({ kind = kind, args = args or { profile = "dev" }, interactive = false,
        env = env, command = "lw " .. kind }, function(r, e) rec.reply = r or { error = e } end)
    function rec.done()
        for _, m in ipairs(rec.events) do if m.phase == "done" then return m end end
    end
    function rec.wait_done(ms) return vim.wait(ms or 60000, function() return rec.done() ~= nil end, 10) end
    function rec.text(phase)
        local t = {}
        for _, m in ipairs(rec.events) do
            if m.phase == phase then t[#t + 1] = (phase == "line" and (m.stream .. ":") or "") .. tostring(m.text) end
        end
        return table.concat(t, phase == "line" and "\n" or "")
    end
    return rec
end

--- The pid in `<pidfile>.<kind>` once the step wrote it, and its start time.
local function step_pid(pidfile, kind, r)
    assert.is_true(vim.wait(30000, function() return read(pidfile .. "." .. kind) ~= nil end, 20),
        "step " .. kind .. " never started" .. (r and ("\n" .. vim.inspect(r.reply) .. "\n" .. r.text("line")
            .. "\n" .. r.text("output") .. "\n" .. vim.inspect(r.done())) or ""))
    local pid = tonumber(read(pidfile .. "." .. kind))
    return pid, proc.start_time(pid)
end

--- The `lw-test-*.xml` results files left in the workspace's .nvim/tmp.
local function results_files(root)
    local out = {}
    local h = uv.fs_scandir(root .. "/.nvim/tmp")
    while h do
        local name = uv.fs_scandir_next(h)
        if not name then break end
        if name:match("^lw%-test%-") then out[#out + 1] = name end
    end
    return out
end

describe("daemon test run (§19.15, §16.16)", function()
    local root, srv, step
    local shell = require("loomworks.modules.shell")
    local saved_parse, saved_argv, saved_timeout
    local nv = (vim.v.progpath:gsub("\\", "/"))

    local function start(opts)
        root = H.shell_workspace(vim.tbl_extend("force", { profile = true }, opts or {}))
        step = root .. "/step.lua"
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        saved_parse, saved_argv, saved_timeout = shell.parse_targets, gtest.probe_argv, gtest.PROBE_TIMEOUT_MS
    end)
    after_each(function()
        shell.parse_targets, gtest.probe_argv, gtest.PROBE_TIMEOUT_MS = saved_parse, saved_argv, saved_timeout
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
        srv = nil
    end)

    --- A saved test target naming an executable build target: the module
    --- reports one (its artifact this nvim, a host program), and the probe
    --- of it is the step script's `probe` step (seam: gtest.probe_argv).
    local function with_probed_target()
        shell.parse_targets = function() return { t1 = { type = "executable", artifact = nv } } end
        gtest.probe_argv = function() return { nv, "--headless", "-u", "NONE", "-l", step, "probe" } end
        gtest.PROBE_TIMEOUT_MS = 60000
        start({ tests = { "t1" } })
    end

    it("a step's framework probe runs on the event loop: another client is answered meanwhile", function()
        with_probed_target()
        local pidfile = H.tmp() .. "/pid"
        local r = request(srv, "test", nil, { env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "probe",
            LW_TEST_PIDFILE = pidfile } })
        local pid, st = step_pid(pidfile, "probe")
        assert.equals(true, proc.alive(pid, st))
        -- While the probe runs, a second client's request is served (a
        -- blocking probe would hold the loop until it ended or timed out).
        local other = client.session(srv.address, {})
        local status
        other:request({ kind = "status" }, function(reply) status = reply end)
        assert.is_true(vim.wait(10000, function() return status ~= nil end, 10), "status not answered")
        assert.equals(true, proc.alive(pid, st), "the probe ended before the other client was served")
        assert.is_true(srv.busy)
        other:close()
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return proc.alive(pid, st) ~= true end, 20))
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 20))
    end)

    it("a cancel during a probe kills it, skips the step and releases the lock", function()
        with_probed_target()
        local pidfile = H.tmp() .. "/pid"
        local r = request(srv, "test", nil, { env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "probe",
            LW_TEST_PIDFILE = pidfile } })
        local pid, st = step_pid(pidfile, "probe")
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        assert.truthy(build_lock.read(bd))
        local run = next(srv.service.runs)
        assert.is_not_nil(run)
        run.cancel("cancelled by test")
        assert.is_true(r.wait_done(15000))
        assert.truthy(r.done().error:find("test stopped: cancelled by test", 1, true), r.done().error)
        assert.is_true(r.done().exit_code ~= 0)
        assert.is_true(vim.wait(15000, function() return proc.alive(pid, st) ~= true end, 20))
        assert.is_nil(build_lock.read(bd))
        -- The step's program never ran, and left no results file.
        assert.is_nil(r.text("line"):find("t1: ", 1, true))
        assert.same({}, results_files(root))
        r.conn:close()
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 20))
    end)

    it("a cancel during a saved launch step kills its program and releases the lock; the next run passes", function()
        -- (Saved targets need a module with build targets: none here.)
        shell.parse_targets = function() return {} end
        start({
            launch = { chk = { command = nv, args = { "--headless", "-u", "NONE", "-l", "${workspace_root}/step.lua", "saved" } } },
            tests = { "chk" },
        })
        local pidfile = H.tmp() .. "/pid"
        local r = request(srv, "test", nil, { env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "saved",
            LW_TEST_PIDFILE = pidfile } })
        local pid, st = step_pid(pidfile, "saved", r)
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        assert.truthy(build_lock.read(bd))
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return proc.alive(pid, st) ~= true end, 20))
        assert.is_true(vim.wait(5000, function() return build_lock.read(bd) == nil end, 20))
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 20))
        local n = request(srv, "test")
        assert.is_true(n.wait_done())
        assert.equals(0, n.done().exit_code, n.text("line") .. "\n" .. tostring(n.done().error))
        assert.truthy(n.text("line"):find("TESTS OK: dev", 1, true), n.text("line"))
        n.conn:close()
    end)

    it("two test runs of one build directory: the second fails fast naming the daemon (as two builds)", function()
        -- (Saved targets need a module with build targets: none here.)
        shell.parse_targets = function() return {} end
        start({
            launch = { chk = { command = nv, args = { "--headless", "-u", "NONE", "-l", "${workspace_root}/step.lua", "saved" } } },
            tests = { "chk" },
        })
        local pidfile = H.tmp() .. "/pid"
        local env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "saved", LW_TEST_PIDFILE = pidfile }
        local a = request(srv, "test", nil, { env = env })
        step_pid(pidfile, "saved")
        local b = request(srv, "test", nil, { env = env })
        assert.is_true(b.wait_done(30000))
        assert.equals(1, b.done().exit_code)
        assert.truthy(b.done().error:find("in use by the workspace daemon (pid " .. srv.pid, 1, true), b.done().error)
        b.conn:close()
        a.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
    end)

    it("a failed step with per-case results keeps its counts in its line and the summary", function()
        -- A gtest-probed build target (the probe lists a suite) whose program
        -- (this nvim, which rejects the results option: exit status 1) leaves
        -- a results file with one failure, two passes, a skip and a disabled
        -- case (seam: housekeeping.tmp_path names the pre-written file).
        local probe = H.tmp() .. "/probe.lua"
        local f = assert(io.open(probe, "wb")); f:write('io.write("Suite.\\n  a\\n")'); f:close()
        shell.parse_targets = function() return { t1 = { type = "executable", artifact = nv } } end
        gtest.probe_argv = function() return { nv, "--headless", "-u", "NONE", "-l", probe } end
        start({ tests = { "t1" } })
        local xml = H.tmp() .. "/results.xml"
        f = assert(io.open(xml, "wb"))
        f:write(table.concat({ '<?xml version="1.0" encoding="UTF-8"?>', '<testsuites tests="5">',
            '  <testsuite name="Suite">',
            '    <testcase name="a" status="run" time="0.01" classname="Suite" />',
            '    <testcase name="b" status="run" time="0.01" classname="Suite">',
            '      <failure message="t.cpp:3" type=""><![CDATA[t.cpp:3]]></failure>',
            '    </testcase>',
            '    <testcase name="c" status="run" time="0.01" classname="Suite" />',
            '    <testcase name="d" status="run" result="skipped" time="0" classname="Suite">',
            '      <skipped message="t.cpp:9"><![CDATA[t.cpp:9]]></skipped>',
            '    </testcase>',
            '    <testcase name="DISABLED_e" status="notrun" result="suppressed" time="0" classname="Suite" />',
            '  </testsuite>', '</testsuites>' }, "\n"))
        f:close()
        local hk = require("loomworks.housekeeping")
        local orig = hk.tmp_path
        hk.tmp_path = function(r, prefix, ext)
            if prefix == "lw-test-" then return xml end
            return orig(r, prefix, ext)
        end
        local r = request(srv, "test")
        local done = r.wait_done()
        hk.tmp_path = orig
        assert.is_true(done)
        local lines = r.text("line")
        assert.equals(1, r.done().exit_code, lines .. "\n" .. tostring(r.done().error))
        assert.truthy(lines:find("t1: FAILED (exit status 1, 1 failed test, 2 passed, 1 skipped, 1 disabled): Suite.b",
            1, true), lines)
        assert.truthy(lines:find("app: t1%s+FAILED %(exit status 1, 1 failed test, 2 passed, 1 skipped, 1 disabled%)"),
            lines)
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
    end)
end)

describe("deploy copies asynchronously (the daemon's test step)", function()
    local deploy = require("loomworks.deploy")
    local orig
    before_each(function() orig = deploy.resolve_deploy_step end)
    after_each(function() deploy.resolve_deploy_step = orig end)

    it("never completes before returning, and a cancel skips the remaining copies", function()
        local dir = H.tmp()
        local src = dir .. "/src.bin"
        local f = assert(io.open(src, "wb")); f:write(string.rep("x", 4096)); f:close()
        deploy.resolve_deploy_step = function(dest)
            return { source_path = src, dest_path = dir .. "/" .. dest, source_build_dir_id = "b", source_rel_path = "src.bin" }
        end
        local copies = 0
        local done
        deploy.execute_deploy_steps({ ["a.bin"] = { project = "p" }, ["b.bin"] = { project = "p" } }, {}, {},
            function(p) return p end, function(ok, err) done = { ok, err } end,
            { async = true, cancelled = function() return copies >= 1 end,
              resume = function(fn) copies = copies + 1; fn() end })
        assert.is_nil(done) -- (the copy is in flight on the loop)
        assert.is_true(vim.wait(5000, function() return done ~= nil end, 10))
        assert.same({ false, "cancelled" }, done)
        local n = (uv.fs_stat(dir .. "/a.bin") and 1 or 0) + (uv.fs_stat(dir .. "/b.bin") and 1 or 0)
        assert.equals(1, n)
    end)
end)
