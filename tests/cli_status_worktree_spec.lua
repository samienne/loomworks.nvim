-- `lw status` in a directory with no workspace: the no-workspace hint block.
-- It points the user at `lw init`, and — only when this is a linked git
-- worktree whose main checkout already has a workspace — at `lw pull`. The
-- detection is read-only, non-fatal, and time-bounded: a missing or hung git
-- must never break status. Branch matrix is exercised with a stubbed git
-- runner; a real temp repo + linked worktree covers the end-to-end path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

-- A fake git runner matching git_query's (cwd, args) -> stdout|nil contract.
local function fake_git(spec)
    return function(_, args)
        local a1 = args[1]
        -- spec.timeout names the probe that runs past its budget: the runner
        -- then answers like git_query does on a timeout, (nil, "timeout").
        if spec.timeout and (a1 == spec.timeout) then return nil, "timeout" end
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

-- Join a hint's lines so substring assertions can span the whole block.
local function joined(lines) return table.concat(lines, "\n") end

-- Any raw ANSI escape (color leak) in the captured/plain path.
local function has_escape(s) return s:find("\27[", 1, true) ~= nil end

describe("lw status worktree hint (_worktree_hint)", function()
    it("offers only `lw init` when git is missing, plus a note", function()
        local lines = cli._worktree_hint({
            dir = "/somewhere",
            git = fake_git({ version = false }),
            stat = never_stat,
        })
        local text = joined(lines)
        assert.is_truthy(text:find("no workspace here", 1, true))
        assert.is_truthy(text:find("lw init", 1, true))
        assert.is_truthy(text:find("git unavailable", 1, true))
        assert.is_nil(text:find("lw pull", 1, true))
    end)

    it("offers only `lw init` when the dir is not a git repo", function()
        local lines = cli._worktree_hint({
            dir = "/plain",
            git = fake_git({ version = true, toplevel = nil }),
            stat = never_stat,
        })
        local text = joined(lines)
        assert.is_truthy(text:find("lw init", 1, true))
        assert.is_nil(text:find("lw pull", 1, true))
        assert.is_nil(text:find("git worktree", 1, true))
        assert.is_nil(text:find("git unavailable", 1, true))
    end)

    it("offers only `lw init` in the main worktree (toplevel == main)", function()
        local lines = cli._worktree_hint({
            dir = "/repo/main",
            git = fake_git({
                version = true,
                toplevel = "/repo/main",
                list = "worktree /repo/main\nHEAD abc\nbranch refs/heads/master\n",
            }),
            stat = always_stat,
        })
        local text = joined(lines)
        assert.is_truthy(text:find("lw init", 1, true))
        assert.is_nil(text:find("lw pull", 1, true))
        assert.is_nil(text:find("git worktree", 1, true))
    end)

    it("offers `lw pull` and `lw init` when the main checkout has a workspace", function()
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
        local text = joined(lines)
        assert.is_truthy(text:find("git worktree", 1, true))
        assert.is_truthy(text:find("/repo/main", 1, true))
        assert.is_truthy(text:find("lw pull", 1, true))
        assert.is_truthy(text:find("lw init", 1, true))
    end)

    it("offers ONLY `lw init` when the main checkout has no workspace either", function()
        local lines = cli._worktree_hint({
            dir = "/repo/wt",
            git = fake_git({
                version = true,
                toplevel = "/repo/wt",
                list = "worktree /repo/main\nHEAD abc\n\nworktree /repo/wt\nHEAD def\n",
            }),
            stat = never_stat,
        })
        local text = joined(lines)
        assert.is_truthy(text:find("git worktree", 1, true))
        assert.is_truthy(text:find("lw init", 1, true))
        assert.is_nil(text:find("lw pull", 1, true))
    end)

    it("offers only `lw init` when `git worktree list` fails", function()
        local lines = cli._worktree_hint({
            dir = "/repo/wt",
            git = fake_git({ version = true, toplevel = "/repo/wt", list = nil }),
            stat = always_stat,
        })
        local text = joined(lines)
        assert.is_truthy(text:find("lw init", 1, true))
        assert.is_nil(text:find("lw pull", 1, true))
    end)
end)

