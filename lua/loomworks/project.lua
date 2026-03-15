--- loomworks/project.lua — Project object wrapping merged project data.
--- Provides query methods for running/deleting/cached state.

--- @class loomworks.Project
--- @field key string project key
--- @field type string module type ("cmake", "ets", "typescript")
--- @field path? string relative path from workspace root
--- @field configuration? string active configuration name
--- @field configuration_key? string cache key for active configuration
--- @field tool? loomworks.ToolRef bundled tool reference (nil for non-keyed modules)
--- @field status loomworks.Status
--- @field orphaned boolean
--- @field needs_refresh boolean
--- @field refresh_reasons string[]
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field cached? loomworks.CachedConfig active configuration's cached state
--- @field cached_configurations table<string, loomworks.CachedConfig>
--- @field cmake? loomworks.ProjectCmakeInfo
local Project = {}
Project.__index = Project

--- Create a new Project object.
--- @param core loomworks.Core
--- @param key string project key
--- @param data? loomworks.MergedProjectData
--- @return loomworks.Project
function Project.new(core, key, data)
  local self = setmetatable({}, Project)
  self._core = core
  self.key = key
  self._removed = false
  if data then self:_update(data) end
  return self
end

--- Update all data fields in place (preserves table identity).
--- @param data loomworks.MergedProjectData
function Project:_update(data)
  self._generation = self._core._generation
  self.type = data.type
  self.path = data.path
  self.configuration = data.configuration
  self.configuration_key = data.configuration_key
  self.tool = data.tool_key and {
    key = data.tool_key,
    data = data.tool_data,
    label = data.tool_label,
    mod_type = data.tool_mod_type,
  } or nil
  self.status = data.status
  self.orphaned = data.orphaned or false
  self.needs_refresh = data.needs_refresh or false
  self.refresh_reasons = data.refresh_reasons or {}
  self.configurations = data.configurations or {}
  self.cached = data.cached
  self.cached_configurations = data.cached_configurations or {}
  self.cmake = data.cmake
end

function Project:__tostring()
  return "Project(" .. self.key .. ")"
end

--- Check if this object's data may be outdated.
--- @return boolean
function Project:is_stale()
  return self._generation ~= self._core._generation
end

--- Get the running action for this project (any config).
--- @return string|nil action ("configure" or "build")
function Project:running_action()
  for _, unit in pairs(self._core._config_units) do
    if unit.project_key == self.key and unit:is_running() then
      return unit:running_action()
    end
  end
  return nil
end

--- Compute the cache key for a configuration name, accounting for kit_id.
--- @param config_name string
--- @return string
function Project:config_cache_key(config_name)
  if self.tool and self.tool.key then
    return config_name .. ":" .. self.tool.key
  end
  return config_name
end

--- Check if a specific configuration is being deleted.
--- @param config_name string
--- @return boolean
function Project:is_deleting_config(config_name)
  local unit = self._core:get_config_unit(self.key, self:config_cache_key(config_name))
  return unit:is_deleting()
end

--- Get the running action for a specific configuration.
--- @param config_name string
--- @return string|nil action
function Project:config_running_action(config_name)
  local unit = self._core:get_config_unit(self.key, self:config_cache_key(config_name))
  return unit:running_action()
end

--- Resolve the cached state for a configuration.
--- Checks kit-qualified key first, then bare name.
--- @param config_name string
--- @return loomworks.CachedConfig|nil
function Project:cached_config(config_name)
  if not self.cached_configurations then return nil end
  if self.tool and self.tool.key then
    local cached = self.cached_configurations[config_name .. ":" .. self.tool.key]
    if cached then return cached end
  end
  return self.cached_configurations[config_name]
end

--- Get absolute path to this project.
--- @return string
function Project:abs_path()
  local ws = self._core:get_workspace()
  if not ws then return self.path or self.key end
  return ws.root .. "/" .. (self.path or self.key)
end

--- Build the module context table used by module.tasks().
--- @param ws_root string workspace root path
--- @return loomworks.ModuleContext
function Project:to_module_context(ws_root)
  return {
    name = self.key,
    path = self.path or self.key,
    type = self.type,
    configuration = self.configuration,
    configuration_key = self.configuration_key,
    configurations = self.configurations,
    tool_key = self.tool and self.tool.key or nil,
    tool_data = self.tool and self.tool.data or nil,
    workspace_root = ws_root,
    env = self.tool and self.tool.data and self.tool.data.env or {},
  }
end

return Project
