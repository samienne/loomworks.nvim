--- loomworks/profile.lua — Profile and ProfileProject objects.
--- Profile represents a configuration_set × kit combination.
--- ProfileProject represents a single project within a profile.

local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")

--- Format a duration in seconds to a compact string.
--- @param seconds number
--- @return string
local function format_duration(seconds)
    local s = math.floor(seconds)
    if s < 60 then
        return s .. "s"
    end
    local m = math.floor(s / 60)
    s = s % 60
    if m < 60 then
        return m .. "m" .. string.format("%02d", s) .. "s"
    end
    local h = math.floor(m / 60)
    m = m % 60
    return h .. "h" .. string.format("%02d", m) .. "m"
end

-- ========================== ProfileProject ==========================

--- @class loomworks.ProfileProject
--- @field project_key string
--- @field variant string configuration variant name
--- @field config_key string precomputed cache key (variant or variant:kit_id)
--- @field _core loomworks.Core
--- @field _profile loomworks.Profile direct reference to parent profile
--- @field _project loomworks.Project|nil direct reference to project object
--- @field _removed boolean
local ProfileProject = {}
ProfileProject.__index = ProfileProject

--- Create a ProfileProject.
--- @param core loomworks.Core
--- @param profile loomworks.Profile parent Profile
--- @param project_key string
--- @param variant string configuration variant name
--- @return loomworks.ProfileProject
function ProfileProject.new(core, profile, project_key, variant)
    local self = setmetatable({}, ProfileProject)
    self._core = core
    self.project_key = project_key
    self._removed = false
    self:_update(profile, variant)
    return self
end

--- Update in place (preserves table identity).
--- Resolves direct references to Profile and Project from Core registries.
--- @param profile loomworks.Profile
--- @param variant string
function ProfileProject:_update(profile, variant)
    self._profile = profile
    self._project = self._core._projects[self.project_key]
    self.variant = variant
    -- Only modules with keyed tools get the tool_key suffix
    local project = self._project
    if profile.tool and profile.tool.key and project
            and self._core:module_has_keyed_tools(project.type) then
        self.config_key = variant .. ":" .. profile.tool.key
    else
        self.config_key = variant
    end
end

function ProfileProject:__tostring()
    return "ProfileProject(" .. self.project_key .. " @ " .. self._profile.key .. ")"
end

--- Get the resolved status for this project-in-profile.
--- Delegates to ConfigUnit for the single source of truth.
--- @return loomworks.ConfigUnitState status
function ProfileProject:status()
    local unit = self._core:get_config_unit(self.project_key, self.config_key)
    return unit:state()
end

--- Get the running action for this project-in-profile.
--- Delegates to ConfigUnit — running state is shared across all profiles
--- that reference the same (project_key, config_key) pair.
--- @return string|nil action
function ProfileProject:running_action()
    local unit = self._core:get_config_unit(self.project_key, self.config_key)
    return unit:running_action()
end

--- Check if this project-in-profile is being deleted.
--- @return boolean
function ProfileProject:is_deleting()
    local unit = self._core:get_config_unit(self.project_key, self.config_key)
    return unit:is_deleting()
end

--- Get cached state from the workspace cache.
--- @return loomworks.CachedConfig|nil
function ProfileProject:cached_state()
    local ws = self._core:get_workspace()
    if not ws or not ws.cache.configurations then return nil end
    local ck = cache_mod.config_cache_key(self.project_key, self.config_key)
    return ws.cache.configurations[ck]
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
--- @field configuration_set? string nil for pinned profiles
--- @field tool? loomworks.ToolRef bundled tool reference (nil for non-keyed modules)
--- @field explicit boolean
--- @field mappings? table<string, string> project_key -> variant name
--- @field orphaned_set boolean true if configuration_set no longer exists in config
--- @field _core loomworks.Core
--- @field _removed boolean
--- @field _config_set_ref? loomworks.ConfigurationSet direct reference, resolved during _update
--- @field _valid_variants table<string, boolean> precomputed variant set
--- @field _operation? loomworks.Operation current or last operation state
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
--- @param core loomworks.Core
--- @param key string profile key
--- @param data? { configuration_set?: string, tool_key?: string, tool_data?: table, tool_label?: string, tool_mod_type?: string, explicit?: boolean, mappings?: table<string, string>, orphaned_set?: boolean }
--- @return loomworks.Profile
function Profile.new(core, key, data)
    local self = setmetatable({}, Profile)
    self._core = core
    self.key = key
    self._removed = false
    if data then self:_update(data) end
    return self
