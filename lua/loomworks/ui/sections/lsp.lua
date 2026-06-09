--- loomworks/ui/sections/lsp.lua — LSP section renderer.
---
--- Shows resolved LSP configuration for loomworks-managed projects:
--- active clients, command line args, compile_commands_dir, and
--- per-integration reset/throttle status.

--- Render the LSP section.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
    local ok, lsp = pcall(require, "loomworks.lsp")
    if not ok then return end

    local status = lsp.get_status()
    if not status or #status == 0 then return end

    tree:blank()
    tree:leaf("LSP", "Title")
    tree:blank()

    for _, entry in ipairs(status) do
        local n = #entry.clients
        local client_str = n > 0
            and (n .. " client" .. (n > 1 and "s" or ""))
            or "no clients"
        local hl = n > 0 and "DiagnosticOk" or "Comment"

        tree:node(entry.project_key .. " [" .. entry.project_type .. "] (" .. client_str .. ")", {
            fold_key = "lsp:" .. entry.project_key,
            hl = hl,
        }, function()
            -- Show resolved command (from our cmd wrapper)
            if entry.resolved_cmd then
                tree:leaf("cmd: " .. table.concat(entry.resolved_cmd, " "), "Comment")
            end

            -- Show each matched client
            for _, client in ipairs(entry.clients) do
                tree:leaf(client.name .. " (#" .. client.id .. ")", "Comment")
            end

            -- cmake-specific: compile_commands resolution
            if entry.extra and entry.extra.compile_commands_dir then
                tree:leaf("compile_commands_dir: " .. entry.extra.compile_commands_dir, "Comment")
            elseif entry.project_type == "cmake" then
                tree:leaf("compile_commands_dir: (not found)", "DiagnosticWarn")
            end

            if #entry.clients == 0 then
                tree:leaf("No active clients", "Comment")
            end

            -- Per-integration reset action. The integration declares
            -- `reset(root_dir)` + a `reset_label`; we don't look at the
            -- server name here — any integration with adaptive state
            -- (clangd's -j step-down today, anything similar tomorrow)
            -- gets a row without touching the core UI section.
            for _, client in ipairs(entry.clients) do
                local integration = lsp.integration(client.name)
                if integration and integration.reset then
                    local server = client.name
                    local root_dir = entry.root_dir
                    local suppressed = lsp.is_suppressed(server, root_dir)
                    local label = integration.reset_label or ("▸ Reset " .. server)
                    if suppressed then
                        label = label .. "  (auto-restart suppressed)"
                    end
                    tree:item("▸ " .. label, {
                        hl = suppressed and "DiagnosticWarn" or "LoomworksActionable",
                        direct = true,
                        on_enter = function()
                            integration.reset(root_dir)
                            vim.notify("loomworks.lsp: reset " .. server
                                .. " for " .. root_dir, vim.log.levels.INFO)
                            require("loomworks.ui.status").refresh()
                        end,
                    })
                    break  -- one reset row per server is plenty
                end
            end
        end)
    end

    tree:blank()
end
