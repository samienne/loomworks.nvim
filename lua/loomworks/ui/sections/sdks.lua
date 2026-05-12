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

        -- Enumerate kits the SDK exposes (platform × arch). Shown
        -- when the node is unfolded so the user can see at a glance
        -- which combinations are available. Picking still happens
        -- via the profile-level Toolchain row — these leaves are
        -- purely informational.
        local kits = sdk:is_resolved() and sdk:kits() or {}

        tree:node(label, {
            fold_key = "sdk:" .. sdk.key,
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
        }, function()
            if #kits == 0 then
                if sdk:is_resolved() then
                    tree:leaf("(no kits exposed)", "Comment")
                else
                    tree:leaf("(SDK not resolved — install missing)",
                        "DiagnosticWarn")
                end
            else
                for _, kit in ipairs(kits) do
                    tree:leaf("  " .. sdk:kit_label(kit.platform, kit.arch),
                        "Comment")
                end
            end
        end)
    end

    -- Add SDK action
    if #providers > 0 then
        tree:item("▸ Add SDK", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                -- Collect all detected installations from all providers,
                -- plus a "Browse..." option per provider for manual path
                local candidates = {}
                local existing_paths = {}
                for _, s in ipairs(sdks) do
                    if s:sdk_path() then existing_paths[s:sdk_path():lower()] = true end
                end

                for _, id in ipairs(providers) do
                    local p = sdk_registry.get(id)
                    if not p then goto next_provider end
                    local display = p.display_name or id
                    -- Detect installations
                    local ok, installations = pcall(p.detect_all)
                    if ok then
                        for _, inst in ipairs(installations) do
                            -- Skip already-added SDKs
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
                    -- Manual path option
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
                        vim.ui.input({
                            prompt = (sdk_registry.get(choice.provider_id).display_name or choice.provider_id)
                                .. " SDK path: ",
                        }, function(path)
                            if not path or path == "" then return end
                            local sdk2, err = ws:add_sdk(choice.provider_id, path)
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
                        local sdk2, err = ws:add_sdk(choice.provider_id, choice.path)
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
