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
    -- Normalize inherits to array
    local inherits = opts.inherits or {}
    if type(inherits) == "string" then
        inherits = inherits ~= "" and { inherits } or {}
    else
        inherits = vim.deepcopy(inherits)
    end
    local options = vim.deepcopy(opts.options or {})
    local variables = vim.deepcopy(opts.variables or {})
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
            -- Show rename side-effects when name has changed
            if not name_error and opts.rename_effects then
                local effects = opts.rename_effects(name)
                if effects then
                    t:leaf("Rename will also update:", "DiagnosticWarn")
                    for _, effect in ipairs(effects) do
                        t:leaf("  " .. effect, "DiagnosticWarn")
                    end
                end
            end
        end

        -- Inherits (for custom configs with options support, not for defaults)
        if opts.has_options and not opts.is_default and #opts.available_configs > 0 then
            local is_abstract = #inherits == 0
            if is_abstract then
                t:leaf("Type:      abstract (mixin only, not buildable)", "DiagnosticWarn")
            end
            local inh_display = #inherits > 0
                and table.concat(inherits, ", ") or "(none — abstract)"
            t:leaf("Inherits:  " .. inh_display,
                #inherits > 0 and "LoomworksActionable" or "Comment")

            -- Show each base with move/remove actions
            local n_bases = #inherits
            for i, base in ipairs(inherits) do
                local idx = i
                local prio_hint = i == n_bases and "  (highest priority)" or ""
                t:item("  " .. i .. ". " .. base .. prio_hint, {
                    hl = "LoomworksActionable",
                    on_move_up = idx > 1 and function()
                        inherits[idx], inherits[idx - 1] = inherits[idx - 1], inherits[idx]
                        if view then
                            view:refresh()
                            -- Move cursor with the item (one line up)
                            local win = view._snacks_win and view._snacks_win.win
                            if win then
                                local cursor = vim.api.nvim_win_get_cursor(win)
                                pcall(vim.api.nvim_win_set_cursor, win, { cursor[1] - 1, 0 })
                            end
                        end
                    end or nil,
                    on_move_down = idx < n_bases and function()
                        inherits[idx], inherits[idx + 1] = inherits[idx + 1], inherits[idx]
                        if view then
                            view:refresh()
                            -- Move cursor with the item (one line down)
                            local win = view._snacks_win and view._snacks_win.win
                            if win then
                                local cursor = vim.api.nvim_win_get_cursor(win)
                                pcall(vim.api.nvim_win_set_cursor, win, { cursor[1] + 1, 0 })
                            end
                        end
                    end or nil,
                    on_delete = function()
                        table.remove(inherits, idx)
                        if view then view:refresh() end
                    end,
                })
            end

            -- Add base button
            t:item("  ▸ Add base", {
                hl = "LoomworksActionable",
                direct = true,
                on_enter = function()
                    -- Filter out already-inherited and self
                    local already = {}
                    for _, b in ipairs(inherits) do already[b] = true end
                    local items = {}
                    for _, c in ipairs(opts.available_configs) do
                        if c ~= name and not already[c] then
                            items[#items + 1] = c
                        end
                    end
                    if #items == 0 then
                        vim.notify("loomworks: no more configs to inherit from",
                            vim.log.levels.INFO)
                        return
                    end
                    vim.ui.select(items, { prompt = "Add base:" }, function(choice)
                        if choice then
                            inherits[#inherits + 1] = choice
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

        -- Variant (read-only, derived from inheritance)
        if opts.has_options then
            local var_display = variant ~= "" and variant or "(none)"
            local var_hint = opts.variant_source
                and ("  (from " .. opts.variant_source .. ")") or ""
            t:leaf("Variant    " .. var_display .. var_hint, "Comment")
        end

        -- Build dir (read-only, computed from cache)
        if opts.build_dir then
            t:leaf("Build dir  " .. opts.build_dir .. "  (computed)", "Comment")
        end

        -- Unified options section
        if opts.has_options then
            t:blank()

            -- Build merged view: all option keys with source info
            local inherited = opts.inherited_options or {}
            local proj_opts = opts.project_options or {}
            local all_keys = {}
            local seen = {}

            -- Collect all unique keys
            for k in pairs(options) do
                if not seen[k] then seen[k] = true; all_keys[#all_keys + 1] = k end
            end
            for k in pairs(inherited) do
                if not seen[k] then seen[k] = true; all_keys[#all_keys + 1] = k end
            end
            for k in pairs(proj_opts) do
                if not seen[k] then seen[k] = true; all_keys[#all_keys + 1] = k end
            end
            table.sort(all_keys)

            if #all_keys > 0 then
                t:leaf("Options:", "Comment")
                for _, k in ipairs(all_keys) do
                    local ek = k
                    local is_own = options[k] ~= nil
                    local inh_info = inherited[k]
                    local proj_val = proj_opts[k]

                    if is_own then
                        -- Own option (editable)
                        local override_hint = ""
                        if inh_info then
                            override_hint = "  (overrides " .. inh_info.value .. " from " .. inh_info.source .. ")"
                        elseif proj_val then
                            override_hint = "  (overrides " .. proj_val .. " from project)"
                        end
                        t:item("  " .. k .. "=" .. options[k] .. override_hint .. " ▸", {
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
                    else
                        -- Inherited or project option (dimmed, Enter to override)
                        local value = inh_info and inh_info.value or proj_val
                        local source = inh_info and inh_info.source or "project"
                        t:item("  " .. k .. "=" .. value .. "  (" .. source .. ")", {
                            hl = "Comment",
                            direct = true,
                            on_enter = function()
                                edit_string(ek .. "=", value, function(v)
                                    if v and v ~= "" then
                                        options[ek] = v
                                        if view then view:refresh() end
                                    end
                                end)
                            end,
                        })
                    end
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
                        -- Pre-fill with inherited value if exists
                        local default_val = ""
                        if inherited[key] then default_val = inherited[key].value
                        elseif proj_opts[key] then default_val = proj_opts[key] end
                        vim.ui.input({ prompt = key .. "=", default = default_val }, function(val)
                            if val then
                                options[key] = val
                                if view then view:refresh() end
                            end
                        end)
                    end)
                end,
            })
        end

        -- Variables section (overrides for project-declared variables)
        local project_vars = opts.project_variables or {}
        local resolved_vars = opts.resolved_variables or {}
        if next(project_vars) then
            t:blank()

            local var_names = {}
            for k in pairs(project_vars) do var_names[#var_names + 1] = k end
            table.sort(var_names)

            t:leaf("Variables:", "Comment")
            for _, vk in ipairs(var_names) do
                local evk = vk  -- capture
                local decl = project_vars[vk]
                local is_own = variables[vk] ~= nil
                local resolved = resolved_vars[vk]

                if is_own then
                    -- Own override (editable)
                    local source_hint = ""
                    if resolved and resolved.source_config then
                        source_hint = "  (overrides " .. resolved.source_config.name .. ")"
                    else
                        source_hint = "  (overrides project default)"
                    end
                    t:item("  " .. vk .. " = " .. variables[vk]
                            .. source_hint .. " ▸", {
                        hl = "LoomworksActionable",
                        direct = true,
                        on_enter = function()
                            edit_string(evk .. " = ", variables[evk], function(v)
                                if v == "" then
                                    variables[evk] = nil
                                else
                                    variables[evk] = v
                                end
                                if view then view:refresh() end
                            end)
                        end,
                        on_delete = function()
                            variables[evk] = nil
                            if view then view:refresh() end
                        end,
                    })
                else
                    -- Inherited or project default (dimmed, Enter to override)
                    local value = resolved and resolved.value or decl.default
                    local source
                    if resolved and resolved.source_config then
                        source = resolved.source_config.name
                    else
                        source = "project default"
                    end
                    t:item("  " .. vk .. " = " .. value .. "  ("
                            .. source .. ", " .. decl.type .. ")", {
                        hl = "Comment",
                        direct = true,
                        on_enter = function()
                            edit_string(evk .. " = ", value, function(v)
                                if v and v ~= "" then
                                    variables[evk] = v
                                    if view then view:refresh() end
                                end
                            end)
                        end,
                    })
                end
            end
        end

        t:blank()
        t:leaf("[Enter] change  [D] remove override  [y] accept  [q] cancel", "Comment")
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
                inherits = #inherits > 0 and (#inherits == 1 and inherits[1] or inherits) or nil,
                options = options,
                variables = variables,
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
            ["<CR>"]  = "enter",
            ["D"]     = "delete",
            ["<C-k>"] = "move_up",
            ["<C-j>"] = "move_down",
            ["y"]     = "accept",
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
