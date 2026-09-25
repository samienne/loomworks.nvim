--- loomworks/integrations/inventory/pwa_node.lua — the pwa-node (js-debug)
--- debug adapter's environment-inventory companion (pwa-node §7, core §8.9.6 /
--- §16.33). Mason `js-debug-adapter` package; version from its receipt. Also
--- declares `exe:node` (shared with the typescript module, probed once), which
--- the adapter runs on. Never a workspace requirement.

local M = {}

--- @param _ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.health_inventory(_ctx)
    local inv = require("loomworks.inventory")
    return {
        inv.tool_declaration({
            id = "dap:pwa-node",
            category = "debug adapters",
            label = "js-debug (pwa-node)",
            mason = { package = "js-debug-adapter", file = "js-debug/src/dapDebugServer.js" },
            hint = ":MasonInstall js-debug-adapter",
        }),
        inv.exe_declaration({
            id = "exe:node", label = "node", names = { "node" },
            hint = function(ctx)
                return ctx.is_windows and "winget install OpenJS.NodeJS.LTS"
                    or "install Node.js (nodejs.org or your package manager)"
            end,
        }),
    }
end

return M
