--- loomworks/ui/sections/sdks.lua — SDKs section renderer.
---
--- Shows installed SDKs with resolution status. Allows adding and
--- removing SDKs from the workspace: the picker lists what `Sdks/1.detect`
--- finds, the add and the removal are `Sdks/1.add` / `Sdks/1.remove`
--- (ui/model_calls: the workspace daemon's in `daemon` mode, step 5o C2c-1).

local helpers = require("loomworks.ui.helpers")

--- A typed SDK path made absolute against the editor's working directory
--- (the workspace daemon refuses a relative one: its working directory is
--- not the editor's); `~` expanded, a trailing separator dropped.
--- @param path string
--- @return string
local function absolute(path)
    local abs = vim.fn.fnamemodify(path, ":p")
    if #abs > 1 and abs:match("[/\\]$") and not abs:match("^%a:[/\\]$") then abs = abs:sub(1, -2) end
    return abs
end

--- Declare an SDK (`Sdks/1.add`); the outcome is notified.
--- @param ws loomworks.Workspace|nil
--- @param provider string
--- @param path string absolute
local function add_sdk(ws, provider, path)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "Sdks/1.add", { provider = provider, path = path }, function(r)
        local ok, err = model.result(r)
        if r.sdk then
            vim.notify("loomworks: SDK '" .. tostring(r.sdk.key) .. "' added", vim.log.levels.INFO)
            -- A detection that outran the wait (a warn note): reported too.
            if not ok then vim.notify("loomworks: " .. tostring(err), vim.log.levels.WARN) end
        else
            vim.notify("loomworks: " .. (err or "failed to add SDK"), vim.log.levels.ERROR)
        end
        require("loomworks.ui.status").refresh()
    end)
end

--- The picker's entries from a `Sdks/1.detect` outcome: each detected
--- installation not declared yet (`declared`: lowercased paths), then a
--- "browse for path" entry per provider.
--- @param providers table[] `{ id, label, path_prompt?, found }`
--- @param declared table<string, boolean>
--- @return table[]
local function candidates_of(providers, declared)
    local out = {}
    for _, p in ipairs(providers or {}) do
        for _, inst in ipairs(p.found or {}) do
            if not declared[(inst.path or ""):lower()] then
                local label = p.label
                if inst.version then label = label .. " " .. inst.version end
                out[#out + 1] = { provider_id = p.id, path = inst.path, label = label .. "  " .. inst.path }
            end
        end
        -- The provider's own prompt for a typed path (e.g. "Path to C/C++
        -- compiler executable"), else a generic "<label> SDK path".
        out[#out + 1] = { provider_id = p.id, browse = true, prompt = p.path_prompt or (p.label .. " SDK path"),
            label = p.label .. "  (browse for path...)" }
    end
    return out
end

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
            on_delete = helpers.actionable(ctx, row) and function()
                vim.ui.select({ "Yes", "No" }, {
                    prompt = "Remove SDK '" .. row.label .. "'?",
                }, function(choice)
                    if choice ~= "Yes" then return end
                    local model = require("loomworks.ui.model_calls")
                    model.call(ws, "Sdks/1.remove", { sdk = row }, function(r)
                        local ok, err = model.result(r)
                        if not ok then
                            vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
                        end
                        require("loomworks.ui.status").refresh()
                    end)
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
                local declared = {}
                for _, s in ipairs(sdks) do
                    if s.path then declared[s.path:lower()] = true end
                end
                local model = require("loomworks.ui.model_calls")
                model.call(ws, "Sdks/1.detect", {}, function(r)
                    if r.outcome ~= "ok" then
                        local _, err = model.result(r)
                        vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
                        return
                    end
                    local candidates = candidates_of(r.providers, declared)
                    if #candidates == 0 then
                        vim.notify("loomworks: no SDK providers available", vim.log.levels.INFO)
                        return
                    end
                    vim.ui.select(candidates, {
                        prompt = "Add SDK:",
                        format_item = function(item) return item.label end,
                    }, function(choice)
                        if not choice then return end
                        if not choice.browse then return add_sdk(ws, choice.provider_id, choice.path) end
                        vim.ui.input({ prompt = choice.prompt .. ": " }, function(path)
                            if not path or path == "" then return end
                            add_sdk(ws, choice.provider_id, absolute(path))
                        end)
                    end)
                end)
            end,
        })
    end

    tree:blank()
end
