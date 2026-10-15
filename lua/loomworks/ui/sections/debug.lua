--- loomworks/ui/sections/debug.lua — Debug adapter section renderer.
---
--- Shows current debug adapter selection per language of the workspace's
--- modules. Allows picking from known adapters via Enter action.
---
--- The mapping comes from loomworks.daemon.editor_ops: in `daemon` mode
--- `DebugConfig/1` (step 5k C2, spec §19.16 "Editor operations"), the
--- section unavailable while it is not carried (step 5s, "Availability");
--- in the `in-process` mode the working copy. Whether an adapter is
--- installed is always nvim-dap's answer, here.

local debug_mod = require("loomworks.debug")

--- Render the Debug Adapters section.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
    local lw = ctx.lw
    local ws = lw.get_workspace()
    if not ws then return end

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

    local ops = require("loomworks.daemon.editor_ops")
    local records, why = ops.debug_adapters(ws)
    local by_lang = {}
    for _, r in ipairs(records or {}) do
        if type(r) == "table" and r.language then by_lang[r.language] = r end
    end

    tree:blank()
    tree:leaf("Debug Adapters", "Title")
    tree:blank()

    if not records then
        tree:leaf("unavailable — " .. tostring(why), "DiagnosticWarn")
        tree:blank()
        return
    end

    for _, lang in ipairs(languages) do
        local rec = by_lang[lang] or {}
        local current = rec.adapter
        local default = rec.default

        if not current and not default then goto next_lang end

        local is_default = (current == default)
        local label = lang .. "  →  " .. (current or "(none)")
        if is_default and current then
            label = label .. "  (default)"
        end

        local hl = debug_mod.adapter_installed(current) and "Comment" or "DiagnosticWarn"

        tree:item(label, {
            hl = hl,
            on_enter = function()
                local known = type(rec.known) == "table" and rec.known or {}
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
                        if debug_mod.adapter_installed(adapter) then
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
                    -- The default removes the override from user.json.
                    local adapter = choice ~= default and choice or nil
                    if adapter == nil and not rec.overridden then return end
                    ops.set_debug_adapter(ws, lang, adapter, function()
                        require("loomworks.ui.status").refresh()
                    end)
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
