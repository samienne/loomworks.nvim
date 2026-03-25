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
local ConfigUnit = require("loomworks.config_unit")
local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local Project = require("loomworks.project")
local ConfigurationSet = require("loomworks.configuration_set")

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
--- @field _build_dir_refs table<string, table<string, true>> normalized_build_dir -> set of cache_keys
--- @field _build_dir_locks table<string, loomworks.BuildDirLock> per-build-dir operation locks
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
    self._build_dir_refs = {}
    self._build_dir_locks = {}
    self._pp_by_config = {}

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

-- ===========================================================================
-- Cache helpers
-- ===========================================================================

--- Save the cache file with standard error handling.
--- @return boolean ok
function Workspace:_save_cache()
    -- Strip runtime-only data (targets) before persisting
    local cache = self.cache
    if cache.configurations then
        for _, cfg in pairs(cache.configurations) do
            if cfg.cmake then cfg.cmake.targets = nil end
        end
    end
    local ok, err = self._core._deps.cache.save(self.root, cache)
    if not ok then
        self._core._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
    if ok and self._tracker then
        self._tracker:mark_written(self._core._deps.cache.filepath(self.root))
    end
    return ok
end

-- ===========================================================================
-- Workspace & merge (sync methods)
-- ===========================================================================

--- Full re-merge: reads config + cache from scratch, rebuilds all domain objects.
--- Called only on deserialization (startup, external file change, tool detection).
--- NOT called after mutations — mutations update objects directly.
function Workspace:remerge()
    local active_set, all_profile_defs = self._core._deps.merge.merge(
        self, self._tools_by_type)
    self._active_set = active_set
    self:_sync_projects()                    -- 1. no deps
    self:_sync_config_sets()                 -- 2. needs Projects
    self:_sync_profiles(all_profile_defs)    -- 3. needs ConfigurationSets
    self:_sync_profile_projects()            -- 4. needs Profiles
    self:_sync_config_units()                -- 5. needs Profiles (for config_keys)
    self:_sync_build_dir_refs()              -- 6. needs ConfigUnits (build_dir data)
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Lightweight refresh after cache changes (task results, deletions, materialization).
--- Re-syncs profiles, profile_projects, config units, and build dir refs
--- without running the full merge pipeline (no merge.merge() call, no
--- re-reading config). Uses get_all_profiles to pick up new cached profiles.

function Workspace:_refresh_after_cache_change()
    local all_profile_defs = self._core._deps.merge.get_all_profiles(
        self.config, self.cache, self._tools_by_type)
    self:_sync_profiles(all_profile_defs)
    self:_sync_profile_projects()
    self:_sync_config_units()
    self:_sync_build_dir_refs()
    self._core._deps.events.emit("active_set_changed", self._active_set)
end

--- Sync the profiles registry with current merge data.
--- Creates new Profile objects, updates existing ones in place, removes stale ones.
--- Profile._update resolves its own mappings from Workspace's config sets registry.
--- @param all_defs table<string, loomworks.ProfileDef> profile definitions from merge
function Workspace:_sync_profiles(all_defs)
    -- Mark removed profiles
    for key, profile in pairs(self._profiles) do
        if not all_defs[key] then
            profile._removed = true
            self._profiles[key] = nil
        end
    end

    -- Create or update -- Profile._update handles mapping resolution internally
    for key, data in pairs(all_defs) do
        data._ws_cache = self.cache
        local existing = self._profiles[key]
        if existing then
            existing:_update(data)
        else
            self._profiles[key] = Profile.new(self, key, data)
        end
    end
end

--- Sync the projects registry with current active set data.
--- Creates new Project objects, updates existing ones in place, removes stale ones.
function Workspace:_sync_projects()
    if not self._active_set then return end

    local new_data = self._active_set.projects

    -- Mark removed projects
    for key, project in pairs(self._projects) do
        if not new_data[key] then
            project._removed = true
            self._projects[key] = nil
        end
    end

    -- Create or update
    for key, data in pairs(new_data) do
        local existing = self._projects[key]
        if existing then
            existing:_update(data)
        else
            self._projects[key] = Project.new(self, key, data)
        end
    end
end

--- Sync the config sets registry with current config data.
--- Runs after _sync_projects so Project objects are available.
--- ConfigurationSet._update resolves project_key -> Project internally.
function Workspace:_sync_config_sets()
    local defs = self.config.configuration_sets or {}

    -- Mark removed
    for name, cs in pairs(self._config_sets) do
        if not defs[name] then
            cs._removed = true
            self._config_sets[name] = nil
        end
    end

    -- Create or update
    for name, raw_mappings in pairs(defs) do
        local existing = self._config_sets[name]
        if existing then
            existing:_update(raw_mappings)
        else
            self._config_sets[name] = ConfigurationSet.new(self, name, raw_mappings)
        end
    end
end

