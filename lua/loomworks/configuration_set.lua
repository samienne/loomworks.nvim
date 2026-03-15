--- loomworks/configuration_set.lua — ConfigurationSet object.
--- Represents a named mapping of projects to configuration variants.
--- Owns activation: find_profile() + activate() replace Core:activate_new_profile.

--- @class loomworks.ConfigurationSet
--- @field name string configuration set name
--- @field mappings table<loomworks.Project, string> project -> variant
local ConfigurationSet = {}
ConfigurationSet.__index = ConfigurationSet

--- Create a new ConfigurationSet.
--- @param core loomworks.Core
--- @param name string
--- @param mappings table<loomworks.Project, string>
--- @return loomworks.ConfigurationSet
function ConfigurationSet.new(core, name, mappings)
  local self = setmetatable({}, ConfigurationSet)
  self._core = core
  self.name = name
  self.mappings = mappings
  return self
end

function ConfigurationSet:__tostring()
  return "ConfigurationSet(" .. self.name .. ")"
end

--- Get the variant for a project in this set.
--- @param project loomworks.Project
--- @return string|nil
function ConfigurationSet:variant(project)
  return self.mappings[project]
end

--- Find a profile in the registry matching this set + tool properties.
--- Uses property-based matching, never key computation.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:find_profile(tool_entry)
  local tool_data = tool_entry and tool_entry.tool_data or nil
  local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil
  for _, profile in pairs(self._core._profiles) do
    if profile.configuration_set == self.name then
      local profile_tool_data = profile.tool and profile.tool.data or nil
      local profile_mod_type = profile.tool and profile.tool.mod_type or nil
      if not tool_data and not profile_tool_data then
        return profile
      end
      if tool_mod_type and profile_mod_type == tool_mod_type then
        local merge = require("loomworks.merge")
        if merge.cached_profile_matches(profile, self.name, tool_data) then
          return profile
        end
      end
    end
  end
  return nil
end

--- Activate this configuration set, optionally with a tool.
--- Materializes the profile if it doesn't exist yet.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:activate(tool_entry)
  if not self._core:get_workspace() then
    self._core._deps.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return nil
  end

  -- Find existing profile by property matching
  local profile = self:find_profile(tool_entry)
  if profile then
    profile:activate()
    return profile
  end

  -- Materialize from structured data
  self._core:_materialize_from_data(self, tool_entry)

  -- Find the newly created profile by property matching
  profile = self:find_profile(tool_entry)
  if profile then
    profile:activate()
  end
  return profile
end

return ConfigurationSet
