-- Temporary files are never written through a file or link planted at their
-- name (a repository's `.nvim/` can be writable by other local users): the
-- daemon handle's staged copy (spec §19.6), io.write_file_atomic's `.tmp`
-- and the commit journal's `.tmp` (§19.4, tests/txn_spec.lua). Hard links
-- stand in for symbolic links on Windows (no privilege needed); POSIX also
-- checks a symbolic link.

local handle = require("loomworks.daemon.handle")
local dpaths = require("loomworks.daemon.paths")
local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop

local function tmpdir()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end

local IS_WIN = package.config:sub(1, 1) == "\\"

--- Plant links at `at` pointing to a victim file; returns the victim's path.
local function plant(dir, at, kind)
    local victim = dir .. "/victim-" .. kind .. ".txt"
    write(victim, "PRECIOUS")
    if kind == "hard" then
        assert(uv.fs_link(victim, at))
    else
        assert(uv.fs_symlink(victim, at))
    end
    return victim
end

local kinds = IS_WIN and { "hard" } or { "hard", "sym" }

describe("planted links at a temporary file's name", function()
    for _, kind in ipairs(kinds) do
        it("the daemon handle's staged copy never writes through one (" .. kind .. " link)", function()
            local root = tmpdir()
            vim.fn.mkdir(root .. "/.nvim", "p")
            local saved = handle._suffix
            handle._suffix = function() return "fixed" end
            local victim = plant(root, dpaths.handle_path(root) .. ".tmp-fixed", kind)
            local ok = handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 2 })
            handle._suffix = saved
            assert.is_nil(ok)
            assert.equals("PRECIOUS", read(victim))
            assert.is_nil(handle.read(root))
            -- With a fresh random name the write succeeds.
            assert.is_true(handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 2 }))
            assert.equals("PRECIOUS", read(victim))
        end)

        it("io.write_file_atomic's .tmp never writes through one (" .. kind .. " link)", function()
            local dir = tmpdir()
            local target = dir .. "/loomworks.user.json"
            write(target, "old")
            local victim = plant(dir, target .. ".tmp", kind)
            assert.is_true((io_mod.write_file_atomic(target, "new")))
            assert.equals("new", read(target))
            assert.equals("PRECIOUS", read(victim))
        end)
    end

    it("io.write_exclusive refuses an existing name", function()
        local dir = tmpdir()
        write(dir .. "/x", "keep")
        local ok, _, code = io_mod.write_exclusive(dir .. "/x", "nope")
        assert.is_false(ok)
        assert.equals("EEXIST", code)
        assert.equals("keep", read(dir .. "/x"))
    end)
end)
