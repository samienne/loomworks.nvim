--- loomworks/ui/sections/lsp.lua — LSP section renderer.
---
--- Shows resolved LSP configuration for loomworks-managed projects:
--- active clients, command line args, compile_commands_dir, and
--- per-integration reset/throttle status. Above the per-project list
--- a "Server defaults" group surfaces user-editable knobs (currently
--- clangd's clang-tidy / background-index / priority) backed by
--- `Workspace:set_lsp_option` — changes persist to user.json and
--- trigger a clangd restart on the next event tick.

local PRIORITY_VALUES = { "low", "normal", "background" }

--- Cycle to the next value in a fixed enum, wrapping to the start.
--- @param current string
--- @param values string[]
--- @return string
local function cycle(current, values)
    for i, v in ipairs(values) do
        if v == current then return values[(i % #values) + 1] end
    end
    return values[1]
end

--- Render the clangd-options block. Each row toggles or cycles on
--- Enter and writes through `lw.set_lsp_option`, which persists
--- user.json synchronously and emits `lsp_options_changed` so the
--- integration restarts the client.
--- @param tree loomworks.Tree
--- @param lw table loomworks public API
local function render_clangd_defaults(tree, lw)
    if not lw.get_lsp_options then return end
    local opts = lw.get_lsp_options("clangd")
    tree:node("Server defaults (clangd)", {
        fold_key = "lsp:defaults:clangd",
    }, function()
        local refresh = function() require("loomworks.ui.status").refresh() end

        tree:item(string.format("▸ clang-tidy: %s",
                opts.clang_tidy and "on" or "off"), {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                lw.set_lsp_option("clangd", "clang_tidy", not opts.clang_tidy)
                refresh()
            end,
        })
        tree:item(string.format("▸ background-index: %s",
                opts.background_index and "on" or "off"), {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                lw.set_lsp_option("clangd", "background_index",
                    not opts.background_index)
                refresh()
            end,
        })
        tree:item(string.format("▸ priority: %s",
                opts.background_index_priority or "low"), {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                local next_v = cycle(opts.background_index_priority or "low",
                    PRIORITY_VALUES)
                lw.set_lsp_option("clangd", "background_index_priority", next_v)
                refresh()
            end,
        })
        local extra = opts.extra_args or {}
        local joined = #extra > 0 and table.concat(extra, " ") or ""
        local display = joined ~= "" and joined or "(unset)"
        local hl = joined ~= "" and "LoomworksActionable" or "Comment"
        -- Mirrors the cmd_array editor in sections/projects.lua: one
        -- prompt, space-separated tokens, empty → clear. Tokens with
        -- internal whitespace need to be hand-edited in user.json for
        -- now (matches the project-side limitation).
        tree:item({
            { "extra args: ", "LoomworksSection" },
            { display, hl },
        }, {
            hl = hl,
            direct = true,
            enter_label = "Edit clangd extra args",
            on_enter = function()
                vim.ui.input({
                    prompt = "clangd extra args (space-separated): ",
                    default = joined,
                }, function(val)
                    if val == nil then return end
                    local parts = {}
                    for tok in val:gmatch("%S+") do
                        parts[#parts + 1] = tok
                    end
                    lw.set_lsp_option("clangd", "extra_args", parts)
                    refresh()
                end)
            end,
            on_delete = (joined ~= "") and function()
                lw.set_lsp_option("clangd", "extra_args", {})
                refresh()
            end or nil,
        })
    end)
end

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

    render_clangd_defaults(tree, ctx.lw)
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
