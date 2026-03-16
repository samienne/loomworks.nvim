--- loomworks/core.lua — All stateful business logic.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.

--- @class loomworks.Core
--- @field _deps table injected dependencies
--- @field _workspace loomworks.Workspace|nil
--- @field _active_set loomworks.ActiveSet|nil
--- @field _config_units table<string, loomworks.ConfigUnit> "project\0config" -> unit
--- @field _config_sets table<string, loomworks.ConfigurationSet> name -> ConfigurationSet
--- @field _delete_waiters function[]
--- @field _tracker loomworks.FileTracker|nil
--- @field _tools_by_type table<string, loomworks.DetectedTool[]> tools per module type
--- @field _profiles table<string, loomworks.Profile>
--- @field _projects table<string, loomworks.Project>
--- @field _setup_error { root: string, message: string }|nil set when setup fails
--- @field _state "uninitialized"|"initializing"|"initialized"
--- @field _tool_state "not_scanned"|"scanning"|"scanned"
--- @field _tool_waiters function[]
local Core = {}
Core.__index = Core

local Profile = require("loomworks.profile").Profile
local Project = require("loomworks.project")
local ConfigUnit = require("loomworks.config_unit")
local ConfigurationSet = require("loomworks.configuration_set")

--- Default dependency table. Tests override individual entries.
local DEFAULT_DEPS = {
    workspace = require("loomworks.workspace"),
    merge     = require("loomworks.merge"),
    events    = require("loomworks.events"),
    user      = require("loomworks.user"),
    cache     = require("loomworks.cache"),
    config    = require("loomworks.config"),
    io        = require("loomworks.io"),
    read_file_async = require("loomworks.io").read_file_async,
    read_files_async = require("loomworks.io").read_files_async,
    detect_tools_async = require("loomworks.merge").detect_tools_async,
    modules   = require("loomworks.modules"),
    FileTracker = require("loomworks.file_tracker"),
    notify    = vim.notify,
    now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    clock     = function() return vim.uv.hrtime() / 1e9 end,
    normalize = vim.fs.normalize,
    schedule  = vim.schedule,
    --- Resolve an overseer task by id. Returns nil if overseer not available.
    --- @param task_id number
    --- @return table|nil task
    get_overseer_task = function(task_id)
        local ok, task_list = pcall(require, "overseer.task_list")
        if not ok then return nil end
        return task_list.get(task_id)
    end,
    --- Get the file path for a buffer.
    --- @param bufnr number
    --- @return string
    buf_name = function(bufnr)
        return vim.api.nvim_buf_get_name(bufnr)
    end,
}

--- Create a new Core instance.
--- @param deps? table override individual dependencies for testing
--- @return loomworks.Core
function Core.new(deps)
    local self = setmetatable({}, Core)
    if deps then
        self._deps = setmetatable(deps, { __index = DEFAULT_DEPS })
    else
        self._deps = DEFAULT_DEPS
    end
    self._workspace = nil
    self._active_set = nil
    self._delete_waiters = {}
    self._tracker = nil
    self._tools_by_type = {}
    self._config_units = {}
    self._config_sets = {}
    self._profiles = {}
    self._projects = {}
    self._profile_projects = {}
    self._setup_error = nil
    self._state = "uninitialized"
    self._tool_state = "not_scanned"
    self._tool_waiters = {}
    return self
end

--- Get or create a ConfigUnit for a (project_key, config_key) pair.
--- Returns the same instance for the same pair (registry/flyweight pattern).
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function Core:get_config_unit(project_key, config_key)
    local key = project_key .. "\0" .. config_key
    local unit = self._config_units[key]
    if not unit then
        unit = ConfigUnit.new(self, project_key, config_key)
        self._config_units[key] = unit
    end
    return unit
end

-- ---------------------------------------------------------------------------
-- Cache helpers
-- ---------------------------------------------------------------------------

--- Save the cache file with standard error handling.
--- @return boolean ok
function Core:_save_cache()
    if not self._workspace then return false end
    -- Strip runtime-only data (targets) before persisting
    local cache = self._workspace.cache
    if cache.configurations then
        for _, cfg in pairs(cache.configurations) do
            if cfg.cmake then cfg.cmake.targets = nil end
        end
    end
    local ok, err = self._deps.cache.save(self._workspace.root, cache)
    if not ok then
        self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Workspace & merge
-- ---------------------------------------------------------------------------

