--- loomworks/ui/sections/debug.lua — Debug adapter section renderer.
---
--- Shows current debug adapter selection per module type.
--- Allows picking from known adapters via Enter action.

local debug_mod = require("loomworks.debug")

--- Render the Debug Adapters section.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
    local lw = ctx.lw
    local ws = lw.get_workspace()
    if not ws then return end

    -- Collect unique languages from all modules
    local modules = ws._modules
    if not modules or #modules == 0 then return end

    local seen = {}
    local languages = {}
    for _, mod in ipairs(modules) do
        for _, lang in ipairs(mod.languages) do
            if not seen[lang] then
                seen[lang] = true
                languages[#languages + 1] = lang
            end
        end
    end
    if #languages == 0 then return end
    table.sort(languages)

    tree:blank()
    tree:leaf("Debug Adapters", "Title")
    tree:blank()

    for _, lang in ipairs(languages) do
        local current = debug_mod.resolve_adapter(ws, lang)
        local default = debug_mod.default_adapter(lang)

        -- Skip languages with no known adapter
        if not current and not default then goto next_lang end

        local is_default = (current == default)
        local label = lang .. "  →  " .. (current or "(none)")
        if is_default and current then
            label = label .. "  (default)"
        end

        -- Check if adapter is available in nvim-dap
        local installed = false
        local ok, dap = pcall(require, "dap")
        if ok and dap.adapters[current] then
            installed = true
        end
        local hl = installed and "Comment" or "DiagnosticWarn"

        tree:item(label, {
            hl = hl,
            on_enter = function()
                local known = debug_mod.known_adapters(lang)
                if #known == 0 then return end

                vim.ui.select(known, {
                    prompt = "Debug adapter for " .. lang .. ":",
                    format_item = function(adapter)
                        local marks = {}
                        if adapter == current then
                            marks[#marks + 1] = "current"
                        end
                        if adapter == default then
                            marks[#marks + 1] = "default"
                        end
                        local ok2, dap2 = pcall(require, "dap")
                        if ok2 and dap2.adapters[adapter] then
                            marks[#marks + 1] = "installed"
                        else
                            marks[#marks + 1] = "not installed"
                        end
                        if #marks > 0 then
                            return adapter .. "  (" .. table.concat(marks, ", ") .. ")"
                        end
                        return adapter
                    end,
                }, function(choice)
                    if not choice then return end
                    if choice == default then
                        -- Reset to default: remove override from user.json
                        if ws._debug_settings
                            and ws._debug_settings.adapters
                            and ws._debug_settings.adapters[lang] then
                            ws._debug_settings.adapters[lang] = nil
                            if not next(ws._debug_settings.adapters) then
                                ws._debug_settings.adapters = nil
                            end
                            if not next(ws._debug_settings) then
                                ws._debug_settings = nil
                            end
                            ws:_save_user()
                        end
                    else
                        ws:set_debug_adapter(lang, choice)
                    end
                    require("loomworks.ui.status").refresh()
                end)
            end,
        })
        ::next_lang::
    end

    if not debug_mod.available() then
        tree:leaf("nvim-dap not installed", "DiagnosticWarn")
    end

    tree:blank()
end
