--- Tests for reserved compiler keys — the profile's tool owns the compiler.
---
--- Covers the shared `reserved_compiler` helper plus the strip-at-build
--- enforcement in the cmake and meson modules. Reject-at-edit
--- (`Project:save_configuration`) is exercised in integration_spec.lua where
--- a real Workspace/Project is already assembled.

local reserved = require("loomworks.reserved_compiler")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")

--- Join a wrapped/plain argv into one searchable string.
local function argv_str(cmd)
    return table.concat(cmd, " ")
end

--- Find a task by its loomworks.action tag.
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

describe("reserved_compiler helper", function()
    it("matches CMAKE_<LANG>_COMPILER option keys", function()
        assert.is_true(reserved.is_reserved_option("CMAKE_C_COMPILER"))
        assert.is_true(reserved.is_reserved_option("CMAKE_CXX_COMPILER"))
        assert.is_true(reserved.is_reserved_option("CMAKE_CUDA_COMPILER"))
        assert.is_true(reserved.is_reserved_option("CMAKE_Fortran_COMPILER"))
    end)

    it("does NOT match launcher/id/target/works neighbours", function()
        assert.is_false(reserved.is_reserved_option("CMAKE_CXX_COMPILER_LAUNCHER"))
        assert.is_false(reserved.is_reserved_option("CMAKE_CXX_COMPILER_ID"))
        assert.is_false(reserved.is_reserved_option("CMAKE_CXX_COMPILER_TARGET"))
        assert.is_false(reserved.is_reserved_option("CMAKE_CXX_COMPILER_WORKS"))
    end)

    it("does NOT match unrelated cache keys", function()
        assert.is_false(reserved.is_reserved_option("BUILD_TESTING"))
        assert.is_false(reserved.is_reserved_option("CMAKE_BUILD_TYPE"))
        assert.is_false(reserved.is_reserved_option("CFLAGS"))
        assert.is_false(reserved.is_reserved_option(nil))
    end)

    it("reserves exactly the compiler-driver env vars", function()
        for _, name in ipairs({ "CC", "CXX", "FC", "CUDACXX",
            "CUDAHOSTCXX", "OBJC", "OBJCXX", "ISPC" }) do
            assert.is_true(reserved.is_reserved_env(name), name)
        end
    end)

    it("does NOT reserve *FLAGS or launchers as env", function()
        assert.is_false(reserved.is_reserved_env("CFLAGS"))
        assert.is_false(reserved.is_reserved_env("CXXFLAGS"))
        assert.is_false(reserved.is_reserved_env("LDFLAGS"))
        assert.is_false(reserved.is_reserved_env("PATH"))
        assert.is_false(reserved.is_reserved_env(nil))
    end)
end)

