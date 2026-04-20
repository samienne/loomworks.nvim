--- loomworks/lsp.lua — LSP dispatch layer.
---
--- Core has no knowledge of specific LSP servers. Modules emit opaque
--- `lsp_configs()` entries (each keyed by `server` name). Server-specific
--- wiring lives in `lua/loomworks/integrations/<server>.lua` and is loaded
--- on demand.
---
--- Public API re-exports clangd factories for user config convenience.

local M = {}

local normalize = vim.fs.normalize

--- Clangd integration (also the entry point that registers event listeners).
--- Loaded eagerly so listeners attach when lsp.lua is required.
local clangd = require("loomworks.integrations.clangd")

-- ---------------------------------------------------------------------------
-- Public factory re-exports
-- ---------------------------------------------------------------------------

--- Create a clangd cmd function for lspconfig's `cmd` option.
--- See `loomworks.integrations.clangd.cmd_factory`.
--- @param base_cmd string[]
--- @return fun(dispatchers: table, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
M.clangd_cmd = clangd.cmd_factory

--- Create a clangd root_dir function for lspconfig.
--- See `loomworks.integrations.clangd.root_dir_factory`.
--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
--- @return fun(bufnr: number, on_dir: fun(root: string))
M.clangd_root_dir = clangd.root_dir_factory

--- Get resolved clangd cmd args for a root_dir (used by status display).
--- @param root_dir string
--- @return string[]|nil
M.get_resolved_cmd = clangd.get_resolved_cmd

-- ---------------------------------------------------------------------------
-- Status query (generic across servers)
-- ---------------------------------------------------------------------------

--- Return LSP configs for a project by calling its module's `lsp_configs`.
--- @param project loomworks.Project
--- @return table[] entries (possibly empty)
local function lsp_configs_for(project)
    local mod = project._module and project._module.impl or nil
    if not mod or not mod.lsp_configs then return {} end
    local ok, entries = pcall(mod.lsp_configs, project)
    if not ok or type(entries) ~= "table" then return {} end
    return entries
end

--- Get the resolved LSP status for all loomworks projects.
--- Returns info per project: matched clients with their cmd args per server.
--- @return table[] list of { project_key, project_type, root_dir, clients, extra }
function M.get_status()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return {} end

    local ws = lw.get_workspace()
    if not ws then return {} end

    local projects = lw.get_projects()

    -- Sort projects alphabetically
    local sorted = {}
    for _, p in pairs(projects) do sorted[#sorted + 1] = p end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    local results = {}
    for _, project in ipairs(sorted) do
        if not project.path then goto continue end

        local entries = lsp_configs_for(project)
        if #entries == 0 then goto continue end

        -- Primary display root_dir: project source path (matches most flows)
        local project_abs = normalize(ws.root .. "/" .. project.path)

        -- Gather matched clients across all servers the module declares
        local matched_clients = {}
        for _, entry in ipairs(entries) do
            local server = entry.server
            local entry_root = entry.root_dir and normalize(entry.root_dir) or project_abs
            for _, client in ipairs(vim.lsp.get_clients({ name = server })) do
                if client.root_dir and normalize(client.root_dir) == entry_root then
                    matched_clients[#matched_clients + 1] = {
                        name = client.name,
                        id = client.id,
                        cmd = client.config and client.config.cmd or nil,
                    }
                end
            end
        end

        -- Per-server extras (used by status page). Clangd is the only server
        -- with meaningful extras for now — we pull them from the clangd entry.
        local extra = {}
        for _, entry in ipairs(entries) do
            if entry.server == "clangd" then
                extra.compile_commands_dir = entry.compile_commands_dir
                extra.clangd_bin = entry.binary
                break
            end
        end

        -- resolved_cmd lookup — only meaningful for servers with a cmd
        -- factory (clangd). Use the first entry's root_dir for the key.
        local resolved_cmd = nil
        if #matched_clients > 0 and entries[1].root_dir then
            resolved_cmd = clangd.get_resolved_cmd(normalize(entries[1].root_dir))
        end

        results[#results + 1] = {
            project_key = project.key,
            project_type = project.type,
            root_dir = project_abs,
            clients = matched_clients,
            resolved_cmd = resolved_cmd,
            extra = extra,
        }

        ::continue::
    end

    return results
end

return M
