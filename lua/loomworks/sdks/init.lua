--- loomworks/sdks/init.lua — SDK provider registry.
---
--- Auto-discovers SDK providers from runtimepath. Third-party plugins
--- can add providers by placing files in lua/loomworks/sdks/.

local API = require("loomworks.api_versions")

local M = {}

--- @type table<string, table> cached providers by id
local _providers = {}

--- Track providers whose load attempt failed (file present but
--- contract-mismatched or version-mismatched) so we don't spam the
--- same warning every time M.get is called.
--- @type table<string, true>
local _rejected = {}

local function reject(id, reason)
    if _rejected[id] then return end
    _rejected[id] = true
    vim.notify(
        "loomworks: SDK provider '" .. id .. "' will not load: " .. reason,
        vim.log.levels.ERROR)
end

--- List all available provider IDs from runtimepath.
--- @return string[]
function M.list()
    local ids = {}
    local seen = {}
    local files = vim.api.nvim_get_runtime_file("lua/loomworks/sdks/*.lua", true)
    for _, path in ipairs(files) do
        -- Final path segment only (`[^/\\]+`, not `.+`): an acquired module's
        -- SDK provider lives at …/modules/<name>/lua/loomworks/sdks/<id>.lua, so
        -- a greedy capture from the first separator would mangle the id.
        local id = path:match("sdks[/\\]([^/\\]+)%.lua$")
        if id and id ~= "init" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

--- Get a provider by ID. Lazy-loads and caches.
--- @param id string provider identifier (e.g., "cpp_compiler")
--- @return table|nil provider module
function M.get(id)
    if _providers[id] then return _providers[id] end
    if _rejected[id] then return nil end
    local ok, mod = pcall(require, "loomworks.sdks." .. id)
    if not ok then return nil end
    if type(mod) ~= "table" then
        reject(id, "provider did not return a table")
        return nil
    end
    if mod.id ~= id then
        reject(id, "provider declares id='" .. tostring(mod.id)
            .. "' but file is loomworks.sdks." .. id)
        return nil
    end
    if mod.api_version ~= API.sdk then
        reject(id, "provider declares api_version="
            .. tostring(mod.api_version)
            .. " but loomworks core requires "
            .. tostring(API.sdk)
            .. ". Update the SDK provider's plugin or pin a "
            .. "compatible loomworks.nvim. No backwards "
            .. "compatibility — see loomworks/api_versions.lua.")
        return nil
    end
    _providers[id] = mod
    return mod
end

--- Get all loaded providers.
--- @return table<string, table>
function M.all()
    -- Ensure all providers are loaded
    for _, id in ipairs(M.list()) do
        M.get(id)
    end
    return _providers
end

return M
