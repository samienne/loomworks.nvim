-- Per-device lock (spec §18.7): per-serial lockfile in a per-user directory
-- (relocatable via LOOMWORKS_DEVICE_LOCK_DIR), waits by default printing the
-- holder once, `wait = false` fails fast, stale locks are reclaimed, and
-- `lw unlock --device <serial>` clears one.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local device_lock = require("loomworks.remote.device_lock")
local fx = require("tests.remote_fixtures")
local uv = vim.uv or vim.loop

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

describe("remote.device_lock", function()
    local root, saved
    before_each(function()
        root = fx.mkroot()
        saved = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = root .. "/locks"
    end)
    after_each(function()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved
        require("loomworks.io").rm_rf(root)
    end)

    it("lives at <LOOMWORKS_DEVICE_LOCK_DIR>/<serial>.lock; odd serials stay inside the dir", function()
        assert.equals(root .. "/locks/SER1.lock", device_lock.path("SER1"))
        assert.equals(root .. "/locks/192.168.0.2_5555.lock", device_lock.path("192.168.0.2:5555"))
        assert.equals(root .. "/locks/.._.._x.lock", device_lock.path("../../x"))
    end)

    it("is exclusive; wait=false fails fast naming the holder", function()
        local h = assert(device_lock.acquire("SER1", { action = "run", workspace = "ws1" }))
        local h2, err = device_lock.acquire("SER1", { wait = false })
        assert.is_nil(h2)
        assert.truthy(err:find("device SER1 is in use by pid", 1, true))
        assert.truthy(err:find("workspace ws1", 1, true))
        assert.truthy(err:find("lw unlock --device SER1", 1, true))
        device_lock.release(h)
        local h3 = assert(device_lock.acquire("SER1", { wait = false }))
        device_lock.release(h3)
    end)

    it("waits by default, announcing the holder once, until released", function()
        local h = assert(device_lock.acquire("SER2"))
        local t = uv.new_timer()
        t:start(400, 0, function() t:close(); device_lock.release(h) end)
        local msgs = {}
        local h2 = device_lock.acquire("SER2", {
            poll_ms = 50, on_wait = function(m) msgs[#msgs + 1] = m end,
        })
        assert.is_not_nil(h2)
        assert.equals(1, #msgs)
        assert.truthy(msgs[1]:find("waiting for it", 1, true))
        device_lock.release(h2)
    end)

    it("reclaims a stale lock", function()
        local path = device_lock.path("SER3")
        fx.write(path, vim.json.encode({ pid = 1, action = "run" }))
        local old = os.time() - 3600
        uv.fs_utime(path, old, old)
        local h = assert(device_lock.acquire("SER3", { wait = false }))
        device_lock.release(h)
    end)

    it("lw unlock --device clears a lock", function()
        local h = assert(device_lock.acquire("SER4"))
        h.timer:stop()
        local res = capture(function() return cli.cmd_unlock(nil, { "unlock", "--device", "SER4" }) end)
        assert.is_true(res.ok, res.stderr)
        assert.truthy(res.stdout:find("unlocked device SER4", 1, true))
        assert.truthy(res.stderr:find("ACTIVE device lock", 1, true))
        assert.is_nil(device_lock.read("SER4"))
        res = capture(function() return cli.cmd_unlock(nil, { "unlock", "--device", "SER4" }) end)
        assert.truthy(res.stdout:find("no device lock for SER4", 1, true))
        pcall(function() h.timer:close() end)
    end)
end)
