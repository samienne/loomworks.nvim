--- loomworks/project.lua — Project object wrapping merged project data.
--- Provides query methods for running/deleting/cached state.

local Configuration = require("loomworks.configuration")

--- @class loomworks.Project
--- @field key string project key
--- @field type string module type ("cmake", "ets", "typescript")
--- @field path? string relative path from workspace root
--- @field type_config? table module-specific configuration (options, configurations, etc.)
--- @field launch? table<string, table> launch configurations
--- @field configuration? string active configuration name
--- @field _tool? loomworks.Tool direct reference to Tool domain object
--- @field status loomworks.Status
--- @field orphaned boolean
--- @field needs_refresh boolean
--- @field refresh_reasons string[]
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field cached? loomworks.CachedConfig active configuration's cached state
--- @field cached_configurations table<string, loomworks.CachedConfig>
--- @field cmake? loomworks.ProjectCmakeInfo
--- @field depends_on? loomworks.Project[] direct references to dependency projects
--- @field _depends_on_keys? string[] raw keys from merge (resolved to objects in _update)
--- @field _configurations? table<string, loomworks.Configuration> name -> Configuration domain object
--- @field _workspace loomworks.Workspace
--- @field _removed boolean
local Project = {}
Project.__index = Project

--- Create a new Project object.
--- @param workspace loomworks.Workspace
--- @param key string project key
--- @param data? loomworks.MergedProjectData
--- @return loomworks.Project
function Project.new(workspace, key, data)
    local self = setmetatable({}, Project)
    self._workspace = workspace
    self.key = key
    self._removed = false
    self._configurations = {}
    if data then self:_update(data) end
    return self
end

--- Update all data fields in place (preserves table identity).
--- Pre-resolved fields (_module, _tool, _depends_on) are set by _sync_projects.
--- @param data loomworks.MergedProjectData
function Project:_update(data)
    self.type = data.type
    self.path = data.path
    self.type_config = data.type_config
    self.launch = data.launch
    self.configuration = data.configuration
    -- Read pre-resolved Module and Tool domain objects (set by _sync_projects)
    self._module = data._module
    self._tool = data._tool
    self.status = data.status
    self.orphaned = data.orphaned or false
    self.needs_refresh = data.needs_refresh or false
    self.refresh_reasons = data.refresh_reasons or {}
    self.configurations = data.configurations or {}
    self.preset_configurations = data.preset_configurations or nil
    self.cached = data.cached
    self.cached_configurations = data.cached_configurations or {}
    self.cmake = data.cmake
    -- Store raw keys for deferred resolution (projects may not all exist yet)
    self._depends_on_keys = data.depends_on
    -- Read pre-resolved dependency Project objects (set by _sync_projects)
    self.depends_on = data._depends_on
    -- Sync Configuration domain objects from configurations dict
    self:_sync_configurations()
end

--- Sync Configuration domain objects from the configurations dict.
--- Creates/updates/removes Configuration objects to match self.configurations.
--- Also syncs preset configurations (from_preset flag).
function Project:_sync_configurations()
    local new_data = self.configurations or {}

    -- Include preset configurations with from_preset flag
    local all_config_data = {}
    for name, info in pairs(new_data) do
        all_config_data[name] = info
    end
    if self.preset_configurations then
        for name, info in pairs(self.preset_configurations) do
            if not all_config_data[name] then
                all_config_data[name] = info
            end
        end
    end

    -- Collect unique variant names from cache
    local cache_variants = {}
    for _, entry in pairs(self.cached_configurations) do
        if entry.variant then
            cache_variants[entry.variant] = true
        end
    end

    -- Mark removed (only if absent from both sources AND cache)
    for name, cfg in pairs(self._configurations) do
        if not all_config_data[name] and not cache_variants[name] then
            cfg._removed = true
            self._configurations[name] = nil
        end
    end

    -- Create or update from module/preset sources
    for name, info in pairs(all_config_data) do
        local existing = self._configurations[name]
        if existing then
            existing:_update(info)
            existing._source_missing = false
        else
            self._configurations[name] = Configuration.new(self, name, info)
        end
    end

    -- Enrich from cache: create Configuration for cache-only variants,
    -- and mark existing ones as source-missing if not in module/preset output
    for variant_name in pairs(cache_variants) do
        if not self._configurations[variant_name] then
            local cfg = Configuration.new(self, variant_name, {})
            cfg._source_missing = true
            self._configurations[variant_name] = cfg
        elseif not all_config_data[variant_name] then
            self._configurations[variant_name]._source_missing = true
        end
    end

    -- Resolve inherits references (all configs exist now)
    for _, cfg in pairs(self._configurations) do
        cfg:_resolve_inherits()
    end
