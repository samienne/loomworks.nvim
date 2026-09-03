--- loomworks/project.lua — Project object wrapping merged project data.
--- Provides query methods for running/deleting/cached state.

local Configuration = require("loomworks.configuration")

--- @class loomworks.Project
--- @field key string project key
--- @field type string module type ("cmake", "typescript")
--- @field path? string relative path from workspace root
--- @field type_config? table module-specific configuration (options, configurations, etc.)
--- @field launch? table<string, table> launch configurations
--- @field deploy? table<string, table|table[]> project-level deploy steps
--- @field variables? table<string, { type: string, default: string }> user-defined variable declarations
--- @field configuration? string active configuration name
--- @field _module? loomworks.Module direct reference to Module domain object
--- @field _tool? loomworks.Tool direct reference to Tool domain object
--- @field status loomworks.Status
--- @field orphaned boolean
--- @field needs_refresh boolean
--- @field refresh_reasons string[]
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field preset_configurations? table<string, loomworks.ConfigurationInfo>
--- @field cached? loomworks.CachedConfig active configuration's cached state
--- @field cached_configurations table<string, loomworks.CachedConfig>
--- @field module_info? table opaque module-specific project-level info
--- @field depends_on? loomworks.Project[] direct references to dependency projects
--- @field _depends_on_keys? string[] raw keys from merge (resolved to objects in _update)
--- @field _configurations? loomworks.Configuration[] Configuration domain objects array
--- @field _workspace loomworks.Workspace
--- @field _removed boolean
--- @field _source "user"|"shared" provenance: "user" = from user.json, "shared" = from loomworks.json
--- @field _intent? "local"|"shared"|"local+shared" intended publish state; nil before data_model.refresh's first sync
--- @field _removed_upstream? boolean transient session flag — was in old baseline but not in new (cleared on publish, restart, or item removal)
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
    -- _intent is intentionally nil here. data_model.refresh assigns the
    -- default from file presence on first sync, then preserves it across
    -- subsequent remerges (intent stickiness). Mutation methods that create a
    -- project outside refresh (e.g., workspace.add_project) set _intent
    -- explicitly before saving.
    self._intent = nil
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
    self.deploy = data.deploy
    self.variables = data.variables or nil
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
    self.module_info = data.module_info
    -- Store raw keys for deferred resolution (projects may not all exist yet)
    self._depends_on_keys = data.depends_on
    -- Read pre-resolved dependency Project objects (set by _sync_projects)
    self.depends_on = data._depends_on
    -- Sync Configuration domain objects from configurations dict
    self:_sync_configurations()
end

