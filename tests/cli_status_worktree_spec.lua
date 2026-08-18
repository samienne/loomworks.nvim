-- `lw status` in a directory with no workspace: the linked-git-worktree hint.
-- The detection is read-only, non-fatal, and time-bounded — a missing or hung
-- git must never break status. Branch matrix is exercised with a stubbed git
-- runner; a real temp repo + linked worktree covers the end-to-end path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

-- A fake git runner matching git_query's (cwd, args) -> stdout|nil contract.
local function fake_git(spec)
    return function(_, args)
        local a1 = args[1]
        if a1 == "--version" then
            return spec.version and "git version 2.40.0" or nil
        elseif a1 == "rev-parse" then
            return spec.toplevel
        elseif a1 == "worktree" then
            return spec.list
        end
        return nil
    end
end

local function always_stat(_) return { type = "file" } end
local function never_stat(_) return nil end

describe("lw status worktree hint (_worktree_hint)", function()
    it("notes a missing git binary once, nothing more", function()
        local lines = cli._worktree_hint({
            dir = "/somewhere",
            git = fake_git({ version = false }),
            stat = never_stat,
        })
        assert.equals(1, #lines)
        assert.is_truthy(lines[1]:find("git not available", 1, true))
    end)

    it("adds no note when the dir is not a git repo", function()
        local lines = cli._worktree_hint({
            dir = "/plain",
            git = fake_git({ version = true, toplevel = nil }),
            stat = never_stat,
        })
        assert.same({}, lines)
    end)

    it("adds no note in the main worktree (toplevel == main)", function()
        local lines = cli._worktree_hint({
            dir = "/repo/main",
            git = fake_git({
                version = true,
                toplevel = "/repo/main",
                list = "worktree /repo/main\nHEAD abc\nbranch refs/heads/master\n",
            }),
            stat = always_stat,
        })
        assert.same({}, lines)
    end)

    it("points at the main checkout when it has a workspace", function()
        local lines = cli._worktree_hint({
            dir = "/repo/wt",
            git = fake_git({
                version = true,
                toplevel = "/repo/wt",
                list = "worktree /repo/main\nHEAD abc\nbranch refs/heads/master\n\n"
                    .. "worktree /repo/wt\nHEAD def\nbranch refs/heads/feature\n",
            }),
            stat = always_stat,
        })
        assert.equals(2, #lines)
        assert.is_truthy(lines[1]:find("git worktree", 1, true))
        assert.is_truthy(lines[1]:find("/repo/main", 1, true))
        assert.is_truthy(lines[1]:find("has a loomworks workspace", 1, true))
        assert.is_truthy(lines[2]:find("isn't wired up", 1, true))
    end)

    it("says so when the main checkout has no workspace either", function()
        local lines = cli._worktree_hint({
            dir = "/repo/wt",
            git = fake_git({
                version = true,
                toplevel = "/repo/wt",
                list = "worktree /repo/main\nHEAD abc\n\nworktree /repo/wt\nHEAD def\n",
            }),
            stat = never_stat,
        })
        assert.equals(1, #lines)
        assert.is_truthy(lines[1]:find("no loomworks workspace either", 1, true))
    end)

    it("degrades to no note when `git worktree list` fails", function()
        local lines = cli._worktree_hint({
            dir = "/repo/wt",
            git = fake_git({ version = true, toplevel = "/repo/wt", list = nil }),
            stat = always_stat,
        })
        assert.same({}, lines)
    end)
end)

describe("lw status never breaks when git fails", function()
    local real_system, wrote

    before_each(function()
        real_system = vim.system
        wrote = {}
        local real_write = io.write
        _G.__real_write = real_write
        io.write = function(s) wrote[#wrote + 1] = s end
    end)

    after_each(function()
        vim.system = real_system
        io.write = _G.__real_write
        _G.__real_write = nil
    end)

    it("returns 0 and prints the base message when git spawning fails", function()
        -- Simulate a git that cannot run: on_exit fires with a non-zero code,
        -- exercising the real git_query timeout/error path end-to-end.
        vim.system = function(_, _, on_exit)
            if on_exit then on_exit({ code = 127, stdout = "", stderr = "" }) end
            return { wait = function() end }
        end
        local code = cli.cmd_status(nil)
        io.write = _G.__real_write -- restore before asserting (assert may print)
        assert.equals(0, code)
        local text = table.concat(wrote)
        assert.is_truthy(text:find("no workspace here", 1, true))
        -- A failed --version probe surfaces the git-not-available note, no crash.
        assert.is_truthy(text:find("git not available", 1, true))
    end)
end)

describe("lw status worktree hint (real git)", function()
    local git_ok = vim.fn.executable("git") == 1

    it("detects a linked worktree whose main checkout has a workspace", function()
        if not git_ok then
            pending("git not available in this environment")
            return
        end
        local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwwtXXXXXX")
        base = base:gsub("\\", "/")
        local main = base .. "/main"
        local wt = base .. "/wt"
        assert(uv.fs_mkdir(main, 448)) -- 0700

        local function git(cwd, ...)
            local cmd = { "git", "-C", cwd }
            for _, a in ipairs({ ... }) do cmd[#cmd + 1] = a end
            local r = vim.system(cmd, { text = true }):wait()
            assert(r.code == 0, "git failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
        end

        git(main, "init", "-q")
        git(main, "config", "user.email", "t@example.com")
        git(main, "config", "user.name", "t")
        -- A committed workspace file: git worktree add needs a HEAD, and this is
        -- the marker the hint looks for in the main checkout.
        local f = assert(io.open(main .. "/loomworks.json", "wb"))
        f:write('{"name":"demo"}\n'); f:close()
        git(main, "add", "loomworks.json")
        git(main, "commit", "-q", "-m", "init")
        git(main, "worktree", "add", "-q", wt)

        local lines = cli._worktree_hint({ dir = wt })
        vim.fn.delete(base, "rf")

        assert.equals(2, #lines)
        assert.is_truthy(lines[1]:find("has a loomworks workspace", 1, true))
        assert.is_truthy(lines[1]:find("git worktree", 1, true))
    end)
end)
