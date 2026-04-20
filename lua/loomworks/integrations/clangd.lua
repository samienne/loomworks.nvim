--- loomworks/integrations/clangd.lua — clangd LSP integration.
---
--- Implements all clangd-specific wiring: cmd factory (injects
--- --compile-commands-dir and binary override), root_dir factory,
--- auto-restart on profile/workspace changes.
---
--- This file is an LSP integration, not core. It reads opaque entries
--- produced by modules via `M.lsp_configs()` and filters for server="clangd".
--- Core never sees clangd specifics — it only routes configs to integrations
--- by `entry.server` name.

local M = {}

local uv = vim.uv or vim.loop
local normalize = vim.fs.normalize

--- Resolved clangd command args keyed by normalized root_dir.
--- Populated by the cmd wrapper, read by get_resolved_cmd().
--- @type table<string, string[]>
local _resolved_cmd = {}

--- State tracking for detecting when clangd needs restart on active_set_changed.
--- @type table<string, { binary: string|nil, compile_commands_dir: string|nil }>
local _client_state = {}

local _listener_registered = false

--- Call a project's module.lsp_configs() and return the first clangd entry.
--- @param project loomworks.Project
--- @return table|nil clangd entry or nil if none declared
local function clangd_entry_for_project(project)
    if not project then return nil end
    local mod = project._module and project._module.impl or nil
    if not mod or not mod.lsp_configs then return nil end

    local ok, entries = pcall(mod.lsp_configs, project)
    if not ok or type(entries) ~= "table" then return nil end

    for _, e in ipairs(entries) do
        if e.server == "clangd" then return e end
    end
    return nil
end

--- Locate the loomworks project for a clangd root_dir.
--- Each module's lsp_configs() sets entry.root_dir — we match against that.
--- @param root_dir string|nil absolute path (clangd root)
--- @return loomworks.Project|nil, loomworks.Workspace|nil, table|nil entry
local function find_project_by_root(root_dir)
    if not root_dir then return nil, nil, nil end

    local ok, lw = pcall(require, "loomworks")
    if not ok then return nil, nil, nil end

    local ws = lw.get_workspace()
    if not ws then return nil, nil, nil end

    local target = normalize(root_dir)
    for _, project in pairs(lw.get_projects()) do
        local entry = clangd_entry_for_project(project)
        if entry and entry.root_dir and normalize(entry.root_dir) == target then
            return project, ws, entry
        end
    end

    return nil, nil, nil
end

