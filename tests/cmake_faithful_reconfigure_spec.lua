--- Tests for the cmake module's faithful reconfigure (cmake §5d "Full
--- reconfigure by default; in place only for the launcher keys", core §5.1):
--- every `-D` loomworks passes is recorded in `module_info.passed_options`; ANY
--- changed configure input (a -D added/changed/removed, the generator, the
--- configuration environment) — or a configured unit with no record — is a
--- full reconfigure (`--fresh` on CMake >= 3.24, a core-run
--- `pre_configure_reset` below it); only a change confined to the
--- compiler-launcher keys is applied in place (re-passed, or `-U` retracted).

local cmake = require("loomworks.modules.cmake")

local function find_configure(tasks)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == "configure" then return t end
    end
end

local function has(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

local function index_of(cmd, pred)
    for i, a in ipairs(cmd) do if pred(a) then return i end end
end

local function u_args(cmd)
    local out = {}
    for _, a in ipairs(cmd) do
        local k = a:match("^%-U(.+)$")
        if k then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

local MSVC = { generator = "Ninja", compiler_id = "msvc-17", cmake_path = "/fake/cmake" }
local GCC = { generator = "Ninja", compiler_id = "gcc-13", cmake_path = "/fake/cmake" }

local function ctx(overrides)
    local c = {
        name = "App",
        path = "App",
        workspace_root = "/fake/root",
        configurations = { Debug = { variant = "Debug", generator = "Ninja" } },
        type_config = {},
        tool_data = GCC,
        cached_build_dir = "/fake/root/App/build",
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function configure(c)
    local t = find_configure(cmake.tasks(c, "Debug"))
    return t, t.builder().cmd
end

--- The record a plain (no options, no cache) gcc/Ninja Debug configure passes.
local function base_record(extra)
    local r = { CMAKE_EXPORT_COMPILE_COMMANDS = "ON", CMAKE_BUILD_TYPE = "Debug" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

--- A unit configured with `passed` (authoritative record) under Ninja.
local function recorded(passed, extra)
    local rec = { generator = "Ninja", cache_launcher = "none", passed_options = passed }
    for k, v in pairs(extra or {}) do rec[k] = v end
    return rec
end

local function preset_ctx(overrides)
    local c = {
        name = "App", path = "App", workspace_root = "/fake/root",
        configurations = { ["preset:dev"] = {
            from_preset = true, base_name = "dev",
            binary_dir = "/fake/root/App/out", variant = "Debug",
        } },
        type_config = {}, tool_data = { generator = "Ninja", cmake_path = "/fake/cmake" },
        cached_build_dir = "/fake/root/App/out", configuration_key = "preset:dev",
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function preset_configure(c)
    local t = find_configure(cmake.tasks(c, "preset:dev"))
    return t, t.builder().cmd
end

describe("cmake faithful reconfigure: passed_options record", function()
    before_each(function() cmake._cmake_version_cache = {} end)

    it("records every -D the configure passes (name → value, type suffix stripped)", function()
        local t = configure(ctx({
            type_config = { options = { FOO = "1", ["BAR:BOOL"] = "ON" } },
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
        }))
        local rec = t.loomworks.module_info.passed_options
        assert.equals("1", rec.FOO)
        assert.equals("ON", rec.BAR)
        assert.equals("/usr/bin/ccache", rec.CMAKE_CXX_COMPILER_LAUNCHER)
        assert.equals("Debug", rec.CMAKE_BUILD_TYPE)
    end)

    it("records the user options appended on the preset path", function()
        local t = preset_configure(preset_ctx({
            type_config = { options = { FOO = "1" } },
        }))
        assert.same({ FOO = "1" }, t.loomworks.module_info.passed_options)
    end)

    it("records an empty (authoritative) set on a preset with no appended options", function()
        local t = preset_configure(preset_ctx())
        assert.same({}, t.loomworks.module_info.passed_options)
    end)
end)

describe("cmake faithful reconfigure: full reconfigure is the default", function()
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
    end)

    it("an unchanged record reconfigures in place (no --fresh, no -U)", function()
        local t, cmd = configure(ctx({
            type_config = { options = { FOO = "1" } },
            recorded_module_info = recorded(base_record({ FOO = "1" })),
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
        assert.is_nil(t.loomworks.pre_configure_reset)
    end)

    it("a REMOVED option uses --fresh (not -U)", function()
        local _, cmd = configure(ctx({
            recorded_module_info = recorded(base_record({ FOO = "1" })),
        }))
        assert.equals("--fresh", cmd[2])
        assert.same({}, u_args(cmd))
    end)

    it("a CHANGED option value uses --fresh", function()
        local _, cmd = configure(ctx({
            type_config = { options = { FOO = "2" } },
            recorded_module_info = recorded(base_record({ FOO = "1" })),
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("an ADDED option uses --fresh", function()
        local _, cmd = configure(ctx({
            type_config = { options = { FOO = "1" } },
            recorded_module_info = recorded(base_record()),
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("a changed CMAKE_TOOLCHAIN_FILE uses --fresh", function()
        local _, cmd = configure(ctx({
            tool_data = { generator = "Ninja", compiler_id = "gcc-13",
                cmake_path = "/fake/cmake", toolchain = "/new.cmake" },
            recorded_module_info = recorded(base_record({ CMAKE_TOOLCHAIN_FILE = "/old.cmake" })),
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("a generator change uses --fresh", function()
        local _, cmd = configure(ctx({
            recorded_module_info = recorded(base_record(), { generator = "Unix Makefiles" }),
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("below CMake 3.24 asks core to reset CMakeCache.txt + CMakeFiles instead", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 22 }
        local t, cmd = configure(ctx({
            recorded_module_info = recorded(base_record({ FOO = "1" })),
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({ "CMakeCache.txt", "CMakeFiles" }, t.loomworks.pre_configure_reset)
    end)

    it("a changed configuration environment uses --fresh", function()
        local _, cmd = configure(ctx({
            configuration_env = { CFLAGS = "-O1" },
            recorded_module_info = recorded(base_record(), { configure_env = { CFLAGS = "-O2" } }),
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("an environment that appeared on a unit recorded without one uses --fresh", function()
        local _, cmd = configure(ctx({
            configuration_env = { SCCACHE_DIR = "/c" },
            recorded_module_info = recorded(base_record()), -- no configure_env
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("no environment on either side stays in place", function()
        local _, cmd = configure(ctx({
            configuration_env = {},
            recorded_module_info = recorded(base_record()),
        }))
        assert.is_false(has(cmd, "--fresh"))
    end)

    it("an unchanged environment stays in place", function()
        local _, cmd = configure(ctx({
            configuration_env = { SCCACHE_DIR = "/c" },
            recorded_module_info = recorded(base_record(), { configure_env = { SCCACHE_DIR = "/c" } }),
        }))
        assert.is_false(has(cmd, "--fresh"))
    end)

    it("a configured unit with no passed_options record takes the full reconfigure", function()
        local _, cmd = configure(ctx({
            recorded_module_info = { generator = "Ninja" },
            recorded_options = {},
        }))
        assert.is_true(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
    end)

    it("a unit known only from core's option snapshot is also legacy → full", function()
        local _, cmd = configure(ctx({ recorded_options = { FOO = "1" } }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("a never-configured unit just configures", function()
        local t, cmd = configure(ctx({}))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
        assert.is_nil(t.loomworks.pre_configure_reset)
    end)
end)

describe("cmake faithful reconfigure: in place only for the launcher keys", function()
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
    end)

    local CC = "/usr/bin/ccache"
    local function with_launcher(p)
        return base_record({ CMAKE_C_COMPILER_LAUNCHER = p, CMAKE_CXX_COMPILER_LAUNCHER = p })
    end

    it("turning the cache off (gcc) retracts both launcher keys with -U in place", function()
        local _, cmd = configure(ctx({
            recorded_cache_launcher = CC,
            recorded_module_info = recorded(with_launcher(CC), { cache_launcher = CC }),
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({ "CMAKE_CXX_COMPILER_LAUNCHER", "CMAKE_C_COMPILER_LAUNCHER" }, u_args(cmd))
        -- -U lands right after `-B <dir>`, ahead of every -D.
        local b = index_of(cmd, function(a) return a == "-B" end)
        assert.is_truthy(cmd[b + 2]:match("^%-U"))
        local first_d = index_of(cmd, function(a) return a:sub(1, 2) == "-D" end)
        assert.is_true(b + 2 < first_d)
    end)

    it("turning the cache on (gcc) re-passes the launcher in place", function()
        local _, cmd = configure(ctx({
            compiler_cache = { tool = "ccache", path = CC },
            recorded_module_info = recorded(base_record()),
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
        assert.is_true(has(cmd, "-DCMAKE_CXX_COMPILER_LAUNCHER=" .. CC))
    end)

    it("a changed launcher path is applied in place", function()
        local _, cmd = configure(ctx({
            compiler_cache = { tool = "sccache", path = "/usr/bin/sccache" },
            recorded_module_info = recorded(with_launcher(CC), { cache_launcher = CC }),
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
    end)

    it("a launcher change combined with any other change takes the full path", function()
        local _, cmd = configure(ctx({
            type_config = { options = { FOO = "1" } },
            recorded_module_info = recorded(with_launcher(CC), { cache_launcher = CC }),
        }))
        assert.is_true(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
    end)

    it("MSVC cache off also drops the /Z7 + CMP0141 keys → full reconfigure", function()
        local _, cmd = configure(ctx({
            tool_data = MSVC,
            recorded_cache_launcher = "/usr/bin/sccache",
            recorded_module_info = recorded(base_record({
                CMAKE_C_COMPILER_LAUNCHER = "/usr/bin/sccache",
                CMAKE_CXX_COMPILER_LAUNCHER = "/usr/bin/sccache",
                CMAKE_MSVC_DEBUG_INFORMATION_FORMAT = "Embedded",
                CMAKE_POLICY_DEFAULT_CMP0141 = "NEW",
            }), { cache_launcher = "/usr/bin/sccache" }),
        }))
        assert.is_true(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
    end)

    it("the MSVC auto migration (legacy unit with a recorded launcher) is a full reconfigure", function()
        local _, cmd = configure(ctx({
            tool_data = MSVC,
            recorded_cache_launcher = "/usr/bin/sccache",
            recorded_module_info = { cache_launcher = "/usr/bin/sccache", generator = "Ninja" },
            recorded_options = {},
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)
end)

describe("cmake faithful reconfigure: preset configurations", function()
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
    end)

    it("an unchanged preset reconfigures in place", function()
        local _, cmd = preset_configure(preset_ctx({
            type_config = { options = { FOO = "1" } },
            recorded_module_info = { cache_launcher = "none", passed_options = { FOO = "1" } },
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({}, u_args(cmd))
    end)

    it("a removed appended option re-applies the preset with --fresh (never -U)", function()
        local _, cmd = preset_configure(preset_ctx({
            recorded_module_info = { cache_launcher = "none", passed_options = { FOO = "1" } },
        }))
        assert.is_true(has(cmd, "--fresh"))
        assert.is_true(has(cmd, "--preset"))
        assert.same({}, u_args(cmd))
    end)

    it("a changed environment re-applies the preset with --fresh", function()
        local _, cmd = preset_configure(preset_ctx({
            configuration_env = { FOO_DIR = "/b" },
            recorded_module_info = { cache_launcher = "none", passed_options = {},
                configure_env = { FOO_DIR = "/a" } },
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("below 3.24 the preset's binaryDir configure state is reset by core", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 21 }
        local t, cmd = preset_configure(preset_ctx({
            recorded_module_info = { cache_launcher = "none", passed_options = { FOO = "1" } },
        }))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({ "CMakeCache.txt", "CMakeFiles" }, t.loomworks.pre_configure_reset)
        assert.equals("/fake/root/App/out", t.loomworks.build_dir)
    end)

    it("a preset unit configured before the record existed takes the full path", function()
        local _, cmd = preset_configure(preset_ctx({
            recorded_module_info = { cache_launcher = "none" },
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)
end)
