--- loomworks/integrations/inventory/codelldb.lua — the codelldb debug adapter's
--- environment-inventory companion (codelldb §6, core §8.9.6 / §16.33).
---
--- Presence on disk (Mason package or search path), not registration with the
--- debugger plugin — that is still checked at debug time. Version from the
--- Mason receipt; no spawn. Never a workspace requirement.

local M = {}

--- @param _ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.health_inventory(_ctx)
    return { require("loomworks.inventory").tool_declaration({
        id = "dap:codelldb",
        category = "debug adapters",
        label = "codelldb",
        names = { "codelldb" },
        version_args = false,
        mason = { package = "codelldb", file = "extension/adapter/codelldb" },
        hint = ":MasonInstall codelldb",
    }) }
end

return M