--- Expand ${ENV_VAR} patterns. Leaves unresolved refs unchanged.
--- @param s string
--- @return string
local function expand_env(s)
    return (s:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Resolve the clangd binary from an entry (verifies existence).
--- @param entry table|nil clangd entry with optional `binary` field
--- @return string|nil absolute path to clangd binary
local function resolve_binary(entry)
    if not entry or not entry.binary then return nil end
    local expanded = expand_env(entry.binary)
    if uv.fs_stat(expanded) then return expanded end
    return nil
end

--- Resolve compile_commands_dir from an entry (verifies the .json exists).
--- @param entry table|nil clangd entry with optional `compile_commands_dir` field
--- @return string|nil absolute compile_commands directory
local function resolve_compile_commands_dir(entry)
    if not entry or not entry.compile_commands_dir then return nil end
    local dir = entry.compile_commands_dir
    if not uv.fs_stat(dir .. "/compile_commands.json") then return nil end
    return dir
end

-- ---------------------------------------------------------------------------
-- Public factory functions (re-exported via lsp.lua for user config)
-- ---------------------------------------------------------------------------

--- Create a clangd `cmd` function for lspconfig that injects
--- --compile-commands-dir and optionally overrides the binary per project.
--- Falls back to `base_cmd` when loomworks has no data.
--- @param base_cmd string[] e.g. { "clangd", "--background-index" }
--- @return fun(dispatchers: table, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.cmd_factory(base_cmd)
    return function(dispatchers, config)
        local args = vim.list_extend({}, base_cmd)
        local _, _, entry = find_project_by_root(config.root_dir)

        local bin = resolve_binary(entry)
        if bin then args[1] = bin end

        local dir = resolve_compile_commands_dir(entry)
        if dir then args[#args + 1] = "--compile-commands-dir=" .. dir end

        if config.root_dir then
            _resolved_cmd[normalize(config.root_dir)] = vim.list_extend({}, args)
        end

        return vim.lsp.rpc.start(args, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

--- Create a `root_dir` function for lspconfig that uses the loomworks
--- project's clangd entry root_dir when the buffer's project has one.
--- Falls through to the provided fallback otherwise.
--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
--- @return fun(bufnr: number, on_dir: fun(root: string))
function M.root_dir_factory(fallback)
    return function(bufnr, on_dir)
        local ok, lw = pcall(require, "loomworks")
        if ok then
            local project = lw.project_for_buf(bufnr)
            if project then
                local entry = clangd_entry_for_project(project)
                if entry and entry.root_dir then
                    on_dir(normalize(entry.root_dir))
                    return
                end
            end
        end
        if fallback then fallback(bufnr, on_dir) end
    end
end

--- Get the resolved command args for a root_dir (if available).
--- @param root_dir string normalized root directory
--- @return string[]|nil
function M.get_resolved_cmd(root_dir)
    return _resolved_cmd[root_dir]
end

--- Get the clangd entry for a project (used by status display).
--- @param project loomworks.Project
--- @return table|nil entry { binary?, compile_commands_dir?, root_dir? }
function M.entry_for(project)
    return clangd_entry_for_project(project)
end

-- ---------------------------------------------------------------------------
-- Auto-restart on profile/workspace changes
-- ---------------------------------------------------------------------------

--- Find LSP clients matching a root_dir.
--- @param root_dir string
--- @return vim.lsp.Client[]
local function find_clangd_clients(root_dir)
    local target = normalize(root_dir)
    local matches = {}
    for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
        if client.root_dir and normalize(client.root_dir) == target then
            matches[#matches + 1] = client
        end
    end
    return matches
end

--- Stop clients and re-enable clangd so open buffers re-attach.
--- Clears resolved cmd cache for the affected root_dirs.
--- @param clients vim.lsp.Client[]
local function restart_clients(clients)
    for _, client in ipairs(clients) do
        if client.root_dir then
            _resolved_cmd[normalize(client.root_dir)] = nil
        end
        client:stop()
    end
    vim.schedule(function() vim.lsp.enable("clangd") end)
end

--- Detect clangd state changes after a profile/active set change.
local function on_active_set_changed()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return end
    if not lw.get_workspace() then return end

    local new_state = {}
    for _, project in pairs(lw.get_projects()) do
        local entry = clangd_entry_for_project(project)
        if entry and entry.root_dir then
            local key = normalize(entry.root_dir)
            local new = {
                binary = resolve_binary(entry),
                compile_commands_dir = resolve_compile_commands_dir(entry),
            }
            new_state[key] = new

            local prev = _client_state[key]
            if prev and (prev.binary ~= new.binary
                    or prev.compile_commands_dir ~= new.compile_commands_dir) then
                local clients = find_clangd_clients(key)
                if #clients > 0 then
                    local parts = {}
                    if new.compile_commands_dir ~= prev.compile_commands_dir then
                        parts[#parts + 1] = "compile_commands: "
                            .. (new.compile_commands_dir or "none")
                    end
                    if new.binary ~= prev.binary then
                        parts[#parts + 1] = "binary: " .. (new.binary or "default")
                    end
                    vim.notify("loomworks: restarting clangd for " .. project.key
                        .. (#parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""))
                    restart_clients(clients)
                end
            end
        end
    end
    _client_state = new_state
end

--- Restart all clangd clients when a workspace loads for the first time.
--- Pre-existing clients were started without loomworks awareness.
local function on_workspace_changed()
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then return end
    vim.notify("loomworks: restarting " .. #clients .. " clangd client(s) for workspace integration")
    restart_clients(clients)
end

--- Register listeners (idempotent). Called once on module load.
local function ensure_listeners()
    if _listener_registered then return end
    _listener_registered = true

    local ok, lw = pcall(require, "loomworks")
    if ok then
        lw.on("active_set_changed", function() vim.schedule(on_active_set_changed) end)
        lw.on("workspace_changed", function() vim.schedule(on_workspace_changed) end)
    end
end

ensure_listeners()

return M
