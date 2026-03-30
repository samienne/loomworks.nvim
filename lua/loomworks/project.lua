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
--- @field _configurations? loomworks.Configuration[] Configuration domain objects array
--- @field _workspace loomworks.Workspace
--- @field _removed boolean
--- @field _source "user"|"shared" provenance: "user" = from user.json, "shared" = from loomworks.json
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
    self._source = "shared"
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
    -- Store type_config without .configurations — that data lives on
    -- Configuration domain objects and is reconstructed for serialization.
    if data.type_config then
        local tc = data.type_config
        if tc.configurations then
            tc = vim.deepcopy(tc)
            tc.configurations = nil
        end
        self.type_config = tc
    else
        self.type_config = data.type_config
    end
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

    -- Build name→existing lookup from current array for identity matching
    local existing_by_name = {}
    for _, cfg in ipairs(self._configurations) do
        existing_by_name[cfg.name] = cfg
    end

    -- Mark removed (absent from both sources AND cache)
    for _, cfg in ipairs(self._configurations) do
        if not all_config_data[cfg.name] and not cache_variants[cfg.name] then
            cfg._removed = true
        end
    end

    -- Build new array: for each source config, find existing or create new
    local new_arr = {}
    local seen = {}
    for name, info in pairs(all_config_data) do
        local existing = existing_by_name[name]
        if existing and not existing._removed then
            existing:_update(info)
            existing._source_missing = false
            new_arr[#new_arr + 1] = existing
        else
            new_arr[#new_arr + 1] = Configuration.new(self, name, info)
        end
        seen[name] = true
    end

    -- Enrich from cache: create Configuration for cache-only variants,
    -- and mark existing ones as source-missing if not in module/preset output.
    -- When creating from cache, use inline configuration snapshot data if available.
    for variant_name in pairs(cache_variants) do
        if not seen[variant_name] then
            local existing = existing_by_name[variant_name]
            if existing and not existing._removed then
                existing._source_missing = true
                new_arr[#new_arr + 1] = existing
            else
                -- Find the best cache entry with snapshot data for this variant
                local cfg_data = {}
                for _, cc in pairs(self.cached_configurations) do
                    if cc.variant == variant_name then
                        if cc.is_user then cfg_data.is_user = true end
                        if cc.options then cfg_data.options = cc.options end
                        if cc.inherits then cfg_data.inherits = cc.inherits end
                        -- Merge module_config fields into cfg_data (they become
                        -- module_config inside Configuration._update)
                        if cc.module_config then
                            for k, v in pairs(cc.module_config) do
                                cfg_data[k] = v
                            end
                        end
                        break
                    end
                end
                local cfg = Configuration.new(self, variant_name, cfg_data)
                cfg._source_missing = true
                new_arr[#new_arr + 1] = cfg
            end
            seen[variant_name] = true
        end
    end

    -- Replace with new array
    self._configurations = new_arr

    -- Resolve inherits references (all configs exist now)
    for _, cfg in ipairs(self._configurations) do
        cfg:_resolve_inherits()
    end
end

--- Get a Configuration domain object by name.
--- @param name string configuration name
--- @return loomworks.Configuration|nil
function Project:get_configuration(name)
    for _, cfg in ipairs(self._configurations) do
        if cfg.name == name then return cfg end
    end
    return nil
end

--- Get or create a Configuration domain object by name.
--- If no Configuration exists, creates a source-missing stub.
--- Used by sync_config_sets to ensure CS mappings always have Configuration objects.
--- @param name string configuration name
--- @return loomworks.Configuration
function Project:ensure_configuration(name)
    local existing = self:get_configuration(name)
    if existing then return existing end
    local cfg = Configuration.new(self, name, {})
    cfg._source_missing = true
    self._configurations[#self._configurations + 1] = cfg
    return cfg
end

--- Get all Configuration domain objects.
--- @return loomworks.Configuration[]
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

--- Build a type_config table with .configurations reconstructed from
--- Configuration domain objects. Used wherever module.info() needs the
--- user-override data (which is no longer stored on type_config at runtime).
--- @return table type_config with .configurations populated
function Project:_type_config_for_module()
    local tc = vim.deepcopy(self.type_config or {})
    local configs = {}
    for _, cfg in ipairs(self._configurations) do
        local override = cfg:serialize_user_override()
        if override then
            configs[cfg.name] = override
        end
    end
    if next(configs) then
        tc.configurations = configs
    else
        tc.configurations = nil
    end
    return tc
end

-- ========================== Mutation methods ==========================

--- Refresh configurations from module info after config changes.
--- Re-syncs Configuration domain objects so callers see updated names/data.
function Project:_refresh_configurations()
    local mod = self._module and self._module.impl or nil
    if not mod or not mod.info then return end
    local abs_path = self._workspace.root .. "/" .. (self.path or self.key)
    local tc = self:_type_config_for_module()
    local mod_info = mod.info(abs_path, tc)
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
    for _, cfg in ipairs(self._configurations) do
        if cfg.is_user then
            existing_names[#existing_names + 1] = cfg.name
        end
    end
    local valid, verr = validate_path_name(config_name, existing_names)
    if not valid then
        return false, "invalid configuration name: " .. verr
    end

    -- Build the data table for Configuration._update (user override format)
    local clean = { is_user = true }
    if config_data.variant then clean.variant = config_data.variant end
    if config_data.inherits then clean.inherits = config_data.inherits end
    if config_data.options and next(config_data.options) then
        clean.options = config_data.options
    end
    if config_data.toolchain then clean.toolchain = config_data.toolchain end
    if config_data.generator then clean.generator = config_data.generator end

    -- Create or update Configuration domain object
    local existing = self:get_configuration(config_name)
    local old_cfg_snapshot = nil
    if existing then
        -- Snapshot for rollback
        old_cfg_snapshot = {
            is_user = existing.is_user,
            is_default = existing.is_default,
            from_preset = existing.from_preset,
            role = existing.role,
            options = existing.options,
            inherits_names = existing.inherits_names,
            module_config = vim.deepcopy(existing.module_config),
        }
        existing:_update(clean)
        existing:_resolve_inherits()
    else
        local cfg = Configuration.new(self, config_name, clean)
        cfg:_resolve_inherits()
        self._configurations[#self._configurations + 1] = cfg
    end

    if not self.type_config then self.type_config = {} end

    local ok, err = ws:_save_config()
    if not ok then
        -- Rollback
        if existing and old_cfg_snapshot then
            existing:_update(old_cfg_snapshot)
            existing:_resolve_inherits()
        else
            -- Remove the newly added Configuration
            for i, cfg in ipairs(self._configurations) do
                if cfg.name == config_name then
                    table.remove(self._configurations, i)
                    break
                end
            end
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

    -- Find the user-defined Configuration object
    local cfg = self:get_configuration(config_name)
    if not cfg or not cfg.is_user then
        return false, "configuration '" .. config_name .. "' not found"
    end

    -- Remove from array
    local removed_idx = nil
    for i, c in ipairs(self._configurations) do
        if c == cfg then
            removed_idx = i
            table.remove(self._configurations, i)
            break
        end
    end

    local ok, err = ws:_save_config()
    if not ok then
        -- Rollback: re-insert at original position
        if removed_idx then
            table.insert(self._configurations, removed_idx, cfg)
        end
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Rename a project configuration atomically: updates Configuration objects,
--- inherits references, config set mappings, cache entries, and profiles.
--- Build dirs are preserved as-is.
--- @param old_name string current configuration name
--- @param new_name string desired new name
--- @param config_data table { variant?, inherits?, options?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function Project:rename_configuration(old_name, new_name, config_data)
    local ws = self._workspace

    -- Find the Configuration object being renamed
    local target_cfg = self:get_configuration(old_name)
    if not target_cfg or not target_cfg.is_user then
        return false, "configuration '" .. old_name .. "' not found"
    end

    -- Validate new name
    local validate_path_name = require("loomworks.workspace").validate_path_name
    local existing_names = {}
    for _, cfg in ipairs(self._configurations) do
        if cfg.is_user and cfg.name ~= old_name then
            existing_names[#existing_names + 1] = cfg.name
        end
    end
    local valid, verr = validate_path_name(new_name, existing_names)
    if not valid then
        return false, "invalid configuration name: " .. verr
    end

    -- Snapshot for rollback
    local old_cfg_snapshot = {
        name = target_cfg.name,
        is_user = target_cfg.is_user,
        is_default = target_cfg.is_default,
        from_preset = target_cfg.from_preset,
        role = target_cfg.role,
        options = target_cfg.options,
        inherits_names = vim.deepcopy(target_cfg.inherits_names),
        module_config = vim.deepcopy(target_cfg.module_config),
    }
    local old_sibling_inherits = {} -- cfg -> old inherits_names snapshot
    for _, cfg in ipairs(self._configurations) do
        if cfg ~= target_cfg and cfg.inherits_names then
            for _, base_name in ipairs(cfg.inherits_names) do
                if base_name == old_name then
                    old_sibling_inherits[cfg] = vim.deepcopy(cfg.inherits_names)
                    break
                end
            end
        end
    end
    local old_cs_configs = {} -- cs -> true (for rollback of name)
    for _, cs in pairs(ws._config_sets) do
        local cfg = cs.mappings[self]
        if cfg and cfg.name == old_name then
            old_cs_configs[cs] = true
        end
    end

    -- Step 1: Update inherits_names in sibling Configuration objects
    for _, cfg in ipairs(self._configurations) do
        if cfg ~= target_cfg and cfg.inherits_names then
            for i, base_name in ipairs(cfg.inherits_names) do
                if base_name == old_name then
                    cfg.inherits_names[i] = new_name
                end
            end
        end
    end

    -- Step 2: Rename the Configuration object and update its data
    target_cfg.name = new_name
    local update_data = { is_user = true }
    if config_data.variant then update_data.variant = config_data.variant end
    if config_data.inherits then update_data.inherits = config_data.inherits end
    if config_data.options and next(config_data.options) then
        update_data.options = config_data.options
    end
    if config_data.toolchain then update_data.toolchain = config_data.toolchain end
    if config_data.generator then update_data.generator = config_data.generator end
    target_cfg:_update(update_data)
    target_cfg:_resolve_inherits()

    -- Step 3: CS mappings already hold a ref to target_cfg — the name mutation
    -- above makes raw_mappings() serialize new_name automatically.

    -- Save config to disk
    local ok, err = ws:_save_config()
    if not ok then
        -- Rollback: restore name, data, and sibling inherits
        target_cfg.name = old_cfg_snapshot.name
        target_cfg:_update(old_cfg_snapshot)
        target_cfg:_resolve_inherits()
        for cfg, old_inh in pairs(old_sibling_inherits) do
            cfg.inherits_names = old_inh
        end
        return false, err
    end

    -- Step 4: Migrate cache entries (ConfigUnit objects + cache)
    local cache_rename_map = {} -- old_id -> new_id
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
        -- Compute new build_dir-based identity
        local tool_data = unit._tool_data
        local new_rel_key = ws:_compute_build_dir(self, new_name, tool_data)
        -- Update first-class fields
        unit._variant = new_name
        unit._config_key = new_config_key
        -- Update ConfigUnit identity
        local old_id = unit.id
        unit.id = new_rel_key
        -- Update build_dir_value to reflect the new path
        local cache_lu = require("loomworks.cache")
        unit.build_dir_value = cache_lu.absolute_build_dir(new_rel_key, ws.root)
        cache_rename_map[old_id] = new_rel_key
        -- Update Project.cached_configurations dict to match ConfigUnit renames
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
            -- Rekey pinned profiles: check if the profile key contains the old variant name.
            -- Pinned profile keys have format "project/variant:tool" which differs from
            -- build_dir keys. Compute new key by substituting the variant in the key.
            if not profile._configuration_set_name and profile.mappings
                    and profile.mappings[self.key] == new_name then
                -- This is a pinned profile that was just updated to use new_name
                -- Check if its key contains the old variant name and substitute
                local old_key = profile.key
                local escaped_old = old_name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
                local new_key = old_key:gsub(escaped_old, new_name, 1)
                if new_key ~= old_key then
                    profile_rekeys[old_key] = new_key
                end
            end
        end
        -- Apply profile rekeys
        for old_pk, new_pk in pairs(profile_rekeys) do
            for _, profile in pairs(ws._profiles) do
                if profile.key == old_pk then
                    profile.key = new_pk
                    break
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
