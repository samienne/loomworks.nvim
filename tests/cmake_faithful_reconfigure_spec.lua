--- Tests for the cmake module's faithful reconfigure (cmake §5d "Retraction and
--- full reconfigure", core §5.1): every `-D` loomworks passes is recorded in
--- `module_info.passed_options`; a key passed last time but not now is retracted
--- with `-U<key>`; a first-configure-only key change escalates to `--fresh`
--- (CMake >= 3.24) or a core-run `pre_configure_reset` below 3.24.

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

local function ctx(overrides)
    local c = {
        name = "App",
        path = "App",
        workspace_root = "/fake/root",
        configurations = { Debug = { variant = "Debug", generator = "Ninja" } },
        type_config = {},
        tool_data = { generator = "Ninja", compiler_id = "gcc-13", cmake_path = "/fake/cmake" },
        cached_build_dir = "/fake/root/App/build",
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function configure(c)
    local t = find_configure(cmake.tasks(c, "Debug"))
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

    it("records nothing on the preset path", function()
        local t = find_configure(cmake.tasks({
            name = "App", path = "App", workspace_root = "/fake/root",
            configurations = { ["preset:dev"] = {
                from_preset = true, base_name = "dev",
                binary_dir = "/fake/root/App/out", variant = "Debug",
            } },
            type_config = {}, tool_data = { generator = "Ninja" },
            cached_build_dir = "/fake/root/App/out", configuration_key = "preset:dev",
            recorded_module_info = { passed_options = { FOO = "1" } },
        }, "preset:dev"))
        assert.is_nil(t.loomworks.module_info.passed_options)
        assert.same({}, u_args(t.builder().cmd))
    end)
end)

describe("cmake faithful reconfigure: -U retraction", function()
    before_each(function() cmake._cmake_version_cache = {} end)

    it("retracts a user option that was passed before and is now removed", function()
        local _, cmd = configure(ctx({
            recorded_module_info = { passed_options = {
                FOO = "1", CMAKE_BUILD_TYPE = "Debug", CMAKE_EXPORT_COMPILE_COMMANDS = "ON",
            } },
        }))
        assert.same({ "FOO" }, u_args(cmd))
        -- -U lands right after `-B <dir>`, ahead of every -D.
        local b = index_of(cmd, function(a) return a == "-B" end)
        assert.equals("-UFOO", cmd[b + 2])
        local first_d = index_of(cmd, function(a) return a:sub(1, 2) == "-D" end)
        assert.is_true(b + 2 < first_d)
        assert.is_false(has(cmd, "--fresh"))
    end)

    it("never retracts a key that is still passed", function()
        local _, cmd = configure(ctx({
            type_config = { options = { FOO = "2" } },
            recorded_module_info = { passed_options = { FOO = "1" } },
        }))
        assert.same({}, u_args(cmd))
    end)

    it("never retracts a key loomworks did not record (e.g. set in CMakeLists)", function()
        local _, cmd = configure(ctx({
            recorded_module_info = { passed_options = { CMAKE_BUILD_TYPE = "Debug" } },
        }))
        assert.same({}, u_args(cmd))
    end)

    it("a never-configured unit gets no -U", function()
        local _, cmd = configure(ctx({}))
        assert.same({}, u_args(cmd))
    end)

    it("turning caching off retracts the launcher, debug format and CMP0141 keys", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 27 }
        local _, cmd = configure(ctx({
            tool_data = MSVC,
            recorded_cache_launcher = "/usr/bin/sccache",
            recorded_module_info = { cache_launcher = "/usr/bin/sccache", passed_options = {
                CMAKE_C_COMPILER_LAUNCHER = "/usr/bin/sccache",
                CMAKE_CXX_COMPILER_LAUNCHER = "/usr/bin/sccache",
                CMAKE_MSVC_DEBUG_INFORMATION_FORMAT = "Embedded",
                CMAKE_POLICY_DEFAULT_CMP0141 = "NEW",
                CMAKE_BUILD_TYPE = "Debug",
            } },
        }))
        assert.same({
            "CMAKE_CXX_COMPILER_LAUNCHER", "CMAKE_C_COMPILER_LAUNCHER",
            "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT", "CMAKE_POLICY_DEFAULT_CMP0141",
        }, u_args(cmd))
    end)

    it("never retracts a reserved compiler key even if it was recorded", function()
        local _, cmd = configure(ctx({
            recorded_module_info = { passed_options = { CMAKE_CXX_COMPILER = "/x/g++" } },
        }))
        assert.same({}, u_args(cmd))
    end)

    it("skips a recorded key that would act as a -U glob", function()
        local _, cmd = configure(ctx({
            recorded_module_info = { passed_options = { ["WEIRD*"] = "1", GOOD = "1" } },
        }))
        assert.same({ "GOOD" }, u_args(cmd))
    end)
