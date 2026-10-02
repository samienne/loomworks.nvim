-- The workspace daemon's build service in-process (spec §19.15, §19.19 step
-- 3): an in-process server with the build service attached (the host is the
-- CLI's own workspace load), a real authenticated client, a real workspace on
-- disk whose `shell` project runs real processes. Covers acceptance and the
-- task stream, refusals and declines before any side effect, the requesting
-- client's environment, the live workspace (external changes, trust refusal),
-- cancellation (client disconnect, daemon stop) and the build locks.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_run = require("loomworks.build_run")
local build_lock = require("loomworks.build_lock")
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

--- A build request through an authenticated connection. Returns a recorder:
--- { reply, events, lines(), output(), done }.
local function build(srv, args, opts)
    opts = opts or {}
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    local env = envscope.capture()
    for k, v in pairs(opts.env or {}) do env[k] = v or nil end
    conn:request({ kind = "build", args = args or { profile = "dev" }, interactive = opts.interactive or false,
        env = env, command = "lw build" }, function(r, e) rec.reply = r or { error = e } end)
    function rec.wait_reply() return vim.wait(60000, function() return rec.reply ~= nil end, 10) end
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

describe("daemon build service (§19.15)", function()
    local root, srv, exited
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        exited = nil
        srv = server_mod.new(root, { exit = function(c) exited = c end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("accepts a build, streams its lines and output, and records the result", function()
        local r = build(srv)
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("dev", r.reply.profile_key)
        assert.equals(srv.pid, r.reply.pid)
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code)
        assert.is_nil(r.done().error)
        local lines = r.text("line")
        assert.truthy(lines:find("out:building profile: dev", 1, true))
        assert.truthy(lines:find("out:==> [build] app", 1, true))
        assert.truthy(lines:find("out:BUILD OK: dev", 1, true))
        assert.truthy(r.text("output"):find("step build", 1, true))
        assert.truthy(r.text("output"):find("stderr of build", 1, true))
        -- The cache write-back of the in-process path (record_task_result).
        local cache = read(root .. "/.nvim/loomworks.cache.json")
        assert.truthy(cache and cache:find('"built"', 1, true))
        r.conn:close()
        assert.is_false(srv.busy)
    end)

    it("refuses before any side effect, with the in-process message", function()
        local r = build(srv, {})
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome)
        local _, want = build_run.resolve_target(srv.service.ws, nil, { interactive = false })
        assert.equals(want, r.reply.message)
        assert.equals(1, r.reply.exit_code)
        r = build(srv, { profile = "nope" })
        assert.is_true(r.wait_reply())
        assert.equals("no profile matching 'nope'. Run `lw profile list` to list.", r.reply.message)
        r = build(srv, { profile = "9" })
        assert.is_true(r.wait_reply())
        assert.equals("profile number 9 out of range (1..1); see `lw profile list`", r.reply.message)
        assert.is_nil(read(root .. "/.nvim/loomworks.cache.json"))
        r.conn:close()
    end)

    it("declines interactive onboarding (the client runs it in-process)", function()
        local r = build(srv, { profile = "dev2" }, { interactive = true })
        assert.is_true(r.wait_reply())
        assert.equals("declined", r.reply.outcome)
        r.conn:close()
    end)

    it("runs the build in the requesting client's environment", function()
        assert.is_nil(os.getenv("LW_TEST_FOO"))
        vim.env.LW_TEST_ONLY = "daemon-side"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_FOO = "from-client", LW_TEST_ONLY = false } })
        assert.is_true(r.wait_done())
        local o = r.text("output")
        assert.truthy(o:find("FOO=from-client", 1, true), o)
        -- A variable only the daemon has does not reach the step.
        assert.truthy(o:find("ONLY=nil", 1, true), o)
        -- The daemon's own environment is restored after the request.
        assert.is_nil(os.getenv("LW_TEST_FOO"))
        assert.equals("daemon-side", os.getenv("LW_TEST_ONLY"))
        vim.env.LW_TEST_ONLY = nil
        r.conn:close()
    end)

    it("forwards the build-tool args and announces the command with -v", function()
        local r = build(srv, { profile = "dev", extra = { "x1", "x2" }, verbose = true })
        assert.is_true(r.wait_done())
        assert.truthy(r.text("output"):find("ARGS=x1,x2", 1, true))
        assert.truthy(r.text("line"):find("out:    $ ", 1, true))
        -- --target on a module that cannot select one: the plan refusal.
        local t = build(srv, { profile = "dev", targets = { "foo" } })
        assert.is_true(t.wait_done())
        assert.equals(1, t.done().exit_code)
        assert.truthy(t.done().error:find("does not support --target", 1, true))
        r.conn:close(); t.conn:close()
    end)

    it("ends with the step's exit code and the in-process failure line", function()
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_FAIL = "build" } })
        assert.is_true(r.wait_done())
        assert.equals(3, r.done().exit_code)
        assert.equals("build failed (exit 3): app: build Debug", r.done().error)
        r.conn:close()
    end)

    it("applies external file changes before the next build (live workspace)", function()
        local r = build(srv)
        assert.is_true(r.wait_done())
        r.conn:close()
        -- Another process changes the build command.
        local cfg = vim.json.decode(read(root .. "/loomworks.json"))
        table.insert(cfg.projects.app.shell.build_cmd, "changed")
        local f = io.open(root .. "/loomworks.json", "w"); f:write(vim.json.encode(cfg)); f:close()
        r = build(srv)
        assert.is_true(r.wait_done())
        assert.truthy(r.text("output"):find("ARGS=changed", 1, true), r.text("output"))
        r.conn:close()
    end)

    it("re-checks trust on the live workspace: a tampered working copy is refused", function()
        local r = build(srv)
        assert.is_true(r.wait_done())
        r.conn:close()
        local path = root .. "/.nvim/loomworks.user.json"
        local text = read(path)
        local f = io.open(path, "wb"); f:write((text:gsub('"dev"', '"dev" ', 1))); f:close()
        r = build(srv)
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome)
        assert.equals(cli._setup_failure(require("loomworks")._core()).message, r.reply.message)
        assert.truthy(r.reply.message:find("lw trust", 1, true))
        r.conn:close()
    end)

    it("cancels a build whose client disconnects: tree killed, lock released, nothing recorded", function()
        local pidfile = H.tmp() .. "/pid"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20),
            vim.inspect({ r.reply, r.events }))
        local spid = tonumber(read(pidfile .. ".configure"))
        local sst = proc.start_time(spid)
        assert.equals(true, proc.alive(spid, sst), vim.inspect({ spid, sst, read(pidfile .. ".configure") }))
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        assert.truthy(build_lock.read(bd))
        assert.is_true(srv.busy)
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        assert.is_true(vim.wait(5000, function() return build_lock.read(bd) == nil end, 20))
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 20))
        -- The interrupted step recorded nothing.
        assert.is_nil(read(root .. "/.nvim/loomworks.cache.json"))
        -- The next build runs normally.
        local n = build(srv)
        assert.is_true(n.wait_done())
        assert.equals(0, n.done().exit_code)
        n.conn:close()
    end)

    it("a stopping daemon ends its builds: step killed, lock released, client told", function()
        local pidfile = H.tmp() .. "/pid"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20))
        local spid = tonumber(read(pidfile .. ".configure"))
        local sst = proc.start_time(spid)
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        srv:stop("stop requested", 0)
        assert.equals(0, exited)
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        assert.is_nil(build_lock.read(bd))
        vim.wait(2000, function() return r.done() ~= nil or r.conn.closed end, 10)
        if r.done() then
            assert.truthy(r.done().error:find("the workspace daemon stopped", 1, true))
            assert.is_true(r.done().exit_code ~= 0)
        end
    end)

    it("two builds of one build directory: the second is refused naming the daemon", function()
        local pidfile = H.tmp() .. "/pid"
        local a = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20))
        -- (The same environment: a different one is declined while a build
        -- runs, see below.)
        local b = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(b.wait_done())
        assert.equals(1, b.done().exit_code)
        assert.truthy(b.done().error:find("in use by the workspace daemon (pid " .. srv.pid, 1, true), b.done().error)
        b.conn:close()
        a.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
    end)

    it("declines a build in another environment while a build runs (the client builds in-process)", function()
        local pidfile = H.tmp() .. "/pid"
        local a = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20))
        local b = build(srv)
        assert.is_true(b.wait_reply())
        assert.equals("declined", b.reply.outcome)
        b.conn:close()
        a.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
    end)
end)
