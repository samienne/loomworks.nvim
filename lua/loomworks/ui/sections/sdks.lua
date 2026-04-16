--- loomworks/ui/sections/sdks.lua — SDKs section renderer.
---
--- Shows installed SDKs with resolution status. Allows adding and
--- removing SDKs from the workspace.

local sdk_registry = require("loomworks.sdks")

--- Render the SDKs section.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
    local lw = ctx.lw
    local ws = lw.get_workspace()
    if not ws then return end

    local sdks = ws:sdks()

    -- Only show section if there are SDKs or providers available
    local providers = sdk_registry.list()
    if #sdks == 0 and #providers == 0 then return end

    tree:blank()
    tree:leaf("SDKs", "Title")
    tree:blank()

    for _, sdk in ipairs(sdks) do
        local hl = sdk:is_resolved() and "Comment" or "DiagnosticWarn"
        local path_str = sdk:sdk_path() and ("  " .. sdk:sdk_path()) or ""
        local label = sdk:display_name() .. path_str

        tree:item(label, {
            hl = hl,
            on_delete = function()
                vim.ui.select({ "Yes", "No" }, {
                    prompt = "Remove SDK '" .. sdk:display_name() .. "'?",
                }, function(choice)
                    if choice ~= "Yes" then return end
                    ws:remove_sdk(sdk.key)
                    require("loomworks.ui.status").refresh()
                end)
            end,
        })
    end

    -- Add SDK action
    if #providers > 0 then
        tree:item("▸ Add SDK", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                -- Pick provider type
                local items = {}
                for _, id in ipairs(providers) do
                    local p = sdk_registry.get(id)
                    if p then
                        items[#items + 1] = { id = id, label = p.display_name or id }
                    end
                end

                vim.ui.select(items, {
                    prompt = "SDK type:",
                    format_item = function(item) return item.label end,
                }, function(choice)
                    if not choice then return end

                    -- Try auto-detect first
                    local sdk, err = ws:add_sdk(choice.id)
                    if sdk then
                        vim.notify("loomworks: SDK '" .. sdk:display_name() .. "' added",
                            vim.log.levels.INFO)
                        require("loomworks.ui.status").refresh()
                    else
                        -- Auto-detect failed — prompt for path
                        vim.ui.input({
                            prompt = choice.label .. " SDK path: ",
                        }, function(path)
                            if not path or path == "" then return end
                            local sdk2, err2 = ws:add_sdk(choice.id, path)
                            if sdk2 then
                                vim.notify("loomworks: SDK '" .. sdk2:display_name() .. "' added",
                                    vim.log.levels.INFO)
                            else
                                vim.notify("loomworks: " .. (err2 or "failed to add SDK"),
                                    vim.log.levels.ERROR)
                            end
                            require("loomworks.ui.status").refresh()
                        end)
                    end
                end)
            end,
        })
    end

    tree:blank()
end
