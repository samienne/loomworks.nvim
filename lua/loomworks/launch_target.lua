--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Phase 1: module targets only (project + target_id).
--- Phase 2: extends to overseer templates and custom commands.

--- @class loomworks.LaunchTarget
--- @field _core loomworks.Core
--- @field _profile loomworks.Profile direct reference
--- @field _project loomworks.Project|nil direct reference
--- @field _config_unit loomworks.ConfigUnit|nil direct reference
--- @field _target loomworks.Target|nil direct reference to resolved target
--- @field _target_id string|nil fallback identifier for re-resolution
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

    -- Resolve ConfigUnit
    self._config_unit = nil
    self._target = nil
    if self._project and self._profile.mappings then
        local variant = self._profile.mappings[descriptor.project]
        if variant then
            local config_key = self._profile:config_key(variant, self._project.type)
            self._config_unit = self._core:get_config_unit(descriptor.project, config_key)
            -- Resolve Target object from ConfigUnit.targets
            if self._config_unit and self._config_unit.targets then
                self._target = self._config_unit.targets[self._target_id]
            end
        end
    end
end

function LaunchTarget:__tostring()
    local project_name = self._project and self._project.key or "?"
    return "LaunchTarget(" .. project_name .. ": " .. (self._target_id or "?") .. ")"
end

--- Build this target.
--- Delegates to the Target object's build method.
function LaunchTarget:build()
    if self._target then
        self._target:build()
    end
end

--- Check if this target is still valid (Target object exists and is resolved).
--- @return boolean
function LaunchTarget:is_valid()
    return self._target ~= nil
end

--- Check if this target has a build step.
--- @return boolean
function LaunchTarget:is_buildable()
    return self._target ~= nil
end

--- Get a display name for this target.
--- @return string
function LaunchTarget:display_name()
    if self._target then
        local project_name = self._project and self._project.key or "?"
        return project_name .. ": " .. self._target:display_name()
    end
    local project_name = self._project and self._project.key or "?"
    return project_name .. ": " .. (self._target_id or "?")
end

return LaunchTarget
