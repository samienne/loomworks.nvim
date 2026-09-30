--- loomworks/integrations/inventory/qmlls.lua — qmlls's environment-inventory
--- companion (qmlls §10, core §9.3 / §16.33).
---
--- Host-neutral half of `integrations/lsp/qmlls.lua` (which registers a
--- filetype at load). Search path (version from `qmlls --version`) and the
--- Mason bin directory; Qt installations are not searched. Never a workspace
--- requirement.

local M = {}

--- Languages this tool serves: a plain `lw health` lists it only in a workspace
--- with one of them (or, for a language server, one whose modules name it in
--- `lsp_servers`) — core §16.36.
M.languages = { "qml" }

--- @param _ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.health_inventory(_ctx)
    return { require("loomworks.inventory").tool_declaration({
        id = "lsp:qmlls",
        category = "language servers",
        label = "qmlls",
        names = { "qmlls" },
        mason_bin = "qmlls",
        hint = "ships in a Qt kit's bin directory — put it on PATH",
    }) }
end

return M