--- Mark this project as in the user.json working copy.
--- Called when any mutation is about to write to user.json.
function Project:_mark_user_owned()
    if self._intent == "shared" then
        self._intent = "local+shared"
    end
    if self._source == "shared" then
        self._source = "user"
    end
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

    -- Build name→existing lookup from current array for identity matching
    local existing_by_name = {}
    for _, cfg in ipairs(self._configurations) do
        existing_by_name[cfg.name] = cfg
    end

    -- Mark removed (absent from config sources). User-declared configs are a
    -- source in their own right, not module output, so absence from the
    -- module's emitted set says nothing about them: a freshly saved one (and
    -- any abstract mixin, which no module ever emits) would otherwise be
    -- dropped from the model the moment it was created, and only reappear
    -- after a reload re-read it from user.json.
    for _, cfg in ipairs(self._configurations) do
        if not all_config_data[cfg.name] and not cfg.is_user then
            cfg._removed = true
        end
    end

    -- Build new array: for each source config, find existing or create new
    local new_arr = {}
    for name, info in pairs(all_config_data) do
        local existing = existing_by_name[name]
        if existing and not existing._removed then
            existing:_update(info)
            new_arr[#new_arr + 1] = existing
        else
            new_arr[#new_arr + 1] = Configuration.new(self, name, info)
        end
    end

    -- Carry over user-declared configs the module doesn't emit (see above).
    -- Ones the module *does* emit were matched by name in the loop above.
    for _, cfg in ipairs(self._configurations) do
        if cfg.is_user and not all_config_data[cfg.name] and not cfg._removed then
            new_arr[#new_arr + 1] = cfg
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
--- When no live Configuration exists, creates a source-missing
--- stub — flagged with `_source_missing = true` so the UI can
--- render it in the orphan colour and offer rename/rebase.
--- Sync paths (sync_config_sets, inherits resolution) rely on
--- this to keep references intact until the user fixes them.
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
    -- Only genuine user configs go into the user_overrides slot.
    --
    -- Skipping auto-gens here is critical: `Configuration.canonicalize`
    -- (called inside `mod.info`) re-tags every entry it sees in
    -- user_overrides as `is_user = true`. If we passed live auto-gens
    -- in here, they'd flip on the next refresh from is_default to
    -- is_user — which is what put `variant:Debug` etc. into the
    -- "looks like a user config" state and silently disabled the
    -- diagnostic gate.
    --
    -- Source-missing stubs are also skipped: they're identity-stable
    -- references kept on the project to keep the data graph sound,
    -- but they don't represent declared configuration data — feeding
    -- them through `serialize_user_override` would materialise them
    -- as user overrides on the next round.
    for _, cfg in ipairs(self._configurations) do
        if not cfg:is_auto_gen() and not cfg._source_missing then
            local override = cfg:serialize_user_override()
            if override then
                configs[cfg.name] = override
            end
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
    self:_mark_user_owned()

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

    -- The profile's tool owns the compiler — a configuration may not select
    -- one through its own options/env (spec §15). Reject reserved keys here
    -- so they never reach the working copy; the strip-at-build path is only a
    -- defence for hand-edited files. The CMAKE_<LANG>_COMPILER option rule is
    -- cmake-only in practice (other modules carry no cmake cache vars) but the
    -- check is generic; the env driver-var rule is shared across modules.
    local reserved = require("loomworks.reserved_compiler")
    if type(config_data.options) == "table" then
        for k in pairs(config_data.options) do
            if reserved.is_reserved_option(k) then
                return false, k .. " cannot be set here — the compiler is "
                    .. "chosen by the profile's tool. Select a tool instead."
            end
        end
    end
    if type(config_data.env) == "table" then
        for k in pairs(config_data.env) do
            if reserved.is_reserved_env(k) then
                return false, k .. " cannot be set here — the compiler is "
                    .. "chosen by the profile's tool. Select a tool instead."
            end
        end
    end

    -- Compiler-family variable `overrides` (core §1.3.1): every overridden
    -- name must be declared in the project `variables`. Reject an undeclared
    -- name at edit time (mirrors the reserved-key rule) so the bad block never
    -- reaches the working copy. Unknown family keys are permitted here and
    -- surface as a workspace diagnostic instead.
    if type(config_data.overrides) == "table" and next(config_data.overrides) then
        local vars_mod = require("loomworks.variables")
        local ok_ov, ov_err = vars_mod.validate_compiler_overrides(
            config_data.overrides, self.variables or {})
        if not ok_ov then
            return false, ov_err
        end
    end

    -- Build the data table for Configuration._update (user override format).
    -- Generic fields get their empty-aware handling; every other key is a
    -- module-specific field (cmake: variant/toolchain/generator; other
    -- modules define their own) and is forwarded generically — no hardcoded
    -- field list, so callers can set any module field the module understands.
    local clean = { is_user = true }
    if config_data.inherits then clean.inherits = config_data.inherits end
    if config_data.options and next(config_data.options) then
        clean.options = config_data.options
    end
    if config_data.variables and next(config_data.variables) then
        clean.variables = config_data.variables
    end
    if config_data.overrides and next(config_data.overrides) then
        clean.overrides = config_data.overrides
    end
    -- Languages: non-nil array = explicit override, nil = inherit
    -- from module. We pass through whatever the caller produced.
    if config_data.languages ~= nil then clean.languages = config_data.languages end
    if config_data.role ~= nil then clean.role = config_data.role end
    local generic_keys = {
        is_user = true, is_default = true, from_preset = true, role = true,
        inherits = true, options = true, variables = true, overrides = true,
        languages = true, prefix = true, base_name = true,
    }
    for k, v in pairs(config_data) do
        if not generic_keys[k] then clean[k] = v end
    end

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
            variables = existing.variables,
            overrides = existing._overrides,
            inherits_names = existing.inherits_names,
            module_config = vim.deepcopy(existing.module_config),
        }
        existing:_update(clean)
        existing:_mark_user_owned()  -- editing a shared cfg materializes it
        existing:_resolve_inherits()
    else
        local cfg = Configuration.new(self, config_name, clean)
        cfg:_mark_user_owned()  -- new local config
        cfg:_resolve_inherits()
        self._configurations[#self._configurations + 1] = cfg
    end

    if not self.type_config then self.type_config = {} end

    local ok, err = ws:_save_user()
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
    self:_mark_user_owned()

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

    local ok, err = ws:_save_user()
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

--- Rename a project configuration: mutates all domain objects in place.
--- Configuration name, Profile mappings, ConfigUnit fields all updated without
--- creating new objects. Old build_dir is preserved as an orphaned cache entry.
--- @param old_name string current configuration name
--- @param new_name string desired new name
--- @param config_data table { variant?, inherits?, options?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function Project:rename_configuration(old_name, new_name, config_data)
    local ws = self._workspace
    self:_mark_user_owned()

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

    -- Step 4: Update the raw configurations dict (used by UI projects section).
    if self.configurations and self.configurations[old_name] then
        self.configurations[new_name] = self.configurations[old_name]
        self.configurations[old_name] = nil
    end

    -- Save config + cache to disk
    local ok, err = ws:_save_user()
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
    -- Update profile mappings: re-derive from ConfigurationSet for set-based,
    -- and update stored mappings for pinned profiles that reference this project.
    -- No rebuild needed — PP._configuration is an object ref that already sees
    -- the new name, and ConfigUnits are updated in place below.
    for _, profile in pairs(ws._profiles) do
        if profile._config_set_ref then
            -- Set-based: re-derive from the live ConfigurationSet
            local mappings = {}
            for project, config in pairs(profile._config_set_ref.mappings) do
                mappings[project.key] = config.name
            end
            profile.mappings = mappings
        elseif profile.mappings and profile.mappings[self.key] == old_name then
            -- Pinned: update the stored variant reference and re-derive key
            profile.mappings[self.key] = new_name
            profile:_derive_key()
        end
    end

    -- Update ConfigUnits in place. Build dir changes on rename (path encodes
    -- variant). Old BuildDir is orphaned; ConfigUnit gets a new build dir.
    -- All other domain objects (Configuration, Profile, PP) keep identity.
    local merge_mod = require("loomworks.merge")
    local BuildDir = require("loomworks.build_dir")
    for _, unit in pairs(ws._config_units) do
        if unit._configuration == target_cfg then
            -- Skip running/deleting units — task is using the old build_dir.
            if unit:is_running() or unit:is_deleting() then
                -- noop: Configuration ref auto-sees new name
            else
                -- Detach old BuildDir (stays in _build_dirs as orphaned)
                unit._build_dir = nil

                -- Update serialization fields
                unit._variant = new_name
                unit._config_key = merge_mod.build_config_key(new_name, unit._tool_key)

                -- Compute new build_dir path from new variant name
                local new_rel, new_abs = ws:_compute_build_dir(self, new_name, unit._tool_data)
                unit.id = new_rel
                unit.build_dir_value = new_abs

                -- Search _build_dirs for existing BuildDir at new path
                -- (rename-back scenario: adopt orphaned BuildDir, restore state)
                local bd = ws:find_build_dir(new_rel)
                if bd and bd:has_state() then
                    unit._build_dir = bd
                    unit.state_value = bd.state
                    unit.last_configured = bd.last_configured
                    unit.last_built = bd.last_built
                    unit.module_info = bd.module_info
                    unit._cached_options = bd.options_snapshot
                    unit._cached_module_config = bd.module_config_snapshot
                else
                    -- Create fresh BuildDir at new path (unconfigured)
                    if not bd then
                        bd = BuildDir.new(new_rel, new_abs)
                        ws._build_dirs[#ws._build_dirs + 1] = bd
                    end
                    unit._build_dir = bd
                    unit.state_value = nil
                    unit.last_configured = nil
                    unit.last_built = nil
                    unit.module_info = nil
                    unit._cached_options = nil
                    unit._cached_module_config = nil
                end
            end
        end
    end

    ws:_save_user()
    ws:_save_cache()
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
    self:_mark_user_owned()

    if not self.type_config then self.type_config = {} end
    local old = self.type_config.options
    self.type_config.options = next(options) and options or nil

    local ok, err = ws:_save_user()
    if not ok then
        self.type_config.options = old
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save an arbitrary type_config field.
--- Generic mutation for module-specific settings (e.g., cmake_env).
--- @param field string field name within type_config
--- @param value any new value (nil or empty table removes the field)
--- @return boolean ok, string|nil err
function Project:save_type_config_field(field, value)
    local ws = self._workspace
    self:_mark_user_owned()

    if not self.type_config then self.type_config = {} end
    local old = self.type_config[field]
    -- Normalize: nil-out empty tables
    if type(value) == "table" and not next(value) then value = nil end
    self.type_config[field] = value

    local ok, err = ws:_save_user()
    if not ok then
        self.type_config[field] = old
        return false, err
    end

    self:_refresh_configurations()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save a project variable declaration (create or update).
--- @param var_name string variable name
--- @param declaration { type: string, default: string }
--- @return boolean ok, string|nil err
function Project:save_variable(var_name, declaration)
    local ws = self._workspace
    self:_mark_user_owned()
    if self._removed then
        return false, "project '" .. self.key .. "' has been removed"
    end

    local vars_mod = require("loomworks.variables")
    if vars_mod.RESERVED_NAMES[var_name] then
        return false, "'" .. var_name .. "' is a reserved variable name"
    end

    local old_variables = self.variables and vim.deepcopy(self.variables) or nil
    if not self.variables then
        self.variables = {}
    end
    self.variables[var_name] = declaration

    local ok, err = ws:_save_user()
    if not ok then
        self.variables = old_variables
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Delete a project variable declaration.
--- Also removes any configuration overrides for this variable.
--- @param var_name string variable name
--- @return boolean ok, string|nil err
function Project:delete_variable(var_name)
    local ws = self._workspace
    self:_mark_user_owned()
    if not self.variables or not self.variables[var_name] then
        return false, "variable '" .. var_name .. "' not found"
    end

    local old_variables = vim.deepcopy(self.variables)
    self.variables[var_name] = nil
    if not next(self.variables) then self.variables = nil end

    -- Remove config overrides for this variable
    local old_config_overrides = {}
    for _, cfg in ipairs(self._configurations) do
        if cfg.variables and cfg.variables[var_name] then
            old_config_overrides[cfg] = cfg.variables[var_name]
            cfg.variables[var_name] = nil
            if not next(cfg.variables) then cfg.variables = nil end
        end
    end

    local ok, err = ws:_save_user()
    if not ok then
        -- Rollback
        self.variables = old_variables
        for cfg, val in pairs(old_config_overrides) do
            if not cfg.variables then cfg.variables = {} end
            cfg.variables[var_name] = val
        end
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save a launch configuration for this project.
--- @param launch_name string
--- @param config table { command, args?, working_dir?, env? }
--- @return boolean ok, string|nil err
function Project:save_launch_config(launch_name, config)
    local ws = self._workspace
    self:_mark_user_owned()
    if self._removed then
        return false, "project '" .. self.key .. "' has been removed"
    end

    if not self.launch then
        self.launch = {}
    end
    self.launch[launch_name] = config

    local ok, err = ws:_save_user()
    if not ok then
        self.launch[launch_name] = nil
        if not next(self.launch) then self.launch = nil end
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Save the project-level deploy dict.
--- Pass nil or an empty dict to clear.
--- @param deploy table<string, table|table[]>|nil
--- @return boolean ok, string|nil err
function Project:save_deploy(deploy)
    local ws = self._workspace
    self:_mark_user_owned()
    if self._removed then
        return false, "project '" .. self.key .. "' has been removed"
    end

    local old = self.deploy
    if deploy == nil or not next(deploy) then
        self.deploy = nil
    else
        self.deploy = deploy
    end

    local ok, err = ws:_save_user()
    if not ok then
        self.deploy = old
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
    self:_mark_user_owned()

    if not self.launch or not self.launch[launch_name] then
        return false, "launch config '" .. launch_name .. "' not found"
    end

    local old = self.launch[launch_name]
    self.launch[launch_name] = nil
    if not next(self.launch) then self.launch = nil end

    local ok, err = ws:_save_user()
    if not ok then
        if not self.launch then self.launch = {} end
        self.launch[launch_name] = old
        return false, err
    end

    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

return Project
