local M = {}

M.id = "typescript"
M.has_keyed_tools = false
M.has_options = false

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve the tsconfig file for a given variant.
--- Resolution order:
--- 1. Explicit tsconfig from config (e.g. { tsconfig = "tsconfig.prod.json" })
--- 2. tsconfig.<variant>.json if it exists on disk
--- 3. Fall back to tsconfig.json
--- @param project_path string absolute project path
--- @param variant string configuration variant name
--- @param config_entry? { tsconfig?: string } explicit config from type_config
--- @return string|nil tsconfig_path relative to project
local function resolve_tsconfig(project_path, variant, config_entry)
    -- 1. Explicit tsconfig from loomworks.json
    if config_entry and config_entry.tsconfig then
        if uv.fs_stat(project_path .. "/" .. config_entry.tsconfig) then
            return config_entry.tsconfig
        end
    end
    -- 2. Variant-specific tsconfig
    local variant_tsconfig = "tsconfig." .. variant .. ".json"
    if uv.fs_stat(project_path .. "/" .. variant_tsconfig) then
        return variant_tsconfig
    end
    -- 3. Base tsconfig.json
    if uv.fs_stat(project_path .. "/tsconfig.json") then
        return "tsconfig.json"
    end
    return nil
end

--- Read the outDir from a tsconfig file.
--- @param project_path string absolute project path
--- @param tsconfig_name string tsconfig filename
--- @return string|nil outDir
local function read_outdir(project_path, tsconfig_name)
    local content = io_mod.read_file(project_path .. "/" .. tsconfig_name)
    if not content then return nil end
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then return nil end
    if data.compilerOptions and data.compilerOptions.outDir then
        return data.compilerOptions.outDir
    end
    return nil
end