end

--- Update all data fields in place (preserves table identity).
--- Resolves mappings and ConfigurationSet reference from Core's registries.
--- @param data loomworks.ProfileDef
function Profile:_update(data)
    self.configuration_set = data.configuration_set
    self.tool = data.tool_key and {
        key = data.tool_key,
        data = data.tool_data,
        label = data.tool_label,
        mod_type = data.tool_mod_type,
    } or nil
    self.explicit = data.explicit or false

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

--- Resolve mappings for this profile from Core's registries.
--- Three tiers: (1) reactive from ConfigurationSet, (2) stored mappings,
--- (3) fallback from cached profile project data.
--- @param data loomworks.ProfileDef
--- @return table<string, string>|nil mappings
--- @return boolean orphaned
function Profile:_resolve_mappings(data)
    -- Tier 1: Set-based profiles — derive from live ConfigurationSet (reactive)
    if data.configuration_set then
        local cs = self._core._config_sets[data.configuration_set]
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

--- Compute the cache key for a variant, accounting for kit_id.
--- @param variant string
--- @return string
function Profile:config_key(variant)
    if self.tool and self.tool.key then
        return variant .. ":" .. self.tool.key
    end
    return variant
end

-- ---------------------------------------------------------------------------
-- Child access
-- ---------------------------------------------------------------------------

--- Get a ProfileProject for a specific project in this profile.
--- Looks up from Core's registry.
--- @param project_key string
--- @return loomworks.ProfileProject|nil
function Profile:project(project_key)
    if not self.mappings or not self.mappings[project_key] then return nil end
    local reg_key = self.key .. "\0" .. project_key
    return self._core._profile_projects[reg_key]
end

