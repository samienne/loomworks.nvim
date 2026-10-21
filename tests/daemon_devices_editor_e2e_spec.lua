-- The editor's devices end to end (step 5n part C2; daemon.md §19.16
-- "Devices", API.md §11 `set_device`, §15 `Devices/1`): the daemon side is
-- real — an in-process server with the real build service
-- (cli._daemon_build_host) on the conformance runner's `devices` fixture (the
-- harness-only devstub module: SER1 online, SER2 offline, `dev` active with
-- its device target `app` as the default target) — and the editor side is
-- the real observer feeding loomworks.device_source and the session tracker.
-- The list comes only from `Devices/1.list` and its `changed` signal, a scan
-- is a `Devices/1.scan` task the editor owns, the choice is
-- `Profiles/1.set_device` / `clear_device`, and a launch is
-- `Launch/1.build`, `Devices/1.install`, `Devices/1.launch`, its stop
-- `Devices/1.stop` — nothing of it in the editor's model. Disconnected, each
-- is refused, never run in-process.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local events = require("loomworks.events")
local device_source = require("loomworks.device_source")
local editor_ops = require("loomworks.daemon.editor_ops")
local session_tracker = require("loomworks.session_tracker")
local dl = require("loomworks.device_log")
local devices_mod = require("loomworks.daemon.devices")
local views = require("loomworks.views")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local s = f:read("*a")
    f:close()
    return s
end

--- The registry record of `serial` in `list`, or nil.
local function rec(list, serial)
    for _, d in ipairs(list or {}) do
        if d.key == serial then return d end
    end
    return nil
end

