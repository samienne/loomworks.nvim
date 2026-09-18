-- Daemon handle file: write/read round-trip + mtime-heartbeat staleness.

local handle = require("loomworks.daemon.handle")
local uv = vim.uv or vim.loop

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

local function sample(over)
    local info = {
        pid = 4242,
        pipe = "\\\\.\\pipe\\loomworks-test",
        protocol_version = 1,
        lw_version = "0.1.0",
        session_generation = 3,
        started_at = os.time(),
    }
    for k, v in pairs(over or {}) do info[k] = v end
    return info
end

describe("daemon.handle", function()
    local root
    before_each(function() root = fresh_root() end)

    it("returns nil when no handle exists", function()
        assert.is_nil(handle.read(root))
        assert.is_false(handle.is_live(handle.read(root)))
    end)

    it("writes and reads back the durable fields", function()
        assert.is_true(handle.write(root, sample()))
        local info = handle.read(root)
        assert.equals(4242, info.pid)
        assert.equals(1, info.protocol_version)
        assert.equals("0.1.0", info.lw_version)
        assert.equals(3, info.session_generation)
        assert.is_false(info.stale)
        assert.is_true(handle.is_live(info))
    end)

    it("does not persist the computed age/stale fields", function()
        handle.write(root, sample())
        -- Read once (adds age/stale), then re-write from that table: the durable
        -- writer must strip the derived fields so they never leak into the file.
        local info = handle.read(root)
        handle.write(root, info)
        local raw = uv.fs_open(handle.path(root), "r", tonumber("400", 8))
        local data = uv.fs_read(raw, 8192, 0)
        uv.fs_close(raw)
        assert.is_nil(data:find("\"age\""))
        assert.is_nil(data:find("\"stale\""))
    end)

    it("marks a handle stale once its mtime crosses the heartbeat window", function()
        handle.write(root, sample())
        local old = os.time() - (handle.STALE_SECONDS + 60)
        uv.fs_utime(handle.path(root), old, old)
        local info = handle.read(root)
        assert.is_true(info.stale)
        assert.is_false(handle.is_live(info))
    end)

    it("heartbeat refreshes the mtime so a stale handle becomes live", function()
        handle.write(root, sample())
        local old = os.time() - (handle.STALE_SECONDS + 60)
        uv.fs_utime(handle.path(root), old, old)
        assert.is_true(handle.read(root).stale)
        assert.is_true(handle.heartbeat(root))
        assert.is_false(handle.read(root).stale)
    end)

    it("heartbeat is a no-op when the handle is absent", function()
        assert.is_false(handle.heartbeat(root))
    end)

    it("remove deletes the handle", function()
        handle.write(root, sample())
        assert.is_true(handle.remove(root))
        assert.is_nil(handle.read(root))
        assert.is_false(handle.remove(root))
    end)
end)
