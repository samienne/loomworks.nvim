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
        saved_env = { lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR, log = vim.env.LW_TEST_DEVICE_LOG }
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

    it("lists, scans, chooses, launches and stops through Devices/1; refused once disconnected", function()
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
            kinds[#kinds + 1] = t.kind
        end
        assert.same({ "scan", "build", "install", "launch" }, kinds)
        local id = session_tracker.active_run().device_task
        assert.is_not_nil(id)
        local lines = read(log)
        assert.truthy(lines:find("install SER1", 1, true), lines)
        assert.truthy(lines:find("launch SER1 com.example.app", 1, true), lines)
        -- The device log is refused, never streamed here.
        assert.is_true(noted("device log: unavailable in daemon mode"))
        assert.is_false(require("loomworks.device_log").is_running())

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
end)
