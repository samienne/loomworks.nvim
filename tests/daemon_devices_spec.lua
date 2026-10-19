-- The workspace daemon's devices (spec §19.16 "Devices", §19.18, §19.20
-- `Devices/1`, `Profiles/1.set_device` / `clear_device`; API.md §11, §15;
-- step 5n part B2), over the loopback transport on the conformance runner's
-- `devices` fixture (the harness-only devstub module): what a transcript
-- cannot show — the caller's environment reaching the module and its
-- commands, a cancel killing a command, the tasks owned by their
-- connection, the lock order B → D (an install holds its build directory
-- while it waits for the device), a device held by another process, and a
-- stop of another client's launch.

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
