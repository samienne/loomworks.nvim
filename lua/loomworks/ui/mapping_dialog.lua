--- loomworks/ui/mapping_dialog.lua — Map configurations dialog.
---
--- Interactive Tree+View dialog for mapping a new project's configurations
--- to existing configuration sets. Opens when adding a project to a
--- workspace that already has config sets.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the mapping dialog for a new project.
--- @param opts table
---   project_key: string
---   project_type: string
---   available_configs: string[] — new project's configuration names
---   config_sets: table<string, table> — raw config_sets from ws.config
---   mod: table — module with map_variant
---   on_accept: fun(set_mappings: table<string, string|nil>)
---   on_cancel: fun()
function M.open(opts)
    local available_configs = opts.available_configs
    local config_sets = opts.config_sets
    local mod = opts.mod

    -- Sorted config set names for stable ordering
    local set_names = {}
    for name in pairs(config_sets) do
        set_names[#set_names + 1] = name
    end
    table.sort(set_names)

    -- Compute max set name width for alignment
    local max_name_len = 0
    for _, name in ipairs(set_names) do
        if #name > max_name_len then max_name_len = #name end
    end

    -- Initialize mappings via auto-detection
    local mappings = {}
    for _, set_name in ipairs(set_names) do
        local variant_type = set_name:lower()
        local mapped = mod.map_variant and mod.map_variant(variant_type, available_configs) or nil
        mappings[set_name] = mapped
    end

    -- Track accept vs cancel
    local accepted = false

    local tree, view

    local function render_fn(t)
        t._level = 1
        t:leaf('Add "' .. opts.project_key .. '" [' .. opts.project_type .. '] — Map configurations', "Title")
        t:blank()

        for _, set_name in ipairs(set_names) do
            local variant = mappings[set_name]
            local display_variant = variant or "None"
            local padded_name = set_name .. string.rep(" ", max_name_len - #set_name)
            local display = padded_name .. "  " .. display_variant .. " ▸"
            local hl = variant and "LoomworksActionable" or "Comment"

            t:item(display, {
                hl = hl,
                direct = true,
                on_enter = function()
                    local items = {}
                    for _, config_name in ipairs(available_configs) do
                        items[#items + 1] = config_name
                    end
                    items[#items + 1] = "None"
                    vim.ui.select(items, {
                        prompt = set_name .. ":",
                    }, function(choice)
                        if choice then
                            mappings[set_name] = choice ~= "None" and choice or nil
                            if view then view:refresh() end
                        end
                    end)
                end,
            })
        end

        t:blank()
        t:leaf("[Enter] change  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    -- Custom accept action
    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            accepted = true
            view:close()
            opts.on_accept(mappings)
            return {}
        end
        return orig_on_key(self, action, line)
    end

    -- Capture parent window for focus restore
    local parent_win = vim.api.nvim_get_current_win()

    -- Compute window dimensions
    local height = #set_names + 4 -- title + blank + rows + blank + footer
    height = math.min(height, math.floor(vim.o.lines * 0.8))
    local width = max_name_len + 30
    width = math.max(width, #opts.project_key + #opts.project_type + 30)
    width = math.min(width, 80)

    view = View.new({
        widget = tree,
        win = {
            width = width,
            height = height,
            zindex = 65,
            backdrop = 65,
            title = " Map configurations ",
            title_pos = "center",
        },
        keymaps = {
            ["<Tab>"]   = "next_item",
            ["<S-Tab>"] = "prev_item",
            ["<CR>"]    = "enter",
            ["y"]       = "accept",
        },
        events = {},
        on_close = function()
            if parent_win and vim.api.nvim_win_is_valid(parent_win) then
                vim.api.nvim_set_current_win(parent_win)
            end
            if not accepted then
                opts.on_cancel()
            end
        end,
    })

    view:open()
end

return M
