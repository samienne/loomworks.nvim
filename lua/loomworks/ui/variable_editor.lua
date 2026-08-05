--- loomworks/ui/variable_editor.lua — Editor for a project variable declaration.
---
--- Tree+View dialog for editing a variable's name, type, and default value.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the variable declaration editor.
--- @param opts table
---   name: string — variable name (editable for new, may be read-only for rename)
---   type: string — "string" or "path"
---   default: string — default value
---   validate?: fun(result): boolean, string|nil
---   on_accept: fun(result: { name: string, type: string, default: string })
---   on_cancel: fun()
function M.open(opts)
    local name = opts.name or ""
    local var_type = opts.type or "string"
    local default = opts.default or ""
    local name_error = nil

    local function revalidate()
        if not opts.validate then
            name_error = nil
            return
        end
        if name == "" then
            name_error = nil
            return
        end
        local ok, err = opts.validate({ name = name, type = var_type, default = default })
        name_error = not ok and err or nil
    end

    local accepted = false
    local tree, view

    local function edit_string(prompt, current, on_done)
        vim.ui.input({
            prompt = prompt,
            default = current,
        }, function(value)
            if value then
                on_done(value)
                if view then view:refresh() end
            end
        end)
    end

    local function render_fn(t)
        t._level = 1

        t:leaf(opts.title or "Variable", "Title")
        t:blank()

        local name_val = name ~= "" and name or "(empty)"
        local name_hl = name_error and "DiagnosticError"
                or (name ~= "" and "LoomworksActionable" or "Comment")
        t:item("Name     " .. name_val .. " ▸", {
            hl = name_hl,
            direct = true,
            on_enter = function()
                edit_string("Variable name: ", name, function(v)
                    name = v
                    revalidate()
                end)
            end,
        })
        if name_error then
            t:leaf(name_error, "DiagnosticError")
        end

        t:item("Type     " .. var_type .. " ▸", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                vim.ui.select({ "string", "path" }, {
                    prompt = "Variable type:",
                }, function(choice)
                    if choice then
                        var_type = choice
                        if view then view:refresh() end
                    end
                end)
            end,
        })

        local def_val = default ~= "" and default or "(empty)"
        t:item("Default  " .. def_val .. " ▸", {
            hl = default ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Default value: ", default, function(v)
                    default = v
                end)
            end,
        })

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
            if name_error then return {} end

            accepted = true
            view:close()
            opts.on_accept({
                name = name,
                type = var_type,
                default = default,
            })
            return {}
        end
        return orig_on_key(self, action, line)
    end

    local parent_win = vim.api.nvim_get_current_win()

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = 70,
            height = 10,
            zindex = 65,
            backdrop = 65,
            title = " " .. (opts.title or "Variable") .. " ",
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
