--- loomworks/profile.lua — Profile and ProfileProject objects.
--- Profile represents a configuration_set × kit combination.
--- ProfileProject represents a single project within a profile.

-- ========================== ProfileProject ==========================

--- @class loomworks.ProfileProject
--- @field _workspace loomworks.Workspace
--- @field _init_project_key string project key for identity and fallback
--- @field _profile loomworks.Profile parent profile
--- @field _project loomworks.Project|nil resolved project
--- @field _configuration loomworks.Configuration|nil resolved configuration
--- @field _config_unit loomworks.ConfigUnit|nil resolved config unit
--- @field _removed boolean
local ProfileProject = {}
ProfileProject.__index = ProfileProject

--- Create a ProfileProject.
--- @param workspace loomworks.Workspace
--- @param project_key string used for identity and fallback resolution
--- @param data { profile: loomworks.Profile, project?: loomworks.Project, configuration?: loomworks.Configuration, config_unit?: loomworks.ConfigUnit }
--- @return loomworks.ProfileProject
function ProfileProject.new(workspace, project_key, data)
    local self = setmetatable({}, ProfileProject)
    self._workspace = workspace
    self._init_project_key = project_key
    self._removed = false
    if data then self:_apply(data) end
    return self
end

--- Update in place (preserves table identity).
--- Receives pre-resolved references from _sync_profile_projects.
--- @param data { profile: loomworks.Profile, project?: loomworks.Project, configuration?: loomworks.Configuration, config_unit?: loomworks.ConfigUnit }
function ProfileProject:_apply(data)
    self._profile = data.profile
    self._project = data.project
    self._configuration = data.configuration
    self._config_unit = data.config_unit
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
    if not self._project or not self._project._module or not self._profile then return nil end
    return self._profile:tool_object_for(self._project._module)
end

--- Get the build directory.
--- @return string|nil
function ProfileProject:build_dir()
    if self._config_unit then
        return self._config_unit.build_dir_value
    end
    return nil
end

--- Get the config key for this project-in-profile.
--- @return string|nil
function ProfileProject:config_key()
    if self._config_unit then
        return self._config_unit:config_key()
    end
    return nil
end

--- Get the project key for this project-in-profile.
--- @return string
function ProfileProject:project_key()
    if self._project then return self._project.key end
    return self._init_project_key
end

-- ========================== Profile ==========================

--- @class loomworks.Profile
--- @field key string profile key — derived from data, never set externally
--- @field _workspace loomworks.Workspace
--- @field _removed boolean
--- Data fields (set during _apply):
--- @field _configuration_set_name string|nil set name for set-based profiles
--- @field _tools_raw table|nil raw tools dict from deserialization (authoritative for mutations)
--- @field _sdk loomworks.SDK|nil SDK domain object reference
--- @field _sdk_key string|nil SDK key for serialization
--- @field _default_target_descriptor table|nil user.json default target for this profile
--- Resolved references (set during _apply):
--- @field _tool_objects table<loomworks.Module, loomworks.Tool>|nil
--- @field _config_set_ref loomworks.ConfigurationSet|nil
--- Computed fields:
--- @field mappings table<string, string>|nil project_key -> variant name
--- @field orphaned_set boolean true if configuration_set no longer in config
--- @field _valid_variants table<string, boolean> precomputed variant set
--- Child objects (built during sync/mutation):
--- @field _projects_list loomworks.ProfileProject[] sorted by dependency order
--- @field _projects_by_key table<string, loomworks.ProfileProject> project_key -> PP
--- Runtime state:
--- @field _operations loomworks.Operation[] active operations
--- @field _last_operation { message: string, success: boolean }|nil
--- @field _intent "local"|"shared"|"local+shared" intended publish state
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
--- @param data? { configuration_set?: string, tools?: table<string, { key: string, data: table, label: string }>, explicit?: boolean, mappings?: table<string, string>, orphaned_set?: boolean }
--- @return loomworks.Profile
function Profile.new(workspace, data)
    local self = setmetatable({}, Profile)
    self._workspace = workspace
    self._removed = false
    self._intent = "local"
    if data then self:_apply(data) end
    return self
end

