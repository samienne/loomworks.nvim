-- `lw worktree add <branch> [<start-point>] [--no-pull]` — create a git
-- worktree at <main>/.worktrees/<branch> (the full branch path mirrored) and,
-- unless --no-pull, auto-pull the MAIN checkout's working config into it
-- (§16.25/§16.27). The argument/error matrix is driven with a stubbed git
-- runner; the create + auto-pull behaviour is exercised end-to-end against real
-- temp git repos (guard-skipped when git is absent). Non-destructive: a
-- pre-existing target is refused and a pull failure keeps the worktree.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local user = require("loomworks.user")
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function tmpdir()
    local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwwtaddXXXXXX")
    return (base:gsub("\\", "/"))
end

--- A git runner matching git_query's (cwd, args) -> stdout|nil contract, used
--- only for the error unit tests (real cases use the actual git binary).
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

--- Run `fn` with io.write / io.stderr / os.exit captured so a die() path is
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

-- A representative, self-consistent source working copy (main's config).
local function sample_source()
    return {
        _meta = { version = 2 },
        active_profile = "Dev:ninja-gcc",
        projects = {
            app = { cmake = {}, path = "app" },
            lib = { cmake = {}, path = "lib" },
        },
        configuration_sets = {
            Dev = { app = "Debug", lib = "Debug" },
        },
        profiles = {
            ["Dev:ninja-gcc"] = { configuration_set = "Dev", tools = { "ninja-gcc" } },
        },
    }
end

local git_ok = vim.fn.executable("git") == 1

--- Run a git command in `cwd`, asserting success. Setup-only.
local function git(cwd, ...)
    local cmd = { "git", "-C", cwd }
    for _, a in ipairs({ ... }) do cmd[#cmd + 1] = a end
    local r = vim.system(cmd, { text = true }):wait()
    assert(r.code == 0, "git failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
end

--- Create a main checkout with a committed README and (optionally) a working
--- copy. Returns the forward-slashed main path.
local function make_main(base, with_config)
    local main = base .. "/main"
    assert(uv.fs_mkdir(main, 448)) -- 0700
    git(main, "init", "-q")
    git(main, "config", "user.email", "t@example.com")
    git(main, "config", "user.name", "t")
    local rf = assert(io.open(main .. "/README.md", "wb"))
    rf:write("demo\n"); rf:close()
    git(main, "add", "README.md")
    git(main, "commit", "-q", "-m", "init")
    if with_config ~= false then assert(user.save(main, sample_source())) end
    return main
end

-- ---------------------------------------------------------------------------
-- Argument / usage errors (stubbed git; die before touching the repo)
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree_add (usage errors)", function()
    it("missing <branch> is a usage error", function()
        local res = capture(function()
            return cli.cmd_worktree_add({ "worktree", "add" }, {
                dir = "/repo/main",
                git = fake_git({ version = true, toplevel = "/repo/main" }),
                color = false,
            })
        end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("missing <branch>", 1, true))
    end)

    it("an unknown option is a usage error", function()
        local res = capture(function()
            return cli.cmd_worktree_add({ "worktree", "add", "--bogus", "feat" }, {
                dir = "/repo/main",
                git = fake_git({ version = true, toplevel = "/repo/main" }),
                color = false,
            })
        end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("unknown option", 1, true))
    end)

    it("errors (non-zero) when git is unavailable", function()
        local res = capture(function()
            return cli.cmd_worktree_add({ "worktree", "add", "feat" }, {
                dir = "/x",
                git = fake_git({ version = false }),
                color = false,
            })
        end)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("git is not available", 1, true))
    end)

    it("errors (non-zero) when the cwd is not a git repo", function()
        local res = capture(function()
            return cli.cmd_worktree_add({ "worktree", "add", "feat" }, {
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
-- Real git worktrees: create + auto-pull, slashed names, existing branch, etc.
-- ---------------------------------------------------------------------------

describe("cli.cmd_worktree_add (real git worktrees)", function()
    local base
    before_each(function() base = tmpdir() end)
    after_each(function() vim.fn.delete(base, "rf") end)

    local function run(args, main)
        return capture(function()
            return cli.cmd_worktree_add(args, { dir = main, color = false })
        end)
    end

    it("creates <main>/.worktrees/feat on a new branch and auto-pulls main's config", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        local res = run({ "worktree", "add", "feat" }, main)
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)

        local path = main .. "/.worktrees/feat"
        assert.is_not_nil(uv.fs_stat(path), "worktree dir not created")
        -- New branch is exactly `feat`.
        local branch = vim.trim(vim.system(
            { "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait().stdout)
        assert.equals("feat", branch)
        -- Auto-pull ran: the new worktree has main's config.
        assert.is_not_nil(uv.fs_stat(user.filepath(path)), "user.json not written by auto-pull")
        local data = user.load(path)
        assert.is_not_nil(data.projects.app)
        assert.is_not_nil(data.configuration_sets.Dev)
        assert.is_not_nil(data.profiles["Dev:ninja-gcc"])
        -- Active profile is per-checkout: NOT pulled.
        assert.is_nil(data.active_profile)
        -- No escape codes on the captured (non-tty) path.
        assert.is_nil(res.stdout:find("\27[", 1, true))
    end)

    it("mirrors a slashed branch as nested dirs AND names the branch in full", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        local res = run({ "worktree", "add", "feature/x" }, main)
        assert.is_true(res.ok, res.stderr)

        local path = main .. "/.worktrees/feature/x"
        assert.is_not_nil(uv.fs_stat(path), "nested worktree dir not created")
        -- The load-bearing assertion: the branch is `feature/x`, NOT `x`.
        local branch = vim.trim(vim.system(
            { "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait().stdout)
        assert.equals("feature/x", branch)
        -- Auto-pull still ran.
        assert.is_not_nil(uv.fs_stat(user.filepath(path)))
    end)

    it("checks out an EXISTING branch at the path", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        git(main, "branch", "existing")
        local res = run({ "worktree", "add", "existing" }, main)
        assert.is_true(res.ok, res.stderr)
        assert.is_truthy(res.stdout:find("(existing)", 1, true))
        local path = main .. "/.worktrees/existing"
        local branch = vim.trim(vim.system(
            { "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait().stdout)
        assert.equals("existing", branch)
    end)

    it("respects an explicit <start-point> for a new branch", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        -- A second commit; tag the FIRST so start-point != HEAD.
        local first = vim.trim(vim.system(
            { "git", "-C", main, "rev-parse", "HEAD" }, { text = true }):wait().stdout)
        local rf = assert(io.open(main .. "/second.txt", "wb"))
        rf:write("second\n"); rf:close()
        git(main, "add", "second.txt")
        git(main, "commit", "-q", "-m", "second")

        local res = run({ "worktree", "add", "fromfirst", first }, main)
        assert.is_true(res.ok, res.stderr)
        local path = main .. "/.worktrees/fromfirst"
        local head = vim.trim(vim.system(
            { "git", "-C", path, "rev-parse", "HEAD" }, { text = true }):wait().stdout)
        assert.equals(first, head) -- created off the start-point, not HEAD
    end)

    it("--no-pull creates the worktree but writes NO working copy", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        local res = run({ "worktree", "add", "nopull", "--no-pull" }, main)
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)
        local path = main .. "/.worktrees/nopull"
        assert.is_not_nil(uv.fs_stat(path), "worktree dir not created")
        assert.is_nil(uv.fs_stat(user.filepath(path)), "--no-pull must not write user.json")
        assert.is_truthy(res.stdout:find("--no-pull", 1, true))
    end)

    it("a main with no working config is 'nothing to pull', not a failure", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base, false) -- no user.json in main
        local res = run({ "worktree", "add", "cfgless" }, main)
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret) -- success: the worktree exists
        local path = main .. "/.worktrees/cfgless"
        assert.is_not_nil(uv.fs_stat(path))
        assert.is_nil(uv.fs_stat(user.filepath(path))) -- nothing pulled
        assert.is_truthy(res.stdout:find("no working config", 1, true))
    end)

    it("refuses a pre-existing target path (no clobber)", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        -- Pre-create the target dir with a file that must survive.
        local path = main .. "/.worktrees/occupied"
        assert(vim.fn.mkdir(path, "p") == 1)
        local keep = path .. "/keep.txt"
        local kf = assert(io.open(keep, "wb")); kf:write("precious\n"); kf:close()

        local res = run({ "worktree", "add", "occupied" }, main)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("already exists", 1, true))
        -- The pre-existing file is untouched.
        local rf = assert(io.open(keep, "rb")); local body = rf:read("*a"); rf:close()
        assert.equals("precious\n", body)
    end)

    it("surfaces git's error when the branch is checked out elsewhere", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        -- `dup` checked out at a path OTHER than .worktrees/dup, so the
        -- target-exists pre-check passes and git's own refusal is what fires.
        git(main, "worktree", "add", "-q", "-b", "dup", base .. "/elsewhere")
        local res = run({ "worktree", "add", "dup" }, main)
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("worktree add failed", 1, true))
        -- git's own message reaches the user (wording varies by version:
        -- "already checked out at" / "already used by worktree at").
        assert.is_truthy(res.stderr:lower():find("already", 1, true))
        assert.is_truthy(res.stderr:find("dup", 1, true))
    end)

    it("keeps the worktree when the auto-pull WRITE fails (non-destructive)", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        -- Force the working-copy write to fail after the worktree is created.
        local real_save = user.save
        user.save = function() return false, "simulated disk failure" end
        local res
        local ok = pcall(function()
            res = run({ "worktree", "add", "pullfail" }, main)
        end)
        user.save = real_save
        assert.is_true(ok)
        -- Non-zero exit so the partial state is visible.
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        -- The worktree is KEPT (undoing it would be a deletion).
        local path = main .. "/.worktrees/pullfail"
        assert.is_not_nil(uv.fs_stat(path), "worktree must be kept on pull failure")
        assert.is_nil(uv.fs_stat(user.filepath(path))) -- write failed
        assert.is_truthy(res.stderr:find("lw pull", 1, true)) -- tells user to retry
        assert.is_truthy(res.stdout:find("worktree kept", 1, true))
    end)

    it("does NOT modify or create a .gitignore", function()
        if not git_ok then pending("git not available"); return end
        local main = make_main(base)
        assert.is_nil(uv.fs_stat(main .. "/.gitignore"))
        local res = run({ "worktree", "add", "gi" }, main)
        assert.is_true(res.ok, res.stderr)
        -- No .gitignore was authored in main or the new worktree.
        assert.is_nil(uv.fs_stat(main .. "/.gitignore"))
        assert.is_nil(uv.fs_stat(main .. "/.worktrees/gi/.gitignore"))
    end)
end)