--- Get all ProfileProjects in this profile, sorted by project_key.
--- Filters Core's registry by this profile's key.
--- @return loomworks.ProfileProject[]
function Profile:projects()
    if not self.mappings then return {} end
    local prefix = self.key .. "\0"
    local result = {}
    for reg_key, pp in pairs(self._core._profile_projects) do
        if reg_key:sub(1, #prefix) == prefix then
            result[#result + 1] = pp
        end
    end
    table.sort(result, function(a, b) return a.project_key < b.project_key end)
    return result
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Activate this profile.
--- Writes to user.json and remerges directly.
function Profile:activate()
    local ws = self._core:get_workspace()
    if not ws then return end
    ws.user.active_profile = self.key
    self._core._deps.user.save(ws.root, ws.user)
    self._core:remerge()
end

--- Deactivate this profile if it is currently active.
function Profile:deactivate()
    local ws = self._core:get_workspace()
    if not ws then return end
    if ws.user.active_profile == self.key then
        ws.user.active_profile = nil
        self._core._deps.user.save(ws.root, ws.user)
        self._core:remerge()
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
    local ws = self._core:get_workspace()
    if not ws then return nil end

    -- Check user.json first
    local descriptor = ws.user.default_target
        and ws.user.default_target[self.key]
    -- Fall back to loomworks.json profile definition
    if not descriptor and ws.config.profiles then
        local profile_def = ws.config.profiles[self.key]
        if profile_def then
            descriptor = profile_def.default_target
        end
    end
    if not descriptor or not descriptor.project or not descriptor.target then
        return nil
    end

    local LaunchTarget = require("loomworks.launch_target")
    return LaunchTarget.new(self._core, self, descriptor)
end

--- Set the default target for this profile.
--- @param project loomworks.Project
--- @param target_id string opaque target identifier
function Profile:set_default_target(project, target_id)
    local ws = self._core:get_workspace()
    if not ws then return end
    ws.user.default_target = ws.user.default_target or {}
    ws.user.default_target[self.key] = {
        project = project.key,
        target = target_id,
    }
    self._core._deps.user.save(ws.root, ws.user)
end

--- Clear the default target for this profile.
function Profile:clear_default_target()
    local ws = self._core:get_workspace()
    if not ws then return end
    if ws.user.default_target then
        ws.user.default_target[self.key] = nil
        self._core._deps.user.save(ws.root, ws.user)
    end
end

-- ---------------------------------------------------------------------------
-- Operations (profile-level action tracking)
-- ---------------------------------------------------------------------------

--- Start tracking a profile-level operation.
--- Replaces any previous operation result.
--- @param action string "configure", "build", or "configure+build"
function Profile:start_operation(action)
    self._operation = {
        action = action,
        started_at = self._core._deps.clock(),
    }
    self._core._deps.events.emit("operation_started", { profile_key = self.key, action = action })
end

--- Finish the current operation and store a result message.
--- @param success boolean
function Profile:finish_operation(success)
    local op = self._operation
    if not op or not op.started_at then return end

    local elapsed = self._core._deps.clock() - op.started_at
    local verb
    if op.action == "configure" then
        verb = success and "configured" or "configure failed"
    elseif op.action == "build" then
        verb = success and "built" or "build failed"
    else
        verb = success and "built" or "failed"
    end

    self._operation = {
        message = verb .. " in " .. format_duration(elapsed),
        success = success,
    }

    self._core._deps.events.emit("operation_finished", {
        profile_key = self.key,
        success = success,
        message = self._operation.message,
    })
end

--- Get the current operation state (in-progress or completed).
--- @return loomworks.Operation|nil
function Profile:operation()
    return self._operation
end

--- Get elapsed seconds for a running operation.
--- @return number|nil seconds
function Profile:operation_elapsed()
    local op = self._operation
    if not op or not op.started_at then return nil end
    return self._core._deps.clock() - op.started_at
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Check if this profile has any configured entries in cache.
--- @return boolean
function Profile:is_configured()
    local ws = self._core:get_workspace()
    if not ws or not ws.cache then return false end

    -- Look up profile in cache by key
    local cached_profile = ws.cache.profiles and ws.cache.profiles[self.key]
    if not cached_profile or not cached_profile.configurations then
        -- Fallback: value matching for set-based profiles
        if self.configuration_set then
            cached_profile = merge.find_cached_profile(
                ws.cache, self.configuration_set, self.tool and self.tool.data)
        end
        if not cached_profile or not cached_profile.configurations then return false end
    end

    -- Check if any referenced configuration has actual build state
    for _, ck in ipairs(cached_profile.configurations) do
        local cached_config = ws.cache.configurations and ws.cache.configurations[ck]
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
        return counts.deleting .. "/" .. total .. " deleting", STATUS_HL.deleting
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
    local ws = self._core:get_workspace()
    local empty = { items = {}, profile_key = self.key, defined_in_config = false }
    if not ws then return empty end
    if not self.mappings then return empty end

    -- Build lookup: which configs are referenced by OTHER profiles.
    local other_refs = {}
    local all_profiles = self._core:get_profiles()
    for _, other in pairs(all_profiles) do
        if other.key ~= self.key then
            for _, other_pp in ipairs(other:projects()) do
                other_refs[other_pp.project_key .. "\0" .. other_pp.config_key] = true
            end
        end
    end

    -- Include ALL project/config combos with disposition
    local items = {}
    for _, pp in ipairs(self:projects()) do
        local lookup = pp.project_key .. "\0" .. pp.config_key
        items[#items + 1] = {
            project_key = pp.project_key,
            config_key = pp.config_key,
            build_dir = pp:build_dir(),
            disposition = other_refs[lookup] and "keep" or "clean",
        }
    end

    table.sort(items, function(a, b) return a.project_key < b.project_key end)

    local defined_in_config = ws.config.profiles and ws.config.profiles[self.key] or false

    return {
        items = items,
        profile_key = self.key,
        defined_in_config = defined_in_config and true or false,
    }
end

--- Delete this profile (plan + execute, no UI confirmation).
--- @param on_done? function
function Profile:delete(on_done)
    self._core:execute_deletion(
        self:plan_deletion(), { deactivate_profile = self }, on_done)
end

--- Clean this profile's configs: delete build dirs and reset to unconfigured.
--- Does NOT remove the profile itself.
--- @param on_done? function
function Profile:clean(on_done)
    local pps = self:projects()
    if #pps == 0 then
        if on_done then on_done() end
        return
    end

    local items = {}
    for _, pp in ipairs(pps) do
        items[#items + 1] = {
            project_key = pp.project_key,
            config_key = pp.config_key,
            build_dir = pp:build_dir(),
        }
    end

    self._core:_run_deletion(items, function(effective_items)
        self._core:reset_cached_configs(effective_items)
    end, on_done)
end

--- Rebuild: clean then build.
function Profile:rebuild()
    self:clean(function()
        self:build()
    end)
end

return { Profile = Profile, ProfileProject = ProfileProject }
