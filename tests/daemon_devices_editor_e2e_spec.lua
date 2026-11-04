-- The editor's devices end to end (step 5n part C2; daemon.md §19.16
-- "Devices", API.md §11 `set_device`, §15 `Devices/1`): the daemon is the
-- real lw of LOOMWORKS_LW (tests/daemon_helpers.lua) on the `devices`
-- fixture (the harness-only devstub module, installed as an acquired module
-- of this editor's data dir: SER1 online, SER2 offline, `dev` active with
-- its device target `app` as the default target), and the editor side is
-- the real observer (through a real `--stdio` relay) feeding
-- loomworks.device_source and the session tracker. A disconnect is the
-- daemon killed (`lw daemon kill`).
-- The list comes only from `Devices/1.list` and its `changed` signal, a scan
-- is a `Devices/1.scan` task the editor owns, the choice is
-- `Profiles/1.set_device` / `clear_device`, and a launch is
-- `Launch/1.build`, `Devices/1.install`, `Devices/1.launch`, its stop
-- `Devices/1.stop` — nothing of it in the editor's model. Disconnected, each
-- is refused, never run in-process.

local observer = require("loomworks.daemon.observer")
local events = require("loomworks")
local device_source = require("loomworks.device_source")
local editor_ops = require("loomworks.daemon.editor_ops")
local session_tracker = require("loomworks.session_tracker")
local dl = require("loomworks.device_log")
local views = require("loomworks.views")
local H = require("tests.daemon_helpers")

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

--- The `devices` fixture: the shell workspace's project `app` as a
--- `devstub` project (its device target `app`), the profile `dev` active
--- with that device target as its default target and no device chosen
--- (signed by lw).
local function devices_workspace()
    local root = H.shell_workspace()
    local f = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = vim.json.decode(f:read("*a")); f:close()
    cfg.projects.app = { path = "app", devstub = cfg.projects.app.shell }
    f = assert(io.open(root .. "/loomworks.json", "wb")); f:write(vim.json.encode(cfg)); f:close()
    local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } },
        projects = { app = cfg.projects.app }, active_profile = "dev",
        default_target = { dev = { project = "app", device_target = "app", device_target_label = "app app" } } }
    local signed = H.signed_user(root, user)
    f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb")); f:write(signed); f:close()
    return root
end

