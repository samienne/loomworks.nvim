local M = {}

--- @type table<string, table>
local registry = {}

--- Register a module handler for a project type.
--- @param id string
--- @param mod table
function M.register(id, mod)
    registry[id] = mod
end

local API = require("loomworks.api_versions")

--- Track modules whose load attempt failed (file present but
--- contract-mismatched or version-mismatched) so we don't spam the
--- same warning every time M.get is called for that id.
--- @type table<string, true>
local rejected = {}

--- Notify the user once that a module file failed the load check.
--- Routed through vim.notify so it shows on the first nvim load
--- the mismatch happens; subsequent gets stay silent.
--- @param id string
--- @param reason string
local function reject(id, reason)
    if rejected[id] then return end
    rejected[id] = true
    vim.notify(
        "loomworks: module '" .. id .. "' will not load: " .. reason,
        vim.log.levels.ERROR)
end

--- Get the module handler for a project type, or nil.
--- @param id string
--- @return table|nil
function M.get(id)
    if registry[id] then return registry[id] end
    if rejected[id] then return nil end
    local ok, mod = pcall(require, "loomworks.modules." .. id)
    if not ok then
        -- File not present on rtp (or load-time error). Not a
        -- "rejection" we want to warn about — it just means no
        -- plugin ships this module. Stay quiet.
        return nil
    end
    if type(mod) ~= "table" then
        reject(id, "module did not return a table")
        return nil
    end
    if mod.id ~= id then
        reject(id, "module declares id='" .. tostring(mod.id)
            .. "' but file is loomworks.modules." .. id)
        return nil
    end
    if mod.api_version ~= API.module then
        reject(id, "module declares api_version="
            .. tostring(mod.api_version)
            .. " but loomworks core requires "
            .. tostring(API.module)
            .. ". Update the module's plugin or pin a compatible "
            .. "loomworks.nvim. No backwards compatibility — see "
            .. "loomworks/api_versions.lua.")
        return nil
    end
    registry[id] = mod
    return mod
end

--- Get all registered module IDs.
---
--- Discovery walks the runtime path for `lua/loomworks/modules/*.lua`.
--- Any plugin (built-in or third-party) that ships a file at that
--- import path appears here. Mirrors the SDK provider registry in
--- `loomworks/sdks/init.lua` so the registration mechanism is the same
--- whichever side of the boundary the module lives on.
--- @return string[]
function M.list()
    local ids = {}
    local seen = {}
    local files = vim.api.nvim_get_runtime_file("lua/loomworks/modules/*.lua", true)
    for _, path in ipairs(files) do
        -- The id is the final path segment only. `[^/\\]+` (not `.+`) so a path
        -- that contains "modules" more than once — as an acquired module's
        -- install path does (…/modules/<id>/lua/loomworks/modules/<id>.lua) —
        -- captures just <id>, not everything after the first "modules".
        local id = path:match("modules[/\\]([^/\\]+)%.lua$")
        if id and id ~= "init" and not seen[id] then
            seen[id] = true
            -- Lazy-load so an invalid module doesn't poison list()
            -- itself; M.get drops modules whose require fails or whose
            -- module table is missing the required `id` field.
            if M.get(id) then
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return ids
end

--- Detect ALL matching project types for a directory.
--- A folder can match multiple modules (e.g., CMakeLists.txt + tsconfig.json).
--- @param abs_path string
--- @return { type: string, marker: string }[]
function M.detect_all_types(abs_path)
    local results = {}
    for _, id in ipairs(M.list()) do
        local mod = M.get(id)
        if mod and mod.detect then
            local ok, hit = pcall(mod.detect, abs_path)
            if ok and hit then
                results[#results + 1] = { type = id, marker = hit.marker }
            end
        end
    end
    return results
end

--- Default directory names to skip during scanning.
local DEFAULT_FILTER = {
    [".git"] = true,
    [".nvim"] = true,
    [".cache"] = true,
    [".vs"] = true,
    [".vscode"] = true,
    ["node_modules"] = true,
    ["build"] = true,
    ["out"] = true,
    ["__pycache__"] = true,
}

--- Async: list subdirectories and detect all types for each.
--- Filters out hidden dirs (starting with .) and common non-project dirs.
--- @param abs_path string directory to scan
--- @param filter? string[] extra directory names to exclude
--- @param callback fun(entries: { name: string, abs_path: string, types: { type: string, marker: string }[] }[])
function M.scan_directory_async(abs_path, filter, callback)
    local uv = vim.uv or vim.loop
    local skip = vim.tbl_extend("force", DEFAULT_FILTER, {})
    if filter then
        for _, name in ipairs(filter) do
            skip[name] = true
        end
    end

    uv.fs_scandir(abs_path, function(err, handle)
        if err or not handle then
            vim.schedule(function() callback({}) end)
            return
        end

        local dirs = {}
        while true do
            local name, ftype = uv.fs_scandir_next(handle)
            if not name then break end
            if ftype == "directory" and not skip[name] and name:sub(1, 1) ~= "." then
                dirs[#dirs + 1] = name
            end
        end

        table.sort(dirs)

        -- Detect types on main thread (modules may use sync fs_stat)
        vim.schedule(function()
            local entries = {}
            for _, name in ipairs(dirs) do
                local child_path = abs_path .. "/" .. name
                local types = M.detect_all_types(child_path)
                entries[#entries + 1] = {
                    name = name,
                    abs_path = child_path,
                    types = types,
                }
            end
            callback(entries)
        end)
    end)
end

return M
