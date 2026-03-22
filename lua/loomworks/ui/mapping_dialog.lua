--- loomworks/ui/mapping_dialog.lua — Map configurations dialog.
---
--- Interactive Tree+View dialog for mapping a new project's configurations
--- to existing configuration sets. Opens when adding a project to a
--- workspace that already has config sets.
---
--- For keyed-module types (cmake), the tool selection comes first.
--- Mappings are shown only when a tool is selected or inherited.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local workspace_view = require("loomworks.workspace_view")

local M = {}

--- Open the mapping dialog for a new project.
--- @param opts table
---   project_key: string
---   project_type: string
---   available_configs: string[] — new project's configuration names
---   config_sets: table<string, table> — raw config_sets from ws.config
---   mod: table — module with map_variant
---   tools: table[]|nil — detected keyed tools (only when no inherited tool)
---   has_keyed_tools: boolean|nil — whether this module has keyed tools
---   inherited_tool: table|nil — tool already in use by existing profiles
---   no_tool_profiles: string[]|nil — cached profile keys without tool
---   on_accept: fun(result: { mappings: table, tool_entry: table|nil })
---   on_cancel: fun()
function M.open(opts)
    local available_configs = opts.available_configs
    local config_sets = opts.config_sets
    local mod = opts.mod
    local tools = opts.tools or {}
    local has_keyed_tools = opts.has_keyed_tools or false
    local inherited_tool = opts.inherited_tool
    local no_tool_profiles = opts.no_tool_profiles or {}

    -- Tool is inherited from existing profiles — no picker needed
    local tool_inherited = inherited_tool ~= nil
    -- Whether the tool picker should be shown (keyed module, no inherited tool)
    local show_tool_picker = has_keyed_tools and not tool_inherited and #tools > 0

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
    local mappings = workspace_view.compute_initial_mappings(mod, set_names, available_configs)

    -- Tool selection state
    local selected_tool = nil -- index into tools array

    -- Track accept vs cancel
    local accepted = false

    -- Whether mappings should be shown
    local function show_mappings()
        if not has_keyed_tools then return true end
        if tool_inherited then return true end
        return selected_tool ~= nil
    end

    local tree, view

    local function render_fn(t)
        t._level = 1

        -- Title
        local title_suffix = show_mappings() and not show_tool_picker
            and " — Map configurations" or ""
        t:leaf('Add "' .. opts.project_key .. '" [' .. opts.project_type .. ']' .. title_suffix, "Title")
        t:blank()

        -- Tool selection (keyed modules without inherited tool)
        if show_tool_picker then
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
            t:blank()
        end

        -- Configuration set mapping rows (conditional for keyed modules)
        if show_mappings() then
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

            -- Profile upgrade preview (tool picker mode only)
            if selected_tool and #no_tool_profiles > 0 and opts.ws then
                local tool = tools[selected_tool]
                local tool_entry = {
                    tool_key = tool.tool_key,
                    tool_data = tool.tool_data,
                    tool_label = tool.tool_label,
                    tool_mod_type = opts.project_type,
                }
                local upgraded = workspace_view.compute_upgrade_preview(
                    opts.ws, tool_entry, mappings)
                if #upgraded > 0 then
                    t:blank()
                    t:leaf("Profiles to upgrade:", "Comment")
                    for _, rename in ipairs(upgraded) do
                        t:leaf("  " .. rename.old_key .. " → " .. rename.new_key, "Comment")
                    end
                end
            end
        else
            -- No tool selected — show descriptive text
            t:leaf("Project will be added without configuration mappings.", "Comment")
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

            -- Build tool_entry from selection or inheritance
            local tool_entry = nil
            if inherited_tool then
                tool_entry = inherited_tool
            elseif selected_tool then
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

    -- Compute window dimensions (generous — content may vary with tool selection)
    local content_rows = #set_names + 6 -- title + blanks + rows + footer + margin
    if show_tool_picker then
        content_rows = content_rows + 3 -- tool row + blanks
        content_rows = content_rows + #no_tool_profiles + 2 -- preview
    end
    local height = math.min(content_rows, math.floor(vim.o.lines * 0.8))
    local width = max_name_len + 30
    width = math.max(width, #opts.project_key + #opts.project_type + 30)
    width = math.min(width, 80)

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = width,
            height = height,
            zindex = 65,
            backdrop = 65,
            title = " Map configurations ",
            title_pos = "center",
        },
        keymaps = {
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