--- Update all data fields in place (preserves table identity).
--- Pre-resolved fields (_tool_objects, _config_set_ref) are set by _sync_profiles.
--- @param data loomworks.ProfileDef
function Profile:_apply(data)
    self._configuration_set_name = data.configuration_set
    self._tools_raw = data.tools or nil
    self._sdk_key = data.sdk or nil
    -- SDK domain object resolved during _sync_profiles or set_sdk()
    if data._sdk then
        self._sdk = data._sdk
        -- Update key to match resolved SDK (migration from old format)
        self._sdk_key = data._sdk.key
    end

    -- Read pre-resolved Tool domain objects (set by _sync_profiles)
    self._tool_objects = data._tool_objects

    -- Read pre-resolved ConfigurationSet reference (set by _sync_profiles)
    self._config_set_ref = data._config_set_ref

    -- Resolve mappings from the pre-resolved ConfigurationSet or fallbacks
    self.mappings, self.orphaned_set = self:_resolve_mappings(data)

    -- Precompute valid variants for is_configured checks
    self._valid_variants = {}
    if self.mappings then
        for _, variant in pairs(self.mappings) do
            self._valid_variants[variant] = true
        end
    end

    -- Derive key from profile data (must be last — depends on fields set above)
    self:_derive_key()
end

