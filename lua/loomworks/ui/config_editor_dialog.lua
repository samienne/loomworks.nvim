--- loomworks/ui/config_editor_dialog.lua — Editor for project configuration properties.
---
--- Tree+View dialog for editing configuration name, variant, inheritance,
--- and module-specific options (cmake -D flags).

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the configuration editor dialog.
--- @param opts table
---   title: string
---   name: string — configuration name (editable for custom, read-only for defaults)
---   variant: string — CMAKE_BUILD_TYPE or equivalent
---   inherits: string — base config name (empty = none)
---   options: table<string, string> — editable key=value options
---   toolchain: string — toolchain path
---   generator: string — generator override
---   is_default: boolean — if true, name is read-only
---   has_options: boolean — whether to show options section
---   available_configs: string[] — for inherits picker
---   project_options: table<string, string> — project-wide options (display only)
---   inherited_options: table<string, { value: string, source: string }> — resolved inherited options
---   validate?: fun(result): boolean, string|nil
---   on_accept: fun(result)
---   on_cancel: fun()
function M.open(opts)
    local name = opts.name
    local variant = opts.variant or ""
    local inherits = opts.inherits or ""
    local options = vim.deepcopy(opts.options or {})
    local toolchain = opts.toolchain or ""
    local generator = opts.generator or ""
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
        local ok, err = opts.validate({ name = name })
        name_error = not ok and err or nil
    end

    local function edit_string(prompt, current, on_done)
        vim.ui.input({ prompt = prompt, default = current }, function(val)
            if val then on_done(val) end
        end)
    end

    local accepted = false
    local tree, view

    local function render_fn(t)
        t._level = 1

        t:leaf(opts.title or "Configuration", "Title")
        t:blank()

        -- Name
        if opts.is_default then
            t:leaf("Name       " .. name, "Comment")
        else
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
                        if view then view:refresh() end
                    end)
                end,
            })
            if name_error then
                t:leaf(name_error, "DiagnosticError")
            end
        end

        -- Inherits (for custom configs with options support, not for defaults)
        if opts.has_options and not opts.is_default and #opts.available_configs > 0 then
            local inh_display = inherits ~= "" and inherits or "(none)"
            -- Resolve display variant from inheritance chain
            local resolved_variant = ""
            if inherits ~= "" then
                for _, c in ipairs(opts.available_configs) do
                    if c == inherits then
                        -- The base config's variant is its name (defaults)
                        resolved_variant = inherits
                        break
                    end
                end
            end
            local variant_hint = resolved_variant ~= ""
                and ("  → " .. resolved_variant) or ""
            t:item("Inherits   " .. inh_display .. variant_hint .. " ▸", {
                hl = inherits ~= "" and "LoomworksActionable" or "Comment",
                direct = true,
                on_enter = function()
                    local items = {}
                    for _, c in ipairs(opts.available_configs) do
                        if c ~= name then
                            items[#items + 1] = c
                        end
                    end
                    vim.ui.select(items, { prompt = "Inherits:" }, function(choice)
                        if choice then
                            inherits = choice
                            if view then view:refresh() end
                        end
                    end)
                end,
            })
        end

        -- Toolchain (cmake-specific)
        if opts.has_options and (toolchain ~= "" or opts.is_default) then
            t:item("Toolchain  " .. (toolchain ~= "" and toolchain or "(none)") .. " ▸", {
                hl = toolchain ~= "" and "LoomworksActionable" or "Comment",
                direct = true,
                on_enter = function()
                    edit_string("Toolchain: ", toolchain, function(v)
                        toolchain = v
                        if view then view:refresh() end
                    end)
                end,
            })
        end

        -- Generator (cmake-specific)
        if opts.has_options and (generator ~= "" or opts.is_default) then
            t:item("Generator  " .. (generator ~= "" and generator or "(default)") .. " ▸", {
                hl = generator ~= "" and "LoomworksActionable" or "Comment",
                direct = true,
                on_enter = function()
                    edit_string("Generator: ", generator, function(v)
                        generator = v
                        if view then view:refresh() end
                    end)
                end,
            })
        end

        -- Options section
        if opts.has_options then
            t:blank()

            local opt_keys = {}
            for k in pairs(options) do opt_keys[#opt_keys + 1] = k end
            table.sort(opt_keys)

            if #opt_keys > 0 then
                t:leaf("Options:", "Comment")
                for _, k in ipairs(opt_keys) do
                    local ek = k
                    t:item("  " .. k .. "=" .. options[k] .. " ▸", {
                        hl = "LoomworksActionable",
                        direct = true,
                        on_enter = function()
                            edit_string(ek .. "=", options[ek], function(v)
                                if v == "" then
                                    options[ek] = nil
                                else
                                    options[ek] = v
                                end
                                if view then view:refresh() end
                            end)
                        end,
                        on_delete = function()
                            options[ek] = nil
                            if view then view:refresh() end
                        end,
                    })
                end
            else
                t:leaf("Options: (none)", "Comment")
            end

            t:item("  ▸ Add option", {
                hl = "LoomworksActionable",
                direct = true,
                on_enter = function()
                    vim.ui.input({ prompt = "Option name: " }, function(key)
                        if not key or key == "" then return end
                        vim.ui.input({ prompt = key .. "=" }, function(val)
                            if val then
                                options[key] = val
                                if view then view:refresh() end
                            end
                        end)
                    end)
                end,
            })

            -- Show inherited options (read-only)
            local inherited = opts.inherited_options or {}
            local inh_keys = {}
            for k in pairs(inherited) do inh_keys[#inh_keys + 1] = k end
            table.sort(inh_keys)

            if #inh_keys > 0 then
                t:blank()
                t:leaf("Inherited options:", "Comment")
                for _, k in ipairs(inh_keys) do
                    local info = inherited[k]
                    t:leaf("  " .. k .. "=" .. info.value .. "  (" .. info.source .. ")", "Comment")
                end
            end

            -- Show project-wide options (read-only)
            local proj_opts = opts.project_options or {}
            local proj_keys = {}
            for k in pairs(proj_opts) do
                if not inherited[k] and not options[k] then
                    proj_keys[#proj_keys + 1] = k
                end
            end
            table.sort(proj_keys)

            if #proj_keys > 0 then
                t:blank()
                t:leaf("Project-wide options:", "Comment")
                for _, k in ipairs(proj_keys) do
                    t:leaf("  " .. k .. "=" .. proj_opts[k] .. "  (project)", "Comment")
                end
            end
        end

        t:blank()
        t:leaf("[Enter] change  [D] remove option  [y] accept  [q] cancel", "Comment")
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
            -- Custom configs with options support must inherit from a base
            if opts.has_options and not opts.is_default and inherits == "" then
                vim.notify("loomworks: custom configuration must inherit from a base",
                    vim.log.levels.ERROR)
                return {}
            end
            accepted = true
            view:close()
            opts.on_accept({
                name = name,
                inherits = inherits ~= "" and inherits or nil,
                options = options,
                toolchain = toolchain ~= "" and toolchain or nil,
                generator = generator ~= "" and generator or nil,
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
            width = 90,
            height = 0.7,
            zindex = 65,
            backdrop = 65,
            title = " " .. (opts.title or "Configuration") .. " ",
            title_pos = "center",
        },
        keymaps = {
            ["<CR>"] = "enter",
            ["D"]    = "delete",
            ["y"]    = "accept",
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
