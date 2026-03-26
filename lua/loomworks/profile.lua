--- loomworks/profile.lua — Profile and ProfileProject objects.
--- Profile represents a configuration_set × kit combination.
--- ProfileProject represents a single project within a profile.

local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")

-- ========================== ProfileProject ==========================

--- @class loomworks.ProfileProject
--- @field _configuration loomworks.Configuration|nil resolved Configuration domain object
--- @field _workspace loomworks.Workspace
--- @field _profile loomworks.Profile direct reference to parent profile
--- @field _project loomworks.Project|nil direct reference to project object
--- @field _removed boolean
local ProfileProject = {}
ProfileProject.__index = ProfileProject

--- Create a ProfileProject.
--- @param workspace loomworks.Workspace
--- @param profile loomworks.Profile parent Profile
--- @param project_key string used for initial project resolution
--- @param variant string configuration variant name
--- @return loomworks.ProfileProject
function ProfileProject.new(workspace, profile, project_key, variant)
    local self = setmetatable({}, ProfileProject)
    self._workspace = workspace
    self._init_project_key = project_key
    self._removed = false
    self:_update(profile, variant)
    return self
end

--- Update in place (preserves table identity).
--- Resolves direct references to Profile and Project from Workspace registries.
--- @param profile loomworks.Profile
--- @param variant string
function ProfileProject:_update(profile, variant)
    self._profile = profile
    local project_key = self._init_project_key
    self._project = self._workspace._projects[project_key]
    self._configuration = nil
    if self._project and self._project._configurations then
        self._configuration = self._project._configurations[variant]
    end
    self._cached = nil
    self._config_unit = nil

    -- Resolve cached entry and ConfigUnit from the profile's cached configurations array.
    -- The cache entry is the authoritative source; ck is the ConfigUnit's id.
    local cache = self._workspace.cache
    if profile._cached_configurations and cache and cache.configurations then
        for _, ck in ipairs(profile._cached_configurations) do
            local entry = cache.configurations[ck]
            if entry and entry.project_key == project_key
                    and entry.variant == variant then
                self._cached = entry
                self._config_unit = self._workspace._config_units[ck]
                break
            end
        end
    end
end

function ProfileProject:__tostring()
    local pkey = self._project and self._project.key or self._init_project_key or "?"
    return "ProfileProject(" .. pkey .. " @ " .. self._profile.key .. ")"
end

--- Get the resolved status for this project-in-profile.
--- Delegates to ConfigUnit (direct reference resolved during _update).
--- @return loomworks.ConfigUnitState status
function ProfileProject:status()
    if not self._config_unit then return "unconfigured" end
    return self._config_unit:state()
end

--- Get the running action for this project-in-profile.
--- Delegates to ConfigUnit — running state is shared across all profiles
--- that reference the same (project_key, config_key) pair.
--- @return string|nil action
function ProfileProject:running_action()
    if not self._config_unit then return nil end
    return self._config_unit:running_action()
end

--- Check if this project-in-profile is being deleted.
--- @return boolean
function ProfileProject:is_deleting()
    if not self._config_unit then return false end
    return self._config_unit:is_deleting()
end

--- Get the live Configuration domain object for this project-in-profile.
--- Returns nil if the Configuration was removed (stale reference).
--- @return loomworks.Configuration|nil
function ProfileProject:configuration()
    if self._configuration and not self._configuration._removed then
        return self._configuration
    end
    return nil
end

--- Get the variant name string for this project-in-profile.
--- Returns the Configuration name if resolved, otherwise falls back to the
--- raw variant string from the profile's mappings.
--- @return string|nil
function ProfileProject:variant_name()
    if self._configuration and not self._configuration._removed then
        return self._configuration.name
    end
    -- Fallback: read from profile mappings
    return self._profile and self._profile.mappings
        and self._profile.mappings[self._init_project_key] or nil
end

--- Check if this PP's variant mapping references a non-existent Configuration.
--- True when the profile maps a variant but no matching Configuration exists
--- in the project (e.g., the configuration was deleted from loomworks.json).
--- @return boolean
function ProfileProject:is_configuration_missing()
    if self._configuration and not self._configuration._removed then return false end
    return self._profile ~= nil and self._profile.mappings ~= nil
        and self._profile.mappings[self._init_project_key] ~= nil
end

--- Get the Tool domain object for this project-in-profile.
--- Resolves from the parent profile's tool objects.
--- @return loomworks.Tool|nil
function ProfileProject:tool_object()
    if not self._project or not self._profile then return nil end
    return self._profile:tool_object_for(self._project.type)
end

