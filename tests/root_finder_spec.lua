-- Workspace root discovery (spec §1.1): the upward search stops at a git
-- working-tree boundary (a repository root or a linked worktree) but walks
-- THROUGH submodules to the superproject's workspace. Fixtures are plain
-- directories with hand-written `.git` files/dirs — no git needed. The same
-- search backs `lw` (cli.lua) and the editor's auto-load (§13).

local uv = vim.uv or vim.loop
local finder = require("loomworks.root_finder")

-- Canonical fixture root: on Windows CI tempname() can hand back an 8.3 short
-- path (RUNNER~1); realpath expands it so path assertions compare like with like.
local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (uv.fs_realpath(d):gsub("\\", "/"))
end

local function mkdir(p) vim.fn.mkdir(p, "p") end

local function write(p, content)
    mkdir(vim.fn.fnamemodify(p, ":h"))
    local f = assert(io.open(p, "wb"))
    f:write(content)
    f:close()
end

local function norm(p) return p and (p:gsub("\\", "/")) or nil end

-- superproject/.git (dir) + loomworks.json, with submodule `sub` whose .git
-- file points at ../.git/modules/sub (and that gitdir exists as a real repo).
local function superproject(opts)
    opts = opts or {}
    local root = tmpdir()
    local super = root .. "/super"
    mkdir(super .. "/.git/modules/sub")
    write(super .. "/.git/HEAD", "ref: refs/heads/master\n")
    if opts.user_only then
        write(super .. "/.nvim/loomworks.user.json", '{ "_meta": { "version": 2 } }')
    else
        write(super .. "/loomworks.json", "{}")
    end
    write(super .. "/sub/.git", opts.sub_git or "gitdir: ../.git/modules/sub\n")
    mkdir(super .. "/sub/src/deep")
    return root, super
end