describe("editor devices through a real daemon /devices (§19.16 Devices, step 5n C2)", function()
    local root, srv, core, obs, sess, ws, profile
    local notes, orig_notify, saved_env, started, handlers, log

    local function on(ev, fn)
        events.on(ev, fn)
        handlers[#handlers + 1] = { ev, fn }
    end

    before_each(function()
        local key = H.tmp() .. "/trust.key"
        trust._set_key_path(key)
        root = runner.fixture("devices", key)
        runner.register_devstub()
        trust._set_key_path(key)
        -- The editor's environment, which its calls carry: a fresh device-lock
        -- directory and the stub device's command log.
        log = H.tmp() .. "/device.log"
        saved_env = { lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR, log = vim.env.LW_TEST_DEVICE_LOG,
            fail = vim.env.LW_TEST_DEVICE_FAIL, sleep = vim.env.LW_TEST_DEVICE_SLEEP,
            scan = vim.env.LW_TEST_SCAN_SLEEP, build = vim.env.LW_TEST_SLEEP,
            log_count = vim.env.LW_TEST_LOG_COUNT, log_sleep = vim.env.LW_TEST_LOG_SLEEP,
            queue_max = devices_mod.LOG_QUEUE_MAX }
        dl._reset_for_tests()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = H.tmp() .. "/locks"
        vim.env.LW_TEST_DEVICE_LOG = log
        core = Core.new()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        profile = ws._active_profile
        notes, started, handlers = {}, {}, {}
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        on("daemon_task_started", function(d) started[#started + 1] = d.task end)
    end)

    after_each(function()
        vim.notify = orig_notify
        pcall(session_tracker.stop)
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        if obs then obs:stop() end
        obs = nil
        if sess then sess:close() end
        sess = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        srv = nil
        pcall(function() core:shutdown() end)
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_env.lock
        vim.env.LW_TEST_DEVICE_LOG = saved_env.log
        vim.env.LW_TEST_DEVICE_FAIL = saved_env.fail
        vim.env.LW_TEST_DEVICE_SLEEP = saved_env.sleep
        vim.env.LW_TEST_SCAN_SLEEP = saved_env.scan
        vim.env.LW_TEST_SLEEP = saved_env.build
        vim.env.LW_TEST_LOG_COUNT = saved_env.log_count
        vim.env.LW_TEST_LOG_SLEEP = saved_env.log_sleep
        devices_mod.LOG_QUEUE_MAX = saved_env.queue_max
        dl._reset_for_tests()
        trust._set_key_path(nil)
    end)

    local function errors()
        local out = {}
        for _, n in ipairs(notes) do
            if n.level == vim.log.levels.ERROR then out[#out + 1] = n.msg end
        end
        return out
    end
    local function noted(text)
        for _, n in ipairs(notes) do
            if n.msg:find(text, 1, true) then return true end
        end
        return false
    end

    --- Does a line of the device-log view contain `text`?
    local function view_has(text)
        for _, l in ipairs(dl._lines_for_tests()) do
            if l:find(text, 1, true) then return true end
        end
        return false
    end

    --- The daemon (the real build service) and the editor's observer,
    --- connected with the device list read.
    local function serve()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function() end })
        srv:registry()
        service.attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start())
        local fr = FR.new({})
        obs = observer.attach(ws, { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(60000, function()
            return obs:can_call("device_scan") and obs:can_call("set_device") and obs._devices ~= nil
        end, 20), obs:runtime_line())
        -- And the daemon has loaded the workspace: a launch before that is
        -- refused as "unloaded" (§19.16), which a slow machine can reach.
        assert.is_true(vim.wait(60000, function()
            local header = views.daemon_state(obs, "header")
            return type(header) == "table" and header.state == "loaded"
        end, 20), obs:runtime_line())
    end

    --- Scan, then choose SER1 for the profile (Devices/1.scan, Profiles/1.set_device).
    local function choose_ser1()
        local scanned
        device_source.scan(ws, function(list) scanned = list or false end)
        assert.is_true(vim.wait(60000, function() return scanned ~= nil end, 20))
        local chosen
        device_source.select(ws, profile, assert(rec(scanned, "SER1")),
            function(ok, err) chosen = { ok = ok, err = err } end)
        assert.is_true(vim.wait(30000, function() return chosen ~= nil end, 20))
        assert.is_true(chosen.ok, tostring(chosen.err))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(ws), "SER1")
            return d ~= nil and d.profiles ~= nil and d.profiles[1] == "dev"
        end, 20))
    end

    --- The kinds of the tasks the editor started, in order.
    local function kinds()
        local out = {}
        for _, t in ipairs(started) do out[#out + 1] = t.kind end
        return out
    end

    --- The started task of `kind` (the first), or nil.
    local function task_of(kind)
        for _, t in ipairs(started) do if t.kind == kind then return t end end
        return nil
    end

    --- Start the profile's default target; true when a question was asked.
    local function start_asked()
        local asked = false
        local orig = vim.ui.select
        vim.ui.select = function() asked = true end
        session_tracker.start(profile:default_target(), "launch")
        vim.ui.select = orig
        return asked
    end

    it("lists, scans, chooses, launches and stops through Devices/1; refused once disconnected", function()
        serve()

        -- The list comes from Devices/1.list: empty until a scan.
        assert.same({}, device_source.list(ws))

        -- A scan is a Devices/1.scan task the editor owns; then the registry.
        local scanned
        device_source.scan(ws, function(list, err) scanned = { list = list, err = err } end)
        assert.is_true(vim.wait(60000, function() return scanned ~= nil end, 20))
        assert.is_nil(scanned.err)
        assert.equals("online", rec(scanned.list, "SER1").state)
        assert.equals("offline", rec(scanned.list, "SER2").state)
        assert.is_string(rec(scanned.list, "SER1").id)
        assert.is_true(started[1] ~= nil and started[1].owned)
        assert.equals("scan", started[1].kind)
        -- Nothing in the editor's own registry.
        assert.same({}, ws:devices())

        -- `changed` refreshes it: another client chooses SER1 for `dev`.
        sess = assert(client.session(srv.address))
        local env = require("loomworks.daemon.envscope").capture()
        local res = client.call_sync(sess, "/profiles", "loomworks.Profiles", 1, "set_device",
            { profile = { key = "dev" }, device = { key = "SER1" } }, { env = env })
        assert.equals("ok", res and res.outcome, vim.inspect(res))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(ws), "SER1")
            return d ~= nil and d.profiles ~= nil and d.profiles[1] == "dev"
        end, 20))

        -- clear / select are Profiles/1 writes.
        local cleared
        device_source.clear(ws, profile, function(ok, err) cleared = { ok = ok, err = err } end)
        assert.is_true(vim.wait(30000, function() return cleared ~= nil end, 20))
        assert.is_true(cleared.ok, tostring(cleared.err))
        assert.is_true(vim.wait(30000, function()
            return rec(device_source.list(ws), "SER1").profiles == nil
        end, 20))
        local chosen
        device_source.select(ws, profile, rec(device_source.list(ws), "SER1"),
            function(ok, err) chosen = { ok = ok, err = err } end)
        assert.is_true(vim.wait(30000, function() return chosen ~= nil end, 20))
        assert.is_true(chosen.ok, tostring(chosen.err))
        assert.truthy(read(root .. "/.nvim/loomworks.user.json"):find('"SER1"', 1, true))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(ws), "SER1")
            return d.profiles ~= nil and d.profiles[1] == "dev"
        end, 20))

        -- The default target's launch: Launch/1.build, install, launch.
        local target = profile:default_target()
        assert.is_true(target:requires_device())
        session_tracker.start(target, "launch")
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
        assert.same({}, errors())
        local kinds = {}
        for _, t in ipairs(started) do
            assert.is_true(t.owned)
            -- (Its device log, started at the launch, is checked below.)
            if t.kind ~= "device_log" then kinds[#kinds + 1] = t.kind end
        end
        assert.same({ "scan", "build", "install", "launch" }, kinds)
        local id = session_tracker.active_run().device_task
        assert.is_not_nil(id)
        local lines = read(log)
        assert.truthy(lines:find("install SER1", 1, true), lines)
        assert.truthy(lines:find("launch SER1 com.example.app", 1, true), lines)
        -- Its device log: a Launch/1.device_log task the editor owns, its
        -- records in the view; the stub's log exits at once, so it ends.
        assert.is_true(vim.wait(60000, function()
            return view_has("hello from the app") and view_has("device log stream ended ──")
        end, 20), table.concat(dl._lines_for_tests(), "\n"))
        assert.is_true(task_of("device_log").owned)
        assert.is_false(dl.is_running())
        assert.is_true(dl.is_visible())
        assert.same({}, errors())

        -- Stop: Devices/1.stop of the launch task.
        session_tracker.stop()
        assert.is_false(session_tracker.is_running())
        assert.is_true(vim.wait(30000, function() return read(log):find("stop SER1", 1, true) ~= nil end, 20),
            read(log))

        -- Disconnected: refused, never run in-process.
        srv:stop("test", 0)
        assert.is_true(vim.wait(30000, function() return not obs:can_call("device_scan") end, 20))
        notes = {}
        local refused
        device_source.scan(ws, function(list, err) refused = { list = list, err = err } end)
        assert.is_true(vim.wait(5000, function() return refused ~= nil end, 20))
        assert.is_nil(refused.list)
        assert.truthy(refused.err:find("^device scan: "), refused.err)
        assert.same({}, device_source.list(ws))
        local before = #started
        session_tracker.start(target, "launch")
        vim.wait(200)
        assert.is_true(noted("loomworks: launch: "))
        assert.equals(before, #started)
        assert.is_false(session_tracker.is_running())
        local wrote
        device_source.clear(ws, profile, function(ok, err) wrote = { ok = ok, err = err } end)
        assert.is_false(wrote.ok)
        assert.truthy(wrote.err:find("^device choice: "), wrote.err)
        assert.same({}, ws:devices())
        assert.is_nil(editor_ops.devices(ws))
    end)

    it("an install that fails ends the chain with its error; nothing is launched", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_DEVICE_FAIL = "install"
        notes = {}
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return #errors() > 0 end, 20), vim.inspect(notes))
        vim.wait(300)
        assert.same({ "scan", "build", "install" }, kinds())
        assert.is_false(session_tracker.is_running())
        assert.is_nil(read(log):find("launch SER1", 1, true), read(log))
        -- Nothing left preparing: a new launch starts at once (no question).
        vim.env.LW_TEST_DEVICE_FAIL = nil
        assert.is_false(start_asked())
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
    end)

    it("a launch that fails ends the chain with its error; no run is tracked", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_DEVICE_FAIL = "launch"
        notes = {}
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return #errors() > 0 end, 20), vim.inspect(notes))
        vim.wait(300)
        assert.same({ "scan", "build", "install", "launch" }, kinds())
        assert.is_false(session_tracker.is_running())
        assert.is_nil(session_tracker.active_run())
    end)

    it("a disconnect during the install ends the chain; nothing runs in-process", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_DEVICE_SLEEP = "5000"
        notes = {}
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return task_of("install") ~= nil end, 20), vim.inspect(notes))
        srv:stop("test", 0)
        assert.is_true(vim.wait(30000, function() return #errors() > 0 end, 20), vim.inspect(notes))
        assert.is_nil(task_of("launch"))
        assert.is_false(session_tracker.is_running())
        assert.same({}, ws:devices())
        -- Nothing left preparing: a new launch asks nothing (refused: unloaded).
        assert.is_false(start_asked())
        vim.wait(200)
        assert.is_true(noted("loomworks: cannot run "), vim.inspect(notes))
    end)

    it("a launched run is forgotten when the daemon disconnects: its stop sends nothing, no error", function()
        serve()
        choose_ser1()
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
        srv:stop("test", 0)
        assert.is_true(vim.wait(30000, function() return not session_tracker.is_running() end, 20))
        notes = {}
        session_tracker.stop()
        assert.is_true(noted("no running session"))
        assert.same({}, errors())
        assert.is_nil(read(log):find("stop SER1", 1, true), read(log))
    end)

    it("a stop during a device run's build cancels the build; nothing installed", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_SLEEP = "20000"
        notes = {}
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(60000, function() return task_of("build") ~= nil end, 20), vim.inspect(notes))
        local build = task_of("build")
        session_tracker.stop()
        assert.is_true(vim.wait(15000, function() return build.finished end, 20))
        vim.wait(300)
        assert.is_nil(task_of("install"))
        assert.same({}, errors())
        assert.is_false(session_tracker.is_running())
    end)

    it("a stop during a device run's scan cancels the scan; no device is chosen", function()
        serve()
        vim.env.LW_TEST_SCAN_SLEEP = "hang"
        notes = {}
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return task_of("scan") ~= nil end, 20), vim.inspect(notes))
        local scan = task_of("scan")
        session_tracker.stop()
        assert.is_true(vim.wait(15000, function() return scan.finished end, 20))
        vim.wait(300)
        assert.is_nil(task_of("install"))
        assert.same({}, errors())
        assert.is_false(session_tracker.is_running())
        assert.is_nil(read(root .. "/.nvim/loomworks.user.json"):find('"SER1"', 1, true))
    end)

    -- Step 5n C3 (API.md §9.5): the run's device log through the real
    -- daemon — a Launch/1.device_log task the editor owns, its records the
    -- `/launch` `log` signal of a subscription naming it.
    --- A device run of SER1 launched; its device log's task once started.
    local function launched_with_log()
        serve()
        choose_ser1()
        session_tracker.start(profile:default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
        assert.is_true(vim.wait(60000, function() return task_of("device_log") ~= nil end, 20))
        return task_of("device_log")
    end

    it("the device log's `start` level is the new view's filter", function()
        launched_with_log()
        assert.is_true(vim.wait(60000, function() return view_has("hello from the app") end, 20))
        -- The devstub's options: level D.
        assert.equals("D", dl._filter_for_tests().level)
    end)

    it("records the daemon's queue dropped are a gap line in the view", function()
        devices_mod.LOG_QUEUE_MAX = 5
        vim.env.LW_TEST_LOG_COUNT = "20"
        launched_with_log()
        assert.is_true(vim.wait(60000, function() return view_has("device log stream ended ──") end, 20),
            table.concat(dl._lines_for_tests(), "\n"))
        assert.is_true(view_has("records dropped"), table.concat(dl._lines_for_tests(), "\n"))
        assert.is_true(view_has("flood 20"))
        assert.same({}, errors())
    end)

    it("closing the view cancels the device log task; the run goes on", function()
        vim.env.LW_TEST_LOG_SLEEP = "20000"
        local task = launched_with_log()
        assert.is_true(vim.wait(60000, function() return view_has("hello from the app") end, 20))
        assert.is_true(dl.is_running())
        local stopped
        on("daemon_task_stopped", function(d) if d.task == task then stopped = d.task end end)
        dl.hide()
        assert.is_false(dl.is_running())
        assert.is_true(vim.wait(15000, function() return stopped ~= nil end, 20))
        assert.is_true(task.finished)
        assert.is_true(session_tracker.is_running())
        assert.is_false(view_has("device log stream ended"))
        assert.is_true(view_has("device log stream stopped"))
        assert.same({}, errors())
    end)
end)
