--- Tests for cmake.kits_from_sdk — focused on the single-compiler
--- caps shape added for the C/C++ compiler SDK provider. Confirms
--- the function emits exactly one kit with CC/CXX env vars and the
--- expected tool_data fields when caps carry `compiler_path` without
--- a `platforms` or `toolchain_file` array.
---
--- The existing platform-cross-product path (used by ohos) is
--- exercised through the harmony test fixtures already; we don't
--- duplicate it here.

local cmake = require("loomworks.modules.cmake")

local function fake_sdk(key, display, version)
    return {
        key = key,
        sdk_version = function() return version end,
        sdk_type = function() return "cpp_compiler" end,
        display_name = function() return display end,
    }
end

describe("cmake.kits_from_sdk single-compiler shape", function()
    it("emits one kit with CC/CXX env and clangd_path", function()
        local kits = cmake.kits_from_sdk({
            compiler_path = "/opt/c/bin/clang++",
            cc_path = "/opt/c/bin/clang",
            clangd_path = "/opt/c/bin/clangd",
            compiler_id = "clang",
            compiler_version = "19.0.0",
            generator = "Ninja",
        }, fake_sdk("cpp_compiler-clang-19.0.0-harmony-clang",
            "Clang 19.0.0 (custom)", "19.0.0"))

        assert.equals(1, #kits)
        local td = kits[1].tool_data
        assert.equals("cpp_compiler-clang-19.0.0-harmony-clang", td.id)
        assert.equals("Clang 19.0.0 (custom)", td.display)
        assert.equals("Ninja", td.generator)
        assert.equals("/opt/c/bin/clang++", td.compiler_path)
        assert.equals("/opt/c/bin/clangd", td.clangd_path)
        assert.equals("clang", td.compiler_id)
        assert.equals("19.0.0", td.compiler_version)
        -- Env carries both CC and CXX so cmake picks the right
        -- compiler at configure time without us needing to write
        -- a toolchain file.
        assert.equals("/opt/c/bin/clang", td.env.CC)
        assert.equals("/opt/c/bin/clang++", td.env.CXX)
    end)

    it("omits CC env when cc_path is nil", function()
        -- A custom compiler where only the C++ driver could be
        -- resolved (sibling C driver missing). cmake gets only
        -- CXX; it'll use the same driver for C too in most cases.
        local kits = cmake.kits_from_sdk({
            compiler_path = "/opt/c/bin/g++",
            cc_path = nil,
            compiler_id = "gcc",
            compiler_version = "13.2.0",
            generator = "Ninja",
        }, fake_sdk("cpp_compiler-gcc-13.2.0-foo", "GCC 13.2.0 (custom)", "13.2.0"))

        assert.equals(1, #kits)
        local td = kits[1].tool_data
        assert.is_nil(td.env.CC)
        assert.equals("/opt/c/bin/g++", td.env.CXX)
    end)

    it("falls through to platforms branch when platforms is set", function()
        -- Make sure the single-compiler branch doesn't steal traffic
        -- intended for the existing platform-cross-product path.
        local kits = cmake.kits_from_sdk({
            cmake_path = "/usr/bin/cmake",
            platforms = {
                {
                    name = "HarmonyOS",
                    toolchain_file = "/sdk/ohos.toolchain.cmake",
                    archs = { "arm64-v8a" },
                },
            },
        }, fake_sdk("ohos-5.0.1", "HarmonyOS 5.0.1", "5.0.1"))

        assert.equals(1, #kits)
        -- Multi-platform kit identity: <sdk_type>-<platform_lower>-<arch>
        assert.equals("cpp_compiler-harmonyos-arm64-v8a", kits[1].tool_data.id)
    end)

    it("returns empty when caps is nil or has neither shape", function()
        assert.same({}, cmake.kits_from_sdk(nil, fake_sdk("x", "x", "x")))
        -- caps without compiler_path AND without platforms / toolchain_file
        assert.same({}, cmake.kits_from_sdk({
            cmake_path = "/usr/bin/cmake",
        }, fake_sdk("x", "x", "x")))
    end)
end)
