--- Tests for the meson module's compiler-cache launcher application (§5a, §11).
---
--- Exercises `meson.tasks()` with a core-resolved `compiler_cache` on the
--- project context: explicit CC/CXX wrapping, bare pinning when off, the
--- `--wipe`-on-launcher-change reconfigure (vs `--reconfigure` when unchanged
--- and vs first-time setup), and `module_info.cache_launcher` recording.

local meson = require("loomworks.modules.meson")

local function has_arg(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

--- A build dir that meson considers "already set up" (has meson-info/).
local function setup_build_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/meson-info", "p")
    return dir
end

local function ctx(overrides)
    local c = {
        name = "App",
        path = "app",
        workspace_root = "/root",
        tool_data = {
            meson = { "/usr/bin/meson" },
            compiler_c_path = "/usr/bin/gcc",
            compiler_path = "/usr/bin/g++",
        },
        configurations = { Debug = { buildtype = "debug" } },
        env = {},
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

-- ---------------------------------------------------------------------------
-- CC/CXX wrapping
-- ---------------------------------------------------------------------------
describe("meson compiler-cache CC/CXX wrapping", function()
    it("wraps the pinned CC/CXX when a launcher is resolved", function()
        local c = ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        local built = meson.tasks(c, "Debug")[1].builder()
        assert.equals("/usr/bin/ccache /usr/bin/gcc", built.env.CC)
        assert.equals("/usr/bin/ccache /usr/bin/g++", built.env.CXX)
    end)

    it("leaves the bare pinned compiler when no launcher is resolved", function()
        local built = meson.tasks(ctx({}), "Debug")[1].builder()
        assert.equals("/usr/bin/gcc", built.env.CC)
        assert.equals("/usr/bin/g++", built.env.CXX)
    end)

    it("records the launcher in configure module_info (or nil)", function()
        local c = ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        assert.equals("/usr/bin/ccache",
            meson.tasks(c, "Debug")[1].loomworks.module_info.cache_launcher)
        assert.is_nil(meson.tasks(ctx({}), "Debug")[1].loomworks.module_info.cache_launcher)
    end)
end)

-- ---------------------------------------------------------------------------
-- --wipe on launcher change (§5a / §11)
-- ---------------------------------------------------------------------------
describe("meson compiler-cache reconfigure mechanism", function()
    it("uses --wipe (not --reconfigure) when the launcher changed", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = nil, -- last configured with no launcher
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
    end)

    it("uses --reconfigure (not --wipe) when the launcher is unchanged", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "/usr/bin/ccache",
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--reconfigure"))
        assert.is_false(has_arg(cmd, "--wipe"))
    end)

    it("wipes when a launcher was removed (recorded set, now off)", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            recorded_cache_launcher = "/usr/bin/ccache", -- had one
            -- compiler_cache nil → now off
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
    end)

    it("first-time setup uses neither --wipe nor --reconfigure", function()
        local c = ctx({
            cached_build_dir = vim.fn.tempname(), -- does not exist
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = nil,
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_false(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
    end)

    it("--wipe preserves the -D options (buildtype survives)", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = nil,
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--buildtype=debug"))
    end)
end)