--- Compute and set self.key from the profile's data fields.
--- Format: config_set:tool_keys (sorted, joined with +)
--- SDK key is included alongside module override keys.
function Profile:_derive_key()
    if not self._configuration_set_name then
        self.key = "unnamed"
        return
    end

    local parts = {}

    -- SDK key
    if self._sdk_key then
        parts[#parts + 1] = self._sdk_key
    end

    -- Module-specific tool override keys (not SDK-derived)
    if self._tools_raw then
        for _, tool_ref in pairs(self._tools_raw) do
            if tool_ref.key then
                parts[#parts + 1] = tool_ref.key
            end
        end
    elseif self._tool_objects then
        for _, tool in pairs(self._tool_objects) do
            if tool.key then
                parts[#parts + 1] = tool.key
            end
        end
    end

    table.sort(parts)
    if #parts > 0 then
        self.key = self._configuration_set_name .. ":" .. table.concat(parts, "+")
    else
        self.key = self._configuration_set_name
    end

    -- Debug: log derived key
    if self._workspace and self._workspace._core then
        self._workspace._core._deps.log:debug("Profile key derived: '%s' (sdk_key=%s, tools_raw=%s)",
            self.key, tostring(self._sdk_key),
            self._tools_raw and vim.inspect(vim.tbl_keys(self._tools_raw)) or "nil")
    end
end

--- Resolve mappings for this profile from pre-resolved references.
--- Two tiers: (1) reactive from ConfigurationSet, (2) stored mappings (pinned profiles).
--- @param data loomworks.ProfileDef
--- @return table<string, string>|nil mappings
--- @return boolean orphaned
function Profile:_resolve_mappings(data)
    -- Derive from live ConfigurationSet (reactive)
    if data.configuration_set then
        local cs = self._config_set_ref
        if cs then
            local mappings = {}
            for project, config in pairs(cs.mappings) do
                mappings[project.key] = config.name
            end
            return mappings, false
        end
        -- Config set referenced but not found → orphaned
        return nil, true
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

--- Get the SDK for this profile.
--- @return loomworks.SDK|nil
function Profile:sdk()
    return self._sdk
end

--- Set the SDK for this profile.
--- @param sdk loomworks.SDK|nil
function Profile:set_sdk(sdk)
    self._sdk = sdk
    self._sdk_key = sdk and sdk.key or nil
end

--- Resolve SDK-derived tool for a module type.
--- @param mod_type string
--- @return table|nil { key, data, label }
function Profile:_resolve_sdk_tool(mod_type)
    if not self._sdk or not self._sdk:is_resolved() then return nil end
    local caps = self._sdk:query(mod_type)
    if not caps then return nil end
    local mod_impl = require("loomworks.modules").get(mod_type)
    if not mod_impl or not mod_impl.kits_from_sdk then return nil end
    local ok, kits = pcall(mod_impl.kits_from_sdk, caps, self._sdk)
    if not ok or not kits or #kits == 0 then return nil end
    return {
        key = mod_impl.tool_key and mod_impl.tool_key(kits[1].tool_data) or nil,
        data = kits[1].tool_data,
        label = mod_impl.tool_label and mod_impl.tool_label(kits[1].tool_data) or nil,
    }
end

--- Derive tools dict from explicit selections only.
--- Returns module-specific overrides (_tools_raw or _tool_objects).
--- Does NOT include SDK-derived tools — those are resolved lazily
--- per-project via tool_for(). This keeps the profile key clean.
--- @return table<string, { key: string, data: table, label: string|nil }>|nil
function Profile:tools_data()
    if self._tools_raw and next(self._tools_raw) then
        return self._tools_raw
    end
    if self._tool_objects then
        local result = {}
        for mod, tool in pairs(self._tool_objects) do
            result[mod.id] = {
                key = tool.key,
                data = tool.data,
                label = tool.label,
            }
        end
        if next(result) then return result end
    end
    return nil
end

--- Generate a definition suitable for loomworks.json.
--- @return table definition { configuration_set?, tools? }
function Profile:to_config_def()
    local def = {}
    if self._configuration_set_name then
        def.configuration_set = self._configuration_set_name
    end
    -- Extract tool key for the definition (kit_id)
    local tools = self:tools_data()
    if tools then
        for _, tool_ref in pairs(tools) do
            if tool_ref.key then
                def.kit_id = tool_ref.key
                break
            end
        end
    end
    if self._default_target_descriptor then
        def.default_target = self._default_target_descriptor
    end
    return def
end

--- Get the ToolRef for a specific module type from this profile's tools.
--- Resolution: 1. module override, 2. SDK-derived, 3. nil (incomplete)
--- @param mod_type string module type (e.g. "cmake")
--- @return loomworks.ToolRef|nil
function Profile:tool_for(mod_type)
    -- 1. Module-specific override (resolved domain objects or raw)
    if self._tool_objects then
        for mod, tool in pairs(self._tool_objects) do
            if mod.id == mod_type then
                return { key = tool.key, data = tool.data, label = tool.label }
            end
        end
    end
    if self._tools_raw and self._tools_raw[mod_type] then
        return self._tools_raw[mod_type]
    end
    -- 2. SDK-derived tool
    return self:_resolve_sdk_tool(mod_type)
end

--- Get the Tool domain object for a specific module.
--- @param module loomworks.Module
--- @return loomworks.Tool|nil
function Profile:tool_object_for(module)
    return self._tool_objects and self._tool_objects[module] or nil
end

--- Compute the cache key for a variant, accounting for tool.
--- When project_type is provided, looks up the tool for that module type.
--- @param variant string
--- @param project_type? string module type of the project
--- @return string
function Profile:config_key(variant, project_type)
    if project_type then
        local tool_ref = self:tool_for(project_type)
        if tool_ref and tool_ref.key then
            return variant .. ":" .. tool_ref.key
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

--- Activate this profile and set it as active.
function Profile:activate()
    self._workspace._active_profile = self
    self._workspace._active_profile_key = self.key
    self._workspace:_save_user()
    self._workspace:remerge()
end

--- Deactivate this profile if it is currently active.
function Profile:deactivate()
    if self._workspace._active_profile_key == self.key then
        self._workspace._active_profile = nil
        self._workspace._active_profile_key = nil
        self._workspace:_save_user()
        self._workspace:remerge()
    end
end

--- Build all projects in this profile via overseer.
--- @return loomworks.Future
function Profile:build()
    return require("loomworks.overseer").run_profile_action(self, "build")
end

--- Configure all projects in this profile via overseer.
--- @return loomworks.Future
function Profile:configure()
    return require("loomworks.overseer").run_profile_action(self, "configure")
end

-- ---------------------------------------------------------------------------
-- Default target
-- ---------------------------------------------------------------------------

--- Get the default LaunchTarget for this profile.
--- Resolves from the profile's stored descriptor, falls back to loomworks.json definition.
--- @return loomworks.LaunchTarget|nil
function Profile:default_target()
    local descriptor = self._default_target_descriptor
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

--- Check if this profile has a user-set default target override.
--- @return boolean
function Profile:has_default_target_override()
    return self._default_target_descriptor ~= nil
end

--- Set the default target for this profile.
--- @param project loomworks.Project
--- @param target_id? string opaque target identifier (module targets)
--- @param launch_name? string launch config name (command launches)
function Profile:set_default_target(project, target_id, launch_name)
    local descriptor = { project = project.key }
    if target_id then descriptor.target = target_id end
    if launch_name then descriptor.launch = launch_name end
    self._default_target_descriptor = descriptor
    self._workspace:_save_user()
end

--- Clear the default target for this profile.
function Profile:clear_default_target()
    self._default_target_descriptor = nil
    self._workspace:_save_user()
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

--- Check if all modules in this profile have tools resolved.
--- A profile is incomplete if any keyed-tool module has no tool available.
--- Non-keyed modules (typescript) don't require explicit tool selection.
--- @return boolean
function Profile:is_complete()
    for _, pp in ipairs(self:projects()) do
        local project = pp._project
        if project and project._module and project._module.has_keyed_tools then
            if not self:tool_for(project.type) then
                return false
            end
        end
    end
    return true
end

--- Check if this profile has any configured entries.
--- Iterates ProfileProjects and checks each ConfigUnit's state.
--- @return boolean
function Profile:is_configured()
    for _, pp in ipairs(self:projects()) do
        if pp._config_unit then
            local state = pp._config_unit:state()
            if state and state ~= "unconfigured" then
                return true
            end
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
    local empty = { items = {}, profile = self, defined_in_config = false }
    if not self.mappings then return empty end

    -- Build lookup: which configs are referenced by OTHER profiles.
    local other_refs = {}
    for _, other in pairs(self._workspace._profiles) do
        if other.key ~= self.key then
            for _, other_pp in ipairs(other:projects()) do
                if other_pp._config_unit then
                    other_refs[other_pp._config_unit] = true
                end
            end
        end
    end

    -- Include ALL project/config combos with disposition
    local items = {}
    for _, pp in ipairs(self:projects()) do
        local has_other_ref = pp._config_unit and other_refs[pp._config_unit] or false
        items[#items + 1] = {
            unit = pp._config_unit,
            build_dir = pp:build_dir(),
            disposition = has_other_ref and "keep" or "clean",
        }
    end

    -- Sort by project key for deterministic UI order
    table.sort(items, function(a, b)
        local a_key = a.unit and a.unit._project and a.unit._project.key or ""
        local b_key = b.unit and b.unit._project and b.unit._project.key or ""
        return a_key < b_key
    end)

    return {
        items = items,
        profile = self,
    }
end

--- Delete this profile (plan + execute, no UI confirmation).
--- Creates a delete Operation to track progress.
--- @param on_done? function
--- Delete this profile. Returns a Future.
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function Profile:delete(on_done)
    local plan = self:plan_deletion()

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

    return self._workspace:execute_deletion(plan, { deactivate_profile = self }, on_done)
end

--- Clean this profile's configs. Returns a Future.
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function Profile:clean(on_done)
    local future_mod = require("loomworks.future")
    local pps = self:projects()
    if #pps == 0 then
        if on_done then on_done() end
        return future_mod.resolved(true)
    end

    local items = {}
    local units = {}
    local target_states = {}
    for _, pp in ipairs(pps) do
        items[#items + 1] = { unit = pp._config_unit }
        units[#units + 1] = pp._config_unit
        target_states[pp._config_unit] = "configured"
    end

    self._workspace:cancel_conflicting_operations(units)

    for _, unit in ipairs(units) do
        unit:mark_deleting(true, "cleaning")
    end
    self._workspace:create_operation(self, "clean", units, target_states)

    self._workspace:mark_cached_configs_cleaned(items)

    local running = self._workspace:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    local f = self._workspace:stop_tasks_then(task_ids):next(function()
        return require("loomworks.overseer").run_profile_clean(self)
    end):next(function()
        for _, unit in ipairs(units) do
            unit:mark_deleting(false)
        end
        return true
    end)

    if on_done then
        f:next(function() on_done() end)
         :catch(function() on_done() end)
    end
    return f
end

--- Rebuild: clean then build. Returns a Future.
--- @return loomworks.Future
function Profile:rebuild()
    return self:clean():next(function()
        return self:build()
    end)
end

return { Profile = Profile, ProfileProject = ProfileProject }