-- A slow git is not an absent git: a probe that ran past the hint's 1.5 s budget
-- must say so (and point at the full check) instead of "git unavailable", and
-- must never pass silently for "not a linked worktree".
describe("lw status worktree hint when the git probe times out", function()
    for _, probe in ipairs({ "--version", "rev-parse", "worktree" }) do
        it("says git timed out (not unavailable) when `" .. probe .. "` times out", function()
            local lines = cli._worktree_hint({
                dir = "/repo/wt",
                git = fake_git({
                    version = true,
                    toplevel = "/repo/wt",
                    list = "worktree /repo/main\n\nworktree /repo/wt\n",
                    timeout = probe,
                }),
                stat = always_stat,
            })
            local text = joined(lines)
            assert.is_truthy(text:find("lw init", 1, true), text)
            assert.is_nil(text:find("git unavailable", 1, true), text)
            assert.is_truthy(text:find(
                "(git timed out after 1.5 s — couldn't check for a parent worktree; " ..
                "`lw worktree` waits longer)", 1, true), text)
        end)
    end

    it("_worktree_list reports git-timeout, distinct from git-missing", function()
        local _, _, r = cli._worktree_list({
            dir = "/x", git = fake_git({ version = true, toplevel = "/x", timeout = "--version" }),
        })
        assert.equals("git-timeout", r)
        local _, _, r2 = cli._worktree_list({
            dir = "/x", git = fake_git({ version = true, timeout = "rev-parse" }),
        })
        assert.equals("git-timeout", r2)
        local _, _, r3 = cli._worktree_list({ dir = "/x", git = fake_git({ version = false }) })
        assert.equals("git-missing", r3)
    end)

    it("the real bounded probe reports a git that never answers as timed out", function()
        local exe = require("loomworks.exe")
        local real = exe.system
        -- A git that spawns but never completes within the 1.5 s budget.
        exe.system = function()
            return { pid = nil, kill = function() end, wait = function() end }
        end
        local ok, lines = pcall(cli._worktree_hint, { dir = "/x", stat = never_stat })
        exe.system = real
        assert.is_true(ok, tostring(lines))
        local text = joined(lines)
        assert.is_truthy(text:find("git timed out after 1.5 s", 1, true), text)
        assert.is_nil(text:find("git unavailable", 1, true), text)
    end)
end)

