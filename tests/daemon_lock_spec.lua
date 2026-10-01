-- Write-authority lock: O_EXCL + mtime-heartbeat staleness, distinct file from
-- build_lock. Exercised against real temp files (stale simulated by aging mtime).

local lock = require("loomworks.daemon.lock")
local uv = vim.uv or vim.loop

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

describe("daemon.lock", function()
    local root
    before_each(function() root = fresh_root() end)

    it("uses the .nvim/loomworks.daemon.lock file, not a build-dir name", function()
        local h = assert(lock.acquire(root))
        assert.is_truthy(h.path:find("%.nvim/loomworks%.daemon%.lock$"))
        lock.release(h)
    end)

    it("acquires, refuses a second live acquire, then releases", function()
        local h = assert(lock.acquire(root, { generation = 7 }))
        local h2, reason = lock.acquire(root)
        assert.is_nil(h2)
        assert.is_truthy(reason:find("already owns"))
        lock.release(h)
        local h3 = assert(lock.acquire(root))
        lock.release(h3)
    end)

    it("records pid + generation and clears after release", function()
        local h = assert(lock.acquire(root, { generation = 42 }))
        local info = lock.read(root)
        assert.is_number(info.pid)
        assert.equals(42, info.session_generation)
        assert.is_false(info.stale)
        lock.release(h)
        assert.is_nil(lock.read(root))
    end)

    it("reclaims a stale (crashed-holder) lock", function()
        local h = assert(lock.acquire(root))
        h.timer:stop(); h.timer:close(); h.timer = nil
        local old = os.time() - (lock.STALE_SECONDS + 60)
        uv.fs_utime(h.path, old, old)
        assert.is_true(lock.read(root).stale)
        local h2 = assert(lock.acquire(root))
        assert.is_false(lock.read(root).stale)
        lock.release(h2)
    end)

    it("force removes a lock", function()
        local h = assert(lock.acquire(root))
        h.timer:stop(); h.timer:close(); h.timer = nil
        assert.is_true(lock.force(root))
        assert.is_nil(lock.read(root))
        assert.is_false(lock.force(root))
    end)
end)
