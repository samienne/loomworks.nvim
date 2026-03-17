--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Phase 1: module targets only (project + target_id).
--- Phase 2: extends to overseer templates and custom commands.

--- @class loomworks.LaunchTarget
--- @field _core loomworks.Core
--- @field _profile loomworks.Profile direct reference
--- @field _project loomworks.Project|nil direct reference
--- @field _config_unit loomworks.ConfigUnit|nil direct reference
--- @field _target_id string|nil opaque target identifier (module-specific)
--- @field _removed boolean
local LaunchTarget = {}
LaunchTarget.__index = LaunchTarget

--- Create a new LaunchTarget from a descriptor.
--- @param core loomworks.Core
--- @param profile loomworks.Profile
--- @param descriptor { project: string, target: string }
--- @return loomworks.LaunchTarget
function LaunchTarget.new(core, profile, descriptor)
    local self = setmetatable({}, LaunchTarget)
    self._core = core
    self._profile = profile
    self._removed = false
    self:_update(descriptor)
    return self
end

--- Resolve references from descriptor (disk data → object references).
--- @param descriptor { project: string, target: string }
function LaunchTarget:_update(descriptor)
    self._target_id = descriptor.target

    -- Resolve project string to Project object
    self._project = self._core._projects[descriptor.project]

    -- Resolve ConfigUnit: find the ProfileProject for this project in the
    -- profile, then get the ConfigUnit it delegates to.
    self._config_unit = nil
    if self._project and self._profile.mappings then
        local variant = self._profile.mappings[descriptor.project]
        if variant then
            local config_key = self._profile:config_key(variant)
            self._config_unit = self._core:get_config_unit(descriptor.project, config_key)
        end
    end
end

function LaunchTarget:__tostring()
    local project_name = self._project and self._project.key or "?"
    return "LaunchTarget(" .. project_name .. ": " .. (self._target_id or "?") .. ")"
end

--- Build this target.
--- Delegates to ConfigUnit:build_target for module targets.
function LaunchTarget:build()
    if not self._config_unit or not self._target_id then return end
    self._config_unit:build_target(self._target_id)
end

--- Check if this target is still valid (exists in ConfigUnit.targets).
--- @return boolean
function LaunchTarget:is_valid()
    if not self._config_unit or self._config_unit._removed then return false end
    if not self._target_id then return false end
    local targets = self._config_unit.targets
    if not targets then return false end
    return targets[self._target_id] ~= nil
end

--- Check if this target has a build step.
--- @return boolean
function LaunchTarget:is_buildable()
    return self._project ~= nil and self._target_id ~= nil
end

--- Get a display name for this target.
--- @return string
function LaunchTarget:display_name()
    local project_name = self._project and self._project.key or "?"
    return project_name .. ": " .. (self._target_id or "?")
end

return LaunchTarget
