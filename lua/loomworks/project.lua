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
--- @param data loomworks.MergedProjectData
function Project:_update(data)
    self.type = data.type
    self.path = data.path
    self.type_config = data.type_config
    self.launch = data.launch
    self.configuration = data.configuration
    -- Resolve Tool domain object from workspace registry
    self._tool = nil
    if data.tool_key and self._workspace.find_tool then
        self._tool = self._workspace:find_tool(data.tool_mod_type or self.type, data.tool_key)
    end
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
    -- Resolve to Project objects (best effort — some deps may not exist)
    self.depends_on = nil
    if data.depends_on then
        local deps = {}
        for _, dep_key in ipairs(data.depends_on) do
            local dep = self._workspace._projects[dep_key]
            if dep then
                deps[#deps + 1] = dep
            end
        end
        if #deps > 0 then
            self.depends_on = deps
        end
    end
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

    -- Mark removed
    for name, cfg in pairs(self._configurations) do
        if not all_config_data[name] then
            cfg._removed = true
            self._configurations[name] = nil
        end
    end

    -- Create or update
    for name, info in pairs(all_config_data) do
        local existing = self._configurations[name]
        if existing then
            existing:_update(info)
        else
            self._configurations[name] = Configuration.new(self, name, info)
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

--- Get ConfigUnits matching a variant name (e.g., "Debug").
--- For keyed-tool modules this may return multiple units (one per tool).
--- @param variant string
--- @return loomworks.ConfigUnit[]
function Project:config_units_for_variant(variant)
    local result = {}
    for _, unit in pairs(self._workspace._config_units) do
        if unit._project == self and unit._cached and unit._cached.variant == variant then
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

--- Check if a specific configuration variant is being deleted.
--- @param variant string configuration variant name
--- @return boolean
function Project:is_deleting_config(variant)
    for _, unit in ipairs(self:config_units_for_variant(variant)) do
        if unit:is_deleting() then return true end
    end
    return false
end

--- Get the running action for a specific configuration variant.
--- @param variant string configuration variant name
--- @return string|nil action
function Project:config_running_action(variant)
    for _, unit in ipairs(self:config_units_for_variant(variant)) do
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
function Project:_refresh_configurations()
    local mod = self._workspace._core._deps.modules.get(self.type)
    if not mod or not mod.info then return end
    local abs_path = self._workspace.root .. "/" .. (self.path or self.key)
    local mod_info = mod.info(abs_path, self.type_config or {})
    if mod_info then
        self.configurations = mod_info.configurations or {}
        self.preset_configurations = mod_info.preset_configurations or nil
    end
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

    -- Step 3: Update configuration_set domain objects + raw config
    for cs in pairs(old_cs_mappings) do
        cs.mappings[self] = new_name
        -- Keep raw config in sync (needed by _refresh_after_cache_change)
        if ws.config.configuration_sets and ws.config.configuration_sets[cs.name] then
            ws.config.configuration_sets[cs.name][self.key] = new_name
        end
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
            if ws.config.configuration_sets and ws.config.configuration_sets[cs.name] then
                ws.config.configuration_sets[cs.name][self.key] = old_val
            end
        end
        return false, err
    end

    -- Step 4: Migrate cache entries
    local cache_rename_map = {} -- old_cache_key -> new_cache_key
    if ws.cache.configurations then
        local to_migrate = {}
        for cache_key, entry in pairs(ws.cache.configurations) do
            if entry.project_key == self.key and entry.variant == old_name then
                to_migrate[#to_migrate + 1] = { cache_key = cache_key, entry = entry }
            end
        end
        for _, item in ipairs(to_migrate) do
            local entry = item.entry
            local new_config_key = ws._core._deps.merge.build_config_key(new_name, entry.tool_key)
            local new_cache_key = ws._core._deps.cache.config_cache_key(self.key, new_config_key)
            -- Move entry to new key with updated fields
            entry.variant = new_name
            entry.config_key = new_config_key
            ws.cache.configurations[new_cache_key] = entry
            ws.cache.configurations[item.cache_key] = nil
            cache_rename_map[item.cache_key] = new_cache_key
        end
    end

    -- Step 5: Update profiles — configurations arrays, pinned mappings, and pinned profile keys.
    -- Note: pinned_key(project_key, config_key) produces the same string as
    -- config_cache_key(project_key, config_key) — both are "project_key/config_key".
    -- So cache_rename_map doubles as the pinned profile rename map.
    if ws.cache.profiles then
        local profile_rekeys = {} -- old_profile_key -> new_profile_key
        for profile_key, profile_data in pairs(ws.cache.profiles) do
            -- Update configurations arrays (cache key references)
            if profile_data.configurations and next(cache_rename_map) then
                for i, ck in ipairs(profile_data.configurations) do
                    if cache_rename_map[ck] then
                        profile_data.configurations[i] = cache_rename_map[ck]
                    end
                end
            end
            -- Update pinned profile mappings (variant references)
            if profile_data.mappings and profile_data.mappings[self.key] == old_name then
                profile_data.mappings[self.key] = new_name
            end
            -- Rekey pinned profiles (pinned key == cache key format)
            if cache_rename_map[profile_key] then
                profile_rekeys[profile_key] = cache_rename_map[profile_key]
            end
        end
        -- Apply profile rekeys
        for old_pk, new_pk in pairs(profile_rekeys) do
            local data = ws.cache.profiles[old_pk]
            ws.cache.profiles[old_pk] = nil
            ws.cache.profiles[new_pk] = data
            -- Update active_profile if it was the old key
            if ws.user.active_profile == old_pk then
                ws.user.active_profile = new_pk
                ws:_save_user()
            end
        end
    end

    ws:_save_cache()
    self:_refresh_configurations()
    ws:_refresh_after_cache_change()
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
