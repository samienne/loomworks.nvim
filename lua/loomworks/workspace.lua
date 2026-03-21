--- loomworks/workspace.lua — Workspace class and assembly functions.
--- Workspace is the domain container: owns projects, profiles, config sets,
--- config units, and all object registries. Core owns infrastructure (I/O,
--- modules, events, tool detection). Domain objects reference Workspace.

local M = {}

local config_mod = require("loomworks.config")
local user_mod = require("loomworks.user")
local cache_mod = require("loomworks.cache")
local ConfigUnit = require("loomworks.config_unit")

-- ========================== Static helpers ==========================

--- Resolve and normalize a workspace root path.
--- @param path? string directory path (defaults to cwd)
--- @param normalize? fun(path: string): string path normalizer (injectable)
--- @return string root
function M.resolve_root(path, normalize)
    normalize = normalize or function(p) return vim.fs.normalize(vim.fn.fnamemodify(p, ":p")) end
    local root = normalize(path or vim.fn.getcwd())
    -- Strip trailing slash (normalize may leave one for root dirs)
    return root:gsub("/$", "")
end

--- Return the file paths that a workspace root implies.
--- @param root string absolute workspace root
--- @return { config: string, user: string, cache: string }
function M.paths(root)
    return {
        config = root .. "/loomworks.json",
        user = user_mod.filepath(root),
        cache = cache_mod.filepath(root),
    }
end

--- Assemble workspace data from raw file contents.
--- Pure function: no file I/O, no side effects.
--- Returns a plain data table (not a Workspace instance).
--- @param root string absolute workspace root
--- @param config_content string|nil raw loomworks.json content
--- @param user_content string|nil raw user.json content
--- @param cache_content string|nil raw cache.json content
--- @return loomworks.WorkspaceData|nil ws, string|nil err
function M.assemble(root, config_content, user_content, cache_content)
    if not config_content then
        return nil, "loomworks.json not found or empty in " .. root
    end

    local config, config_err = config_mod.parse(config_content, root)
    if not config then
        return nil, config_err
    end

    local user_data, user_version_mismatch
    if user_content then
        user_data, user_version_mismatch = user_mod.parse(user_content)
    else
        user_data = user_mod.default()
        user_version_mismatch = false
    end

    local cache_data, cache_version_mismatch
    if cache_content then
        cache_data, cache_version_mismatch = cache_mod.parse(cache_content)
    else
        cache_data = cache_mod.default()
        cache_version_mismatch = false
    end

    -- Update cache hash from raw content
    if cache_data._meta then
        cache_data._meta.loomworks_hash = cache_mod.compute_hash(config_content)
    end

    local dir_name = root:match("([^/]+)$") or root

    return {
        root = root,
        name = config.name or dir_name,
        config = config,
        user = user_data,
        cache = cache_data,
        cache_version_mismatch = cache_version_mismatch,
        user_version_mismatch = user_version_mismatch,
    }, nil
end

-- ========================== Workspace class ==========================

--- @class loomworks.Workspace
--- @field _core loomworks.Core back-reference to infrastructure
--- @field root string absolute workspace root
--- @field name string workspace display name
--- @field config loomworks.Config parsed config
--- @field user loomworks.UserData parsed user data
--- @field cache loomworks.CacheData parsed cache data
--- @field cache_version_mismatch boolean
--- @field user_version_mismatch boolean
--- @field _active_set loomworks.ActiveSet|nil
--- @field _config_units table<string, loomworks.ConfigUnit> "project\0config" -> unit
--- @field _config_sets table<string, loomworks.ConfigurationSet> name -> ConfigurationSet
--- @field _profiles table<string, loomworks.Profile>
--- @field _projects table<string, loomworks.Project>
--- @field _profile_projects table<string, loomworks.ProfileProject> "profile\0project" -> ProfileProject
--- @field _operations loomworks.Operation[] active operations
--- @field _tools_by_type table<string, loomworks.DetectedTool[]> tools per module type
--- @field _tool_state "not_scanned"|"scanning"|"scanned"
--- @field _tool_waiters function[]
--- @field _delete_waiters function[]
local Workspace = {}
Workspace.__index = Workspace

--- Create a new Workspace instance from assembled data.
--- @param core loomworks.Core back-reference to infrastructure
--- @param data loomworks.WorkspaceData assembled workspace data
--- @return loomworks.Workspace
function Workspace.new(core, data)
    local self = setmetatable({}, Workspace)
    self._core = core

    -- Copy data fields from assembled workspace
    self.root = data.root
    self.name = data.name
    self.config = data.config
    self.user = data.user
    self.cache = data.cache
    self.cache_version_mismatch = data.cache_version_mismatch
    self.user_version_mismatch = data.user_version_mismatch

    -- Object registries (moved from Core)
    self._active_set = nil
    self._config_units = {}
    self._config_sets = {}
    self._profiles = {}
    self._projects = {}
    self._profile_projects = {}
    self._operations = {}
    self._tools_by_type = {}
    self._tool_state = "not_scanned"
    self._tool_waiters = {}
    self._delete_waiters = {}

    return self
end

--- Get or create a ConfigUnit for a (project_key, config_key) pair.
--- Returns the same instance for the same pair (registry/flyweight pattern).
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function Workspace:get_config_unit(project_key, config_key)
    local key = project_key .. "\0" .. config_key
    local unit = self._config_units[key]
    if not unit then
        unit = ConfigUnit.new(self, project_key, config_key)
        self._config_units[key] = unit
    end
    return unit
end

M.Workspace = Workspace

return M