--- Get cached state (direct reference resolved during _update).
--- @return loomworks.CachedConfig|nil
function ProfileProject:cached_state()
    return self._cached
end

--- Get the build directory from cache.
--- @return string|nil
function ProfileProject:build_dir()
    local cached = self:cached_state()
    return cached and cached.build_dir
end

-- ========================== Profile ==========================

--- @class loomworks.Profile
--- @field key string profile key
--- @field _tool_objects? table<string, loomworks.Tool> direct Tool references keyed by module type
--- @field explicit boolean
--- @field explicit_def? table raw definition from loomworks.json (for serialization)
--- @field mappings? table<string, string> project_key -> variant name
--- @field orphaned_set boolean true if configuration_set no longer exists in config
--- @field _workspace loomworks.Workspace
--- @field _removed boolean
--- @field _projects_list loomworks.ProfileProject[] sorted by dependency order
--- @field _projects_by_key table<string, loomworks.ProfileProject> project_key -> PP
--- @field _config_set_ref? loomworks.ConfigurationSet direct reference, resolved during _update
--- @field _valid_variants table<string, boolean> precomputed variant set
--- @field _operations loomworks.Operation[] active operations on this profile
--- @field _last_operation? { message: string, success: boolean } last completed operation result
local Profile = {}
Profile.__index = Profile

-- Status highlight groups (semantic severity levels)
local STATUS_HL = {
    unconfigured     = "Comment",
    configured       = "DiagnosticInfo",
    built            = "DiagnosticOk",
    failed_configure = "DiagnosticError",
    failed_build     = "DiagnosticError",
    configuring      = "DiagnosticWarn",
    building         = "DiagnosticWarn",
    deleting         = "DiagnosticError",
}

--- Create a new Profile object.
--- @param workspace loomworks.Workspace
--- @param key string profile key
--- @param data? { configuration_set?: string, tools?: table<string, { key: string, data: table, label: string }>, explicit?: boolean, mappings?: table<string, string>, orphaned_set?: boolean }
--- @return loomworks.Profile
function Profile.new(workspace, key, data)
    local self = setmetatable({}, Profile)
    self._workspace = workspace
    self.key = key
    self._removed = false
    if data then self:_update(data) end
    return self
end

--- Update all data fields in place (preserves table identity).
--- Resolves mappings and ConfigurationSet reference from Workspace's registries.
--- @param data loomworks.ProfileDef
function Profile:_update(data)
    self._configuration_set_name = data.configuration_set
    self._tools_raw = data.tools or nil
    self._cached_configurations = data._cached_configurations
    self.explicit = data.explicit or false
    self.explicit_def = data.explicit_def or nil

    -- Resolve Tool domain objects from workspace registry
    self._tool_objects = nil
    if self._tools_raw and self._workspace.find_tool then
        local tool_objs = {}
        for mod_type, tool_ref in pairs(self._tools_raw) do
            local tool = self._workspace:find_tool(mod_type, tool_ref.key)
            if tool then
                tool_objs[mod_type] = tool
            end
        end
        if next(tool_objs) then
            self._tool_objects = tool_objs
        end
    end

    -- Resolve mappings and ConfigurationSet reference
    self._config_set_ref = nil
    self.mappings, self.orphaned_set = self:_resolve_mappings(data)

    -- Precompute valid variants for is_configured checks
    self._valid_variants = {}
    if self.mappings then
        for _, variant in pairs(self.mappings) do
            self._valid_variants[variant] = true
        end
    end
end

--- Resolve mappings for this profile from Workspace's registries.
--- Three tiers: (1) reactive from ConfigurationSet, (2) stored mappings,
--- (3) fallback from cached profile project data.
--- @param data loomworks.ProfileDef
--- @return table<string, string>|nil mappings
--- @return boolean orphaned
function Profile:_resolve_mappings(data)
    -- Tier 1: Set-based profiles — derive from live ConfigurationSet (reactive)
    if data.configuration_set then
        local cs = self._workspace._config_sets[data.configuration_set]
        if cs then
            self._config_set_ref = cs
            local mappings = {}
            for project, variant in pairs(cs.mappings) do
                mappings[project.key] = variant
            end
            return mappings, false
        end
    end

    -- Tier 2: Pinned profiles or set-based with stored mappings
    if data.mappings then
        local orphaned = data.configuration_set ~= nil
        return data.mappings, orphaned
    end

    -- Tier 3: Fallback from cached profile configuration keys
    if data._cached_configurations and data._ws_cache then
        local mappings = {}
        for _, ck in ipairs(data._cached_configurations) do
            local cached_config = data._ws_cache.configurations
                    and data._ws_cache.configurations[ck]
            if cached_config and cached_config.variant then
                mappings[cached_config.project_key] = cached_config.variant
            end
        end
        if next(mappings) then return mappings, data.configuration_set ~= nil end
    end

    return nil, false
