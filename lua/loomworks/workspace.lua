--- loomworks/workspace.lua — Workspace class and assembly functions.
--- Workspace is the domain container: owns projects, profiles, config sets,
--- config units, and all object registries. Also owns all business logic
--- (sync, merge, cache, operations, deletion, task tracking, tool scanning).
--- Core owns infrastructure (I/O, modules, events, file tracking, setup).
--- Domain objects reference Workspace.

local M = {}

local config_mod = require("loomworks.config")
local user_mod = require("loomworks.user")
local cache_mod = require("loomworks.cache")
local data_model = require("loomworks.data_model")
local ConfigUnit = require("loomworks.config_unit")
local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local Project = require("loomworks.project")
local ConfigurationSet = require("loomworks.configuration_set")
local Tool = require("loomworks.tool")
local Module = require("loomworks.module")

-- ========================== Static helpers ==========================

--- Validate a name used as a build directory path component.
--- Rejects names that would cause path traversal, nested paths, or
--- sanitization collisions with existing names.
--- @param name string the name to validate
--- @param existing_names? string[] existing names to check for sanitization collisions
--- @return boolean ok, string|nil err
function M.validate_path_name(name, existing_names)
    if not name or name == "" then
        return false, "name cannot be empty"
    end
    if name:find("[/\\]") then
        return false, "name cannot contain slashes"
    end
    if name == "." or name == ".." then
        return false, "name cannot be '.' or '..'"
    end
    -- Check for sanitization collision: names that differ only in chars
    -- replaced by sanitize_path_component (: < > " | ? *) would produce
    -- the same build directory.
    if existing_names then
        local sanitized = name:gsub('[:<>"|?*]', "_"):lower()
        for _, existing in ipairs(existing_names) do
            if existing ~= name then
                local existing_sanitized = existing:gsub('[:<>"|?*]', "_"):lower()
                if existing_sanitized == sanitized then
                    return false, "'" .. name .. "' would produce the same build directory as '" .. existing .. "'"
                end
            end
        end
    end
    return true
end

--- Resolve and normalize a workspace root path.
--- @param path? string directory path (defaults to cwd)
--- @param normalize? fun(path: string): string path normalizer (injectable)
--- @return string root
function M.resolve_root(path, normalize)
    normalize = normalize or function(p)
        local n = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
        -- Windows FS is case-insensitive; lowercase for reliable comparisons
        if vim.fn.has("win32") == 1 then n = n:lower() end
        return n
    end
    local root = normalize(path or vim.fn.getcwd())
    -- Strip trailing slash (normalize may leave one for root dirs)
    return root:gsub("/$", "")
end

--- Create a barebones workspace (loomworks.json) on disk.
--- Bootstrap operation — no Workspace instance needed.
--- Fails if loomworks.json already exists.
--- @param root string workspace root directory
--- @param name? string workspace name (defaults to directory basename)
--- @param write_json? fun(path: string, data: table): boolean, string|nil writer (injectable for testing)
--- @return boolean ok, string|nil err
function M.create_workspace_config(root, name, write_json)
    local path = root .. "/loomworks.json"
    local uv = vim.uv or vim.loop
    if uv.fs_stat(path) then
        return false, "loomworks.json already exists in " .. root
    end

    local dir_name = root:match("([^/]+)$") or root
    local data = {
        name = name or dir_name,
        projects = {},
    }

    write_json = write_json or require("loomworks.io").write_json
    return write_json(path, data)
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

--- Merge user.json and loomworks.json into a single config for merge.merge().
--- User wins at the project level (entire project definition) and at the
--- configuration_set level (entire set definition). Shared items fill in
--- anything the user doesn't override.
--- @param user_config table|nil parsed user data (may have projects, configuration_sets)
--- @param shared_config table|nil parsed loomworks.json config
--- @return table merged config suitable for merge.merge()
--- @return table<string, boolean> user_project_keys set of project keys from user
--- @return table<string, boolean> user_cs_names set of config_set names from user
function M.merge_configs(user_config, shared_config)
    local merged = {
        name = shared_config and shared_config.name or nil,
        projects = {},
        configuration_sets = {},
        profiles = shared_config and shared_config.profiles or nil,
    }
    local user_project_keys = {}
    local user_cs_names = {}

    -- Start with shared
    if shared_config and shared_config.projects then
        for k, v in pairs(shared_config.projects) do
            merged.projects[k] = v
        end
    end
    -- User overrides at project level
    if user_config and user_config.projects then
        for k, v in pairs(user_config.projects) do
            merged.projects[k] = v
            user_project_keys[k] = true
        end
    end

    -- Configuration sets: same pattern
    if shared_config and shared_config.configuration_sets then
        for k, v in pairs(shared_config.configuration_sets) do
            merged.configuration_sets[k] = v
        end
    end
    if user_config and user_config.configuration_sets then
        for k, v in pairs(user_config.configuration_sets) do
            merged.configuration_sets[k] = v
            user_cs_names[k] = true
        end
    end

    -- Empty tables should be nil for downstream compatibility
    if not next(merged.configuration_sets) then
        merged.configuration_sets = nil
    end

    return merged, user_project_keys, user_cs_names
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

    -- Normalize user projects from raw JSON format to internal format
    if user_data.projects and next(user_data.projects) then
        local normalized, norm_err = config_mod.normalize_projects(user_data.projects)
        if normalized then
            user_data.projects = normalized
        else
            vim.notify("loomworks: user.json projects invalid: " .. (norm_err or "unknown"), vim.log.levels.WARN)
            user_data.projects = nil
        end
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

    -- Validate cache internal consistency
    local cache_consistent = true
    if not cache_version_mismatch then
        cache_consistent = cache_mod.validate_consistency(cache_data)
    end

    local dir_name = root:match("([^/]+)$") or root

    return {
        root = root,
        name = config.name or dir_name,
        config = config,
        user = user_data,
        cache = cache_data,
        cache_version_mismatch = cache_version_mismatch,
        cache_inconsistent = not cache_consistent,
        user_version_mismatch = user_version_mismatch,
    }, nil
end

-- ========================== Workspace class ==========================

--- @class loomworks.Workspace
--- @field _core loomworks.Core back-reference to infrastructure
--- @field root string absolute workspace root
--- @field name string workspace display name
--- @field cache_version_mismatch boolean
--- @field user_version_mismatch boolean
--- @field _active_profile_key string|nil persisted active profile key
--- @field _active_profile loomworks.Profile|nil resolved active profile object
--- @field _default_target_data table|nil raw default_target map from user.json
--- @field _active_set loomworks.ActiveSet|nil
--- @field _modules loomworks.Module[] module domain objects
--- @field _config_units loomworks.ConfigUnit[] all config units
--- @field _config_sets loomworks.ConfigurationSet[] all configuration sets
--- @field _profiles loomworks.Profile[] all profiles
--- @field _projects loomworks.Project[] all projects in active set
--- @field _profile_projects loomworks.ProfileProject[] all profile-project pairs
--- @field _operations loomworks.Operation[] active operations
--- @field _tools_by_type table<string, loomworks.DetectedTool[]> detected tools per module type
--- @field _tool_state "not_scanned"|"scanning"|"scanned"
--- @field _tool_waiters function[]
--- @field _delete_waiters function[]
--- @field _build_dir_refs table<string, loomworks.ConfigUnit[]> normalized_build_dir -> units
--- @field _build_dir_locks table<string, loomworks.BuildDirLock> per-build-dir operation locks
--- @field _user_config_overlay table|nil user.json project/configuration_set overlay
--- @field _user_project_keys table<string, boolean> project keys from user.json
--- @field _user_cs_names table<string, boolean> config_set names from user.json
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
    self.cache_version_mismatch = data.cache_version_mismatch
    self.user_version_mismatch = data.user_version_mismatch

    -- Object registries
    self._active_set = nil
    self._active_profile = nil
    self._active_profile_key = nil
    self._default_target_data = nil
    self._config_units = {}
    self._config_sets = {}
    self._profiles = {}
    self._projects = {}
    self._profile_projects = {}
    self._operations = {}
    self._tools_by_type = {}
    self._modules = {} -- id -> Module domain object (tools owned by modules)
    self._user_config_overlay = nil
    self._user_project_keys = {}
    self._user_cs_names = {}
    self._tool_state = "not_scanned"
    self._tool_waiters = {}
    self._delete_waiters = {}
    self._build_dirs = {}  -- BuildDir domain objects (all, including orphaned)
    self._build_dir_refs = {}
    self._build_dir_locks = {}
    self._deploy_records = {}  -- normalized dest path → { source_build_dir, source_rel_path, source_mtime }

    return self
end

--- Get or create a ConfigUnit for a (project_key, config_key) pair.
--- Find an existing ConfigUnit by property match.
--- @param project loomworks.Project
--- @param configuration loomworks.Configuration configuration domain object
--- @param tool? loomworks.Tool tool domain object (nil for non-keyed modules)
--- @return loomworks.ConfigUnit|nil
function Workspace:find_config_unit(project, configuration, tool)
    for _, unit in pairs(self._config_units) do
        if unit._project == project
                and unit._configuration == configuration
                and unit._tool == tool then
            return unit
        end
    end
    return nil
end

--- Find a BuildDir by its relative path.
--- @param rel_path string relative build dir path (cache key)
--- @return loomworks.BuildDir|nil
function Workspace:find_build_dir(rel_path)
    for _, bd in pairs(self._build_dirs) do
        if bd.rel_path == rel_path then return bd end
    end
    return nil
end

--- Compute the expected build directory for a project configuration.
--- Delegates to the module's resolve_build_dir, then relativizes.
--- For modules without resolve_build_dir, uses default path formula.
--- @param project loomworks.Project
--- @param variant string configuration variant name
--- @param tool_data? table module-specific tool data (with .id for cmake kits)
--- @return string relative build_dir key (used as ConfigUnit id and cache key)
--- @return string absolute build_dir path
function Workspace:_compute_build_dir(project, variant, tool_data)
    local mod = project._module and project._module.impl or nil
    local abs_path
    if mod and mod.resolve_build_dir then
        -- Get configuration info from project for binary_dir overrides
        local config_info = nil
        local cfg = project:get_configuration(variant)
        if cfg and cfg.module_config then
            config_info = cfg.module_config
        end
        abs_path = mod.resolve_build_dir(project.key, variant, config_info, self.root, tool_data)
    else
        -- Default: {root}/.nvim/build/{project_key}/{variant}
        -- Include tool id as path segment when present
        local tool_id = tool_data and tool_data.id or nil
        if tool_id then
            abs_path = self.root .. "/.nvim/build/" .. project.key .. "/" .. tool_id .. "/" .. variant
        else
            abs_path = self.root .. "/.nvim/build/" .. project.key .. "/" .. variant
        end
    end
    local rel_key = cache_mod.relative_build_dir(abs_path, self.root)
    return rel_key, abs_path
end

--- Find or create a ConfigUnit for the given project, configuration, and tool.
--- Searches by properties first. If not found, creates a new cache entry
--- and ConfigUnit. Key generation is a write-time cache concern only.
--- @param project loomworks.Project
--- @param configuration loomworks.Configuration configuration domain object
--- @param tool? loomworks.Tool tool domain object (nil for non-keyed modules)
--- @return loomworks.ConfigUnit
function Workspace:ensure_config_unit(project, configuration, tool)
    local existing = self:find_config_unit(project, configuration, tool)
    if existing then return existing end

    local variant = configuration.name
    local tool_key = tool and tool.key or nil
    local tool_data = tool and tool.data or nil
    local config_key = self._core._deps.merge.build_config_key(variant, tool_key)

    -- Compute build_dir-based identity
    local rel_key, abs_path = self:_compute_build_dir(project, variant, tool_data)

    -- Create cache entry as owned data on the ConfigUnit
    local entry = {
        project_key = project.key,
        config_key = config_key,
        type = project.type,
        variant = variant,
        tool_key = tool_key,
        tool_data = tool_data,
        build_dir = abs_path,
    }

    -- Create ConfigUnit and register — pre-resolve references
    local unit = ConfigUnit.new(self, rel_key, project.key)
    unit:_apply({
        cached = entry,
        project = project,
        tool = tool,
        configuration = configuration,
    })
    self._config_units[#self._config_units + 1] = unit
    self:_save_cache()
    return unit
end

-- ===========================================================================
-- Cache helpers
-- ===========================================================================

--- Serialize workspace state to a cache data structure for persistence.
--- Serializes from BuildDir domain objects (both live and orphaned).
--- Also includes ConfigUnit-linked state for live entries (enriches with
--- configuration snapshot from the live Configuration object).
--- Does not include _meta — that is added by cache.save() and _save_cache().
--- @return loomworks.CacheData
function Workspace:_serialize_cache()
    local data = {
        build_dirs = {},
    }

    -- Build a lookup: rel_path → ConfigUnit for enrichment
    local unit_for_bd = {}
    for _, unit in pairs(self._config_units) do
        if unit._build_dir then
            unit_for_bd[unit._build_dir] = unit
        end
    end

    -- Serialize all BuildDir objects with state
    for _, bd in pairs(self._build_dirs) do
        if bd:has_state() then
            local entry = bd:serialize()
            if entry.cmake then entry.cmake.targets = nil end
            -- Enrich with live Configuration snapshot if a ConfigUnit references this BD
            local unit = unit_for_bd[bd]
            if unit and unit._configuration and not unit._configuration._removed then
                local cfg = unit._configuration
                if cfg.options then entry.options = cfg.options end
                if cfg.module_config and next(cfg.module_config) then
                    entry.module_config = cfg.module_config
                end
                if cfg.is_user then entry.is_user = true end
                if cfg.inherits_names and #cfg.inherits_names > 0 then
                    entry.inherits = #cfg.inherits_names == 1
                        and cfg.inherits_names[1] or cfg.inherits_names
                end
            end
            data.build_dirs[bd.rel_path] = entry
        end
    end

    -- Also serialize ConfigUnit build state that hasn't been captured in a
    -- BuildDir yet (e.g., units whose state was set directly before a BD was
    -- created — transitional compatibility).
    for _, unit in pairs(self._config_units) do
        if unit._variant and unit.state_value and not unit._build_dir then
            local entry = unit:serialize()
            if entry.cmake then entry.cmake.targets = nil end
            data.build_dirs[unit.id] = entry
        end
    end

    -- Serialize deploy state (already in the right format)
    if next(self._deploy_records) then
        data.deploy_state = self._deploy_records
    end

    return data
end

--- Save the cache file with standard error handling.
--- Computes loomworks_hash from the current config for change detection.
--- @return boolean ok
function Workspace:_save_cache()
    local cache = self:_serialize_cache()
    -- Compute loomworks_hash from serialized config content
    local config_json = vim.json.encode(self:_serialize_config())
    cache._meta = { loomworks_hash = cache_mod.compute_hash(config_json) }
    local ok, err = self._core._deps.cache.save(self.root, cache)
    if not ok then
        self._core._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
    if ok then
        if self._tracker then
            self._tracker:mark_written(self._core._deps.cache.filepath(self.root))
        end
    end
    return ok
end

-- ===========================================================================
-- Workspace & merge (sync methods)
-- ===========================================================================

--- Full re-merge: reads config + cache from scratch, rebuilds all domain objects.
--- Called only on deserialization (startup, external file change, tool detection).
--- NOT called after mutations — mutations update objects directly.
---
--- Two-layer merge: user.json projects/configuration_sets are combined with
--- loomworks.json (shared config), with user winning at the project/set level.
--- @param raw_config? table parsed loomworks.json config (nil = use stored shared config or serialize from objects)
--- @param raw_cache? table parsed cache data (nil = serialize from domain objects)
--- @param raw_user? table parsed user data (nil = use current state)
function Workspace:remerge(raw_config, raw_cache, raw_user)
    -- Determine the shared config (loomworks.json portion).
    -- When raw_config is provided (startup, file change), use it directly.
    -- When nil (after mutations or tool detection), reconstruct from domain
    -- objects — _shared_config_from_objects() returns only shared-sourced
    -- items in the internal format merge.merge() expects.
    local shared_config
    if raw_config then
        shared_config = raw_config
    else
        shared_config = self:_shared_config_from_objects()
    end

    local cache = raw_cache or self:_serialize_cache()
    -- BuildDir objects are created during data_model.refresh() from cache entries.
    -- No raw cache retention needed — _build_dirs replaces _last_raw_cache.

    -- Extract user state: if raw user data is provided, use it (even if fields are nil);
    -- otherwise use current domain state
    local active_profile_key, default_target_data
    local user_overlay
    local user_data  -- for merge.merge (includes pinned_profiles)
    if raw_user then
        active_profile_key = raw_user.active_profile
        default_target_data = raw_user.default_target
        -- Store user overlay (projects/configuration_sets from user.json)
        user_overlay = {}
        if raw_user.projects then user_overlay.projects = raw_user.projects end
        if raw_user.configuration_sets then user_overlay.configuration_sets = raw_user.configuration_sets end
        self._user_config_overlay = next(user_overlay) and user_overlay or nil
        user_data = raw_user
    else
        active_profile_key = self._active_profile_key
        default_target_data = self._default_target_data
        user_overlay = self._user_config_overlay
        -- Reconstruct user_data from current state for merge (includes pinned profiles)
        user_data = self:_serialize_user()
    end

    -- Two-layer merge: combine user overlay with shared config
    local config, user_project_keys, user_cs_names = M.merge_configs(user_overlay, shared_config)
    self._user_project_keys = user_project_keys
    self._user_cs_names = user_cs_names

    local active_set, all_profile_defs = self._core._deps.merge.merge(
        config, active_profile_key, cache, self.root, self._tools_by_type, user_data)
    self._active_set = active_set

    local current = {
        modules = self._modules,
        projects = self._projects,
        config_sets = self._config_sets,
        profiles = self._profiles,
        config_units = self._config_units,
        profile_projects = self._profile_projects,
        build_dirs = self._build_dirs,
    }

    local result = data_model.refresh(self, config, cache, active_set, all_profile_defs, current, {
        modules_registry = self._core._deps.modules,
        normalize = self._core._deps.normalize,
        tools_by_type = self._tools_by_type,
        default_target_data = default_target_data,
        user_project_keys = user_project_keys,
        user_cs_names = user_cs_names,
        compute_build_dir = function(project, variant, tool_data)
            return self:_compute_build_dir(project, variant, tool_data)
        end,
    })

    self._modules = result.modules
    self._projects = result.projects
    self._config_sets = result.config_sets
    self._profiles = result.profiles
    self._config_units = result.config_units
    self._profile_projects = result.profile_projects
    self._build_dirs = result.build_dirs
    self._build_dir_refs = result.build_dir_refs
    self._active_profile = result.active_profile
    self._active_profile_key = active_profile_key
    self._default_target_data = default_target_data
    -- Deploy records: read from cache (no domain object resolution needed)
    if raw_cache and raw_cache.deploy_state then
        self._deploy_records = raw_cache.deploy_state
    end
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Resolve the active Profile object from the active set name.
--- Called at the end of remerge/refresh to cache the resolved reference.
function Workspace:_resolve_active_profile()
    self._active_profile = nil
    local active_set = self._active_set
    if not active_set or not active_set.name then return end
    for _, p in pairs(self._profiles) do
        if p.key == active_set.name then
            self._active_profile = p
            return
        end
    end
end


--- Remove a profile entirely: marks it _removed, drops it from _profiles,
--- and removes its ProfileProject objects from _profile_projects.
--- @param profile loomworks.Profile
function Workspace:_remove_profile(profile)
    profile._removed = true
    for i, p in ipairs(self._profiles) do
        if p == profile then table.remove(self._profiles, i); break end
    end
    -- Remove PPs belonging to this profile
    local kept = {}
    for _, pp in ipairs(self._profile_projects) do
        if pp._profile == profile then
            pp._removed = true
        else
            kept[#kept + 1] = pp
        end
    end
    self._profile_projects = kept
    profile._projects_list = {}
    profile._projects_by_key = {}
end

--- Rebuild ProfileProject objects for a single profile.
--- Removes existing PPs for this profile from _profile_projects, creates new
--- ones from the profile's mappings, and populates the profile's _projects_list
--- and _projects_by_key. Used after mutations that change a profile's structure
--- without running a full _sync_profile_projects pass.
--- @param profile loomworks.Profile
function Workspace:_rebuild_profile_projects_for(profile)
    -- Build lookup tables
    local projects_by_key = {}
    for _, p in pairs(self._projects) do projects_by_key[p.key] = p end
    local units_by_id = {}
    for _, u in pairs(self._config_units) do units_by_id[u.id] = u end

    -- Build identity map of existing PPs for this profile (for reuse)
    local existing_pps = {}
    for _, pp in pairs(self._profile_projects) do
        if pp._profile == profile then
            local reg_key = profile.key .. "\0" .. pp._init_project_key
            existing_pps[reg_key] = pp
        end
    end

    -- Remove old PPs for this profile from the registry
    local kept = {}
    for _, pp in pairs(self._profile_projects) do
        if pp._profile ~= profile then
            kept[#kept + 1] = pp
        end
    end

    -- Build new PPs from profile mappings
    local new_pps = {}
    if profile.mappings then
        for project_key, variant in pairs(profile.mappings) do
            local project = projects_by_key[project_key]
            local configuration = nil
            if project then
                configuration = project:get_configuration(variant)
            end
            local config_unit = nil
            if project then
                local tool_data = nil
                local tool_key = nil
                local profile_tools = profile:tools_data()
                if profile_tools and profile_tools[project.type] then
                    tool_data = profile_tools[project.type].data
                    tool_key = profile_tools[project.type].key
                end
                local expected_id = self:_compute_build_dir(project, variant, tool_data)
                config_unit = units_by_id[expected_id]
                -- Create ConfigUnit if no existing one found. Link BuildDir if available.
                if not config_unit and expected_id and configuration then
                    local tool = project._module and project._module:find_tool(tool_key) or nil
                    config_unit = self:ensure_config_unit(project, configuration, tool)
                    -- Link to existing BuildDir at the expected path
                    local bd = self:find_build_dir(expected_id)
                    if bd then
                        config_unit._build_dir = bd
                        -- Sync ConfigUnit fields from BuildDir for backward compat
                        config_unit.state_value = bd.state
                        config_unit.build_dir_value = bd.path
                        config_unit.last_configured = bd.last_configured
                        config_unit.last_built = bd.last_built
                        config_unit.cmake_info = bd.cmake_info
                        config_unit._cached_options = bd.options_snapshot
                        config_unit._cached_module_config = bd.module_config_snapshot
                    end
                    units_by_id[config_unit.id] = config_unit
                end
            end
            local reg_key = profile.key .. "\0" .. project_key
            local data = {
                project_key = project_key,
                profile = profile,
                project = project,
                configuration = configuration,
                config_unit = config_unit,
            }
            local existing = existing_pps[reg_key]
            if existing then
                existing:_apply(data)
                new_pps[#new_pps + 1] = existing
            else
                new_pps[#new_pps + 1] = ProfileProject.new(
                    self, project_key, data)
            end
        end
    end

    -- Merge into global registry
    for _, pp in ipairs(new_pps) do
        kept[#kept + 1] = pp
    end
    self._profile_projects = kept

    -- Rebuild profile's sorted project list
    local dependency = require("loomworks.dependency")
    local list = {}
    local by_key = {}
    for _, pp in ipairs(new_pps) do
        list[#list + 1] = pp
        by_key[pp._init_project_key] = pp
    end
    profile._projects_list = dependency.toposort(list)
    profile._projects_by_key = by_key
end


--- Rebuild the build dir reverse index from ConfigUnit objects.
--- Delegates to data_model.sync_build_dir_refs.
function Workspace:_sync_build_dir_refs()
    self._build_dir_refs = data_model.sync_build_dir_refs(
        self._config_units, self._core._deps.normalize)
end

--- Get the ConfigUnits that share a build directory.
--- @param build_dir string normalized build directory path
--- @return loomworks.ConfigUnit[]
function Workspace:get_build_dir_refs(build_dir)
    return self._build_dir_refs[build_dir] or {}
end

-- ===========================================================================
-- Module object registry
-- ===========================================================================

--- Look up a Module domain object by type identifier.
--- @param mod_type string module type (e.g., "cmake")
--- @return loomworks.Module|nil
function Workspace:find_module(mod_type)
    for _, mod in pairs(self._modules) do
        if mod.id == mod_type then return mod end
    end
end

-- ===========================================================================
-- Tool object registry
-- ===========================================================================

--- Get or create a Tool object, delegating to the Module's tool registry.
--- @param mod_type string module type (e.g., "cmake")
--- @param tool_key string|nil opaque identifier (nil for default tools)
--- @param tool_data table module-specific data
--- @param tool_label string|nil display label
--- @return loomworks.Tool
function Workspace:get_or_create_tool(mod_type, tool_key, tool_data, tool_label)
    local mod = self:find_module(mod_type)
    if not mod then
        local impl = self._core._deps.modules.get(mod_type)
        mod = Module.new(mod_type, impl or { id = mod_type })
        self._modules[#self._modules + 1] = mod
    end
    return mod:get_or_create_tool(tool_key, tool_data, tool_label)
end

--- Look up a Tool object by module type and key.
--- Delegates to the Module's tool registry.
--- @param mod_type string
--- @param tool_key string|nil
--- @return loomworks.Tool|nil
function Workspace:find_tool(mod_type, tool_key)
    local mod = self:find_module(mod_type)
    return mod and mod:find_tool(tool_key) or nil
end


--- Get all Tool objects for a module type.
--- @param mod_type string
--- @return loomworks.Tool[]
function Workspace:get_tools_for_type(mod_type)
    local mod = self:find_module(mod_type)
    return mod and mod:tools() or {}
end

-- ===========================================================================
-- Build dir operation queue
-- ===========================================================================

--- @class loomworks.BuildDirLock
--- @field exclusive boolean true if an exclusive op is running
--- @field shared_count number number of concurrent shared ops
--- @field queue { fn: function, lock_type: "exclusive"|"shared" }[]

--- Get or create a lock entry for a build directory.
--- @param dir string normalized build directory path
--- @return loomworks.BuildDirLock
function Workspace:_get_lock(dir)
    local lock = self._build_dir_locks[dir]
    if not lock then
        lock = { exclusive = false, shared_count = 0, queue = {} }
        self._build_dir_locks[dir] = lock
    end
    return lock
end

--- Try to acquire a build dir lock. If the lock can be acquired immediately,
--- calls fn() and returns true. Otherwise queues fn for later and returns false.
--- @param dir string normalized build directory path
--- @param lock_type "exclusive"|"shared" exclusive for configure/delete/clean, shared for build
--- @param fn function called when lock is acquired (immediately or dequeued)
--- @return boolean acquired true if lock was acquired immediately
function Workspace:acquire_build_dir_lock(dir, lock_type, fn)
    local lock = self:_get_lock(dir)

    if lock_type == "shared" then
        if not lock.exclusive then
            lock.shared_count = lock.shared_count + 1
            fn()
            return true
        end
    else -- exclusive
        if not lock.exclusive and lock.shared_count == 0 then
            lock.exclusive = true
            fn()
            return true
        end
    end

    -- Can't acquire now — queue
    lock.queue[#lock.queue + 1] = { fn = fn, lock_type = lock_type }
    return false
end

--- Release a build dir lock and dequeue the next compatible operation(s).
--- @param dir string normalized build directory path
--- @param lock_type "exclusive"|"shared"
function Workspace:release_build_dir_lock(dir, lock_type)
    local lock = self._build_dir_locks[dir]
    if not lock then return end

    if lock_type == "shared" then
        lock.shared_count = math.max(0, lock.shared_count - 1)
    else
        lock.exclusive = false
    end

    -- Dequeue: run as many compatible queued items as possible
    self:_dequeue_build_dir_lock(dir)
end

--- Dequeue and run compatible operations from the build dir lock queue.
--- @param dir string
function Workspace:_dequeue_build_dir_lock(dir)
    local lock = self._build_dir_locks[dir]
    if not lock or #lock.queue == 0 then
        -- Clean up empty lock entries
        if lock and not lock.exclusive and lock.shared_count == 0 and #lock.queue == 0 then
            self._build_dir_locks[dir] = nil
        end
        return
    end

    local next_entry = lock.queue[1]

    if next_entry.lock_type == "exclusive" then
        if lock.exclusive or lock.shared_count > 0 then return end
        -- Run the exclusive op
        table.remove(lock.queue, 1)
        lock.exclusive = true
        next_entry.fn()
    else
        -- Shared: run all consecutive shared entries if no exclusive is held
        if lock.exclusive then return end
        local ran = 0
        while #lock.queue > 0 and lock.queue[1].lock_type == "shared" do
            local entry = table.remove(lock.queue, 1)
            lock.shared_count = lock.shared_count + 1
            ran = ran + 1
            entry.fn()
        end
    end
end

--- Check whether a build dir has any queued operations waiting.
--- @param dir string normalized build directory path
--- @return boolean
function Workspace:has_queued_operations(dir)
    local lock = self._build_dir_locks[dir]
    return lock ~= nil and #lock.queue > 0
end

--- Check whether a build dir currently has an active lock (exclusive or shared).
--- @param dir string normalized build directory path
--- @return boolean locked, string|nil lock_type
function Workspace:is_build_dir_locked(dir)
    local lock = self._build_dir_locks[dir]
    if not lock then return false, nil end
    if lock.exclusive then return true, "exclusive" end
    if lock.shared_count > 0 then return true, "shared" end
    return false, nil
end

-- ===========================================================================
-- Getters (direct access to registries/data)
-- ===========================================================================

--- Get the merged active configuration set.
--- @return loomworks.ActiveSet|nil
function Workspace:get_active_configuration_set()
    return self._active_set
end

--- Get the active Profile object (resolved during remerge/refresh).
--- @return loomworks.Profile|nil
function Workspace:get_active_profile()
    return self._active_profile
end

--- Get all Profile objects.
--- @return loomworks.Profile[]
function Workspace:get_profiles()
    return self._profiles
end

--- Get all Project objects from the active set as a dict (keyed by project key).
--- @return table<string, loomworks.Project>
function Workspace:get_projects()
    return self._projects
end

--- Get all ConfigurationSet objects as a dict (keyed by name).
--- @return table<string, loomworks.ConfigurationSet>
function Workspace:get_config_sets()
    return self._config_sets
end

--- Get tool entries for the configuration sets UI.
--- Builds entries from detected tools and domain Profile objects.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function Workspace:get_tool_entries()
    local merge_mod = self._core._deps.merge
    local result = {}
    if #self._config_sets == 0 then return result end

    -- Build set of module types present in projects
    local active_types = {}
    for _, proj in pairs(self._projects) do
        if not proj.orphaned and proj.type then
            active_types[proj.type] = true
        end
    end

    -- Collect keyed tools only for module types with active projects
    local keyed_tools = {}
    local keyed_mod_type = nil
    for mod_type, tools in pairs(self._tools_by_type) do
        if active_types[mod_type] then
            for _, tool in ipairs(tools) do
                if tool.tool_key then
                    keyed_tools[#keyed_tools + 1] = tool
                    keyed_mod_type = mod_type
                end
            end
        end
    end

    -- Build profile lookup from domain objects
    local profiles_by_key = {}
    for _, p in pairs(self._profiles) do profiles_by_key[p.key] = p end

    for _, cs in pairs(self._config_sets) do
        local entries = {}
        if #keyed_tools > 0 then
            for _, tool in ipairs(keyed_tools) do
                local tools_dict = { [keyed_mod_type] = { key = tool.tool_key } }
                local pkey = merge_mod.profile_key(cs.name, tools_dict)
                local profile = profiles_by_key[pkey]
                entries[#entries + 1] = {
                    profile_key = pkey,
                    tool_key = tool.tool_key,
                    tool_data = tool.tool_data,
                    tool_label = tool.tool_label,
                    tool_mod_type = keyed_mod_type,
                    cached = true,  -- all profiles exist as runtime objects
                    profile = profile,
                }
            end
        end
        result[cs.name] = entries
    end

    return result
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function Workspace:get_tools_by_type()
    return self._tools_by_type
end

-- ===========================================================================
-- Profile materialization
-- ===========================================================================

--- Materialize a profile: ensure skeleton ConfigUnits exist for all projects
--- in the configuration set, save cache, and rebuild profile projects.
--- The profile already exists as a runtime object (derived from config_sets × tools).
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
function Workspace:_materialize_from_data(config_set, tool_entry)
    -- Wait for tool detection to complete before materializing
    if self._tool_state == "scanning" then
        self._tool_waiters[#self._tool_waiters + 1] = function()
            self:_materialize_from_data(config_set, tool_entry)
        end
        return
    end

    local set_name = config_set.name

    -- Build tools dict from tool_entry
    local tools = nil
    local tool_key = tool_entry and tool_entry.tool_key or nil
    local tool_data = tool_entry and tool_entry.tool_data or nil
    local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil
    if tool_entry and tool_key then
        tools = {
            [tool_mod_type] = {
                key = tool_key,
                data = tool_data,
                label = tool_entry.tool_label,
            },
        }
    end

    -- Find the profile (should already exist as runtime object)
    local profile_key = self._core._deps.merge.profile_key(set_name, tools)
    local profile = nil
    for _, p in pairs(self._profiles) do
        if p.key == profile_key then profile = p; break end
    end

    local changed = false
    for project, config in pairs(config_set.mappings) do
        local variant = config.name
        -- tool_key applies only to projects whose module type matches the tool
        local project_tool_key = tools and tools[project.type]
            and tools[project.type].key or nil
        local project_tool_data = project_tool_key and tools[project.type].data or nil

        -- Compute build_dir-based id
        local rel_key, abs_path = self:_compute_build_dir(project, variant, project_tool_data)

        -- Ensure ConfigUnit exists (or reuse stale one from prior deletion)
        local existing_unit = nil
        for _, u in pairs(self._config_units) do
            if u.id == rel_key then existing_unit = u; break end
        end

        -- Resolve tool domain object
        local tool_obj = nil
        if project_tool_key then
            local mod = project._module
            if mod then tool_obj = mod:find_tool(project_tool_key) end
        end

        if existing_unit then
            -- Re-populate stale unit (e.g. after deletion cleared state)
            if not existing_unit._configuration then
                existing_unit:_apply({
                    project = project,
                    tool = tool_obj,
                    configuration = config,
                    build_dir_value = abs_path,
                })
                changed = true
            end
        else
            local unit = ConfigUnit.new(self, rel_key, project.key)
            unit:_apply({
                project = project,
                tool = tool_obj,
                configuration = config,
                build_dir_value = abs_path,
            })
            self._config_units[#self._config_units + 1] = unit
            changed = true
        end
    end
    if profile then
        self:_rebuild_profile_projects_for(profile)
    end
    if changed then
        self:_sync_build_dir_refs()
    end
    self:_resolve_active_profile()
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

-- ===========================================================================
-- Cache migration and cleanup
-- ===========================================================================

--- Build referenced set from runtime Profile objects.
--- Reflects the authoritative mappings from live ConfigurationSets.
--- @return table<string, boolean>
function Workspace:_build_live_referenced_set()
    local referenced = {}
    for _, profile in pairs(self._profiles) do
        for _, pp in ipairs(profile:projects()) do
            if pp._config_unit then
                referenced[pp._config_unit.id] = true
            end
        end
    end
    return referenced
end

--- Clean up unreferenced unconfigured skeletons on init.
--- Configs with no state and no profile reference are silently dropped.
--- Configs with state are left as orphaned (shown in UI).
--- Called before remerge (domain objects may not exist yet), so reads
--- from the raw cache parameter for the initial pass. Also cleans up any
--- matching ConfigUnit objects if they exist.
--- Mutates raw_cache in place so callers pass the cleaned version to remerge.
--- @param raw_cache loomworks.CacheData raw cache data
function Workspace:_cleanup_orphaned_skeletons(raw_cache)
    if not raw_cache or not raw_cache.build_dirs then return end

    local referenced = self:_build_live_referenced_set()

    local changed = false
    local to_drop = {}

    for cache_key, cached_config in pairs(raw_cache.build_dirs) do
        if not referenced[cache_key] then
            local state = cached_config.state
            if not state or state == "unconfigured" then
                to_drop[#to_drop + 1] = cache_key
                changed = true
            end
        end
    end

    for _, cache_key in ipairs(to_drop) do
        raw_cache.build_dirs[cache_key] = nil
        -- Also clean up ConfigUnit if it exists (may not during init)
        for i, unit in ipairs(self._config_units) do
            if unit.id == cache_key then
                unit:_apply(nil)
                unit._removed = true
                table.remove(self._config_units, i)
                break
            end
        end
    end

    if changed then
        self:_save_cache()
    end
end

--- Get orphaned BuildDirs: build directories with state not referenced by
--- any ConfigUnit (and therefore not referenced by any profile).
--- Orphaned BuildDirs are domain objects, not raw cache entries.
--- @return loomworks.OrphanedConfig[]
function Workspace:get_orphaned_configs()
    -- Build set of BuildDirs that are live (referenced by a ConfigUnit)
    local live_bds = {}
    for _, unit in pairs(self._config_units) do
        if unit._build_dir then live_bds[unit._build_dir] = true end
    end

    -- Find BuildDirs not referenced by any ConfigUnit
    local result = {}
    for _, bd in pairs(self._build_dirs) do
        if not live_bds[bd] and bd:has_state() then
            result[#result + 1] = {
                project_key = bd.project_key,
                config_key = bd.config_key or bd.variant,
                build_dir_key = bd.rel_path,
                cached_entry = bd:serialize(),
                build_dir_obj = bd,
            }
        end
    end

    -- Sort for deterministic UI order
    table.sort(result, function(a, b)
        if a.project_key ~= b.project_key then return a.project_key < b.project_key end
        return a.config_key < b.config_key
    end)

    return result
end

-- ===========================================================================
-- Operations
-- ===========================================================================

--- Create an Operation for a profile action.
--- @param profile loomworks.Profile|nil nil for config-level operations
--- @param action string "build"|"configure"|"configure+build"|"clean"|"delete"
--- @param units loomworks.ConfigUnit[]
--- @param target_states table<loomworks.ConfigUnit, loomworks.ConfigUnitState>
--- @return loomworks.Operation
function Workspace:create_operation(profile, action, units, target_states)
    local OperationClass = require("loomworks.operation")
    local ws = self
    local op = OperationClass.new(ws, profile, action, units, target_states, function(completed_op)
        -- On completion: clean up from workspace and profile registries
        if profile then
            profile:complete_operation(completed_op)
        end
        for i, o in ipairs(ws._operations) do
            if o == completed_op then
                table.remove(ws._operations, i)
                break
            end
        end
        -- Flush deletion waiters if no more deletion operations are active
        if completed_op:is_deletion() and not ws:has_pending_deletions() then
            local waiters = ws._delete_waiters
            ws._delete_waiters = {}
            for _, fn in ipairs(waiters) do fn() end
        end
    end)

    ws._operations[#ws._operations + 1] = op
    if profile then
        profile:add_operation(op)
    end

    self._core._deps.events.emit("operation_started", {
        profile_key = profile and profile.key or nil,
        action = action,
        operation = op,
    })

    return op
end

--- Get all active operations.
--- @return loomworks.Operation[]
function Workspace:get_operations()
    return self._operations
end

--- Cancel all active build/configure Operations that overlap with the given units.
--- Called before clean/delete to stop conflicting work.
--- @param units loomworks.ConfigUnit[]
function Workspace:cancel_conflicting_operations(units)
    local unit_set = {}
    for _, u in ipairs(units) do
        unit_set[u] = true
    end
    -- Iterate a copy since cancel modifies _operations via callback
    local ops = {}
    for _, op in ipairs(self._operations) do
        ops[#ops + 1] = op
    end
    for _, op in ipairs(ops) do
        if not op.completed and not op:is_deletion() then
            for _, u in ipairs(op.units) do
                if unit_set[u] then
                    op:cancel()
                    break
                end
            end
        end
    end
end

--- Check if any items are currently being deleted.
--- @return boolean
function Workspace:has_pending_deletions()
    for _, op in ipairs(self._operations) do
        if not op.completed and op:is_deletion() then return true end
    end
    return false
end

--- Wait for all pending deletions to finish, then call fn.
--- If nothing is pending, calls fn immediately.
--- @param fn function
function Workspace:after_deletions(fn)
    if not self:has_pending_deletions() then
        fn()
        return
    end
    self._delete_waiters[#self._delete_waiters + 1] = fn
end

-- ===========================================================================
-- Running task tracking
-- ===========================================================================

--- Check if any tasks are currently running.
--- @return boolean
function Workspace:has_running_tasks()
    for _, unit in pairs(self._config_units) do
        if unit:is_running() then return true end
    end
    return false
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
function Workspace:find_running_tasks_for_items(items)
    local matches = {}
    for _, item in ipairs(items) do
        local unit = item.unit
        if unit and unit._task_id then
            matches[unit._task_id] = {
                project_key = unit._project and unit._project.key or unit._init_project_key,
                action = unit:running_action(),
                configuration_key = unit:config_key() or unit.id,
            }
        end
    end
    return matches
end

--- Stop running overseer tasks and call on_done when all have stopped.
--- @param task_ids number[] overseer task IDs to stop
--- @param on_done function called when all tasks have stopped
--- Stop overseer tasks and return a Future that resolves when all are stopped.
--- @param task_ids number[]
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function Workspace:stop_tasks_then(task_ids, on_done)
    local future_mod = require("loomworks.future")
    if #task_ids == 0 then
        if on_done then on_done() end
        return future_mod.resolved(true)
    end

    local task_futures = {}
    for _, task_id in ipairs(task_ids) do
        local tf = future_mod.Future.new()
        task_futures[#task_futures + 1] = tf
        local task = self._core._deps.get_overseer_task(task_id)
        if task and not task:is_complete() then
            task:subscribe("on_complete", function()
                tf:_resolve(true)
            end)
            task:stop()
        else
            tf:_resolve(true)
        end
    end

    local f = future_mod.when_all(task_futures):next(function() return true end)
    if on_done then
        f:next(function() on_done() end)
    end
    return f
end

-- ===========================================================================
-- Task result recording
-- ===========================================================================

--- Record a task result and update the cache.
--- @param result loomworks.TaskResult
function Workspace:record_task_result(result)
    local config_unit = result.unit
    local action = result.action
    local success = result.success
    local now = self._core._deps.now()

    -- Resolve ConfigUnit, creating one if needed for fallback results
    local project, proj_type
    if config_unit and config_unit._config_key then
        project = config_unit._project
        proj_type = project and project.type or "unknown"
    elseif result.project_key and result.configuration_key then
        -- Fallback for results without a ConfigUnit (e.g. buggy multi-config tasks)
        for _, p in pairs(self._projects) do
            if p.key == result.project_key then project = p; break end
        end
        proj_type = project and project.type or "unknown"
        -- Compute build_dir-based id
        local tool_data = result.tool and result.tool.data or nil
        local rel_key
        if result.build_dir then
            rel_key = cache_mod.relative_build_dir(result.build_dir, self.root)
        elseif project then
            rel_key = self:_compute_build_dir(project, result.variant or result.configuration_key, tool_data)
        else
            -- Last resort: synthetic path
            rel_key = "build/" .. result.project_key .. "/" .. (result.variant or result.configuration_key)
        end
        -- Find or create ConfigUnit for this build_dir key
        local existing_unit = nil
        for _, u in pairs(self._config_units) do
            if u.id == rel_key then existing_unit = u; break end
        end
        if existing_unit then
            config_unit = existing_unit
        else
            local abs_path = result.build_dir
                or cache_mod.absolute_build_dir(rel_key, self.root)
            local entry = {
                project_key = result.project_key,
                config_key = result.configuration_key,
                type = proj_type,
                variant = result.variant,
                tool_key = result.tool and result.tool.key or nil,
                build_dir = abs_path,
            }
            local unit = ConfigUnit.new(self, rel_key, result.project_key)
            unit:_apply({ cached = entry, project = project })
            self._config_units[#self._config_units + 1] = unit
            config_unit = unit
        end
    else
        return
    end

    if action == "configure" then
        if success then
            -- Don't downgrade from built to configured
            if config_unit.state_value ~= "built" then
                config_unit.state_value = "configured"
            end
            config_unit.last_configured = now
        else
            config_unit.state_value = "failed_configure"
        end
    elseif action == "build" then
        if success then
            config_unit.state_value = "built"
            config_unit.last_built = now
        else
            config_unit.state_value = "failed_build"
        end
    end

    if result.build_dir then
        config_unit.build_dir_value = result.build_dir
    end
    if result.tool and result.tool.data then
        config_unit._tool_data = result.tool.data
    end

    if result.cmake then
        config_unit.cmake_info = config_unit.cmake_info or {}
        for k, v in pairs(result.cmake) do
            config_unit.cmake_info[k] = v
        end
    end

    -- Sync state to BuildDir domain object (create if needed)
    local BuildDir = require("loomworks.build_dir")
    local bd = config_unit._build_dir
    if not bd then
        bd = self:find_build_dir(config_unit.id)
        if not bd then
            local abs_path = config_unit.build_dir_value
                or cache_mod.absolute_build_dir(config_unit.id, self.root)
            bd = BuildDir.new(config_unit.id, abs_path)
            self._build_dirs[#self._build_dirs + 1] = bd
        end
        config_unit._build_dir = bd
    end
    bd:update({
        state = config_unit.state_value,
        last_configured = config_unit.last_configured,
        last_built = config_unit.last_built,
        cmake_info = config_unit.cmake_info,
        project_key = config_unit._project and config_unit._project.key or config_unit._init_project_key,
        variant = config_unit._variant,
        config_key = config_unit._config_key,
        mod_type = config_unit._project and config_unit._project.type or nil,
    })
    -- Snapshot current configuration options for stale detection
    if config_unit._configuration and not config_unit._configuration._removed then
        bd.options_snapshot = config_unit._configuration.options
        bd.module_config_snapshot = config_unit._configuration.module_config
        config_unit._cached_options = bd.options_snapshot
        config_unit._cached_module_config = bd.module_config_snapshot
    end
    if result.tool and result.tool.key then
        bd.tool_snapshot = { key = result.tool.key, data = result.tool.data }
    elseif config_unit._tool then
        bd.tool_snapshot = { key = config_unit._tool.key, data = config_unit._tool.data }
    elseif config_unit._tool_key then
        bd.tool_snapshot = { key = config_unit._tool_key, data = config_unit._tool_data }
    end

    self:_save_cache()
    self:_sync_build_dir_refs()
    self._core._deps.events.emit("active_set_changed", self._active_set)

    -- Parse file-api targets after successful configure (runtime only, not cached)
    if config_unit and action == "configure" and success and result.build_dir then
        if proj_type ~= "unknown" then
            local mod = self._core._deps.modules.get(proj_type)
            if mod and mod.parse_file_api then
                config_unit:set_targets(mod.parse_file_api(result.build_dir, result.variant))
            end
        end
    end
    self._core._deps.events.emit("task_result", result)
end

-- ===========================================================================
-- Deletion: cache mutations
-- ===========================================================================

--- Remove cache entries entirely (cache-only, no filesystem operations).
--- @param items loomworks.DeletionItem[]
--- Delete an orphaned build directory (cache-only, no ConfigUnit).
--- Removes the entry from cache and optionally deletes the build dir from disk.
--- @param build_dir_key string relative build dir key
--- @param on_done? function callback after deletion
--- Delete an orphaned build directory. Returns a Future.
--- @param build_dir_key string
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function Workspace:delete_orphaned_build_dir(build_dir_key, on_done)
    local future_mod = require("loomworks.future")
    local bd = self:find_build_dir(build_dir_key)
    if bd then
        for i, b in ipairs(self._build_dirs) do
            if b == bd then table.remove(self._build_dirs, i); break end
        end

        if bd.path then
            local abs_dir = self._core._deps.normalize(bd.path)
            local safe_prefix = self._core._deps.normalize(self.root)
            if self:_validate_build_dir(abs_dir, safe_prefix) then
                local ws = self
                local f = self:_delete_build_dirs_async({ abs_dir }):next(function()
                    ws:_save_cache()
                    ws._core._deps.events.emit("active_set_changed", ws._active_set)
                    return true
                end)
                if on_done then
                    f:next(function() on_done() end)
                     :catch(function() on_done() end)
                end
                return f
            end
        end
    end

    self:_save_cache()
    self._core._deps.events.emit("active_set_changed", self._active_set)
    if on_done then on_done() end
    return future_mod.resolved(true)
end

function Workspace:delete_cached_configs(items)
    local deploy = require("loomworks.deploy")
    for _, item in ipairs(items) do
        if item.unit then
            -- Clean deploy records sourced from this build dir
            if item.unit.id then
                deploy.clean_deploy_records(self._deploy_records, item.unit.id)
            end
            -- Clear BuildDir state (by reference or by path lookup)
            local bd = item.unit._build_dir or self:find_build_dir(item.unit.id)
            if bd then bd:clear_state() end
            -- Clear first-class fields but preserve structural references (_project, _tool, etc.)
            item.unit.state_value = nil
            item.unit.build_dir_value = nil
            item.unit.last_configured = nil
            item.unit.last_built = nil
            item.unit.cmake_info = nil
            item.unit._config_key = nil
            item.unit._variant = nil
            item.unit._tool_key = nil
            item.unit._tool_data = nil
        end
    end
end

--- Reset cached configurations: clear state to unconfigured (cache-only, no filesystem).
--- Keeps the cache entry skeleton (variant, tool_key, tool_data) intact.
--- @param items loomworks.DeletionItem[]
function Workspace:reset_cached_configs(items)
    local deploy = require("loomworks.deploy")
    for _, item in ipairs(items) do
        if not item.unit then goto continue end
        -- Clean deploy records sourced from this build dir
        if item.unit.id then
            deploy.clean_deploy_records(self._deploy_records, item.unit.id)
        end
        -- Clear BuildDir state (by reference or by path lookup)
        local bd = item.unit._build_dir or self:find_build_dir(item.unit.id)
        if bd then bd:clear_state() end
        -- Clear first-class fields
        item.unit.state_value = nil
        item.unit.build_dir_value = nil
        item.unit.last_configured = nil
        item.unit.last_built = nil
        item.unit.cmake_info = nil
        ::continue::
    end
end

--- Mark cached configs as cleaned (reset build state but keep build_dir
--- and configuration metadata). Used after module clean tasks complete.
--- @param items table[] { project_key, config_key }
function Workspace:mark_cached_configs_cleaned(items)
    for _, item in ipairs(items) do
        if not item.unit then goto continue end
        -- Update first-class fields
        item.unit.state_value = "configured"
        item.unit.last_built = nil
        ::continue::
    end
    self:_save_cache()
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Set cache state to "unknown" for items that have build directories.
--- @param items loomworks.DeletionItem[]
function Workspace:_mark_cache_unknown(items)
    for _, item in ipairs(items) do
        if not item.unit then goto continue end
        if item.unit.build_dir_value then
            item.unit.state_value = "unknown"
        end
        ::continue::
    end
end

-- ===========================================================================
-- Deletion: validate & execute
-- ===========================================================================

--- Validate a build directory path is safe to delete (under workspace root).
--- Checks that the path is strictly under the workspace root using a
--- directory boundary check (trailing "/") to prevent prefix collisions
--- (e.g., "/root" must not match "/roots/...").
--- @param build_dir string normalized path
--- @param safe_prefix string normalized workspace root
--- @return boolean safe
function Workspace:_validate_build_dir(build_dir, safe_prefix)
    local is_under = build_dir == safe_prefix
        or build_dir:sub(1, #safe_prefix + 1) == safe_prefix .. "/"
    if not is_under then
        self._core._deps.notify("loomworks: refusing to delete build dir outside workspace: " .. build_dir, vim.log.levels.ERROR)
        return false
    end
    return true
end

--- Remove empty ancestor directories up to (but not including) the stop path.
--- Synchronous — only removes genuinely empty directories.
--- @param dir string normalized path of the deleted directory
--- @param stop string normalized path to stop at (build root)
function Workspace:_cleanup_empty_ancestors(dir, stop)
    local uv = vim.uv or vim.loop
    local parent = dir:match("^(.+)/[^/]+$")
    while parent and #parent > #stop do
        local handle = uv.fs_scandir(parent)
        if not handle then break end
        local name = uv.fs_scandir_next(handle)
        if name then break end -- not empty
        uv.fs_rmdir(parent)
        parent = parent:match("^(.+)/[^/]+$")
    end
end

--- Delete multiple build directories asynchronously via subprocesses (parallel).
--- After deletion, cleans up empty ancestor directories up to the build root.
--- @param dirs string[] list of normalized directory paths
--- @param callback fun(results: {dir: string, ok: boolean, err: string|nil}[])
--- Delete build directories asynchronously. Returns a Future resolving
--- with an array of { dir, ok, err } results.
--- @param dirs string[]
--- @param callback? function legacy callback (deprecated)
--- @return loomworks.Future
function Workspace:_delete_build_dirs_async(dirs, callback)
    local future_mod = require("loomworks.future")
    if #dirs == 0 then
        if callback then callback({}) end
        return future_mod.resolved({})
    end

    local build_root = self._core._deps.normalize(self.root .. "/.nvim/build")
    local dir_futures = {}
    for _, dir in ipairs(dirs) do
        local captured_dir = dir
        local df = future_mod.create(function(resolve, _, token)
            self._core._deps.io.rm_rf_async(captured_dir, function(ok, err)
                if ok then
                    self:_cleanup_empty_ancestors(captured_dir, build_root)
                end
                resolve({ dir = captured_dir, ok = ok, err = err })
            end)
            token:on_cancel(function()
                -- Can't cancel rm -rf mid-flight, but resolve to let chain continue
                resolve({ dir = captured_dir, ok = false, err = "cancelled" })
            end)
        end)
        dir_futures[#dir_futures + 1] = df
    end

    local f = future_mod.when_all(dir_futures):next(function(wrapped)
        local results = {}
        for _, r in ipairs(wrapped) do
            results[#results + 1] = r[1]  -- unwrap from when_all's {values} wrapper
        end
        return results
    end)

    if callback then
        f:next(function(results) callback(results) end)
    end
    return f
end

--- Common async deletion workflow: cancel conflicting operations, mark items
--- as deleting, stop running tasks, delete build dirs via async subprocess,
--- then apply cache mutations.
--- Crash-safe: cache is set to "unknown" before async deletion starts.
--- @param items table[] list of { project_key, config_key, ... }
--- @param work_fn function called after build dirs are successfully deleted (cache mutations)
--- @param on_done? function called when complete
--- @param reason? "deleting"|"cleaning" reason for the deletion flag (default "deleting")
--- Common async deletion workflow. Returns a Future.
--- @param items table[]
--- @param work_fn function cache mutations after successful deletion
--- @param on_done? function legacy callback (deprecated)
--- @param reason? "deleting"|"cleaning"
--- @return loomworks.Future
function Workspace:_run_deletion(items, work_fn, on_done, reason)
    local future_mod = require("loomworks.future")
    if #items == 0 then
        if on_done then on_done() end
        return future_mod.resolved(true)
    end

    local units = {}
    for _, item in ipairs(items) do
        if item.unit then units[#units + 1] = item.unit end
    end
    self:cancel_conflicting_operations(units)

    for _, unit in ipairs(units) do
        unit:mark_deleting(true, reason)
    end
    self._core._deps.events.emit("deletion_started", items)

    local running = self:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    local ws = self
    local f = self:stop_tasks_then(task_ids):next(function()
        ws:_mark_cache_unknown(items)
        ws:_save_cache()

        local deleting_units = {}
        for _, unit in ipairs(units) do deleting_units[unit] = true end

        local safe_prefix = ws._core._deps.normalize(ws.root)
        local dirs = {}
        local seen_dirs = {}
        for _, item in ipairs(items) do
            if item.build_dir then
                local normalized = ws._core._deps.normalize(item.build_dir)
                if not seen_dirs[normalized] and ws:_validate_build_dir(normalized, safe_prefix) then
                    seen_dirs[normalized] = true
                    local ref_units = ws._build_dir_refs[normalized]
                    if ref_units then
                        local remaining_refs = 0
                        for _, ref_unit in ipairs(ref_units) do
                            if not deleting_units[ref_unit] then
                                remaining_refs = remaining_refs + 1
                            end
                        end
                        if remaining_refs > 0 then
                            ws._core._deps.notify(
                                "loomworks: skipped deleting " .. normalized
                                    .. " — still referenced by " .. remaining_refs .. " config(s)",
                                vim.log.levels.INFO)
                            goto skip_dir
                        end
                    end
                    dirs[#dirs + 1] = normalized
                    ::skip_dir::
                end
            end
        end

        return ws:_delete_build_dirs_async(dirs)
    end):next(function(results)
        local errors = {}
        for _, r in ipairs(results) do
            if not r.ok then errors[#errors + 1] = r end
        end

        if #errors > 0 then
            for _, e in ipairs(errors) do
                ws._core._deps.notify("loomworks: failed to delete " .. e.dir .. ": " .. (e.err or "unknown"), vim.log.levels.ERROR)
            end
            for _, unit in ipairs(units) do unit:mark_deleting(false) end
            ws:_save_cache()
            ws:_sync_build_dir_refs()
            ws:_resolve_active_profile()
            ws._core._deps.events.emit("active_set_changed", ws._active_set)
            ws._core._deps.events.emit("deletion_failed", { items = items, errors = errors })
            return true  -- don't reject — deletion "completed" with errors reported
        end

        work_fn(items)
        ws:_save_cache()
        ws:_sync_build_dir_refs()
        ws:_resolve_active_profile()
        ws._core._deps.events.emit("active_set_changed", ws._active_set)
        for _, unit in ipairs(units) do unit:mark_deleting(false) end
        ws._core._deps.events.emit("deletion_completed", items)
        return true
    end)

    if on_done then
        f:next(function() on_done() end)
         :catch(function() on_done() end)
    end
    return f
end

--- Execute a deletion plan asynchronously.
--- Items with disposition "clean" have their cache entries removed.
--- Items with disposition "reset" have their state cleared to unconfigured.
--- Items with disposition "keep" are left untouched (referenced by another profile).
--- Also removes the profile entry from cache if plan.profile_key is set.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: loomworks.Profile }
--- @param on_done? function called when deletion is complete
--- Execute a deletion plan asynchronously. Returns a Future.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: loomworks.Profile }
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function Workspace:execute_deletion(plan, opts, on_done)
    local future_mod = require("loomworks.future")
    opts = opts or {}

    if opts.deactivate_profile then
        opts.deactivate_profile:deactivate()
    end

    if plan.profile and plan.profile._pinned then
        local profile = plan.profile
        profile._removed = true
        profile._pinned = false
        for i, p in ipairs(self._profiles) do
            if p == profile then table.remove(self._profiles, i); break end
        end
        self:_save_user()
    end
    self:_save_cache()

    local actionable = {}
    local clean_units = {}
    for _, item in ipairs(plan.items) do
        if item.disposition == "clean" then
            actionable[#actionable + 1] = item
            if item.unit then clean_units[item.unit] = true end
        elseif item.disposition == "reset" then
            actionable[#actionable + 1] = item
        end
    end

    if #actionable == 0 then
        self:_sync_build_dir_refs()
        self:_resolve_active_profile()
        self._core._deps.events.emit("active_set_changed", self._active_set)
        if on_done then on_done() end
        return future_mod.resolved(true)
    end

    local f = self:_run_deletion(actionable, function(effective_items)
        local eff_clean = {}
        local eff_reset = {}
        for _, item in ipairs(effective_items) do
            if item.unit and clean_units[item.unit] then
                eff_clean[#eff_clean + 1] = item
            else
                eff_reset[#eff_reset + 1] = item
            end
        end
        if #eff_clean > 0 then
            self:delete_cached_configs(eff_clean)
        end
        if #eff_reset > 0 then
            self:reset_cached_configs(eff_reset)
        end
    end, on_done)

    return f
end

-- ===========================================================================
-- Tool scanning
-- ===========================================================================

--- Scan tools from all modules present in the workspace.
--- Results are stored on the Workspace instance for use by merge and UI.
function Workspace:_scan_tools()
    local config = self:_config_from_objects()
    local cache = self:_serialize_cache()
    self._tools_by_type = self._core._deps.merge.detect_tools(
        config, cache)
end

--- Scan tools asynchronously and remerge when complete.
function Workspace:_scan_tools_async()
    self._tool_state = "scanning"
    self._core._deps.events.emit("tools_scanning")

    local config = self:_config_from_objects()
    local cache = self:_serialize_cache()
    self._core._deps.detect_tools_async(
        config, cache,
        function(tools_by_type)
            self._core._deps.schedule(function()
                if not self._core._workspace then return end
                self._tools_by_type = tools_by_type
                self:remerge()
                self._tool_state = "scanned"
                self._core._deps.events.emit("tools_detected")

                -- Flush tool waiters
                local waiters = self._tool_waiters
                self._tool_waiters = {}
                for _, fn in ipairs(waiters) do
                    fn()
                end

                -- Scan targets for existing build dirs (async, runtime only)
                self:_scan_targets_async()
            end)
        end
    )
end

--- Scan targets for all ConfigUnits that have a build directory.
--- Runs asynchronously, processing units sequentially to avoid blocking.
--- Results stored on ConfigUnit.targets (runtime only, not cached).
function Workspace:_scan_targets_async()
    -- Collect scannable units: modules with parse_file_api_async (need build_dir)
    -- or parse_targets_async (need project path)
    local units = {}
    local seen_projects = {} -- avoid duplicate project-level scans
    for _, unit in pairs(self._config_units) do
        local project = unit._project
        if not project then goto continue end

        local mod = project._module and project._module.impl or nil
        if not mod then goto continue end

        local build_dir = unit:build_dir()
        if build_dir and mod.parse_file_api_async then
            units[#units + 1] = {
                unit = unit, mod = mod,
                scan_type = "file_api",
                build_dir = build_dir,
            }
        elseif mod.parse_targets_async and not seen_projects[project.key] then
            -- Project-level target scan (e.g., npm scripts) -- once per project
            seen_projects[project.key] = true
            local abs_path = self.root .. "/" .. (project.path or project.key)
            units[#units + 1] = {
                unit = unit, mod = mod,
                scan_type = "project",
                project_path = abs_path,
            }
        end

        ::continue::
    end

    if #units == 0 then return end

    local idx = 0
    local any_found = false
    local ws = self
    local function next_unit()
        idx = idx + 1
        if idx > #units then
            -- Add launch configs from loomworks.json as targets
            ws:_add_launch_config_targets()
            if any_found then
                ws._core._deps.events.emit("active_set_changed", ws._active_set)
            end
            return
        end

        local entry = units[idx]
        local function on_targets(targets)
            ws._core._deps.schedule(function()
                if targets then
                    entry.unit:set_targets(targets)
                    any_found = true
                end
                next_unit()
            end)
        end

        if entry.scan_type == "file_api" then
            local variant = entry.unit:variant()
            entry.mod.parse_file_api_async(entry.build_dir, variant, on_targets)
        else
            local variant = entry.unit:variant()
            entry.mod.parse_targets_async(entry.project_path, variant, on_targets)
        end
    end

    next_unit()
end

--- Add launch configs from loomworks.json as targets on ConfigUnits.
--- Called after module target scanning completes.
function Workspace:_add_launch_config_targets()
    local Target = require("loomworks.target")

    for _, unit in pairs(self._config_units) do
        local project = unit._project
        if project and project.launch then
            unit.targets = unit.targets or {}
            for name, cfg in pairs(project.launch) do
                local launch_key = "launch:" .. name
                if not unit.targets[launch_key] then
                    unit.targets[launch_key] = Target.new(unit, launch_key, {
                        type = "launch_config",
                        artifact = cfg.command,
                    })
                end
            end
        end
    end
end

--- Re-scan tools and remerge. Used for manual rescan from UI.
function Workspace:rescan_tools()
    local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
    if ok then cmake_kits.clear_cache() end
    self:_scan_tools_async()
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

--- Produce a parsed config structure from domain objects.
--- Returns the same shape as config.parse() / config.validate(): projects
--- have .type, .path, .type_config, .depends_on, .launch fields.
--- Used by remerge() and tool detection when no raw config is available.
--- @return loomworks.Config
function Workspace:_config_from_objects()
    local projects = {}
    for _, project in pairs(self._projects) do
        if not project.orphaned then
            -- Reconstruct type_config with configurations from domain objects
            local tc = project.type_config
                    and vim.deepcopy(project.type_config) or {}
            local configs_dict = {}
            for _, cfg in ipairs(project._configurations) do
                local override = cfg:serialize_user_override()
                if override then
                    configs_dict[cfg.name] = override
                end
            end
            if next(configs_dict) then
                tc.configurations = configs_dict
            end
            projects[project.key] = {
                path = project.path or project.key,
                type = project.type,
                type_config = tc,
                depends_on = project._depends_on_keys,
                launch = project.launch,
            }
        end
    end

    local configuration_sets = nil
    if #self._config_sets > 0 then
        configuration_sets = {}
        for _, cs in pairs(self._config_sets) do
            configuration_sets[cs.name] = cs:raw_mappings()
        end
    end

    local profiles = nil
    for _, profile in pairs(self._profiles) do
        if profile.explicit_def then
            if not profiles then profiles = {} end
            profiles[profile.key] = profile.explicit_def
        end
    end

    return {
        name = self.name,
        projects = projects,
        configuration_sets = configuration_sets,
        profiles = profiles,
    }
end

--- Reconstruct the shared config (loomworks.json portion) from domain objects.
--- Same as _config_from_objects() but only includes shared-sourced items.
--- Used by remerge() as a fallback when no raw_config is provided after mutations.
--- @return loomworks.Config
function Workspace:_shared_config_from_objects()
    local projects = {}
    for _, project in pairs(self._projects) do
        if not project.orphaned and project._source ~= "user" then
            local tc = project.type_config
                    and vim.deepcopy(project.type_config) or {}
            local configs_dict = {}
            for _, cfg in ipairs(project._configurations) do
                local override = cfg:serialize_user_override()
                if override then
                    configs_dict[cfg.name] = override
                end
            end
            if next(configs_dict) then
                tc.configurations = configs_dict
            end
            projects[project.key] = {
                path = project.path or project.key,
                type = project.type,
                type_config = tc,
                depends_on = project._depends_on_keys,
                launch = project.launch,
            }
        end
    end

    local configuration_sets = nil
    for _, cs in pairs(self._config_sets) do
        if cs._source ~= "user" then
            if not configuration_sets then configuration_sets = {} end
            configuration_sets[cs.name] = cs:raw_mappings()
        end
    end

    local profiles = nil
    for _, profile in pairs(self._profiles) do
        if profile.explicit_def then
            if not profiles then profiles = {} end
            profiles[profile.key] = profile.explicit_def
        end
    end

    return {
        name = self.name,
        projects = projects,
        configuration_sets = configuration_sets,
        profiles = profiles,
    }
end

--- Serialize a project domain object to the raw JSON format used in config files.
--- @param project loomworks.Project
--- @return table entry raw JSON-compatible project entry
function Workspace:_serialize_project(project)
    local type_config = project.type_config
            and vim.deepcopy(project.type_config) or {}
    local configs_dict = {}
    for _, cfg in ipairs(project._configurations) do
        local override = cfg:serialize_user_override()
        if override then
            configs_dict[cfg.name] = override
        end
    end
    if next(configs_dict) then
        type_config.configurations = configs_dict
    end
    local entry = { [project.type] = next(type_config)
            and type_config or vim.empty_dict() }
    if project.path and project.path ~= project.key then
        entry.path = project.path
    end
    if project._depends_on_keys then
        entry.depends_on = project._depends_on_keys
    end
    if project.launch then
        entry.launch = project.launch
    end
    if project.variables and next(project.variables) then
        entry.variables = project.variables
    end
    return entry
end

--- Serialize workspace state to raw JSON-writable format for loomworks.json.
--- Only includes shared-sourced items (excludes user-sourced projects/config_sets).
--- Reads from domain objects (Project, ConfigurationSet, Profile).
--- This is the object → disk serialization boundary.
--- @return table raw JSON-compatible table
function Workspace:_serialize_config()
    local raw = { projects = {} }
    if self.name then
        raw.name = self.name
    end

    -- Projects from domain objects (skip cache-only orphans and user-sourced)
    for _, project in pairs(self._projects) do
        if not project.orphaned and project._source ~= "user" then
            raw.projects[project.key] = self:_serialize_project(project)
        end
    end

    -- Configuration sets from domain objects (skip user-sourced)
    local sets = {}
    for _, cs in pairs(self._config_sets) do
        if cs._source ~= "user" then
            sets[cs.name] = cs:raw_mappings()
        end
    end
    if next(sets) then raw.configuration_sets = sets end

    -- Explicit profiles from domain objects
    local profiles = {}
    for _, profile in pairs(self._profiles) do
        if profile.explicit_def then
            profiles[profile.key] = profile.explicit_def
        end
    end
    if next(profiles) then raw.profiles = profiles end

    return raw
end

--- Write the current config to loomworks.json.
--- Updates the file tracker's cached content to suppress self-write detection.
--- @return boolean ok, string|nil err
function Workspace:_save_config()
    local raw = self:_serialize_config()
    local path = M.paths(self.root).config
    local ok, err = self._core._deps.io.write_json(path, raw)
    if ok and self._tracker then
        self._tracker:mark_written(path)
    end
    return ok, err
end

--- Serialize a project partially — only configurations in needed_config_names.
--- Used by _serialize_user() to emit only pin-reachable configurations.
--- @param project loomworks.Project
--- @param needed_config_names table<string, boolean> set of config names to include
--- @return table entry raw JSON-compatible project entry
function Workspace:_serialize_project_partial(project, needed_config_names)
    local type_config = project.type_config
            and vim.deepcopy(project.type_config) or {}
    local configs_dict = {}
    for _, cfg in ipairs(project._configurations) do
        if needed_config_names[cfg.name] then
            local override = cfg:serialize_user_override()
            if override then
                configs_dict[cfg.name] = override
            end
        end
    end
    if next(configs_dict) then
        type_config.configurations = configs_dict
    end
    local entry = { [project.type] = next(type_config)
            and type_config or vim.empty_dict() }
    if project.path and project.path ~= project.key then
        entry.path = project.path
    end
    if project._depends_on_keys then
        entry.depends_on = project._depends_on_keys
    end
    if project.launch then
        entry.launch = project.launch
    end
    if project.variables and next(project.variables) then
        entry.variables = project.variables
    end
    return entry
end

--- Serialize user state from domain objects into a user.json data table.
--- Walks pin roots to compute transitive closure — only reachable objects
--- are serialized (serialization-as-GC).
--- @return loomworks.UserData
function Workspace:_serialize_user()
    local data = { _meta = { version = 2 } }

    -- Active selection
    if self._active_profile_key then
        data.active_profile = self._active_profile_key
    end

    -- Default targets (all profiles, not just pinned)
    local targets = {}
    for _, profile in pairs(self._profiles) do
        if profile._default_target_descriptor then
            targets[profile.key] = profile._default_target_descriptor
        end
    end
    if next(targets) then data.default_target = targets end

    -- Walk pin roots to compute transitive closure
    local needed_projects = {}   -- project_key → set of config names needed
    local needed_config_sets = {} -- set_name → true

    -- Serialize pinned profiles and collect their deps
    local pinned = {}
    for _, profile in pairs(self._profiles) do
        if profile._pinned then
            local entry = {}
            if profile._configuration_set_name then
                entry.configuration_set = profile._configuration_set_name
                needed_config_sets[profile._configuration_set_name] = true
            end
            local tools = profile:tools_data()
            if tools then entry.tools = tools end
            if profile.mappings and not profile._configuration_set_name then
                entry.mappings = profile.mappings
            end
            pinned[profile.key] = entry

            -- Collect project/config dependencies from profile mappings
            if profile.mappings then
                for project_key, variant in pairs(profile.mappings) do
                    if not needed_projects[project_key] then
                        needed_projects[project_key] = {}
                    end
                    needed_projects[project_key][variant] = true
                end
            end
        end
    end
    if next(pinned) then
        data.pinned_profiles = pinned
    end

    -- Collect deps from needed config sets (they map projects to configs)
    for _, cs in pairs(self._config_sets) do
        if needed_config_sets[cs.name] then
            for project, config in pairs(cs.mappings) do
                if not needed_projects[project.key] then
                    needed_projects[project.key] = {}
                end
                needed_projects[project.key][config.name] = true
            end
        end
    end

    -- Expand inherits chains for each needed config
    for project_key, config_names in pairs(needed_projects) do
        local project = nil
        for _, p in pairs(self._projects) do
            if p.key == project_key then project = p; break end
        end
        if project then
            local expanded = {}
            local function expand(name)
                if expanded[name] then return end
                expanded[name] = true
                local cfg = project:get_configuration(name)
                if cfg and cfg.inherits_names then
                    for _, base in ipairs(cfg.inherits_names) do
                        expand(base)
                    end
                end
            end
            for name in pairs(config_names) do
                expand(name)
            end
            needed_projects[project_key] = expanded
        end
    end

    -- Serialize needed config sets (user-sourced only)
    local config_sets = {}
    for _, cs in pairs(self._config_sets) do
        if needed_config_sets[cs.name] and cs._source == "user" then
            config_sets[cs.name] = cs:raw_mappings()
        end
    end
    if next(config_sets) then data.configuration_sets = config_sets end

    -- Serialize needed projects (partial — only needed configs, user-sourced only)
    local projects = {}
    for project_key, config_names in pairs(needed_projects) do
        local project = nil
        for _, p in pairs(self._projects) do
            if p.key == project_key then project = p; break end
        end
        if project and not project.orphaned and project._source == "user" then
            projects[project_key] = self:_serialize_project_partial(project, config_names)
        end
    end
    if next(projects) then data.projects = projects end

    return data
end

--- Write the current user data to loomworks.user.json.
--- Updates the file tracker's cached content to suppress self-write detection.
function Workspace:_save_user()
    local data = self:_serialize_user()
    local ok, err = self._core._deps.user.save(self.root, data)
    if not ok then
        self._core._deps.notify(
            "loomworks: failed to save user.json: " .. (err or "unknown"),
            vim.log.levels.ERROR)
    end
    if self._tracker then
        self._tracker:mark_written(self._core._deps.user.filepath(self.root))
    end
end

-- ---------------------------------------------------------------------------
-- Mutation methods
-- ---------------------------------------------------------------------------

--- Add a project to the workspace.
--- Updates config, remerges, and saves to disk.
--- Mappings are added separately via ConfigurationSet:update_mapping().
--- @param key string project key
--- @param type string module type ("cmake", "typescript", "ets")
--- @param path? string relative path (defaults to key)
--- @return boolean ok, string|nil err
function Workspace:add_project(key, type, path)
    -- Check for duplicate key via domain objects
    for _, p in pairs(self._projects) do
        if p.key == key then
            return nil, "project '" .. key .. "' already exists"
        end
    end

    -- Validate name for build dir safety (slashes, traversal, sanitization collisions)
    local existing_keys = {}
    for _, p in pairs(self._projects) do existing_keys[#existing_keys + 1] = p.key end
    local valid, verr = M.validate_path_name(key, existing_keys)
    if not valid then
        return nil, "invalid project key: " .. verr
    end

    -- Create domain object
    local project = Project.new(self, key, {
        type = type,
        path = path or key,
        type_config = {},
        status = "unconfigured",
        configurations = {},
        cached_configurations = {},
    })
    self._projects[#self._projects + 1] = project

    local ok, err = self:_save_config()
    if not ok then
        -- Rollback domain object
        for i, p in ipairs(self._projects) do
            if p.key == key then table.remove(self._projects, i); break end
        end
        return nil, err
    end

    self._core._deps.events.emit("active_set_changed", self._active_set)
    return project
end

--- Remove a project from the workspace.
--- Updates config, removes from configuration sets, and saves.
--- @param project loomworks.Project project to remove
--- @return boolean ok, string|nil err
function Workspace:remove_project(project)
    if project._removed then
        return false, "project '" .. project.key .. "' not found"
    end

    -- Remove from domain objects
    project._removed = true
    for i, p in ipairs(self._projects) do
        if p == project then table.remove(self._projects, i); break end
    end

    -- Remove from ConfigurationSet domain objects
    for _, cs in pairs(self._config_sets) do
        cs.mappings[project] = nil
    end

    local ok, err = self:_save_config()
    if not ok then return false, err end

    self._core._deps.events.emit("active_set_changed", self._active_set)
    return true
end

--- Add a configuration set to the workspace.
--- @param name string configuration set name
--- @param mappings table<string, string> project_key → variant
--- @return boolean ok, string|nil err
function Workspace:add_configuration_set(name, mappings)
    -- Check for duplicate name via domain objects
    for _, cs in pairs(self._config_sets) do
        if cs.name == name then
            return nil, "configuration set '" .. name .. "' already exists"
        end
    end

    -- Basic name validation (slashes, dots)
    local valid, verr = M.validate_path_name(name)
    if not valid then
        return nil, "invalid configuration set name: " .. verr
    end

    -- Reject case-colliding names (same profile key on case-insensitive FS).
    local name_lower = name:lower()
    for _, cs in pairs(self._config_sets) do
        if cs.name ~= name and cs.name:lower() == name_lower then
            return nil, "configuration set '" .. name .. "' collides with '" .. cs.name .. "' (case-insensitive)"
        end
    end

    -- Create domain object — resolve projects and configurations for _update (deserialization boundary)
    local projects_by_key = {}
    for _, p in pairs(self._projects) do projects_by_key[p.key] = p end
    local resolved = {}
    for project_key, variant in pairs(mappings) do
        local project = projects_by_key[project_key]
        if project then
            local cfg = project:get_configuration(variant)
                or project:ensure_configuration(variant)
            if cfg then
                resolved[project] = cfg
            end
        end
    end
    local cs = ConfigurationSet.new(self, name, resolved)
    self._config_sets[#self._config_sets + 1] = cs

    local ok, err = self:_save_config()
    if not ok then
        -- Rollback domain object
        for i, c in ipairs(self._config_sets) do
            if c.name == name then table.remove(self._config_sets, i); break end
        end
        return nil, err
    end

    self._core._deps.events.emit("active_set_changed", self._active_set)
    return cs
end

--- Remove a configuration set from the workspace.
--- @param cs loomworks.ConfigurationSet configuration set to remove
--- @return boolean ok, string|nil err
function Workspace:remove_configuration_set(cs)
    if cs._removed then
        return false, "configuration set '" .. cs.name .. "' not found"
    end

    -- Remove domain object
    cs._removed = true
    for i, c in ipairs(self._config_sets) do
        if c == cs then table.remove(self._config_sets, i); break end
    end

    local ok, err = self:_save_config()
    if not ok then return false, err end

    -- Update affected profiles:
    -- Non-pinned derived profiles are removed entirely (they only existed
    -- because this config set existed). Pinned profiles are kept with
    -- orphaned_set = true so the user can decide what to do.
    local profiles_to_remove = {}
    for _, profile in pairs(self._profiles) do
        if profile._configuration_set_name == cs.name then
            if profile._pinned then
                profile._config_set_ref = nil
                -- Re-derive mappings — will fall through to Tier 2/3 and set orphaned_set
                profile.mappings, profile.orphaned_set = profile:_resolve_mappings({
                    configuration_set = profile._configuration_set_name,
                    mappings = profile.mappings,
                    _resolved_mappings = nil,
                })
                self:_rebuild_profile_projects_for(profile)
            else
                profiles_to_remove[#profiles_to_remove + 1] = profile
            end
        end
    end
    for _, profile in ipairs(profiles_to_remove) do
        self:_remove_profile(profile)
    end
    self:_sync_build_dir_refs()
    self:_resolve_active_profile()
    self._core._deps.events.emit("active_set_changed", self._active_set)
    return true
end


--- Ensure skeleton ConfigUnits exist for all projects in a profile's config set.
--- Creates ConfigUnits for projects not yet represented in cache.
--- @param profile loomworks.Profile
function Workspace:_ensure_profile_config_units(profile)
    if not profile._configuration_set_name then return end

    local config_set = profile._config_set_ref
    if not config_set then return end

    local tools = profile:tools_data()

    -- Build unit lookup
    local units_by_id = {}
    for _, u in pairs(self._config_units) do units_by_id[u.id] = u end

    for project, config in pairs(config_set.mappings) do
        local variant = config.name
        local project_key = project.key
        -- Tool key applies only to projects whose module type matches
        local project_tool = tools and tools[project.type] or nil
        local project_tool_key = project_tool and project_tool.key or nil
        local project_tool_data = project_tool and project_tool.data or nil
        local config_key = self._core._deps.merge.build_config_key(variant, project_tool_key)

        -- Compute build_dir-based id
        local rel_key, abs_path = self:_compute_build_dir(project, variant, project_tool_data)

        -- Create skeleton ConfigUnit if absent
        if not units_by_id[rel_key] then
            local entry = {
                project_key = project_key,
                config_key = config_key,
                type = project.type,
                variant = variant,
                tool_key = project_tool_key,
                tool_data = project_tool_data,
                build_dir = abs_path,
            }
            local unit = ConfigUnit.new(self, rel_key, project_key)
            unit:_apply({ cached = entry, project = project })
            self._config_units[#self._config_units + 1] = unit
            units_by_id[rel_key] = unit
        end
    end
end

--- Compute profile renames that would result from a tools-dict transformation.
--- Pure query — does not mutate state.
--- @param transform fun(tools: table|nil): table|nil  tools dict transformation
--- @return { old_key: string, new_key: string }[]
function Workspace:compute_profile_renames(transform)
    local merge_mod = self._core._deps.merge
    local renames = {}
    for _, profile in pairs(self._profiles) do
        if profile._configuration_set_name then
            local new_tools = transform(profile:tools_data())
            local new_key = merge_mod.profile_key(profile._configuration_set_name, new_tools)
            if profile.key ~= new_key then
                renames[#renames + 1] = {
                    old_key = profile.key,
                    new_key = new_key,
                }
            end
        end
    end
    table.sort(renames, function(a, b) return a.old_key < b.old_key end)
    return renames
end

--- Apply profile renames to domain objects, cache, and user state.
--- Updates the tools dict on each renamed profile via the transform function.
--- The profile key is re-derived automatically from the updated tools.
--- @param renames { old_key: string, new_key: string }[]
--- @param transform fun(tools: table|nil): table|nil
--- @return boolean user_changed whether active_profile was updated
function Workspace:apply_profile_renames(renames, transform)
    -- Build profile lookup from domain objects
    local profiles_by_key = {}
    for _, p in pairs(self._profiles) do profiles_by_key[p.key] = p end

    local user_changed = false
    for _, r in ipairs(renames) do
        -- Update domain object — key re-derives from updated tools
        local profile = profiles_by_key[r.old_key]
        if profile then
            profile._tools_raw = transform(profile:tools_data())
            -- Clear resolved tool objects so tools_data() reads from _tools_raw
            profile._tool_objects = nil
            profile:_derive_key()
        end

        if self._active_profile_key == r.old_key then
            self._active_profile_key = r.new_key
            user_changed = true
        end
    end
    return user_changed
end

--- Upgrade profiles when a keyed-module project is added.
--- Profiles without this tool type get it added; profiles already with
--- tools get extended with skeleton entries for the new project.
---
--- @param tool_entry { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
function Workspace:upgrade_profiles_for_tool(tool_entry)
    if #self._profiles == 0 then return end

    local function add_tool(tools)
        local t = tools and vim.deepcopy(tools) or {}
        t[tool_entry.tool_mod_type] = {
            key = tool_entry.tool_key,
            data = tool_entry.tool_data,
            label = tool_entry.tool_label,
        }
        return t
    end

    -- Only rename profiles whose config set has a project of the tool's module type
    local function should_rename(profile)
        if not profile._configuration_set_name then return false end
        for _, cs in pairs(self._config_sets) do
            if cs.name == profile._configuration_set_name then
                for project in pairs(cs.mappings) do
                    if project.type == tool_entry.tool_mod_type then
                        return true
                    end
                end
                return false
            end
        end
        return false
    end

    -- Collect renames (profiles that need the tool added)
    local renames = {}
    local extends = {} -- profiles that already have tools
    for _, profile in pairs(self._profiles) do
        if profile._configuration_set_name then
            local profile_tools = profile:tools_data()
            local has_this_tool = profile_tools
                and profile_tools[tool_entry.tool_mod_type]
            if not has_this_tool and should_rename(profile) then
                local new_tools = add_tool(profile_tools)
                local new_key = self._core._deps.merge.profile_key(
                    profile._configuration_set_name, new_tools)
                renames[#renames + 1] = { old_key = profile.key, new_key = new_key }
            elseif has_this_tool then
                extends[#extends + 1] = profile
            end
        end
    end

    -- Apply renames and update tools dicts
    local user_changed = self:apply_profile_renames(renames, add_tool)

    -- Build profile lookup after renames (keys may have changed)
    local profiles_by_key = {}
    for _, p in pairs(self._profiles) do profiles_by_key[p.key] = p end

    -- Ensure skeleton ConfigUnits for renamed profiles
    for _, r in ipairs(renames) do
        local profile = profiles_by_key[r.new_key]
        if profile then
            self:_ensure_profile_config_units(profile)
        end
    end

    -- Ensure skeleton ConfigUnits for existing keyed profiles (new project)
    for _, profile in ipairs(extends) do
        self:_ensure_profile_config_units(profile)
    end

    self:_save_cache()
    if user_changed then
        self:_save_user()
    end

    -- Rebuild PPs for affected profiles
    for _, r in ipairs(renames) do
        local profile = profiles_by_key[r.new_key]
        if profile then
            self:_rebuild_profile_projects_for(profile)
        end
    end
    for _, profile in ipairs(extends) do
        self:_rebuild_profile_projects_for(profile)
    end
    self:_sync_build_dir_refs()
    self:_resolve_active_profile()
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Compute profile renames that would occur if a project were removed.
--- Pure query — does not mutate state. Uses compute_profile_renames
--- with a remove-tool transform.
--- @param project loomworks.Project project about to be removed
--- @return { old_key: string, new_key: string }[]
function Workspace:compute_downgrade_preview(project)
    if not project._module or not project._module.has_keyed_tools then return {} end

    -- Check if any OTHER project of the same type exists
    for _, proj in pairs(self._projects) do
        if proj ~= project and proj.type == project.type then
            return {} -- not the last one
        end
    end

    local proj_type = project.type
    return self:compute_profile_renames(function(tools)
        if not tools then return nil end
        local t = vim.deepcopy(tools)
        t[proj_type] = nil
        return next(t) and t or nil
    end)
end

--- Downgrade keyed profiles when the last project of a keyed-module type
--- is removed. Strips tool from tools dict, removes keyed-module
--- configuration entries from profiles.
--- No-op if other projects of the same type still exist.
--- @param mod_type string module type (e.g. "cmake")
function Workspace:downgrade_profiles_from_tool(mod_type)
    if #self._profiles == 0 then return end

    -- Guard: if any remaining project has this keyed type, do nothing
    for _, proj in pairs(self._projects) do
        if proj.type == mod_type then return end
    end

    local function remove_tool(tools)
        if not tools then return nil end
        local t = vim.deepcopy(tools)
        t[mod_type] = nil
        return next(t) and t or nil
    end

    -- Clean skeleton ConfigUnit entries for the removed module type.
    -- Mark unconfigured skeleton units as removed; keep units with build state.
    for _, unit in pairs(self._config_units) do
        local unit_type = unit._project and unit._project.type
        if unit_type == mod_type and unit._config_key then
            local state = unit.state_value
            if not state or state == "unconfigured" then
                unit:_apply(nil)
                unit._removed = true
            end
        end
    end

    -- Remove dropped units from registry
    local kept_units = {}
    for _, unit in pairs(self._config_units) do
        if not unit._removed then
            kept_units[#kept_units + 1] = unit
        end
    end
    self._config_units = kept_units

    -- Compute and apply renames
    local renames = self:compute_profile_renames(remove_tool)
    local user_changed = self:apply_profile_renames(renames, remove_tool)

    self:_save_cache()
    if user_changed then
        self:_save_user()
    end

    -- Rebuild PPs for affected profiles
    local profiles_by_key = {}
    for _, p in pairs(self._profiles) do profiles_by_key[p.key] = p end
    for _, r in ipairs(renames) do
        local profile = profiles_by_key[r.new_key]
        if profile then
            self:_rebuild_profile_projects_for(profile)
        end
    end
    self:_sync_build_dir_refs()
    self:_resolve_active_profile()
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Create (materialize) a profile and optionally activate it.
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? table
--- @param activate? boolean
--- @return loomworks.Profile|nil
function Workspace:create_profile(config_set, tool_entry, activate)
    local profile
    if activate then
        profile = config_set:activate(tool_entry)
    else
        profile = config_set:ensure_profile(tool_entry)
    end
    return profile
end

--- Activate a profile by key. Writes user.json and remerges.
--- @param profile loomworks.Profile
function Workspace:activate_profile(profile)
    profile:activate()
end

-- ---------------------------------------------------------------------------
-- Query methods
-- ---------------------------------------------------------------------------

--- Get a module by type.
--- @param type string module type
--- @return table|nil module
function Workspace:get_module(type)
    return self._core._deps.modules.get(type)
end

--- Query available configurations for a project path and module type.
--- Returns the module info (configurations, etc.) without modifying state.
--- @param mod_type string module type
--- @param abs_path string absolute project path
--- @param type_config? table module-specific config
--- @return table|nil info module info with configurations
function Workspace:query_available_configs(mod_type, abs_path, type_config)
    local mod = self._core._deps.modules.get(mod_type)
    if not mod or not mod.info then return nil end
    return mod.info(abs_path, type_config or {})
end

--- Map a variant type to a configuration name using the module's mapper.
--- @param mod_type string module type
--- @param variant_type string "debug"|"release"
--- @param config_names string[] available configuration names
--- @return string|nil mapped configuration name
function Workspace:map_variant(mod_type, variant_type, config_names)
    local mod = self._core._deps.modules.get(mod_type)
    if not mod or not mod.map_variant then return nil end
    return mod.map_variant(variant_type, config_names)
end

--- Generate default configuration sets from project info.
--- Returns plain data (does not modify state).
--- @return table<string, table<string, string>>|nil sets, string|nil err
function Workspace:generate_default_config_sets()
    if #self._projects == 0 then
        return nil, "no projects defined"
    end

    local modules = self._core._deps.modules

    -- Gather project info from domain objects
    local project_infos = {} -- { key, type, config_names[], mod }
    for _, project in pairs(self._projects) do
        if not project.orphaned then
            local mod = modules.get(project.type)
            if mod and mod.info and mod.map_variant then
                local abs_path = self.root .. "/" .. (project.path or project.key)
                local info = mod.info(abs_path, project.type_config or {})
                if info and info.configurations then
                    local config_names = {}
                    for name in pairs(info.configurations) do
                        config_names[#config_names + 1] = name
                    end
                    table.sort(config_names)
                    project_infos[#project_infos + 1] = {
                        key = project.key,
                        type = project.type,
                        config_names = config_names,
                        mod = mod,
                    }
                end
            end
        end
    end

    if #project_infos == 0 then
        return nil, "no projects with detectable configurations"
    end

    -- Standard set candidates
    local candidates = {
        { set_name = "Debug", variant_type = "debug" },
        { set_name = "Release", variant_type = "release" },
    }

    local sets = {}
    for _, candidate in ipairs(candidates) do
        local mappings = {}
        local all_mapped = true
        for _, pinfo in ipairs(project_infos) do
            local mapped = pinfo.mod.map_variant(candidate.variant_type, pinfo.config_names)
            if mapped then
                mappings[pinfo.key] = mapped
            else
                all_mapped = false
                break
            end
        end
        if all_mapped then
            sets[candidate.set_name] = mappings
        end
    end

    -- Fallback: if no candidates succeeded but every project has exactly one config
    if not next(sets) then
        local all_single = true
        local mappings = {}
        for _, pinfo in ipairs(project_infos) do
            if #pinfo.config_names ~= 1 then
                all_single = false
                break
            end
            mappings[pinfo.key] = pinfo.config_names[1]
        end
        if all_single then
            sets["Default"] = mappings
        end
    end

    if not next(sets) then
        return nil, "could not auto-detect configuration sets"
    end

    return sets
end

-- ---------------------------------------------------------------------------
-- File tracking
-- ---------------------------------------------------------------------------

--- Start watching workspace files for external changes.
--- @param paths { config: string, user: string, cache: string }
function Workspace:_start_tracking(paths)
    if self._tracker then
        self._tracker:stop()
    end
    self._tracker = self._core._deps.FileTracker.new({
        callback = function(path, content)
            self:_on_file_changed(path, content)
        end,
        schedule = self._core._deps.schedule,
        read_file = self._core._deps.io.read_file,
    })
    self._tracker:watch(paths.config)
    self._tracker:watch(paths.user)
    self._tracker:watch(paths.cache)
end

--- Stop file tracking.
function Workspace:_stop_tracking()
    if self._tracker then
        self._tracker:stop()
        self._tracker = nil
    end
end

--- Handle a tracked file change.
--- @param path string absolute file path that changed
--- @param content string|nil new raw content
function Workspace:_on_file_changed(path, content)
    local paths = M.paths(self.root)

    if path == paths.config then
        -- loomworks.json changed: full reassemble
        local data, err = M.assemble(
            self.root,
            content,
            self._tracker:content(paths.user),
            self._tracker:content(paths.cache)
        )
        if data then
            local ok, val_err = self._core:_validate_projects(data.config, data.root)
            if ok then
                -- Update workspace data fields in place
                self.root = data.root
                self.name = data.name
                self:_scan_tools_async()
                self:remerge(data.config, data.cache, data.user)
                self._core._deps.notify("loomworks: config reloaded", vim.log.levels.INFO)
            else
                self._core._deps.notify("loomworks: config reload failed: " .. val_err, vim.log.levels.WARN)
            end
        else
            self._core._deps.notify("loomworks: config reload failed: " .. (err or "unknown"), vim.log.levels.WARN)
        end

    elseif path == paths.user then
        -- user.json changed: normalize user projects and pass through remerge
        local user_data = content and user_mod.parse(content) or user_mod.default()
        if user_data.projects and next(user_data.projects) then
            local normalized, norm_err = config_mod.normalize_projects(user_data.projects)
            if normalized then
                user_data.projects = normalized
            else
                self._core._deps.notify("loomworks: user.json projects invalid: " .. (norm_err or "unknown"), vim.log.levels.WARN)
                user_data.projects = nil
            end
        end
        self:remerge(nil, nil, user_data)

    elseif path == paths.cache then
        -- cache.json changed: update cache data and remerge
        local cache_data = content and cache_mod.parse(content) or cache_mod.default()
        self:remerge(nil, cache_data)
    end
end

--- Force-reload loomworks.json from disk and remerge.
--- Used after programmatic writes to loomworks.json to avoid waiting
--- for the file watcher poll interval.
function Workspace:reload_config()
    local paths = M.paths(self.root)
    local content = self._core._deps.io.read_file(paths.config)
    self:_on_file_changed(paths.config, content)
end

M.Workspace = Workspace

return M
