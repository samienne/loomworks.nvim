--- loomworks/debug.lua — DAP integration.
--- Translates loomworks domain data into nvim-dap launch configurations.

local M = {}

--- Default adapter mapping: language → DAP adapter type.
--- @type table<string, string>
local DEFAULT_ADAPTERS = {
    ["c++"] = "codelldb",
    typescript = "pwa-node",
}

--- Backwards-compatibility mapping: module type → language.
--- Used when old-style module type keys appear in user.json debug.adapters.
--- @type table<string, string>
local MODULE_TO_LANGUAGE = {
    cmake = "c++",
}

--- Check if nvim-dap is available.
--- @return boolean
function M.available()
    local ok = pcall(require, "dap")
    return ok
end

--- Launch or attach a debug session via nvim-dap.
--- @param spec { program: string, args?: string[], cwd?: string, env?: table<string, string>, adapter: string, name?: string, extra?: table, request?: string, attach_pid?: number }
--- @param callbacks? { on_terminated?: fun(), on_pid?: fun(pid: number) }
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

    local request = spec.request or "launch"

    local config = {
        name = spec.name or ("Debug " .. vim.fn.fnamemodify(spec.program or "process", ":t")),
        type = spec.adapter,
        request = request,
        program = spec.program,
        cwd = spec.cwd,
        env = spec.env,
    }

    if request == "launch" then
        config.args = spec.args
    else
        -- Attach mode: set pid for the adapter
        config.pid = spec.attach_pid
    end

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

    -- Capture PID from runInTerminal response (for multi-adapter attach)
    if callbacks and callbacks.on_pid then
        local pid_key = "loomworks-pid-" .. tostring(os.clock())
        dap.listeners.after.runInTerminal[pid_key] = function(_, body)
            dap.listeners.after.runInTerminal[pid_key] = nil
            if body and body.processId then
                callbacks.on_pid(body.processId)
            end
        end
    end

    dap.run(config)
    return true
end

--- Resolve the DAP adapter type for a language.
--- Checks workspace debug settings (from user.json) first, falls back to defaults.
--- Accepts both language strings ("c++") and legacy module types ("cmake").
--- @param workspace loomworks.Workspace
--- @param language string language or module type
--- @return string adapter_type
function M.resolve_adapter(workspace, language)
    -- Normalize legacy module type to language
    local lang = MODULE_TO_LANGUAGE[language] or language

    local settings = workspace._debug_settings
    if settings and settings.adapters then
        -- Check language key first, then legacy module type key
        local adapter = settings.adapters[lang] or settings.adapters[language]
        if adapter then return adapter end
    end
    return DEFAULT_ADAPTERS[lang] or "codelldb"
end

--- Known adapters per language (for picker UI).
--- @type table<string, string[]>
local KNOWN_ADAPTERS = {
    ["c++"] = { "codelldb", "cppdbg" },
    typescript = { "pwa-node", "pwa-chrome" },
}

--- Get the list of known adapters for a language.
--- @param language string
--- @return string[]
function M.known_adapters(language)
    return KNOWN_ADAPTERS[language] or {}
end

--- Get the default adapter for a language.
--- @param language string
--- @return string|nil
function M.default_adapter(language)
    return DEFAULT_ADAPTERS[language]
end

--- Get all known languages.
--- @return string[]
function M.known_languages()
    local langs = {}
    for lang in pairs(DEFAULT_ADAPTERS) do
        langs[#langs + 1] = lang
    end
    table.sort(langs)
    return langs
end

return M
