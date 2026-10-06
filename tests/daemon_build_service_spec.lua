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

    it("sends the cache write-back's model_change before the task's done, to the owner and an observer (§19.16 End)", function()
        local seen = {}
        local obs = assert(client.session(srv.address, { client = "editor", role = "observer",
            on_message = function(m) seen[#seen + 1] = m end }))
        local all = {}
        local conn = assert(client.session(srv.address, {
            on_message = function(m) all[#all + 1] = m end }))
        local done
        conn:request({ kind = "build", args = { profile = "dev" }, interactive = false,
            env = envscope.capture(), command = "lw build" }, function() end)
        assert.is_true(vim.wait(60000, function()
            for _, m in ipairs(all) do if m.kind == "task" and m.phase == "done" then done = m; return true end end
            return false
        end, 10))
        assert.equals(0, done.exit_code)
        local function order(list)
            local last_change, done_at, start
            for i, m in ipairs(list) do
                if m.kind == "model_change" then last_change = i end
                if m.kind == "task" and m.phase == "done" then done_at = done_at or i end
                if m.kind == "task" and m.phase == "start" then start = start or m end
            end
            return last_change, done_at, start
        end
        local c1, d1, s1 = order(all)
        assert.is_not_nil(c1, "no model_change for the write-back")
        assert.is_true(c1 < d1)
        -- The start meta carries the owner's origin (protocol 7).
        assert.equals("cli", s1.meta.origin)
        assert.is_true(vim.wait(10000, function() local _, d = order(seen); return d ~= nil end, 10))
        local c2, d2, s2 = order(seen)
        assert.is_true(c2 ~= nil and c2 < d2)
        assert.equals("cli", s2.meta.origin)
        conn:close(); obs:close()
    end)

    it("status lists the running tasks with their origin; none once ended (§19.11, protocol 7)", function()
        local pidfile = H.tmp() .. "/pid"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20))
        r.wait_reply()
        local q = assert(client.session(srv.address, { client = "editor" }))
        local st = assert(client.request(q, { kind = "status" }))
        assert.equals(1, #st.tasks, vim.inspect(st.tasks))
        local t = st.tasks[1]
        assert.equals("build", t.kind)
        assert.equals("dev", t.profile)
        assert.equals("dev", t.name)
        assert.equals("cli", t.origin)
        assert.equals("app", t.units[1].project)
        -- (An opaque string on this transport-11 session; a protocol-10
        -- connection keeps its integer, §19.20.)
        assert.is_string(t.task_id)
        assert.is_true(math.abs(os.time() - t.started_at) < 120)
        -- `lw status` lists it under the Runtime row (§19.6): the handle shows
        -- a live, busy daemon with this lw's key.
        local lines
        assert.is_true(vim.wait(5000, function()
            lines = require("loomworks.daemon.running").lines(root)
            return #lines == 1
        end, 50), vim.inspect(lines))
        assert.truthy(lines[1]:find("^  build  dev  %(lw%)  %d+s  ?%d*%%?$"), lines[1])
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        st = assert(client.request(q, { kind = "status" }))
        assert.same({}, st.tasks)
        q:close()
    end)

    it("the running task's percent follows the build tool's progress lines (status, late joiner)", function()
        local pidfile = H.tmp() .. "/pid"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "build",
            LW_TEST_PIDFILE = pidfile, LW_TEST_PROGRESS = "3/4" } })
        -- configure (step 1 of 2) ran, the build step printed `[3/4]` and sleeps:
        -- (1 + 3/4) / 2 = 88%, not the step-boundary 50%.
        assert.is_true(vim.wait(60000, function() return read(pidfile .. ".build") ~= nil end, 20))
        local q = assert(client.session(srv.address, { client = "editor" }))
        local st
        for _ = 1, 100 do -- (no request inside a vim.wait condition)
            st = assert(client.request(q, { kind = "status" }))
            if st.tasks[1] and st.tasks[1].percent ~= nil and st.tasks[1].percent >= 88 then break end
            vim.wait(100)
        end
        assert.equals(88, st.tasks[1] and st.tasks[1].percent, vim.inspect(st.tasks))
        -- The owner's stream carried the same tick.
        local last
        for _, m in ipairs(r.events) do if m.phase == "progress" then last = m.pct end end
        assert.equals(88, last)
        -- `lw status` shows it.
        local lines
        assert.is_true(vim.wait(5000, function()
            lines = require("loomworks.daemon.running").lines(root)
            return #lines == 1 and lines[1]:find("88%%$") ~= nil
        end, 50), vim.inspect(lines))
        -- An editor that joins now adopts the current percent, not 0.
        local adopted = require("loomworks.daemon.remote_task").adopt(nil, st.tasks[1], 0, os.time())
        assert.equals(88, adopted.pct)
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        q:close()
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

    it("applies a loomworks.json AND a working-copy change made together before the next build (§19.15, §2.7)", function()
        local r = build(srv)
        assert.is_true(r.wait_done())
        r.conn:close()
        -- Another process changes the build command and, before the daemon
        -- syncs, the working copy (a profile description, signed like lw does).
        local cfg = vim.json.decode(read(root .. "/loomworks.json"))
        table.insert(cfg.projects.app.shell.build_cmd, "changed")
        local f = io.open(root .. "/loomworks.json", "w"); f:write(vim.json.encode(cfg)); f:close()
        local upath = root .. "/.nvim/loomworks.user.json"
        local status, body = trust.verify("user", read(upath))
        assert.equals("valid", status)
        local user = vim.json.decode(body)
        user.profiles.dev.description = "edited elsewhere"
        local signed = trust.sign("user", trust.encode(user))
        f = io.open(upath, "wb"); f:write(signed); f:close()
        r = build(srv)
        assert.is_true(r.wait_reply())
        assert.is_nil(r.reply.outcome == "refused" and r.reply.message or nil)
        assert.is_true(r.wait_done())
        assert.truthy(r.text("output"):find("ARGS=changed", 1, true), r.text("output"))
        r.conn:close()
        -- Both edits are applied, and the working copy on disk keeps the other one.
        local ws = require("loomworks")._core()._workspace
        local desc = {}
        for _, p in pairs(ws:get_profiles()) do desc[#desc + 1] = p.description end
        assert.same({ "edited elsewhere" }, desc)
        local _, now = trust.verify("user", read(upath))
        assert.equals("edited elsewhere", vim.json.decode(now).profiles.dev.description)
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