end)

describe("cmake faithful reconfigure: legacy record (no passed_options)", function()
    before_each(function() cmake._cmake_version_cache = {} end)

    -- The cmake §5d migration: an MSVC unit configured under the old `auto`
    -- (launcher injected, no passed_options record yet) must have the launcher
    -- and the injected /Z7 format retracted now that auto resolves to none.
    it("retracts the launcher + debug format implied by a recorded launcher", function()
        local _, cmd = configure(ctx({
            tool_data = MSVC,
            recorded_cache_launcher = "/usr/bin/sccache",
            recorded_module_info = { cache_launcher = "/usr/bin/sccache", generator = "Ninja" },
            recorded_options = {},
        }))
        assert.same({
            "CMAKE_CXX_COMPILER_LAUNCHER", "CMAKE_C_COMPILER_LAUNCHER",
            "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT",
        }, u_args(cmd))
    end)

    it("retracts removed options from core's snapshot, never reserved keys", function()
        local _, cmd = configure(ctx({
            recorded_cache_launcher = "none",
            recorded_module_info = { cache_launcher = "none" },
            recorded_options = { FOO = "1", CMAKE_CXX_COMPILER = "/x/g++" },
        }))
        assert.same({ "FOO" }, u_args(cmd))
    end)

    it("does not escalate to --fresh without an authoritative record", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 27 }
        local _, cmd = configure(ctx({
            tool_data = { generator = "Ninja", compiler_id = "gcc-13", cmake_path = "/fake/cmake",
                toolchain = "/tc.cmake" },
            recorded_options = { FOO = "1" },
        }))
        assert.is_false(has(cmd, "--fresh"))
    end)
end)

describe("cmake faithful reconfigure: full reconfigure", function()
    before_each(function() cmake._cmake_version_cache = {} end)

    local function tc_ctx(new_tc, prev_tc)
        return ctx({
            tool_data = { generator = "Ninja", compiler_id = "gcc-13", cmake_path = "/fake/cmake",
                toolchain = new_tc },
            recorded_module_info = { generator = "Ninja", passed_options = {
                CMAKE_TOOLCHAIN_FILE = prev_tc, CMAKE_BUILD_TYPE = "Debug", FOO = "1",
            } },
        })
    end

    it("a changed CMAKE_TOOLCHAIN_FILE uses --fresh on CMake >= 3.24 (no -U needed)", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 24 }
        local t, cmd = configure(tc_ctx("/new.cmake", "/old.cmake"))
        assert.equals("--fresh", cmd[2])
        assert.same({}, u_args(cmd))
        assert.is_nil(t.loomworks.pre_configure_reset)
    end)

    it("a removed CMAKE_TOOLCHAIN_FILE is a first-configure-only change too", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 30 }
        local _, cmd = configure(tc_ctx(nil, "/old.cmake"))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("below CMake 3.24 asks core to reset CMakeCache.txt + CMakeFiles instead", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 22 }
        local t, cmd = configure(tc_ctx("/new.cmake", "/old.cmake"))
        assert.is_false(has(cmd, "--fresh"))
        assert.same({ "CMakeCache.txt", "CMakeFiles" }, t.loomworks.pre_configure_reset)
    end)

    it("a generator change escalates to a full reconfigure", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 28 }
        local _, cmd = configure(ctx({
            recorded_module_info = { generator = "Unix Makefiles", passed_options = {} },
        }))
        assert.is_true(has(cmd, "--fresh"))
    end)

    it("an unchanged toolchain stays in place", function()
        cmake._cmake_version_cache["/fake/cmake"] = { major = 3, minor = 28 }
        local t, cmd = configure(tc_ctx("/same.cmake", "/same.cmake"))
        assert.is_false(has(cmd, "--fresh"))
        assert.is_nil(t.loomworks.pre_configure_reset)
        assert.same({ "FOO" }, u_args(cmd))
    end)
end)
