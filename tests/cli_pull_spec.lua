-- `lw pull` — fold another checkout's working copy into the current one.
-- Covers the SOURCE-wins item-level merge (the opposite winner from the
-- loomworks.json->user.json fold), the exclusions (active profile + cache),
-- source resolution and its explicit errors, and --dry-run writing nothing.
-- Source resolution is driven with a stubbed git runner + real temp dirs; a
-- real temp repo + linked worktree covers the end-to-end path (guard-skipped
-- when git is absent).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local user = require("loomworks.user")
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function tmpdir()
    local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwpullXXXXXX")
    return (base:gsub("\\", "/"))
end

--- A git runner matching git_query's (cwd, args) -> stdout|nil contract, where
--- the current worktree's toplevel is `target` and the main worktree is `main`.
--- `main == nil` makes `git worktree list` fail (not a linked worktree).
local function fake_git(target, main)
    return function(_, args)
        local a1 = args[1]
        if a1 == "--version" then
            return "git version 2.40.0"
        elseif a1 == "rev-parse" then
            return target
        elseif a1 == "worktree" then
            if not main then return nil end
            return "worktree " .. main .. "\nHEAD abc\n\nworktree " .. target .. "\nHEAD def\n"
        end
        return nil
    end
end

--- Write a source working copy at `root` and return the same table.
local function write_user(root, data)
    data._meta = data._meta or { version = 2 }
    assert(user.save(root, data))
    return data
end

