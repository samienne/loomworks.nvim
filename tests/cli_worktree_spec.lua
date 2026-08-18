-- `lw worktree` — list every git worktree of the current repo, its branch, the
-- main / current markers, and whether loomworks is initialised in each. The
-- parsing + row matrix is driven with a stubbed git runner + injected stat; a
-- real temp repo + linked worktrees covers the end-to-end path (guard-skipped
-- when git is absent). Unlike the status hint this command is git-required: it
-- errors (non-zero) when git is missing or the cwd is not a git repo.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- A git runner matching git_query's (cwd, args) -> stdout|nil contract.
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

--- A stat that reports a workspace present at each root in `present`.
local function stat_for(present)
    return function(path)
        for root in pairs(present) do
            if path == root .. "/loomworks.json"
                or path == root .. "/.nvim/loomworks.user.json" then
                return { type = "file" }
            end
        end
        return nil
    end
end

local function never_stat(_) return nil end

--- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
--- observable (exit_code set, no process kill) instead of terminating busted.
local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return {
        ok = ok,
        ret = ret,
        exit_code = exit_code,
        stdout = table.concat(out_buf),
        stderr = table.concat(err_buf),
    }
end

local function lines_of(s)
    local t = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = line end
    return t
end

--- The first captured line containing `sub` (plain).
local function line_with(s, sub)
    for _, line in ipairs(lines_of(s)) do
        if line:find(sub, 1, true) then return line end
    end
    return nil
end

local function has_escape(s) return s:find("\27[", 1, true) ~= nil end
local function strip_ansi(s) return (s:gsub("\27%[%d+m", "")) end

-- A representative three-worktree porcelain listing (main + two linked).
local MULTI = table.concat({
    "worktree /repo/main",
    "HEAD aaaaaaa1111111111111111111111111111111",
    "branch refs/heads/master",
    "",
    "worktree /repo/wt-feat",
    "HEAD bbbbbbb2222222222222222222222222222222",
    "branch refs/heads/feat",
    "",
    "worktree /repo/wt-wip",
    "HEAD ccccccc3333333333333333333333333333333",
    "branch refs/heads/wip",
}, "\n")

-- ---------------------------------------------------------------------------
-- _worktree_list — porcelain parsing (main first, branch/detached/bare)
-- ---------------------------------------------------------------------------

