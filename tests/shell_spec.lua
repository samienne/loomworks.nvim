--- Tests for the shell module — generic user-declared command runner.
--- Focuses on the unique shell behavior: variable expansion in
--- commands, build_dir template handling, lsp_configs forwarding,
--- and the never-auto-detect contract.

package.loaded["loomworks.modules.shell"] = nil
local shell = require("loomworks.modules.shell")
local uv = vim.uv or vim.loop

local function make_tmp_dir()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    return tmp
end

--- Build a minimal ModuleContext for tasks/clean_tasks tests.
local function make_ctx(opts)
    opts = opts or {}
    return {
        name = opts.name or "myproj",
        path = opts.path or "myproj",
        type = "shell",
        configuration = opts.active_config or "default",
        configuration_key = opts.configuration_key or "default",
        configurations = opts.configurations or { default = { variant = "default" } },
        tool_data = opts.tool_data,
        workspace_root = opts.workspace_root or "/work",
        env = opts.env or {},
        cached_build_dir = opts.cached_build_dir,
        type_config = opts.type_config or {},
        resolved_variables = opts.resolved_variables,
    }
end

describe("shell module", function()
    describe("identity", function()
        it("declares id and capability flags", function()
            assert.equals("shell", shell.id)
            assert.is_false(shell.has_keyed_tools)
            assert.is_false(shell.has_options)
            assert.is_false(shell.has_devices)
            assert.same({ "c++" }, shell.languages)
        end)
    end)

    describe("detect", function()
        it("never auto-detects — any directory could be 'shell'", function()
            local tmp = make_tmp_dir()
            assert.is_nil(shell.detect(tmp))
            assert.is_nil(shell.detect("/nonexistent"))
            assert.is_nil(shell.detect(""))
        end)
    end)

    describe("validate", function()
        it("warns on missing required fields when type_config is empty", function()
            local tmp = make_tmp_dir()
            local r = shell.validate(tmp, {})
            assert.is_true(r.valid)
            -- build_dir + configure_cmd + build_cmd
            assert.is_true(#r.warnings >= 3)
        end)

        it("warns on each missing required field individually", function()
            local tmp = make_tmp_dir()
            local r = shell.validate(tmp, { build_dir = "/x" })
            -- configure_cmd + build_cmd still missing
            assert.is_true(#r.warnings >= 2)
        end)

        it("no warnings on a fully declared shell block", function()
            local tmp = make_tmp_dir()
            local r = shell.validate(tmp, {
                build_dir = "${workspace_root}/out",
                configure_cmd = { "./script.sh" },
                build_cmd = { "./script.sh", "--fast" },
            })
            assert.equals(0, #r.warnings)
        end)
    end)

    describe("default_configurations", function()
        it("returns a single 'default' config", function()
            local cfgs = shell.default_configurations("/x", {})
            assert.is_not_nil(cfgs.default)
            assert.equals("variant", cfgs.default.prefix)
            assert.equals("default", cfgs.default.variant)
        end)
    end)

    describe("info", function()
        it("puts build_dir template into each config's module_config", function()
            local info = shell.info("/x", {
                build_dir = "${workspace_root}/out/${variant}",
            })
            local cfg = info.configurations["variant:default"]
            assert.is_not_nil(cfg)
            assert.equals("${workspace_root}/out/${variant}", cfg.module_config.build_dir)
            assert.equals("default", cfg.module_config.variant)
        end)

        it("preserves user-declared configurations alongside the default", function()
            local info = shell.info("/x", {
                build_dir = "${workspace_root}/out/${variant}",
                configurations = {
                    Debug   = { variables = { gn_args = "--debug" } },
                    Release = { variables = { gn_args = "--release" } },
                },
            })
            assert.is_not_nil(info.configurations.Debug)
            assert.is_not_nil(info.configurations.Release)
            -- User configs without explicit variant fall back to base_name
            assert.equals("Debug", info.configurations.Debug.variant)
        end)

        it("propagates variant from inherits chain when not set", function()
            local info = shell.info("/x", {
                build_dir = "${workspace_root}/out",
                configurations = {
                    Debug = { variant = "Debug" },
                    DebugAsan = { inherits = "Debug" },
                },
            })
            assert.equals("Debug", info.configurations.DebugAsan.variant)
        end)
    end)

    describe("resolve_build_dir", function()
        it("expands ${workspace_root}, ${project_path}, ${variant} in template", function()
            local out = shell.resolve_build_dir("myproj", "Debug",
                { build_dir = "${workspace_root}/out/${variant}" },
                "/ws", nil)
            assert.equals("/ws/out/Debug", out)
        end)

        it("supports project_path in template", function()
            local out = shell.resolve_build_dir("myproj", "Release",
                { build_dir = "${workspace_root}/${project_path}/out" },
                "/ws", nil)
            assert.equals("/ws/myproj/out", out)
        end)

        it("falls back to .nvim/build when no template provided", function()
            local out = shell.resolve_build_dir("myproj", "Debug", {}, "/ws", nil)
            assert.equals("/ws/.nvim/build/myproj/Debug", out)
        end)
    end)

    describe("tasks", function()
        it("emits configure + build tasks with expanded commands", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out/${variant}",
                    configure_cmd = { "./build.sh", "--all" },
                    build_cmd = { "./build.sh", "--fast" },
                },
            })
            local tasks = shell.tasks(ctx, "default")
            assert.equals(2, #tasks)
            assert.equals("configure", tasks[1].loomworks.action)
            assert.equals("build", tasks[2].loomworks.action)

            local cfg_spec = tasks[1].builder()
            assert.same({ "./build.sh", "--all" }, cfg_spec.cmd)
            local b_spec = tasks[2].builder()
            assert.same({ "./build.sh", "--fast" }, b_spec.cmd)
        end)

        it("expands ${variant} in commands", function()
            local ctx = make_ctx({
                active_config = "Debug",
                type_config = {
                    build_dir = "${workspace_root}/out/${variant}",
                    configure_cmd = { "./build.sh", "--config=${variant}" },
                    build_cmd = { "./build.sh", "--fast" },
                },
            })
            local tasks = shell.tasks(ctx, "Debug")
            local cfg_spec = tasks[1].builder()
            assert.same({ "./build.sh", "--config=Debug" }, cfg_spec.cmd)
        end)

        it("expands ${build_dir} in commands (computed from template)", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out/${variant}",
                    configure_cmd = { "./build.sh", "-B", "${build_dir}" },
                    build_cmd = { "ninja", "-C", "${build_dir}" },
                },
            })
            local tasks = shell.tasks(ctx, "default")
            local cfg_spec = tasks[1].builder()
            assert.same({ "./build.sh", "-B", "/work/out/default" }, cfg_spec.cmd)
        end)

        it("expands resolved_variables in commands", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out",
                    configure_cmd = { "./build.sh", "${gn_args}" },
                    build_cmd = { "./build.sh", "--fast", "${gn_args}" },
                },
                resolved_variables = {
                    gn_args = { value = "--debug", type = "string" },
                },
            })
            local tasks = shell.tasks(ctx, "default")
            local cfg_spec = tasks[1].builder()
            assert.same({ "./build.sh", "--debug" }, cfg_spec.cmd)
            local b_spec = tasks[2].builder()
            assert.same({ "./build.sh", "--fast", "--debug" }, b_spec.cmd)
        end)

        it("prefers cached_build_dir over re-expanding the template", function()
            local ctx = make_ctx({
                cached_build_dir = "/cached/path",
                type_config = {
                    build_dir = "${workspace_root}/out",
                    configure_cmd = { "echo", "${build_dir}" },
                    build_cmd = { "echo", "build" },
                },
            })
            local tasks = shell.tasks(ctx, "default")
            assert.same({ "echo", "/cached/path" }, tasks[1].builder().cmd)
        end)

        it("emits no tasks when configure_cmd / build_cmd are missing", function()
            local ctx = make_ctx({
                type_config = { build_dir = "/x" },
            })
            local tasks = shell.tasks(ctx, "default")
            assert.equals(0, #tasks)
        end)

        it("merges env with expansion", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out",
                    configure_cmd = { "./script" },
                    build_cmd = { "./script" },
                    env = { OUT = "${build_dir}" },
                },
            })
            local tasks = shell.tasks(ctx, "default")
            local spec = tasks[1].builder()
            assert.equals("/work/out", spec.env.OUT)
        end)
    end)

    describe("clean_tasks", function()
        it("uses clean_cmd when declared", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out",
                    configure_cmd = { "./script" },
                    build_cmd = { "./script" },
                    clean_cmd = { "./script", "--clean", "${build_dir}" },
                },
            })
            local tasks = shell.clean_tasks(ctx, "default")
            assert.equals(1, #tasks)
            local spec = tasks[1].builder()
            assert.same({ "./script", "--clean", "/work/out" }, spec.cmd)
        end)

        it("falls back to a platform-appropriate wipe when clean_cmd is absent", function()
            local ctx = make_ctx({
                type_config = {
                    build_dir = "${workspace_root}/out",
                    configure_cmd = { "./script" },
                    build_cmd = { "./script" },
                },
            })
            local tasks = shell.clean_tasks(ctx, "default")
            assert.equals(1, #tasks)
            local cmd = tasks[1].builder().cmd
            -- Build dir gets substituted into whichever portable wipe
            -- form runs on this platform.
            local joined = table.concat(cmd, " ")
            assert.is_truthy(joined:find("/work/out", 1, true))
        end)
    end)

    describe("tools (shim)", function()
        it("returns a single default tool with empty data", function()
            local tools = shell.detect_tools()
            assert.equals(1, #tools)
            assert.same({}, tools[1].tool_data)
        end)

        it("tools_match always true, tool_key/tool_label nil", function()
            assert.is_true(shell.tools_match({}, {}))
            assert.is_nil(shell.tool_key({}))
            assert.is_nil(shell.tool_label({}))
        end)
    end)

    describe("editable_type_config_fields", function()
        it("declares one row per editable shell field with the right kind", function()
            local fields = shell.editable_type_config_fields()
            local by_name = {}
            for _, f in ipairs(fields) do by_name[f.name] = f end

            -- Each kind drives a specific UI editor in projects.lua —
            -- the renderer dispatches on `kind`, so mismatches here
            -- silently produce "(unsupported kind: ...)" leaves.
            assert.equals("string",    by_name.build_dir.kind)
            assert.equals("cmd_array", by_name.configure_cmd.kind)
            assert.equals("cmd_array", by_name.build_cmd.kind)
            assert.equals("cmd_array", by_name.clean_cmd.kind)
            assert.equals("string",    by_name.compile_commands.kind)
            assert.equals("env_dict",  by_name.env.kind)
            assert.equals("string",    by_name.clangd.kind)
        end)
    end)

    describe("map_variant", function()
        it("single-config fallback returns the only config", function()
            assert.equals("default", shell.map_variant("debug", { "default" }))
            assert.equals("default", shell.map_variant("release", { "default" }))
        end)

        it("prefers name match across debug / release / RelWithDebInfo", function()
            assert.equals("Debug", shell.map_variant("debug", { "Debug", "Release" }))
            assert.equals("Release", shell.map_variant("release", { "Debug", "Release" }))
            assert.equals("RelWithDebInfo", shell.map_variant("release_debug",
                { "Debug", "Release", "RelWithDebInfo" }))
        end)
    end)

    describe("lsp_configs", function()
        local function fake_project(opts)
            opts = opts or {}
            local ws = {
                root = opts.ws_root or "/work",
                get_active_profile = function() return nil end,
            }
            return {
                key = opts.key or "myproj",
                path = opts.path or "myproj",
                type = "shell",
                type_config = opts.type_config or {},
                tool_data = opts.tool_data,
                cached = opts.cached or { build_dir = opts.build_dir or "/work/out" },
                variables = opts.variables,
                _workspace = ws,
            }
        end

        it("returns empty when compile_commands is unset", function()
            local cfgs = shell.lsp_configs(fake_project({
                type_config = { build_dir = "${workspace_root}/out" },
            }))
            assert.same({}, cfgs)
        end)

        it("emits a clangd entry with compile_commands_dir", function()
            local cfgs = shell.lsp_configs(fake_project({
                build_dir = "/work/out",
                type_config = {
                    build_dir = "${workspace_root}/out",
                    compile_commands = "${build_dir}/compile_commands.json",
                },
            }))
            assert.equals(1, #cfgs)
            assert.equals("clangd", cfgs[1].server)
            assert.equals("/work/out", cfgs[1].compile_commands_dir)
            assert.equals("/work/myproj", cfgs[1].root_dir)
        end)

        it("strips compile_commands.json suffix from compile_commands_dir", function()
            local cfgs = shell.lsp_configs(fake_project({
                build_dir = "/work/out",
                type_config = {
                    build_dir = "${workspace_root}/out",
                    compile_commands = "/abs/path/compile_commands.json",
                },
            }))
            assert.equals("/abs/path", cfgs[1].compile_commands_dir)
        end)

        it("accepts a bare directory path (no compile_commands.json suffix)", function()
            local cfgs = shell.lsp_configs(fake_project({
                build_dir = "/work/out",
                type_config = {
                    build_dir = "${workspace_root}/out",
                    compile_commands = "/abs/path",
                },
            }))
            assert.equals("/abs/path", cfgs[1].compile_commands_dir)
        end)

        it("prefers type_config.clangd binary override", function()
            local cfgs = shell.lsp_configs(fake_project({
                build_dir = "/work/out",
                type_config = {
                    clangd = "/opt/clang/bin/clangd",
                    build_dir = "${workspace_root}/out",
                    compile_commands = "${build_dir}/compile_commands.json",
                },
            }))
            assert.equals("/opt/clang/bin/clangd", cfgs[1].binary)
            assert.is_false(cfgs[1].binary_required)
        end)

        it("falls back to tool_data.clangd_path with binary_required honored", function()
            local cfgs = shell.lsp_configs(fake_project({
                build_dir = "/work/out",
                tool_data = {
                    clangd_path = "/sdk/clangd",
                    clangd_required = true,
                },
                type_config = {
                    build_dir = "${workspace_root}/out",
                    compile_commands = "${build_dir}/compile_commands.json",
                },
            }))
            assert.equals("/sdk/clangd", cfgs[1].binary)
            assert.is_true(cfgs[1].binary_required)
        end)
    end)
end)
