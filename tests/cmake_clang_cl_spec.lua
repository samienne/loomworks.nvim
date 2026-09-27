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

-- VS-bundled clang-cl per install (Community has one, with sibling clangd),
-- and a standalone clang-cl on PATH (no clangd). The stub mirrors
-- `msvc.clang_cl_for`: bundled first, the standalone one only when the caller
-- allows the fallback for that install.
local BUNDLED = {
    ["C:/VS/Community"] = {
        path = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe",
        version = "18.1.7",
        clangd_path = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clangd.exe",
    },
}
local STANDALONE = {
    path = "C:/LLVM/bin/clang-cl.exe",
    version = "17.0.6",
    clangd_path = nil,
}
local function stub_clang_cl_for(bundled)
    return function(inst, opts)
        return bundled[inst.install_path] or (opts and opts.standalone and STANDALONE) or nil
    end
end

-- An old install listed after the newest one (the locator sorts newest first).
local VS2017 = {
    id = "msvc-15-2017-professional",
    display = "MSVC 15 2017 (Professional)",
    vs_major = "15",
    version_line = "2017",
    product = "Professional",
    vcvarsall = "C:/VS/2017/VC/Auxiliary/Build/vcvarsall.bat",
    arch = "x64",
    install_path = "C:/VS/2017",
}

describe("cmake_kits clang-cl kits (at most one per MSVC install)", function()
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
        msvc.clang_cl_for = stub_clang_cl_for(BUNDLED)
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

    local function clang_kits()
        local by_id, n = {}, 0
        for _, k in ipairs(cmake_kits.detect()) do
            if k.id:match("^ninja%-clang%-cl%-") then by_id[k.id] = k; n = n + 1 end
        end
        return by_id, n
    end

    it("emits a clang-cl kit for an install with a VS-bundled clang-cl, paired vcvarsall/clangd", function()
        local by_id = clang_kits()
        local com = by_id["ninja-clang-cl-17-community"]
        assert.is_not_nil(com)
        assert.equals("Ninja", com.generator)
        assert.equals("clang-cl-18.1.7", com.compiler_id)
        assert.equals(BUNDLED["C:/VS/Community"].path, com.compiler_path)
        assert.equals(BUNDLED["C:/VS/Community"].clangd_path, com.clangd_path)
        assert.equals(INSTALLS[1].vcvarsall, com.vcvarsall)
        assert.equals("x64", com.arch)
        assert.equals("Ninja - clang-cl (MSVC 17 2022 (Community))", com.display)
        -- BuildTools bundles none, and the standalone clang-cl pairs only with
        -- the newest install: no kit named after BuildTools.
        assert.is_nil(by_id["ninja-clang-cl-17-buildtools"])
    end)

    it("never names a clang-cl kit after an older install without a bundled clang-cl", function()
        -- Tester report: VS 2017 (no bundled clang-cl) got ninja-clang-cl-15-professional.
        msvc.detect = function() return { INSTALLS[1], VS2017 } end
        cmake_kits.clear_cache()
        local by_id, n = clang_kits()
        assert.equals(1, n)
        assert.is_not_nil(by_id["ninja-clang-cl-17-community"])
        assert.is_nil(by_id["ninja-clang-cl-15-professional"])
    end)

    it("a standalone clang-cl pairs with the newest install when that one bundles none", function()
        msvc.detect = function() return { INSTALLS[2], VS2017 } end -- BuildTools 2022, then 2017
        cmake_kits.clear_cache()
        local by_id, n = clang_kits()
        assert.equals(1, n)
        local bt = by_id["ninja-clang-cl-17-buildtools"]
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
