-- The workspace log `.nvim/loomworks.log` is shared by every host (the editor
-- and each `lw` invocation): it is appended to, never truncated, so earlier
-- invocations' lines survive; its size is bounded by rotating it to
-- `loomworks.log.1` (one old file kept) once it exceeds the limit.

local log = require("loomworks.log")

local function read(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

describe("workspace log file", function()
    local root, saved_max
    before_each(function()
        root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root .. "/.nvim", "p")
        saved_max = log.MAX_BYTES
    end)
    after_each(function()
        log.MAX_BYTES = saved_max
        vim.fn.delete(root, "rf")
    end)

    it("appends across loggers (one per invocation) instead of truncating", function()
        local a = log.new(); a:set_root(root); a:info("first invocation")
        local b = log.new(); b:set_root(root); b:info("second invocation")
        local s = read(root .. "/.nvim/loomworks.log")
        assert.truthy(s:find("first invocation", 1, true), s)
        assert.truthy(s:find("second invocation", 1, true), s)
        assert.is_true(s:find("first invocation", 1, true) < s:find("second invocation", 1, true))
        local _, starts = s:gsub("loomworks log started", "")
        assert.equals(2, starts)
    end)

    it("rotates to loomworks.log.1 past the limit, keeping one old file", function()
        log.MAX_BYTES = 200
        local p = root .. "/.nvim/loomworks.log"
        local a = log.new(); a:set_root(root)
        for i = 1, 10 do a:info("old line %d %s", i, string.rep("x", 30)) end
        -- Rotated while writing: the live file is back under (about) the limit
        -- and the previous content is in .1.
        assert.truthy(read(p .. ".1"))
        assert.is_true(#read(p) <= 200 + 80, tostring(#read(p)))
        -- A new invocation over an oversized file rotates before it starts.
        local f = io.open(p, "ab"); f:write(string.rep("y", 300) .. "\n"); f:close()
        local b = log.new(); b:set_root(root); b:info("fresh")
        local live, old = read(p), read(p .. ".1")
        assert.truthy(live:find("fresh", 1, true))
        assert.is_nil(live:find("yyyy", 1, true))
        assert.truthy(old:find("yyyy", 1, true), "the rotated file replaces the previous .1")
        assert.is_nil(vim.uv.fs_stat(p .. ".2"))
    end)

    it("never writes without a root (default logger before set_root)", function()
        local a = log.new()
        a:info("nowhere")
        assert.is_nil(vim.uv.fs_stat(root .. "/.nvim/loomworks.log"))
    end)
end)
