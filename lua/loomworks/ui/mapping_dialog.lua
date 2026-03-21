--- loomworks/ui/mapping_dialog.lua — Map configurations dialog.
---
--- Interactive Tree+View dialog for mapping a new project's configurations
--- to existing configuration sets. Opens when adding a project to a
--- workspace that already has config sets.
---
--- For keyed-module types (cmake), also shows a tool selection row and
--- a profile upgrade preview.

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
---   tools: table[]|nil — detected keyed tools for this module type
---   has_keyed_tools: boolean|nil — whether this module has keyed tools
---   no_tool_profiles: string[]|nil — cached profile keys without tool
---   on_accept: fun(result: { mappings: table, tool_entry: table|nil })
---   on_cancel: fun()
function M.open(opts)
    local available_configs = opts.available_configs
    local config_sets = opts.config_sets
    local mod = opts.mod
    local tools = opts.tools or {}
    local has_keyed_tools = opts.has_keyed_tools or false
    local no_tool_profiles = opts.no_tool_profiles or {}

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

    -- Tool selection state
    local selected_tool = nil -- index into tools array

    -- Track accept vs cancel
    local accepted = false

    local tree, view

    local function render_fn(t)
        t._level = 1

        -- Title
        local title_suffix = has_keyed_tools and "" or " — Map configurations"
        t:leaf('Add "' .. opts.project_key .. '" [' .. opts.project_type .. ']' .. title_suffix, "Title")
        t:blank()

        -- Configuration set mapping rows
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

        -- Tool selection section (keyed modules only)
        if has_keyed_tools and #tools > 0 then
            t:blank()
            local tool_label = selected_tool
                and (tools[selected_tool].tool_label or tools[selected_tool].tool_key)
                or "None"
            local tool_display = "Tool:  " .. tool_label .. " ▸"
            local tool_hl = selected_tool and "LoomworksActionable" or "Comment"

            t:item(tool_display, {
                hl = tool_hl,
                direct = true,
                on_enter = function()
                    local items = {}
                    for i, tool in ipairs(tools) do
                        items[#items + 1] = {
                            idx = i,
                            label = tool.tool_label or tool.tool_key,
                        }
                    end
                    vim.ui.select(items, {
                        prompt = "Tool:",
                        format_item = function(item) return item.label end,
                    }, function(choice)
                        if choice then
                            selected_tool = choice.idx
                            if view then view:refresh() end
                        end
                    end)
                end,
            })

            -- Profile upgrade preview: only profiles whose config set has a
            -- non-None mapping for the new project (keyed module).
            if selected_tool and #no_tool_profiles > 0 then
                local tool_key = tools[selected_tool].tool_key
                -- Build set of config sets that will have a keyed mapping
                local sets_with_mapping = {}
                for set_name, variant in pairs(mappings) do
                    if variant then
                        sets_with_mapping[set_name] = true
                    end
                end
                -- No-tool profile keys equal their config set name
                local upgraded = {}
                for _, pkey in ipairs(no_tool_profiles) do
                    if sets_with_mapping[pkey] then
                        upgraded[#upgraded + 1] = pkey
                    end
                end
                if #upgraded > 0 then
                    t:blank()
                    t:leaf("Profiles to upgrade:", "Comment")
                    for _, pkey in ipairs(upgraded) do
                        local new_key = pkey .. ":" .. tool_key
                        t:leaf("  " .. pkey .. " → " .. new_key, "Comment")
                    end
                end
            end
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

            -- Build tool_entry from selection
            local tool_entry = nil
            if selected_tool then
                local tool = tools[selected_tool]
                tool_entry = {
                    tool_key = tool.tool_key,
                    tool_data = tool.tool_data,
                    tool_label = tool.tool_label,
                    tool_mod_type = opts.project_type,
                }
            end

            opts.on_accept({
                mappings = mappings,
                tool_entry = tool_entry,
            })
            return {}
        end
        return orig_on_key(self, action, line)
    end

    -- Capture parent window for focus restore
    local parent_win = vim.api.nvim_get_current_win()

    -- Compute window dimensions
    local content_rows = #set_names + 4 -- title + blank + rows + blank + footer
    if has_keyed_tools and #tools > 0 then
        content_rows = content_rows + 2 -- blank + tool row
        if #no_tool_profiles > 0 then
            content_rows = content_rows + 2 + #no_tool_profiles -- blank + header + previews
        end
    end
    local height = math.min(content_rows, math.floor(vim.o.lines * 0.8))
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