--- Report project/set references in `data` that point at absent items.
local function dangling_refs(data)
    local bad = {}
    for name, mappings in pairs(data.configuration_sets or {}) do
        for pkey in pairs(mappings or {}) do
            if not (data.projects and data.projects[pkey]) then
                bad[#bad + 1] = "set " .. name .. " -> missing project " .. pkey
            end
        end
    end
    for key, prof in pairs(data.profiles or {}) do
        local set = prof.configuration_set
        if set and not (data.configuration_sets and data.configuration_sets[set]) then
            bad[#bad + 1] = "profile " .. key .. " -> missing set " .. set
        end
    end
    return bad
end

-- A representative, self-consistent source working copy.
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

-- ---------------------------------------------------------------------------
-- _pull_merge — the item-level, SOURCE-wins union
-- ---------------------------------------------------------------------------

describe("cli._pull_merge (SOURCE wins, non-destructive)", function()
    it("SOURCE wins on a colliding project key", function()
        local target = { projects = { app = { path = "t/app" }, tonly = { path = "t/only" } } }
        local source = { projects = { app = { path = "s/app" }, sonly = { path = "s/only" } } }
        local merged = cli._pull_merge(target, source)
        -- The load-bearing assertion: the collision resolves to the SOURCE.
        assert.equals("s/app", merged.projects.app.path)
        -- Non-destructive: the target-only item survives.
        assert.equals("t/only", merged.projects.tonly.path)
        -- Source-only item is added.
        assert.equals("s/only", merged.projects.sonly.path)
    end)

    it("SOURCE wins on a colliding configuration set (item-level replace)", function()
        local target = { configuration_sets = { S = { app = "Debug" }, T = { app = "Debug" } } }
        local source = { configuration_sets = { S = { app = "Release" } } }
        local merged = cli._pull_merge(target, source)
        assert.same({ app = "Release" }, merged.configuration_sets.S) -- source
        assert.same({ app = "Debug" }, merged.configuration_sets.T)   -- kept
    end)

    it("SOURCE wins on a colliding profile", function()
        local target = { profiles = { P = { configuration_set = "T" } } }
        local source = { profiles = { P = { configuration_set = "S" }, Q = { configuration_set = "S" } } }
        local merged = cli._pull_merge(target, source)
        assert.equals("S", merged.profiles.P.configuration_set)
        assert.equals("S", merged.profiles.Q.configuration_set)
    end)

    it("never pulls the active profile — target keeps its own", function()
        local target = { active_profile = "T-active" }
        local source = { active_profile = "S-active", projects = { a = {} } }
        local merged = cli._pull_merge(target, source)
        assert.equals("T-active", merged.active_profile)
    end)

    it("keeps the target's active profile even when the target has none", function()
        local merged = cli._pull_merge({}, { active_profile = "S", projects = { a = {} } })
        assert.is_nil(merged.active_profile)
    end)

    it("creates a full config from a fresh (empty) target", function()
        local merged = cli._pull_merge({}, sample_source())
        assert.is_not_nil(merged.projects.app)
        assert.is_not_nil(merged.configuration_sets.Dev)
        assert.is_not_nil(merged.profiles["Dev:ninja-gcc"])
        assert.same({}, dangling_refs(merged))
    end)

    it("never pulls the workspace name — target keeps its own identity", function()
        local merged = cli._pull_merge({ name = "target-ws" }, { name = "source-ws", projects = { a = {} } })
        assert.equals("target-ws", merged.name)
    end)

    it("keeps a nil name when neither the merge nor the target sets one", function()
        local merged = cli._pull_merge({}, { name = "source-ws", projects = { a = {} } })
        assert.is_nil(merged.name)
    end)

    it("never pulls the per-machine device selection — target keeps its own map", function()
        local target = { device = { ["P"] = { serial = "t-serial" } } }
        local source = { device = { ["P"] = { serial = "s-serial" }, ["Q"] = { serial = "q" } },
            projects = { a = {} } }
        local merged = cli._pull_merge(target, source)
        assert.equals("t-serial", merged.device.P.serial) -- unchanged
        assert.is_nil(merged.device.Q)                    -- source device NOT added
    end)

    it("unions debug adapters per key (source wins on collision, siblings survive)", function()
        local target = { debug = { adapters = { ["c++"] = "codelldb", typescript = "pwa-node" } } }
        local source = { debug = { adapters = { ["c++"] = "cppdbg", rust = "codelldb" } } }
        local merged = cli._pull_merge(target, source)
        assert.equals("cppdbg", merged.debug.adapters["c++"])       -- collision -> source
        assert.equals("pwa-node", merged.debug.adapters.typescript) -- target-only kept
        assert.equals("codelldb", merged.debug.adapters.rust)       -- source-only added
    end)

    it("unions lsp options per key (server -> option, siblings survive)", function()
        local target = { lsp = { clangd = { clang_tidy = true, background_index = true } } }
        local source = { lsp = { clangd = { clang_tidy = false }, luals = { hint = true } } }
        local merged = cli._pull_merge(target, source)
        assert.equals(false, merged.lsp.clangd.clang_tidy)       -- collision -> source
        assert.equals(true, merged.lsp.clangd.background_index)  -- target-only kept
        assert.equals(true, merged.lsp.luals.hint)               -- source-only server added
    end)

    it("keeps default_target (travels with the profile), source-wins per profile", function()
        local target = { default_target = { P = "t", R = "keep" } }
        local source = { default_target = { P = "s", Q = "add" } }
        local merged = cli._pull_merge(target, source)
        assert.equals("s", merged.default_target.P)    -- source wins
        assert.equals("keep", merged.default_target.R) -- target-only kept
        assert.equals("add", merged.default_target.Q)  -- source-only added
    end)
end)

-- ---------------------------------------------------------------------------
-- _plan_pull — resolution, load, merge, changed-flag, summary (stubbed git)
-- ---------------------------------------------------------------------------

describe("cli._plan_pull", function()
    local target, source
    before_each(function()
        target = tmpdir()
        source = tmpdir()
    end)
    after_each(function()
        vim.fn.delete(target, "rf")
        vim.fn.delete(source, "rf")
    end)

    it("pulls all items into a fresh worktree with no working copy", function()
        write_user(source, sample_source())
        local plan, err = cli._plan_pull({ cwd = target, git = fake_git(target, source) })
        assert.is_nil(err)
        assert.is_true(plan.changed)
        assert.equals(source, plan.source_root)
        assert.equals(target, plan.target_root)
        local added = plan.summary.projects.added
        table.sort(added)
        assert.same({ "app", "lib" }, added)
        assert.is_not_nil(plan.merged.profiles["Dev:ninja-gcc"])
        assert.same({}, dangling_refs(plan.merged))
        -- Not written yet — planning only.
        assert.is_nil(uv.fs_stat(user.filepath(target)))
    end)

    it("SOURCE wins merging into a target that already has config", function()
        write_user(target, {
            active_profile = "Local:x",
            projects = { app = { cmake = {}, path = "app-TARGET" }, only_here = { cmake = {} } },
        })
        write_user(source, {
            projects = { app = { cmake = {}, path = "app-SOURCE" }, only_source = { cmake = {} } },
        })
        local plan = assert(cli._plan_pull({ cwd = target, git = fake_git(target, source) }))
        assert.equals("app-SOURCE", plan.merged.projects.app.path) -- source wins
        assert.is_not_nil(plan.merged.projects.only_here)          -- target-only kept
        assert.is_not_nil(plan.merged.projects.only_source)        -- source-only added
        assert.same({ "app" }, plan.summary.projects.updated)
        assert.same({ "only_source" }, plan.summary.projects.added)
        assert.same({ "only_here" }, plan.summary.projects.kept)
        -- Active profile is the target's own, untouched.
        assert.equals("Local:x", plan.merged.active_profile)
    end)

    it("reports non-itemized (settings) changes when only debug/lsp differ", function()
        write_user(target, { projects = { app = { cmake = {}, path = "app" } } })
        write_user(source, {
            projects = { app = { cmake = {}, path = "app" } }, -- identical -> no item change
            debug = { adapters = { rust = "codelldb" } },
        })
        local plan = assert(cli._plan_pull({ cwd = target, git = fake_git(target, source) }))
        assert.is_true(plan.changed)
        -- No itemized project change...
        assert.same({}, plan.summary.projects.added)
        assert.same({}, plan.summary.projects.updated)
        -- ...but the settings change is reported, so the summary is never blank.
        assert.is_truthy(vim.tbl_contains(plan.settings, "debug adapters"))
    end)

    it("reports no change when the source adds nothing new", function()
        write_user(target, { projects = { app = { cmake = {}, path = "app" } } })
        write_user(source, { projects = { app = { cmake = {}, path = "app" } } })
        local plan = assert(cli._plan_pull({ cwd = target, git = fake_git(target, source) }))
        assert.is_false(plan.changed)
    end)

    it("errors when the source has no working copy", function()
        -- source dir exists but has no .nvim/loomworks.user.json
        local plan, err = cli._plan_pull({ cwd = target, git = fake_git(target, source) })
        assert.is_nil(plan)
        assert.is_truthy(err:find("nothing to pull", 1, true))
    end)

    it("errors when no source is given and this is not a linked worktree", function()
        write_user(source, sample_source())
        local plan, err = cli._plan_pull({ cwd = target, git = fake_git(target, nil) })
        assert.is_nil(plan)
        assert.is_truthy(err:find("not a linked git worktree", 1, true))
    end)

    it("refuses when the source resolves to the current checkout", function()
        write_user(target, sample_source())
        -- Explicit source == target.
        local plan, err = cli._plan_pull({
            cwd = target,
            source = target,
            git = fake_git(target, source),
        })
        assert.is_nil(plan)
        assert.is_truthy(err:find("same checkout", 1, true))
    end)

    it("refuses when the git top-level and realpath'd source spell the same dir differently", function()
        -- Regression for the CI-Windows self-pull miss: the git top-level
        -- (target_root) is NOT realpath'd while resolve_abs(source) IS, so a
        -- symlink/junction/short-name divergence made norm_cmp alone miss the
        -- guard. Reproduce with a directory symlink: the "git" top-level is the
        -- LINK spelling, resolve_abs realpaths it to the real dir -> the two
        -- roots diverge pre-fix. Symlink creation needs privilege on Windows;
        -- skip cleanly there rather than hard-fail.
        local realdir = target .. "/real"
        assert(uv.fs_mkdir(realdir, 448))
        write_user(realdir, sample_source())
        local linkpath = target .. "/link"
        local ok = uv.fs_symlink(realdir, linkpath, { dir = true })
        if not ok then
            pending("requires symlink support (privileged on Windows)")
            return
        end
        -- git top-level = the LINK spelling; resolve_abs(source) -> realdir.
        local plan, err = cli._plan_pull({
            cwd = linkpath,
            source = linkpath,
            git = fake_git(linkpath, source),
        })
        assert.is_nil(plan)
        assert.is_truthy(err:find("same checkout", 1, true))
    end)

    it("errors when the current checkout can't be determined", function()
        -- Not a git repo (rev-parse nil) and cwd holds no workspace.
        local nogit = function(_, args)
            if args[1] == "--version" then return "git version 2.40.0" end
            return nil
        end
        local plan, err = cli._plan_pull({ cwd = target, source = source, git = nogit })
        assert.is_nil(plan)
        assert.is_truthy(err:find("determine the current checkout", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- cmd_pull — end-to-end write + --dry-run (stubbed git, captured stdout)
-- ---------------------------------------------------------------------------

describe("cli.cmd_pull", function()
    local target, source, wrote, real_write
    before_each(function()
        target, source = tmpdir(), tmpdir()
        wrote, real_write = {}, io.write
        io.write = function(s) wrote[#wrote + 1] = s end
    end)
    after_each(function()
        io.write = real_write
        vim.fn.delete(target, "rf")
        vim.fn.delete(source, "rf")
    end)

    it("writes the pulled working copy and excludes the active profile", function()
        write_user(source, sample_source())
        local code = cli.cmd_pull({ "pull" }, { cwd = target, git = fake_git(target, source) })
        io.write = real_write
        assert.equals(0, code)
        local written = uv.fs_stat(user.filepath(target))
        assert.is_not_nil(written)
        local data = user.load(target)
        assert.is_not_nil(data.projects.app)
        assert.is_not_nil(data.configuration_sets.Dev)
        assert.is_not_nil(data.profiles["Dev:ninja-gcc"])
        -- active_profile was NOT pulled (target had none).
        assert.is_nil(data.active_profile)
        assert.same({}, dangling_refs(data))
    end)

    it("--dry-run writes nothing", function()
        write_user(source, sample_source())
        local code = cli.cmd_pull({ "pull", "--dry-run" }, { cwd = target, git = fake_git(target, source) })
        io.write = real_write
        assert.equals(0, code)
        assert.is_nil(uv.fs_stat(user.filepath(target)), "dry run must not write user.json")
        assert.is_truthy(table.concat(wrote):find("dry run", 1, true))
    end)

    it("--dry-run reports a settings-only change and still writes nothing", function()
        write_user(target, { projects = { app = { cmake = {}, path = "app" } } })
        write_user(source, {
            projects = { app = { cmake = {}, path = "app" } },
            debug = { adapters = { rust = "codelldb" } },
        })
        local before = user.load(target)
        local code = cli.cmd_pull({ "pull", "--dry-run" }, { cwd = target, git = fake_git(target, source) })
        io.write = real_write
        assert.equals(0, code)
        local text = table.concat(wrote)
        assert.is_truthy(text:find("debug adapters", 1, true)) -- non-blank summary
        assert.is_truthy(text:find("dry run", 1, true))
        -- Nothing written: the target's working copy is byte-for-byte unchanged.
        assert.same(before, user.load(target))
        assert.is_nil(user.load(target).debug)
    end)
end)

-- ---------------------------------------------------------------------------
-- End-to-end with a real linked git worktree.
-- ---------------------------------------------------------------------------

describe("cli.cmd_pull (real git worktree)", function()
    local git_ok = vim.fn.executable("git") == 1

    it("a fresh linked worktree pulls the main checkout's config", function()
        if not git_ok then
            pending("git not available in this environment")
            return
        end
        local base = tmpdir()
        local main = base .. "/main"
        assert(uv.fs_mkdir(main, 448))

        local function git(cwd, ...)
            local cmd = { "git", "-C", cwd }
            for _, a in ipairs({ ... }) do cmd[#cmd + 1] = a end
            local r = vim.system(cmd, { text = true }):wait()
            assert(r.code == 0, "git failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
        end

        git(main, "init", "-q")
        git(main, "config", "user.email", "t@example.com")
        git(main, "config", "user.name", "t")
        -- A committed file so `git worktree add` has a HEAD to check out. The
        -- working copy stays untracked (.nvim), like the real setup.
        local f = assert(io.open(main .. "/README.md", "wb"))
        f:write("demo\n"); f:close()
        git(main, "add", "README.md")
        git(main, "commit", "-q", "-m", "init")
        write_user(main, sample_source())

        local wt = base .. "/wt"
        git(main, "worktree", "add", "-q", wt)
        wt = (uv.fs_realpath(wt) or wt):gsub("\\", "/")

        -- Fresh worktree: no working copy yet.
        assert.is_nil(uv.fs_stat(user.filepath(wt)))

        local real_write = io.write
        io.write = function() end
        local code = cli.cmd_pull({ "pull" }, { cwd = wt })
        io.write = real_write

        assert.equals(0, code)
        local data = user.load(wt)
        assert.is_not_nil(data.projects.app)
        assert.is_not_nil(data.profiles["Dev:ninja-gcc"])
        assert.is_nil(data.active_profile) -- not pulled
        assert.same({}, dangling_refs(data))

        vim.fn.delete(base, "rf")
    end)
end)
