--- Tests for cmake clang-cl support:
---   * cmake_kits emits one Ninja + clang-cl kit per detected MSVC install
---     (sourced from the shared loomworks.msvc module), with unique ids and the
---     paired install's vcvarsall / clangd_path.
---   * cmake.tasks configures a clang-cl kit as a Ninja build in the paired
---     MSVC vcvars environment, with clang-cl as BOTH the C and C++ compiler.
---
--- MSVC / clang-cl detection is stubbed on loomworks.msvc so the tests are
--- independent of the host toolchain.

package.loaded["loomworks.cmake_kits"] = nil
local cmake_kits = require("loomworks.cmake_kits")
local cmake = require("loomworks.modules.cmake")
local msvc = require("loomworks.msvc")
local cpp = require("loomworks.cpp_compilers")

local INSTALLS = {
    {
        id = "msvc-17-2022-community",
        display = "MSVC 17 2022 (Community)",
        vs_major = "17",
        version_line = "2022",
        product = "Community",
        vcvarsall = "C:/VS/Community/VC/Auxiliary/Build/vcvarsall.bat",
        arch = "x64",
        install_path = "C:/VS/Community",
    },
    {
        id = "msvc-17-2022-buildtools",
        display = "MSVC 17 2022 (BuildTools)",
        vs_major = "17",
        version_line = "2022",
        product = "BuildTools",
        vcvarsall = "C:/VS/BuildTools/VC/Auxiliary/Build/vcvarsall.bat",
        arch = "x64",
        install_path = "C:/VS/BuildTools",
    },
}

-- Community has a VS-bundled clang-cl (with sibling clangd); BuildTools falls
-- back to a standalone clang-cl (no clangd).
local CC_BY_INSTALL = {
    ["C:/VS/Community"] = {
        path = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe",
        version = "18.1.7",
        clangd_path = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clangd.exe",
    },
    ["C:/VS/BuildTools"] = {
        path = "C:/LLVM/bin/clang-cl.exe",
        version = "17.0.6",
        clangd_path = nil,
    },
}

describe("cmake_kits clang-cl kits (one per MSVC install)", function()
    local saved

    before_each(function()
        saved = {
            executable = vim.fn.executable,
            detect = msvc.detect,
            clang_cl_for = msvc.clang_cl_for,
            cpp_detect = cpp.detect,
        }
        ---@diagnostic disable: duplicate-set-field
        vim.fn.executable = function(n) return n == "ninja" and 1 or 0 end
        msvc.detect = function() return INSTALLS end
        msvc.clang_cl_for = function(inst) return CC_BY_INSTALL[inst.install_path] end
        cpp.detect = function() return {} end
        ---@diagnostic enable: duplicate-set-field
        cmake_kits.clear_cache()
    end)

    after_each(function()
        vim.fn.executable = saved.executable
        msvc.detect = saved.detect
        msvc.clang_cl_for = saved.clang_cl_for
        cpp.detect = saved.cpp_detect
        cmake_kits.clear_cache()
    end)

    it("emits a distinct clang-cl kit per install with paired vcvarsall/clangd", function()
        local kits = cmake_kits.detect()
        local clang = {}
        for _, k in ipairs(kits) do
            if k.id:match("^ninja%-clang%-cl%-") then clang[#clang + 1] = k end
        end
        assert.equals(2, #clang)

        local by_id = {}
        for _, k in ipairs(clang) do by_id[k.id] = k end

        local com = by_id["ninja-clang-cl-17-community"]
        local bt = by_id["ninja-clang-cl-17-buildtools"]
        assert.is_not_nil(com)
        assert.is_not_nil(bt)

        -- Bundled clang-cl (Community): compiler_path + sibling clangd + vcvars.
        assert.equals("Ninja", com.generator)
        assert.equals("clang-cl-18.1.7", com.compiler_id)
        assert.equals(CC_BY_INSTALL["C:/VS/Community"].path, com.compiler_path)
        assert.equals(CC_BY_INSTALL["C:/VS/Community"].clangd_path, com.clangd_path)
        assert.equals(INSTALLS[1].vcvarsall, com.vcvarsall)
        assert.equals("x64", com.arch)
        assert.equals("Ninja - clang-cl (MSVC 17 2022 (Community))", com.display)

        -- Standalone clang-cl (BuildTools): distinct id/version, no clangd,
        -- different vcvars env even though the driver may be shared.
        assert.equals("clang-cl-17.0.6", bt.compiler_id)
        assert.equals("C:/LLVM/bin/clang-cl.exe", bt.compiler_path)
        assert.is_nil(bt.clangd_path)
        assert.equals(INSTALLS[2].vcvarsall, bt.vcvarsall)
    end)

    it("omits clang-cl kits entirely when ninja is unavailable", function()
        vim.fn.executable = function() return 0 end -- no ninja
        cmake_kits.clear_cache()
        local kits = cmake_kits.detect()
        for _, k in ipairs(kits) do
            assert.is_nil(k.id:match("^ninja%-clang%-cl%-"))
        end
    end)
end)

describe("cmake clang-cl configure command", function()
    local root, build_dir

    before_each(function()
        root = vim.fn.tempname()
        build_dir = root .. "/build"
        vim.fn.mkdir(build_dir, "p")
    end)

    local CLANG_CL = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe"

    local function ctx()
        return {
            name = "App",
            path = "App",
            workspace_root = root,
            configurations = {
                ["variant:Debug"] = { variant = "Debug", generator = "Ninja" },
            },
            tool_data = {
                generator = "Ninja",
                compiler_path = CLANG_CL,
                vcvarsall = "C:/VS/Community/VC/Auxiliary/Build/vcvarsall.bat",
                arch = "x64",
            },
            cached_build_dir = build_dir,
        }
    end

    local function find_task(tasks, action)
        for _, t in ipairs(tasks) do
            if t.loomworks and t.loomworks.action == action then return t end
        end
        return nil
    end

    it("uses -G Ninja, clang-cl for both C and C++, exports compile_commands, vcvars-wrapped", function()
        local tasks = cmake.tasks(ctx(), "variant:Debug")
        local configure = find_task(tasks, "configure")
        assert.is_not_nil(configure)

        local cmd = configure.builder().cmd
        -- Wrapped into a vcvars .bat: { "cmd", "/C", <bat> }.
        assert.equals("cmd", cmd[1])
        local bat = cmd[3]
        local f = assert(io.open(bat, "r"))
        local contents = f:read("*a")
        f:close()

        assert.is_truthy(contents:find("-G", 1, true))
        assert.is_truthy(contents:find("Ninja", 1, true))
        assert.is_truthy(contents:find("-DCMAKE_C_COMPILER=" .. CLANG_CL, 1, true),
            "C compiler must be clang-cl:\n" .. contents)
        assert.is_truthy(contents:find("-DCMAKE_CXX_COMPILER=" .. CLANG_CL, 1, true),
            "C++ compiler must be clang-cl (same path as C):\n" .. contents)
        assert.is_truthy(contents:find("-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", 1, true))
        assert.is_truthy(contents:find("vcvarsall", 1, true),
            "configure must run inside the paired MSVC vcvars env:\n" .. contents)
    end)
end)