describe("cmake strip-at-build", function()
    local root, build_dir

    before_each(function()
        root = vim.fn.tempname()
        build_dir = root .. "/build"
        vim.fn.mkdir(build_dir, "p")
    end)

    local GXX = "/usr/bin/g++"

    --- Ninja+gcc kit context with a hand-edited config carrying reserved
    --- keys in both options and env.
    local function ctx()
        return {
            name = "App",
            path = "App",
            workspace_root = root,
            configurations = {
                ["variant:Debug"] = {
                    variant = "Debug",
                    generator = "Ninja",
                    options = {
                        CMAKE_CXX_COMPILER = "smuggled-c++",
                        CMAKE_C_COMPILER = "smuggled-cc",
                        CMAKE_CXX_COMPILER_LAUNCHER = "ccache",
                        BUILD_TESTING = "ON",
                    },
                },
            },
            tool_data = { generator = "Ninja", compiler_path = GXX },
            env = { CXX = "smuggled-c++", CFLAGS = "-O2" },
            cached_build_dir = build_dir,
        }
    end

    it("strips reserved -D options but keeps the tool's compiler", function()
        local tasks = cmake.tasks(ctx(), "variant:Debug")
        local configure = find_task(tasks, "configure")
        local cmd = argv_str(configure.builder().cmd)

        -- The tool's managed compiler wins and is the ONLY compiler -D.
        assert.is_truthy(cmd:find("-DCMAKE_CXX_COMPILER=" .. GXX, 1, true), cmd)
        assert.is_nil(cmd:find("-DCMAKE_CXX_COMPILER=smuggled-c++", 1, true))
        assert.is_nil(cmd:find("-DCMAKE_C_COMPILER=smuggled-cc", 1, true))

        -- Non-reserved options (launcher, BUILD_TESTING) survive.
        assert.is_truthy(cmd:find("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache", 1, true), cmd)
        assert.is_truthy(cmd:find("-DBUILD_TESTING=ON", 1, true), cmd)
    end)

    it("strips reserved env vars but keeps non-reserved ones", function()
        local tasks = cmake.tasks(ctx(), "variant:Debug")
        local configure = find_task(tasks, "configure")
        local env = configure.builder().env

        assert.is_nil(env.CXX)
        assert.equals("-O2", env.CFLAGS)
    end)

    it("records the stripped keys as a diagnostic", function()
        local tasks = cmake.tasks(ctx(), "variant:Debug")
        local configure = find_task(tasks, "configure")
        local stripped = configure.loomworks.stripped_compiler_keys
        assert.is_not_nil(stripped)
        assert.same({ "CMAKE_CXX_COMPILER", "CMAKE_C_COMPILER" }, stripped.options)
        assert.same({ "CXX" }, stripped.env)
    end)

    it("records nothing when the config is clean", function()
        local c = ctx()
        c.configurations["variant:Debug"].options = { BUILD_TESTING = "ON" }
        c.env = { CFLAGS = "-O2" }
        local tasks = cmake.tasks(c, "variant:Debug")
        local configure = find_task(tasks, "configure")
        assert.is_nil(configure.loomworks.stripped_compiler_keys)
    end)

    it("strips layered options on a from_preset config; preset file untouched", function()
        local c = {
            name = "App",
            path = "App",
            workspace_root = root,
            configurations = {
                ["preset:dev"] = {
                    from_preset = true,
                    base_name = "dev",
                    binary_dir = build_dir,
                    options = { CMAKE_CXX_COMPILER = "smuggled-c++" },
                },
            },
            tool_data = nil,
            env = {},
            cached_build_dir = build_dir,
        }
        local tasks = cmake.tasks(c, "preset:dev")
        local configure = find_task(tasks, "configure")
        local cmd = argv_str(configure.builder().cmd)

        assert.is_truthy(cmd:find("--preset", 1, true))
        assert.is_truthy(cmd:find("dev", 1, true))
        assert.is_nil(cmd:find("-DCMAKE_CXX_COMPILER", 1, true), cmd)
        assert.same({ "CMAKE_CXX_COMPILER" },
            configure.loomworks.stripped_compiler_keys.options)
    end)
end)

describe("meson strip-at-build", function()
    it("strips config CXX from composed env; tool's pinned CXX retained", function()
        local tool_data = {
            compiler_path = "/usr/bin/g++",
            compiler_c_path = "/usr/bin/gcc",
        }
        local env, stripped = meson.compose_task_env(
            { CXX = "smuggled-c++", CFLAGS = "-O2" }, tool_data)

        -- Tool wins; the smuggled config CXX is gone.
        assert.equals("/usr/bin/g++", env.CXX)
        assert.equals("/usr/bin/gcc", env.CC)
        assert.equals("-O2", env.CFLAGS)
        assert.same({ "CXX" }, stripped)
    end)

    it("records the stripped env keys on the configure task", function()
        local root = vim.fn.tempname()
        local ctx = {
            name = "App",
            path = "App",
            workspace_root = root,
            configurations = { Debug = { buildtype = "debug" } },
            tool_data = {
                meson = { "meson" },
                compiler_path = "/usr/bin/g++",
                compiler_c_path = "/usr/bin/gcc",
            },
            env = { CXX = "smuggled-c++" },
            cached_build_dir = root .. "/build",
        }
        local tasks = meson.tasks(ctx, "Debug")
        local configure = find_task(tasks, "configure")
        assert.same({ "CXX" }, configure.loomworks.stripped_compiler_keys.env)

        -- The composed build env carries the tool's compiler, not the config's.
        assert.equals("/usr/bin/g++", configure.builder().env.CXX)
    end)
end)
