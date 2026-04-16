local M = {}

--- @type table<string, table>
local registry = {}

--- Register a module handler for a project type.
--- @param id string
--- @param mod table
function M.register(id, mod)
    registry[id] = mod
end

--- Get the module handler for a project type, or nil.
--- @param id string
--- @return table|nil
function M.get(id)
    if not registry[id] then
        -- Try to load it
        local ok, mod = pcall(require, "loomworks.modules." .. id)
        if ok and type(mod) == "table" and mod.id then
            registry[id] = mod
        end
    end
    return registry[id]
end

--- Get all registered module IDs.
--- @return string[]
function M.list()
    -- Ensure built-in modules are loaded
    for _, id in ipairs({ "cmake", "harmony", "typescript" }) do
        M.get(id)
    end
    local ids = {}
    for id in pairs(registry) do
        ids[#ids + 1] = id
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