describe("cli._worktree_list (porcelain parsing)", function()
    it("parses every worktree in order with branch / detached / bare", function()
        local list = table.concat({
            "worktree /repo/main",
            "HEAD aaaaaaa1000000000000000000000000000000",
            "branch refs/heads/master",
            "",
            "worktree /repo/wt-det",
            "HEAD bbbbbbb2000000000000000000000000000000",
            "detached",
            "",
            "worktree /repo/bare",
            "bare",
        }, "\n")
        local records, top, reason = cli._worktree_list({
            dir = "/repo/main",
            git = fake_git({ version = true, toplevel = "/repo/main", list = list }),
        })
        assert.is_nil(reason)
        assert.equals("/repo/main", top)
        assert.equals(3, #records)
        -- Main is first; branch is short (refs/heads/ stripped).
        assert.equals("/repo/main", records[1].path)
        assert.equals("master", records[1].branch)
        -- Detached: flagged, HEAD retained, no branch.
        assert.equals("/repo/wt-det", records[2].path)
        assert.is_true(records[2].detached)
        assert.is_nil(records[2].branch)
        assert.is_truthy(records[2].head)
        -- Bare entry.
        assert.equals("/repo/bare", records[3].path)
        assert.is_true(records[3].bare)
    end)

    it("reports git-missing / not-git without listing", function()
        local _, _, r1 = cli._worktree_list({ dir = "/x", git = fake_git({ version = false }) })
        assert.equals("git-missing", r1)
        local _, _, r2 = cli._worktree_list({
            dir = "/x", git = fake_git({ version = true, toplevel = nil }),
        })
        assert.equals("not-git", r2)
    end)

    it("_main_worktree still returns the first entry (regression)", function()
        local main, top = cli._main_worktree({
            dir = "/repo/wt-feat",
            git = fake_git({ version = true, toplevel = "/repo/wt-feat", list = MULTI }),
        })
        assert.equals("/repo/main", main)
        assert.equals("/repo/wt-feat", top)
    end)
end)

-- ---------------------------------------------------------------------------
-- cmd_worktree — the rendered listing (stubbed git + injected stat)
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree (rendered listing)", function()
    it("lists all worktrees with branch, main / current markers, inited status", function()
        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/repo/wt-feat", -- current = feat
                git = fake_git({ version = true, toplevel = "/repo/wt-feat", list = MULTI }),
                stat = stat_for({ ["/repo/main"] = true, ["/repo/wt-feat"] = true }),
                color = false,
            })
        end)
        assert.is_true(res.ok)
        assert.equals(0, res.ret)
        local text = res.stdout

        -- Header + all three paths present.
        assert.is_truthy(text:find("3 worktrees", 1, true))
        assert.is_truthy(text:find("/repo/main", 1, true))
        assert.is_truthy(text:find("/repo/wt-feat", 1, true))
        assert.is_truthy(text:find("/repo/wt-wip", 1, true))

        -- Branch labels shown per worktree.
        assert.is_truthy(text:find("[master]", 1, true))
        assert.is_truthy(text:find("[feat]", 1, true))
        assert.is_truthy(text:find("[wip]", 1, true))

        -- The main worktree row carries the `main` marker; the linked ones don't.
        local main_line = line_with(text, "/repo/main")
        assert.is_truthy(main_line:find("main", 1, true))
        assert.is_truthy(main_line:find("[master]", 1, true))
        local feat_line = line_with(text, "/repo/wt-feat")
        assert.is_nil(feat_line:find("main", 1, true))

        -- Current marker `*` sits only on the worktree we're in (feat).
        assert.is_truthy(feat_line:find("*", 1, true))
        assert.is_nil(main_line:find("*", 1, true))

        -- Inited status reflects the presence predicate: main + feat have a
        -- workspace, wip does not.
        assert.is_nil(main_line:find("no workspace", 1, true))
        assert.is_truthy(main_line:find("workspace", 1, true))
        assert.is_truthy(line_with(text, "/repo/wt-wip"):find("no workspace", 1, true))
    end)

    it("reflects the working copy alone as `workspace` (no published snapshot)", function()
        -- Only .nvim/loomworks.user.json present at feat — still counts as inited.
        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/repo/main",
                git = fake_git({ version = true, toplevel = "/repo/main", list = MULTI }),
                stat = function(path)
                    if path == "/repo/wt-feat/.nvim/loomworks.user.json" then
                        return { type = "file" }
                    end
                    return nil
                end,
                color = false,
            })
        end)
        assert.is_true(res.ok)
        assert.is_truthy(line_with(res.stdout, "/repo/wt-feat"):find("workspace", 1, true))
        assert.is_nil(line_with(res.stdout, "/repo/wt-feat"):find("no workspace", 1, true))
        -- main has neither file -> not inited.
        assert.is_truthy(line_with(res.stdout, "/repo/main"):find("no workspace", 1, true))
    end)

    it("labels a detached HEAD and a bare entry", function()
        local list = table.concat({
            "worktree /repo/main",
            "bare",
            "",
            "worktree /repo/wt-det",
            "HEAD deadbee1111111111111111111111111111111",
            "detached",
        }, "\n")
        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/repo/wt-det",
                git = fake_git({ version = true, toplevel = "/repo/wt-det", list = list }),
                stat = never_stat,
                color = false,
            })
        end)
        assert.is_true(res.ok)
        assert.is_truthy(res.stdout:find("(bare)", 1, true))
        assert.is_truthy(res.stdout:find("[detached deadbee]", 1, true))
    end)

    it("`lw worktree list` renders identically to bare `lw worktree`", function()
        local opts = {
            dir = "/repo/main",
            git = fake_git({ version = true, toplevel = "/repo/main", list = MULTI }),
            stat = stat_for({ ["/repo/main"] = true }),
            color = false,
        }
        local bare = capture(function() return cli.cmd_worktree({ "worktree" }, opts) end)
        local list = capture(function() return cli.cmd_worktree({ "worktree", "list" }, opts) end)
        assert.is_true(bare.ok and list.ok)
        assert.equals(bare.stdout, list.stdout)
    end)
end)

