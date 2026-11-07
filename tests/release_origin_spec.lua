--- Tests for the release origin by version (boot.origin): lw below 0.2 is
--- published in samienne/loomworks.nvim, 0.2 and later (pre-releases included)
--- in samienne/loomworks. The lw.sh / lw.cmd launcher templates apply the same
--- rule to the version in lw.pin: their origin block is run through sh / cmd.exe
--- and must agree with the Lua rule.

local origin = require("boot.origin")
local launcher = require("boot.launcher")

local NEW = "samienne/loomworks"
local OLD = "samienne/loomworks.nvim"

local CASES = {
    { "0.1.50-beta.1", OLD },
    { "0.1.50", OLD },
    { "0.1.0", OLD },
    { "0.0.0-dev", OLD },
    { "0.2.0-beta.1", NEW },
    { "0.2.0", NEW },
    { "0.10.0", NEW },
    { "1.0.0", NEW },
    { "1.1.3", NEW },
}

--- The lines of `text` from the first one containing `first` through the first
--- one at or after it containing `last`, joined with `sep`.
local function excerpt(text, first, last, sep)
    local lines, inside = {}, false
    for line in (launcher.normalize(text) .. "\n"):gmatch("([^\n]*)\n") do
        if not inside and line:find(first, 1, true) then inside = true end
        if inside then
            lines[#lines + 1] = line
            if line:find(last, 1, true) and #lines > 1 then break end
        end
    end
    return table.concat(lines, sep)
end

describe("boot.origin", function()
    it("chooses the repository by version", function()
        for _, c in ipairs(CASES) do
            assert.equals(c[2], origin.release_repo(c[1]), c[1])
            assert.equals("https://github.com/" .. c[2], origin.release_origin(c[1]), c[1])
            assert.equals("https://github.com/" .. c[2] .. "/releases/download/v" .. c[1],
                origin.download_base(c[1]), c[1])
        end
    end)

    it("looks up the latest release in loomworks, with loomworks.nvim as the fallback", function()
        assert.equals("https://github.com/samienne/loomworks/releases/latest/download",
            origin.LATEST_DOWNLOAD)
        assert.equals("https://api.github.com/repos/samienne/loomworks/releases", origin.RELEASES_API)
        assert.equals("https://github.com/samienne/loomworks.nvim/releases/latest/download",
            origin.LEGACY_LATEST_DOWNLOAD)
        assert.equals("https://api.github.com/repos/samienne/loomworks.nvim/releases",
            origin.LEGACY_RELEASES_API)
    end)
end)

describe("boot.update fetches a version from the repository it was published in", function()
    -- boot.update is luvi code: stub the luvi-only modules it loads at require
    -- time (nothing here reaches them).
    local STUBBED = { "uv", "miniz", "openssl" }
    for _, name in ipairs(STUBBED) do
        if not package.loaded[name] then
            package.preload[name] = function() return name == "uv" and vim.uv or {} end
        end
    end
    local paths = require("boot.paths")
    local update = require("boot.update")
    for _, name in ipairs(STUBBED) do package.preload[name] = nil end
    local env, config, saved_getenv, saved_read_config

    before_each(function()
        env, config = {}, {}
        saved_getenv, saved_read_config = paths.getenv, paths.read_config
        paths.getenv = function(name) return env[name] end
        paths.read_config = function() return config end
    end)

    after_each(function()
        paths.getenv, paths.read_config = saved_getenv, saved_read_config
    end)

    it("uses the version's origin without an override", function()
        for _, c in ipairs(CASES) do
            assert.equals("https://github.com/" .. c[2] .. "/releases/download/v" .. c[1],
                update.versioned_base(c[1]), c[1])
        end
    end)

    it("looks up the latest release in loomworks first, loomworks.nvim second", function()
        assert.equals("https://github.com/samienne/loomworks/releases/latest/download",
            update.DEFAULT_RELEASE_URL)
        assert.equals("https://api.github.com/repos/samienne/loomworks/releases", update.RELEASES_API_URL)
        assert.equals("https://github.com/samienne/loomworks.nvim/releases/latest/download",
            update.LEGACY_RELEASE_URL)
        assert.equals("https://api.github.com/repos/samienne/loomworks.nvim/releases",
            update.LEGACY_RELEASES_API_URL)
        assert.equals(update.DEFAULT_RELEASE_URL, update.release_base())
    end)

    describe("resolves the newest release (spec 16.29)", function()
        local download = require("boot.download")
        local saved_fetch, served, asked
        local NEW_LATEST = "https://github.com/samienne/loomworks/releases/latest/download/manifest.json"
        local OLD_LATEST = "https://github.com/samienne/loomworks.nvim/releases/latest/download/manifest.json"
        local NEW_API = "https://api.github.com/repos/samienne/loomworks/releases"
        local OLD_API = "https://api.github.com/repos/samienne/loomworks.nvim/releases"
        local function not_found(url)
            return "curl failed (22) for " .. url .. ": curl: (22) The requested URL returned error: 404"
        end
        local function manifest(v) return '{"schema":1,"version":"' .. v .. '"}' end
        local function list(...)
            local out = {}
            for _, t in ipairs({ ... }) do out[#out + 1] = '{"draft":false,"tag_name":"v' .. t .. '"}' end
            return "[" .. table.concat(out, ",") .. "]"
        end

        before_each(function()
            served, asked = {}, {}
            saved_fetch = download.fetch
            download.fetch = function(url)
                asked[#asked + 1] = url
                local body = served[url]
                if type(body) == "string" then return body end
                return nil, body and body.err or not_found(url)
            end
        end)

        after_each(function() download.fetch = saved_fetch end)

        it("stable: takes loomworks' latest release", function()
            served[NEW_LATEST] = manifest("0.2.0")
            served[OLD_LATEST] = manifest("0.1.51")
            assert.equals("0.2.0", update.resolve_newest_version({ channel = "stable" }))
            assert.same({ NEW_LATEST }, asked)
        end)

        it("stable: falls back to loomworks.nvim while loomworks has no stable release", function()
            served[OLD_LATEST] = manifest("0.1.51")
            local v, err = update.resolve_newest_version({ channel = "stable" })
            assert.equals("0.1.51", v, err)
            -- Not found twice in loomworks (no manifest, no SHA256SUMS) = no stable release there.
            assert.same({ NEW_LATEST,
                "https://github.com/samienne/loomworks/releases/latest/download/SHA256SUMS", OLD_LATEST }, asked)
        end)

        it("stable: does not fall back when loomworks is unreachable", function()
            served[NEW_LATEST] = { err = "curl failed (28) for " .. NEW_LATEST .. ": timed out" }
            served[OLD_LATEST] = manifest("0.1.51")
            local v, err = update.resolve_newest_version({ channel = "stable" })
            assert.is_nil(v)
            assert.truthy(tostring(err):find("timed out", 1, true))
            assert.same({ NEW_LATEST }, asked)
        end)

        it("unstable: takes the highest version across both repositories", function()
            served[NEW_API] = list("0.2.0-beta.3", "0.2.0-beta.1")
            served[OLD_API] = list("0.1.51", "0.1.50")
            assert.equals("0.2.0-beta.3", update.resolve_newest_version({ channel = "unstable" }))
            served[NEW_API] = list()
            assert.equals("0.1.51", update.resolve_newest_version({ channel = "unstable" }))
            served[OLD_API] = list("0.1.52-beta.1", "0.1.51")
            served[NEW_API] = list("0.2.0-beta.1")
            assert.equals("0.2.0-beta.1", update.resolve_newest_version({ channel = "unstable" }))
        end)

        it("unstable: fails when either releases list cannot be read, naming it", function()
            served[OLD_API] = list("0.1.51")
            local v, err = update.resolve_newest_version({ channel = "unstable" })
            assert.is_nil(v)
            assert.truthy(tostring(err):find("releases of samienne/loomworks:", 1, true), err)
            served[OLD_API] = nil
            served[NEW_API] = list("0.2.0-beta.3")
            v, err = update.resolve_newest_version({ channel = "unstable" })
            assert.is_nil(v)
            assert.truthy(tostring(err):find("releases of samienne/loomworks.nvim:", 1, true), err)
        end)

        it("unstable: a list's versions count only when published in that list's repository", function()
            -- A plugin tag v0.2.0 in loomworks.nvim is not lw 0.2.0, and a
            -- 0.1.x tag in loomworks is not a release of this line.
            served[NEW_API] = list("0.2.0-beta.3", "0.1.99")
            served[OLD_API] = list("0.2.0", "0.1.51")
            assert.equals("0.2.0-beta.3", update.resolve_newest_version({ channel = "unstable" }))
            served[NEW_API] = list("0.1.99")
            assert.equals("0.1.51", update.resolve_newest_version({ channel = "unstable" }))
        end)

        local STRANDED = "is released at samienne/loomworks but this lw cannot update to it; "
            .. "reinstall with the install command in the README: https://github.com/samienne/loomworks#install"
        local NEW_SUMS = "https://github.com/samienne/loomworks/releases/latest/download/SHA256SUMS"
        local function sums(v)
            return ("0"):rep(64) .. "  lw-" .. v .. "-descriptor.json\n" .. ("1"):rep(64) .. "  lw-linux-x64\n"
        end

        it("stable: fails loudly when loomworks has a stable release without a manifest", function()
            served[NEW_SUMS] = sums("0.2.0")
            served[OLD_LATEST] = manifest("0.1.51")
            local v, err, info = update.resolve_newest_version({ channel = "stable" })
            assert.is_nil(v)
            assert.equals("lw 0.2.0 " .. STRANDED, err)
            assert.same({ stranded = true, version = "0.2.0" }, info)
            assert.same({ NEW_LATEST, NEW_SUMS }, asked) -- never falls back
        end)

        it("stable: names 0.2+ when the release's version is not in its SHA256SUMS", function()
            served[NEW_SUMS] = ("0"):rep(64) .. "  something-else\n"
            local _, err = update.resolve_newest_version({ channel = "stable" })
            assert.equals("lw 0.2+ " .. STRANDED, err)
        end)

        it("stable: does not fall back when the SHA256SUMS probe fails other than not-found", function()
            served[NEW_SUMS] = { err = "curl failed (22) for " .. NEW_SUMS ..
                ": curl: (22) The requested URL returned error: 502" }
            served[OLD_LATEST] = manifest("0.1.51")
            local v, err = update.resolve_newest_version({ channel = "stable" })
            assert.is_nil(v)
            assert.truthy(tostring(err):find("502", 1, true), err)
            assert.same({ NEW_LATEST, NEW_SUMS }, asked)
        end)

        it("stable: a server error is a failure, never a fallback", function()
            served[NEW_LATEST] = { err = "curl failed (22) for " .. NEW_LATEST ..
                ": curl: (22) The requested URL returned error: 503" }
            served[OLD_LATEST] = manifest("0.1.51")
            local v, err = update.resolve_newest_version({ channel = "stable" })
            assert.is_nil(v)
            assert.truthy(tostring(err):find("503", 1, true), err)
            assert.same({ NEW_LATEST }, asked)
        end)

        it("unstable: fails loudly when the newest loomworks release has no manifest asset", function()
            served[NEW_API] = '[{"draft":false,"tag_name":"v0.2.0-beta.9",'
                .. '"assets":[{"name":"SHA256SUMS"},{"name":"lw-linux-x64"}]},'
                .. '{"draft":false,"tag_name":"v0.2.0-beta.3","assets":[{"name":"manifest.json"}]}]'
            served[OLD_API] = list("0.1.51")
            local v, err, info = update.resolve_newest_version({ channel = "unstable" })
            assert.is_nil(v)
            assert.equals("lw 0.2.0-beta.9 " .. STRANDED, err)
            assert.same({ stranded = true, version = "0.2.0-beta.9" }, info)
            -- With the manifest asset (or no asset data) it resolves as usual.
            served[NEW_API] = '[{"draft":false,"tag_name":"v0.2.0-beta.9",'
                .. '"assets":[{"name":"manifest.json"}]}]'
            assert.equals("0.2.0-beta.9", update.resolve_newest_version({ channel = "unstable" }))
            served[NEW_API] = list("0.2.0-beta.9")
            assert.equals("0.2.0-beta.9", update.resolve_newest_version({ channel = "unstable" }))
        end)

        it("self-update reports the same loud failure on stable", function()
            served[NEW_SUMS] = sums("0.2.0")
            served[OLD_LATEST] = manifest("0.1.51")
            local res, err, info = update.self_update({ channel = "stable" })
            assert.is_nil(res)
            assert.equals("lw 0.2.0 " .. STRANDED, err)
            assert.same({ stranded = true, version = "0.2.0" }, info)
        end)

        it("self-update says when neither repository has a stable release", function()
            local res, err, info = update.self_update({ channel = "stable" })
            assert.is_nil(res)
            assert.truthy(tostring(err):find("404", 1, true), err)
            assert.same({ latest_not_found = true }, info)
            -- Another not-found (here: an override's) is not the two-repository lookup.
            env.LOOMWORKS_RELEASE_URL = "https://mirror.example/flat"
            res, err, info = update.self_update({ channel = "stable" })
            assert.is_nil(res)
            assert.is_nil(info)
        end)

        it("with an override asks only the override, on either channel", function()
            env.LOOMWORKS_RELEASE_URL = "https://mirror.example/flat"
            served["https://mirror.example/flat/manifest.json"] = manifest("0.1.50")
            for _, channel in ipairs({ "stable", "unstable" }) do
                asked = {}
                assert.equals("0.1.50", update.resolve_newest_version({ channel = channel }), channel)
                assert.same({ "https://mirror.example/flat/manifest.json" }, asked, channel)
            end
            -- A missing manifest at the override is an error, never a fallback.
            served["https://mirror.example/flat/manifest.json"] = nil
            asked = {}
            assert.is_nil((update.resolve_newest_version({ channel = "stable" })))
            assert.same({ "https://mirror.example/flat/manifest.json" }, asked)
        end)
    end)

    it("treats an override as one mirror for all versions", function()
        env.LOOMWORKS_RELEASE_URL = "https://mirror.example/o/r/releases/latest/download"
        for _, v in ipairs({ "0.1.49", "0.2.0-beta.1" }) do
            assert.equals("https://mirror.example/o/r/releases/download/v" .. v, update.versioned_base(v), v)
        end
        env.LOOMWORKS_RELEASE_URL = nil
        config["release-url"] = "https://mirror.example/flat"
        for _, v in ipairs({ "0.1.49", "0.2.0-beta.1" }) do
            assert.equals("https://mirror.example/flat", update.versioned_base(v), v)
        end
        assert.equals("/tmp/mirror", update.versioned_base("0.1.49", { url = "/tmp/mirror" }))
    end)
end)

describe("launcher templates choose the origin from lw.pin's version", function()
    it("build the download URL and the attestation repo from it", function()
        assert.is_nil(launcher.LW_SH:find("loomworks.nvim/releases", 1, true))
        assert.is_nil(launcher.LW_CMD:find("loomworks.nvim/releases", 1, true))
        assert.truthy(launcher.LW_SH:find('url="https://github.com/$repo/releases/download/v$version/$asset"', 1, true))
        assert.truthy(launcher.LW_SH:find('--repo "$repo"', 1, true))
        assert.truthy(launcher.LW_CMD:find('set "url=https://github.com/!repo!/releases/download/v!version!/%asset%"', 1, true))
        assert.truthy(launcher.LW_CMD:find("--repo !repo!", 1, true))
    end)

    it("lw.sh agrees with the Lua rule", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("sh not available")
            return
        end
        local block = excerpt(launcher.LW_SH, "# The repository the pinned version", "esac", "\n")
        assert.truthy(block:find("repo=", 1, true), "origin block found")
        for _, c in ipairs(CASES) do
            local script = "version='" .. c[1] .. "'\n" .. block .. '\nprintf %s "$repo"\n'
            local r = vim.system({ "sh", "-c", script }, { text = true }):wait()
            assert.equals(0, r.code, r.stderr)
            assert.equals(c[2], r.stdout, c[1])
        end
    end)

    it("lw.cmd agrees with the Lua rule", function()
        if vim.fn.has("win32") ~= 1 then
            pending("cmd.exe is Windows-only")
            return
        end
        local block = excerpt(launcher.LW_CMD, 'set "repo=', 'if "!version:~0,4!"=="0.1."', "\r\n")
        assert.truthy(block:find("0.0.", 1, true), "origin block found")
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local bat = dir .. "/origin.cmd"
        for _, c in ipairs(CASES) do
            local f = assert(io.open(bat, "wb"))
            f:write("@echo off\r\nsetlocal EnableExtensions EnableDelayedExpansion\r\n" ..
                'set "version=' .. c[1] .. '"\r\n' .. block .. "\r\necho !repo!\r\n")
            f:close()
            local r = vim.system({ "cmd.exe", "/d", "/c", (bat:gsub("/", "\\")) }, { text = true }):wait()
            assert.equals(0, r.code, r.stderr)
            assert.equals(c[2], vim.trim(r.stdout), c[1])
        end
        vim.fn.delete(dir, "rf")
    end)

    it("the previous launchers are a known generation that breaks on a 0.2 pin", function()
        local prev = {
            sh = "e320286c13d612f12424ff36e0219f18bb29b4924b997e5177b7ca23ed0c0b44",
            cmd = "2561fcb70a8ffa46f96577cb2105cf43ff875b7b9ba8d1f73fe04be619d366a5",
        }
        for kind, hash in pairs(prev) do
            local g = launcher.GENERATIONS[kind][hash]
            assert.truthy(g, kind)
            local breaks = false
            for _, d in ipairs(g.defects) do
                if d.severity == "breaks" and d.text:find("loomworks.nvim", 1, true) then breaks = true end
            end
            assert.is_true(breaks, kind)
            -- the current template is never catalogued as an older generation
            local cur = vim.fn.sha256(launcher.normalize(kind == "sh" and launcher.LW_SH or launcher.LW_CMD))
            assert.is_nil(launcher.GENERATIONS[kind][cur], kind)
        end
    end)
end)

describe("the legacy-origin launcher defect depends on the pin", function()
    local uv = vim.uv or vim.loop
    local pin = require("boot.pin")
    local lh = require("loomworks.launcher_health")
    local LEGACY = launcher.LEGACY_ORIGIN_DEFECT
    local MINOR = { severity = "minor", text = "no download retry" }
    local old_sh = "#!/bin/sh\n# an older launcher\n"
    local old_cmd = "@echo off\r\nrem an older launcher\r\n"
    local ksh = vim.fn.sha256(launcher.normalize(old_sh))
    local kcmd = vim.fn.sha256(launcher.normalize(old_cmd))

    before_each(function()
        launcher.GENERATIONS.sh[ksh] = { gen = 0, releases = "0.1.0-0.1.1", defects = { LEGACY } }
        launcher.GENERATIONS.cmd[kcmd] = { gen = 0, releases = "0.1.0-0.1.1", defects = { MINOR, LEGACY } }
    end)
    after_each(function()
        launcher.GENERATIONS.sh[ksh] = nil
        launcher.GENERATIONS.cmd[kcmd] = nil
    end)

    it("classify drops it for a legacy pin only", function()
        local sha = vim.fn.sha256
        for _, v in ipairs({ "0.1.50", "0.1.50-beta.1", "0.0.0-dev" }) do
            local c = launcher.classify("sh", old_sh, sha, v)
            assert.same({}, c.defects, v)
            assert.is_false(c.breaks, v)
            local m = launcher.classify("cmd", old_cmd, sha, v)
            assert.same({ MINOR }, m.defects, v)
            assert.is_false(m.breaks, v)
        end
        for _, v in ipairs({ "0.2.0-beta.1", "0.2.0", "1.0.0" }) do
            local c = launcher.classify("sh", old_sh, sha, v)
            assert.same({ LEGACY }, c.defects, v)
            assert.is_true(c.breaks, v)
        end
        -- no pin known: every defect stays
        assert.is_true(launcher.classify("sh", old_sh, sha).breaks)
    end)

    --- The health findings about launcher generations, for a pin of `version`
    --- next to the older launchers (no git repository: file checks only).
    local function findings(version)
        local d = uv.fs_mkdtemp((vim.fn.tempname():gsub("[^/\\]*$", "")) .. "lwroXXXXXX")
        d = ((uv.fs_realpath(d) or d):gsub("\\", "/"))
        local hashes = {}
        for _, a in pairs(pin.HOST_ASSETS) do hashes[a] = string.rep("a", 64) end
        hashes[pin.bundle_asset(version)] = string.rep("b", 64)
        local function put(name, text)
            local f = assert(io.open(d .. "/" .. name, "wb")); f:write(text); f:close()
        end
        put("lw.pin", pin.serialize(version, hashes))
        put("lw.sh", old_sh)
        put("lw.cmd", old_cmd)
        local items = lh.provider({ root = d })
        vim.fn.delete(d, "rf")
        local out = {}
        for _, i in ipairs(items) do
            if i.title:find("launcher written by lw", 1, true) then out[#out + 1] = i end
        end
        return out
    end

    it("health: a legacy pin reports no new defect", function()
        local items = findings("0.1.50")
        assert.equals(1, #items)  -- lw.cmd's earlier minor defect only
        assert.equals("info", items[1].kind)
        assert.truthy(items[1].title:find("lw.cmd", 1, true))
        assert.is_nil(items[1].title:find("loomworks.nvim", 1, true))
    end)

    it("health: a 0.2 pin reports it as breaking", function()
        local items = findings("0.2.0")
        assert.equals(2, #items)
        for _, i in ipairs(items) do
            assert.equals("suggestion", i.kind, i.title)
            assert.truthy(i.title:find("samienne/loomworks.nvim", 1, true), i.title)
        end
    end)
end)
