--- loomworks/sdks/init.lua — SDK provider registry.
---
--- Auto-discovers SDK providers from runtimepath. Third-party plugins
--- can add providers by placing files in lua/loomworks/sdks/.

local M = {}

--- @type table<string, table> cached providers by id
local _providers = {}

--- List all available provider IDs from runtimepath.
--- @return string[]
function M.list()
    local ids = {}
    local seen = {}
    local files = vim.api.nvim_get_runtime_file("lua/loomworks/sdks/*.lua", true)
    for _, path in ipairs(files) do
        local id = path:match("sdks[/\\](.+)%.lua$")
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
    if _providers[id] then
        return _providers[id]
    end
    local ok, mod = pcall(require, "loomworks.sdks." .. id)
    if ok and type(mod) == "table" and mod.id then
        _providers[id] = mod
        return mod
    end
    return nil
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