--- Scan for tsconfig.*.json files to discover variant names.
--- @param project_path string absolute project path
--- @return string[] variant names
local function scan_tsconfig_variants(project_path)
    local variants = {}
    local handle = uv.fs_scandir(project_path)
    if not handle then return variants end
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if ftype == "file" or ftype == nil then
            local variant = name:match("^tsconfig%.(.+)%.json$")
            if variant then
                variants[#variants + 1] = variant
            end
        end
    end
    table.sort(variants)
    return variants
end

--- Read the scripts section from package.json.
--- @param project_path string absolute project path
--- @return table<string, string>|nil scripts name -> command
local function read_package_scripts(project_path)
    local content = io_mod.read_file(project_path .. "/package.json")
    if not content then return nil end
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then return nil end
    return data.scripts
end

--- Resolve the npm script name for a loomworks action.
--- Checks type_config overrides first, then falls back to convention.
--- @param config table type_config from loomworks.json
--- @param action string "configure"|"build"|"clean"
--- @return string|nil script name (nil means use direct command, not npm run)
local function resolve_script(config, action)
    -- Explicit mapping: typescript.scripts.build = "compile"
    if config.scripts and config.scripts[action] then
        return config.scripts[action]
    end
    -- Convention: action name matches script name
    return action == "configure" and nil or action
end

--- Wrap a command for Windows (prepend cmd /c for npm/npx).
--- @param cmd string[] command array
--- @return string[]
local function wrap_cmd(cmd)
    if vim.fn.has("win32") == 1 then
        return vim.list_extend({ "cmd", "/c" }, cmd)
    end
    return cmd
end

-- ---------------------------------------------------------------------------
-- Module interface
-- ---------------------------------------------------------------------------

--- Detect whether a directory looks like a typescript project.
--- Checks tsconfig.json first, then package.json with a typescript dependency.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/tsconfig.json") then
        return { marker = "tsconfig.json" }
    end
    local pkg_path = abs_path .. "/package.json"
    if uv.fs_stat(pkg_path) then
        local content = io_mod.read_file(pkg_path)
        if content then
            local ok, data = pcall(vim.json.decode, content)
            if ok and type(data) == "table" then
                local deps = data.dependencies or {}
                local dev_deps = data.devDependencies or {}
                if deps.typescript or dev_deps.typescript then
                    return { marker = "package.json" }
                end
            end
        end
    end
    return nil
end

--- Check if the path+config is valid.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}

    local has_tsconfig = uv.fs_stat(path .. "/tsconfig.json") ~= nil
    local has_package = uv.fs_stat(path .. "/package.json") ~= nil

    if not has_tsconfig and not has_package then
        warnings[#warnings + 1] = "neither tsconfig.json nor package.json found in " .. path
    elseif not has_tsconfig then
        warnings[#warnings + 1] = "tsconfig.json not found in " .. path
    end

    return { valid = true, warnings = warnings }
end

--- Return what the module knows about the project.
--- Detects configurations from tsconfig.*.json files or type_config overrides.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
--- Return the default configurations for this module.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
function M.default_configurations(path, config)
    return { default = {} }
end

function M.info(path, config)
    local configurations = {}

    -- Auto-detect defaults from tsconfig.*.json files
    local variants = scan_tsconfig_variants(path)
    if #variants > 0 then
        for _, name in ipairs(variants) do
            local tsconfig = "tsconfig." .. name .. ".json"
            configurations[name] = {
                variant = name,
                tsconfig = tsconfig,
                outDir = read_outdir(path, tsconfig),
            }
        end
    else
        -- Fallback: single default configuration using tsconfig.json
        configurations["default"] = {
            variant = "default",
            tsconfig = "tsconfig.json",
            outDir = read_outdir(path, "tsconfig.json"),
        }
    end

    -- Merge user overrides/additions on top
    if config.configurations then
        for name, cfg in pairs(config.configurations) do
            local entry = type(cfg) == "table" and cfg or {}
            local tsconfig = resolve_tsconfig(path, name, entry)
            configurations[name] = configurations[name] or {}
            configurations[name].tsconfig = tsconfig
            configurations[name].outDir = tsconfig and read_outdir(path, tsconfig) or nil
            -- Copy any extra fields from user config
            for k, v in pairs(entry) do
                if k ~= "tsconfig" then
                    configurations[name][k] = v
                end
            end
        end
    end

    return { configurations = configurations }
end

--- Detect available tools. TypeScript has a single default tool.
--- @return { tool_data: table }[]
function M.detect_tools()
    return { { tool_data = {} } }
end

--- Detect available tools asynchronously. TypeScript has a single default tool.
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    callback({ { tool_data = {} } })
end

--- Compare two TypeScript tool_data objects. Always match (single tool).
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    return true
end

--- Cache key suffix. nil = no suffix needed (single tool).
--- @param tool_data table
--- @return nil
function M.tool_key(tool_data)
    return nil
end

--- Display label. nil = omit from display (single tool).
--- @param tool_data table
--- @return nil
function M.tool_label(tool_data)
    return nil
end

--- Map a semantic variant type to a configuration name from available configs.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil matching configuration name
function M.map_variant(variant_type, available_configs)
    if #available_configs == 1 then
        return available_configs[1]
    end

    local targets = {
        debug = { "development", "default" },
        release = { "production", "default" },
    }

    local candidates = targets[variant_type]
    if not candidates then return nil end

    for _, target in ipairs(candidates) do
        for _, config in ipairs(available_configs) do
            if config:lower() == target then
                return config
            end
        end
    end
    return nil
end

--- Return overseer task templates for a project.
--- Uses npm scripts when available, falls back to direct tsc commands.
--- Script mapping configurable via type_config.scripts.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local configuration_key = project.configuration_key or active_config
    local config = project.type_config or {}
    local scripts = read_package_scripts(abs_path)

    -- Resolve tsconfig for this variant
    local config_info = project.configurations and project.configurations[active_config]
    local tsconfig = resolve_tsconfig(abs_path, active_config, config_info)

    -- Configure command: always npm install (not a script)
    local configure_cmd = { "npm", "install" }

    -- Build command: prefer npm run <script>, fall back to direct tsc
    local build_script = resolve_script(config, "build")
    local build_cmd
    if build_script and scripts and scripts[build_script] then
        build_cmd = { "npm", "run", build_script }
    else
        build_cmd = { "npx", "tsc", "--build" }
        if tsconfig and tsconfig ~= "tsconfig.json" then
            build_cmd[#build_cmd + 1] = tsconfig
        end
        build_cmd[#build_cmd + 1] = "--force"
    end

    return {
        {
            name = project.name .. ": configure",
            builder = function()
                return {
                    cmd = wrap_cmd(configure_cmd),
                    cwd = abs_path,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "configure",
                configuration_key = configuration_key,
            },
        },
        {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = wrap_cmd(build_cmd),
                    cwd = abs_path,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
            },
        },
    }
end

--- Return overseer task templates for cleaning build artifacts.
--- Uses npm run <clean_script> when available, falls back to tsc --clean.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local configuration_key = project.configuration_key or active_config
    local config = project.type_config or {}
    local scripts = read_package_scripts(abs_path)

    local config_info = project.configurations and project.configurations[active_config]
    local tsconfig = resolve_tsconfig(abs_path, active_config, config_info)

    local clean_script = resolve_script(config, "clean")
    local clean_cmd
    if clean_script and scripts and scripts[clean_script] then
        clean_cmd = { "npm", "run", clean_script }
    else
        clean_cmd = { "npx", "tsc", "--build" }
        if tsconfig and tsconfig ~= "tsconfig.json" then
            clean_cmd[#clean_cmd + 1] = tsconfig
        end
        clean_cmd[#clean_cmd + 1] = "--clean"
    end

    return {
        {
            name = project.name .. ": clean " .. active_config,
            builder = function()
                return {
                    cmd = wrap_cmd(clean_cmd),
                    cwd = abs_path,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "clean",
                configuration_key = configuration_key,
            },
        },
    }
end

--- Return progress parser tool name. nil = no progress tracking.
function M.progress_parser()
    return nil
end

--- Check if project files have changed since last build.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @param cached table<string, table> cached configurations
--- @return { needs_refresh: boolean, reasons: string[], notes: string[] }
function M.inspect(path, config, cached)
    local reasons = {}

    -- Check if package.json is newer than any cached config
    local pkg_stat = uv.fs_stat(path .. "/package.json")
    local tsconfig_stat = uv.fs_stat(path .. "/tsconfig.json")

    for config_key, cached_config in pairs(cached) do
        if cached_config.last_configured then
            local configured_time = cached_config.last_configured
            -- Simple string comparison works for ISO 8601 timestamps
            if pkg_stat then
                local pkg_time = os.date("!%Y-%m-%dT%H:%M:%SZ", pkg_stat.mtime.sec)
                if pkg_time > configured_time then
                    reasons[#reasons + 1] = "package.json modified since last configure"
                    break
                end
            end
            if tsconfig_stat then
                local ts_time = os.date("!%Y-%m-%dT%H:%M:%SZ", tsconfig_stat.mtime.sec)
                if ts_time > configured_time then
                    reasons[#reasons + 1] = "tsconfig.json modified since last configure"
                    break
                end
            end
        end
    end

    return { needs_refresh = #reasons > 0, reasons = reasons, notes = {} }
end

-- Scripts excluded from target detection (used by module or well-known lifecycle)
local EXCLUDED_SCRIPTS = {
    build = true, clean = true, test = true, lint = true,
    start = true, dev = true, serve = true,
    preinstall = true, postinstall = true, prepare = true,
    prepublish = true, prepublishOnly = true,
    pretest = true, posttest = true,
    prebuild = true, postbuild = true,
}

--- Detect targets from package.json scripts.
--- Returns non-lifecycle scripts as "npm_script" targets.
--- @param build_dir string (unused, kept for interface compatibility)
--- @param config_name? string (unused)
--- @return table<string, loomworks.CachedTarget>|nil
function M.parse_file_api(build_dir, config_name)
    -- build_dir isn't meaningful for TypeScript — read from project path
    -- The caller passes build_dir but for TS we need the project path.
    -- Since we don't have it here, we return nil and use parse_targets instead.
    return nil
end

--- Detect targets from package.json scripts for a given project path.
--- Called by core after configure/init instead of parse_file_api.
--- @param project_path string absolute project path
--- @return table<string, { type: string }>|nil
function M.parse_targets(project_path)
    local scripts = read_package_scripts(project_path)
    if not scripts then return nil end

    local targets = {}
    for name, cmd in pairs(scripts) do
        if not EXCLUDED_SCRIPTS[name] then
            targets[name] = {
                type = "npm_script",
                artifact = cmd,
            }
        end
    end

    return next(targets) and targets or nil
end

--- Async version of parse_targets.
--- @param project_path string
--- @param config_name? string (unused)
--- @param callback fun(targets: table|nil)
function M.parse_targets_async(project_path, config_name, callback)
    vim.schedule(function()
        callback(M.parse_targets(project_path))
    end)
end

return M
