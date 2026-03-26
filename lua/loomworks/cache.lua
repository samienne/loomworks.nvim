local M = {}

local io_mod = require("loomworks.io")

local CURRENT_VERSION = 6

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
--- @param project_key string
--- @param config_key string
--- @return string
function M.config_cache_key(project_key, config_key)
    return project_key .. "/" .. config_key
end

--- Return a default (empty) CacheData structure.
--- @return loomworks.CacheData
function M.default()
    return {
        _meta = { version = CURRENT_VERSION, loomworks_hash = "", cached_at = "" },
        configurations = {},
    }
end

--- Parse raw JSON content into CacheData.
--- Returns defaults on invalid content. Second return value is true when a
--- version mismatch was detected (valid JSON but wrong version number).
--- @param content string raw JSON content
--- @return loomworks.CacheData data, boolean version_mismatch
function M.parse(content)
    local ok, raw = pcall(vim.json.decode, content)
    if not ok or type(raw) ~= "table" then
        return M.default(), false
    end
    if not raw._meta or raw._meta.version ~= CURRENT_VERSION then
        return M.default(), true
    end
    raw.configurations = raw.configurations or {}
    return raw, false
end

--- Validate internal consistency of cache data.
--- Checks that every configuration referenced by a profile exists in the
--- configurations dict and has a variant field.
--- @param data loomworks.CacheData
--- @return boolean ok, string|nil err
function M.validate_consistency(data)
    if not data.profiles then return true end
    local configs = data.configurations or {}
    for profile_key, profile in pairs(data.profiles) do
        if profile.configurations then
            for _, ck in ipairs(profile.configurations) do
                local entry = configs[ck]
                if not entry then
                    return false, "profile '" .. profile_key
                        .. "' references missing configuration '" .. ck .. "'"
                end
                if not entry.variant then
                    return false, "configuration '" .. ck
                        .. "' is missing variant field"
                end
            end
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

    data.configurations = data.configurations or {}

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