-- ---------------------------------------------------------------------------
-- Errors: unknown subcommand, git missing, not a repo (all non-zero, no list)
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree (errors, git-required)", function()
    it("an unknown subcommand is a usage error, not a listing", function()
        local res = capture(function()
            return cli.cmd_worktree({ "worktree", "bogus" }, {
                dir = "/repo/main",
                git = fake_git({ version = true, toplevel = "/repo/main", list = MULTI }),
                stat = never_stat,
                color = false,
            })
        end)
        assert.is_false(res.ok)             -- die() raised
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("unknown worktree subcommand", 1, true))
        assert.is_nil(res.stdout:find("/repo/main", 1, true)) -- did not list
    end)

    it("errors with a non-zero exit when git is unavailable", function()
        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/x",
                git = fake_git({ version = false }),
                color = false,
            })
        end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("git is not available", 1, true))
    end)

    it("errors with a non-zero exit when the cwd is not a git repo", function()
        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/plain",
                git = fake_git({ version = true, toplevel = nil }),
                color = false,
            })
        end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("not in a git repository", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- Color gating: escape-free on the non-tty/captured path; aligned when colored
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree color gating", function()
    local function render(color)
        return capture(function()
            return cli.cmd_worktree({ "worktree" }, {
                dir = "/repo/wt-feat",
                git = fake_git({ version = true, toplevel = "/repo/wt-feat", list = MULTI }),
                stat = stat_for({ ["/repo/main"] = true, ["/repo/wt-feat"] = true }),
                color = color,
            })
        end)
    end

    it("emits no ANSI escape when color is off (the captured path)", function()
        assert.is_false(has_escape(render(false).stdout))
    end)

    it("colors only escape-safe fields and keeps columns aligned", function()
        local plain = render(false).stdout
        local colored = render(true).stdout
        -- Color forced on -> escapes present...
        assert.is_true(has_escape(colored))
        -- ...but stripping them yields byte-identical layout: padding was
        -- computed from plain widths, so color never shifts a column.
        assert.equals(plain, strip_ansi(colored))
    end)
end)

-- ---------------------------------------------------------------------------
-- End-to-end with real linked git worktrees.
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree (real git worktrees)", function()
    local git_ok = vim.fn.executable("git") == 1

    it("lists real worktrees and their inited status", function()
        if not git_ok then
            pending("git not available in this environment")
            return
        end
        local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwwtlsXXXXXX")
        base = base:gsub("\\", "/")
        local main = base .. "/main"
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
        -- Commit a README so `git worktree add` has a HEAD to check out. The
        -- workspace file stays UNTRACKED (like the real setup: loomworks.json /
        -- .nvim are the marker in the main checkout but git-ignored / uncommitted),
        -- so a fresh worktree does NOT inherit it.
        local rf = assert(io.open(main .. "/README.md", "wb"))
        rf:write("demo\n"); rf:close()
        git(main, "add", "README.md")
        git(main, "commit", "-q", "-m", "init")
        local f = assert(io.open(main .. "/loomworks.json", "wb"))
        f:write('{"name":"demo"}\n'); f:close()

        -- A linked worktree on its own branch, with NO workspace of its own.
        local wt = base .. "/wt"
        git(main, "worktree", "add", "-q", "-b", "feature-x", wt)
        wt = (uv.fs_realpath(wt) or wt):gsub("\\", "/")

        local res = capture(function()
            return cli.cmd_worktree({ "worktree" }, { dir = wt, color = false })
        end)

        vim.fn.delete(base, "rf")

        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)
        local text = res.stdout
        assert.is_false(has_escape(text))
        -- Both worktrees appear; the linked one is on feature-x. Key the row by
        -- branch, robust to path formatting differences across platforms.
        local wt_line = line_with(text, "feature-x")
        assert.is_truthy(wt_line, "feature-x worktree not listed:\n" .. text)
        assert.is_truthy(wt_line:find("[feature-x]", 1, true))
        -- The current marker sits on the worktree we ran in (wt == feature-x).
        assert.is_truthy(wt_line:find("*", 1, true))
        -- Inited status: main has a workspace file, the fresh worktree does not.
        assert.is_truthy(wt_line:find("no workspace", 1, true))
        -- The main worktree carries the `main` marker and is inited.
        local main_line = line_with(text, "[master]")
        assert.is_truthy(main_line, "main worktree not listed:\n" .. text)
        assert.is_truthy(main_line:find("main", 1, true))
        assert.is_nil(main_line:find("no workspace", 1, true))
    end)
end)
