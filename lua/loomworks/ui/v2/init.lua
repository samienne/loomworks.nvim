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

--- User-tunable configuration. Set via `require("loomworks.ui.v2").setup({...})`.
--- @class loomworks.uiv2.Config
--- @field layout? "tabpage"|"float"
--- @field float? loomworks.uiv2.FloatConfig
local config = {
    layout = "tabpage",
    float = {
        margin = 2,            -- gap between the workbench and editor edges (number or {top,bottom,left,right})
        overview_width = 0.4,  -- proportion of viewport width
        activity_height = 0.25,
        pane_gap = 1,          -- gap between panes
        border = "rounded",
    },
}

--- Apply user configuration. Subsequent open()/toggle() calls will use the new
--- settings; existing windows are not retroactively updated.
--- @param opts loomworks.uiv2.Config
function M.setup(opts)
    if not opts then return end
    config = vim.tbl_deep_extend("force", config, opts)
end

--- Returns a copy of the current config (test/debug helper).
--- @return loomworks.uiv2.Config
function M._config()
    return vim.deepcopy(config)
end

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
    layout:open(config)
end

function M.close()
    if layout then layout:close() end
end

function M.toggle()
    ensure()
    if layout:is_open() then layout:close() else layout:open(config) end
end

--- @return boolean
function M.is_open()
    return layout and layout:is_open() or false
end

--- Internal accessor for the palette and other call sites that need to
--- dispatch into the view model (e.g. drill_in to focus an item).
--- Constructs the view model lazily so the palette can dispatch even
--- when the layout has never been opened.
--- @return loomworks.uiv2.ViewModel|nil
function M._view_model_for_palette()
    ensure()
    return view_model
end

return M
