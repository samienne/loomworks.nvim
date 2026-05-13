--- loomworks/modules/shell.lua — Generic shell-command runner.
---
--- Wraps user-declared configure/build/clean commands. Owns no build-
--- system knowledge — every project-specific detail comes from
--- `type_config.shell.*` plus the project's variable system. Intended
--- for self-managed builds (custom scripts, Make-based projects,
--- vendor toolchains) that don't warrant a bespoke module.

local M = {}

M.id = "shell"
M.has_keyed_tools = false
M.has_options = false
M.has_devices = false
M.languages = { "c++" }

local uv = vim.uv or vim.loop
local expand = require("loomworks.expand")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build an expansion context from a ModuleContext + active variant.
--- Layers built-ins, then resolved project variables (which may
--- reference built-ins via two-pass expansion), then optionally
--- `build_dir` once the caller has resolved it.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table<string, string>
local function build_ctx(project, active_config)
    local ctx = {
        workspace_root = project.workspace_root,
        project_path = project.path or project.name,
        variant = active_config,
    }
    local resolved = project.resolved_variables
    if resolved then
        for name, entry in pairs(resolved) do
            ctx[name] = expand.expand_string(entry.value, ctx)
        end
    end
    return ctx
end

--- The shell module's type_config IS the user's `shell:` block — the
--- inner key under each project entry becomes `project.type_config`
--- (see `config.lua` `_extract_type`). So `build_dir`, `configure_cmd`,
--- etc. live directly on `project.type_config`, not nested under a
--- second `shell` key.
--- @param project loomworks.ModuleContext
--- @return table
local function shell_block(project)
    return project.type_config or {}
end

--- Expand a command array.
--- @param cmd string[]|nil
--- @param ctx table
--- @return string[]|nil
local function expand_cmd(cmd, ctx)
    if type(cmd) ~= "table" or #cmd == 0 then return nil end
    return expand.expand_array(cmd, ctx)
end

--- Resolve the env table for tasks.
--- @param project loomworks.ModuleContext
--- @param ctx table
--- @return table<string, string>|nil
local function resolve_env(project, ctx)
    local env = {}
    for k, v in pairs(project.env or {}) do env[k] = v end
    local tc = shell_block(project)
    if type(tc.env) == "table" then
        for k, v in pairs(tc.env) do
            if type(v) == "string" then
                env[k] = expand.expand_string(v, ctx)
            end
        end
    end
    return next(env) and env or nil
end

--- Resolve the build_dir for `tasks()` / `clean_tasks()`.
--- Prefers core's cached value (which came from resolve_build_dir).
--- Falls back to live expansion of the user-declared build_dir
--- template, then to the standard .nvim/build path so the module is
--- never crippled.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @param ctx table
--- @return string
local function resolve_build_dir_for_tasks(project, active_config, ctx)
    if project.cached_build_dir then return project.cached_build_dir end
    local tc = shell_block(project)
    if type(tc.build_dir) == "string" and tc.build_dir ~= "" then
        return expand.expand_string(tc.build_dir, ctx)
    end
    return project.workspace_root .. "/.nvim/build/" .. project.name .. "/" .. active_config
end

-- ---------------------------------------------------------------------------
-- Module interface — detection / validation
-- ---------------------------------------------------------------------------

--- The shell module never auto-detects. Projects are manually declared
--- in loomworks.json — "any directory" is not a meaningful marker.
function M.detect(_abs_path)
    return nil
end

