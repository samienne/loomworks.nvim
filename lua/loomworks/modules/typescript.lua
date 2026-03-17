local M = {}

M.id = "typescript"

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve the tsconfig file for a given variant.
--- Checks for tsconfig.<variant>.json first, falls back to tsconfig.json.
--- @param project_path string absolute project path
--- @param variant string configuration variant name
--- @return string|nil tsconfig_path relative to project (e.g. "tsconfig.development.json")
local function resolve_tsconfig(project_path, variant)
    local variant_tsconfig = "tsconfig." .. variant .. ".json"
    if uv.fs_stat(project_path .. "/" .. variant_tsconfig) then
        return variant_tsconfig
    end
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
function M.info(path, config)
    local configurations = {}

    if config.configurations then
        -- Explicit configuration list from loomworks.json
        if type(config.configurations) == "table" then
            -- Support both array and dict forms
            if #config.configurations > 0 then
                -- Array: ["development", "production"]
                for _, name in ipairs(config.configurations) do
                    local tsconfig = resolve_tsconfig(path, name)
                    configurations[name] = {
                        outDir = tsconfig and read_outdir(path, tsconfig) or nil,
                    }
                end
            else
                -- Dict: { development = {}, production = {} }
                for name, cfg in pairs(config.configurations) do
                    configurations[name] = cfg
                end
            end
        end
    else
        -- Auto-detect from tsconfig.*.json files
        local variants = scan_tsconfig_variants(path)
        if #variants > 0 then
            for _, name in ipairs(variants) do
                local tsconfig = "tsconfig." .. name .. ".json"
                configurations[name] = {
                    outDir = read_outdir(path, tsconfig),
                }
            end
        else
            -- Fallback: single default configuration
            configurations["default"] = {
                outDir = read_outdir(path, "tsconfig.json"),
            }
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

--- Return overseer task templates for a project.
--- Configure = npm install, Build = tsc --build.
--- Supports command overrides via type_config.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local configuration_key = project.configuration_key or active_config

    -- Resolve tsconfig for this variant
    local tsconfig = resolve_tsconfig(abs_path, active_config)

    -- Configure command: npm install
    local configure_cmd = { "npm", "install" }

    -- Build command: npx tsc --build [tsconfig] --force
    local build_cmd = { "npx", "tsc", "--build" }
    if tsconfig and tsconfig ~= "tsconfig.json" then
        build_cmd[#build_cmd + 1] = tsconfig
    end
    build_cmd[#build_cmd + 1] = "--force"

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
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local configuration_key = project.configuration_key or active_config

    local tsconfig = resolve_tsconfig(abs_path, active_config)

    local clean_cmd = { "npx", "tsc", "--build" }
    if tsconfig and tsconfig ~= "tsconfig.json" then
        clean_cmd[#clean_cmd + 1] = tsconfig
    end
    clean_cmd[#clean_cmd + 1] = "--clean"

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

return M
