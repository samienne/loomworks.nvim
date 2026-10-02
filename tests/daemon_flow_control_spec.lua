-- Flow control of the workspace daemon's task stream (spec §19.15): the
-- owner's stream is lossless but flow-controlled (a client that stops reading
-- — `lw build | less`, paused — makes the daemon stop reading the step's
-- output, so the build tool blocks as it would in-process, and the daemon's
-- memory stays bounded); observers are capped by bytes per task and a slow
-- observer is dropped. Also: two terminals whose environments differ only in
-- per-session variables share the warm workspace; the step kill falls back
-- when the tree kill fails; a disconnect never kills inside the read callback.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local tasks_mod = require("loomworks.daemon.tasks")
local runner = require("loomworks.daemon.runner")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_lock = require("loomworks.build_lock")
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000
local MiB = 1024 * 1024

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

--- The shell workspace's step script, plus: with $LW_TEST_SPEW_MB, the build
--- step writes that many MiB of numbered 12-byte lines on stdout.
local SPEW = [[
if kind == "build" and os.getenv("LW_TEST_SPEW_MB") then
    local total = math.floor(tonumber(os.getenv("LW_TEST_SPEW_MB")) * 1048576 / 12)
    local i = 0
    while i < total do
        local t = {}
        for _ = 1, 5000 do
            i = i + 1
            if i > total then break end
            t[#t + 1] = string.format("%011d", i)
        end
        io.stdout:write(table.concat(t, string.char(10)) .. string.char(10))
    end
    io.stdout:flush()
end
]]

local function spew_workspace()
    local root = H.shell_workspace({ profile = true })
    local step = H.STEP:gsub("local ms = tonumber", function(m) return SPEW .. m end, 1)
    local f = io.open(root .. "/step.lua", "w"); f:write(step); f:close()
    return root
end

--- A build request through an authenticated connection (as in
--- daemon_build_service_spec).
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
    conn:request({ kind = "build", args = args or { profile = "dev" }, interactive = false,
        env = env, command = "lw build" }, function(r, e) rec.reply = r or { error = e } end)
    function rec.wait_reply() return vim.wait(60000, function() return rec.reply ~= nil end, 10) end
    function rec.done()
        for _, m in ipairs(rec.events) do if m.phase == "done" then return m end end
    end
    function rec.wait_done(ms) return vim.wait(ms or 60000, function() return rec.done() ~= nil end, 10) end
    function rec.stdout()
        local t = {}
        for _, m in ipairs(rec.events) do
            if m.phase == "output" and m.stream == "stdout" then t[#t + 1] = m.text end
        end
        return table.concat(t)
    end
    return rec
end

--- The numbered lines in `text` are exactly 1..n, in order. Returns n.
local function check_sequence(text)
    local n = 0
    for line in text:gmatch("([^\n]*)\n") do
        -- (CRLF on Windows: the step writes in text mode.)
        line = line:gsub("\r$", "")
        if line:match("^%d+$") then
            n = n + 1
            if tonumber(line) ~= n then error("line " .. n .. " is " .. line) end
        end
    end
    return n
end

local function qsize(conn)
    local ok, n = pcall(function() return conn.sock:get_write_queue_size() end)
    return ok and n or 0
end

describe("daemon task stream flow control (§19.15)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = spew_workspace()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("an owner that stops reading pauses the step (bounded queue) and still gets all output in order", function()
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SPEW_MB = "24" } })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        r.conn:pause_reading()
        local task = srv.service.tasks.tasks[r.reply.task_id]
        assert.is_not_nil(task)
        local owner, maxq = task.owner, 0
        vim.wait(4000, function()
            local q = qsize(owner)
            if q > maxq then maxq = q end
            return false
        end, 20)
        -- The build is held (its tool blocked writing), not finished, and the
        -- daemon queued a few MiB at most — not the whole 24 MiB.
        assert.is_true(srv.busy)
        assert.is_true(maxq < 12 * MiB, "write queue reached " .. maxq)
        r.conn:resume_reading()
        assert.is_true(r.wait_done(180000))
        assert.equals(0, r.done().exit_code, vim.inspect(r.done()))
        assert.equals(math.floor(24 * MiB / 12), check_sequence(r.stdout()))
        r.conn:close()
    end)

    it("a paused owner that disconnects cancels the build: step killed, lock released", function()
        local pidfile = H.tmp() .. "/pid"
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SPEW_MB = "64", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome)
        r.conn:pause_reading()
        local task = srv.service.tasks.tasks[r.reply.task_id]
        assert.is_true(vim.wait(30000, function() return qsize(task.owner) > 2 * MiB end, 20))
        assert.is_true(vim.wait(10000, function() return read(pidfile .. ".build") ~= nil end, 20))
        local spid = tonumber(read(pidfile .. ".build"))
        local sst = proc.start_time(spid)
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        assert.is_nil(build_lock.read(bd))
    end)

    it("observers get at most OBSERVER_CAP_BYTES of a task's output, then one truncation notice", function()
        local seen = {}
        local obs = client.session(srv.address, {
            on_message = function(m) if m.kind == "task" then seen[#seen + 1] = m end end,
        })
        assert.is_not_nil(obs)
        local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SPEW_MB = "12" } })
        assert.is_true(r.wait_done(120000))
        assert.equals(0, r.done().exit_code)
        assert.is_true(vim.wait(10000, function()
            for _, m in ipairs(seen) do if m.phase == "done" then return true end end
        end, 10))
        local bytes, notices = 0, 0
        for _, m in ipairs(seen) do
            if m.phase == "output" then
                if m.text:find("[loomworks: task output truncated", 1, true) then notices = notices + 1
                else bytes = bytes + #m.text end
            end
        end
        assert.is_true(bytes <= tasks_mod.OBSERVER_CAP_BYTES, "observer got " .. bytes)
        assert.is_true(bytes > 0)
        assert.equals(1, notices)
        obs:close(); r.conn:close()
    end)

    it("an observer that falls too far behind is dropped; the build is unaffected", function()
        local saved = tasks_mod.OBSERVER_QUEUE_MAX
        tasks_mod.OBSERVER_QUEUE_MAX = 256 * 1024
        local ok, err = pcall(function()
            local obs = client.session(srv.address, { on_message = function() end })
            assert.is_not_nil(obs)
            obs:pause_reading()
            local r = build(srv, { profile = "dev" }, { env = { LW_TEST_SPEW_MB = "8" } })
            assert.is_true(r.wait_done(120000))
            assert.equals(0, r.done().exit_code)
            assert.equals(math.floor(8 * MiB / 12), check_sequence(r.stdout()))
            -- Only the owner is still connected.
            assert.equals(1, srv:client_count())
            obs:resume_reading()
            assert.is_true(vim.wait(10000, function() return obs.closed end, 10))
            r.conn:close()
        end)
        tasks_mod.OBSERVER_QUEUE_MAX = saved
        if not ok then error(err, 0) end
    end)

    it("two terminals differing only in session variables share the warm workspace", function()
        local pidfile = H.tmp() .. "/pid"
        local function session_env(tag)
            return { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile, WT_SESSION = "wt-" .. tag,
                TERM_SESSION_ID = "ts-" .. tag, TMUX = "/tmp/tmux-" .. tag, TMUX_PANE = "%" .. tag,
                SSH_CONNECTION = "10.0.0." .. tag .. " 22", SSH_TTY = "/dev/pts/" .. tag,
                VSCODE_GIT_IPC_HANDLE = "ipc-" .. tag, VSCODE_IPC_HOOK_CLI = "hook-" .. tag,
                WINDOWID = tag, KITTY_WINDOW_ID = tag, WEZTERM_PANE = tag, GPG_TTY = "/dev/pts/" .. tag }
        end
        local a = build(srv, { profile = "dev" }, { env = session_env("1") })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20))
        local ws = srv.service.ws
        -- Another terminal, same build directory: not declined (it would run
        -- in-process) but carried, and refused by the build lock like any
        -- second build of one directory.
        local b = build(srv, { profile = "dev" }, { env = session_env("2") })
        assert.is_true(b.wait_reply())
        assert.equals("accepted", b.reply.outcome, vim.inspect(b.reply))
        assert.is_true(b.wait_done())
        assert.truthy(b.done().error:find("in use by the workspace daemon", 1, true), b.done().error)
        assert.equals(ws, srv.service.ws)
        b.conn:close()
        a.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        -- A PATH difference still reloads.
        local pk = "PATH"
        for k in pairs(envscope.capture()) do if k:upper() == "PATH" then pk = k end end
        local sep = H.is_win and ";" or ":"
        local c = build(srv, { profile = "dev" }, { env = { [pk] = os.getenv(pk) .. sep .. H.tmp() } })
        assert.is_true(c.wait_done())
        assert.are_not.equal(ws, srv.service.ws)
        c.conn:close()
    end)
end)

describe("daemon build cancellation helpers", function()
    it("runner.kill falls back to killing the child object when the tree kill fails", function()
        local orig = proc.kill_tree
        proc.kill_tree = function() return false, "process 1 is still running" end
        local sig
        local ok, err = pcall(runner.kill, { pid = 1, start = "x", obj = { kill = function(_, s) sig = s end } })
        proc.kill_tree = orig
        assert.is_true(ok, err)
        assert.equals("sigkill", sig)
    end)

    it("a closed connection's builds are cancelled outside the read callback", function()
        local root = H.workspace()
        local srv = server_mod.new(root, { exit = function() end, tick_ms = 100 })
        local svc = service.attach(srv, { load = function() end, unload = function() end, current = function() end })
        local conn, cancelled = {}, nil
        local run = { ctx = { conn = conn }, cancel = function(why) cancelled = why end }
        svc.runs[run] = true
        svc:on_conn_closed(conn)
        assert.is_nil(cancelled)
        assert.is_true(vim.wait(2000, function() return cancelled ~= nil end, 10))
        assert.truthy(cancelled:find("disconnected", 1, true))
    end)
end)
