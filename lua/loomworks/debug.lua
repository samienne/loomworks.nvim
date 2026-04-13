--- loomworks/debug.lua — DAP integration.
--- Translates loomworks domain data into nvim-dap launch configurations.

local M = {}

--- Default adapter mapping: module_type → DAP adapter type.
--- @type table<string, string>
local DEFAULT_ADAPTERS = {
    cmake = "codelldb",
    typescript = "pwa-node",
}

--- Check if nvim-dap is available.
--- @return boolean
function M.available()
    local ok = pcall(require, "dap")
    return ok
end

--- Launch a debug session via nvim-dap.
--- @param spec { program: string, args?: string[], cwd?: string, env?: table<string, string>, adapter: string, name?: string, extra?: table }
--- @param callbacks? { on_terminated?: fun() }
function M.run(spec, callbacks)
    local ok, dap = pcall(require, "dap")
    if not ok then return false end

    if not dap.adapters[spec.adapter] then
        vim.notify(
            "loomworks: debug adapter '" .. spec.adapter
                .. "' not configured. Install via :Mason and restart.",
            vim.log.levels.WARN)
        return false
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

    -- Merge adapter-specific fields (e.g. sourceMaps, runtimeExecutable)
    if spec.extra then
        for k, v in pairs(spec.extra) do
            config[k] = v
        end
    end

    -- Register per-session callbacks via unique listener keys
    if callbacks and callbacks.on_terminated then
        local key = "loomworks-session-" .. tostring(os.clock())
        local function cleanup()
            dap.listeners.before.event_terminated[key] = nil
            dap.listeners.before.event_exited[key] = nil
            callbacks.on_terminated()
        end
        dap.listeners.before.event_terminated[key] = cleanup
        dap.listeners.before.event_exited[key] = cleanup
    end

    dap.run(config)
    return true
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

--- Known adapters per module type (for picker UI).
--- @type table<string, string[]>
local KNOWN_ADAPTERS = {
    cmake = { "codelldb", "cppdbg" },
    typescript = { "pwa-node", "pwa-chrome" },
}

--- Get the list of known adapters for a module type.
--- @param module_type string
--- @return string[]
function M.known_adapters(module_type)
    return KNOWN_ADAPTERS[module_type] or {}
end

--- Get the default adapter for a module type.
--- @param module_type string
--- @return string|nil
function M.default_adapter(module_type)
    return DEFAULT_ADAPTERS[module_type]
end

return M
