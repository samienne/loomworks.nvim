--- loomworks/ui/launch_editor.lua — Editor for project launch configurations.
---
--- Tree+View dialog for editing launch config properties: name, command,
--- args, working directory, and environment variables.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the launch config editor.
--- @param opts table
---   title: string
---   name: string — launch config name (editable)
---   command: string
---   args: string[]
---   working_dir: string
---   env: table<string, string>
---   validate?: fun(result): boolean, string|nil
---   on_accept: fun(result: { name: string, command: string, args: string[], working_dir: string, env: table<string, string> })
---   on_cancel: fun()
function M.open(opts)
    local name = opts.name
    local command = opts.command or ""
    local args = vim.deepcopy(opts.args or {})
    local working_dir = opts.working_dir or ""
    local env = vim.deepcopy(opts.env or {})
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
        local ok, err = opts.validate({
            name = name, command = command,
            args = args, working_dir = working_dir, env = env,
        })
        name_error = not ok and err or nil
    end

    local accepted = false
    local tree, view

    --- Prompt for a string value and refresh.
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

        t:leaf(opts.title or "Launch Configuration", "Title")
        t:blank()

        -- Name
        local name_val = name ~= "" and name or "(empty)"
        local name_hl = name_error and "DiagnosticError"
                or (name ~= "" and "LoomworksActionable" or "Comment")
        t:item("Name       " .. name_val .. " ▸", {
            hl = name_hl,
            direct = true,
            on_enter = function()
                edit_string("Name: ", name, function(v)
                    name = v
                    revalidate()
                end)
            end,
        })
        if name_error then
            t:leaf(name_error, "DiagnosticError")
        end

        -- Command
        local cmd_val = command ~= "" and command or "(empty)"
        t:item("Command    " .. cmd_val .. " ▸", {
            hl = command ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Command: ", command, function(v) command = v end)
            end,
        })

        -- Args
        local args_display = #args > 0 and table.concat(args, " ") or "(none)"
        t:item("Args       " .. args_display .. " ▸", {
            hl = #args > 0 and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Args (space-separated): ", table.concat(args, " "), function(v)
                    args = {}
                    for arg in v:gmatch("%S+") do
                        args[#args + 1] = arg
                    end
                end)
            end,
        })

        -- Working directory
        local wd_val = working_dir ~= "" and working_dir or "(default)"
        t:item("Work dir   " .. wd_val .. " ▸", {
            hl = working_dir ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Working directory: ", working_dir, function(v) working_dir = v end)
            end,
        })

        t:blank()

        -- Environment variables
        local env_keys = {}
        for k in pairs(env) do env_keys[#env_keys + 1] = k end
        table.sort(env_keys)

        if #env_keys > 0 then
            t:leaf("Environment:", "Comment")
            for _, k in ipairs(env_keys) do
                local ek = k  -- capture
                t:item("  " .. k .. "=" .. env[k] .. " ▸", {
                    hl = "LoomworksActionable",
                    direct = true,
                    on_enter = function()
                        edit_string(ek .. "=", env[ek], function(v)
                            if v == "" then
                                env[ek] = nil
                            else
                                env[ek] = v
                            end
                        end)
                    end,
                    on_delete = function()
                        env[ek] = nil
                        if view then view:refresh() end
                    end,
                })
            end
        else
            t:leaf("Environment: (none)", "Comment")
        end

        t:item("  ▸ Add variable", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                vim.ui.input({ prompt = "Variable name: " }, function(key)
                    if not key or key == "" then return end
                    vim.ui.input({ prompt = key .. "=" }, function(val)
                        if val then
                            env[key] = val
                            if view then view:refresh() end
                        end
                    end)
                end)
            end,
        })

        t:blank()
        t:leaf("[Enter] change  [D] remove var  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            if name == "" then
                name_error = "name cannot be empty"
                return { refresh = true }
            end
            if command == "" then
                vim.notify("loomworks: command cannot be empty", vim.log.levels.ERROR)
                return {}
            end
            if name_error then
                return {}
            end
            accepted = true
            view:close()
            opts.on_accept({
                name = name,
                command = command,
                args = args,
                working_dir = working_dir,
                env = env,
            })
            return {}
        end
        return orig_on_key(self, action, line)
    end

    local parent_win = vim.api.nvim_get_current_win()

    local height = 0.7
    local width = 90

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = width,
            height = height,
            zindex = 65,
            backdrop = 65,
            title = " " .. (opts.title or "Launch Configuration") .. " ",
            title_pos = "center",
        },
        keymaps = {
            ["<CR>"]    = "enter",
            ["D"]       = "delete",
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
