--- Tests for the repo launcher / pin health provider (headless §16.31 provider
--- #4): file checks (pin hash coverage, launcher presence and generation),
--- the git checks against real throwaway repositories (tracked, exec bit,
--- effective eol attributes, committed and checked-out line endings, the
--- ignore rule — committed vs personal), stale cached binaries, the all-green
--- line, and that it is report-only (never on the passive path, never cached).
--- The real-git cases are skipped when git is not available.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local uv = vim.uv or vim.loop
local lh = require("loomworks.launcher_health")
local launcher = require("boot.launcher")
local pin = require("boot.pin")

local git_ok = vim.fn.executable("git") == 1

local function git(cwd, ...)
    local cmd = { "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=",
        "-c", "init.defaultBranch=main", "-c", "user.email=t@example.com", "-c", "user.name=t",
        "-C", cwd }
    for _, a in ipairs({ ... }) do cmd[#cmd + 1] = a end
    local r = vim.system(cmd, { text = true }):wait()
    assert(r.code == 0, "git failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
    return vim.trim(r.stdout or "")
end

local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text); f:close()
end

local VERSION = "1.2.3"

--- A complete pin for VERSION (every host binary + the bundle).
local function pin_text(skip)
    local hashes = {}
    for _, a in pairs(pin.HOST_ASSETS) do
        if a ~= skip then hashes[a] = string.rep("a", 64) end
    end
    hashes[pin.bundle_asset(VERSION)] = string.rep("b", 64)
    return pin.serialize(VERSION, hashes)
end

local function tmpdir()
    local d = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwlhXXXXXX")
    return ((uv.fs_realpath(d) or d):gsub("\\", "/"))
end

--- A repository in the Windows-like configuration (no file-mode tracking, no
--- autocrlf) with the three launcher files written.
local function repo_with_files(opts)
    opts = opts or {}
    local r = tmpdir()
    git(r, "init", "-q")
    git(r, "config", "core.filemode", "false")
    git(r, "config", "core.autocrlf", "false")
    -- Isolate from the developer's personal ignore/attributes files.
    git(r, "config", "core.excludesFile", r .. "/.git/no-such-excludes")
    git(r, "config", "core.attributesFile", r .. "/.git/no-such-attributes")
    write(r .. "/lw.pin", opts.pin or pin_text())
    write(r .. "/lw.sh", opts.sh or launcher.render("sh"))
    write(r .. "/lw.cmd", opts.cmd or launcher.render("cmd"))
    return r
end

local function titles(items)
    local t = {}
    for _, i in ipairs(items) do t[#t + 1] = (i.kind or "suggestion") .. "|" .. i.title end
    return table.concat(t, "\n")
end

local function find(items, needle)
    for _, i in ipairs(items) do
        if i.title:find(needle, 1, true) then return i end
    end
end

describe("launcher health (§16.31 provider #4)", function()
    it("is silent without a pin", function()
        local r = tmpdir()
        assert.same({}, lh.provider({ root = r }))
        vim.fn.delete(r, "rf")
    end)

    it("a correctly committed launcher gives one all-good line", function()
        if not git_ok then pending("git not available") return end
        local r = repo_with_files()
        write(r .. "/.gitattributes", "lw.sh text eol=lf\nlw.cmd text eol=crlf\nlw.pin text eol=lf\n")
        write(r .. "/.gitignore", ".nvim/\n")
        git(r, "add", "--chmod=+x", "lw.sh")
        git(r, "add", "lw.cmd", "lw.pin", ".gitattributes", ".gitignore")
        git(r, "commit", "-q", "-m", "x")
        local items = lh.provider({ root = r })
        assert.equals(1, #items, titles(items))
        assert.equals("info", items[1].kind)
        assert.matches("launcher: lw 1.2.3 pinned; lw.sh / lw.cmd current, modes and line endings ok",
            items[1].title, 1, true)
        vim.fn.delete(r, "rf")
    end)

    it("reports the reactive-style first-use problems, each with a remedy", function()
        if not git_ok then pending("git not available") return end
        -- A lw.cmd from a known generation with a defect that breaks runs.
        local old_cmd = "@echo off\r\nrem a broken old launcher\r\n"
        local key = vim.fn.sha256(launcher.normalize(old_cmd))
        launcher.GENERATIONS.cmd[key] = { gen = 0, releases = "0.0.1-0.0.2",
            defects = { { severity = "breaks", text = "calls find by bare name" } } }
        local r = repo_with_files({ pin = pin_text("lw-macos-arm64"), cmd = old_cmd })
        git(r, "add", "lw.sh", "lw.cmd", "lw.pin") -- mode 100644: bootstrapped on Windows
        git(r, "commit", "-q", "-m", "x")
        write(r .. "/.nvim/cache/lw-1.0.0-lw-linux-x86_64", string.rep("x", 1024))
        write(r .. "/.nvim/cache/lw-" .. VERSION .. "-lw-linux-x86_64", "current")

        local items = lh.provider({ root = r })
        launcher.GENERATIONS.cmd[key] = nil
        local t = titles(items)
        local function nag(needle)
            local i = find(items, needle)
            assert.is_truthy(i, "missing '" .. needle .. "' in:\n" .. t)
            assert.equals("suggestion", i.kind, needle)
            assert.is_truthy(i.remedy and i.remedy ~= "", needle)
            return i
        end
        local p = nag("lw.pin has no hash for lw-macos-arm64")
        assert.matches("./lw.sh update --version 1.2.3", p.remedy, 1, true)
        nag("lw.cmd is an old launcher (from lw 0.0.1-0.0.2): calls find by bare name")
        local x = nag("lw.sh is not executable in git (mode 100644)")
        assert.matches("git update-index --chmod=+x lw.sh", x.remedy, 1, true)
        nag("no line-ending rule for lw.sh, lw.cmd, lw.pin in .gitattributes")
        nag(".nvim/cache/ is not ignored")
        local stale = find(items, "1 old pinned binary in .nvim/cache")
        assert.is_truthy(stale, t)
        assert.equals("info", stale.kind)
        assert.is_nil(find(items, "pinned; lw.sh / lw.cmd current"))
        vim.fn.delete(r, "rf")
    end)

    it("checks committed and checked-out line endings", function()
        if not git_ok then pending("git not available") return end
        local r = repo_with_files({ pin = pin_text():gsub("\n", "\r\n") })
        git(r, "add", "--chmod=+x", "lw.sh")
        git(r, "add", "lw.cmd", "lw.pin")
        git(r, "commit", "-q", "-m", "x")
        -- the checkout's lw.sh then gets CR LF (as autocrlf would without the rule)
        write(r .. "/lw.sh", (launcher.render("sh"):gsub("\n", "\r\n")))
        local items = lh.provider({ root = r })
        local t = titles(items)
        local c = find(items, "committed with CR LF line endings:")
        assert.is_truthy(c and c.title:find("lw.pin (crlf)", 1, true), t)
        assert.is_truthy(find(items, "wrong line endings in this checkout: lw.sh (crlf, needs lf)"), t)
        vim.fn.delete(r, "rf")
    end)

    it("an ignore rule only in the personal gitignore does not count", function()
        if not git_ok then pending("git not available") return end
        local r = repo_with_files()
        local excl = r .. "/../" .. vim.fn.fnamemodify(r, ":t") .. "-excludes"
        write(excl, ".nvim/\n")
        git(r, "config", "core.excludesFile", excl)
        local items = lh.provider({ root = r })
        assert.is_truthy(find(items, ".nvim/cache/ is ignored only by your personal gitignore"), titles(items))
        -- a committed rule (any form git accepts) satisfies it
        write(r .. "/.gitignore", "/.nvim/**\n")
        items = lh.provider({ root = r })
        assert.is_nil(find(items, ".nvim/cache/ is"), titles(items))
        vim.fn.delete(r, "rf"); os.remove(excl)
    end)

    it("equivalent pattern attributes satisfy the check; the global attributes file does not", function()
        if not git_ok then pending("git not available") return end
        local r = repo_with_files()
        local gattr = r .. "-attrs"
        write(gattr, "lw.sh text eol=lf\nlw.cmd text eol=crlf\nlw.pin text eol=lf\n")
        git(r, "config", "core.attributesFile", gattr)
        assert.is_truthy(find(lh.provider({ root = r }), "no line-ending rule"))
        write(r .. "/.gitattributes", "*.sh text eol=lf\n*.cmd text eol=crlf\n*.pin text eol=lf\n")
        assert.is_nil(find(lh.provider({ root = r }), "no line-ending rule"))
        vim.fn.delete(r, "rf"); os.remove(gattr)
    end)

    it("unknown launcher content is informational; a missing launcher nags; no git -> file checks only", function()
        local r = tmpdir()
        write(r .. "/lw.pin", pin_text())
        write(r .. "/lw.sh", "#!/bin/sh\necho mine\n")
        local saved = lh._git
        lh._git = function() return 127, "" end
        local items = lh.provider({ root = r })
        lh._git = saved
        local t = titles(items)
        local u = find(items, "lw.sh differs from every launcher lw wrote (local edits?)")
        assert.is_truthy(u, t)
        assert.equals("info", u.kind)
        local m = find(items, "lw.cmd is missing")
        assert.is_truthy(m, t)
        assert.equals("suggestion", m.kind)
        assert.is_nil(find(items, "executable in git"), t)
        vim.fn.delete(r, "rf")
    end)

    it("is report-only: registered with persist = false", function()
        local sug = require("loomworks.suggestions")
        assert.is_true(sug._report_only[sug.launcher_provider] == true)
        local found = false
        for _, p in ipairs(sug._providers) do if p == sug.launcher_provider then found = true end end
        assert.is_false(found, "must not be a passive provider")
    end)

    it("shows in `lw health` text with the launcher: prefix", function()
        if not git_ok then pending("git not available") return end
        local cli = require("loomworks.cli")
        local r = repo_with_files()
        write(r .. "/loomworks.json", vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
        vim.fn.mkdir(r .. "/App", "p")
        local orig_probe = cli._probe_inventory
        cli._probe_inventory = function() return nil end
        local out_buf = {}
        local rw = io.write
        io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = tostring(s) end end
        local ok, err = pcall(cli.cmd_health, r)
        io.write = rw
        cli._probe_inventory = orig_probe
        assert.is_true(ok, err)
        local text = table.concat(out_buf)
        assert.is_truthy(text:find("launcher: no line-ending rule", 1, true), text)
        vim.fn.delete(r, "rf")
    end)
end)
