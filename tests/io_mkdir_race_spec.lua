-- `io.mkdir_p` — mkdir -p that tolerates the concurrent-create race.
--
-- Neovim's `vim.fn.mkdir(path, "p")` checks, then creates. When two processes
-- (e.g. `lw configure` and the editor configuring two profiles that share a
-- brand-new parent directory) create the same directory at the same moment,
-- the loser throws E739 "file already exists" although the directory now
-- exists. The race is simulated deterministically: the stubbed mkdir creates
-- the directory (the "winner") and then throws E739 (the "loser").

local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop

local function tmpdir()
    local p = vim.fn.tempname()
    assert(vim.fn.mkdir(p, "p") == 1)
    return (p:gsub("\\", "/"))
end

local real_mkdir = vim.fn.mkdir

--- Make vim.fn.mkdir lose the race: another process creates the directory
--- between the existence check and the create, so mkdir throws E739.
local function lose_the_race()
    vim.fn.mkdir = function(path, flags)
        real_mkdir(path, flags)
        error("Vim:E739: Cannot create directory " .. path .. ": file already exists")
    end
end

local function is_dir(p)
    local st = uv.fs_stat(p)
    return st ~= nil and st.type == "directory"
end

describe("io.mkdir_p", function()
    local base
    before_each(function() base = tmpdir() end)
    after_each(function()
        vim.fn.mkdir = real_mkdir
        vim.fn.delete(base, "rf")
    end)

    it("creates a nested directory", function()
        local p = base .. "/a/b/c"
        assert.is_true(io_mod.mkdir_p(p))
        assert.is_true(is_dir(p))
    end)

    it("succeeds when the directory already exists", function()
        assert.is_true(io_mod.mkdir_p(base))
    end)

    it("treats a lost concurrent-create race (E739, directory now exists) as success", function()
        local p = base .. "/shared/new"
        lose_the_race()
        local ok, err = io_mod.mkdir_p(p)
        vim.fn.mkdir = real_mkdir
        assert.is_true(ok, err)
        assert.is_true(is_dir(p))
    end)

    it("keeps going when the race is lost on an INTERMEDIATE component", function()
        -- mkdir -p aborts at the first component it loses the race on, so the
        -- leaf does not exist yet: the other process created only `shared`.
        local mid, p = base .. "/shared", base .. "/shared/a/b"
        local calls = 0
        vim.fn.mkdir = function(path, flags)
            calls = calls + 1
            if calls == 1 then
                real_mkdir(mid, "p")
                error("Vim:E739: Cannot create directory " .. mid .. ": file already exists")
            end
            return real_mkdir(path, flags)
        end
        local ok, err = io_mod.mkdir_p(p)
        vim.fn.mkdir = real_mkdir
        assert.is_true(ok, err)
        assert.is_true(is_dir(p))
    end)

    it("still fails when a FILE is in the way", function()
        local p = base .. "/blocker"
        local f = assert(io.open(p, "wb")); f:write("x"); f:close()
        local ok, err = io_mod.mkdir_p(p .. "/sub")
        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_true(#err > 0)
        assert.is_false(is_dir(p .. "/sub"))
    end)

    it("ensure_dir tolerates the race too", function()
        local p = base .. "/ens/new"
        lose_the_race()
        local ok, err = io_mod.ensure_dir(p)
        vim.fn.mkdir = real_mkdir
        assert.is_true(ok, err)
        assert.is_true(is_dir(p))
    end)
end)

describe("product mkdir sites tolerate the race", function()
    local base
    before_each(function() base = tmpdir() end)
    after_each(function()
        vim.fn.mkdir = real_mkdir
        vim.fn.delete(base, "rf")
    end)

    it("shell configure: a build dir created concurrently does not fail the task", function()
        local shell = require("loomworks.modules.shell")
        local tasks = shell.tasks({
            name = "p", path = "p", type = "shell",
            configuration = "default", configuration_key = "default",
            configurations = { default = { variant = "default" } },
            workspace_root = base, env = {},
            type_config = {
                build_dir = "${workspace_root}/out/${variant}",
                configure_cmd = { "true" },
                build_cmd = { "true" },
            },
        }, "default")
        lose_the_race()
        local ok, spec = pcall(tasks[1].builder)
        vim.fn.mkdir = real_mkdir
        assert.is_true(ok, tostring(spec))
        assert.same({ "true" }, spec.cmd)
        assert.is_true(is_dir(base .. "/out/default"))
    end)
end)
