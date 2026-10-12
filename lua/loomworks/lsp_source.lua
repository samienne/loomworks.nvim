--- loomworks/lsp_source.lua — where the editor's LSP layer reads the LSP
--- configuration state (spec §9.2 "Where the entries come from", daemon.md
--- §19.16 "LSP configuration"). loomworks/lsp.lua and the server
--- integrations read projects, entries, options and readiness only through
--- this module, never from the workspace model.
---
--- Two sources, one shape (as §19.13): today only the in-process source
--- exists — the state built by loomworks/lsp_config.lua from the editor's own
--- model, reached through the `loomworks` facade. Step 5l part C adds the
--- daemon's `LspConfig/1` state here, with the in-process one as the fallback.

local lsp_config = require("loomworks.lsp_config")

local M = {}

--- The loomworks facade, or nil when it cannot be loaded.
--- @return table|nil
local function facade()
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw) ~= "table" then return nil end
    return lw
end

--- The in-process workspace model (the one place the LSP layer touches it).
--- @param lw table|nil
--- @return loomworks.Workspace|nil
local function model(lw)
    if not lw or type(lw.get_workspace) ~= "function" then return nil end
    return lw.get_workspace()
end

--- The in-process projects, as the facade lists them.
--- @param lw table
--- @return table<any, loomworks.Project>
local function projects(lw)
    return type(lw.get_projects) == "function" and lw.get_projects() or {}
end

--- Whether the facade can be loaded at all (never false in practice).
--- @return boolean
function M.available()
    return facade() ~= nil
end

--- Whether a workspace is loaded.
--- @return boolean
function M.loaded()
    return model(facade()) ~= nil
end

--- Whether a LOADED workspace exists AND the active profile's owned LSP
--- databases are ready (§9.7). Before any workspace is loaded readiness alone
--- reports ready-to-resolve, but a buffer of a workspace must still be held —
--- so this requires a loaded workspace. True when the facade has no workspace
--- notion at all.
--- @return boolean
function M.loaded_and_ready()
    local lw = facade()
    if not lw or type(lw.get_workspace) ~= "function" then return true end
    if not model(lw) then return false end
    return type(lw.lsp_ready) == "function" and lw.lsp_ready() == true
end

--- Whether a workspace load is pending: readiness is not reported (the
--- facade reports ready-to-resolve when nothing is pending, §9.7).
--- @return boolean
function M.pending()
    local lw = facade()
    if not lw or type(lw.lsp_ready) ~= "function" then return false end
    return lw.lsp_ready() ~= true
end

--- The loaded workspace's root, or nil.
--- @return string|nil
function M.root()
    local ws = model(facade())
    return ws and ws.root or nil
end

--- The whole state (the §19.20 `LspConfig/1.get` shape).
--- @return loomworks.LspConfigState
function M.state()
    local lw = facade()
    local ws = model(lw)
    if not ws then
        local err = lw and type(lw.get_setup_error) == "function" and lw.get_setup_error() or nil
        return lsp_config.state(nil, { state = err and "error" or "unloaded" })
    end
    return lsp_config.state(ws, { projects = projects(lw) })
end

--- The project records in ascending key order (empty when nothing is loaded).
--- @return loomworks.LspConfigProject[]
function M.projects()
    local lw = facade()
    local ws = model(lw)
    if not ws then return {} end
    return lsp_config.project_records(ws, projects(lw))
end

--- The record of the project a buffer belongs to, or nil.
--- @param bufnr integer
--- @return loomworks.LspConfigProject|nil
function M.project_for_buf(bufnr)
    local lw = facade()
    if not lw or type(lw.project_for_buf) ~= "function" then return nil end
    local project = lw.project_for_buf(bufnr)
    if not project then return nil end
    return lsp_config.project_record(model(lw), project)
end

--- The record and entry of `server` whose `root_dir` is `root_dir`.
--- @param server string
--- @param root_dir string|nil
--- @return loomworks.LspConfigProject|nil record, loomworks.LspConfigEntry|nil entry
function M.find_by_root(server, root_dir)
    if not root_dir then return nil, nil end
    local normalize = vim.fs.normalize
    local target = normalize(root_dir)
    for _, rec in ipairs(M.projects()) do
        local entry = lsp_config.entry(rec, server)
        if entry and entry.root_dir and normalize(entry.root_dir) == target then
            return rec, entry
        end
    end
    return nil, nil
end

--- A project's module type (for display), or nil.
--- @param key string
--- @return string|nil
function M.project_type(key)
    local lw = facade()
    if not lw then return nil end
    for _, p in pairs(projects(lw)) do
        if p.key == key then return p.type end
    end
    return nil
end

--- A server's options with defaults applied, or nil when the facade offers
--- none (the integration then uses its own defaults).
--- @param server string
--- @return table|nil
function M.options(server)
    local lw = facade()
    if not lw or type(lw.get_lsp_options) ~= "function" then return nil end
    return lw.get_lsp_options(server)
end

return M
