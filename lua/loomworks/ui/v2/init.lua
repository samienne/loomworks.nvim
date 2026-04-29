--- loomworks/ui/v2/init.lua — Entry point for the v2 UI.
---
--- Read-only, single-instance: one layout per editor session. Lazily
--- constructs the view model + layout on first open. Registered under
--- `<leader>wW` in `loomworks/init.lua`'s setup_keymaps.
---
--- v2 lives alongside v1; opening v2 does not affect v1.

local M = {}

--- @type loomworks.uiv2.ViewModel|nil
local view_model = nil
--- @type loomworks.uiv2.Layout|nil
local layout = nil

local function ensure()
    if view_model and layout then return end
    local ViewModel = require("loomworks.ui.v2.view_model")
    local Layout    = require("loomworks.ui.v2.view.layout")
    view_model = ViewModel.new({
        workspace_provider = function()
            local lw = require("loomworks")
            return lw.get_workspace and lw.get_workspace() or nil
        end,
    })
    layout = Layout.new(view_model)
end

function M.open()
    ensure()
    layout:open()
end

function M.close()
    if layout then layout:close() end
end

function M.toggle()
    ensure()
    layout:toggle()
end

--- @return boolean
function M.is_open()
    return layout and layout:is_open() or false
end

return M
