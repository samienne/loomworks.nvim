-- The workspace daemon's devices (spec §19.16 "Devices", §19.18, §19.20
-- `Devices/1`, `Profiles/1.set_device` / `clear_device`; API.md §11, §15;
-- step 5n part B2), over the loopback transport on the conformance runner's
-- `devices` fixture (the harness-only devstub module): what a transcript
-- cannot show — the caller's environment reaching the module and its
-- commands, a cancel killing a command, the tasks owned by their
-- connection, the lock order B → D (an install holds its build directory
-- while it waits for the device), a device held by another process, and a
-- stop of another client's launch. Then `Launch/1.device_log` (API.md
-- §9.5; step 5n part B3): the records of the `log` signal, the prefilter,
-- the dropped count, cancel, disconnect, the pid-gone end and its refusals.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local uv = vim.uv or vim.loop
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")
local trust = require("loomworks.trust")
local build_lock = require("loomworks.build_lock")
local device_lock = require("loomworks.remote.device_lock")
local devices = require("loomworks.daemon.devices")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

--- The fixture's profile, named as the editor names its active one.
local DEV = { profile = { key = "dev" } }

local function read(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local s = f:read("*a")
    f:close()
    return s
end

--- A loopback daemon on a fresh `devices` fixture, handshaken. `extra`: the
--- client environment's additions (its device-lock directory is fresh).
local function session(extra)
    local key = (vim.fn.tempname():gsub("\\", "/")) .. "/trust.key"
    vim.fn.mkdir(vim.fn.fnamemodify(key, ":h"), "p")
    trust._set_key_path(key)
    local root = runner.fixture("devices", key)
    trust._set_key_path(key)
    runner.register_devstub()
    local d = runner.loopback_driver(root)
    local lockdir = (vim.fn.tempname():gsub("\\", "/"))
    local s = { d = d, root = root, inbox = {}, req = 0, lockdir = lockdir,
        log = lockdir .. "-device.log" }
    s.env = runner.wire_env(uv.os_environ())
    s.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
    s.env.LW_TEST_DEVICE_LOG = s.log
    for k, v in pairs(extra or {}) do s.env[k] = v end
    -- (This process computes the same lock paths.)
    s.saved_lockdir = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
    vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
    function s.send(f) assert(d.send(f)) end
    --- Next frame satisfying `pred` (others kept for later).
    function s.wait(pred, ms)
        local deadline = uv.now() + (ms or 30000)
        while true do
            for i, f in ipairs(s.inbox) do
                if pred(f) then table.remove(s.inbox, i); return f end
            end
            local left = deadline - uv.now()
            assert(left > 0, "timed out waiting for a frame")
            local f = d.recv(math.min(left, 50))
            if f then s.inbox[#s.inbox + 1] = f end
        end
    end
    --- Send a call without waiting for its reply; returns its req_id.
    function s.send_call(object, iface, method, args, env)
        s.req = s.req + 1
        local id = s.req
        if args == nil or next(args) == nil then args = vim.empty_dict() end
        s.send({ kind = "call", req_id = id, object = object, iface = iface, v = 1, method = method,
            args = args, env = env })
        return id
    end
    --- The reply frame of call `id`.
    function s.reply(id, ms)
        return s.wait(function(m) return m.req_id == id end, ms)
    end
    --- A call's reply frame.
    function s.raw(object, iface, method, args, env)
        return s.reply(s.send_call(object, iface, method, args, env))
    end
    --- Serve the daemon (frames kept) until `fn()` holds.
    function s.poll(fn, ms)
        local deadline = uv.now() + (ms or 30000)
        while not fn() do
            local left = deadline - uv.now()
            assert(left > 0, "timed out waiting for a condition")
            local f = d.recv(math.min(left, 50))
            if f then s.inbox[#s.inbox + 1] = f end
        end
    end
    function s.call(object, iface, method, args, env)
        local f = s.raw(object, iface, method, args, env)
        assert.equals("ok", f.kind, vim.inspect(f))
        return f.result
    end
    function s.dev(method, args, env)
        return s.call("/devices", "loomworks.Devices", method, args, env or s.env)
    end
    function s.list() return s.dev("list").devices end
    --- Start a task method; returns its task id.
    function s.start(method, args, env)
        local r = s.dev(method, args, env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        return r.task_id
    end
    --- The lines, output and done frame of a task.
    function s.done(task_id, ms)
        local lines, out = {}, {}
        while true do
            local f = s.wait(function(m)
                return m.kind == "task" and m.task_id == task_id
                    and (m.phase == "line" or m.phase == "output" or m.phase == "done")
            end, ms)
            if f.phase == "done" then return f, lines, table.concat(out) end
            if f.phase == "line" then lines[#lines + 1] = f.stream .. ": " .. f.text else out[#out + 1] = f.text end
        end
    end
    --- The next line of a task (other frames kept).
    function s.line(task_id, ms)
        return s.wait(function(m) return m.kind == "task" and m.task_id == task_id and m.phase == "line" end, ms)
    end
    function s.set_device(serial)
        local r = s.call("/profiles", "loomworks.Profiles", "set_device",
            { profile = { key = "dev" }, device = { key = serial } }, s.env)
        assert.equals("ok", r.outcome, vim.inspect(r))
    end
    function s.scan()
        local f = s.done(s.start("scan"))
        assert.equals(0, f.exit_code, vim.inspect(f))
    end
    function s.service() return d.server.service end
    function s.unit()
        local ws = s.service().ws
        return ws._active_profile:projects()[1]._config_unit
    end
    s.send({ kind = "hello", protocol = 11, client = "editor", lw_version = require("loomworks.daemon.version").identity() })
    s.wait(function(m) return m.kind == "welcome" end)
    function s.close()
        pcall(d.close)
        trust._set_key_path(nil)
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = s.saved_lockdir
    end
    return s
end

describe("Devices/1 in the workspace daemon (§19.16 Devices)", function()
    local s
    after_each(function()
        L.cleanup()
        if s then s.close(); s = nil end
    end)

    it("list never probes; a scan in the caller's environment fills the registry and signals changed", function()
        s = session()
        assert.same({}, s.list())
        local sub = s.call("/", "loomworks.Root", "subscribe",
            { object = "/devices", iface = "loomworks.Devices", v = 1, signals = { "changed" } })
        local id = s.start("scan", nil, vim.tbl_extend("force", s.env, { LW_TEST_DEVICES = "X1=Env Phone,X2:offline" }))
        local f, lines = s.done(id)
        assert.equals(0, f.exit_code)
        assert.same({ exit_code = 0, devices = 2 }, f.result)
        assert.equals("out: SCAN OK: 2 devices (1 online)", lines[#lines])
        local sig = s.wait(function(m) return m.kind == "signal" and m.object == "/devices" end)
        assert.equals(sub.sub_id, sig.sub_id)
        assert.equals("changed", sig.name)
        assert.equals(1, sig.args.seq)
        local list = s.list()
        assert.equals(2, #list)
        assert.same({ "X1", "Env Phone", "online", "devstub" },
            { list[1].key, list[1].label, list[1].state, list[1].provider })
        assert.same({ "X2", "X2", "offline" }, { list[2].key, list[2].label, list[2].state })
        assert.is_string(list[1].id)
        assert.is_nil(list[1].profiles)
    end)

    it("set_device / clear_device write the working copy; list shows the choosing profiles", function()
        s = session()
        s.scan()
        local r = s.call("/profiles", "loomworks.Profiles", "set_device",
            { profile = { key = "dev" }, device = { key = "NOPE" } }, s.env)
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no device 'NOPE'", 1, true), r.message)
        r = s.call("/profiles", "loomworks.Profiles", "set_device",
            { profile = { key = "ghost" }, device = { key = "SER1" } }, s.env)
        assert.equals("refused", r.outcome)
        -- By id, as the editor sends it.
        local id = s.list()[1].id
        r = s.call("/profiles", "loomworks.Profiles", "set_device", { profile = { key = "dev" }, device = { id = id } },
            s.env)
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "dev" }, s.list()[1].profiles)
        assert.equals("SER1", s.service().ws._active_profile:device_serial())
        assert.truthy(read(s.root .. "/.nvim/loomworks.user.json"):find('"SER1"', 1, true))
        r = s.call("/profiles", "loomworks.Profiles", "clear_device", { profile = { key = "dev" } }, s.env)
        assert.equals("ok", r.outcome)
        assert.is_nil(s.list()[1].profiles)
        assert.is_nil(s.service().ws._active_profile:device_serial())
    end)

    it("install / launch / stop run the module's commands in the caller's environment", function()
        s = session()
        -- No device chosen: the task ends nonzero before anything runs.
        local f = s.done(s.start("install", DEV))
        assert.equals(1, f.exit_code)
        assert.truthy(f.error:find("has no device", 1, true), f.error)
        s.scan()
        s.set_device("SER1")
        local out
        f, _, out = s.done(s.start("install", DEV))
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.truthy(out:find("install SER1 ", 1, true), out)
        local id = s.start("launch", DEV)
        f = s.done(id)
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.same({ exit_code = 0, pid = 4242, bundle = "com.example.app" }, f.result)
        local r = s.dev("stop", { task = id })
        assert.same({ outcome = "ok" }, r)
        -- Stopped once: nothing left to stop.
        r = s.dev("stop", { task = id })
        assert.equals("refused", r.outcome)
        local log = read(s.log)
        assert.truthy(log:find("install SER1 " .. s.unit():build_dir() .. "/app.hap install", 1, true), log)
        assert.truthy(log:find("launch SER1 com.example.app launch", 1, true), log)
        -- (The pid probe: the module command's program, in the caller's environment.)
        assert.truthy(log:find("pid SER1 com.example.app", 1, true), log)
        assert.truthy(log:find("stop SER1 com.example.app stop", 1, true), log)
        -- Every lock was released.
        assert.is_nil(device_lock.read("SER1"))
        assert.is_false(build_lock.held_by_me(s.unit():build_dir()))
    end)

    it("a failing command fails its task with the module command's line", function()
        s = session({ LW_TEST_DEVICE_FAIL = "install" })
        s.scan()
        s.set_device("SER1")
        local f = s.done(s.start("install", DEV))
        assert.equals(1, f.exit_code)
        assert.equals("app: install on SER1 failed (exit 1)", f.error)
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("a target that is not a device target is refused inside the task", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        s.service().ws._active_profile._default_target_descriptor = nil
        local f = s.done(s.start("install", DEV))
        assert.equals(1, f.exit_code)
    end)

    it("tasks are owned by their connection: a cancel or the owner's disconnect kills the command", function()
        s = session({ LW_TEST_DEVICE_SLEEP = "30000" })
        s.scan()
        s.set_device("SER1")
        local id = s.start("install", DEV)
        s.wait(function(m) return m.kind == "task" and m.task_id == id and m.phase == "output" end)
        local rows = s.call("/tasks", "loomworks.Tasks", "list").tasks
        assert.equals("install", rows[1].kind)
        assert.is_true(rows[1].owned)
        local t0 = uv.now()
        assert.same({ outcome = "ok" }, s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id }))
        local f = s.done(id)
        assert.is_true(uv.now() - t0 < 15000)
        assert.equals(130, f.exit_code)
        assert.truthy(f.error:find("^install stopped: cancelled by the client"), f.error)
        assert.is_nil(device_lock.read("SER1"))
        assert.is_false(build_lock.held_by_me(s.unit():build_dir()))
        -- The owner's disconnect cancels a launch likewise.
        id = s.start("launch", DEV)
        s.wait(function(m) return m.kind == "task" and m.task_id == id and m.phase == "output" end)
        local svc = s.service()
        svc:on_conn_closed(svc.tasks.tasks[id].owner)
        f = s.done(id)
        assert.equals(130, f.exit_code)
        assert.truthy(f.error:find("disconnected", 1, true), f.error)
    end)

    it("a cancelled scan leaves the registry as it was", function()
        s = session()
        local id = s.start("scan", nil, vim.tbl_extend("force", s.env, { LW_TEST_SCAN_SLEEP = "hang" }))
        s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id })
        local f = s.done(id)
        assert.equals(130, f.exit_code)
        assert.equals("scan stopped: cancelled by the client that started it", f.error)
        assert.same({}, s.list())
    end)

    it("an install holds its build directory (B) while it waits for the device (D); a launch only D", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        local bd = s.unit():build_dir()
        L.hold(device_lock.path("SER1"), "run")
        local id = s.start("install", DEV)
        local l = s.line(id)
        assert.truthy(l.text:find("^device SER1 is in use by pid %d+"), l.text)
        assert.truthy(l.text:find("waiting for it", 1, true), l.text)
        -- B taken first, D waited for.
        assert.is_true(build_lock.held_by_me(bd))
        L.cleanup()
        local f = s.done(id)
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.is_false(build_lock.held_by_me(bd))
        -- A launch never takes the build directory.
        L.hold(device_lock.path("SER1"), "run")
        id = s.start("launch", DEV)
        s.line(id)
        assert.is_false(build_lock.held_by_me(bd))
        L.cleanup()
        f = s.done(id)
        assert.equals(0, f.exit_code, vim.inspect(f))
    end)

    it("an install whose build directory another process holds fails fast, before the device lock", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        local bd = s.unit():build_dir()
        vim.fn.mkdir(bd, "p")
        L.hold(build_lock.lock_path(bd), "build")
        local f = s.done(s.start("install", DEV))
        assert.equals(1, f.exit_code)
        assert.truthy(f.error:find("in use", 1, true) or f.error:find("busy", 1, true), f.error)
        assert.is_nil(device_lock.read("SER1"))
        assert.equals("", read(s.log))
    end)

    it("stop refuses a running or unknown task and another client's launch is forbidden", function()
        s = session({ LW_TEST_DEVICE_SLEEP = "30000" })
        local r = s.dev("stop", { task = "nope" })
        assert.equals("refused", r.outcome)
        s.scan()
        s.set_device("SER1")
        local id = s.start("launch", DEV)
        s.wait(function(m) return m.kind == "task" and m.task_id == id and m.phase == "output" end)
        r = s.dev("stop", { task = id })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("still running", 1, true), r.message)
        s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id })
        s.done(id)
        -- Another client's launch.
        devices.launches(s.service())["T-other"] = { owner = {}, serial = "SER1", stop = false }
        local fr = s.raw("/devices", "loomworks.Devices", "stop", { task = "T-other" }, s.env)
        assert.equals("error", fr.kind)
        assert.equals("forbidden", fr.error.code)
    end)

    it("stop stops the program its launch launched, even after the default target changed", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        local id = s.start("launch", DEV)
        assert.equals(0, s.done(id).exit_code)
        s.service().ws._active_profile._default_target_descriptor = nil
        assert.same({ outcome = "ok" }, s.dev("stop", { task = id }))
        local log = read(s.log)
        assert.truthy(log:find("stop SER1 com.example.app stop", 1, true), log)
    end)

    it("a running stop is a run: its owner's disconnect kills it and releases the device", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        local id = s.start("launch", DEV)
        assert.equals(0, s.done(id).exit_code)
        local slow = vim.tbl_extend("force", s.env, { LW_TEST_DEVICE_SLEEP = "30000" })
        local req = s.send_call("/devices", "loomworks.Devices", "stop", { task = id }, slow)
        s.poll(function() return read(s.log):find("stop SER1", 1, true) ~= nil end)
        local svc = s.service()
        local stop_run
        for run in pairs(svc.runs) do
            if run.op == "stop" then stop_run = run end
        end
        assert.is_not_nil(stop_run)
        -- Busy: the idle work cap does not unload under it.
        assert.is_false(svc:abandon_background())
        assert.is_not_nil(device_lock.read("SER1"))
        local t0 = uv.now()
        svc:on_conn_closed(devices.launches(svc)[id].owner)
        local r = s.reply(req, 15000)
        assert.is_true(uv.now() - t0 < 15000)
        assert.equals("refused", r.result.outcome, vim.inspect(r))
        assert.is_nil(device_lock.read("SER1"))
        assert.is_nil(next(svc.runs))
    end)

    it("two stops of one launch run its stop command once; the second is refused", function()
        s = session({ LW_TEST_DEVICE_SLEEP = "2000" })
        s.scan()
        s.set_device("SER1")
        local id = s.start("launch", DEV)
        assert.equals(0, s.done(id).exit_code)
        local req1 = s.send_call("/devices", "loomworks.Devices", "stop", { task = id }, s.env)
        local req2 = s.send_call("/devices", "loomworks.Devices", "stop", { task = id }, s.env)
        local r2 = s.reply(req2)
        local r1 = s.reply(req1)
        assert.same({ outcome = "ok" }, r1.result)
        assert.equals("refused", r2.result.outcome, vim.inspect(r2))
        assert.truthy(r2.result.message:find("already being stopped", 1, true), r2.result.message)
        local _, n = read(s.log):gsub("stop SER1", "")
        assert.equals(1, n)
    end)

    it("a reload keeps the device registry and its ids and leaves running device tasks alone", function()
        s = session()
        s.scan()
        s.set_device("SER1")
        local before = s.list()
        local launch = s.start("launch", DEV)
        assert.equals(0, s.done(launch).exit_code)
        L.hold(device_lock.path("SER1"), "run")
        local id = s.start("install", DEV)
        s.line(id) -- waiting for the device
        local old_ws = s.service().ws
        -- A scan from a client with another environment reloads the workspace.
        local other = vim.tbl_extend("force", s.env, { LW_TEST_DEVICES = "SER1=Stub Phone", LW_TEST_OTHER = "1" })
        local f = s.done(s.start("scan", nil, other))
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.are_not.equal(old_ws, s.service().ws)
        local after = s.list()
        assert.equals(2, #after)
        assert.equals(before[1].id, after[1].id)
        assert.equals(before[2].id, after[2].id)
        assert.equals("offline", after[2].state)
        L.cleanup()
        f = s.done(id)
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.is_false(build_lock.held_by_me(s.unit():build_dir()))
        assert.same({ outcome = "ok" }, s.dev("stop", { task = launch }))
    end)

    it("a cancel during the launch's pid probe ends the task at once", function()
        s = session({ LW_TEST_PID_SLEEP = "2500" })
        s.scan()
        s.set_device("SER1")
        local LT = require("loomworks.launch_target")
        local orig = LT.device_resolve_pid
        local exits = 0
        LT.device_resolve_pid = function(self, serial, bundle, opts)
            local sys = opts.system
            opts.system = function(cmd, so, on_exit)
                return sys(cmd, so, function(res) exits = exits + 1; on_exit(res) end)
            end
            return orig(self, serial, bundle, opts)
        end
        local ok, err = pcall(function()
            local id = s.start("launch", DEV)
            s.poll(function() return read(s.log):find("pid SER1", 1, true) ~= nil end)
            s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id })
            local f = s.done(id)
            assert.equals(130, f.exit_code, vim.inspect(f))
            -- Ended by the killed probe's exit, not after the probe's retries.
            assert.is_true(exits < 6, "probe exits: " .. exits)
            assert.is_nil(devices.launches(s.service())[id])
        end)
        LT.device_resolve_pid = orig
        assert(ok, err)
    end)

    it("Launch/1.build builds a device target (no refusal, no device outcome)", function()
        s = session()
        local r = s.call("/launch", "loomworks.Launch", "build", DEV, s.env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 120000)
        assert.equals(0, f.exit_code, vim.inspect(f))
        assert.is_nil(f.result.device)
    end)