--- Sync the profile projects registry.
--- Derives data from synced profiles' mappings.
--- Runs after _sync_profiles so Profile objects and their mappings are available.
--- Also builds per-Profile direct lists and _pp_by_config index.
function Workspace:_sync_profile_projects()
    -- Build the set of expected (profile_key, project_key) pairs
    -- Carry project_key explicitly to avoid parsing from registry key.
    local expected = {}
    for profile_key, profile in pairs(self._profiles) do
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                local reg_key = profile_key .. "\0" .. project_key
                expected[reg_key] = { profile = profile, variant = variant, project_key = project_key }
            end
        end
    end

    -- Mark removed
    for reg_key, pp in pairs(self._profile_projects) do
        if not expected[reg_key] then
            pp._removed = true
            self._profile_projects[reg_key] = nil
        end
    end

    -- Create or update
    for reg_key, info in pairs(expected) do
        local existing = self._profile_projects[reg_key]
        if existing then
            existing:_update(info.profile, info.variant)
        else
            self._profile_projects[reg_key] = ProfileProject.new(
                self, info.profile, info.project_key, info.variant)
        end
    end

    -- Build per-Profile direct lists (D3) and _pp_by_config index (D4)
    local dependency = require("loomworks.dependency")
    local pp_by_config = {}
    for _, profile in pairs(self._profiles) do
        local list = {}
        local by_key = {}
        if profile.mappings then
            for project_key in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. project_key
                local pp = self._profile_projects[reg_key]
                if pp then
                    list[#list + 1] = pp
                    by_key[project_key] = pp
                    -- Build nested index: [project_key][config_key] -> PP
                    if not pp_by_config[pp.project_key] then
                        pp_by_config[pp.project_key] = {}
                    end
                    if not pp_by_config[pp.project_key][pp.config_key] then
                        pp_by_config[pp.project_key][pp.config_key] = pp
                    end
                end
            end
        end
        profile._projects_list = dependency.toposort(list)
        profile._projects_by_key = by_key
    end
    self._pp_by_config = pp_by_config
end

--- Sync the config units registry.
--- Collects all valid (project_key, config_key) pairs from profiles and cache,
--- creates/updates/removes ConfigUnit objects. Preserves runtime state.
--- Carries project_key and config_key explicitly (no key parsing).
function Workspace:_sync_config_units()
    -- Collect all valid (project_key, config_key) pairs
    local expected = {} -- reg_key -> { project_key, config_key }

    -- From all profiles' mappings (via profile_projects)
    for _, pp in pairs(self._profile_projects) do
        local reg_key = pp.project_key .. "\0" .. pp.config_key
        if not expected[reg_key] then
            expected[reg_key] = { project_key = pp.project_key, config_key = pp.config_key }
        end
    end

    -- From cache entries
    if self.cache.configurations then
        for _, cached_config in pairs(self.cache.configurations) do
            local reg_key = cached_config.project_key .. "\0" .. cached_config.config_key
            if not expected[reg_key] then
                expected[reg_key] = { project_key = cached_config.project_key, config_key = cached_config.config_key }
            end
        end
    end

    -- Mark removed (only if not running/deleting -- don't remove active units)
    for reg_key, unit in pairs(self._config_units) do
        if not expected[reg_key] and not unit:is_running() and not unit:is_deleting() then
            unit._removed = true
            self._config_units[reg_key] = nil
        end
    end

    -- Create or update
    for reg_key, info in pairs(expected) do
        local existing = self._config_units[reg_key]
        if existing then
            existing:_update()
        else
            self._config_units[reg_key] = ConfigUnit.new(self, info.project_key, info.config_key)
        end
    end
end

--- Rebuild the build dir reverse index from ConfigUnit objects.
--- Maps normalized_build_dir -> array of ConfigUnits that reference it.
function Workspace:_sync_build_dir_refs()
    local refs = {}
    for _, unit in pairs(self._config_units) do
        local bd = unit:build_dir()
        if bd then
            local dir = self._core._deps.normalize(bd)
            if not refs[dir] then refs[dir] = {} end
            refs[dir][#refs[dir] + 1] = unit
        end
    end
    self._build_dir_refs = refs
end

--- Get the ConfigUnits that share a build directory.
--- @param build_dir string normalized build directory path
--- @return loomworks.ConfigUnit[]
function Workspace:get_build_dir_refs(build_dir)
    return self._build_dir_refs[build_dir] or {}
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

--- Get the active Profile object.
--- @return loomworks.Profile|nil
function Workspace:get_active_profile()
    local active_set = self._active_set
    if not active_set or not active_set.name then return nil end
    return self._profiles[active_set.name]
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function Workspace:get_profiles()
    return self._profiles
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function Workspace:get_projects()
    return self._projects
end

--- Get all ConfigurationSet objects.
--- @return table<string, loomworks.ConfigurationSet>
function Workspace:get_config_sets()
    return self._config_sets
end

--- Get tool entries for the configuration sets UI.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function Workspace:get_tool_entries()
    return self._core._deps.merge.get_tool_entries(
        self.config, self.cache, self._tools_by_type)
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function Workspace:get_tools_by_type()
    return self._tools_by_type
end

-- ===========================================================================
-- Profile materialization
-- ===========================================================================

--- Materialize a profile from structured data: write it to cache with full
--- tool and project references. Creates skeleton configuration entries.
--- No-op if the profile is already materialized (by property match).
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

    -- Compute profile key (pure cache identifier)
    local profile_key = self._core._deps.merge.profile_key(set_name, tools)

    -- Already cached?
    if self.cache.profiles and self.cache.profiles[profile_key] then return end

    local profile_configurations = {}
    self.cache.configurations = self.cache.configurations or {}

    for project, variant in pairs(config_set.mappings) do
        -- tool_key applies only to projects whose module type matches the tool
        local project_tool_key = tools and tools[project.type]
            and tools[project.type].key or nil
        local project_tool_data = project_tool_key and tools[project.type].data or nil
        local config_key = self._core._deps.merge.build_config_key(variant, project_tool_key)

        local cache_key = self._core._deps.cache.config_cache_key(project.key, config_key)
        profile_configurations[#profile_configurations + 1] = cache_key

        -- Ensure skeleton config entry exists in flat cache
        if not self.cache.configurations[cache_key] then
            self.cache.configurations[cache_key] = {
                project_key = project.key,
                config_key = config_key,
                type = project.type,
                variant = variant,
                tool_key = project_tool_key,
                tool_data = project_tool_data,
            }
        end
    end

    -- Write profile to cache
    self.cache.profiles = self.cache.profiles or {}
    self.cache.profiles[profile_key] = {
        configuration_set = set_name,
        tools = tools,
        configurations = profile_configurations,
    }

    self:_save_cache()
    self:_refresh_after_cache_change()
end

-- ===========================================================================
-- Cache migration and cleanup
-- ===========================================================================

--- Build a set of all cache keys referenced by profiles.
--- @return table<string, boolean> referenced set keyed by cache key ("project_key/config_key")
function Workspace:_build_referenced_set()
    local referenced = {}
    if self.cache.profiles then
        for _, profile in pairs(self.cache.profiles) do
            if profile.configurations then
                for _, ck in ipairs(profile.configurations) do
                    referenced[ck] = true
                end
            end
        end
    end
    return referenced
end

--- Build referenced set from runtime Profile objects (post-remerge).
--- Unlike _build_referenced_set which uses raw cache data, this reflects
--- the authoritative mappings from live ConfigurationSets. Stale cache
--- references to removed projects are excluded.
--- @return table<string, boolean>
function Workspace:_build_live_referenced_set()
    local referenced = {}
    for _, profile in pairs(self._profiles) do
        for _, pp in ipairs(profile:projects()) do
            local ck = cache_mod.config_cache_key(pp.project_key, pp.config_key)
            referenced[ck] = true
        end
    end
    return referenced
end

--- Clean up unreferenced unconfigured skeletons on init.
--- Configs with no state and no profile reference are silently dropped.
--- Configs with state are left as orphaned (shown in UI).
function Workspace:_cleanup_orphaned_skeletons()
    if not self.cache.configurations then return end

    local referenced = self:_build_referenced_set()

    local changed = false
    local to_drop = {}

    for cache_key, cached_config in pairs(self.cache.configurations) do
        if not referenced[cache_key] then
            local state = cached_config.state
            if not state or state == "unconfigured" then
                to_drop[#to_drop + 1] = cache_key
                changed = true
            end
        end
    end

    for _, cache_key in ipairs(to_drop) do
        self.cache.configurations[cache_key] = nil
    end

    if changed then
        self:_save_cache()
    end
end

--- Get orphaned cached configs: configs with state not referenced by any profile.
--- @return loomworks.OrphanedConfig[]
function Workspace:get_orphaned_configs()
    if not self.cache.configurations then return {} end

    -- Use live referenced set: stale cache refs to removed projects are
    -- excluded, so their configs correctly appear as orphaned.
    local referenced = self:_build_live_referenced_set()

    local result = {}
    for cache_key, cached_config in pairs(self.cache.configurations) do
        local state = cached_config.state
        if state and state ~= "unconfigured"
                and not referenced[cache_key] then
            result[#result + 1] = {
                project_key = cached_config.project_key,
                config_key = cached_config.config_key,
                cached = cached_config,
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
        local unit = self:get_config_unit(item.project_key, item.config_key)
        if unit._task_id then
            matches[unit._task_id] = {
                project_key = unit.project_key,
                action = unit:running_action(),
                configuration_key = unit.config_key,
            }
        end
    end
    return matches
end

--- Stop running overseer tasks and call on_done when all have stopped.
--- @param task_ids number[] overseer task IDs to stop
--- @param on_done function called when all tasks have stopped
function Workspace:stop_tasks_then(task_ids, on_done)
    if #task_ids == 0 then
        on_done()
        return
    end

    local remaining = #task_ids
    local schedule = self._core._deps.schedule
    local function check_done()
        remaining = remaining - 1
        if remaining == 0 then
            schedule(on_done)
        end
    end

    for _, task_id in ipairs(task_ids) do
        local task = self._core._deps.get_overseer_task(task_id)
        if task and not task:is_complete() then
            task:subscribe("on_complete", function()
                check_done()
            end)
            task:stop()
        else
            check_done()
        end
    end
end

-- ===========================================================================
-- Task result recording
-- ===========================================================================

--- Record a task result and update the cache.
--- @param result loomworks.TaskResult
function Workspace:record_task_result(result)
    local project_key = result.project_key
    local config_key = result.configuration_key
    local action = result.action
    local success = result.success
    local now = self._core._deps.now()

    -- Ensure cache structure exists
    local cache_key = self._core._deps.cache.config_cache_key(project_key, config_key)
    self.cache.configurations = self.cache.configurations or {}

    local project = self._projects[project_key]
    local proj_type = project and project.type or "unknown"

    if not self.cache.configurations[cache_key] then
        self.cache.configurations[cache_key] = {
            project_key = project_key,
            config_key = config_key,
            type = proj_type,
            variant = result.variant,
            tool_key = result.tool and result.tool.key or nil,
        }
    end

    local cached_config = self.cache.configurations[cache_key]

    if action == "configure" then
        if success then
            -- Don't downgrade from built to configured
            if cached_config.state ~= "built" then
                cached_config.state = "configured"
            end
            cached_config.last_configured = now
        else
            cached_config.state = "failed_configure"
        end
    elseif action == "build" then
        if success then
            cached_config.state = "built"
            cached_config.last_built = now
        else
            cached_config.state = "failed_build"
        end
    end

    if result.build_dir then
        cached_config.build_dir = result.build_dir
    end
    if result.tool and result.tool.data then
        cached_config.tool_data = result.tool.data
    end

    if result.cmake then
        cached_config.cmake = cached_config.cmake or {}
        for k, v in pairs(result.cmake) do
            cached_config.cmake[k] = v
        end
    end

    self:_save_cache()
    self:_refresh_after_cache_change()

    -- Parse file-api targets after successful configure (runtime only, not cached)
    if action == "configure" and success and result.build_dir then
        if proj_type ~= "unknown" then
            local mod = self._core._deps.modules.get(proj_type)
            if mod and mod.parse_file_api then
                local unit = self:get_config_unit(project_key, config_key)
                unit:set_targets(mod.parse_file_api(result.build_dir, result.variant))
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
function Workspace:delete_cached_configs(items)
    if not self.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._core._deps.cache.config_cache_key(item.project_key, item.config_key)
        self.cache.configurations[cache_key] = nil
    end
end

--- Reset cached configurations: clear state to unconfigured (cache-only, no filesystem).
--- Keeps the cache entry skeleton (variant, tool_key, tool_data) intact.
--- @param items loomworks.DeletionItem[]
function Workspace:reset_cached_configs(items)
    if not self.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._core._deps.cache.config_cache_key(item.project_key, item.config_key)
        local cached_config = self.cache.configurations[cache_key]
        if cached_config then
            cached_config.state = nil
            cached_config.build_dir = nil
            cached_config.last_configured = nil
            cached_config.last_built = nil
            cached_config.cmake = nil
        end
    end
end

--- Mark cached configs as cleaned (reset build state but keep build_dir
--- and configuration metadata). Used after module clean tasks complete.
--- @param items table[] { project_key, config_key }
function Workspace:mark_cached_configs_cleaned(items)
    if not self.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._core._deps.cache.config_cache_key(item.project_key, item.config_key)
        local cached_config = self.cache.configurations[cache_key]
        if cached_config then
            cached_config.state = "configured"
            cached_config.last_built = nil
        end
    end
    self:_save_cache()
    self:_refresh_after_cache_change()
end

--- Set cache state to "unknown" for items that have build directories.
--- @param items loomworks.DeletionItem[]
function Workspace:_mark_cache_unknown(items)
    if not self.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._core._deps.cache.config_cache_key(item.project_key, item.config_key)
        local cached_config = self.cache.configurations[cache_key]
        if cached_config and cached_config.build_dir then
            cached_config.state = "unknown"
        end
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

--- Delete multiple build directories asynchronously via subprocesses (parallel).
--- @param dirs string[] list of normalized directory paths
--- @param callback fun(results: {dir: string, ok: boolean, err: string|nil}[])
function Workspace:_delete_build_dirs_async(dirs, callback)
    if #dirs == 0 then
        callback({})
        return
    end

    local results = {}
    local remaining = #dirs
    for _, dir in ipairs(dirs) do
        self._core._deps.io.rm_rf_async(dir, function(ok, err)
            results[#results + 1] = { dir = dir, ok = ok, err = err }
            remaining = remaining - 1
            if remaining == 0 then
                callback(results)
            end
        end)
    end
end

--- Common async deletion workflow: cancel conflicting operations, mark items
--- as deleting, stop running tasks, delete build dirs via async subprocess,
--- then apply cache mutations.
--- Crash-safe: cache is set to "unknown" before async deletion starts.
--- @param items table[] list of { project_key, config_key, ... }
--- @param work_fn function called after build dirs are successfully deleted (cache mutations)
--- @param on_done? function called when complete
--- @param reason? "deleting"|"cleaning" reason for the deletion flag (default "deleting")
function Workspace:_run_deletion(items, work_fn, on_done, reason)
    if #items == 0 then
        if on_done then on_done() end
        return
    end

    -- Cancel any active build/configure Operations on the affected units
    local units = {}
    for _, item in ipairs(items) do
        units[#units + 1] = self:get_config_unit(item.project_key, item.config_key)
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

    self:stop_tasks_then(task_ids, function()
        -- Crash-safe: mark cache as "unknown" before starting async deletion
        self:_mark_cache_unknown(items)
        self:_save_cache()

        -- Build set of ConfigUnits being deleted in this batch
        local deleting_units = {}
        for _, unit in ipairs(units) do
            deleting_units[unit] = true
        end

        -- Collect build directories to delete (skip shared dirs still referenced)
        local safe_prefix = self._core._deps.normalize(self.root)
        local dirs = {}
        local seen_dirs = {}
        for _, item in ipairs(items) do
            if item.build_dir then
                local normalized = self._core._deps.normalize(item.build_dir)
                if not seen_dirs[normalized] and self:_validate_build_dir(normalized, safe_prefix) then
                    seen_dirs[normalized] = true
                    -- Check if other configs still reference this dir
                    local ref_units = self._build_dir_refs[normalized]
                    if ref_units then
                        local remaining = 0
                        for _, ref_unit in ipairs(ref_units) do
                            if not deleting_units[ref_unit] then
                                remaining = remaining + 1
                            end
                        end
                        if remaining > 0 then
                            self._core._deps.notify(
                                "loomworks: skipped deleting " .. normalized
                                    .. " — still referenced by " .. remaining .. " config(s)",
                                vim.log.levels.INFO)
                            goto skip_dir
                        end
                    end
                    dirs[#dirs + 1] = normalized
                    ::skip_dir::
                end
            end
        end

        -- Delete build directories asynchronously
        self:_delete_build_dirs_async(dirs, function(results)
            -- Check for failures
            local errors = {}
            for _, r in ipairs(results) do
                if not r.ok then
                    errors[#errors + 1] = r
                end
            end

            if #errors > 0 then
                -- Failure: cache already has "unknown" state, notify user
                for _, e in ipairs(errors) do
                    self._core._deps.notify("loomworks: failed to delete " .. e.dir .. ": " .. (e.err or "unknown"), vim.log.levels.ERROR)
                end

                for _, unit in ipairs(units) do
                    unit:mark_deleting(false)
                end

                self:_save_cache()
                self:_refresh_after_cache_change()

                self._core._deps.events.emit("deletion_failed", { items = items, errors = errors })
                if on_done then on_done() end
                return
            end

            -- Success: apply cache mutations
            work_fn(items)

            self:_save_cache()
            self:_refresh_after_cache_change()

            for _, unit in ipairs(units) do
                unit:mark_deleting(false)
            end

            self._core._deps.events.emit("deletion_completed", items)

            if on_done then on_done() end
        end)
    end)
end

--- Execute a deletion plan asynchronously.
--- Items with disposition "clean" have their cache entries removed.
--- Items with disposition "reset" have their state cleared to unconfigured.
--- Items with disposition "keep" are left untouched (referenced by another profile).
--- Also removes the profile entry from cache if plan.profile_key is set.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: loomworks.Profile }
--- @param on_done? function called when deletion is complete
function Workspace:execute_deletion(plan, opts, on_done)
    opts = opts or {}

    -- Deactivate profile if requested
    if opts.deactivate_profile then
        opts.deactivate_profile:deactivate()
    end

    -- Remove profile entry from cache (before async work)
    if plan.profile_key then
        if self.cache.profiles and self.cache.profiles[plan.profile_key] then
            self.cache.profiles[plan.profile_key] = nil
            if not next(self.cache.profiles) then
                self.cache.profiles = nil
            end
            self:_save_cache()
        end
    end

    -- Split items by disposition
    local actionable = {}
    local clean_items = {}
    local reset_items = {}
    for _, item in ipairs(plan.items) do
        if item.disposition == "clean" then
            actionable[#actionable + 1] = item
            clean_items[#clean_items + 1] = item
        elseif item.disposition == "reset" then
            actionable[#actionable + 1] = item
            reset_items[#reset_items + 1] = item
        end
    end

    if #actionable == 0 then
        self:_refresh_after_cache_change()
        if on_done then on_done() end
        return
    end

    self:_run_deletion(actionable, function(effective_items)
        -- Split effective items by their original disposition
        local eff_clean = {}
        local eff_reset = {}
        local clean_set = {} -- [project_key][config_key] = true
        for _, item in ipairs(clean_items) do
            if not clean_set[item.project_key] then
                clean_set[item.project_key] = {}
            end
            clean_set[item.project_key][item.config_key] = true
        end
        for _, item in ipairs(effective_items) do
            if clean_set[item.project_key] and clean_set[item.project_key][item.config_key] then
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
end

-- ===========================================================================
-- Tool scanning
-- ===========================================================================

--- Scan tools from all modules present in the workspace.
--- Results are stored on the Workspace instance for use by merge and UI.
function Workspace:_scan_tools()
    self._tools_by_type = self._core._deps.merge.detect_tools(
        self.config, self.cache)
end

--- Scan tools asynchronously and remerge when complete.
function Workspace:_scan_tools_async()
    self._tool_state = "scanning"
    self._core._deps.events.emit("tools_scanning")

    self._core._deps.detect_tools_async(
        self.config, self.cache,
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

        local mod = self._core._deps.modules.get(project.type)
        if not mod then goto continue end

        local build_dir = unit:build_dir()
        if build_dir and mod.parse_file_api_async then
            units[#units + 1] = {
                unit = unit, mod = mod,
                scan_type = "file_api",
                build_dir = build_dir,
            }
        elseif mod.parse_targets_async and not seen_projects[unit.project_key] then
            -- Project-level target scan (e.g., npm scripts) -- once per project
            seen_projects[unit.project_key] = true
            local abs_path = self.root .. "/" .. (project.path or unit.project_key)
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
            entry.mod.parse_file_api_async(entry.build_dir, entry.unit.variant, on_targets)
        else
            entry.mod.parse_targets_async(entry.project_path, entry.unit.variant, on_targets)
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

--- Serialize workspace state to raw JSON-writable format.
--- Reads from domain objects (Project, ConfigurationSet, Profile), not from
--- workspace.config. This is the object → disk serialization boundary.
--- @return table raw JSON-compatible table
function Workspace:_serialize_config()
    local raw = { projects = {} }
    if self.name then
        raw.name = self.name
    end

    -- Projects from domain objects (skip cache-only orphans)
    for key, project in pairs(self._projects) do
        if not project.orphaned then
            local entry = { [project.type] = project.type_config or vim.empty_dict() }
            if project.path and project.path ~= key then
                entry.path = project.path
            end
            if project._depends_on_keys then
                entry.depends_on = project._depends_on_keys
            end
            if project.launch then
                entry.launch = project.launch
            end
            raw.projects[key] = entry
        end
    end

    -- Configuration sets from domain objects
    local sets = {}
    for name, cs in pairs(self._config_sets) do
        sets[name] = cs:raw_mappings()
    end
    if next(sets) then raw.configuration_sets = sets end

    -- Explicit profiles from domain objects
    local profiles = {}
    for key, profile in pairs(self._profiles) do
        if profile.explicit_def then
            profiles[key] = profile.explicit_def
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

--- Write the current user data to loomworks.user.json.
--- Updates the file tracker's cached content to suppress self-write detection.
function Workspace:_save_user()
    self._core._deps.user.save(self.root, self.user)
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
    if self.config.projects[key] then
        return false, "project '" .. key .. "' already exists"
    end

    -- Validate name for build dir safety (slashes, traversal, sanitization collisions)
    local existing_keys = {}
    for k in pairs(self.config.projects) do existing_keys[#existing_keys + 1] = k end
    local valid, verr = M.validate_path_name(key, existing_keys)
    if not valid then
        return false, "invalid project key: " .. verr
    end

    -- Add to parsed config + domain object
    local proj_data = {
        path = path or key,
        type = type,
        type_config = {},
    }
    self.config.projects[key] = proj_data

    local project = Project.new(self, key, {
        type = type,
        path = path or key,
        type_config = {},
        status = "unconfigured",
        configurations = {},
        cached_configurations = {},
    })
    self._projects[key] = project

    local ok, err = self:_save_config()
    if not ok then
        -- Rollback
        self.config.projects[key] = nil
        self._projects[key] = nil
        return false, err
    end

    self._core._deps.events.emit("active_set_changed", self._active_set)
    return true
end

--- Remove a project from the workspace.
--- Updates config, removes from configuration sets, remerges, and saves.
--- @param key string project key to remove
--- @return boolean ok, string|nil err
function Workspace:remove_project(key)
    if not self.config.projects[key] then
        return false, "project '" .. key .. "' not found"
    end

    self.config.projects[key] = nil

    -- Remove from domain objects
    local removed_project = self._projects[key]
    if removed_project then
        removed_project._removed = true
        self._projects[key] = nil
    end

    -- Remove from configuration_sets (config + domain objects)
    if self.config.configuration_sets then
        local empty_sets = {}
        for set_name, mappings in pairs(self.config.configuration_sets) do
            if type(mappings) == "table" then
                mappings[key] = nil
                if not next(mappings) then
                    empty_sets[#empty_sets + 1] = set_name
                end
            end
        end
        for _, set_name in ipairs(empty_sets) do
            self.config.configuration_sets[set_name] = nil
        end
        if not next(self.config.configuration_sets) then
            self.config.configuration_sets = nil
        end
    end
    -- Update ConfigurationSet domain objects
    if removed_project then
        for _, cs in pairs(self._config_sets) do
            cs.mappings[removed_project] = nil
        end
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
    if not self.config.configuration_sets then
        self.config.configuration_sets = {}
    end

    if self.config.configuration_sets[name] then
        return false, "configuration set '" .. name .. "' already exists"
    end

    -- Basic name validation (slashes, dots)
    local valid, verr = M.validate_path_name(name)
    if not valid then
        return false, "invalid configuration set name: " .. verr
    end

    -- Reject case-colliding names (same profile key on case-insensitive FS).
    -- Skip the name being added (already caught by exact match above) and
    -- skip names that will be removed as part of a rename (caller passes except).
    local name_lower = name:lower()
    for existing in pairs(self.config.configuration_sets) do
        if existing ~= name and existing:lower() == name_lower then
            return false, "configuration set '" .. name .. "' collides with '" .. existing .. "' (case-insensitive)"
        end
    end

    self.config.configuration_sets[name] = mappings

    -- Create domain object
    local cs = ConfigurationSet.new(self, name, mappings)
    self._config_sets[name] = cs

    local ok, err = self:_save_config()
    if not ok then
        self.config.configuration_sets[name] = nil
        self._config_sets[name] = nil
        return false, err
    end

    self._core._deps.events.emit("active_set_changed", self._active_set)
    return true
end

--- Remove a configuration set from the workspace.
--- @param name string configuration set name
--- @return boolean ok, string|nil err
function Workspace:remove_configuration_set(name)
    if not self.config.configuration_sets or not self.config.configuration_sets[name] then
        return false, "configuration set '" .. name .. "' not found"
    end

    self.config.configuration_sets[name] = nil

    if not next(self.config.configuration_sets) then
        self.config.configuration_sets = nil
    end

    -- Remove domain object
    local cs = self._config_sets[name]
    if cs then
        cs._removed = true
        self._config_sets[name] = nil
    end

    local ok, err = self:_save_config()
    if not ok then return false, err end

    -- Refresh profiles (detect orphaned_set for profiles referencing this set)
    self:_refresh_after_cache_change()
    return true
end


--- Extend a cached profile's configurations array with missing entries
--- for projects in its configuration set. Creates skeleton cache entries
--- for projects not yet represented. Used by upgrade_profiles_for_tool.
--- @param profile_data table cached profile data from cache.profiles
--- @param tools table<string, { key: string, data: table }>|nil tools dict
function Workspace:_extend_cached_profile(profile_data, tools)
    local set_name = profile_data.configuration_set
    if not set_name then return end

    local set_mappings = self.config.configuration_sets
        and self.config.configuration_sets[set_name]
    if not set_mappings then return end

    -- Build lookup of existing cache keys for fast membership check
    local existing = {}
    for _, ck in ipairs(profile_data.configurations or {}) do
        existing[ck] = true
    end

    profile_data.configurations = profile_data.configurations or {}
    self.cache.configurations = self.cache.configurations or {}

    for project_key, variant in pairs(set_mappings) do
        local project = self._projects[project_key]
        if project then
            -- Tool key applies only to projects whose module type matches
            local project_tool = tools and tools[project.type] or nil
            local project_tool_key = project_tool and project_tool.key or nil
            local config_key = self._core._deps.merge.build_config_key(variant, project_tool_key)
            local ck = self._core._deps.cache.config_cache_key(project_key, config_key)

            if not existing[ck] then
                -- Create skeleton cache entry if absent
                if not self.cache.configurations[ck] then
                    self.cache.configurations[ck] = {
                        project_key = project_key,
                        config_key = config_key,
                        type = project.type,
                        variant = variant,
                        tool_key = project_tool_key,
                        tool_data = project_tool and project_tool.data or nil,
                    }
                end
                profile_data.configurations[#profile_data.configurations + 1] = ck
            end
        end
    end
end

--- Compute profile renames that would result from a tools-dict transformation.
--- Pure query — does not mutate state.
--- @param transform fun(tools: table|nil): table|nil  tools dict transformation
--- @return { old_key: string, new_key: string }[]
function Workspace:compute_profile_renames(transform)
    if not self.cache.profiles then return {} end
    local merge = self._core._deps.merge
    local renames = {}
    for profile_key, profile_data in pairs(self.cache.profiles) do
        if profile_data.configuration_set then
            local new_tools = transform(profile_data.tools)
            local new_key = merge.profile_key(profile_data.configuration_set, new_tools)
            if profile_key ~= new_key then
                renames[#renames + 1] = {
                    old_key = profile_key,
                    new_key = new_key,
                }
            end
        end
    end
    table.sort(renames, function(a, b) return a.old_key < b.old_key end)
    return renames
end

--- Apply profile renames to cache and user state.
--- Updates the tools dict on each renamed profile via the transform function.
--- @param renames { old_key: string, new_key: string }[]
--- @param transform fun(tools: table|nil): table|nil
--- @return boolean user_changed whether active_profile was updated
function Workspace:apply_profile_renames(renames, transform)
    local user_changed = false
    for _, r in ipairs(renames) do
        local profile_data = self.cache.profiles[r.old_key]
        if profile_data then
            profile_data.tools = transform(profile_data.tools)
            self.cache.profiles[r.old_key] = nil
            self.cache.profiles[r.new_key] = profile_data
            if self.user.active_profile == r.old_key then
                self.user.active_profile = r.new_key
                user_changed = true
            end
        end
    end
    return user_changed
end

--- Upgrade cached profiles when a keyed-module project is added.
--- Profiles without this tool type get it added; profiles already with
--- tools get extended with skeleton entries for the new project.
---
--- @param tool_entry { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
function Workspace:upgrade_profiles_for_tool(tool_entry)
    if not self.cache.profiles then return end

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
    local function should_rename(profile_data)
        local cs = self._config_sets[profile_data.configuration_set]
        if not cs then return false end
        for project in pairs(cs.mappings) do
            if project.type == tool_entry.tool_mod_type then
                return true
            end
        end
        return false
    end

    -- Collect renames (profiles that need the tool added)
    local renames = {}
    local extends = {} -- profiles that already have tools
    for profile_key, profile_data in pairs(self.cache.profiles) do
        if profile_data.configuration_set then
            local has_this_tool = profile_data.tools
                and profile_data.tools[tool_entry.tool_mod_type]
            if not has_this_tool and should_rename(profile_data) then
                local new_tools = add_tool(profile_data.tools)
                local new_key = self._core._deps.merge.profile_key(
                    profile_data.configuration_set, new_tools)
                renames[#renames + 1] = { old_key = profile_key, new_key = new_key }
            elseif has_this_tool then
                extends[#extends + 1] = profile_data
            end
        end
    end

    -- Apply renames and update tools dicts
    local user_changed = self:apply_profile_renames(renames, add_tool)

    -- Extend renamed profiles with skeleton entries
    for _, r in ipairs(renames) do
        local profile_data = self.cache.profiles[r.new_key]
        if profile_data then
            self:_extend_cached_profile(profile_data, profile_data.tools)
        end
    end

    -- Extend existing keyed profiles with new project entries
    for _, profile_data in ipairs(extends) do
        self:_extend_cached_profile(profile_data, profile_data.tools)
    end

    self:_save_cache()
    if user_changed then
        self:_save_user()
    end
    self:_refresh_after_cache_change()
end

--- Compute profile renames that would occur if a project were removed.
--- Pure query — does not mutate state. Uses compute_profile_renames
--- with a remove-tool transform.
--- @param project_key string project key about to be removed
--- @return { old_key: string, new_key: string }[]
function Workspace:compute_downgrade_preview(project_key)
    local project = self._projects[project_key]
    if not project then return {} end

    local mod = self._core._deps.modules.get(project.type)
    if not mod or not mod.has_keyed_tools then return {} end

    -- Check if any OTHER project of the same type exists
    for key, proj in pairs(self._projects) do
        if key ~= project_key and proj.type == project.type then
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
    if not self.cache.profiles then return end

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

    -- Clean skeleton entries for the removed module type from each affected profile
    for _, profile_data in pairs(self.cache.profiles) do
        if profile_data.configuration_set
            and profile_data.tools and profile_data.tools[mod_type] then
            if profile_data.configurations then
                local kept = {}
                for _, ck in ipairs(profile_data.configurations) do
                    local cached_cfg = self.cache.configurations and self.cache.configurations[ck]
                    if not cached_cfg or cached_cfg.type ~= mod_type then
                        kept[#kept + 1] = ck
                    else
                        -- Remove skeleton entries from cache; keep entries with
                        -- build state (they become proper orphaned configs)
                        local state = cached_cfg.state
                        if not state or state == "unconfigured" then
                            self.cache.configurations[ck] = nil
                        end
                    end
                end
                profile_data.configurations = kept
            end
        end
    end

    -- Compute and apply renames
    local renames = self:compute_profile_renames(remove_tool)
    local user_changed = self:apply_profile_renames(renames, remove_tool)

    self:_save_cache()
    if user_changed then
        self:_save_user()
    end
    self:_refresh_after_cache_change()
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
    if not self.config.projects or not next(self.config.projects) then
        return nil, "no projects defined"
    end

    local modules = self._core._deps.modules

    -- Gather project info
    local project_infos = {} -- { key, type, config_names[], mod }
    for project_key, project_cfg in pairs(self.config.projects) do
        local mod = modules.get(project_cfg.type)
        if mod and mod.info and mod.map_variant then
            local abs_path = self.root .. "/" .. (project_cfg.path or project_key)
            local info = mod.info(abs_path, project_cfg.type_config or {})
            if info and info.configurations then
                local config_names = {}
                for name in pairs(info.configurations) do
                    config_names[#config_names + 1] = name
                end
                table.sort(config_names)
                project_infos[#project_infos + 1] = {
                    key = project_key,
                    type = project_cfg.type,
                    config_names = config_names,
                    mod = mod,
                }
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
                self.config = data.config
                self.user = data.user
                self.cache = data.cache
                self:_scan_tools_async()
                self:remerge()
                self._core._deps.notify("loomworks: config reloaded", vim.log.levels.INFO)
            else
                self._core._deps.notify("loomworks: config reload failed: " .. val_err, vim.log.levels.WARN)
            end
        else
            self._core._deps.notify("loomworks: config reload failed: " .. (err or "unknown"), vim.log.levels.WARN)
        end

    elseif path == paths.user then
        -- user.json changed: update user data and remerge
        local user_data = content and user_mod.parse(content) or user_mod.default()
        self.user = user_data
        self:remerge()

    elseif path == paths.cache then
        -- cache.json changed: update cache data and remerge
        local cache_data = content and cache_mod.parse(content) or cache_mod.default()
        self.cache = cache_data
        self:remerge()
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