describe("root_finder.find", function()
    it("finds the workspace in the start dir itself", function()
        local _, super = superproject()
        local r, info = finder.find(super)
        assert.equals(super, norm(r))
        assert.is_nil(info and info.submodule)
    end)

    it("walks up through plain subdirectories", function()
        local _, super = superproject()
        mkdir(super .. "/src/a")
        assert.equals(super, norm(finder.find(super .. "/src/a")))
    end)

    it("walks from a submodule to the superproject workspace", function()
        local _, super = superproject()
        local r, info = finder.find(super .. "/sub")
        assert.equals(super, norm(r))
        assert.equals(super .. "/sub", norm(info.submodule))
    end)

    it("walks from deep inside a submodule", function()
        local _, super = superproject()
        assert.equals(super, norm(finder.find(super .. "/sub/src/deep")))
    end)

    it("recognizes a working-copy-only workspace above a submodule", function()
        local _, super = superproject({ user_only = true })
        assert.equals(super, norm(finder.find(super .. "/sub")))
    end)

    it("accepts backslashes in the start path", function()
        local _, super = superproject()
        assert.equals(super, norm(finder.find((super .. "/sub"):gsub("/", "\\"))))
    end)

    it("walks through nested submodules (.git/modules/A/modules/B)", function()
        local _, super = superproject()
        mkdir(super .. "/.git/modules/sub/modules/libs/inner")
        write(super .. "/sub/libs/inner/.git",
            "gitdir: ../../../.git/modules/sub/modules/libs/inner\n")
        local r, info = finder.find(super .. "/sub/libs/inner")
        assert.equals(super, norm(r))
        assert.equals(super .. "/sub/libs/inner", norm(info.submodule))
    end)

    it("handles a submodule whose name contains slashes", function()
        local _, super = superproject()
        mkdir(super .. "/.git/modules/third_party/fmt")
        write(super .. "/third_party/fmt/.git", "gitdir: ../../.git/modules/third_party/fmt\n")
        assert.equals(super, norm(finder.find(super .. "/third_party/fmt")))
    end)

    it("handles an absolute gitdir", function()
        local _, super = superproject({ sub_git = "" })
        write(super .. "/sub/.git", "gitdir: " .. super .. "/.git/modules/sub\n")
        assert.equals(super, norm(finder.find(super .. "/sub")))
    end)

    it("handles an absolute gitdir with backslashes", function()
        local _, super = superproject({ sub_git = "" })
        write(super .. "/sub/.git", "gitdir: " .. (super:gsub("/", "\\")) .. "\\.git\\modules\\sub\n")
        assert.equals(super, norm(finder.find(super .. "/sub")))
    end)

    it("handles CRLF and no trailing newline in the .git file", function()
        local _, super = superproject({ sub_git = "gitdir: ../.git/modules/sub\r\n" })
        assert.equals(super, norm(finder.find(super .. "/sub")))
        write(super .. "/sub/.git", "gitdir: ../.git/modules/sub")
        assert.equals(super, norm(finder.find(super .. "/sub")))
    end)

    it("classifies a submodule gitdir that does not exist on disk by its shape", function()
        local _, super = superproject()
        write(super .. "/other/.git", "gitdir: ../.git/modules/other\n") -- no such dir
        assert.equals(super, norm(finder.find(super .. "/other")))
    end)

    it("stops at a submodule-shaped path when its target is a worktree admin dir (commondir)", function()
        -- A submodule literally at tools/worktrees/x has the same gitdir SHAPE as
        -- a worktree admin dir; the commondir file is what tells them apart.
        local _, super = superproject()
        mkdir(super .. "/.git/modules/tools/worktrees/x")
        write(super .. "/tools/worktrees/x/.git", "gitdir: ../../../.git/modules/tools/worktrees/x\n")
        assert.equals(super, norm(finder.find(super .. "/tools/worktrees/x")))
        -- ...and the same shape WITH commondir is a linked worktree of `tools`: boundary.
        write(super .. "/.git/modules/tools/worktrees/x/commondir", "../..\n")
        assert.is_nil(finder.find(super .. "/tools/worktrees/x"))
    end)

    it("stops at a linked worktree of the superproject (existing behaviour)", function()
        local root, super = superproject()
        mkdir(super .. "/.git/worktrees/wt")
        write(super .. "/.git/worktrees/wt/commondir", "../..\n")
        write(root .. "/wt/.git", "gitdir: " .. super .. "/.git/worktrees/wt\n")
        -- A linked worktree nested under the main checkout must not bind to it.
        write(super .. "/nested-wt/.git", "gitdir: ../.git/worktrees/wt\n")
        assert.is_nil(finder.find(root .. "/wt"))
        assert.is_nil(finder.find(super .. "/nested-wt"))
    end)

    it("stops at a worktree-shaped gitdir even when the admin dir is missing", function()
        local _, super = superproject()
        write(super .. "/nested-wt/.git", "gitdir: ../.git/worktrees/gone\n")
        assert.is_nil(finder.find(super .. "/nested-wt"))
    end)

    it("stops at a linked worktree of a submodule", function()
        local _, super = superproject()
        mkdir(super .. "/.git/modules/sub/worktrees/feat")
        write(super .. "/.git/modules/sub/worktrees/feat/commondir", "../..\n")
        write(super .. "/sub-feat/.git", "gitdir: ../.git/modules/sub/worktrees/feat\n")
        assert.is_nil(finder.find(super .. "/sub-feat"))
    end)

    it("a submodule inside a linked worktree walks to the worktree root, not the main checkout", function()
        local root, super = superproject()
        mkdir(super .. "/.git/worktrees/wt/modules/sub")
        write(super .. "/.git/worktrees/wt/commondir", "../..\n")
        local wt = root .. "/wt"
        write(wt .. "/.git", "gitdir: " .. super .. "/.git/worktrees/wt\n")
        write(wt .. "/sub/.git", "gitdir: ../../super/.git/worktrees/wt/modules/sub\n")
        -- Worktree not initialised yet: the search stops at its root.
        assert.is_nil(finder.find(wt .. "/sub"))
        -- Once the worktree has its own working copy, the submodule resolves to it.
        write(wt .. "/.nvim/loomworks.user.json", "{}")
        local r, info = finder.find(wt .. "/sub")
        assert.equals(wt, norm(r))
        assert.equals(wt .. "/sub", norm(info.submodule))
    end)

    it("stops at a submodule whose superproject has no workspace", function()
        local root = tmpdir()
        mkdir(root .. "/super/.git/modules/sub")
        write(root .. "/super/sub/.git", "gitdir: ../.git/modules/sub\n")
        -- A workspace ABOVE the superproject's repo root is not found.
        write(root .. "/loomworks.json", "{}")
        assert.is_nil(finder.find(root .. "/super/sub"))
    end)

    it("stops at a plain repository root (.git directory)", function()
        local root = tmpdir()
        write(root .. "/loomworks.json", "{}")
        mkdir(root .. "/repo/.git")
        assert.is_nil(finder.find(root .. "/repo"))
    end)

    it("treats an unreadable/garbled .git file as a boundary", function()
        local _, super = superproject({ sub_git = "not a gitdir line\n" })
        assert.is_nil(finder.find(super .. "/sub"))
        write(super .. "/sub/.git", "")
        assert.is_nil(finder.find(super .. "/sub"))
    end)

    it("treats a separated-git-dir repo root as a boundary", function()
        local root, super = superproject()
        mkdir(root .. "/elsewhere/repo.git")
        write(super .. "/sep/.git", "gitdir: " .. root .. "/elsewhere/repo.git\n")
        assert.is_nil(finder.find(super .. "/sep"))
    end)

    it("returns nil outside any workspace", function()
        local root = tmpdir()
        mkdir(root .. "/x/y")
        assert.is_nil(finder.find(root .. "/x/y"))
    end)
end)

