--- Module / SDK / progress-parser ids come from workspace files, so the
--- registries must only ever load them from the runtime path — never through
--- `package.path`, whose default begins with `./?.lua` (a Lua file relative to
--- the current directory). Ids that are not plain identifiers are refused.
---
--- Fixtures are benign: each plugin file just sets a global flag and returns a
--- well-formed module table, so the assertions are "was this file loaded?".

local modules = require("loomworks.modules")
local sdks = require("loomworks.sdks")
local progress = require("loomworks.progress")
local API = require("loomworks.api_versions")

local uv = vim.uv or vim.loop

local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

--- A plugin file that records that it ran.
local function plugin_src(kind, id, flag)
    local api = kind == "sdks" and API.sdk or API.module
    return ("_G[%q] = true\nreturn { id = %q, api_version = %d }\n"):format(flag, id, api)
end

describe("configuration-named plugin loading", function()
    local saved_cwd, saved_notify, tmp

    before_each(function()
        saved_cwd = uv.cwd()
        saved_notify = vim.notify
        vim.notify = function() end
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        uv.chdir(saved_cwd)
        vim.notify = saved_notify
        vim.fn.delete(tmp, "rf")
    end)

    for _, kind in ipairs({ "modules", "sdks" }) do
        local reg = kind == "modules" and modules or sdks

        it(kind .. ": a plugin file relative to the cwd is not loaded", function()
            local id = "_cwd_probe_" .. kind
            local flag = "__lw_cwd_probe_" .. kind
            _G[flag] = nil
            write(tmp .. "/loomworks/" .. kind .. "/" .. id .. ".lua", plugin_src(kind, id, flag))
            uv.chdir(tmp)
            local got = reg.get(id)
            uv.chdir(saved_cwd)
            assert.is_nil(got)
            assert.is_nil(_G[flag], "cwd-relative " .. kind .. " file was executed")
            package.loaded["loomworks." .. kind .. "." .. id] = nil
        end)

        it(kind .. ": a plugin file on the runtime path is loaded", function()
            local id = "_rtp_probe_" .. kind
            local flag = "__lw_rtp_probe_" .. kind
            _G[flag] = nil
            local root = tmp .. "/plug"
            write(root .. "/lua/loomworks/" .. kind .. "/" .. id .. ".lua", plugin_src(kind, id, flag))
            vim.opt.rtp:append(root)
            local got = reg.get(id)
            vim.opt.rtp:remove(root)
            package.loaded["loomworks." .. kind .. "." .. id] = nil
            assert.is_table(got)
            assert.equals(id, got.id)
            assert.is_true(_G[flag])
            _G[flag] = nil
        end)

        for _, bad in ipairs({ "a.b", "../x", "x/y", "x\\y", "", "sp ace" }) do
            it(kind .. ": refuses the non-identifier id " .. vim.inspect(bad), function()
                local seen
                vim.notify = function(msg) seen = msg end
                -- A file matching the dotted spelling exists relative to the
                -- cwd; the refusal must happen before any lookup.
                write(tmp .. "/loomworks/" .. kind .. "/a/b.lua", "_G.__lw_dotted_probe = true\nreturn {}\n")
                uv.chdir(tmp)
                local got = reg.get(bad)
                uv.chdir(saved_cwd)
                assert.is_nil(got)
                assert.is_nil(_G.__lw_dotted_probe)
                assert.is_truthy(reg.rejected()[bad], "invalid id not reported as rejected")
                assert.matches("invalid id", reg.rejected()[bad], 1, true)
                assert.is_string(seen)
            end)
        end
    end

    it("progress: a parser relative to the cwd is not loaded", function()
        _G.__lw_cwd_progress = nil
        write(tmp .. "/loomworks/progress/_cwd_parser.lua",
            "_G.__lw_cwd_progress = true\nreturn function() end\n")
        uv.chdir(tmp)
        local got = progress.get("_cwd_parser")
        uv.chdir(saved_cwd)
        assert.is_nil(got)
        assert.is_nil(_G.__lw_cwd_progress)
    end)

    it("progress: refuses a non-identifier tool name", function()
        assert.is_nil(progress.get("../ninja"))
        assert.is_nil(progress.get("a.b"))
    end)

    it("progress: the built-in ninja parser still loads", function()
        assert.is_function(progress.get("ninja"))
    end)

    it("built-in modules and providers still load", function()
        assert.is_table(modules.get("cmake"))
        assert.is_table(modules.get("shell"))
        assert.is_true(vim.tbl_contains(modules.list(), "cmake"))
        assert.is_true(#sdks.list() >= 1)
        for _, id in ipairs(sdks.list()) do
            assert.is_table(sdks.get(id), "provider " .. id)
        end
    end)
end)
