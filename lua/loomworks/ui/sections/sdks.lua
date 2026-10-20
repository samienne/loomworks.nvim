--- loomworks/ui/sections/sdks.lua — SDKs section renderer.
---
--- Shows installed SDKs with resolution status. Allows adding and
--- removing SDKs from the workspace.

local sdk_registry = require("loomworks.sdks")

--- Render the SDKs section.
--- @param tree loomworks.Tree
--- @param ctx table { view, ref, ws } the workspace view's `sdks`
return function(tree, ctx)
    local ws = ctx.ws
    local sdks = ctx.view.sdks
    if #sdks == 0 and ctx.view.sdk_providers == 0 then return end

    tree:blank()
    tree:leaf("SDKs", "Title")
    tree:blank()

    for _, row in ipairs(sdks) do
        local hl = row.resolved and "Comment" or "DiagnosticWarn"
        local path_str = row.path and ("  " .. row.path) or ""
        local label = row.label .. path_str

        -- Enumerate kits the SDK exposes (platform × arch). Shown
        -- when the node is unfolded so the user can see at a glance
        -- which combinations are available. Picking still happens
        -- via the profile-level Toolchain row — these leaves are
        -- purely informational.
        local kits = row.kits

        tree:node(label, {
            fold_key = "sdk:" .. row.key,
            hl = hl,
            on_delete = ctx.ref(row) and function()
                vim.ui.select({ "Yes", "No" }, {
                    prompt = "Remove SDK '" .. row.label .. "'?",
                }, function(choice)
                    if choice ~= "Yes" then return end
                    local ok, err = require("loomworks.workspace_view").remove_sdk(ws, ctx.ref(row))
                    if not ok then
                        vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
                    end
                    require("loomworks.ui.status").refresh()
                end)
            end or nil,
        }, function()
            if #kits == 0 then
                if row.resolved then
                    tree:leaf("(no kits exposed)", "Comment")
                else
                    tree:leaf("(SDK not resolved — install missing)",
                        "DiagnosticWarn")
                end
            else
                for _, kit_label in ipairs(kits) do
                    tree:leaf("  " .. kit_label, "Comment")
                end
            end
        end)
    end

    if ctx.view.sdk_providers > 0 then
        tree:item("▸ Add SDK", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                local providers = sdk_registry.list()
                local candidates = {}
                local existing_paths = {}
                for _, s in ipairs(sdks) do
                    if s.path then existing_paths[s.path:lower()] = true end
                end

                for _, id in ipairs(providers) do
                    local p = sdk_registry.get(id)
                    if not p then goto next_provider end
                    local display = p.display_name or id
                    local ok, installations = pcall(p.detect_all)
                    if ok then
                        for _, inst in ipairs(installations) do
                            if not existing_paths[(inst.path or ""):lower()] then
                                local label = display
                                if inst.version then label = label .. " " .. inst.version end
                                label = label .. "  " .. inst.path
                                candidates[#candidates + 1] = {
                                    provider_id = id,
                                    path = inst.path,
                                    version = inst.version,
                                    label = label,
                                }
                            end
                        end
                    end
                    candidates[#candidates + 1] = {
                        provider_id = id,
                        browse = true,
                        label = display .. "  (browse for path...)",
                    }
                    ::next_provider::
                end

                if #candidates == 0 then
                    vim.notify("loomworks: no SDK providers available", vim.log.levels.INFO)
                    return
                end

                vim.ui.select(candidates, {
                    prompt = "Add SDK:",
                    format_item = function(item) return item.label end,
                }, function(choice)
                    if not choice then return end

                    if choice.browse then
                        -- Providers may override the prompt label via
                        -- `path_prompt` — useful when "SDK path" is
                        -- misleading (e.g. the C/C++ compiler
                        -- provider wants "Path to C/C++ compiler
                        -- executable"). Falls back to a generic
                        -- "<display_name> SDK path" otherwise.
                        local prov = sdk_registry.get(choice.provider_id)
                        local prompt = prov and prov.path_prompt
                            or ((prov and prov.display_name or choice.provider_id)
                                .. " SDK path")
                        vim.ui.input({
                            prompt = prompt .. ": ",
                        }, function(path)
                            if not path or path == "" then return end
                            local sdk2, err = require("loomworks.workspace_view").add_sdk(ws, choice.provider_id, path)
                            if sdk2 then
                                vim.notify("loomworks: SDK '" .. sdk2:display_name() .. "' added",
                                    vim.log.levels.INFO)
                            else
                                vim.notify("loomworks: " .. (err or "failed to add SDK"),
                                    vim.log.levels.ERROR)
                            end
                            require("loomworks.ui.status").refresh()
                        end)
                    else
                        local sdk2, err = require("loomworks.workspace_view").add_sdk(ws, choice.provider_id, choice.path)
                        if sdk2 then
                            vim.notify("loomworks: SDK '" .. sdk2:display_name() .. "' added",
                                vim.log.levels.INFO)
                        else
                            vim.notify("loomworks: " .. (err or "failed to add SDK"),
                                vim.log.levels.ERROR)
                        end
                        require("loomworks.ui.status").refresh()
                    end
                end)
            end,
        })
    end

    tree:blank()
end