describe("root_finder.classify_git_file", function()
    it("classifies by the gitdir target", function()
        local _, super = superproject()
        assert.equals("submodule", finder.classify_git_file(super .. "/sub/.git"))
        write(super .. "/w/.git", "gitdir: ../.git/worktrees/w\n")
        assert.equals("worktree", finder.classify_git_file(super .. "/w/.git"))
        assert.equals("boundary", finder.classify_git_file(super .. "/missing/.git"))
    end)
end)

describe("editor auto-load from a submodule cwd (§13)", function()
    local auto_load = require("loomworks.auto_load")
    local saved_lw, saved_cwd

    before_each(function()
        saved_lw = package.loaded["loomworks"]
        saved_cwd = uv.cwd()
    end)
    after_each(function()
        package.loaded["loomworks"] = saved_lw
        vim.cmd("noautocmd cd " .. vim.fn.fnameescape(saved_cwd))
    end)

    local function fake_lw(loaded_root)
        local calls = {}
        package.loaded["loomworks"] = {
            _auto_load_mode = function() return "auto" end,
            get_workspace = function() return loaded_root and { root = loaded_root } or nil end,
            setup = function(opts) calls[#calls + 1] = opts end,
        }
        return calls
    end

    it("loads the superproject workspace when started inside a submodule", function()
        local _, super = superproject()
        local calls = fake_lw(nil)
        vim.cmd("noautocmd cd " .. vim.fn.fnameescape(super .. "/sub/src"))
        auto_load.check_cwd()
        assert.equals(1, #calls)
        assert.equals(vim.fs.normalize(super), vim.fs.normalize(calls[1].root))
    end)

    it("is a no-op when the superproject workspace is already loaded", function()
        local _, super = superproject()
        local calls = fake_lw(vim.fs.normalize(super))
        vim.cmd("noautocmd cd " .. vim.fn.fnameescape(super .. "/sub"))
        auto_load.check_cwd()
        assert.equals(0, #calls)
    end)

    it("does not bind a linked worktree to the main checkout's workspace", function()
        local root, super = superproject()
        mkdir(super .. "/.git/worktrees/wt")
        write(super .. "/.git/worktrees/wt/commondir", "../..\n")
        write(root .. "/wt/.git", "gitdir: " .. super .. "/.git/worktrees/wt\n")
        local calls = fake_lw(nil)
        vim.cmd("noautocmd cd " .. vim.fn.fnameescape(root .. "/wt"))
        auto_load.check_cwd()
        assert.equals(0, #calls)
    end)
end)

describe("lw from inside a submodule (§1.1, §16 status)", function()
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local cli = require("loomworks.cli")

    local function capture(fn)
        local buf = {}
        local rw = io.write
        io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
        local ok, err = pcall(fn)
        io.write = rw
        if not ok then error(err, 0) end
        return table.concat(buf)
    end

    local function ts_superproject()
        local _, super = superproject()
        write(super .. "/loomworks.json", vim.json.encode({ projects = { App = {
            typescript = vim.empty_dict(),
        } } }))
        mkdir(super .. "/App")
        return super
    end

    it("resolves the superproject root instead of 'run lw init'", function()
        local super = ts_superproject()
        local r, info = cli._find_root(super .. "/sub/src")
        assert.equals(super, norm(r))
        assert.equals(super .. "/sub", norm(info.submodule))
    end)

    it("`lw status` names the superproject and the submodule it came from", function()
        local super = ts_superproject()
        local out = capture(function()
            cli.cmd_status(super, { submodule = super .. "/sub" })
        end)
        assert.is_truthy(out:find("superproject", 1, true), out)
        assert.is_truthy(out:find("submodule sub", 1, true), out)
        -- Without the submodule hop there is no note.
        local plain = capture(function() cli.cmd_status(super, {}) end)
        assert.is_nil(plain:find("superproject", 1, true))
    end)
end)
