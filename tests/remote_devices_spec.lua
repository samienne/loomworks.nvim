-- Device registry for runners + selection (spec §18.3) and `lw device
-- list/select` (spec §16.34), against the fake runner's in-memory device.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local devices = require("loomworks.remote.devices")
local runners = require("loomworks.remote.runners")
local fx = require("tests.remote_fixtures")

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return { ok = ok, ret = ret, exit_code = exit_code,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function mock_ws(sdk, profiles)
    return {
        _profiles = profiles or {},
        _devices = {},
        sdks = function() return { sdk } end,
    }
end

local function mock_profile(key, serial)
    local p = { key = key, _device_serial = serial, saved = 0 }
    function p:set_device(s) self._device_serial = s; self.saved = self.saved + 1 end
    function p:clear_device() self._device_serial = nil; self.saved = self.saved + 1 end
    function p:projects() return {} end
    function p:sdk() return nil end
    return p
end

describe("remote.devices.select (§18.3)", function()
    local list = {
        { serial = "A", state = "online", display_name = "A" },
        { serial = "B", state = "offline", display_name = "Bee" },
    }

    it("explicit wins, then persisted, then the sole online device", function()
        local two = { list[1], { serial = "C", state = "online", display_name = "C" } }
        assert.equals("C", (devices.select(two, { explicit = "C", persisted = "A" })))
        assert.equals("A", (devices.select(two, { persisted = "A" })))
        local s, _, src = devices.select(list, {})
        assert.equals("A", s)
        assert.equals("sole", src)
    end)

    it("a named serial that is not online is an error naming it — never substituted", function()
        local s, err = devices.select(list, { explicit = "B", runner_id = "fake" })
        assert.is_nil(s)
        assert.truthy(err:find("device 'B' is offline", 1, true))
        s, err = devices.select(list, { persisted = "Z", profile_key = "P" })
        assert.is_nil(s)
        assert.truthy(err:find("persisted for profile 'P'", 1, true))
        assert.truthy(err:find("not attached", 1, true))
    end)

    it("none or several online with nothing selected is an error listing them", function()
        local _, err = devices.select({ list[2] }, { runner_id = "fake" })
        assert.truthy(err:find("no device online", 1, true))
        assert.truthy(err:find("B (offline, Bee)", 1, true))
        _, err = devices.select({ list[1], { serial = "C", state = "online", display_name = "C" } }, {})
        assert.truthy(err:find("2 devices online (A, C)", 1, true))
        assert.truthy(err:find("--device <serial>", 1, true))
    end)
end)

describe("remote.devices.list + merge", function()
    it("lists through the executor, skips placeholders, merges without touching module devices", function()
        local dev = fx.device({ serials = { S1 = "One", S2 = "Two" } })
        dev.boards.S2.state = "Offline"
        local r = fx.fake_runner_table()
        local l = assert(devices.list(r, { backend = dev:backend() }))
        assert.equals(2, #l)
        assert.equals("online", l[1].state)
        assert.equals("offline", l[2].state)
        assert.equals("fake", l[1].provider)

        local Device = require("loomworks.device")
        local ws = { _devices = { MOD = Device.new({ serial = "MOD", provider = "somemodule" }) } }
        devices.merge(ws, "fake", l)
        assert.equals("fake", ws._devices.S1.provider)
        -- the runner's device vanishes → offline; the module's is untouched
        devices.merge(ws, "fake", { l[2] })
        assert.equals("offline", ws._devices.S1.state)
        assert.equals("online", ws._devices.MOD.state)

        dev.boards = {}
        local empty = assert(devices.list(r, { backend = dev:backend() }))
        assert.equals(0, #empty) -- "[Empty]" is not a device
    end)
end)

describe("lw device list / select", function()
    after_each(function() runners._reset() end)

    it("prints serial, state, runner, name and the persisting profile", function()
        local dev = fx.device({ serials = { S1 = "Board One" } })
        local sdk = fx.fake_sdk(fx.fake_runner_table())
        local ws = mock_ws(sdk, { mock_profile("Debug:kit", "S1") })
        local res = capture(function() return cli._device_list(ws, {}, { backend = dev:backend() }) end)
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)
        assert.truthy(res.stdout:find("SERIAL", 1, true))
        assert.truthy(res.stdout:find("S1%s+online%s+fake%s+Board One%s+%(device for Debug:kit%)"))
        assert.equals("online", ws._devices.S1.state)
    end)

    it("--json emits a machine-readable list; empty list exits 0", function()
        local dev = fx.device({ serials = {} })
        local sdk = fx.fake_sdk(fx.fake_runner_table())
        local res = capture(function()
            return cli._device_list(mock_ws(sdk), { json = true }, { backend = dev:backend() })
        end)
        assert.equals(0, res.ret)
        local decoded = vim.json.decode(res.stdout)
        assert.equals(0, #decoded.devices)
    end)

    it("no runner in scope is an error", function()
        local sdk = { key = "x", _provider = {}, is_resolved = function() return true end }
        local res = capture(function() return cli._device_list(mock_ws(sdk), {}, {}) end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.truthy(res.stderr:find("no device runner available", 1, true))
    end)

    it("select persists and --clear removes the profile's serial", function()
        local p = mock_profile("Debug")
        local ws = mock_ws(nil, { p })
        local res = capture(function() return cli._device_select(ws, { "SER9", "Debug" }) end)
        assert.is_true(res.ok, res.stderr)
        assert.equals("SER9", p._device_serial)
        res = capture(function() return cli._device_select(ws, { "--clear", "Debug" }) end)
        assert.is_true(res.ok)
        assert.is_nil(p._device_serial)
        assert.equals(2, p.saved)
    end)

    it("device clean removes this workspace's staging tree and its sync records", function()
        local saved = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
        local lockroot = fx.mkroot()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockroot
        local dev = fx.device({ serials = { S1 = "One" } })
        dev.boards.S1.files["/data/stage/myws/u/a"] = { data = "x" }
        dev.boards.S1.files["/data/stage/other/b"] = { data = "y" }
        local sdk = fx.fake_sdk(fx.fake_runner_table())
        local ws = mock_ws(sdk)
        ws.name = "myws"
        ws._device_sync = { S1 = { ["/data/stage/myws/u"] = { files = {} }, ["/data/stage/other/v"] = {} } }
        local saves = 0
        ws._save_cache = function() saves = saves + 1 end
        local res = capture(function() return cli._device_clean(ws, {}, { backend = dev:backend() }) end)
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved
        require("loomworks.io").rm_rf(lockroot)
        assert.is_true(res.ok, res.stderr)
        assert.truthy(res.stdout:find("removed /data/stage/myws from S1", 1, true))
        assert.is_nil(dev.boards.S1.files["/data/stage/myws/u/a"])
        assert.is_not_nil(dev.boards.S1.files["/data/stage/other/b"])
        assert.is_nil(ws._device_sync.S1["/data/stage/myws/u"])
        assert.is_not_nil(ws._device_sync.S1["/data/stage/other/v"])
        assert.equals(1, saves)
    end)

    it("select without a profile under non-interactive mode refuses", function()
        local ws = mock_ws(nil, { mock_profile("A"), mock_profile("B") })
        local res = capture(function() return cli._device_select(ws, { "SER9" }) end)
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("no profile specified", 1, true))
    end)
end)