end

function Profile:__tostring()
    return "Profile(" .. self.key .. ")"
end

function Profile:__eq(other)
    return self.key == other.key
end

--- Get the ConfigurationSet object for this profile.
--- @return loomworks.ConfigurationSet|nil
function Profile:config_set()
    return self._config_set_ref
end

--- Get the ToolRef for a specific module type from this profile's tools.
--- @param mod_type string module type (e.g. "cmake")
--- @return loomworks.ToolRef|nil
function Profile:tool_for(mod_type)
    return self._tools_raw and self._tools_raw[mod_type] or nil
end

--- Get the Tool domain object for a specific module type.
--- @param mod_type string module type (e.g. "cmake")
--- @return loomworks.Tool|nil
function Profile:tool_object_for(mod_type)
    return self._tool_objects and self._tool_objects[mod_type] or nil
end

--- Compute the cache key for a variant, accounting for tool.
--- When project_type is provided, looks up the tool for that module type.
--- @param variant string
--- @param project_type? string module type of the project
--- @return string
function Profile:config_key(variant, project_type)
    if self._tools_raw and project_type then
        local tool = self._tools_raw[project_type]
        if tool and tool.key then
            return variant .. ":" .. tool.key
        end
    end
    return variant
end

-- ---------------------------------------------------------------------------
-- Child access
-- ---------------------------------------------------------------------------

--- Get a ProfileProject for a specific project in this profile.
--- Uses direct reference populated during sync.
--- @param project_key string
--- @return loomworks.ProfileProject|nil
function Profile:project(project_key)
    return self._projects_by_key and self._projects_by_key[project_key] or nil
end

--- Get all ProfileProjects in this profile, sorted by dependency order.
--- Uses direct list populated during sync.
--- @return loomworks.ProfileProject[]
function Profile:projects()
    return self._projects_list or {}
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Activate this profile.
--- Writes to user.json and remerges directly.
function Profile:activate()
    self._workspace.user.active_profile = self.key
    self._workspace:_save_user()
    self._workspace:remerge()
end

--- Deactivate this profile if it is currently active.
function Profile:deactivate()
    if self._workspace.user.active_profile == self.key then
        self._workspace.user.active_profile = nil
        self._workspace:_save_user()
        self._workspace:remerge()
    end
end

--- Build all projects in this profile via overseer.
function Profile:build()
    require("loomworks.overseer").run_profile_action(self, "build")
end

--- Configure all projects in this profile via overseer.
function Profile:configure()
    require("loomworks.overseer").run_profile_action(self, "configure")
end

-- ---------------------------------------------------------------------------
-- Default target
-- ---------------------------------------------------------------------------

--- Get the default LaunchTarget for this profile.
--- Resolves from user.json, falls back to loomworks.json profile definition.
--- @return loomworks.LaunchTarget|nil
function Profile:default_target()
    -- Check user.json first
    local descriptor = self._workspace.user.default_target
        and self._workspace.user.default_target[self.key]
    -- Fall back to loomworks.json profile definition
    if not descriptor and self._workspace.config.profiles then
        local profile_def = self._workspace.config.profiles[self.key]
        if profile_def then
            descriptor = profile_def.default_target
        end
    end
    if not descriptor or not descriptor.project then
        return nil
    end
    -- Need either a target (module target) or a launch config name
    if not descriptor.target and not descriptor.launch then
        return nil
    end

    local LaunchTarget = require("loomworks.launch_target")
    return LaunchTarget.new(self._workspace, self, descriptor)
end

--- Set the default target for this profile.
--- @param project loomworks.Project
--- @param target_id? string opaque target identifier (module targets)
--- @param launch_name? string launch config name (command launches)
function Profile:set_default_target(project, target_id, launch_name)
    self._workspace.user.default_target = self._workspace.user.default_target or {}
    local descriptor = { project = project.key }
    if target_id then descriptor.target = target_id end
    if launch_name then descriptor.launch = launch_name end
    self._workspace.user.default_target[self.key] = descriptor
    self._workspace:_save_user()
end

--- Clear the default target for this profile.
function Profile:clear_default_target()
    if self._workspace.user.default_target then
        self._workspace.user.default_target[self.key] = nil
        self._workspace:_save_user()
    end
end

-- ---------------------------------------------------------------------------
-- Operations (profile-level action tracking)
-- ---------------------------------------------------------------------------

