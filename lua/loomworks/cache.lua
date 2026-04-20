local M = {}

local io_mod = require("loomworks.io")

local CURRENT_VERSION = 8

--- Return the file path for a workspace root.
--- @param root string
--- @return string
function M.filepath(root)
    return root .. "/.nvim/loomworks.cache.json"
end

--- Compute a hash of loomworks.json content for fast change detection.
--- @param config_content string
--- @return string
function M.compute_hash(config_content)
    local hash = vim.fn.sha256(config_content)
    return hash:sub(1, 12)
end

--- Build the cache key for a configuration entry.
--- Opaque identifier — never parse this to extract parts.
--- @deprecated v6 compat — will be removed once all callers migrate to build_dir keys
--- @param project_key string
--- @param config_key string
--- @return string
function M.config_cache_key(project_key, config_key)
    return project_key .. "/" .. config_key
end

--- Return the next available key that doesn't collide with existing entries.
--- If base_key is available, returns it unchanged. Otherwise appends -2, -3, etc.
--- @param base_key string desired key
--- @param existing table<string, any> dict of existing keys
--- @return string available_key
function M.next_available_key(base_key, existing)
    if not existing[base_key] then return base_key end
    local n = 2
    while existing[base_key .. "-" .. n] do
        n = n + 1
    end
    return base_key .. "-" .. n
end

--- Compute relative build_dir key from absolute path.
--- Strips {root}/.nvim/ prefix. Returns path relative to .nvim/.
--- @param abs_path string absolute build dir path
--- @param root string workspace root path
--- @return string relative key (e.g., "build/App/Debug")
function M.relative_build_dir(abs_path, root)
    local prefix = root .. "/.nvim/"
    if abs_path:sub(1, #prefix) == prefix then
        return abs_path:sub(#prefix + 1)
    end
    return abs_path  -- fallback: use as-is (external build dirs)
end

--- Compute absolute build_dir from relative key.
--- Prepends {root}/.nvim/ prefix.
--- @param rel_key string relative build dir key (e.g., "build/App/Debug")
--- @param root string workspace root path
--- @return string absolute path
function M.absolute_build_dir(rel_key, root)
    -- If already absolute, return as-is
    if rel_key:sub(1, 1) == "/" or rel_key:match("^%a:") then
        return rel_key
    end
    return root .. "/.nvim/" .. rel_key
end

--- Return a default (empty) CacheData structure.
--- @return loomworks.CacheData
function M.default()
    return {
        _meta = { version = CURRENT_VERSION, loomworks_hash = "", cached_at = "" },
        build_dirs = {},
        deploy_state = {},
    }
end

--- One-way transparent migration v7 → v8: rename build_dir entry field
--- `cmake` to `module_info`. Lets pre-existing caches load after the
--- cmake_info→module_info rename without a nuke. Safe to remove after
--- all dev caches have been rewritten at v8.
--- TODO: remove once all tracked dev workspaces have migrated.
--- @param raw table parsed cache
--- @return boolean migrated true if a migration happened
local function migrate_v7_to_v8(raw)
    if not raw._meta or raw._meta.version ~= 7 then return false end
    if raw.build_dirs then
        for _, entry in pairs(raw.build_dirs) do
            if entry.cmake ~= nil and entry.module_info == nil then
                entry.module_info = entry.cmake
            end
            entry.cmake = nil
        end
    end
    raw._meta.version = CURRENT_VERSION
    return true
end

--- Parse raw JSON content into CacheData.
--- Returns defaults on invalid content. Second return value is true when a
--- version mismatch was detected (valid JSON but wrong version number).
--- Applies transparent migrations for recent schema bumps (see
--- `migrate_v7_to_v8`).
--- @param content string raw JSON content
--- @return loomworks.CacheData data, boolean version_mismatch
function M.parse(content)
    local ok, raw = pcall(vim.json.decode, content)
    if not ok or type(raw) ~= "table" then
        return M.default(), false
    end
    migrate_v7_to_v8(raw)
    if not raw._meta or raw._meta.version ~= CURRENT_VERSION then
        return M.default(), true
    end
    raw.build_dirs = raw.build_dirs or {}
    raw.deploy_state = raw.deploy_state or {}
    return raw, false
end

--- Validate internal consistency of cache data.
--- Checks that every build_dirs entry has a project_key and variant field.
--- @param data loomworks.CacheData
--- @return boolean ok, string|nil err
function M.validate_consistency(data)
    local build_dirs = data.build_dirs or {}
    for dir_key, entry in pairs(build_dirs) do
        if not entry.project_key then
            return false, "build_dir '" .. dir_key .. "' is missing project_key"
        end
        if not entry.variant then
            return false, "build_dir '" .. dir_key .. "' is missing variant field"
        end
    end
    return true
end

--- Load cache for a workspace.
--- Returns defaults if file doesn't exist.
--- @param root string
--- @return loomworks.CacheData
function M.load(root)
    local data, err = io_mod.read_json(M.filepath(root))
    if not data then
        return M.default()
    end

    if not data._meta or data._meta.version ~= CURRENT_VERSION then
        vim.notify("loomworks: cache.json has unexpected version, using defaults", vim.log.levels.WARN)
        return M.default()
    end

    data.build_dirs = data.build_dirs or {}
    data.deploy_state = data.deploy_state or {}

    return data
end

--- Save cache for a workspace.
--- @param root string
--- @param data loomworks.CacheData
--- @return boolean ok, string|nil err
function M.save(root, data)
    data._meta = data._meta or {}
    data._meta.version = CURRENT_VERSION
    data._meta.cached_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local dir = root .. "/.nvim"
    local ok, dir_err = io_mod.ensure_dir(dir)
    if not ok then return false, "mkdir: " .. (dir_err or "unknown") end

    return io_mod.write_json(M.filepath(root), data)
end

return M