--- Validate all projects against their modules.
--- @param config loomworks.Config
--- @param root string
--- @return boolean ok, string|nil err
function Core:_validate_projects(config, root)
    local modules_mod = self._deps.modules
    for key, project in pairs(config.projects) do
        local mod = modules_mod.get(project.type)
        if mod and mod.validate then
            local abs_path = root .. "/" .. project.path
            local result = mod.validate(abs_path, project.type_config)
            if not result.valid then
                return false, "project '" .. key .. "': " .. table.concat(result.warnings, "; ")
            end
            for _, warning in ipairs(result.warnings) do
                self._deps.notify("loomworks: project '" .. key .. "': " .. warning, vim.log.levels.WARN)
            end
        end
    end
    return true, nil
end

--- Scan tools from all modules present in the workspace.
--- Results are stored on the Core instance for use by merge and UI.
function Core:_scan_tools()
    if not self._workspace then return end
    self._tools_by_type = self._deps.merge.detect_tools(
        self._workspace.config, self._workspace.cache)
end

--- Scan tools asynchronously and remerge when complete.
function Core:_scan_tools_async()
    if not self._workspace then return end
    self._tool_state = "scanning"
    self._deps.events.emit("tools_scanning")

    self._deps.detect_tools_async(
        self._workspace.config, self._workspace.cache,
        function(tools_by_type)
            self._deps.schedule(function()
                self._tools_by_type = tools_by_type
                self:remerge()
                self._tool_state = "scanned"
                self._deps.events.emit("tools_detected")

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
function Core:_scan_targets_async()
    if not self._workspace then return end

    -- Collect units that have a build_dir and a cmake project type
    local units = {}
    for _, unit in pairs(self._config_units) do
        local build_dir = unit:build_dir()
        if build_dir then
            local ws = self._workspace
            local proj_cfg = ws and ws.config.projects and ws.config.projects[unit.project_key]
            if proj_cfg then
                local mod = self._deps.modules.get(proj_cfg.type)
                if mod and mod.parse_file_api_async then
                    units[#units + 1] = { unit = unit, mod = mod, build_dir = build_dir }
                end
            end
        end
    end

    if #units == 0 then return end

    local idx = 0
    local any_found = false
    local function next_unit()
        idx = idx + 1
        if idx > #units then
            if any_found then
                self._deps.events.emit("active_set_changed", self._active_set)
            end
            return
        end

        local entry = units[idx]
        entry.mod.parse_file_api_async(entry.build_dir, entry.unit.variant,
            function(targets)
                self._deps.schedule(function()
                    if targets then
                        entry.unit.targets = targets
                        any_found = true
                    end
                    next_unit()
                end)
            end
        )
    end

    next_unit()
end

--- Re-scan tools and remerge. Used for manual rescan from UI.
function Core:rescan_tools()
    local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
    if ok then cmake_kits.clear_cache() end
    self:_scan_tools_async()
end

--- Check if a module type has keyed tools (static, no detection needed).
--- @param mod_type string
--- @return boolean
function Core:module_has_keyed_tools(mod_type)
    return self._deps.merge.module_has_keyed_tools(mod_type)
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function Core:get_tools_by_type()
    return self._tools_by_type
end

--- Handle a tracked file change.
--- @param path string absolute file path that changed
--- @param content string|nil new raw content
function Core:_on_file_changed(path, content)
    if not self._workspace then return end

    local paths = self._deps.workspace.paths(self._workspace.root)

    if path == paths.config then
        -- loomworks.json changed: full reassemble
        local ws, err = self._deps.workspace.assemble(
            self._workspace.root,
            content,
            self._tracker:content(paths.user),
            self._tracker:content(paths.cache)
        )
        if ws then
            local ok, val_err = self:_validate_projects(ws.config, ws.root)
            if ok then
                self._workspace = ws
                self:_scan_tools_async()
                self:_migrate_set_names()
                self:remerge()
                self._deps.notify("loomworks: config reloaded", vim.log.levels.INFO)
            else
                self._deps.notify("loomworks: config reload failed: " .. val_err, vim.log.levels.WARN)
            end
        else
            self._deps.notify("loomworks: config reload failed: " .. (err or "unknown"), vim.log.levels.WARN)
        end

    elseif path == paths.user then
        -- user.json changed: update user data and remerge
        local user_data = content and self._deps.user.parse(content) or self._deps.user.default()
        self._workspace.user = user_data
        self:remerge()

    elseif path == paths.cache then
        -- cache.json changed: update cache data and remerge
        local cache_data = content and self._deps.cache.parse(content) or self._deps.cache.default()
        self._workspace.cache = cache_data
        self:remerge()
    end
end

--- Get the workspace initialization state.
--- @return "uninitialized"|"initializing"|"initialized"
function Core:state()
    return self._state
end

--- Get the tool detection state.
--- @return "not_scanned"|"scanning"|"scanned"
function Core:tool_state()
    return self._tool_state
end

--- Initialize the workspace asynchronously.
--- Reads files in parallel, then processes synchronously via vim.schedule.
--- @param opts? { root?: string }
function Core:setup(opts)
    if self._state == "initializing" then return end

    self._setup_error = nil
    self._state = "initializing"
    self._deps.events.emit("workspace_initializing")

    local ws_mod = self._deps.workspace
    local root = ws_mod.resolve_root(opts and opts.root or nil)
    local paths = ws_mod.paths(root)

    self._deps.read_files_async(
        { paths.config, paths.user, paths.cache },
        function(results)
            self._deps.schedule(function()
                self:_on_files_read(root, paths, results)
            end)
        end
    )
end

--- Process read file results and complete initialization.
--- @param root string
--- @param paths table
--- @param results table<string, string|nil>
function Core:_on_files_read(root, paths, results)
    local ws_mod = self._deps.workspace

    local config_content = results[paths.config]
    if not config_content then
        self._deps.notify("loomworks: loomworks.json not found in " .. root, vim.log.levels.ERROR)
        self._state = "uninitialized"
        return
    end
    local user_content = results[paths.user]
    local cache_content = results[paths.cache]

    -- Assemble workspace from raw content
    local ws, err = ws_mod.assemble(root, config_content, user_content, cache_content)
    if not ws then
        self._deps.notify("loomworks: " .. err, vim.log.levels.ERROR)
        self._state = "uninitialized"
        return
    end

    -- Refuse to load when cache has incompatible version
    if ws.cache_version_mismatch then
        local msg = "Cache version mismatch (expected v3). Press <C-n> to reset."
        self._setup_error = { root = root, message = msg }
        self._deps.notify("loomworks: " .. msg, vim.log.levels.ERROR)
        self._state = "uninitialized"
        return
    end

    -- Validate projects
    local ok, val_err = self:_validate_projects(ws.config, ws.root)
    if not ok then
        self._deps.notify("loomworks: " .. val_err, vim.log.levels.ERROR)
        self._state = "uninitialized"
        return
    end

    self._workspace = ws
    self._config_units = {}
    self._config_sets = {}
    self._profiles = {}
    self._projects = {}
    self._profile_projects = {}
    self:_migrate_set_names()
    self:_cleanup_orphaned_skeletons()
    self:remerge()
    self._state = "initialized"
    self._deps.events.emit("workspace_changed", ws)

    -- Start file tracking
    if self._tracker then
        self._tracker:stop()
    end
    self._tracker = self._deps.FileTracker.new({
        callback = function(path, content)
            self:_on_file_changed(path, content)
        end,
        schedule = self._deps.schedule,
        read_file = self._deps.io.read_file,
    })
    self._tracker:watch(paths.config)
    self._tracker:watch(paths.user)
    self._tracker:watch(paths.cache)

    self._deps.notify("loomworks: workspace '" .. ws.name .. "' loaded (" .. ws.root .. ")", vim.log.levels.INFO)

    -- Start async tool detection
    self:_scan_tools_async()
end

--- Validate that a path is a child of root/.nvim/ before deletion.
--- Uses absolute normalized paths to prevent directory traversal.
--- @param path string path to validate
--- @param root string workspace root
--- @return boolean safe
function Core:_safe_nvim_path(path, root)
    local normalize = self._deps.normalize
    local norm_path = normalize(path)
    local nvim_prefix = normalize(root .. "/.nvim")
    -- Ensure path starts with root/.nvim/ (trailing slash prevents partial matches)
    return norm_path == nvim_prefix or norm_path:sub(1, #nvim_prefix + 1) == nvim_prefix .. "/"
end

--- Nuke the cache: delete .nvim/build/ and loomworks.cache.json, then reload.
--- Caller must confirm with the user before calling this.
--- @param root string workspace root to nuke
function Core:nuke_cache(root)
    -- Safety: root must be absolute (Unix /... or Windows C:/...)
    local norm_root = self._deps.normalize(root)
    if not norm_root:match("^/") and not norm_root:match("^%a:/") then
        self._deps.notify("loomworks: nuke_cache requires an absolute path, got: " .. root, vim.log.levels.ERROR)
        return
    end

    -- Safety: loomworks.json must exist at root (confirms this is a real workspace)
    local config_path = norm_root .. "/loomworks.json"
    if not self._deps.io.read_file(config_path) then
        self._deps.notify("loomworks: no loomworks.json found at " .. norm_root .. ", aborting nuke", vim.log.levels.ERROR)
        return
    end

    -- Build absolute paths
    local build_dir = norm_root .. "/.nvim/build"
    local cache_path = self._deps.cache.filepath(norm_root)
    local cache_bak = cache_path .. ".bak"

    -- Safety: verify all paths are under root/.nvim/
    local paths_to_delete = { build_dir, cache_path, cache_bak }
    for _, p in ipairs(paths_to_delete) do
        if not self:_safe_nvim_path(p, norm_root) then
            self._deps.notify("loomworks: refusing to delete path outside .nvim/: " .. p, vim.log.levels.ERROR)
            return
        end
    end

    -- Delete build directory
    local ok, err = self._deps.io.rm_rf(build_dir)
    if not ok then
        self._deps.notify("loomworks: failed to delete build dir: " .. err, vim.log.levels.ERROR)
    end

    -- Delete cache file and backup
    self._deps.io.rm_rf(cache_path)
    self._deps.io.rm_rf(cache_bak)

    -- Re-setup from scratch
    self:setup({ root = norm_root })
end

--- Re-merge workspace state, sync object registries, and emit events.
--- Order matters: each step may depend on objects synced in previous steps.
function Core:remerge()
    if not self._workspace then return end
    local active_set, all_profile_defs = self._deps.merge.merge(
        self._workspace, self._tools_by_type)
    self._active_set = active_set
    self:_sync_projects()                    -- 1. no deps
    self:_sync_config_sets()                 -- 2. needs Projects
    self:_sync_profiles(all_profile_defs)    -- 3. needs ConfigurationSets
    self:_sync_profile_projects()            -- 4. needs Profiles
    self:_sync_config_units()                -- 5. needs Profiles (for config_keys)
    self._deps.events.emit("active_set_changed", self._active_set)
end

--- Get the merged active configuration set.
--- @return loomworks.ActiveSet|nil
function Core:get_active_configuration_set()
    return self._active_set
end

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function Core:get_workspace()
    return self._workspace
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function Core:get_setup_error()
    return self._setup_error
end

-- ---------------------------------------------------------------------------
-- Object registries
-- ---------------------------------------------------------------------------

--- Sync the profiles registry with current merge data.
--- Creates new Profile objects, updates existing ones in place, removes stale ones.
--- Profile._update resolves its own mappings from Core's config sets registry.
--- @param all_defs table<string, loomworks.ProfileDef> profile definitions from merge
function Core:_sync_profiles(all_defs)
    local ws = self._workspace
    if not ws then return end

    -- Mark removed profiles
    for key, profile in pairs(self._profiles) do
        if not all_defs[key] then
            profile._removed = true
            self._profiles[key] = nil
        end
    end

    -- Create or update — Profile._update handles mapping resolution internally
    for key, data in pairs(all_defs) do
        data._ws_cache = ws.cache
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
function Core:_sync_projects()
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
--- ConfigurationSet._update resolves project_key → Project internally.
function Core:_sync_config_sets()
    local ws = self._workspace
    local defs = ws and ws.config.configuration_sets or {}

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
function Core:_sync_profile_projects()
    local ProfileProject = require("loomworks.profile").ProfileProject

    -- Build the set of expected (profile_key, project_key) pairs
    local expected = {}
    for profile_key, profile in pairs(self._profiles) do
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                local reg_key = profile_key .. "\0" .. project_key
                expected[reg_key] = { profile = profile, variant = variant }
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
            -- Extract project_key from reg_key (after the \0 separator)
            local project_key = reg_key:match("%z(.+)$")
            self._profile_projects[reg_key] = ProfileProject.new(
                self, info.profile, project_key, info.variant)
        end
    end
end

--- Sync the config units registry.
--- Collects all valid (project_key, config_key) pairs from profiles and cache,
--- creates/updates/removes ConfigUnit objects. Preserves runtime state.
function Core:_sync_config_units()
    local ws = self._workspace
    if not ws then return end

    -- Collect all valid (project_key, config_key) pairs
    local expected = {} -- reg_key -> true

    -- From all profiles' mappings (via profile_projects)
    for _, pp in pairs(self._profile_projects) do
        local reg_key = pp.project_key .. "\0" .. pp.config_key
        expected[reg_key] = true
    end

    -- From cache entries
    if ws.cache.configurations then
        for _, cached_config in pairs(ws.cache.configurations) do
            local reg_key = cached_config.project_key .. "\0" .. cached_config.config_key
            expected[reg_key] = true
        end
    end

    -- Mark removed (only if not running/deleting — don't remove active units)
    for reg_key, unit in pairs(self._config_units) do
        if not expected[reg_key] and not unit:is_running() and not unit:is_deleting() then
            unit._removed = true
            self._config_units[reg_key] = nil
        end
    end

    -- Create or update
    for reg_key in pairs(expected) do
        local existing = self._config_units[reg_key]
        if existing then
            existing:_update()
        else
            local project_key = reg_key:match("^(.-)%z")
            local config_key = reg_key:match("%z(.+)$")
            self._config_units[reg_key] = ConfigUnit.new(self, project_key, config_key)
        end
    end
end

--- Get all ConfigurationSet objects.
--- @return table<string, loomworks.ConfigurationSet>
function Core:get_config_sets()
    return self._config_sets
end

--- Get the active Profile object.
--- @return loomworks.Profile|nil
function Core:get_active_profile()
    if not self._active_set or not self._active_set.name then return nil end
    return self._profiles[self._active_set.name]
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function Core:get_profiles()
    return self._profiles
end

--- Get tool entries for the configuration sets UI.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function Core:get_tool_entries()
    if not self._workspace then return {} end
    return self._deps.merge.get_tool_entries(
        self._workspace.config, self._workspace.cache, self._tools_by_type)
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function Core:get_projects()
    return self._projects
end

-- ---------------------------------------------------------------------------
-- Profile materialization
-- ---------------------------------------------------------------------------

--- Materialize a profile from structured data: write it to cache with full
--- tool and project references. Creates skeleton configuration entries.
--- No-op if the profile is already materialized (by property match).
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
function Core:_materialize_from_data(config_set, tool_entry)
    if not self._workspace then return end

    -- Wait for tool detection to complete before materializing
    if self._tool_state == "scanning" then
        self._tool_waiters[#self._tool_waiters + 1] = function()
            self:_materialize_from_data(config_set, tool_entry)
        end
        return
    end

    local ws = self._workspace
    local set_name = config_set.name

    -- Compute profile key (pure cache identifier)
    local tool_key = tool_entry and tool_entry.tool_key or nil
    local profile_key = self._deps.merge.profile_key(set_name, tool_key)

    -- Already cached?
    if ws.cache.profiles and ws.cache.profiles[profile_key] then return end

    local tool_data = tool_entry and tool_entry.tool_data or nil
    local tool_label = tool_entry and tool_entry.tool_label or nil
    local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil

    local profile_configurations = {}
    ws.cache.configurations = ws.cache.configurations or {}

    for project, variant in pairs(config_set.mappings) do
        local project_config = ws.config.projects[project.key]
        if not project_config then goto continue end

        local config_key = self._deps.merge.build_config_key(
            project_config.type, variant, tool_key)

        local cache_key = self._deps.cache.config_cache_key(project.key, config_key)
        profile_configurations[#profile_configurations + 1] = cache_key

        -- Ensure skeleton config entry exists in flat cache
        if not ws.cache.configurations[cache_key] then
            local has_keyed = self._deps.merge.module_has_keyed_tools(
                project_config.type)
            ws.cache.configurations[cache_key] = {
                project_key = project.key,
                config_key = config_key,
                type = project_config.type,
                variant = variant,
                tool_key = tool_key,
                tool_data = has_keyed and tool_data or nil,
            }
        end

        ::continue::
    end

    -- Write profile to cache
    ws.cache.profiles = ws.cache.profiles or {}
    ws.cache.profiles[profile_key] = {
        configuration_set = set_name,
        tool_key = tool_key,
        tool_data = tool_data,
        tool_label = tool_label,
        tool_mod_type = tool_mod_type,
        configurations = profile_configurations,
    }

    self:_save_cache()
    self:remerge()
end

--- Migrate cached profile names when configuration_sets are renamed (case change).
--- Matches cached profiles to config sets case-insensitively and updates the cache.
function Core:_migrate_set_names()
    local ws = self._workspace
    if not ws or not ws.cache.profiles or not ws.config.configuration_sets then return end

    -- Build case-insensitive lookup: lowercase -> actual name in config
    local config_sets_lower = {}
    for name in pairs(ws.config.configuration_sets) do
        config_sets_lower[name:lower()] = name
    end

    local renames = {} -- old_key -> { new_key, new_set }
    for profile_key, cached_profile in pairs(ws.cache.profiles) do
        local old_set = cached_profile.configuration_set
        if not old_set then goto continue end -- pinned profiles have no set

        -- Already matches exactly?
        if ws.config.configuration_sets[old_set] then goto continue end

        -- Try case-insensitive match
        local new_set = config_sets_lower[old_set:lower()]
        if new_set then
            local new_key = self._deps.merge.profile_key(new_set, cached_profile.tool_key)
            renames[profile_key] = { new_key = new_key, new_set = new_set }
        end

        ::continue::
    end

    if not next(renames) then return end

    for old_key, info in pairs(renames) do
        local profile_data = ws.cache.profiles[old_key]
        profile_data.configuration_set = info.new_set
        ws.cache.profiles[info.new_key] = profile_data
        ws.cache.profiles[old_key] = nil

        -- Update active_profile if it was the old key
        if ws.user.active_profile == old_key then
            ws.user.active_profile = info.new_key
            self._deps.user.save(ws.root, ws.user)
        end
    end

    self:_save_cache()
end

--- Build a set of all cache keys referenced by profiles.
--- @return table<string, boolean> referenced set keyed by cache key ("project_key/config_key")
function Core:_build_referenced_set()
    local ws = self._workspace
    local referenced = {}
    if ws and ws.cache.profiles then
        for _, profile in pairs(ws.cache.profiles) do
            if profile.configurations then
                for _, ck in ipairs(profile.configurations) do
                    referenced[ck] = true
                end
            end
        end
    end
    return referenced
end

--- Clean up unreferenced unconfigured skeletons on init.
--- Configs with no state and no profile reference are silently dropped.
--- Configs with state are left as orphaned (shown in UI).
function Core:_cleanup_orphaned_skeletons()
    local ws = self._workspace
    if not ws or not ws.cache.configurations then return end

    local referenced = self:_build_referenced_set()

    local changed = false
    local to_drop = {}

    for cache_key, cached_config in pairs(ws.cache.configurations) do
        if not referenced[cache_key] then
            local state = cached_config.state
            if not state or state == "unconfigured" then
                to_drop[#to_drop + 1] = cache_key
                changed = true
            end
        end
    end

    for _, cache_key in ipairs(to_drop) do
        ws.cache.configurations[cache_key] = nil
    end

    if changed then
        self:_save_cache()
    end
end

--- Get orphaned cached configs: configs with state not referenced by any profile.
--- @return loomworks.OrphanedConfig[]
function Core:get_orphaned_configs()
    local ws = self._workspace
    if not ws or not ws.cache.configurations then return {} end

    local referenced = self:_build_referenced_set()

    local result = {}
    for cache_key, cached_config in pairs(ws.cache.configurations) do
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



-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Check if any tasks are currently running.
--- @return boolean
function Core:has_running_tasks()
    for _, unit in pairs(self._config_units) do
        if unit:is_running() then return true end
    end
    return false
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
function Core:find_running_tasks_for_items(items)
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
function Core:stop_tasks_then(task_ids, on_done)
    if #task_ids == 0 then
        on_done()
        return
    end

    local remaining = #task_ids
    local schedule = self._deps.schedule
    local function check_done()
        remaining = remaining - 1
        if remaining == 0 then
            schedule(on_done)
        end
    end

    for _, task_id in ipairs(task_ids) do
        local task = self._deps.get_overseer_task(task_id)
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

-- ---------------------------------------------------------------------------
-- Task result recording
-- ---------------------------------------------------------------------------

--- Record a task result and update the cache.
--- @param result loomworks.TaskResult
function Core:record_task_result(result)
    if not self._workspace then return end

    local ws = self._workspace
    local project_key = result.project_key
    local config_key = result.configuration_key
    local action = result.action
    local success = result.success
    local now = self._deps.now()

    -- Ensure cache structure exists
    local cache_key = self._deps.cache.config_cache_key(project_key, config_key)
    ws.cache.configurations = ws.cache.configurations or {}

    local proj_type = ws.config.projects[project_key]
            and ws.config.projects[project_key].type or "unknown"

    if not ws.cache.configurations[cache_key] then
        ws.cache.configurations[cache_key] = {
            project_key = project_key,
            config_key = config_key,
            type = proj_type,
            variant = result.variant,
            tool_key = result.tool and result.tool.key or nil,
        }
    end

    local cached_config = ws.cache.configurations[cache_key]

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
    self:remerge()

    -- Parse file-api targets after successful configure (runtime only, not cached)
    if action == "configure" and success and result.build_dir then
        if proj_type ~= "unknown" then
            local mod = self._deps.modules.get(proj_type)
            if mod and mod.parse_file_api then
                local unit = self:get_config_unit(project_key, config_key)
                unit.targets = mod.parse_file_api(result.build_dir, result.variant)
            end
        end
    end
    self._deps.events.emit("task_result", result)
end

-- ---------------------------------------------------------------------------
-- Deletion: query & status
-- ---------------------------------------------------------------------------

--- Check if any items are currently being deleted.
--- @return boolean
function Core:has_pending_deletions()
    for _, unit in pairs(self._config_units) do
        if unit:is_deleting() then return true end
    end
    return false
end

--- Wait for all pending deletions to finish, then call fn.
--- If nothing is pending, calls fn immediately.
--- @param fn function
function Core:after_deletions(fn)
    if not self:has_pending_deletions() then
        fn()
        return
    end
    self._delete_waiters[#self._delete_waiters + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Deletion: execute
-- ---------------------------------------------------------------------------

--- Validate a build directory path is safe to delete (under workspace root).
--- Checks that the path is strictly under the workspace root using a
--- directory boundary check (trailing "/") to prevent prefix collisions
--- (e.g., "/root" must not match "/roots/...").
--- @param build_dir string normalized path
--- @param safe_prefix string normalized workspace root
--- @return boolean safe
function Core:_validate_build_dir(build_dir, safe_prefix)
    local is_under = build_dir == safe_prefix
        or build_dir:sub(1, #safe_prefix + 1) == safe_prefix .. "/"
    if not is_under then
        self._deps.notify("loomworks: refusing to delete build dir outside workspace: " .. build_dir, vim.log.levels.ERROR)
        return false
    end
    return true
end

--- Delete multiple build directories asynchronously via subprocesses (parallel).
--- @param dirs string[] list of normalized directory paths
--- @param callback fun(results: {dir: string, ok: boolean, err: string|nil}[])
function Core:_delete_build_dirs_async(dirs, callback)
    if #dirs == 0 then
        callback({})
        return
    end

    local results = {}
    local remaining = #dirs
    for _, dir in ipairs(dirs) do
        self._deps.io.rm_rf_async(dir, function(ok, err)
            results[#results + 1] = { dir = dir, ok = ok, err = err }
            remaining = remaining - 1
            if remaining == 0 then
                callback(results)
            end
        end)
    end
end

--- Remove cache entries entirely (cache-only, no filesystem operations).
--- @param items loomworks.DeletionItem[]
function Core:delete_cached_configs(items)
    if not self._workspace then return end

    local ws = self._workspace
    if not ws.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._deps.cache.config_cache_key(item.project_key, item.config_key)
        ws.cache.configurations[cache_key] = nil
    end
end

--- Reset cached configurations: clear state to unconfigured (cache-only, no filesystem).
--- Keeps the cache entry skeleton (variant, tool_key, tool_data) intact.
--- @param items loomworks.DeletionItem[]
function Core:reset_cached_configs(items)
    if not self._workspace then return end

    local ws = self._workspace
    if not ws.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._deps.cache.config_cache_key(item.project_key, item.config_key)
        local cached_config = ws.cache.configurations[cache_key]
        if cached_config then
            cached_config.state = nil
            cached_config.build_dir = nil
            cached_config.last_configured = nil
            cached_config.last_built = nil
            cached_config.cmake = nil
        end
    end
end

--- Set cache state to "unknown" for items that have build directories.
--- @param items loomworks.DeletionItem[]
function Core:_mark_cache_unknown(items)
    if not self._workspace then return end

    local ws = self._workspace
    if not ws.cache.configurations then return end
    for _, item in ipairs(items) do
        local cache_key = self._deps.cache.config_cache_key(item.project_key, item.config_key)
        local cached_config = ws.cache.configurations[cache_key]
        if cached_config and cached_config.build_dir then
            cached_config.state = "unknown"
        end
    end
end

--- Common async deletion workflow: mark items as deleting, stop running tasks,
--- delete build dirs via async subprocess, then apply cache mutations.
--- Crash-safe: cache is set to "unknown" before async deletion starts.
--- @param items table[] list of { project_key, config_key, ... }
--- @param work_fn function called after build dirs are successfully deleted (cache mutations)
--- @param on_done? function called when complete
function Core:_run_deletion(items, work_fn, on_done)
    if #items == 0 then
        if on_done then on_done() end
        return
    end

    for _, item in ipairs(items) do
        self:get_config_unit(item.project_key, item.config_key):mark_deleting(true)
    end
    self._deps.events.emit("deletion_started", items)

    local running = self:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    self:stop_tasks_then(task_ids, function()
        -- Crash-safe: mark cache as "unknown" before starting async deletion
        self:_mark_cache_unknown(items)
        self:_save_cache()

        -- Collect build directories to delete
        local ws = self._workspace
        if not ws then
            if on_done then on_done() end
            return
        end

        local safe_prefix = self._deps.normalize(ws.root)
        local dirs = {}
        for _, item in ipairs(items) do
            if item.build_dir then
                local normalized = self._deps.normalize(item.build_dir)
                if self:_validate_build_dir(normalized, safe_prefix) then
                    dirs[#dirs + 1] = normalized
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
                    self._deps.notify("loomworks: failed to delete " .. e.dir .. ": " .. (e.err or "unknown"), vim.log.levels.ERROR)
                end

                -- Discard any queued actions on failed items
                for _, item in ipairs(items) do
                    local unit = self:get_config_unit(item.project_key, item.config_key)
                    unit:mark_deleting(false)
                end

                self:_save_cache()
                self:remerge()

                if not self:has_pending_deletions() then
                    local waiters = self._delete_waiters
                    self._delete_waiters = {}
                    for _, fn in ipairs(waiters) do fn() end
                end

                self._deps.events.emit("deletion_failed", { items = items, errors = errors })
                if on_done then on_done() end
                return
            end

            -- Success: check for queued actions before applying cache mutations
            local queued = {}
            for _, item in ipairs(items) do
                local unit = self:get_config_unit(item.project_key, item.config_key)
                local action = unit:pop_queued_action()
                if action then
                    queued[#queued + 1] = { item = item, action = action }
                end
            end

            -- Apply cache mutations for items without queued actions
            if #queued > 0 then
                -- Items with queued actions: reset to unconfigured (keep cache entry)
                local queued_items = {}
                local normal_items = {}
                local queued_set = {}
                for _, q in ipairs(queued) do
                    local key = q.item.project_key .. "\0" .. q.item.config_key
                    queued_set[key] = true
                    queued_items[#queued_items + 1] = q.item
                end
                for _, item in ipairs(items) do
                    local key = item.project_key .. "\0" .. item.config_key
                    if not queued_set[key] then
                        normal_items[#normal_items + 1] = item
                    end
                end
                -- Reset queued items to unconfigured
                self:reset_cached_configs(queued_items)
                -- Apply normal work_fn only to non-queued items
                -- For simplicity, run work_fn for all then restore queued ones
                -- Actually, the work_fn operates on all items - we need to exclude queued ones
                -- Split: run work_fn replacement logic manually
                -- The work_fn is either delete_cached_configs or reset_cached_configs
                -- We handle this by not calling work_fn for queued items
                if #normal_items > 0 then
                    -- Re-scope work_fn: this is called with the original items, so we need
                    -- to apply the mutation to normal items only. The caller passes work_fn
                    -- that operates on the full item list. Instead, we apply mutations directly.
                    work_fn(normal_items)
                end
            else
                work_fn(items)
            end

            self:_save_cache()
            self:remerge()

            for _, item in ipairs(items) do
                self:get_config_unit(item.project_key, item.config_key):mark_deleting(false)
            end
            if not self:has_pending_deletions() then
                local waiters = self._delete_waiters
                self._delete_waiters = {}
                for _, fn in ipairs(waiters) do fn() end
            end

            self._deps.events.emit("deletion_completed", items)

            -- Execute queued actions after everything is settled
            for _, q in ipairs(queued) do
                self._deps.schedule(function()
                    local overseer = require("loomworks.overseer")
                    overseer.run_config_action(q.item.project_key, q.item.config_key, q.action)
                end)
            end

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
function Core:execute_deletion(plan, opts, on_done)
    opts = opts or {}

    -- Deactivate profile if requested
    if opts.deactivate_profile then
        opts.deactivate_profile:deactivate()
    end

    -- Remove profile entry from cache (before async work)
    if plan.profile_key and self._workspace then
        local ws = self._workspace
        if ws.cache.profiles and ws.cache.profiles[plan.profile_key] then
            ws.cache.profiles[plan.profile_key] = nil
            if not next(ws.cache.profiles) then
                ws.cache.profiles = nil
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
        self:remerge()
        if on_done then on_done() end
        return
    end

    self:_run_deletion(actionable, function(effective_items)
        -- Split effective items by their original disposition
        local eff_clean = {}
        local eff_reset = {}
        local clean_set = {}
        for _, item in ipairs(clean_items) do
            clean_set[item.project_key .. "\0" .. item.config_key] = true
        end
        for _, item in ipairs(effective_items) do
            local key = item.project_key .. "\0" .. item.config_key
            if clean_set[key] then
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

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return string|nil project_key, loomworks.Project|nil
function Core:project_for_buf(bufnr)
    if not self._workspace then return nil, nil end

    local buf_path = self._deps.buf_name(bufnr)
    if buf_path == "" then return nil, nil end
    buf_path = self._deps.normalize(buf_path)

    local best_key, best_len = nil, 0
    for key, project in pairs(self._workspace.config.projects) do
        local project_abs = self._deps.normalize(self._workspace.root .. "/" .. project.path)
        if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
            best_key = key
            best_len = #project_abs
        end
    end

    if best_key then
        return best_key, self._projects[best_key]
    end
    return nil, nil
end

--- Stop file tracking and clean up.
function Core:shutdown()
    if self._tracker then
        self._tracker:stop()
        self._tracker = nil
    end
end

return Core
