local M = {}

M.id = "typescript"
M.has_keyed_tools = false

local uv = vim.uv or vim.loop

--- Check if the path+config is valid.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}

    if not uv.fs_stat(path .. "/tsconfig.json") then
        warnings[#warnings + 1] = "tsconfig.json not found in " .. path
    end

    return { valid = true, warnings = warnings }
end

--- Return what the module knows about the project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    local configurations = {}

    if config.configurations then
        for name, cfg in pairs(config.configurations) do
            configurations[name] = cfg
        end
    else
        configurations["development"] = {}
        configurations["production"] = {}
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