--- Register an Operation on this profile.
--- @param operation loomworks.Operation
function Profile:add_operation(operation)
    self._operations = self._operations or {}
    self._operations[#self._operations + 1] = operation
end

--- Called when an Operation completes — stores the result and removes it
--- from the active list.
--- @param operation loomworks.Operation
function Profile:complete_operation(operation)
    self._last_operation = {
        message = operation.message,
        success = operation.success,
    }
    -- Remove from active list
    if self._operations then
        for i, op in ipairs(self._operations) do
            if op == operation then
                table.remove(self._operations, i)
                break
            end
        end
    end
end

--- Get active operations on this profile.
--- @return loomworks.Operation[]
function Profile:active_operations()
    return self._operations or {}
end

--- Check if this profile has any active operations.
--- @return boolean
function Profile:has_active_operation()
    return self._operations ~= nil and #self._operations > 0
end

--- Get the last completed operation result.
--- @return { message: string, success: boolean }|nil
function Profile:operation()
    return self._last_operation
end

--- Get elapsed seconds for the first active operation.
--- @return number|nil seconds
function Profile:operation_elapsed()
    if not self._operations or #self._operations == 0 then return nil end
    return self._operations[1]:elapsed()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Check if this profile has any configured entries in cache.
--- @return boolean
function Profile:is_configured()
    if not self._workspace.cache then return false end

    -- Look up profile in cache by key
    local cached_profile = self._workspace.cache.profiles and self._workspace.cache.profiles[self.key]
    if not cached_profile or not cached_profile.configurations then
        -- Fallback: value matching for set-based profiles
        if self._configuration_set_name then
            cached_profile = merge.find_cached_profile(
                self._workspace.cache, self._configuration_set_name, self._tools_raw)
        end
        if not cached_profile or not cached_profile.configurations then return false end
    end

    -- Check if any referenced configuration has actual build state
    for _, ck in ipairs(cached_profile.configurations) do
        local cached_config = self._workspace.cache.configurations and self._workspace.cache.configurations[ck]
        if cached_config and cached_config.state
                and cached_config.state ~= "unconfigured" then
            return true
        end
    end
    return false
end

--- Check if this profile has any running tasks.
--- @return boolean
function Profile:is_running()
    if not self.mappings then return false end
    for _, pp in ipairs(self:projects()) do
        if pp:running_action() then return true end
    end
    return false
end

--- Compute aggregate status label and highlight group for UI display.
--- @return string label, string hl_group vim highlight group name
function Profile:status()
    local pps = self:projects()
    if #pps == 0 then return "empty", "Comment" end

    local total = #pps
    local counts = {
        unconfigured = 0,
        configured = 0,
        built = 0,
        configure_failed = 0,
        build_failed = 0,
        configuring = 0,
        building = 0,
        deleting = 0,
    }

    for _, pp in ipairs(pps) do
        local s = pp:status()
        counts[s] = (counts[s] or 0) + 1
    end

    if counts.deleting > 0 then
        -- Check if all deleting units are "cleaning" vs "deleting"
        local all_cleaning = true
        for _, pp in ipairs(pps) do
            if pp:status() == "deleting" then
                local unit = pp._config_unit
                if unit:deleting_reason() ~= "cleaning" then
                    all_cleaning = false
                    break
                end
            end
        end
        local label = all_cleaning and "cleaning" or "deleting"
        return counts.deleting .. "/" .. total .. " " .. label, STATUS_HL.deleting
    end

    local running = counts.configuring + counts.building
    local failed = counts.configure_failed + counts.build_failed

    if running > 0 then
        local parts = {}
        if counts.configuring > 0 then parts[#parts + 1] = counts.configuring .. " configuring" end
        if counts.building > 0 then parts[#parts + 1] = counts.building .. " building" end
        if failed > 0 then parts[#parts + 1] = failed .. " failed" end
        return table.concat(parts, ", "), STATUS_HL.configuring
    end

    if counts.built == total then return "built", STATUS_HL.built end
    if counts.configured == total then return "configured", STATUS_HL.configured end
    if counts.unconfigured == total then return "unconfigured", STATUS_HL.unconfigured end

    if failed > 0 then
        local parts = {}
        if counts.configure_failed > 0 then
            parts[#parts + 1] = counts.configure_failed .. " failed configure"
        end
        if counts.build_failed > 0 then
            parts[#parts + 1] = counts.build_failed .. " failed build"
        end
        local ok_count = counts.built + counts.configured
        if ok_count > 0 then
            parts[#parts + 1] = ok_count .. "/" .. total .. " ok"
        end
        return table.concat(parts, ", "), STATUS_HL.failed_configure
    end

    local parts = {}
    if counts.built > 0 then parts[#parts + 1] = counts.built .. " built" end
    if counts.configured > 0 then parts[#parts + 1] = counts.configured .. " configured" end
    if counts.unconfigured > 0 then parts[#parts + 1] = counts.unconfigured .. " unconfigured" end
    return table.concat(parts, ", "), STATUS_HL.configured
end

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

--- Plan a deletion of this profile's cached configs.
--- Returns a plan object with items, shared analysis, and metadata.
--- @return loomworks.DeletionPlan
function Profile:plan_deletion()
    local empty = { items = {}, profile_key = self.key, defined_in_config = false }
    if not self.mappings then return empty end

    -- Build lookup: which configs are referenced by OTHER profiles.
    -- Nested set: [project_key][config_key] = true
    local other_refs = {}
    for _, other in pairs(self._workspace._profiles) do
        if other.key ~= self.key then
            for _, other_pp in ipairs(other:projects()) do
                if other_pp._config_unit then
                    if not other_refs[other_pp._config_unit] then
                        other_refs[other_pp._config_unit] = true
                    end
                end
            end
        end
    end

    -- Include ALL project/config combos with disposition
    local items = {}
    for _, pp in ipairs(self:projects()) do
        local pp_cached = pp._cached
        local has_other_ref = pp._config_unit and other_refs[pp._config_unit] or false
        items[#items + 1] = {
            project_key = pp._project and pp._project.key or (pp_cached and pp_cached.project_key),
            config_key = pp_cached and pp_cached.config_key,
            build_dir = pp:build_dir(),
            disposition = has_other_ref and "keep" or "clean",
            unit = pp._config_unit,
        }
    end

    table.sort(items, function(a, b) return (a.project_key or "") < (b.project_key or "") end)

    local defined_in_config = self._workspace.config.profiles and self._workspace.config.profiles[self.key] or false

    return {
        items = items,
        profile_key = self.key,
        defined_in_config = defined_in_config and true or false,
    }
end

--- Delete this profile (plan + execute, no UI confirmation).
--- Creates a delete Operation to track progress.
--- @param on_done? function
function Profile:delete(on_done)
    local plan = self:plan_deletion()

    -- Collect units for the Operation
    local units = {}
    local target_states = {}
    for _, item in ipairs(plan.items) do
        if item.disposition ~= "keep" and item.unit then
            units[#units + 1] = item.unit
            target_states[item.unit] = "unconfigured"
        end
    end
    if #units > 0 then
        self._workspace:create_operation(self, "delete", units, target_states)
    end

    self._workspace:execute_deletion(plan, { deactivate_profile = self }, on_done)
end

--- Clean this profile's configs: run module clean tasks and reset build state.
--- Does NOT remove the profile itself or its build directories.
--- Creates a clean Operation to track progress.
--- @param on_done? function
function Profile:clean(on_done)
    local pps = self:projects()
    if #pps == 0 then
        if on_done then on_done() end
        return
    end

    local items = {}
    local units = {}
    local target_states = {}
    for _, pp in ipairs(pps) do
        local pp_cached = pp._cached
        items[#items + 1] = {
            project_key = pp._project and pp._project.key or (pp_cached and pp_cached.project_key),
            config_key = pp_cached and pp_cached.config_key,
            unit = pp._config_unit,
        }
        units[#units + 1] = pp._config_unit
        target_states[pp._config_unit] = "configured"
    end

    -- Cancel conflicting build/configure operations
    self._workspace:cancel_conflicting_operations(units)

    -- Mark units as cleaning and create Operation synchronously so that
    -- has_pending_deletions() returns true immediately (before async work).
    for _, unit in ipairs(units) do
        unit:mark_deleting(true, "cleaning")
    end
    self._workspace:create_operation(self, "clean", units, target_states)

    -- Crash-safe: set cache to "configured" before async clean tasks.
    -- If we crash mid-clean, the state is still valid (needs rebuild, not broken).
    self._workspace:mark_cached_configs_cleaned(items)

    -- Stop running tasks, then run module clean tasks
    local running = self._workspace:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    self._workspace:stop_tasks_then(task_ids, function()
        require("loomworks.overseer").run_profile_clean(self, function()
            for _, unit in ipairs(units) do
                unit:mark_deleting(false)
            end

            if on_done then on_done() end
        end)
    end)
end

--- Rebuild: clean then build.
function Profile:rebuild()
    self:clean(function()
        self:build()
    end)
end

return { Profile = Profile, ProfileProject = ProfileProject }
