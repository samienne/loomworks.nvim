--- loomworks/debug.lua — DAP integration.
--- Translates loomworks domain data into nvim-dap launch configurations.
--- The adapter tables (defaults, known adapters, user.json overrides) are
--- host-neutral and live in loomworks/debug_config.lua.

local M = {}

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

--- Is `adapter` registered in nvim-dap (§8.9.6: the client's question,
--- never the daemon's)? False without nvim-dap or without an adapter.
--- @param adapter string|nil
--- @return boolean
function M.adapter_installed(adapter)
    local ok, dap = pcall(require, "dap")
    return ok and adapter ~= nil and dap.adapters[adapter] ~= nil
end

--- The install hint for an adapter nvim-dap lacks (one notification).
--- @param adapter string|nil
--- @param language? string the debug language (named when it has no adapter)
function M.adapter_hint(adapter, language)
    if not adapter then
        vim.notify("loomworks: no debug adapter for " .. tostring(language or "this language")
            .. " — set one in the Debug Adapters section.", vim.log.levels.WARN)
        return
    end
    vim.notify(
        "loomworks: debug adapter '" .. adapter
            .. "' not configured. Install via :Mason and restart.",
        vim.log.levels.WARN)
end

--- Launch or attach a debug session via nvim-dap.
--- @param spec { program: string, args?: string[], cwd?: string, env?: table<string, string>, adapter: string, name?: string, extra?: table, request?: string, attach_pid?: number }
--- @param callbacks? { on_terminated?: fun(), on_pid?: fun(pid: number) }
--- @return boolean started
--- @return { stop: fun() }|nil control `stop` ends the run's session (on_terminated then fires)
function M.run(spec, callbacks)
    local ok, dap = pcall(require, "dap")
    if not ok then return false end

    if not M.adapter_installed(spec.adapter) then
        M.adapter_hint(spec.adapter)
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

    -- `on_terminated` follows the one session this run starts: the first
    -- new top-level session under this config's name (nvim-dap's
    -- `on_session`; one already running is never ours), ended by that
    -- session's `on_close` — a `terminated`, a disconnect or an adapter
    -- failure alike — never by another session's end. It fires once.
    local ctl = { stop = function() end }
    if callbacks and callbacks.on_terminated then
        local key = "loomworks-session-" .. tostring(os.clock()) .. "-" .. tostring(math.random(1e9))
        local known = {}
        for id in pairs(dap.sessions() or {}) do known[id] = true end
        local bound, ended, stopping = nil, false, false
        local function finish()
            if ended then return end
            ended = true
            dap.listeners.on_session[key] = nil
            vim.schedule(callbacks.on_terminated)
        end
        local function disconnect(s)
            pcall(s.disconnect, s, { terminateDebuggee = true })
        end
        local function ours(s)
            return not bound and type(s) == "table" and s.parent == nil and not known[s.id]
                and type(s.config) == "table" and s.config.name == config.name
        end
        dap.listeners.on_session[key] = function(_, s)
            if not ours(s) then return end
            bound = s
            dap.listeners.on_session[key] = nil
            if stopping then return disconnect(s) end
            if s.closed then return finish() end
            s.on_close[key] = function() finish() end
        end
        -- Stop: the live session is disconnected (its close ends the run);
        -- none started yet ends it at once, and one starting late is
        -- disconnected as it binds.
        ctl.stop = function()
            if bound then
                if not bound.closed then disconnect(bound) end
                return
            end
            if stopping then return end
            stopping = true
            finish()
            dap.listeners.on_session[key] = function(_, s)
                if not ours(s) then return end
                bound = s
                dap.listeners.on_session[key] = nil
                disconnect(s)
            end
        end
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
    return true, ctl
end

return M