end

--- Get a Configuration domain object by name.
--- @param name string configuration name
--- @return loomworks.Configuration|nil
function Project:get_configuration(name)
    return self._configurations[name]
end

--- Get all Configuration domain objects.
--- @return table<string, loomworks.Configuration>
function Project:get_configurations()
    return self._configurations
end

function Project:__tostring()
    return "Project(" .. self.key .. ")"
end

--- Get all ConfigUnits belonging to this project (scan on demand).
--- @return loomworks.ConfigUnit[]
function Project:config_units()
    local result = {}
    for _, unit in pairs(self._workspace._config_units) do
        if unit._project == self then
            result[#result + 1] = unit
        end
    end
    return result
end

--- Get ConfigUnits matching a Configuration domain object.
--- For keyed-tool modules this may return multiple units (one per tool).
--- @param configuration loomworks.Configuration
--- @return loomworks.ConfigUnit[]
function Project:config_units_for_configuration(configuration)
    local result = {}
    for _, unit in pairs(self._workspace._config_units) do
        if unit._project == self and unit._configuration == configuration then
            result[#result + 1] = unit
        end
    end
    return result
end

--- Get the running action for this project (any config).
--- @return string|nil action ("configure" or "build")
function Project:running_action()
    for _, unit in pairs(self._workspace._config_units) do
        if unit._project == self and unit:is_running() then
            return unit:running_action()
        end
    end
    return nil
end

--- Check if a specific configuration is being deleted.
--- @param configuration loomworks.Configuration
--- @return boolean
function Project:is_deleting_config(configuration)
    for _, unit in ipairs(self:config_units_for_configuration(configuration)) do
        if unit:is_deleting() then return true end
    end
    return false
end

--- Get the running action for a specific configuration.
--- @param configuration loomworks.Configuration
--- @return string|nil action
function Project:config_running_action(configuration)
    for _, unit in ipairs(self:config_units_for_configuration(configuration)) do
        local action = unit:running_action()
        if action then return action end
    end
    return nil
end

--- Resolve the cached state for a configuration.
--- Checks kit-qualified key first, then bare name.
--- @param config_name string
--- @return loomworks.CachedConfig|nil
function Project:cached_config(config_name)
    if not self.cached_configurations then return nil end
    if self._tool and self._tool.key then
        local cached = self.cached_configurations[config_name .. ":" .. self._tool.key]
        if cached then return cached end
    end
    return self.cached_configurations[config_name]
end

--- Get absolute path to this project.
--- @return string
function Project:abs_path()
    return self._workspace.root .. "/" .. (self.path or self.key)
end

--- Build the module context table used by module.tasks().
--- @param ws_root string workspace root path
--- @return loomworks.ModuleContext
function Project:to_module_context(ws_root)
    local tool_key = self._tool and self._tool.key or nil
    local tool_data = self._tool and self._tool.data or nil
    return {
        name = self.key,
        path = self.path or self.key,
        type = self.type,
        configuration = self.configuration,
        configurations = self.configurations,
        tool_key = tool_key,
        tool_data = tool_data,
        workspace_root = ws_root,
        env = tool_data and tool_data.env or {},
    }
end

-- ========================== Mutation methods ==========================

--- Refresh configurations from module info after config changes.
--- Re-syncs Configuration domain objects so callers see updated names/data.
function Project:_refresh_configurations()
    local mod = self._module and self._module.impl or nil
    if not mod or not mod.info then return end
    local abs_path = self._workspace.root .. "/" .. (self.path or self.key)
    local mod_info = mod.info(abs_path, self.type_config or {})
    if mod_info then
        self.configurations = mod_info.configurations or {}
        self.preset_configurations = mod_info.preset_configurations or nil
    end
    self:_sync_configurations()
end

--- Save a project configuration (create or update).
--- @param config_name string configuration name
--- @param config_data table { variant?, inherits?, options?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function Project:save_configuration(config_name, config_data)
    local ws = self._workspace

    -- Validate config name for build dir safety
    local validate_path_name = require("loomworks.workspace").validate_path_name
    local existing_names = {}
    if self.type_config and self.type_config.configurations then
        for k in pairs(self.type_config.configurations) do
            existing_names[#existing_names + 1] = k
        end
    end
    local valid, verr = validate_path_name(config_name, existing_names)
    if not valid then
        return false, "invalid configuration name: " .. verr
    end

    -- Ensure type_config.configurations exists
    if not self.type_config then self.type_config = {} end
    if not self.type_config.configurations then
        self.type_config.configurations = {}
    end

    -- Omit empty fields
    local clean = {}
    if config_data.variant then clean.variant = config_data.variant end
    if config_data.inherits then clean.inherits = config_data.inherits end
    if config_data.options and next(config_data.options) then
        clean.options = config_data.options
    end
    if config_data.toolchain then clean.toolchain = config_data.toolchain end
    if config_data.generator then clean.generator = config_data.generator end

    self.type_config.configurations[config_name] = clean

    local ok, err = ws:_save_config()
    if not ok then
        self.type_config.configurations[config_name] = nil
        if not next(self.type_config.configurations) then
            self.type_config.configurations = nil
        end
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Delete a project configuration.
--- @param config_name string
--- @return boolean ok, string|nil err
function Project:delete_configuration(config_name)
    local ws = self._workspace
    if not self.type_config or not self.type_config.configurations
            or not self.type_config.configurations[config_name] then
        return false, "configuration '" .. config_name .. "' not found"
    end

    local old = self.type_config.configurations[config_name]
    self.type_config.configurations[config_name] = nil
    if not next(self.type_config.configurations) then
        self.type_config.configurations = nil
    end

    local ok, err = ws:_save_config()
    if not ok then
        if not self.type_config.configurations then
            self.type_config.configurations = {}
        end
        proj.type_config.configurations[config_name] = old
        self.type_config = proj.type_config
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Rename a project configuration atomically: updates loomworks.json
--- (type_config, inherits, config_set mappings) and cache (rekeys entries,
--- updates profile configurations arrays). Build dirs are preserved as-is.
--- @param old_name string current configuration name
--- @param new_name string desired new name
--- @param config_data table { variant?, inherits?, options?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function Project:rename_configuration(old_name, new_name, config_data)
    local ws = self._workspace

    if not self.type_config or not self.type_config.configurations
            or not self.type_config.configurations[old_name] then
        return false, "configuration '" .. old_name .. "' not found"
    end

    -- Validate new name
    local validate_path_name = require("loomworks.workspace").validate_path_name
    local existing_names = {}
    for k in pairs(self.type_config.configurations) do
        if k ~= old_name then existing_names[#existing_names + 1] = k end
    end
    local valid, verr = validate_path_name(new_name, existing_names)
    if not valid then
        return false, "invalid configuration name: " .. verr
    end

    -- Snapshot for rollback
    local old_config_data_snapshot = self.type_config.configurations[old_name]
    local old_inherits_snapshot = {}
    for cname, cdata in pairs(self.type_config.configurations) do
        if cdata.inherits then
            old_inherits_snapshot[cname] = cdata.inherits
        end
    end
    local old_cs_mappings = {} -- cs -> old_variant (for rollback)
    for _, cs in pairs(ws._config_sets) do
        if cs.mappings[self] == old_name then
            old_cs_mappings[cs] = old_name
        end
    end

    -- Step 1: Update inherits in sibling configs
    for _, cdata in pairs(self.type_config.configurations) do
        if cdata.inherits then
            if type(cdata.inherits) == "string" then
                if cdata.inherits == old_name then
                    cdata.inherits = new_name
                end
            elseif type(cdata.inherits) == "table" then
                for i, base in ipairs(cdata.inherits) do
                    if base == old_name then
                        cdata.inherits[i] = new_name
                    end
                end
            end
        end
    end

    -- Step 2: Rename in type_config.configurations
    local clean = {}
    if config_data.variant then clean.variant = config_data.variant end
    if config_data.inherits then clean.inherits = config_data.inherits end
    if config_data.options and next(config_data.options) then
        clean.options = config_data.options
    end
    if config_data.toolchain then clean.toolchain = config_data.toolchain end
    if config_data.generator then clean.generator = config_data.generator end
    self.type_config.configurations[old_name] = nil
    self.type_config.configurations[new_name] = clean

    -- Step 3: Update configuration_set domain objects
    for cs in pairs(old_cs_mappings) do
        cs.mappings[self] = new_name
    end

    -- Save config to disk
    local ok, err = ws:_save_config()
    if not ok then
        -- Rollback
        self.type_config.configurations[new_name] = nil
        self.type_config.configurations[old_name] = old_config_data_snapshot
        for cname, inh in pairs(old_inherits_snapshot) do
            if self.type_config.configurations[cname] then
                self.type_config.configurations[cname].inherits = inh
            end
        end
        for cs, old_val in pairs(old_cs_mappings) do
            cs.mappings[self] = old_val
        end
        return false, err
    end

    -- Step 4: Migrate cache entries (ConfigUnit objects + cache)
    local cache_rename_map = {} -- old_cache_key -> new_cache_key
    local to_migrate = {}
    for _, unit in pairs(ws._config_units) do
        if unit._project == self and unit._variant
                and unit._variant == old_name then
            to_migrate[#to_migrate + 1] = unit
        end
    end
    for _, unit in ipairs(to_migrate) do
        local old_config_key = unit._config_key
        local new_config_key = ws._core._deps.merge.build_config_key(new_name, unit._tool_key)
        local new_cache_key = ws._core._deps.cache.config_cache_key(self.key, new_config_key)
        -- Update first-class fields
        unit._variant = new_name
        unit._config_key = new_config_key
        -- Update ConfigUnit identity
        local old_id = unit.id
        unit.id = new_cache_key
        cache_rename_map[old_id] = new_cache_key
        -- Update Project.cached_configurations (was previously done via shared _cached table mutation)
        if old_config_key and self.cached_configurations then
            local entry = self.cached_configurations[old_config_key]
            if entry then
                self.cached_configurations[old_config_key] = nil
                entry.variant = new_name
                entry.config_key = new_config_key
                self.cached_configurations[new_config_key] = entry
            end
        end
    end

    -- Step 5: Update profiles — _cached_configurations, pinned mappings, and pinned profile keys.
    if next(cache_rename_map) then
        local profile_rekeys = {} -- old_profile_key -> new_profile_key
        for _, profile in pairs(ws._profiles) do
            -- Update _cached_configurations arrays
            if profile._cached_configurations then
                for i, ck in ipairs(profile._cached_configurations) do
                    if cache_rename_map[ck] then
                        profile._cached_configurations[i] = cache_rename_map[ck]
                    end
                end
            end
            -- Update pinned profile mappings (variant references)
            if profile.mappings and profile.mappings[self.key] == old_name then
                profile.mappings[self.key] = new_name
            end
            -- Rekey pinned profiles (pinned key == cache key format)
            if cache_rename_map[profile.key] then
                profile_rekeys[profile.key] = cache_rename_map[profile.key]
            end
        end
        -- Apply profile rekeys (domain objects + cache)
        for old_pk, new_pk in pairs(profile_rekeys) do
            for _, profile in pairs(ws._profiles) do
                if profile.key == old_pk then
                    profile.key = new_pk
                    break
                end
            end
            -- Keep cache in sync during transition
            if ws.cache and ws.cache.profiles then
                local data = ws.cache.profiles[old_pk]
                if data then
                    ws.cache.profiles[old_pk] = nil
                    ws.cache.profiles[new_pk] = data
                    -- Also update cache profile data
                    if data.configurations and next(cache_rename_map) then
                        for i, ck in ipairs(data.configurations) do
                            if cache_rename_map[ck] then
                                data.configurations[i] = cache_rename_map[ck]
                            end
                        end
                    end
                    if data.mappings and data.mappings[self.key] == old_name then
                        data.mappings[self.key] = new_name
                    end
                end
            end
            -- Update active_profile if it was the old key
            if ws._active_profile_key == old_pk then
                ws._active_profile_key = new_pk
                ws:_save_user()
            end
        end
    end

    ws:_save_cache()

    self:_refresh_configurations()
    -- Rebuild PPs for all profiles (rename may have changed keys, mappings, and config units)
    for _, profile in pairs(ws._profiles) do
        ws:_rebuild_profile_projects_for(profile)
    end
    ws:_sync_build_dir_refs()
    ws:_resolve_active_profile()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save project-wide options.
--- @param options table<string, string>
--- @return boolean ok, string|nil err
function Project:save_options(options)
    local ws = self._workspace

    if not self.type_config then self.type_config = {} end
    local old = self.type_config.options
    self.type_config.options = next(options) and options or nil

    local ok, err = ws:_save_config()
    if not ok then
        self.type_config.options = old
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save a launch configuration for this project.
--- @param launch_name string
--- @param config table { command, args?, working_dir?, env? }
--- @return boolean ok, string|nil err
function Project:save_launch_config(launch_name, config)
    local ws = self._workspace
    if self._removed then
        return false, "project '" .. self.key .. "' has been removed"
    end

    if not self.launch then
        self.launch = {}
    end
    self.launch[launch_name] = config

    local ok, err = ws:_save_config()
    if not ok then
        self.launch[launch_name] = nil
        if not next(self.launch) then self.launch = nil end
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Delete a launch configuration from this project.
--- @param launch_name string
--- @return boolean ok, string|nil err
function Project:delete_launch_config(launch_name)
    local ws = self._workspace

    if not self.launch or not self.launch[launch_name] then
        return false, "launch config '" .. launch_name .. "' not found"
    end

    local old = self.launch[launch_name]
    self.launch[launch_name] = nil
    if not next(self.launch) then self.launch = nil end

    local ok, err = ws:_save_config()
    if not ok then
        if not self.launch then self.launch = {} end
        self.launch[launch_name] = old
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

return Project
