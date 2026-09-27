--- Build-directory deletion is done in-process (libuv filesystem calls), never
--- by composing a shell command line from a path, never follows a link out of
--- the tree being deleted, and never removes the workspace root itself.
--- Fixtures are scratch directories; the assertions are about what survives.

local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop
local IS_WIN = vim.fn.has("win32") == 1

local function touch(p, text)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "w")); f:write(text or "x"); f:close()
end

local function exists(p) return uv.fs_lstat(p) ~= nil end

--- Link `path` -> directory `target` (a junction on Windows: no privilege needed).
local function dir_link(target, path)
    local ok = uv.fs_symlink(target, path, IS_WIN and { junction = true } or nil)
    return ok == true
end

local function wait_future(f)
    local done, ok_v, err_v = false, nil, nil
    f:next(function() ok_v = true; done = true end)
     :catch(function(e) ok_v = false; err_v = e; done = true end)
    vim.wait(20000, function() return done end, 10)
    return ok_v, err_v
end

describe("io deletion", function()
    local tmp
    before_each(function()
        tmp = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(tmp, "p")
    end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("rm_rf_async removes a directory whose name has shell metacharacters", function()
        local victim = tmp .. "/keep"
        touch(victim .. "/file.txt")
        local dir = tmp .. "/a&b"
        touch(dir .. "/sub/f.o")
        touch(dir .. "/g.o")
        local ok, err = wait_future(io_mod.rm_rf_async(dir))
        assert.is_true(ok, tostring(err))
        assert.is_false(exists(dir))
        assert.is_true(exists(victim .. "/file.txt"))
    end)

    it("rm_rf_async removes a read-only file", function()
        local dir = tmp .. "/ro"
        touch(dir .. "/obj.pack")
        uv.fs_chmod(dir .. "/obj.pack", 292) -- 0444
        local ok, err = wait_future(io_mod.rm_rf_async(dir))
        assert.is_true(ok, tostring(err))
        assert.is_false(exists(dir))
    end)

    it("rm_rf_async does not follow a directory link inside the tree", function()
        local outside = tmp .. "/outside"
        touch(outside .. "/precious.txt")
        local dir = tmp .. "/build"
        touch(dir .. "/x.o")
        if not dir_link(outside, dir .. "/link") then pending("cannot create a directory link here") return end
        local ok, err = wait_future(io_mod.rm_rf_async(dir))
        assert.is_true(ok, tostring(err))
        assert.is_false(exists(dir))
        assert.is_true(exists(outside .. "/precious.txt"))
    end)

    it("rm_rf (sync) does not follow a top-level directory link", function()
        local outside = tmp .. "/outside"
        touch(outside .. "/precious.txt")
        if not dir_link(outside, tmp .. "/buildlink") then pending("cannot create a directory link here") return end
        local ok, err = io_mod.rm_rf(tmp .. "/buildlink")
        assert.is_true(ok, tostring(err))
        assert.is_false(exists(tmp .. "/buildlink"))
        assert.is_true(exists(outside .. "/precious.txt"))
    end)

    it("rm_rf_async does not follow a top-level directory link", function()
        local outside = tmp .. "/outside"
        touch(outside .. "/precious.txt")
        if not dir_link(outside, tmp .. "/buildlink") then pending("cannot create a directory link here") return end
        local ok, err = wait_future(io_mod.rm_rf_async(tmp .. "/buildlink"))
        assert.is_true(ok, tostring(err))
        assert.is_false(exists(tmp .. "/buildlink"))
        assert.is_true(exists(outside .. "/precious.txt"))
    end)

    it("rm_rf_async resolves for a missing path", function()
        local ok = wait_future(io_mod.rm_rf_async(tmp .. "/nope"))
        assert.is_true(ok)
    end)
end)

describe("_validate_build_dir refuses the workspace root", function()
    local function make_ws()
        local ws = setmetatable({ root = "C:/ws/root", _core = {
            _deps = {
                normalize = function(p) return (p:gsub("\\", "/"):gsub("/+$", ""):lower()) end,
                notify = function() end,
                realpath = function() return nil end,
            },
        } }, { __index = require("loomworks.workspace").Workspace })
        return ws
    end
    it("refuses build_dir == root (and with a trailing slash)", function()
        local ws = make_ws()
        assert.is_false(ws:_validate_build_dir("C:/ws/root", "C:/ws/root"))
        assert.is_false(ws:_validate_build_dir("C:/ws/root/", "C:/ws/root"))
        assert.is_true(ws:_validate_build_dir("C:/ws/root/build", "C:/ws/root"))
    end)

    it("allows the root only when the caller opts in (in-source configure-state reset)", function()
        local ws = make_ws()
        assert.is_true(ws:_validate_build_dir("C:/ws/root", "C:/ws/root", { allow_root = true }))
    end)
end)

describe("shell module default clean", function()
    local shell = require("loomworks.modules.shell")

    it("asks core to wipe the build dir instead of composing a shell command", function()
        local ctx = {
            name = "App", path = "App", workspace_root = "C:/ws",
            configuration = "Debug", configuration_key = "Debug",
            configurations = { Debug = {} },
            type_config = {
                build_dir = "C:/ws/out/a&b Debug",
                build_cmd = { "make" },
            },
        }
        local tasks = shell.clean_tasks(ctx, "Debug")
        assert.equals(1, #tasks)
        local t = tasks[1]
        assert.is_true(t.loomworks.wipe_build_dir == true)
        assert.is_string(t.loomworks.build_dir)
        assert.is_nil(t.builder, "default clean must not spawn a command")
    end)
end)

describe("core-performed wipe (wipe_build_dir)", function()
    local overseer_mod = require("loomworks.overseer")
    local Workspace = require("loomworks.workspace").Workspace
    local tmp

    local function real_ws(root)
        return setmetatable({ root = root, _core = { _deps = {
            normalize = function(p)
                p = (p or ""):gsub("\\", "/"):gsub("/+$", "")
                return IS_WIN and p:lower() or p
            end,
            notify = function() end,
            io = io_mod,
        } } }, { __index = Workspace })
    end

    before_each(function()
        tmp = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(tmp .. "/ws/build/App", "p")
        touch(tmp .. "/ws/build/App/a.o")
        touch(tmp .. "/ws/src.c")
        touch(tmp .. "/other/keep.txt")
    end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("removes a build dir under the workspace root", function()
        local ws = real_ws(tmp .. "/ws")
        local ok = wait_future(overseer_mod._wipe_build_dir(ws,
            { loomworks = { build_dir = tmp .. "/ws/build/App", wipe_build_dir = true } }))
        assert.is_true(ok)
        assert.is_false(exists(tmp .. "/ws/build/App"))
        assert.is_true(exists(tmp .. "/ws/src.c"))
    end)

    it("refuses the workspace root and paths outside it", function()
        local ws = real_ws(tmp .. "/ws")
        assert.is_false(wait_future(overseer_mod._wipe_build_dir(ws,
            { loomworks = { build_dir = tmp .. "/ws", wipe_build_dir = true } })))
        assert.is_false(wait_future(overseer_mod._wipe_build_dir(ws,
            { loomworks = { build_dir = tmp .. "/other", wipe_build_dir = true } })))
        assert.is_false(wait_future(overseer_mod._wipe_build_dir(ws,
            { loomworks = { build_dir = tmp .. "/ws/../other", wipe_build_dir = true } })))
        assert.is_true(exists(tmp .. "/ws/src.c"))
        assert.is_true(exists(tmp .. "/other/keep.txt"))
    end)

    it("treats a missing build dir as nothing to wipe", function()
        local ws = real_ws(tmp .. "/ws")
        assert.is_true(wait_future(overseer_mod._wipe_build_dir(ws, { loomworks = { wipe_build_dir = true } })))
    end)
end)
