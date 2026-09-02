local meson = require("loomworks.modules.meson")
local uv = vim.uv or vim.loop

local function make_tmp_dir()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    return tmp
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

describe("meson module", function()
    describe("detect", function()
        it("detects a directory with meson.build", function()
            local tmp = make_tmp_dir()
            write_file(tmp .. "/meson.build", "project('x', 'cpp')")
            local hit = meson.detect(tmp)
            assert.is_not_nil(hit)
            assert.equals("meson.build", hit.marker)
        end)

        it("returns nil when no meson.build", function()
            local tmp = make_tmp_dir()
            assert.is_nil(meson.detect(tmp))
        end)
    end)

    describe("validate", function()
        it("warns when meson.build is missing", function()
            local tmp = make_tmp_dir()
            local r = meson.validate(tmp, {})
            assert.is_true(r.valid)
            assert.is_true(#r.warnings > 0)
        end)

        it("no warnings when meson.build present", function()
            local tmp = make_tmp_dir()
            write_file(tmp .. "/meson.build", "project('x', 'cpp')")
            local r = meson.validate(tmp, {})
            assert.is_true(r.valid)
            assert.equals(0, #r.warnings)
        end)
    end)

    describe("default_configurations", function()
        it("returns Debug/Release/RelWithDebInfo with buildtype mappings", function()
            local cfgs = meson.default_configurations("/tmp/x", {})
            assert.equals("debug", cfgs.Debug.buildtype)
            assert.equals("release", cfgs.Release.buildtype)
            assert.equals("debugoptimized", cfgs.RelWithDebInfo.buildtype)
        end)

        it("each default sets variant = name (concrete, not abstract)", function()
            local cfgs = meson.default_configurations("/tmp/x", {})
            assert.equals("Debug", cfgs.Debug.variant)
            assert.equals("Release", cfgs.Release.variant)
            assert.equals("RelWithDebInfo", cfgs.RelWithDebInfo.variant)
        end)
    end)

    describe("resolve_build_dir", function()
        -- Regression: canonical config names contain ':' (variant:Debug), which
        -- is invalid in a Windows path and broke `meson setup` (WinError 267).
        -- meson.resolve_build_dir sanitizes like cmake's.
        it("sanitizes ':' in the config name (variant:Debug -> variant_Debug)", function()
            local dir = meson.resolve_build_dir("App", "variant:Debug", nil, "/root", nil)
            assert.equals("/root/.nvim/build/App/variant_Debug", dir)
        end)

        it("strips every Windows-illegal char from path components", function()
            local dir = meson.resolve_build_dir('a:b', 'x<>:"|?*y', nil, "/root", nil)
            local tail = dir:sub(#"/root/.nvim/build/" + 1)
            assert.is_nil(tail:find('[<>:"|?*]'))
        end)

        it("scopes the build dir by compiler (compiler_id segment)", function()
            local dir = meson.resolve_build_dir("App", "variant:Debug", nil, "/root",
                { compiler_id = "gcc-14.2.0" })
            assert.equals("/root/.nvim/build/App/gcc-14.2.0/variant_Debug", dir)
        end)

        it("gives cl and clang-cl distinct build dirs for the same config", function()
            local cl = meson.resolve_build_dir("R", "variant:Debug", nil, "/root",
                { compiler_id = "msvc-17-2022-enterprise" })
            local clcl = meson.resolve_build_dir("R", "variant:Debug", nil, "/root",
                { compiler_id = "clang-cl-18.1.7" })
            assert.are_not.equal(cl, clcl)
            assert.equals("/root/.nvim/build/R/msvc-17-2022-enterprise/variant_Debug", cl)
        end)

        it("omits the compiler segment when tool_data has no id", function()
            local dir = meson.resolve_build_dir("App", "Debug", nil, "/root", {})
            assert.equals("/root/.nvim/build/App/Debug", dir)
        end)
    end)

    describe("resolve_configurations", function()
        it("emits canonical `variant:Debug` keys for defaults", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}), {})
            assert.is_not_nil(cfgs["variant:Debug"])
            assert.is_true(cfgs["variant:Debug"].is_default)
            assert.equals("Debug", cfgs["variant:Debug"].variant)
            assert.equals("variant", cfgs["variant:Debug"].prefix)
        end)

        it("user configs are standalone (NOT a silent override of variant:Debug)", function()
            -- Strict separation: a user "Debug" is its own thing,
            -- not a merge into `variant:Debug`. Old behaviour would
            -- have collapsed them into one entry.
            local defaults = meson.default_configurations("/tmp/x", {})
            local cfgs = meson.resolve_configurations(defaults, {
                configurations = {
                    Debug = { buildtype = "debug", options = { warning_level = 3 } },
                },
            })
            assert.is_not_nil(cfgs["variant:Debug"])
            assert.is_true(cfgs["variant:Debug"].is_default)
            assert.is_nil(cfgs["variant:Debug"].is_user)
            assert.is_nil(cfgs["variant:Debug"].options)
            -- User's Debug stands alone at the bare key
            assert.is_not_nil(cfgs.Debug)
            assert.is_true(cfgs.Debug.is_user)
            assert.is_nil(cfgs.Debug.prefix)
            assert.equals(3, cfgs.Debug.options.warning_level)
        end)

        it("user config with no inherits is abstract (no variant)", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = { CustomMixin = { options = { warning_level = 3 } } } })
            assert.is_not_nil(cfgs.CustomMixin)
            assert.is_nil(cfgs.CustomMixin.variant)  -- abstract
            assert.is_true(cfgs.CustomMixin.is_user)
        end)

        it("user config inheriting from `variant:Debug` picks up its variant", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = {
                    ["Debug-asan"] = { inherits = "variant:Debug" },
                } })
            assert.equals("Debug", cfgs["Debug-asan"].variant)
            assert.equals("debug", cfgs["Debug-asan"].buildtype)
        end)

        -- Regression: a user config whose NAME differs from its variant
        -- (e.g. "Tracy" with variant "Release"), declaring no `inherits` and
        -- no explicit `buildtype`, must derive its buildtype from the variant.
        -- Previously buildtype stayed nil, so M.tasks() fell back to the
        -- config NAME ("Tracy"), missed BUILDTYPE_BY_NAME, and built debug.
        it("user config with explicit variant derives buildtype from the variant", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = {
                    Tracy = { variant = "Release" },
                } })
            assert.is_not_nil(cfgs.Tracy)
            assert.equals("Release", cfgs.Tracy.variant)
            assert.equals("release", cfgs.Tracy.buildtype)
            -- Derived, not user-declared, so it is not written back to disk.
            assert.is_true(cfgs.Tracy._derived and cfgs.Tracy._derived.buildtype)
        end)

        -- End-to-end through M.tasks(): the derived buildtype must reach the
        -- `meson setup --buildtype=` argument.
        it("M.tasks() emits --buildtype=release for a variant-Release config", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = {
                    Tracy = { variant = "Release" },
                } })
            local t = meson.tasks({
                name = "App",
                path = "app",
                workspace_root = "/root",
                tool_data = { meson = { "/usr/bin/meson" } },
                configurations = cfgs,
                env = {},
            }, "Tracy")
            assert.equals("--buildtype=release", t[1].builder().cmd[4])
        end)
    end)

    describe("map_variant", function()
        it("maps debug → Debug", function()
            assert.equals("Debug", meson.map_variant("debug", { "Debug", "Release" }))
        end)

        it("maps release → Release", function()
            assert.equals("Release", meson.map_variant("release", { "Debug", "Release" }))
        end)

        it("maps release_debug → RelWithDebInfo when available", function()
            assert.equals("RelWithDebInfo",
                meson.map_variant("release_debug", { "Debug", "Release", "RelWithDebInfo" }))
        end)

        it("falls back when preferred name is absent", function()
            assert.equals("Debug", meson.map_variant("release", { "Debug" }))
        end)
    end)

    describe("tasks", function()
        local project = {
            name = "App",
            path = "app",
            workspace_root = "/root",
            tool_data = { meson = { "/usr/bin/meson" } },
            configurations = {
                Debug = { buildtype = "debug" },
                Custom = { buildtype = "debug", machine_file = "/tmp/cross.ini" },
            },
            env = {},
        }

        it("produces configure + build tasks", function()
            local t = meson.tasks(project, "Debug")
            assert.equals(2, #t)
            assert.equals("configure", t[1].loomworks.action)
            assert.equals("build", t[2].loomworks.action)
        end)

        it("configure command uses meson setup with --buildtype", function()
            local t = meson.tasks(project, "Debug")
            local cmd = t[1].builder().cmd
            assert.equals("/usr/bin/meson", cmd[1])
            assert.equals("setup", cmd[2])
            assert.equals("--buildtype=debug", cmd[4])
        end)

        it("build command uses meson compile -C", function()
            local t = meson.tasks(project, "Debug")
            local cmd = t[2].builder().cmd
            assert.equals("compile", cmd[2])
            assert.equals("-C", cmd[3])
        end)

        it("adds --cross-file when machine_file set on config", function()
            local t = meson.tasks(project, "Custom")
            local cmd = t[1].builder().cmd
            local found = false
            for _, arg in ipairs(cmd) do
                if arg:match("^%-%-cross%-file=") then found = true break end
            end
            assert.is_true(found)
        end)

        it("passes -D options from type_config.options", function()
            local proj2 = vim.deepcopy(project)
            proj2.type_config = { options = { warning_level = "3" } }
            local t = meson.tasks(proj2, "Debug")
            local cmd = t[1].builder().cmd
            local found_opt = false
            for _, arg in ipairs(cmd) do
                if arg == "-Dwarning_level=3" then found_opt = true end
            end
            assert.is_true(found_opt)
        end)

        --- Collect the -D args of a configure command.
        local function d_args(proj, config_name)
            local found = {}
            for _, arg in ipairs(meson.tasks(proj, config_name)[1].builder().cmd) do
                local k, v = arg:match("^%-D([^=]+)=(.*)$")
                if k then found[k] = v end
            end
            return found
        end

        -- Inheriting a base gave a config the base's variant but NOT its
        -- options: build_option_args merged project-wide + own only, never
        -- walking `inherits` (despite claiming to mirror cmake). A mixin whose
        -- whole purpose is to carry options therefore contributed nothing, so
        -- multi-base chains silently built without the options they named.
        it("merges options from an inherited base", function()
            local proj2 = vim.deepcopy(project)
            proj2.configurations = {
                ["variant:Release"] = { variant = "Release", buildtype = "release" },
                asan = { is_user = true, options = { b_sanitize = "address" } },
                RelAsan = {
                    is_user = true,
                    inherits = { "variant:Release", "asan" },
                    buildtype = "release",
                },
            }
            assert.equals("address", d_args(proj2, "RelAsan").b_sanitize)
        end)

        it("own options beat an inherited base's", function()
            local proj2 = vim.deepcopy(project)
            proj2.configurations = {
                base = { is_user = true, options = { warning_level = "1" } },
                child = {
                    is_user = true,
                    inherits = "base",
                    buildtype = "debug",
                    options = { warning_level = "3" },
                },
            }
            assert.equals("3", d_args(proj2, "child").warning_level)
        end)

        it("a later base beats an earlier one", function()
            local proj2 = vim.deepcopy(project)
            proj2.configurations = {
                first = { is_user = true, options = { warning_level = "1" } },
                second = { is_user = true, options = { warning_level = "2" } },
                child = { is_user = true, inherits = { "first", "second" }, buildtype = "debug" },
            }
            assert.equals("2", d_args(proj2, "child").warning_level)
        end)

        it("survives a circular inherits chain", function()
            local proj2 = vim.deepcopy(project)
            proj2.configurations = {
                a = { is_user = true, inherits = "b", options = { x = "1" } },
                b = { is_user = true, inherits = "a", buildtype = "debug" },
            }
            assert.equals("1", d_args(proj2, "a").x)
        end)
    end)

    describe("clean_tasks", function()
        it("produces a single --clean task", function()
            local t = meson.clean_tasks({
                name = "App", path = "app", workspace_root = "/root",
                tool_data = { meson = { "/usr/bin/meson" } }, env = {},
            }, "Debug")
            assert.equals(1, #t)
            local cmd = t[1].builder().cmd
            assert.equals("--clean", cmd[#cmd])
        end)
    end)

    describe("lsp_configs", function()
        it("emits a clangd entry with compile_commands_dir from cached build_dir", function()
            local project = {
                key = "App",
                path = "app",
                _workspace = { root = "/root" },
                cached = { build_dir = "/root/.nvim/build/App/Debug" },
                type_config = {},
            }
            local entries = meson.lsp_configs(project)
            assert.equals(1, #entries)
            assert.equals("clangd", entries[1].server)
            assert.equals("/root/.nvim/build/App/Debug", entries[1].compile_commands_dir)
            assert.equals("/root/app", entries[1].root_dir)
        end)

        it("applies user clangd override from type_config", function()
            local project = {
                key = "App", path = "app",
                _workspace = { root = "/root" },
                cached = { build_dir = "/root/.nvim/build/App/Debug" },
                type_config = { clangd = "/usr/local/bin/clangd" },
            }
            local entries = meson.lsp_configs(project)
            assert.equals("/usr/local/bin/clangd", entries[1].binary)
        end)
    end)

    describe("tool_key / tool_label / tools_match", function()
        local td_gcc = {
            meson = { "/usr/bin/meson" },
            compiler_id = "gcc-14.2.0",
            compiler_display = "GCC 14.2.0",
            compiler_path = "/usr/bin/g++",
        }
        local td_clang = {
            meson = { "/usr/bin/meson" },
            compiler_id = "clang-18.1.8",
            compiler_display = "Clang 18.1.8",
            compiler_path = "/usr/bin/clang++",
        }

        it("tool_key is compiler_id (keyed by toolchain identity)", function()
            assert.equals("gcc-14.2.0", meson.tool_key(td_gcc))
            assert.is_nil(meson.tool_key({}))
        end)

        it("tool_label reports the compiler display", function()
            assert.equals("GCC 14.2.0", meson.tool_label(td_gcc))
        end)

        it("tool_label falls back to 'meson' for legacy non-keyed data", function()
            assert.equals("meson", meson.tool_label({ meson = { "/usr/bin/meson" } }))
            assert.equals("meson", meson.tool_label({ meson = "/usr/bin/meson" }))
        end)

        it("tools_match is true iff compiler_path matches", function()
            assert.is_true(meson.tools_match(td_gcc, td_gcc))
            assert.is_false(meson.tools_match(td_gcc, td_clang))
        end)
    end)

    describe("parse_targets", function()
        local orig_system

        before_each(function()
            orig_system = vim.fn.system
        end)
        after_each(function()
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.system = orig_system
        end)

        local SAMPLE = [[
[
  {
    "name": "arrange_test",
    "type": "executable",
    "build_by_default": true,
    "filename": ["/build/arrange_test"],
    "target_sources": [
      {
        "language": "cpp",
        "sources": [
          "/src/arrange/test/constraint_test.cpp",
          "/src/arrange/test/diff_test.cpp"
        ]
      },
      { "language": null, "sources": [] }
    ]
  }
]
]]

        it("flattens target_sources[*].sources into a single list", function()
            local orig_exepath = vim.fn.exepath
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.exepath = function(n)
                if n == "meson" then return "/fake/meson" end
                return ""
            end
            -- parse_targets only introspects a *configured* tree (meson-info/).
            local uv = vim.uv or vim.loop
            local orig_fs_stat = uv.fs_stat
            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_stat = function(p)
                if p == "/build/meson-info" then return { type = "directory" } end
                return orig_fs_stat(p)
            end
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.system = function(cmd)
                -- Only answer the introspect --targets call with our
                -- fixture; anything else returns empty so we don't
                -- pretend to be a meson binary for unrelated probes.
                if type(cmd) == "table" then
                    for _, a in ipairs(cmd) do
                        if a == "--targets" then return SAMPLE end
                    end
                end
                return ""
            end

            local targets = meson.parse_targets({ build_dir = "/build" })

            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.exepath = orig_exepath
            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_stat = orig_fs_stat

            assert.is_not_nil(targets)
            local t = targets.arrange_test
            assert.is_not_nil(t)
            assert.are.same(
                {
                    "/src/arrange/test/constraint_test.cpp",
                    "/src/arrange/test/diff_test.cpp",
                },
                t.sources
            )
        end)

        it("returns nil without spawning when the build dir isn't configured", function()
            -- No meson-info/ → unconfigured tree. Must not spawn meson/python.
            local uv = vim.uv or vim.loop
            local orig_fs_stat = uv.fs_stat
            local orig_system = vim.fn.system
            local spawned = false
            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_stat = function(p)
                if p == "/unbuilt/meson-info" then return nil end
                return orig_fs_stat(p)
            end
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.system = function() spawned = true; return "" end

            local targets = meson.parse_targets({ build_dir = "/unbuilt" })

            ---@diagnostic disable-next-line: duplicate-set-field
            uv.fs_stat = orig_fs_stat
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.fn.system = orig_system

            assert.is_nil(targets)
            assert.is_false(spawned)
        end)
    end)
end)

describe("meson clang-cl (per MSVC install)", function()
    local msvc = require("loomworks.msvc")
    local cpp = require("loomworks.cpp_compilers")

    local INSTALLS = {
        {
            id = "msvc-17-2022-community", display = "MSVC 17 2022 (Community)",
            vs_major = "17", version_line = "2022", product = "Community",
            vcvarsall = "C:/VS/Community/VC/Auxiliary/Build/vcvarsall.bat",
            arch = "x64", install_path = "C:/VS/Community",
        },
        {
            id = "msvc-17-2022-buildtools", display = "MSVC 17 2022 (BuildTools)",
            vs_major = "17", version_line = "2022", product = "BuildTools",
            vcvarsall = "C:/VS/BuildTools/VC/Auxiliary/Build/vcvarsall.bat",
            arch = "x64", install_path = "C:/VS/BuildTools",
        },
    }
    -- Both installs fall back to the SAME standalone driver on purpose, to prove
    -- the per-install identity keeps them distinct tools.
    local CC = {
        path = "C:/LLVM/bin/clang-cl.exe", version = "18.1.7",
        clangd_path = "C:/LLVM/bin/clangd.exe",
    }

    local saved
    before_each(function()
        saved = {
            has = vim.fn.has, exepath = vim.fn.exepath,
            detect = msvc.detect, clang_cl_for = msvc.clang_cl_for,
            cpp_detect = cpp.detect,
        }
        ---@diagnostic disable: duplicate-set-field
        vim.fn.has = function(f) return f == "win32" and 1 or 0 end
        vim.fn.exepath = function(n) return n == "meson" and "C:/py/Scripts/meson.exe" or "" end
        msvc.detect = function() return INSTALLS end
        msvc.clang_cl_for = function(_inst) return CC end
        cpp.detect = function() return {} end
        ---@diagnostic enable: duplicate-set-field
    end)
    after_each(function()
        vim.fn.has = saved.has
        vim.fn.exepath = saved.exepath
        msvc.detect = saved.detect
        msvc.clang_cl_for = saved.clang_cl_for
        cpp.detect = saved.cpp_detect
    end)

    local function clang_tools()
        local out = {}
        for _, t in ipairs(meson.detect_tools()) do
            if t.tool_data.compiler_family == "clang-cl" then out[#out + 1] = t.tool_data end
        end
        return out
    end

    it("emits one clang-cl tool per install, distinct ids, carrying clangd_path", function()
        local clang = clang_tools()
        assert.equals(2, #clang)

        local by_id = {}
        for _, td in ipairs(clang) do by_id[td.compiler_id] = td end
        local com = by_id["clang-cl-18.1.7-17-community"]
        local bt = by_id["clang-cl-18.1.7-17-buildtools"]
        assert.is_not_nil(com)
        assert.is_not_nil(bt)

        -- Same driver, different vcvars env.
        assert.equals("C:/LLVM/bin/clang-cl.exe", com.compiler_path)
        assert.equals("C:/LLVM/bin/clang-cl.exe", com.cc)
        assert.equals("C:/LLVM/bin/clang-cl.exe", com.cxx)
        assert.equals("C:/LLVM/bin/clangd.exe", com.clangd_path)
        assert.equals("C:/VS/Community/VC/Auxiliary/Build/vcvarsall.bat", com.vcvarsall)
        assert.equals("C:/VS/BuildTools/VC/Auxiliary/Build/vcvarsall.bat", bt.vcvarsall)
        assert.equals("clang-cl 18.1.7 (MSVC 17 2022 (Community))", com.compiler_display)
    end)

    it("tools_match keeps same-driver clang-cl tools distinct via vcvarsall", function()
        local clang = clang_tools()
        assert.is_false(meson.tools_match(clang[1], clang[2]))
        assert.is_true(meson.tools_match(clang[1], clang[1]))
    end)

    it("clang-cl tool_data.clangd_path reaches lsp_configs as the clangd binary", function()
        local project = {
            key = "App", path = "app",
            _workspace = { root = "/root" },
            cached = { build_dir = "/root/.nvim/build/App/clang-cl" },
            type_config = {},
            tool_data = { clangd_path = "C:/LLVM/bin/clangd.exe" },
        }
        local entries = meson.lsp_configs(project)
        assert.equals(1, #entries)
        assert.equals("C:/LLVM/bin/clangd.exe", entries[1].binary)
    end)
end)
