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

    describe("resolve_configurations", function()
        it("marks defaults with is_default and preserves variant", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}), {})
            assert.is_true(cfgs.Debug.is_default)
            assert.equals("Debug", cfgs.Debug.variant)
        end)

        it("merges user override on top and marks is_user", function()
            local defaults = meson.default_configurations("/tmp/x", {})
            local cfgs = meson.resolve_configurations(defaults, {
                configurations = {
                    Debug = { buildtype = "debug", options = { warning_level = 3 } },
                },
            })
            assert.is_true(cfgs.Debug.is_user)
            assert.equals(3, cfgs.Debug.options.warning_level)
            assert.equals("Debug", cfgs.Debug.variant)
        end)

        it("adds new user configs not in defaults (abstract unless variant given)", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = { CustomMixin = { options = { warning_level = 3 } } } })
            assert.is_not_nil(cfgs.CustomMixin)
            assert.is_nil(cfgs.CustomMixin.variant)  -- abstract
            assert.is_true(cfgs.CustomMixin.is_user)
        end)

        it("user config inheriting from a default picks up the variant", function()
            local cfgs = meson.resolve_configurations(
                meson.default_configurations("/tmp/x", {}),
                { configurations = { ["Debug-asan"] = { inherits = "Debug" } } })
            assert.equals("Debug", cfgs["Debug-asan"].variant)
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

        it("configure command embeds full prefix for python-mode tool_data", function()
            local py_project = vim.deepcopy(project)
            py_project.tool_data = { meson = { "/usr/bin/python3", "-m", "mesonbuild" } }
            local t = meson.tasks(py_project, "Debug")
            local cmd = t[1].builder().cmd
            assert.equals("/usr/bin/python3", cmd[1])
            assert.equals("-m", cmd[2])
            assert.equals("mesonbuild", cmd[3])
            assert.equals("setup", cmd[4])
        end)

        it("build command embeds full prefix for python-mode tool_data", function()
            local py_project = vim.deepcopy(project)
            py_project.tool_data = { meson = { "/usr/bin/python3", "-m", "mesonbuild" } }
            local t = meson.tasks(py_project, "Debug")
            local cmd = t[2].builder().cmd
            assert.equals("/usr/bin/python3", cmd[1])
            assert.equals("mesonbuild", cmd[3])
            assert.equals("compile", cmd[4])
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
        it("tool_key is nil (non-keyed)", function()
            assert.is_nil(meson.tool_key({}))
        end)

        it("tool_label reports 'meson' for direct binary", function()
            assert.equals("meson", meson.tool_label({ meson = { "/usr/bin/meson" } }))
        end)

        it("tool_label indicates python fallback when pip install", function()
            assert.equals(
                "meson (python -m mesonbuild)",
                meson.tool_label({ meson = { "/usr/bin/python3", "-m", "mesonbuild" } }))
        end)

        it("tool_label tolerates legacy string form from older caches", function()
            assert.equals("meson", meson.tool_label({ meson = "/usr/bin/meson" }))
        end)

        it("tools_match always true for non-keyed module", function()
            assert.is_true(meson.tools_match({}, { meson = { "/other/bin/meson" } }))
        end)
    end)

    describe("inspect", function()
        it("flags meson.build modified since last configure", function()
            local tmp = make_tmp_dir()
            write_file(tmp .. "/meson.build", "project('x', 'cpp')")
            -- Backdate last_configured to 2020
            local cached = { Debug = { last_configured = "2020-01-01T00:00:00Z" } }
            local r = meson.inspect(tmp, {}, cached)
            assert.is_true(r.needs_refresh)
            assert.is_true(#r.reasons > 0)
        end)

        it("does not flag when cache is ahead of files", function()
            local tmp = make_tmp_dir()
            write_file(tmp .. "/meson.build", "project('x', 'cpp')")
            local cached = { Debug = { last_configured = "2099-01-01T00:00:00Z" } }
            local r = meson.inspect(tmp, {}, cached)
            assert.is_false(r.needs_refresh)
        end)
    end)
end)
