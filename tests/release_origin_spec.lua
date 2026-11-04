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

    it("looks up the latest release in the legacy repository only", function()
        assert.equals("https://github.com/samienne/loomworks.nvim/releases/latest/download",
            origin.LATEST_DOWNLOAD)
        assert.equals("https://api.github.com/repos/samienne/loomworks.nvim/releases", origin.RELEASES_API)
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

    it("looks up the latest release and the releases API in the legacy repository only", function()
        assert.equals("https://github.com/samienne/loomworks.nvim/releases/latest/download",
            update.DEFAULT_RELEASE_URL)
        assert.equals("https://api.github.com/repos/samienne/loomworks.nvim/releases", update.RELEASES_API_URL)
        assert.equals(update.DEFAULT_RELEASE_URL, update.release_base())
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

    it("the previous launchers are a known generation that works for every 0.1 pin", function()
        local prev = {
            sh = "e320286c13d612f12424ff36e0219f18bb29b4924b997e5177b7ca23ed0c0b44",
            cmd = "2561fcb70a8ffa46f96577cb2105cf43ff875b7b9ba8d1f73fe04be619d366a5",
        }
        for kind, hash in pairs(prev) do
            local g = launcher.GENERATIONS[kind][hash]
            assert.truthy(g, kind)
            assert.same({}, g.defects, kind)
            -- the current template is never catalogued as an older generation
            local cur = vim.fn.sha256(launcher.normalize(kind == "sh" and launcher.LW_SH or launcher.LW_CMD))
            assert.is_nil(launcher.GENERATIONS[kind][cur], kind)
        end
    end)
end)
