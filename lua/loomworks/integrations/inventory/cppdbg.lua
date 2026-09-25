--- loomworks/integrations/inventory/cppdbg.lua — the cppdbg (OpenDebugAD7)
--- debug adapter's environment-inventory companion (cppdbg §6, core §8.9.6 /
--- §16.33). Mason `cpptools` package or the search path; version from the Mason
--- receipt, no spawn. Never a workspace requirement.

local M = {}

--- @param _ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.health_inventory(_ctx)
    return { require("loomworks.inventory").tool_declaration({
        id = "dap:cppdbg",
        category = "debug adapters",
        label = "cppdbg (OpenDebugAD7)",
        names = { "OpenDebugAD7" },
        version_args = false,
        mason = { package = "cpptools", file = "extension/debugAdapters/bin/OpenDebugAD7" },
        hint = ":MasonInstall cpptools",
    }) }
end

return M
