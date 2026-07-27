--- loomworks/ui/v2/palette.lua — Command palette for v2.
---
--- Builds a list of action entries from the current workspace state and
--- presents them via `vim.ui.select` (Snacks intercepts when its UI is
--- enabled, otherwise default Neovim picker). Reachable from any buffer.

local M = {}

--- Open the v2 UI and drill into a ref.
--- @param ref table
local function open_and_drill(ref)
    local v2 = require("loomworks.ui.v2")
    v2.open()
    local vm = v2._view_model_for_palette()
    if vm then
        vm:dispatch("drill_in", { ref = ref })
    end
end

--- Build the list of palette entries for the current workspace state.
--- @return { label: string, run: fun() }[]
function M.build_entries()
    local lw = require("loomworks")
    local ws = lw.get_workspace and lw.get_workspace() or nil
    local entries = {}

    entries[#entries + 1] = {
        label = "Open loomworks v2 UI",
        run = function() require("loomworks.ui.v2").toggle() end,
    }
    entries[#entries + 1] = {
        label = "Workspace cleanup",
        run = function() open_and_drill({ kind = "cleanup_audit" }) end,
    }
    entries[#entries + 1] = {
        label = "Rescan tools",
        run = function() lw.rescan_tools() end,
    }
    if ws and ws.has_device_modules and ws:has_device_modules() then
        entries[#entries + 1] = {
            label = "Rescan devices",
            run = function() lw.scan_devices() end,
        }
    end

    if not ws then return entries end

    local active = ws._active_profile

    if active then
        entries[#entries + 1] = {
            label = "Build active profile (" .. active.key .. ")",
            run = function() if active.build then active:build() end end,
        }
        entries[#entries + 1] = {
            label = "Configure active profile (" .. active.key .. ")",
            run = function() if active.configure then active:configure() end end,
        }
    end

    for _, p in pairs(ws._profiles or {}) do
        if p.key ~= (active and active.key or nil) then
            local key = p.key
            entries[#entries + 1] = {
                label = "Activate profile: " .. key,
                run = function()
                    for _, prof in pairs(ws._profiles or {}) do
                        if prof.key == key and prof.activate then
                            prof:activate()
                            break
                        end
                    end
                end,
            }
        end
    end

    for _, p in pairs(ws._projects or {}) do
        local key = p.key
        entries[#entries + 1] = {
            label = "Inspect project: " .. key,
            run = function() open_and_drill({ kind = "project", key = key }) end,
        }
    end
    for _, p in pairs(ws._profiles or {}) do
        local key = p.key
        entries[#entries + 1] = {
            label = "Inspect profile: " .. key,
            run = function() open_and_drill({ kind = "profile", key = key }) end,
        }
    end
    for _, cs in pairs(ws._config_sets or {}) do
        local name = cs.name
        entries[#entries + 1] = {
            label = "Inspect configuration set: " .. name,
            run = function() open_and_drill({ kind = "config_set", key = name }) end,
        }
    end

    entries[#entries + 1] = {
        label = "Add project",
        run = function()
            vim.ui.input({ prompt = "New project name (also default path): " }, function(name)
                if not name or name == "" then return end
                local ok, modules = pcall(require, "loomworks.modules")
                local types = ok and modules.list and modules.list() or { "cmake" }
                vim.ui.select(types, { prompt = "Project type" }, function(t)
                    if not t then return end
                    if ws.add_project then ws:add_project(name, t, name) end
                end)
            end)
        end,
    }
    entries[#entries + 1] = {
        label = "Add configuration set",
        run = function()
            vim.ui.input({ prompt = "New configuration set name: " }, function(name)
                if not name or name == "" then return end
                if ws.add_configuration_set then ws:add_configuration_set(name, {}) end
            end)
        end,
    }

    return entries
end

--- Open the palette: pick an entry and run it.
function M.open()
    local entries = M.build_entries()
    vim.ui.select(entries, {
        prompt      = "loomworks command palette",
        format_item = function(e) return e.label end,
    }, function(choice)
        if not choice or not choice.run then return end
        choice.run()
    end)
end

return M
