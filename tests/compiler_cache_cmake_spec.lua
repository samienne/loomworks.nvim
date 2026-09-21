--- Tests for the cmake module's compiler-cache launcher application (§5d).
---
--- Exercises `cmake.tasks()` directly with a core-resolved `compiler_cache`
--- field on the project context: launcher `-D` injection (C + CXX),
--- conditional launcher ownership vs a user-set launcher, the MSVC `/Z7`
--- debug-format adjustment (version-gated + conflict), the preset non-goal,
--- and `module_info.cache_launcher` recording.

local cmake = require("loomworks.modules.cmake")

local function find_configure(tasks)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == "configure" then return t end
    end
end

local function d_value(cmd, key)
    for _, arg in ipairs(cmd) do
        local v = arg:match("^%-D" .. key .. "=(.*)$")
        if v then return v end
    end
end

local function d_count(cmd, key)
    local n = 0
    for _, arg in ipairs(cmd) do
        if arg:match("^%-D" .. key .. "=") then n = n + 1 end
    end
    return n
end

--- Build a Ninja single-config configure context. `overrides` replaces keys.
local function ninja_ctx(overrides)
    local ctx = {
        name = "App",
        path = "App",
        workspace_root = "/fake/root",
        configurations = { Debug = { variant = "Debug", generator = "Ninja" } },
        type_config = {},
        tool_data = { generator = "Ninja", compiler_id = "gcc-13" },
        cached_build_dir = "/fake/root/App/build",
    }
    for k, v in pairs(overrides or {}) do ctx[k] = v end
    return ctx
end

local function configure_cmd(ctx)
    return find_configure(cmake.tasks(ctx, "Debug")).builder().cmd
end

-- ---------------------------------------------------------------------------
-- Launcher injection
-- ---------------------------------------------------------------------------
describe("cmake compiler-cache launcher injection", function()
    it("injects CMAKE_C/CXX_COMPILER_LAUNCHER for a resolved launcher", function()
        local ctx = ninja_ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        local cmd = configure_cmd(ctx)
        assert.equals("/usr/bin/ccache", d_value(cmd, "CMAKE_C_COMPILER_LAUNCHER"))
        assert.equals("/usr/bin/ccache", d_value(cmd, "CMAKE_CXX_COMPILER_LAUNCHER"))
    end)

    it("records the launcher path in configure module_info", function()
        local ctx = ninja_ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        local t = find_configure(cmake.tasks(ctx, "Debug"))
        assert.equals("/usr/bin/ccache", t.loomworks.module_info.cache_launcher)
    end)

    it("injects nothing and records nil when no launcher is resolved", function()
        local ctx = ninja_ctx({})
        local t = find_configure(cmake.tasks(ctx, "Debug"))
        local cmd = t.builder().cmd
        assert.is_nil(d_value(cmd, "CMAKE_C_COMPILER_LAUNCHER"))
        assert.is_nil(d_value(cmd, "CMAKE_CXX_COMPILER_LAUNCHER"))
        assert.is_nil(t.loomworks.module_info.cache_launcher)
    end)

    it("does not touch MSVC debug format for a gcc kit", function()
        local ctx = ninja_ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        assert.is_nil(d_value(configure_cmd(ctx), "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
    end)
end)

-- ---------------------------------------------------------------------------
-- Conditional launcher ownership (§4f / §5d)
-- ---------------------------------------------------------------------------
describe("cmake compiler-cache launcher ownership", function()
    it("the feature's launcher WINS over a user-set one (dropped)", function()
        local ctx = ninja_ctx({
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
            type_config = { options = { CMAKE_CXX_COMPILER_LAUNCHER = "/opt/mine" } },
        })
        local cmd = configure_cmd(ctx)
        -- Exactly one launcher flag, and it's ours.
        assert.equals(1, d_count(cmd, "CMAKE_CXX_COMPILER_LAUNCHER"))
        assert.equals("/usr/bin/sccache", d_value(cmd, "CMAKE_CXX_COMPILER_LAUNCHER"))
    end)

    it("a user launcher passes through when no cache is resolved", function()
        local ctx = ninja_ctx({
            type_config = { options = { CMAKE_CXX_COMPILER_LAUNCHER = "/opt/mine" } },
        })
        assert.equals("/opt/mine", d_value(configure_cmd(ctx), "CMAKE_CXX_COMPILER_LAUNCHER"))
    end)
end)

-- ---------------------------------------------------------------------------
-- MSVC /Z7 handling (§5d)
-- ---------------------------------------------------------------------------
describe("cmake compiler-cache MSVC debug format", function()
    before_each(function() cmake._cmake_version_cache = {} end)

    it("injects Embedded (/Z7) for MSVC single-config with cmake >= 3.25", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 27 }
        local ctx = ninja_ctx({
            tool_data = { generator = "Ninja", compiler_id = "msvc-17", cmake_path = "/fake/cmake" },
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
        })
        assert.equals("Embedded",
            d_value(configure_cmd(ctx), "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
    end)

    it("skips Embedded below cmake 3.25", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 20 }
        local ctx = ninja_ctx({
            tool_data = { generator = "Ninja", compiler_id = "msvc-17", cmake_path = "/fake/cmake" },
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
        })
        assert.is_nil(d_value(configure_cmd(ctx), "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
    end)

    it("keeps a user's conflicting debug format (does not override)", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 27 }
        local ctx = ninja_ctx({
            tool_data = { generator = "Ninja", compiler_id = "msvc-17", cmake_path = "/fake/cmake" },
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
            type_config = { options = { CMAKE_MSVC_DEBUG_INFORMATION_FORMAT = "ProgramDatabase" } },
        })
        assert.equals("ProgramDatabase",
            d_value(configure_cmd(ctx), "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
    end)

    it("clang-cl is treated as MSVC-style for /Z7", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 27 }
        local ctx = ninja_ctx({
            tool_data = { generator = "Ninja", compiler_id = "clang-cl-17.0.0", cmake_path = "/fake/cmake" },
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
        })
        assert.equals("Embedded",
            d_value(configure_cmd(ctx), "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
    end)
end)

-- ---------------------------------------------------------------------------
-- Preset non-goal (§5d)
-- ---------------------------------------------------------------------------
describe("cmake compiler-cache preset non-goal", function()
    it("does not inject a launcher for a preset config, records nil", function()
        local ctx = {
            name = "App",
            path = "App",
            workspace_root = "/fake/root",
            configurations = {
                ["preset:dev"] = {
                    from_preset = true,
                    base_name = "dev",
                    binary_dir = "/fake/root/App/out",
                    variant = "Debug",
                },
            },
            type_config = {},
            tool_data = { generator = "Ninja" },
            cached_build_dir = "/fake/root/App/out",
            configuration_key = "preset:dev",
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
        }
        local t = find_configure(cmake.tasks(ctx, "preset:dev"))
        local cmd = t.builder().cmd
        assert.is_nil(d_value(cmd, "CMAKE_C_COMPILER_LAUNCHER"))
        assert.is_nil(d_value(cmd, "CMAKE_CXX_COMPILER_LAUNCHER"))
        assert.is_nil(t.loomworks.module_info.cache_launcher)
    end)
end)
