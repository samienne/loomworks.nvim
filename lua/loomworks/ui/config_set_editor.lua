--- loomworks/ui/config_set_editor.lua — Edit dialog for config set mappings.
---
--- Purpose-built dialog for editing project→variant mappings within a
--- configuration set. Simpler than mapping_dialog (no tool picker, no
--- upgrade preview).
---
--- Used for both "create new config set" and "edit existing config set".
--- Works with Project and Configuration domain objects — no string keys.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the config set editor dialog.
--- @param opts table
---   name: string — current config set name (editable)
---   projects: loomworks.Project[] — sorted project list
---   mappings: table<loomworks.Project, loomworks.Configuration|nil> — current mappings
---   available_configs: table<loomworks.Project, loomworks.Configuration[]> — available configs per project
---   validate?: fun(result): boolean, string|nil — return false + error message to block accept
---   on_accept: fun(result: { name: string, mappings: table<loomworks.Project, loomworks.Configuration|nil> })
---   on_cancel: fun()
function M.open(opts)
    local projects = opts.projects
    local mappings = {}
    -- Deep copy mappings (object refs are stable, just copy the table structure)
    for project, config in pairs(opts.mappings) do
        mappings[project] = config
    end
    local available_configs = opts.available_configs
    local name = opts.name
    local name_error = nil

    local max_name_len = 4 -- len("Name")
    for _, project in ipairs(projects) do
        if #project.key > max_name_len then max_name_len = #project.key end
    end

    --- Run validate and update name_error.
    local function revalidate()
        if not opts.validate then
            name_error = nil
            return
        end
        if name == "" then
            name_error = nil -- empty-name is handled separately on accept
            return
        end
        local ok, err = opts.validate({ name = name, mappings = mappings })
        name_error = not ok and err or nil
    end

    local accepted = false
    local tree, view

    local function render_fn(t)
        t._level = 1

        t:leaf(opts.title or "Configuration Set", "Title")
        t:blank()

        local padded_label = "Name" .. string.rep(" ", max_name_len - 4)
        local name_value = name ~= "" and name or "(empty)"
        local name_display = padded_label .. "  " .. name_value .. " ▸"
        local name_hl = name_error and "DiagnosticError"
                or (name ~= "" and "LoomworksActionable" or "Comment")
        t:item(name_display, {
            hl = name_hl,
            direct = true,
            on_enter = function()
                vim.ui.input({
                    prompt = "Configuration set name: ",
                    default = name,
                }, function(new_name)
                    if new_name and new_name ~= "" then
                        name = new_name
                        revalidate()
                        if view then view:refresh() end
                    end
                end)
            end,
        })

        if name_error then
            t:leaf(name_error, "DiagnosticError")
        end

        t:blank()

        for _, project in ipairs(projects) do
            local config = mappings[project]
            local display_variant = config and config.name or "None"
            local padded_name = project.key .. string.rep(" ", max_name_len - #project.key)
            local display = padded_name .. "  " .. display_variant .. " ▸"
            local hl = config and "LoomworksActionable" or "Comment"

            t:item(display, {
                hl = hl,
                direct = true,
                on_enter = function()
                    local configs = available_configs[project] or {}
                    local items = {}
                    for _, cfg in ipairs(configs) do
                        items[#items + 1] = cfg.name
                    end
                    items[#items + 1] = "None"
                    vim.ui.select(items, {
                        prompt = project.key .. ":",
                    }, function(choice)
                        if choice then
                            if choice == "None" then
                                mappings[project] = nil
                            else
                                for _, cfg in ipairs(configs) do
                                    if cfg.name == choice then
                                        mappings[project] = cfg
                                        break
                                    end
                                end
                            end
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

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            if name == "" then
                name_error = "name cannot be empty"
                return { refresh = true }
            end
            if name_error then
                return {}
            end
            accepted = true
            view:close()
            opts.on_accept({ name = name, mappings = mappings })
            return {}
        end
        return orig_on_key(self, action, line)
    end

    local parent_win = vim.api.nvim_get_current_win()

    local content_rows = #projects + 7 -- title + blank + name + blank + rows + blank + footer
    local height = math.min(content_rows, math.floor(vim.o.lines * 0.8))
    local width = max_name_len + 30
    width = math.max(width, #(opts.title or "Configuration Set") + 10)
    width = math.min(width, 80)

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = width,
            height = height,
            zindex = 65,
            backdrop = 65,
            title = " " .. (opts.title or "Configuration Set") .. " ",
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