describe("lw status hint color gating", function()
    -- Force stdout to look like a non-tty for the duration of `fn`, on every
    -- platform, so the default color decision is deterministic regardless of
    -- how the test host is launched (piped, redirected, or a real terminal).
    local function with_non_tty(fn)
        local real = uv.guess_handle
        uv.guess_handle = function(fd) return fd == 1 and "file" or real(fd) end
        local ok, err = pcall(fn)
        uv.guess_handle = real
        assert(ok, err)
    end

    it("emits no ANSI escape on the default (non-tty) path, every branch", function()
        with_non_tty(function()
            local branches = {
                { git = fake_git({ version = false }), stat = never_stat },
                { git = fake_git({ version = true, toplevel = nil }), stat = never_stat },
                {
                    git = fake_git({
                        version = true,
                        toplevel = "/repo/wt",
                        list = "worktree /repo/main\n\nworktree /repo/wt\n",
                    }),
                    stat = always_stat,
                },
            }
            for _, b in ipairs(branches) do
                b.dir = "/repo/wt"
                -- No opts.color: exercises the real stdout_supports_color gate.
                assert.is_false(has_escape(joined(cli._worktree_hint(b))))
            end
        end)
    end)

    it("stdout_supports_color() is false on a non-tty, all platforms", function()
        -- The tty gate short-circuits before the Windows FFI path, so on Linux
        -- CI this both stays plain AND never reaches kernel32.
        with_non_tty(function()
            assert.is_false(cli._stdout_supports_color())
        end)
    end)

    it("respects NO_COLOR even when stdout is a tty", function()
        local real = uv.guess_handle
        uv.guess_handle = function(fd) return fd == 1 and "tty" or real(fd) end
        local saved = vim.env.NO_COLOR
        vim.env.NO_COLOR = "1"
        local ok, res = pcall(cli._stdout_supports_color)
        vim.env.NO_COLOR = saved
        uv.guess_handle = real
        assert.is_true(ok)
        assert.is_false(res)
    end)

    it("wraps command tokens in color codes only when color is forced on", function()
        local opts = {
            dir = "/repo/wt",
            color = true,
            git = fake_git({
                version = true,
                toplevel = "/repo/wt",
                list = "worktree /repo/main\n\nworktree /repo/wt\n",
            }),
            stat = always_stat,
        }
        -- Painters emit loomworks.term markers; the CLI's writer renders them.
        local text = require("loomworks.term").render(joined(cli._worktree_hint(opts)))
        assert.is_truthy(has_escape(text))
        assert.is_truthy(text:find("\27[36mlw pull\27[0m", 1, true))
        assert.is_truthy(text:find("\27[36mlw init\27[0m", 1, true))

        opts.color = false
        assert.is_false(has_escape(joined(cli._worktree_hint(opts))))
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
        -- A failed --version probe surfaces the git-unavailable note, no crash.
        assert.is_truthy(text:find("git unavailable", 1, true))
        -- Captured output is plain text, never raw escapes.
        assert.is_false(text:find("\27[", 1, true) ~= nil)
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

        -- Real git, but with the git-required probe budget (30 s) instead of
        -- the hint's 1.5 s: on a loaded runner a timed-out probe would drop the
        -- worktree lines asserted below. Still bounded, never a hang.
        local lines = cli._worktree_hint({ dir = wt, git = cli._git_query_required })
        vim.fn.delete(base, "rf")

        local text = joined(lines)
        assert.is_truthy(text:find("git worktree", 1, true))
        assert.is_truthy(text:find("lw pull", 1, true))
        assert.is_truthy(text:find("lw init", 1, true))
    end)
end)

