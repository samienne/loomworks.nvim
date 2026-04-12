--- loomworks/debug.lua — DAP integration.
--- Translates loomworks domain data into nvim-dap launch configurations.

local M = {}

--- Default adapter mapping: module_type → DAP adapter type.
--- @type table<string, string>
local DEFAULT_ADAPTERS = {
    cmake = "codelldb",
}

--- Launch a debug session via nvim-dap.
--- @param spec { program: string, args?: string[], cwd?: string, env?: table<string, string>, adapter: string, name?: string }
function M.run(spec)
    local ok, dap = pcall(require, "dap")
    if not ok then
        vim.notify("loomworks: nvim-dap is not installed", vim.log.levels.ERROR)
        return
    end

    local config = {
        name = spec.name or ("Debug " .. vim.fn.fnamemodify(spec.program, ":t")),
        type = spec.adapter,
        request = "launch",
        program = spec.program,
        args = spec.args,
        cwd = spec.cwd,
        env = spec.env,
    }

    dap.run(config)
end

--- Resolve the DAP adapter type for a given module type.
--- Checks workspace debug settings (from user.json) first, falls back to defaults.
--- @param workspace loomworks.Workspace
--- @param module_type string
--- @return string adapter_type
function M.resolve_adapter(workspace, module_type)
    local settings = workspace._debug_settings
    if settings and settings.adapters then
        local adapter = settings.adapters[module_type]
        if adapter then return adapter end
    end
    return DEFAULT_ADAPTERS[module_type] or "codelldb"
end

return M