end)

-- `Launch/1.device_log` (API.md §9.5; step 5n part B3): the log stream of
-- a device launch, its records as the `log` signal.
describe("Launch/1.device_log in the workspace daemon (API.md §9.5)", function()
    local s
    local saved = {}
    local tasks_mod = require("loomworks.daemon.tasks")
    local daemon_runner = require("loomworks.daemon.runner")
    local stubbed = {}
    --- Replace `t[k]` with `v` until the test ends.
    local function stub(t, k, v)
        stubbed[#stubbed + 1] = { t, k, t[k] }
        t[k] = v
    end
    before_each(function()
        for _, k in ipairs({ "LOG_QUEUE_MAX", "LOG_FLUSH_MS", "LOG_PID_POLL_MS", "LOG_LINE_MAX",
            "LOG_BATCH_BYTES", "LOG_CLEAR_TIMEOUT_MS", "PROBE_TIMEOUT_MS" }) do saved[k] = devices[k] end
    end)
    after_each(function()
        for k, v in pairs(saved) do devices[k] = v end
        for i = #stubbed, 1, -1 do
            local e = stubbed[i]
            e[1][e[2]] = e[3]
        end
        stubbed = {}
        L.cleanup()
        if s then s.close(); s = nil end
    end)

    --- A finished launch of the fixture's device target on SER1; its task id.
    local function launched()
        s.scan()
        s.set_device("SER1")
        local f = s.done(s.start("launch", DEV))
        assert.equals(0, f.exit_code, vim.inspect(f))
        return f.task_id
    end
    --- The caller's environment with `extra`.
    local function env_with(extra)
        local e = vim.deepcopy(s.env)
        for k, v in pairs(extra) do e[k] = v end
        return e
    end
    --- Subscribe to `log` (`args`: its subscribe_args).
    local function subscribe(args)
        local r = s.call("/", "loomworks.Root", "subscribe",
            { object = "/launch", iface = "loomworks.Launch", v = 1, signals = { "log" }, args = args })
        assert.truthy(r.sub_id)
    end
    local function device_log(task, env)
        return s.call("/launch", "loomworks.Launch", "device_log", { task = task }, env or s.env)
    end
    local function start_log(task, env)
        local r = device_log(task, env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        return r.task_id
    end
    --- The `log` signals of task `id` until `stop(records)` holds (default:
    --- its `done`): the records, the dropped total, the done frame (when
    --- reached), the task's lines and each signal's record count.
    local function collect(id, stop, ms)
        local recs, dropped, lines, batches = {}, 0, {}, {}
        while true do
            local f = s.wait(function(m)
                return (m.kind == "signal" and m.object == "/launch" and m.name == "log" and m.args.task == id)
                    or (m.kind == "task" and m.task_id == id and (m.phase == "line" or m.phase == "done"))
            end, ms)
            if f.kind == "signal" then
                assert.is_true(#f.args.records > 0 or (f.args.dropped or 0) > 0)
                vim.list_extend(recs, f.args.records)
                batches[#batches + 1] = #f.args.records
                dropped = dropped + (f.args.dropped or 0)
                if stop and stop(recs) then return recs, dropped, nil, lines, batches end
            elseif f.phase == "line" then
                lines[#lines + 1] = f.stream .. ": " .. f.text
            else
                return recs, dropped, f, lines, batches
            end
        end
    end

    local APP = { tid = 4243, domain = "A00001", proc = "com.example.app" }

    it("streams the launch's lines as records, prefiltered and normalized, after the clear", function()
        s = session()
        local launch = launched()
        subscribe()
        local id = start_log(launch)
        local recs, dropped, done = collect(id)
        assert.same({
            { ts = "10-19 12:00:00.001", level = "info", tag = "AppTag", pid = 4242,
                message = "hello from the app", fields = APP },
            { level = "info", message = "not a device log line" },
            { ts = "10-19 12:00:00.003", level = "error", tag = "AppTag", pid = 4242,
                message = "something failed", fields = { tid = 4242, domain = "A00001", proc = "com.example.app" } },
        }, recs)
        assert.equals(0, dropped)
        assert.equals(0, done.exit_code, vim.inspect(done))
        assert.same({ exit_code = 0 }, done.result)
        -- The clear ran first, in the caller's environment; the stream got no
        -- pid (the module did not ask for strict-pid filtering).
        local log = read(s.log)
        local c, l = log:find("log_clear SER1 - log_clear", 1, true), log:find("\nlog SER1 - log", 1, true)
        assert.truthy(c and l and c < l, log)
        assert.is_nil(device_lock.read("SER1"))
        -- The launch can still be logged again, and stopped.
        assert.equals("accepted", device_log(launch).outcome)
    end)

    it("passes the pid to the module's command when it asks for strict-pid filtering", function()
        s = session()
        local launch = launched()
        local _, _, done = collect(start_log(launch, env_with({ LW_TEST_LOG_STRICT = "1" })))
        assert.equals(0, done.exit_code)
        assert.truthy(read(s.log):find("log SER1 4242 log", 1, true), read(s.log))
    end)

    it("a full queue drops the oldest records and counts them on the next log", function()
        s = session()
        local launch = launched()
        subscribe()
        devices.LOG_QUEUE_MAX = 5
        devices.LOG_FLUSH_MS = 60000
        local recs, dropped, done = collect(start_log(launch, env_with({ LW_TEST_LOG_COUNT = "20" })))
        assert.equals(0, done.exit_code)
        assert.equals(5, #recs)
        assert.equals(23 - 5, dropped)
        assert.equals("flood 20", recs[5].message)
    end)

    it("a cancel or the owner's disconnect ends it at once", function()
        s = session()
        local launch = launched()
        subscribe()
        local slow = env_with({ LW_TEST_LOG_SLEEP = "30000" })
        local id = start_log(launch, slow)
        collect(id, function(r) return #r >= 3 end)
        local rows = s.call("/tasks", "loomworks.Tasks", "list").tasks
        local row
        for _, t in ipairs(rows) do if t.task_id == id then row = t end end
        assert.equals("device_log", row.kind)
        assert.is_true(row.owned)
        local t0 = uv.now()
        assert.same({ outcome = "ok" }, s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id }))
        local _, _, done = collect(id)
        assert.is_true(uv.now() - t0 < 15000)
        assert.equals(130, done.exit_code)
        assert.truthy(done.error:find("^device_log stopped: cancelled by the client"), done.error)
        id = start_log(launch, slow)
        collect(id, function(r) return #r >= 3 end)
        local svc = s.service()
        svc:on_conn_closed(svc.tasks.tasks[id].owner)
        _, _, done = collect(id)
        assert.equals(130, done.exit_code)
        assert.truthy(done.error:find("disconnected", 1, true), done.error)
    end)

    it("ends with exit 0 once the program's pid is gone from two probes", function()
        s = session()
        local launch = launched()
        devices.LOG_PID_POLL_MS = 100
        local id = start_log(launch, env_with({ LW_TEST_LOG_SLEEP = "30000", LW_TEST_DEVICE_PID = "0" }))
        local t0 = uv.now()
        local _, _, done, lines = collect(id)
        assert.is_true(uv.now() - t0 < 15000)
        assert.equals(0, done.exit_code, vim.inspect(done))
        assert.same({ "out: the program exited — log stream closed" }, lines)
    end)

    it("a failed clear is a note; a failed stream ends the task with its exit", function()
        s = session()
        local launch = launched()
        local _, _, done, lines = collect(start_log(launch, env_with({ LW_TEST_DEVICE_FAIL = "log_clear" })))
        assert.equals(0, done.exit_code)
        assert.truthy(lines[1]:find("^note: device log not cleared: "), vim.inspect(lines))
        subscribe()
        local recs
        recs, _, done = collect(start_log(launch, env_with({ LW_TEST_DEVICE_FAIL = "log" })))
        assert.equals(1, done.exit_code)
        assert.equals("device log stream ended (exit 1)", done.error)
        -- (Its stderr is read too, as the in-process view reads both streams.)
        assert.equals(4, #recs)
        assert.same({ level = "info", message = "log failed on SER1" }, recs[4])
    end)

    local function cancel(id)
        assert.same({ outcome = "ok" }, s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id }))
    end
    --- The next line of task `id`.
    local function next_line(id)
        return s.wait(function(m) return m.kind == "task" and m.task_id == id and m.phase == "line" end)
    end
    --- Read frames for `ms` into the inbox.
    local function drain(ms)
        local until_ = uv.now() + ms
        while uv.now() < until_ do
            local f = s.d.recv(50)
            if f then s.inbox[#s.inbox + 1] = f end
        end
    end
    local function log_signals()
        local n = 0
        for _, f in ipairs(s.inbox) do
            if f.kind == "signal" and f.object == "/launch" and f.name == "log" then n = n + 1 end
        end
        return n
    end

    it("a clear that does not end in 3 s is killed: a note line, then the stream", function()
        s = session()
        local launch = launched()
        subscribe()
        local t0 = uv.now()
        local recs, _, done, lines = collect(start_log(launch, env_with({ LW_TEST_DEVICE_SLEEP = "30000" })))
        assert.is_true(uv.now() - t0 < 15000)
        assert.equals(0, done.exit_code, vim.inspect(done))
        assert.truthy(lines[1] and lines[1]:find("^note: device log not cleared: .*timed out"), vim.inspect(lines))
        assert.equals(3, #recs)
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("a device lock it cannot take is a note line, then the stream", function()
        s = session()
        local launch = launched()
        subscribe()
        stub(device_lock, "try_acquire", function() return nil, "device SER1: the lock is unreadable" end)
        local recs, _, done, lines = collect(start_log(launch))
        assert.equals(0, done.exit_code, vim.inspect(done))
        assert.same({ "note: device log not cleared: device SER1: the lock is unreadable" }, lines)
        assert.equals(3, #recs)
        assert.is_nil(read(s.log):find("log_clear", 1, true))
    end)

    it("kills a running pid probe when the stream ends by itself", function()
        s = session()
        local launch = launched()
        devices.LOG_PID_POLL_MS = 1
        local proc = require("loomworks.proc")
        local probes = {}
        local spawn = daemon_runner.spawn
        stub(daemon_runner, "spawn", function(spec, sink)
            local obj = spawn(spec, sink)
            if obj and obj.pid and vim.tbl_contains(spec.cmd, "pid") then
                probes[#probes + 1] = { pid = obj.pid, start = proc.start_time(obj.pid) }
            end
            return obj
        end)
        local id = start_log(launch, env_with({ LW_TEST_PID_SLEEP = "30000", LW_TEST_LOG_SLEEP = "200" }))
        assert.is_true(vim.wait(10000, function() return #probes == 1 end, 20))
        assert.is_true(proc.alive(probes[1].pid, probes[1].start))
        local _, _, done = collect(id)
        assert.equals(0, done.exit_code, vim.inspect(done))
        assert.equals(1, #probes)
        -- (Gone well before its own 3 s timeout would kill it.)
        assert.is_true(vim.wait(1500, function() return not proc.alive(probes[1].pid, probes[1].start) end, 20))
    end)

    it("is refused as stop is: unknown, running, pid-less; another client's launch is forbidden", function()
        s = session({ LW_TEST_DEVICE_SLEEP = "30000" })
        local r = device_log("nope")
        assert.same({ outcome = "refused", exit_code = 1, message = "no program launched by task nope" }, r)
        s.scan()
        s.set_device("SER1")
        local id = s.start("launch", DEV)
        s.wait(function(m) return m.kind == "task" and m.task_id == id and m.phase == "output" end)
        r = device_log(id)
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("still running", 1, true), r.message)
        local svc = s.service()
        local owner = svc.tasks.tasks[id].owner
        s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = id })
        s.done(id)
        local lt = require("loomworks.run_prep").select(svc.ws, svc.ws._active_profile)
        devices.launches(svc)["T-nopid"] = { owner = owner, serial = "SER1", stop = false,
            target = lt }
        r = device_log("T-nopid")
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("has no process id", 1, true), r.message)
        devices.launches(svc)["T-other"] = { owner = {}, serial = "SER1", stop = false, target = lt, pid = 1 }
        local fr = s.raw("/launch", "loomworks.Launch", "device_log", { task = "T-other" }, s.env)
        assert.equals("error", fr.kind)
        assert.equals("forbidden", fr.error.code)
    end)
end)
