-- Cross-process build-dir lock (build_lock.lua): O_EXCL lockfile + heartbeat
-- staleness. Exercised against real temp files (no second process needed — a
-- stale lock is simulated by aging the file mtime).

local bl = require("loomworks.build_lock")
local uv = vim.uv or vim.loop

local function fresh_build_dir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d .. "/build/variant"
end

describe("build_lock", function()
    local dir
    before_each(function() dir = fresh_build_dir() end)

    it("acquires, fails a second acquire (fail-fast), then releases", function()
        local h = assert(bl.acquire(dir, "build"))
        local h2, reason = bl.acquire(dir, "build")
        assert.is_nil(h2)
        assert.is_truthy(reason:find("in use"))
        bl.release(h)
        local h3 = assert(bl.acquire(dir, "build"))
        bl.release(h3)
    end)

    it("read returns the holder's info and clears after release", function()
        local h = assert(bl.acquire(dir, "configure"))
        local info = bl.read(dir)
        assert.equals("configure", info.action)
        assert.is_number(info.pid)
        assert.is_false(info.stale)
        bl.release(h)
        assert.is_nil(bl.read(dir))
    end)

    it("reclaims a stale (crashed-holder) lock", function()
        local h = assert(bl.acquire(dir, "build"))
        -- Simulate a crash: stop the heartbeat and age the mtime past the window.
        h.timer:stop(); h.timer:close(); h.timer = nil
        local old = os.time() - (bl.STALE_SECONDS + 60)
        uv.fs_utime(dir .. ".loomworks-lock", old, old)
        assert.is_true(bl.read(dir).stale)

        local h2 = assert(bl.acquire(dir, "build")) -- reclaims the stale lock
        assert.is_false(bl.read(dir).stale)
        bl.release(h2)
    end)

    it("does NOT reclaim a fresh lock", function()
        local h = assert(bl.acquire(dir, "build"))
        local h2, reason = bl.acquire(dir, "build")
        assert.is_nil(h2)
        assert.is_truthy(reason)
        bl.release(h)
    end)

    it("force removes a lock", function()
        local h = assert(bl.acquire(dir, "build"))
        h.timer:stop(); h.timer:close(); h.timer = nil
        assert.is_true(bl.force(dir))
        assert.is_nil(bl.read(dir))
        assert.is_false(bl.force(dir)) -- nothing to remove
    end)
end)
