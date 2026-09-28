--- Tests for the git submodule drift provider (headless §16.31 provider #3):
--- the pure parsers (status lines, .gitmodules, relative-URL resolution), the
--- terse grouped items, and end-to-end against real throwaway git repositories
--- (checkout ahead/behind, a pin behind its tracked branch via a local
--- "remote", uninitialized nested submodules, an unreachable relative URL) —
--- plus `lw health` text / --verbose / --json and the passive path staying
--- free of it. The real-git cases are skipped when git is not available.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local uv = vim.uv or vim.loop
local sm = require("loomworks.submodules")

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

describe("submodules parsers", function()
    local A = string.rep("a", 40)
    local B = string.rep("b", 40)
    local C = string.rep("c", 40)
    local D = string.rep("d", 40)

    it("parses `git submodule status` lines (prefix, sha, path, describe dropped)", function()
        local text = table.concat({
            " " .. A .. " libs/core (heads/main)",
            "+" .. B .. " libs/ui (v1.2-3-gbbbbbbb)",
            "-" .. C .. " libs/core/third party/x",
            "U" .. D .. " conflicted",
            "",
        }, "\n")
        local e = sm.parse_status(text)
        assert.equals(4, #e)
        assert.same({ prefix = " ", sha = A, path = "libs/core" }, e[1])
        assert.same({ prefix = "+", sha = B, path = "libs/ui" }, e[2])
        assert.same({ prefix = "-", sha = C, path = "libs/core/third party/x" }, e[3])
        assert.same({ prefix = "U", sha = D, path = "conflicted" }, e[4])
    end)

    it("parses .gitmodules (quoted names, case-insensitive keys, branch)", function()
        local text = [[
# comment
[submodule "LumeBase"]
	path = LumeBase
	url = ../LumeBase
	Branch = dev
[submodule "with space"]
	path = "dir/with space"
	url = https://example.com/x.git ; trailing comment
]]
        local by_path = sm.parse_gitmodules(text)
        assert.same({ name = "LumeBase", path = "LumeBase", url = "../LumeBase", branch = "dev" }, by_path["LumeBase"])
        assert.same({ name = "with space", path = "dir/with space", url = "https://example.com/x.git" },
            by_path["dir/with space"])
    end)

    it("resolves relative submodule URLs against the parent's remote (git rules)", function()
        assert.equals("https://h/org/N", sm.resolve_url("../N", "https://h/org/A.git"))
        assert.equals("https://h/org/N", sm.resolve_url("../N", "https://h/org/A/"))
        assert.equals("https://h/org/A.git/N", sm.resolve_url("./N", "https://h/org/A.git"))
        assert.equals("https://h/N", sm.resolve_url("../../N", "https://h/org/A"))
        assert.equals("git@h:org/N.git", sm.resolve_url("../N.git", "git@h:org/A.git"))
        assert.equals("git@h:N", sm.resolve_url("../N", "git@h:A"))
        assert.equals("C:/src/N", sm.resolve_url("../N", "C:/src/A"))
        assert.equals("/src/N", sm.resolve_url("../N", "/src/A"))
        -- Absolute URLs pass through unchanged.
        assert.equals("https://x/y.git", sm.resolve_url("https://x/y.git", "https://h/org/A"))
        -- Nothing to resolve against.
        assert.is_nil(sm.resolve_url("../N", nil))
    end)

    it("classifies ahead/behind counts", function()
        assert.equals("match", sm.classify(0, 0))
        assert.equals("ahead", sm.classify(0, 2))
        assert.equals("behind", sm.classify(3, 0))
        assert.equals("diverged", sm.classify(1, 1))
    end)

    it("groups a report into terse informational items with verbose-only detail", function()
        local report = {
            root = "/r",
            entries = {
                { path = "A", nested = false, state = "ahead", ahead = 1, behind = 0,
                    tracking = { ref = "origin/main", ahead = 0, behind = 1 } },
                { path = "B", nested = false, state = "behind", ahead = 0, behind = 2,
                    tracking = { ref = "origin/dev", ahead = 0, behind = 5 } },
                { path = "C", nested = false, state = "diverged", ahead = 1, behind = 1 },
                { path = "D", nested = false, state = "unrelated" },
                { path = "E", nested = false, state = "match", tracking = { ref = "origin/main", ahead = 0, behind = 0 } },
                { path = "A/n", nested = true, state = "uninitialized", url = "/x/n", reachable = false },
                { path = "F", nested = false, state = "uninitialized" },
            },
        }
        local items = sm.items(report)
        local by = {}
        for _, it in ipairs(items) do
            assert.equals("info", it.kind)
            assert.is_nil(it.remedy)
            assert.is_true(it.detail_verbose)
            by[#by + 1] = it.title
        end
        local drift = items[1].title
        assert.is_truthy(drift:find("^submodules: 4 checked out off their recorded commit"))
        assert.is_truthy(drift:find("A 1 ahead", 1, true))
        assert.is_truthy(drift:find("B 2 behind", 1, true))
        assert.is_truthy(drift:find("+1", 1, true)) -- only a few named
        assert.is_truthy(drift:find("lw health --verbose", 1, true))
        assert.is_truthy(items[1].detail:find("git submodule update --init --recursive", 1, true))
        assert.is_truthy(items[1].detail:find("git add", 1, true))
        local pins = items[2].title
        assert.is_truthy(pins:find("^submodules: 2 pins behind their tracked branch"))
        assert.is_truthy(pins:find("B 5 behind origin/dev", 1, true))
        assert.is_truthy(items[3].title:find("^submodules: 2 not initialized, 1 nested %("))
        assert.is_truthy(items[4].title:find("^submodules: 1 remote unreachable"))
        assert.is_truthy(items[4].title:find("A/n", 1, true))
        assert.equals(4, #items)
    end)

    it("a probe that timed out is 'not verified', never 'unreachable'", function()
        local items = sm.items({ root = "/r", entries = {
            { path = "A", nested = false, state = "match" },
            { path = "A/x", nested = true, state = "uninitialized", url = "git@h:x.git", reach = "no-answer",
                reach_detail = "no answer within 10 s" },
        } })
        local titles = {}
        for _, it in ipairs(items) do titles[#titles + 1] = it.title end
        local all = table.concat(titles, "\n")
        assert.is_nil(all:find("unreachable", 1, true), all)
        assert.is_truthy(all:find("submodules: 1 remote did not answer within 10 s — not verified (A/x)", 1, true), all)
    end)

    it("a clean report is one 'in sync' note", function()
        local items = sm.items({ root = "/r", entries = {
            { path = "A", nested = false, state = "match" },
            { path = "B", nested = false, state = "match" },
        } })
        assert.equals(1, #items)
        assert.equals("info", items[1].kind)
        assert.equals("submodules: 2 in sync with their recorded commits", items[1].title)
    end)

    it("finds the enclosing repository by its .git marker (file checks only)", function()
        local base = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(base .. "/repo/sub/deeper", "p")
        vim.fn.mkdir(base .. "/repo/.git", "p")
        assert.equals(base .. "/repo", sm.find_repo(base .. "/repo/sub/deeper"))
        assert.is_nil(sm.find_repo(base)) -- above the repo: none (tempdir is not in one)
        vim.fn.delete(base, "rf")
    end)
end)

-- ---------------------------------------------------------------------------
-- Real git fixtures
-- ---------------------------------------------------------------------------

local git_ok = vim.fn.executable("git") == 1

--- Run git (fixture setup) with a config isolated from the user's: no signing,
--- no hooks, a fixed default branch, local file transport allowed.
local function git(cwd, ...)
    local cmd = { "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=",
        "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always",
        "-c", "user.email=t@example.com", "-c", "user.name=t", "-C", cwd }
    for _, a in ipairs({ ... }) do cmd[#cmd + 1] = a end
    local r = vim.system(cmd, { text = true }):wait()
    assert(r.code == 0, "git failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
    return vim.trim(r.stdout or "")
end

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text); f:close()
end

local function commit(repo, name)
    write(repo .. "/" .. name .. ".txt", name .. "\n")
    git(repo, "add", name .. ".txt")
    git(repo, "commit", "-q", "-m", name)
end

--- Build the fixture:
---   up_N                  nested upstream (1 commit)
---   up_A                  has nested `nestedN` (url ../up_N) and a gitlink
---                         `gone` (url ../up_gone, which does not exist)
---   up_B                  main c1..c3, then branch dev = c3 + 2 commits
---   super/A  (from up_A)  checked out 1 AHEAD of its pin; up_A later gets 1
---                         more commit and super/A fetches → pin 1 behind
---                         origin/main (origin/HEAD)
---   super/B  (from up_B)  checked out 1 BEHIND its pin; .gitmodules
---                         branch = dev, fetched → pin 2 behind origin/dev
--- Returns the canonical (long-path) superproject root and the base dir.
local function make_fixture()
    local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwsmXXXXXX")
    -- Canonical path: on Windows CI tempname() can be the 8.3 short form
    -- (RUNNER~1) while git reports the long one.
    base = ((uv.fs_realpath(base) or base):gsub("\\", "/"))

    local upN, upA, upB, super = base .. "/up_N", base .. "/up_A", base .. "/up_B", base .. "/super"
    for _, d in ipairs({ upN, upA, upB, super }) do
        vim.fn.mkdir(d, "p")
        git(d, "init", "-q")
    end
    commit(upN, "n1")

    commit(upA, "a1")
    git(upA, "submodule", "add", "-q", upN, "nestedN")
    git(upA, "config", "-f", ".gitmodules", "submodule.nestedN.url", "../up_N")
    local nsha = git(upN, "rev-parse", "HEAD")
    git(upA, "update-index", "--add", "--cacheinfo", "160000," .. nsha .. ",gone")
    git(upA, "config", "-f", ".gitmodules", "submodule.gone.path", "gone")
    git(upA, "config", "-f", ".gitmodules", "submodule.gone.url", "../up_gone")
    git(upA, "add", ".gitmodules")
    git(upA, "commit", "-q", "-m", "nested")

    commit(upB, "c1"); commit(upB, "c2"); commit(upB, "c3")

    commit(super, "s1")
    git(super, "submodule", "add", "-q", upA, "A")
    git(super, "submodule", "add", "-q", upB, "B")
    git(super, "config", "-f", ".gitmodules", "submodule.B.branch", "dev")
    git(super, "add", ".gitmodules")
    git(super, "commit", "-q", "-m", "subs")

    -- A: a local commit → checked out 1 ahead of the pin.
    commit(super .. "/A", "local")
    -- up_A advances; A fetches → pin 1 behind origin/main.
    commit(upA, "a2")
    git(super .. "/A", "fetch", "-q", "origin")
    -- B: check out the pin's parent → 1 behind.
    git(super .. "/B", "checkout", "-q", "HEAD~1")
    -- up_B grows a dev branch 2 past the pin; B fetches it.
    git(upB, "checkout", "-q", "-b", "dev")
    commit(upB, "d1"); commit(upB, "d2")
    git(super .. "/B", "fetch", "-q", "origin")

    return super, base
end

describe("submodules report (real git)", function()
    it("reports checkout drift, pins vs tracked branch, nested uninitialized and reachability; git runs hook-free", function()
        if not git_ok then pending("git not available in this environment") return end
        local super, base = make_fixture()

        -- Every git call disables repository command hooks (spec §17.8).
        local exe = require("loomworks.exe")
        local orig_system = exe.system
        local lines = {}
        exe.system = function(cmd, ...)
            lines[#lines + 1] = table.concat(cmd, " ")
            return orig_system(cmd, ...)
        end
        local ok, report = pcall(sm.report, super .. "/")
        exe.system = orig_system
        assert.is_true(ok, report)
        assert.is_true(#lines > 0)
        for _, line in ipairs(lines) do
            assert.is_truthy(line:find("-c core.fsmonitor=false", 1, true), line)
            assert.is_truthy(line:find("-c core.hooksPath=", 1, true), line)
        end
        assert.is_not_nil(report)
        assert.equals(super, report.root)
        local by = {}
        for _, e in ipairs(report.entries) do by[e.path] = e end

        assert.equals("ahead", by["A"].state)
        assert.equals(1, by["A"].ahead)
        assert.equals(0, by["A"].behind)
        assert.is_false(by["A"].nested)
        assert.same({ ref = "origin/main", ahead = 0, behind = 1 }, by["A"].tracking)

        assert.equals("behind", by["B"].state)
        assert.equals(1, by["B"].behind)
        assert.same({ ref = "origin/dev", ahead = 0, behind = 2 }, by["B"].tracking)
        assert.is_truthy(by["B"].recorded and by["B"].checked_out and by["B"].recorded ~= by["B"].checked_out)

        assert.equals("uninitialized", by["A/nestedN"].state)
        assert.is_true(by["A/nestedN"].nested)
        assert.equals(base .. "/up_N", by["A/nestedN"].url)
        assert.is_true(by["A/nestedN"].reachable)
        assert.equals("reachable", by["A/nestedN"].reach)

        assert.equals("uninitialized", by["A/gone"].state)
        assert.equals(base .. "/up_gone", by["A/gone"].url)
        assert.is_false(by["A/gone"].reachable)
        assert.equals("unreachable", by["A/gone"].reach)

        local titles = {}
        for _, it in ipairs(sm.items(report)) do titles[#titles + 1] = it.title end
        local all = table.concat(titles, "\n")
        assert.is_truthy(all:find("submodules: 2 checked out off their recorded commit (A 1 ahead, B 1 behind)", 1, true), all)
        assert.is_truthy(all:find("submodules: 2 pins behind their tracked branch (A 1 behind origin/main, B 2 behind origin/dev)", 1, true), all)
        assert.is_truthy(all:find("submodules: 2 not initialized, 2 nested (A/gone, A/nestedN)", 1, true), all)
        assert.is_truthy(all:find("submodules: 1 remote unreachable (A/gone)", 1, true), all)

        -- Reachability is skippable (the passive-free path never probes).
        local r2 = sm.report(super, { reachability = false })
        for _, e in ipairs(r2.entries) do assert.is_nil(e.reachable) end

        vim.fn.delete(base, "rf")
    end)

    it("is silent without .gitmodules, outside a repo, or without git", function()
        if not git_ok then pending("git not available in this environment") return end
        local base = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwsmXXXXXX")
        base = ((uv.fs_realpath(base) or base):gsub("\\", "/"))
        vim.fn.mkdir(base .. "/plain", "p")
        assert.is_nil(sm.report(base .. "/plain"))
        vim.fn.mkdir(base .. "/repo", "p")
        git(base .. "/repo", "init", "-q")
        assert.is_nil(sm.report(base .. "/repo"))
        write(base .. "/repo/.gitmodules", "")
        assert.is_nil(sm.report(base .. "/repo", { git = "lw-no-such-git-xyz" }))
        vim.fn.delete(base, "rf")
    end)
end)

-- ---------------------------------------------------------------------------
-- lw health integration
-- ---------------------------------------------------------------------------

describe("lw health submodule items", function()
    local cli = require("loomworks.cli")
    local suggestions = require("loomworks.suggestions")

    local function capture(fn)
        local out_buf = {}
        local rw, rs = io.write, io.stderr
        io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
        io.stderr = { write = function() end }
        local ok, err = pcall(fn)
        io.write, io.stderr = rw, rs
        if not ok then error(err, 0) end
        return table.concat(out_buf)
    end

    local orig_probe
    before_each(function()
        orig_probe = cli._probe_inventory
        cli._probe_inventory = function() return nil end
    end)
    after_each(function() cli._probe_inventory = orig_probe end)

    it("text (terse; detail only with --verbose), --json report, never cached or counted", function()
        if not git_ok then pending("git not available in this environment") return end
        local super, base = make_fixture()
        write(super .. "/loomworks.json", vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
        vim.fn.mkdir(super .. "/App", "p")

        local text = capture(function() assert.equals(0, cli.cmd_health(super)) end)
        assert.is_truthy(text:find("· submodules: 2 checked out off their recorded commit", 1, true), text)
        assert.is_truthy(text:find("· submodules: 1 remote unreachable (A/gone)", 1, true), text)
        -- Per-submodule detail only in the verbose report.
        assert.is_nil(text:find("git submodule update --init --recursive", 1, true))

        local verbose = capture(function() cli.cmd_health(super, { verbose = true }) end)
        assert.is_truthy(verbose:find("git submodule update --init --recursive", 1, true), verbose)
        assert.is_truthy(verbose:find("A/gone", 1, true))

        local doc = vim.json.decode(capture(function() cli.cmd_health(super, { json = true }) end))
        assert.equals(super, doc.submodules.root)
        local by = {}
        for _, e in ipairs(doc.submodules.entries) do by[e.path] = e end
        assert.equals("ahead", by["A"].state)
        assert.equals("origin/dev", by["B"].tracking.ref)
        assert.is_false(by["A/gone"].reachable)
        assert.equals(0, doc.summary.actionable) -- all informational
        local sub_items = 0
        for _, s in ipairs(doc.suggestions) do
            if s.title:find("^submodules:") then
                sub_items = sub_items + 1
                assert.equals("info", s.kind)
            end
        end
        assert.equals(4, sub_items)

        -- Report-only: nothing about submodules lands in the health cache …
        local f = assert(io.open(super .. "/.nvim/loomworks.health.json", "rb"))
        local cached = f:read("*a"); f:close()
        assert.is_nil(cached:find("submodules", 1, true))

        -- … and the passive status count never runs git.
        local exe = require("loomworks.exe")
        local orig_system = exe.system
        exe.system = function(cmd, ...)
            if cmd[1] == "git" then error("passive path spawned git") end
            return orig_system(cmd, ...)
        end
        local ok, status = pcall(capture, function() cli.cmd_status(super, {}) end)
        exe.system = orig_system
        assert.is_true(ok, status)
        assert.is_nil(status:find("suggestion", 1, true))

        -- Outside a git repo the JSON carries no `submodules` key.
        suggestions._update_check = nil
        vim.fn.delete(base, "rf")
    end)
end)