--- Validate a shell project's type_config.
--- The `config` parameter IS the `shell:` block from loomworks.json.
--- @param path string
--- @param config table
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}
    config = config or {}
    if type(config.build_dir) ~= "string" or config.build_dir == "" then
        warnings[#warnings + 1] = "build_dir is required"
    end
    if type(config.configure_cmd) ~= "table" or #config.configure_cmd == 0 then
        warnings[#warnings + 1] = "configure_cmd is required"
    end
    if type(config.build_cmd) ~= "table" or #config.build_cmd == 0 then
        warnings[#warnings + 1] = "build_cmd is required"
    end
    if not uv.fs_stat(path) then
        warnings[#warnings + 1] = "project path does not exist: " .. path
    end
    return { valid = true, warnings = warnings }
end

-- ---------------------------------------------------------------------------
-- Configurations
-- ---------------------------------------------------------------------------

M.default_config_prefix = "variant"

--- Single default configuration. The user adds Debug/Release/etc.
--- under `configurations` to get more.
function M.default_configurations(_path, _config)
    return { default = { prefix = "variant", variant = "default" } }
end

function M.info(path, config)
    local Configuration = require("loomworks.configuration")
    config = config or {}
    local auto = M.default_configurations(path, config)
    local configurations = Configuration.canonicalize(
        auto, config.configurations, M.id)

    -- Propagate variant from inherits + fill in `module_config.build_dir`
    -- so the core's _compute_build_dir picks up the user's template
    -- without needing to crack open type_config. Built-in vars only
    -- (no user-declared variable refs in build_dir templates).
    for name, cfg in pairs(configurations) do
        if not cfg.variant and cfg.inherits then
            local bases = type(cfg.inherits) == "string"
                and { cfg.inherits } or cfg.inherits
            for _, base_name in ipairs(bases) do
                local base = configurations[base_name]
                if base and base.variant then
                    cfg.variant = base.variant
                    break
                end
            end
        end
        if not cfg.variant then
            cfg.variant = (cfg.base_name or name)
        end

        cfg.module_config = cfg.module_config or {}
        if config.build_dir and not cfg.module_config.build_dir then
            cfg.module_config.build_dir = config.build_dir
        end
        cfg.module_config.variant = cfg.variant
    end

    return { configurations = configurations }
end

-- ---------------------------------------------------------------------------
-- Tools (none — single default)
-- ---------------------------------------------------------------------------

function M.detect_tools()
    return { { tool_data = {} } }
end

function M.detect_tools_async(callback)
    callback({ { tool_data = {} } })
end

function M.tools_match(_a, _b)
    return true
end

function M.tool_key(_tool_data)
    return nil
end

function M.tool_label(_tool_data)
    return nil
end

--- Map a semantic variant to a configuration name.
function M.map_variant(variant_type, available_configs)
    if #available_configs == 1 then
        return available_configs[1]
    end
    local targets = {
        debug = { "Debug", "debug", "default" },
        release = { "Release", "release", "default" },
        release_debug = { "RelWithDebInfo", "release_debug" },
    }
    local candidates = targets[variant_type]
    if not candidates then return nil end
    for _, target in ipairs(candidates) do
        for _, config in ipairs(available_configs) do
            if config == target then return config end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Build directory
-- ---------------------------------------------------------------------------

--- Resolve the build directory.
--- Called by core's `Workspace:_compute_build_dir`. `config_info` is
--- the active Configuration's `module_config` (populated by `info()`
--- with `build_dir` and `variant`).
--- @param project_name string
--- @param config_name string|nil
--- @param config_info table|nil module_config
--- @param workspace_root string
--- @param _tool_data table|nil
--- @return string
function M.resolve_build_dir(project_name, config_name, config_info, workspace_root, _tool_data)
    local template = config_info and config_info.build_dir
    if type(template) == "string" and template ~= "" then
        return expand.expand_string(template, {
            workspace_root = workspace_root,
            project_path = project_name,
            variant = config_name or "default",
        })
    end
    return workspace_root .. "/.nvim/build/" .. project_name
        .. "/" .. (config_name or "default")
end

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------

function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. (project.path or project.name)
    local configuration_key = project.configuration_key or active_config

    local ctx = build_ctx(project, active_config)
    local build_dir = resolve_build_dir_for_tasks(project, active_config, ctx)
    ctx.build_dir = build_dir

    local shell = shell_block(project)
    local configure_cmd = expand_cmd(shell.configure_cmd, ctx)
    local build_cmd = expand_cmd(shell.build_cmd, ctx)
    local env = resolve_env(project, ctx)

    local tasks = {}

    if configure_cmd then
        tasks[#tasks + 1] = {
            name = project.name .. ": configure",
            builder = function()
                vim.fn.mkdir(build_dir, "p")
                return { cmd = configure_cmd, cwd = abs_path, env = env }
            end,
            loomworks = {
                project_key = project.name,
                action = "configure",
                configuration_key = configuration_key,
                build_dir = build_dir,
                tool_data = project.tool_data,
            },
        }
    end

    if build_cmd then
        tasks[#tasks + 1] = {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return { cmd = build_cmd, cwd = abs_path, env = env }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
                build_dir = build_dir,
                tool_data = project.tool_data,
            },
        }
    end

    return tasks
end

function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. (project.path or project.name)
    local configuration_key = project.configuration_key or active_config

    local ctx = build_ctx(project, active_config)
    local build_dir = resolve_build_dir_for_tasks(project, active_config, ctx)
    ctx.build_dir = build_dir

    local shell = shell_block(project)
    local cmd = expand_cmd(shell.clean_cmd, ctx)
    if not cmd then
        if vim.fn.has("win32") == 1 then
            cmd = { "cmd", "/c", "if exist " .. build_dir
                .. " rd /s /q " .. build_dir }
        else
            cmd = { "rm", "-rf", build_dir }
        end
    end

    local env = resolve_env(project, ctx)

    return {
        {
            name = project.name .. ": clean " .. active_config,
            builder = function()
                return { cmd = cmd, cwd = abs_path, env = env }
            end,
            loomworks = {
                project_key = project.name,
                action = "clean",
                configuration_key = configuration_key,
                build_dir = build_dir,
            },
        },
    }
end

function M.progress_parser()
    return nil
end

-- ---------------------------------------------------------------------------
-- UI: editable type_config fields
-- ---------------------------------------------------------------------------

--- Declare fields the status page can edit inline. The generic renderer
--- in `ui/sections/projects.lua` reads these and emits one row per
--- field; the field's `kind` picks the editor (string, cmd_array,
--- env_dict). Persistence goes through `Project:save_type_config_field`,
--- so no extra mutation plumbing is required here.
--- @return table[]
function M.editable_type_config_fields()
    return {
        { name = "build_dir",        label = "Build dir",        kind = "string" },
        { name = "configure_cmd",    label = "Configure cmd",    kind = "cmd_array" },
        { name = "build_cmd",        label = "Build cmd",        kind = "cmd_array" },
        { name = "clean_cmd",        label = "Clean cmd",        kind = "cmd_array" },
        { name = "compile_commands", label = "Compile commands", kind = "string" },
        { name = "env",              label = "Build environment", kind = "env_dict" },
        { name = "clangd",           label = "clangd binary",    kind = "string" },
    }
end

-- ---------------------------------------------------------------------------
-- LSP integration
-- ---------------------------------------------------------------------------

--- Emit a clangd config when `compile_commands` is set in the user's
--- `shell:` block (which is `project.type_config`).
--- @param project loomworks.Project
--- @return table[]
function M.lsp_configs(project)
    local ws = project._workspace
    if not ws then return {} end

    local tc = project.type_config or {}
    if type(tc.compile_commands) ~= "string" or tc.compile_commands == "" then
        return {}
    end

    -- Resolve build_dir from active profile so ${build_dir} matches
    -- what the build actually produces.
    local build_dir = nil
    local active_profile = ws.get_active_profile and ws:get_active_profile()
    if active_profile then
        local pp = active_profile:project(project.key)
        if pp then build_dir = pp:build_dir() end
    end
    if not build_dir and project.cached then
        build_dir = project.cached.build_dir
    end

    local ctx = {
        workspace_root = ws.root,
        project_path = project.path or project.key,
        build_dir = build_dir or "",
    }

    -- Layer in resolved project variables.
    if project.variables and next(project.variables) then
        local pp = active_profile and active_profile:project(project.key)
        local conf = pp and pp._config_unit and pp._config_unit._configuration or nil
        local variables = require("loomworks.variables")
        for name, entry in pairs(variables.resolve(project, conf)) do
            ctx[name] = expand.expand_string(entry.value, ctx)
        end
    end

    local compile_commands = expand.expand_string(tc.compile_commands, ctx)
    if not compile_commands or compile_commands == "" then return {} end

    -- compile_commands_dir wants the containing directory.
    local dir = compile_commands
    if compile_commands:match("compile_commands%.json$") then
        dir = compile_commands:gsub("[/\\]?compile_commands%.json$", "")
    end

    local binary = nil
    local binary_required = false
    if type(tc.clangd) == "string" and tc.clangd ~= "" then
        binary = tc.clangd
    elseif project.tool_data and project.tool_data.clangd_path then
        binary = project.tool_data.clangd_path
        binary_required = project.tool_data.clangd_required == true
    end

    local root_dir = ws.root .. "/" .. (project.path or project.key)

    return {
        {
            server = "clangd",
            binary = binary,
            binary_required = binary_required,
            compile_commands_dir = dir,
            root_dir = root_dir,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Staleness / targets / tests (intentionally not implemented)
-- ---------------------------------------------------------------------------

-- No `inspect` — shell module never auto-reconfigures based on file
-- changes. See spec/modules/shell.md §8.

-- No `parse_targets` — users with a known target list declare a launch
-- configuration with an explicit `program` path.

-- No `create_test_unit` — test integration is out of scope for v1.

return M
