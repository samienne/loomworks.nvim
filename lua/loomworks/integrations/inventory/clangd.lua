--- loomworks/integrations/inventory/clangd.lua — clangd's environment-inventory
--- companion (clangd §14, core §9.3 / §16.33).
---
--- Host-neutral: the editor integration (`integrations/lsp/clangd.lua`) needs
--- editor facilities at load, so its inventory declaration lives here where the
--- standalone `lw` host can load it too. The integration re-exports this hook.
--- Reports every clangd found — on the search path (version from
--- `clangd --version`) and in Mason's install directory (version from the
--- receipt, no spawn). Never a workspace requirement.

local M = {}

--- @param _ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.health_inventory(_ctx)
    return { require("loomworks.inventory").tool_declaration({
        id = "lsp:clangd",
        category = "language servers",
        label = "clangd",
        names = { "clangd" },
        mason = { package = "clangd", bin = "clangd" },
        hint = "install clangd (LLVM) or :MasonInstall clangd",
    }) }
end

return M