-- The `lw status` overview palette: colors the workspace overview on a real
-- terminal and stays byte-for-byte plain on a pipe/redirect. paint_help splits
-- a "<prose> · <lw command>" help line into dim prose + cyan command.
describe("lw status overview palette", function()
    it("is the identity on every field when color is off (no escapes)", function()
        local pal = cli._status_palette(false)
        for _, k in ipairs({ "title", "dim", "active", "cmd" }) do
            assert.equals("x", pal[k]("x"))
        end
        -- inline delimits with backticks (not color) so a pipe keeps the cue.
        assert.equals("`lw run`", pal.inline("lw run"))
        assert.is_false(has_escape(pal.title("x") .. pal.dim("y") .. pal.inline("z")))
    end)

    it("wraps fields in their ANSI codes when color is on", function()
        -- The palette emits loomworks.term markers; render() (what the CLI's
        -- writers apply) turns them into the ANSI codes.
        local R = require("loomworks.term").render
        local pal = cli._status_palette(true)
        assert.equals("\27[1mHi\27[0m", R(pal.title("Hi")))
        assert.equals("\27[2mHi\27[0m", R(pal.dim("Hi")))
        assert.equals("\27[32mHi\27[0m", R(pal.active("Hi")))
        assert.equals("\27[36mHi\27[0m", R(pal.cmd("Hi")))
        -- inline is dim on a terminal (secondary guidance) — no backticks, the
        -- color carries the "this is a hint" cue instead.
        assert.equals("\27[2mlw run\27[0m", R(pal.inline("lw run")))
    end)

    it("paint_help dims the whole help line (prose + command), color on", function()
        local pal = cli._status_palette(true)
        local out = require("loomworks.term").render(
            cli._paint_help(pal, "create a profile · lw profile create <set> <tool>"))
        assert.equals("\27[2mcreate a profile · lw profile create <set> <tool>\27[0m", out)
    end)

    it("paint_help dims a bare command hint (no ' · ') whole", function()
        local pal = cli._status_palette(true)
        assert.equals("\27[2mlw profiles\27[0m",
            require("loomworks.term").render(cli._paint_help(pal, "lw profiles")))
    end)

    it("paint_help is plain text when color is off", function()
        local pal = cli._status_palette(false)
        assert.equals("create a profile · lw profile create <set> <tool>",
            cli._paint_help(pal, "create a profile · lw profile create <set> <tool>"))
    end)

    -- Capture what status_section writes via io.write (how the CLI's out() emits).
    local function capture(fn)
        local real = io.write
        local buf = {}
        io.write = function(s) buf[#buf + 1] = s end
        local ok, err = pcall(fn)
        io.write = real
        assert(ok, err)
        return table.concat(buf)
    end

    it("status_section renders rows and separates the help line by a blank line", function()
        local pal = cli._status_palette(false)
        local text = capture(function()
            cli._status_section(pal, "Profiles", { "a", "b" }, 6,
                function(x) return "  " .. x end, "lw profiles",
                "create a profile · lw profile create <set> <tool>")
        end)
        -- The bug this guards: status_section calling paint_help — a local
        -- declared LATER in cli.lua — must resolve, not blow up as a nil global.
        assert.is_truthy(text:find("Profiles (2)", 1, true))
        assert.is_truthy(text:find("  a\n  b\n", 1, true))
        -- Rows, then a blank line, then the help line.
        assert.is_truthy(text:find("  b\n\n  create a profile", 1, true))
    end)

    it("status_section colors title/count/help when color is on", function()
        local pal = cli._status_palette(true)
        local text = capture(function()
            cli._status_section(pal, "Projects", { "x" }, 6,
                function(v) return "  " .. v end, "lw project list",
                "add a project · lw project add <path> [type]")
        end)
        assert.is_truthy(text:find("\27[1mProjects\27[0m \27[2m(1)\27[0m", 1, true))
        -- Help line is dimmed whole, not cyan-highlighted.
        assert.is_truthy(text:find("\27[2madd a project · lw project add <path> [type]\27[0m", 1, true))
    end)

    it("status_section on an empty list shows only the help hint, no blank pad", function()
        local pal = cli._status_palette(false)
        local text = capture(function()
            cli._status_section(pal, "Projects", {}, 6, function(v) return v end,
                "lw project list", "add a project · lw project add <path> [type]")
        end)
        assert.is_truthy(text:find("Projects (0)\n  add a project", 1, true))
    end)

    it("status_section renders each help line when given a list", function()
        local pal = cli._status_palette(false)
        local text = capture(function()
            cli._status_section(pal, "Profiles", { "a", "b" }, 6,
                function(x) return "  " .. x end, "lw profiles",
                { "switch the profile · lw profile select",
                  "create a profile · lw profile create <set> <tool>" })
        end)
        -- Both hints, in order, after the blank separator.
        assert.is_truthy(text:find(
            "\n\n  switch the profile · lw profile select\n" ..
            "  create a profile · lw profile create <set> <tool>\n", 1, true))
    end)
end)

-- `lw status` overview, worktrees section (§16.18): the repository's worktrees
-- with the same rows `lw worktree` prints, capped like the other sections, and
-- omitted when there are no linked worktrees or git cannot answer.
describe("lw status overview worktrees section", function()
    local function capture_status(fn)
        local buf = {}
        local rw = io.write
        io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
        local ok, err = pcall(fn)
        io.write = rw
        if not ok then error(err, 0) end
        return table.concat(buf)
    end

    local root
    before_each(function()
        root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root .. "/App", "p")
        local t = assert(io.open(root .. "/App/tsconfig.json", "w")); t:write("{}"); t:close()
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    -- Porcelain listing: main = root, then `n` linked worktrees on branches.
    local function listing(n)
        local parts = { "worktree " .. root .. "\nHEAD aaaaaaaaaa\nbranch refs/heads/master\n" }
        for i = 1, n do
            parts[#parts + 1] = "worktree /wt/l" .. i .. "\nHEAD bbbbbbbbbb\nbranch refs/heads/feat/" .. i .. "\n"
        end
        return table.concat(parts, "\n")
    end

    local function status(git, stat)
        return capture_status(function()
            cli.cmd_status(root, { can_pull = false, worktree_git = git, worktree_stat = stat })
        end)
    end

    -- Only the main worktree and /wt/l1 carry a workspace.
    local function stat_some(p)
        if p == root .. "/loomworks.json" or p == "/wt/l1/.nvim/loomworks.user.json" then
            return { type = "file" }
        end
        return nil
    end

    it("lists linked worktrees after Projects with markers, branch and init state", function()
        local list = listing(2) .. "\nworktree /wt/det\nHEAD 1234567890abc\ndetached\n"
        local out = status(fake_git({ version = true, toplevel = root, list = list }), stat_some)
        local sec = out:find("\nWorktrees (4)\n", 1, true)
        assert.is_truthy(sec, out)
        assert.is_true(out:find("\nProjects (", 1, true) < sec)
        assert.is_true(sec < out:find("Common: ", 1, true))
        -- Rows are exactly `lw worktree`'s rows.
        local records = { { path = root, branch = "master" },
            { path = "/wt/l1", branch = "feat/1" }, { path = "/wt/l2", branch = "feat/2" },
            { path = "/wt/det", detached = true, head = "1234567890abc" } }
        local rows = cli._worktree_rows(records, root, stat_some)
        local plain = function(s) return s end
        for _, row in ipairs(rows) do
            assert.is_truthy(out:find(cli._worktree_row(row, plain) .. "\n", 1, true), out)
        end
        local main_line = cli._worktree_row(rows[1], plain)
        assert.is_truthy(main_line:find("^  %* "), main_line)
        assert.is_truthy(main_line:find("main", 1, true))
        assert.is_truthy(main_line:find("[master]", 1, true))
        assert.is_truthy(main_line:find("workspace$"))
        assert.is_truthy(cli._worktree_row(rows[2], plain):find("  workspace$"))
        assert.is_truthy(cli._worktree_row(rows[3], plain):find("no workspace$"))
        assert.is_truthy(cli._worktree_row(rows[4], plain):find("[detached 1234567]", 1, true))
        assert.is_nil(out:find("lw worktree add", 1, true), out)
        assert.is_false(has_escape(out))
    end)

    it("is omitted when only the main worktree exists", function()
        local out = status(fake_git({ version = true, toplevel = root, list = listing(0) }), always_stat)
        assert.is_nil(out:find("Worktrees (", 1, true), out)
        assert.is_truthy(out:find("Common: ", 1, true))
    end)

    it("is omitted when git is missing", function()
        local out = status(fake_git({ version = false }), always_stat)
        assert.is_nil(out:find("Worktrees (", 1, true), out)
        assert.is_truthy(out:find("Common: ", 1, true))
    end)

    it("is omitted when a git probe times out", function()
        for _, probe in ipairs({ "--version", "rev-parse", "worktree" }) do
            local out = status(fake_git({ version = true, toplevel = root, list = listing(2), timeout = probe }),
                always_stat)
            assert.is_nil(out:find("Worktrees (", 1, true), probe .. "\n" .. out)
            assert.is_truthy(out:find("Common: ", 1, true))
        end
    end)

    it("is omitted outside a git repository", function()
        local out = status(fake_git({ version = true, toplevel = nil }), always_stat)
        assert.is_nil(out:find("Worktrees (", 1, true), out)
    end)

    it("caps at six rows with a +K more pointer to `lw worktree`", function()
        local out = status(fake_git({ version = true, toplevel = root, list = listing(8) }), never_stat)
        assert.is_truthy(out:find("\nWorktrees (9)\n", 1, true), out)
        assert.is_truthy(out:find("  +3 more · lw worktree\n", 1, true), out)
        assert.is_truthy(out:find("/wt/l5 ", 1, true))
        assert.is_nil(out:find("/wt/l6 ", 1, true))
    end)
end)
