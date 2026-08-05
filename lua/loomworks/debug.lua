--- loomworks/debug.lua — DAP integration.
--- Translates loomworks domain data into nvim-dap launch configurations.

local M = {}

--- Default adapter mapping: language → DAP adapter type.
--- @type table<string, string>
local DEFAULT_ADAPTERS = {
    ["c++"] = "codelldb",
    typescript = "pwa-node",
}

--- JS/TS debug adapters that need runtimeExecutable transformation.
--- @type table<string, boolean>
local JS_ADAPTERS = {
    ["pwa-node"] = true,
    ["pwa-chrome"] = true,
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
    local is_js_adapter = JS_ADAPTERS[spec.adapter]

    local config = {
        name = spec.name or ("Debug " .. vim.fn.fnamemodify(spec.program or "process", ":t")),
        type = spec.adapter,
        request = request,
        cwd = spec.cwd,
        env = spec.env,
    }

    if request == "attach" then
        config.pid = spec.attach_pid
        config.program = spec.program  -- for symbol resolution
    elseif is_js_adapter then
        -- JS adapters: command becomes runtimeExecutable, first arg becomes program
        config.runtimeExecutable = spec.program
        config.sourceMaps = true
        config.console = "integratedTerminal"
        local args = spec.args or {}
        config.program = args[1]
        if #args > 1 then
            local remaining = {}
            for i = 2, #args do remaining[#remaining + 1] = args[i] end
            config.args = remaining
        end
    else
        -- Native adapters (codelldb, cppdbg): program is the executable.
        -- Resolve command name to full path via PATH if not already absolute.
        local program = spec.program
        if program and not program:match("^/") and not program:match("^%a:") then
            local resolved = vim.fn.exepath(program)
            if resolved ~= "" then
                program = resolved
            end
        end
        config.program = program
        config.args = spec.args
    end

    if spec.extra then
        for k, v in pairs(spec.extra) do
            config[k] = v
        end
    end

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

    -- Capture PID after session initializes (for multi-adapter attach).
    -- The PID is available from the terminal job that runInTerminal created.
    -- For js-debug: event_initialized fires on both parent and child sessions.
    -- The term_buf may not exist on first firing (parent), so we keep the
    -- listener until we find it, then poll briefly if needed.
    if callbacks and callbacks.on_pid then
        local pid_key = "loomworks-pid-" .. tostring(os.clock())
        local pid_found = false
        local function try_extract_pid()
            for _, s in pairs(dap.sessions()) do
                local cur = s
                while cur do
                    if cur.term_buf and vim.api.nvim_buf_is_valid(cur.term_buf) then
                        local chan = vim.bo[cur.term_buf].channel
                        if chan and chan > 0 then
                            local ok_pid, pid = pcall(vim.fn.jobpid, chan)
                            if ok_pid and pid then
                                return pid
                            end
                        end
                    end
                    cur = cur.parent
                end
            end
            return nil
        end

        dap.listeners.after.event_initialized[pid_key] = function()
            if pid_found then return end
            local pid = try_extract_pid()
            if pid then
                pid_found = true
                dap.listeners.after.event_initialized[pid_key] = nil
                callbacks.on_pid(pid)
            else
                -- term_buf might not exist yet; retry after short delay
                vim.defer_fn(function()
                    if pid_found then return end
                    local retry_pid = try_extract_pid()
                    if retry_pid then
                        pid_found = true
                        dap.listeners.after.event_initialized[pid_key] = nil
                        callbacks.on_pid(retry_pid)
                    end
                end, 500)
            end
        end
    end

    dap.run(config)
    return true
end

--- Resolve the DAP adapter type for a language.
--- Checks workspace debug settings (from user.json) first, falls back to defaults.
--- @param workspace loomworks.Workspace
--- @param language string language name (e.g. "c++", "typescript")
--- @return string|nil adapter_type
function M.resolve_adapter(workspace, language)
    local settings = workspace._debug_settings
    if settings and settings.adapters and settings.adapters[language] then
        return settings.adapters[language]
    end
    return DEFAULT_ADAPTERS[language]
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
