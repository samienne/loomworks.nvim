local M = {}

M.id = "ets"
M.has_keyed_tools = false
M.has_options = false

local uv = vim.uv or vim.loop

--- Detect whether a directory looks like an eTS project.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/build-profile.json5") then
        return { marker = "build-profile.json5" }
    end
    return nil
end

--- Check if the path+config is valid.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}

    if not uv.fs_stat(path .. "/build-profile.json5") then
        warnings[#warnings + 1] = "build-profile.json5 not found in " .. path
    end

    if not uv.fs_stat(path .. "/oh-package.json5") then
        warnings[#warnings + 1] = "oh-package.json5 not found in " .. path
    end

    return { valid = true, warnings = warnings }
end

--- Return the default configurations for this module.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
function M.default_configurations(path, config)
    return { debug = {}, release = {} }
end

--- Return what the module knows about the project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    -- Always start with defaults
    local configurations = M.default_configurations(path, config)

    -- Merge user overrides/additions on top
    if config.configurations then
        for name, cfg in pairs(config.configurations) do
            configurations[name] = configurations[name] or {}
            for k, v in pairs(cfg) do
                configurations[name][k] = v
            end
        end
    end

    return { configurations = configurations }
end

--- Detect available tools. eTS has a single default tool.
--- @return { tool_data: table }[]
function M.detect_tools()
    return { { tool_data = {} } }
end

--- Detect available tools asynchronously. eTS has a single default tool.
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    callback({ { tool_data = {} } })
end

--- Compare two eTS tool_data objects. Always match (single tool).
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
        debug = { "debug" },
        release = { "release" },
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

--- Build a platform-appropriate sleep command.
--- @param seconds number
--- @return string[]
local function sleep_cmd(seconds)
    if vim.fn.has("win32") == 1 then
        return { "powershell", "-command", "Start-Sleep -Seconds " .. seconds }
    end
    return { "sleep", tostring(seconds) }
end

--- Return overseer task templates for a project.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local build_dir = project.workspace_root .. "/.nvim/build/" .. project.name .. "/" .. active_config
    local configuration_key = project.configuration_key or active_config

    return {
        {
            name = project.name .. ": configure",
            builder = function()
                return {
                    cmd = sleep_cmd(1),
                    cwd = abs_path,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "configure",
                configuration_key = configuration_key,
                build_dir = build_dir,
            },
        },
        {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = sleep_cmd(5),
                    cwd = abs_path,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
                build_dir = build_dir,
            },
        },
    }
end

function M.progress_parser()
    return nil
end

function M.inspect(path, config, cached)
    return { needs_refresh = false, reasons = {}, notes = {} }
end

return M
