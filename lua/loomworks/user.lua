local M = {}

local io_mod = require("loomworks.io")

local CURRENT_VERSION = 1

--- Return the file path for a workspace root.
--- @param root string
--- @return string
function M.filepath(root)
    return root .. "/.nvim/loomworks.user.json"
end

--- Return a default (empty) UserData structure.
--- @return loomworks.UserData
function M.default()
    return { _meta = { version = CURRENT_VERSION } }
end

--- Parse raw JSON content into UserData.
--- Returns defaults on invalid content. Second return value is true when a
--- version mismatch was detected (valid JSON but wrong version number).
--- @param content string raw JSON content
--- @return loomworks.UserData data, boolean version_mismatch
function M.parse(content)
    local ok, raw = pcall(vim.json.decode, content)
    if not ok or type(raw) ~= "table" then
        return M.default(), false
    end
    if not raw._meta or raw._meta.version ~= CURRENT_VERSION then
        return M.default(), true
    end
    return raw, false
end

--- Load user preferences for a workspace.
--- Returns defaults if file doesn't exist.
--- @param root string
--- @return loomworks.UserData
function M.load(root)
    local data, err = io_mod.read_json(M.filepath(root))
    if not data then
        return M.default()
    end

    if not data._meta or data._meta.version ~= CURRENT_VERSION then
        vim.notify("loomworks: user.json has unexpected version, using defaults", vim.log.levels.WARN)
        return M.default()
    end

    return data
end

--- Save user preferences for a workspace.
--- @param root string
--- @param data loomworks.UserData
--- @return boolean ok, string|nil err
function M.save(root, data)
    data._meta = { version = CURRENT_VERSION }

    local dir = root .. "/.nvim"
    local ok, dir_err = io_mod.ensure_dir(dir)
    if not ok then return false, "mkdir: " .. (dir_err or "unknown") end

    return io_mod.write_json(M.filepath(root), data)
end

return M