-- The `daemon`-mode editor holds no model (step 6b-alpha): the registry,
-- the scan and the device choice are calls (device_source with no model,
-- `Profiles/1.set_device` / `clear_device` by the profile row's id), the
-- default target a `Launch/1.targets` record (loomworks.daemon.LaunchRef).
describe("editor devices through a real daemon /devices (§19.16 Devices, step 5n C2)", function()
    local root, env, obs, sess
    local notes, orig_notify, saved_env, started, handlers, log

    local function on(ev, fn)
        events.on(ev, fn)
        handlers[#handlers + 1] = { ev, fn }
    end

    before_each(function()
        H.install_stub_module("devstub")
        env = H.editor_env({ LOOMWORKS_RUNTIME = "daemon" })
        root = devices_workspace()
        -- The editor's environment, which its calls carry: a fresh device-lock
        -- directory and the stub device's command log.
        log = H.tmp() .. "/device.log"
        saved_env = { lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR, log = vim.env.LW_TEST_DEVICE_LOG,
            fail = vim.env.LW_TEST_DEVICE_FAIL, sleep = vim.env.LW_TEST_DEVICE_SLEEP,
            scan = vim.env.LW_TEST_SCAN_SLEEP, build = vim.env.LW_TEST_SLEEP,
            log_count = vim.env.LW_TEST_LOG_COUNT, log_sleep = vim.env.LW_TEST_LOG_SLEEP }
        dl._reset_for_tests()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = H.tmp() .. "/locks"
        vim.env.LW_TEST_DEVICE_LOG = log
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
        observer.detach()
        H.track_root(root, env)
        if H.daemon(root, env) then H.stop_daemon(root, env) end
        H.cleanup()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_env.lock
        vim.env.LW_TEST_DEVICE_LOG = saved_env.log
        vim.env.LW_TEST_DEVICE_FAIL = saved_env.fail
        vim.env.LW_TEST_DEVICE_SLEEP = saved_env.sleep
        vim.env.LW_TEST_SCAN_SLEEP = saved_env.scan
        vim.env.LW_TEST_SLEEP = saved_env.build
        vim.env.LW_TEST_LOG_COUNT = saved_env.log_count
        vim.env.LW_TEST_LOG_SLEEP = saved_env.log_sleep
        dl._reset_for_tests()
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

    --- The daemon (started by the editor's relay) and the editor's
    --- observer, connected with the device list read.
    local function serve()
        obs = observer.attach(root, { getenv = daemon_mode, keepalive_ms = 500,
            resolve = function() return "lw" end, relay = H.real_relay() })
        H.track_root(root, env)
        assert.is_true(vim.wait(60000, function()
            return obs:can_call("device_scan") and obs:can_call("Profiles/1.set_device") and obs._devices ~= nil
        end, 20), obs:runtime_line())
        -- And the daemon has loaded the workspace: a launch before that is
        -- refused as "unloaded" (§19.16), which a slow machine can reach.
        assert.is_true(vim.wait(60000, function()
            local header = views.daemon_state(obs, "header")
            return type(header) == "table" and header.state == "loaded"
        end, 20), obs:runtime_line())
    end

    --- The daemon goes away under the editor (`lw daemon kill`).
    local function drop()
        local r = H.lw({ "daemon", "kill" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr .. r.stdout)
    end

    --- The profile row (`dev`) of the daemon's workspace view.
    local function profile_row()
        assert.is_true(vim.wait(60000, function()
            local v = obs:workspace_view()
            return v ~= nil and #(v.profiles or {}) > 0
        end, 20), obs:runtime_line())
        for _, row in ipairs(obs:workspace_view().profiles) do
            if row.key == "dev" then return row end
        end
        error("no profile row dev")
    end

    --- The device choice of the profile row (`Profiles/1.set_device`, or
    --- `clear_device` for nil): its outcome.
    local function set_device(device)
        local r
        local method = device and "Profiles/1.set_device" or "Profiles/1.clear_device"
        require("loomworks.ui.model_calls").call(nil, method, { profile = profile_row(), device = device },
            function(x) r = x end)
        assert.is_true(vim.wait(30000, function() return r ~= nil end, 20), method)
        return r
    end

    --- Scan, then choose SER1 for the profile (Devices/1.scan, Profiles/1.set_device).
    local function choose_ser1()
        local scanned
        device_source.scan(nil, function(list) scanned = list or false end)
        assert.is_true(vim.wait(60000, function() return scanned ~= nil end, 20))
        local r = set_device(assert(rec(scanned, "SER1")))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(nil), "SER1")
            return d ~= nil and d.profiles ~= nil and d.profiles[1] == "dev" and profile_row().device ~= nil
        end, 20))
    end

    --- The profile's default target: its `Launch/1.targets` record marked
    --- default (the fixture's device target `app`).
    local function default_target()
        local refs
        require("loomworks.daemon.facade").targets(profile_row(), function(r) refs = r end)
        assert.is_true(vim.wait(30000, function() return refs ~= nil end, 20), obs:runtime_line())
        for _, r in ipairs(refs) do
            if r.default then return r end
        end
        error("no default target: " .. vim.inspect(refs))
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

    --- Start `target` (default: the profile's default target); true when a
    --- question was asked.
    local function start_asked(target)
        local asked = false
        local orig = vim.ui.select
        vim.ui.select = function() asked = true end
        session_tracker.start(target or default_target(), "launch")
        vim.ui.select = orig
        return asked
    end

    it("lists, scans, chooses, launches and stops through Devices/1; refused once disconnected", function()
        serve()

        -- The list comes from Devices/1.list: empty until a scan.
        assert.same({}, device_source.list(nil))

        -- A scan is a Devices/1.scan task the editor owns; then the registry.
        local scanned
        device_source.scan(nil, function(list, err) scanned = { list = list, err = err } end)
        assert.is_true(vim.wait(60000, function() return scanned ~= nil end, 20))
        assert.is_nil(scanned.err)
        assert.equals("online", rec(scanned.list, "SER1").state)
        assert.equals("offline", rec(scanned.list, "SER2").state)
        assert.is_string(rec(scanned.list, "SER1").id)
        assert.is_true(started[1] ~= nil and started[1].owned)
        assert.equals("scan", started[1].kind)

        -- `changed` refreshes it: another client chooses SER1 for `dev`.
        sess = H.session(root)
        local res, err = H.call(sess, "/profiles", "loomworks.Profiles", 1, "set_device",
            { profile = { key = "dev" }, device = { key = "SER1" } }, vim.fn.environ())
        assert.equals("ok", res and res.outcome, vim.inspect(err or res))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(nil), "SER1")
            return d ~= nil and d.profiles ~= nil and d.profiles[1] == "dev"
        end, 20))

        -- clear / select are Profiles/1 writes by the profile row's id.
        local cleared = set_device(nil)
        assert.equals("ok", cleared.outcome, vim.inspect(cleared))
        assert.is_true(vim.wait(30000, function()
            return rec(device_source.list(nil), "SER1").profiles == nil and profile_row().device == nil
        end, 20))
        local chosen = set_device(rec(device_source.list(nil), "SER1"))
        assert.equals("ok", chosen.outcome, vim.inspect(chosen))
        assert.truthy(read(root .. "/.nvim/loomworks.user.json"):find('"SER1"', 1, true))
        assert.is_true(vim.wait(30000, function()
            local d = rec(device_source.list(nil), "SER1")
            return d.profiles ~= nil and d.profiles[1] == "dev" and profile_row().device ~= nil
        end, 20))

        -- The default target's launch: Launch/1.build, install, launch.
        local target = default_target()
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
        drop()
        assert.is_true(vim.wait(30000, function() return not obs:can_call("device_scan") end, 20))
        notes = {}
        local refused
        device_source.scan(nil, function(list, err) refused = { list = list, err = err } end)
        assert.is_true(vim.wait(5000, function() return refused ~= nil end, 20))
        assert.is_nil(refused.list)
        assert.truthy(refused.err:find("^device scan: "), refused.err)
        assert.same({}, device_source.list(nil))
        local before = #started
        session_tracker.start(target, "launch")
        -- Refused: by the launch's call, or (once the editor has seen the
        -- workspace unloaded) before it.
        assert.is_true(vim.wait(10000, function()
            return noted("loomworks: launch: ") or noted("loomworks: cannot run ")
        end, 20), vim.inspect(notes))
        assert.equals(before, #started)
        assert.is_false(session_tracker.is_running())
        local wrote
        require("loomworks.ui.model_calls").call(nil, "Profiles/1.clear_device", { profile = { id = "gone" } },
            function(x) wrote = x end)
        assert.is_true(vim.wait(5000, function() return wrote ~= nil end, 20))
        assert.equals("refused", wrote.outcome, vim.inspect(wrote))
        assert.is_nil(editor_ops.devices(nil))
    end)

    it("an install that fails ends the chain with its error; nothing is launched", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_DEVICE_FAIL = "install"
        notes = {}
        session_tracker.start(default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return #errors() > 0 end, 20), vim.inspect(notes))
        vim.wait(300)
        assert.same({ "scan", "build", "install" }, kinds())
        assert.is_false(session_tracker.is_running())
        assert.is_nil(read(log):find("launch SER1", 1, true), read(log))
        -- Nothing left preparing: a new launch starts at once (no question),
        -- reaches its install again and runs.
        vim.env.LW_TEST_DEVICE_FAIL = nil
        assert.is_false(start_asked())
        assert.is_true(vim.wait(180000, function()
            local n = 0
            for _, k in ipairs(kinds()) do if k == "install" then n = n + 1 end end
            return n == 2
        end, 20), vim.inspect(kinds()))
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
    end)

    it("a launch that fails ends the chain with its error; no run is tracked", function()
        serve()
        choose_ser1()
        vim.env.LW_TEST_DEVICE_FAIL = "launch"
        notes = {}
        session_tracker.start(default_target(), "launch")
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
        local target = default_target()
        session_tracker.start(target, "launch")
        assert.is_true(vim.wait(180000, function() return task_of("install") ~= nil end, 20), vim.inspect(notes))
        drop()
        assert.is_true(vim.wait(30000, function() return #errors() > 0 end, 20), vim.inspect(notes))
        assert.is_nil(task_of("launch"))
        assert.is_false(session_tracker.is_running())
        -- Nothing left preparing: a new launch asks nothing (refused: unloaded).
        assert.is_false(start_asked(target))
        assert.is_true(vim.wait(10000, function() return noted("loomworks: cannot run ") end, 20), vim.inspect(notes))
    end)

    it("a launched run is forgotten when the daemon disconnects: its stop sends nothing, no error", function()
        serve()
        choose_ser1()
        session_tracker.start(default_target(), "launch")
        assert.is_true(vim.wait(180000, function() return session_tracker.is_running() end, 20),
            vim.inspect(errors()))
        drop()
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
        session_tracker.start(default_target(), "launch")
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
        session_tracker.start(default_target(), "launch")
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
        session_tracker.start(default_target(), "launch")
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

    -- GAP: the daemon's log queue bound (2000 records) cannot be lowered
    -- in a real lw, and a flood past it is too slow for a spec.
    pending("records the daemon's queue dropped are a gap line in the view "
        .. "(GAP: the daemon's log queue bound is not settable through lw's CLI or the protocol)")

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

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
