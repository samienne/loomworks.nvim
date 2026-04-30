--- loomworks/ui/v2/view_model/inspector_kinds/cleanup_audit.lua
---
--- Workspace-level cleanup view. Lists items that are candidates for
--- removal — currently orphaned cached configurations (entries in
--- cache.json with state but no profile referencing them). Each entry
--- is drillable to the orphan ref so the standard delete affordance
--- applies. A "+ Delete all" sentinel removes the entire list with
--- confirmation in the layer above.
---
--- v0 doesn't enumerate stray build directories — that needs filesystem
--- traversal under workspace root. Listed here as a deferred extension.

local M = {}

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "cleanup_audit" }
--- @return table
function M.build(workspace, ref)
    if not workspace then
        return {
            kind     = "cleanup_audit",
            subject  = "Workspace cleanup",
            missing  = true,
            hint_bar = {},
        }
    end

    local lw = require("loomworks")
    local raw = lw.get_orphaned_configs and lw.get_orphaned_configs() or {}
    local orphans = {}
    for cache_key, entry in pairs(raw or {}) do
        orphans[#orphans + 1] = {
            cache_key   = cache_key,
            project_key = entry and entry.project_key or "?",
            config_key  = entry and entry.config_key  or cache_key,
            ref         = { kind = "orphan_config", key = cache_key },
        }
    end
    table.sort(orphans, function(a, b)
        if a.project_key ~= b.project_key then return a.project_key < b.project_key end
        return a.config_key < b.config_key
    end)

    return {
        kind        = "cleanup_audit",
        subject     = "Workspace cleanup",
        missing     = false,
        orphans     = orphans,
        orphan_count = #orphans,
        commit_actions = (#orphans > 0) and {
            { kind = "cleanup_audit_delete_all", label = "+ Delete all listed orphans" },
        } or nil,
        hint_bar    = {
            { key = "<CR>",   label = "drill / delete all" },
            { key = "<C-w>w", label = "cycle pane" },
        },
    }
end

return M
