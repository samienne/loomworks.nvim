--- loomworks/configuration_set.lua — ConfigurationSet object.
--- Represents a named mapping of projects to configuration variants.
--- Owns activation: find_profile() + activate() replace Core:activate_new_profile.

--- @class loomworks.ConfigurationSet
--- @field name string configuration set name
--- @field mappings table<loomworks.Project, string> project -> variant
--- @field _configuration_mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration object
local ConfigurationSet = {}
ConfigurationSet.__index = ConfigurationSet

--- Create a new ConfigurationSet.
--- @param workspace loomworks.Workspace
--- @param name string
--- @param resolved_mappings table<loomworks.Project, string> project -> variant (pre-resolved)
--- @return loomworks.ConfigurationSet
function ConfigurationSet.new(workspace, name, resolved_mappings)
    local self = setmetatable({}, ConfigurationSet)
    self._workspace = workspace
    self.name = name
    self._removed = false
    self:_update(resolved_mappings)
    return self
end

--- Update mappings in place (preserves table identity).
--- Receives pre-resolved { Project -> variant } from _sync_config_sets.
--- Also resolves Configuration objects from Project's own registry.
--- @param resolved_mappings table<loomworks.Project, string> project -> variant
function ConfigurationSet:_update(resolved_mappings)
    self.mappings = {}
    self._configuration_mappings = {}
    for project, variant in pairs(resolved_mappings) do
        self.mappings[project] = variant
        -- Resolve Configuration domain object (within Project's own registry)
        if project._configurations then
            local cfg = project._configurations[variant]
            if cfg then
                self._configuration_mappings[project] = cfg
            end
        end
    end
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

--- Get the Configuration object for a project in this set.
--- @param project loomworks.Project
--- @return loomworks.Configuration|nil
function ConfigurationSet:configuration(project)
    return self._configuration_mappings and self._configuration_mappings[project] or nil
end

--- Return raw mappings (project_key → variant) for serialization.
--- @return table<string, string>
function ConfigurationSet:raw_mappings()
    local raw = {}
    for project, variant in pairs(self.mappings) do
        raw[project.key] = variant
    end
    return raw
end

--- Update a single project mapping in this configuration set.
--- @param project loomworks.Project
--- @param variant string|nil variant name (nil to remove mapping)
--- @return boolean ok, string|nil err
function ConfigurationSet:update_mapping(project, variant)
    local ws = self._workspace
    if not ws.config.configuration_sets or not ws.config.configuration_sets[self.name] then
        return false, "configuration set '" .. self.name .. "' not found"
    end

    local project_key = project.key
    local old = ws.config.configuration_sets[self.name][project_key]
    ws.config.configuration_sets[self.name][project_key] = variant

    -- Update domain object
    self.mappings[project] = variant

    local ok, err = ws:_save_config()
    if not ok then
        ws.config.configuration_sets[self.name][project_key] = old
        self.mappings[project] = old
        return false, err
    end

    -- Refresh profiles (mapping change affects profile_projects)
    ws:_refresh_after_cache_change()
    return true
end

--- Find a profile in the registry matching this set + tool properties.
--- Uses property-based matching, never key computation.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:find_profile(tool_entry)
    local tool_data = tool_entry and tool_entry.tool_data or nil
    local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil
    for _, profile in pairs(self._workspace._profiles) do
        if profile._configuration_set_name == self.name then
            if not tool_data and not profile._tools_raw then
                return profile
            end
            if tool_mod_type and profile._tools_raw then
                local profile_tool = profile._tools_raw[tool_mod_type]
                if profile_tool then
                    local mod = self._workspace:find_module(tool_mod_type)
                    local impl = mod and mod.impl or nil
                    if impl and impl.tools_match then
                        if impl.tools_match(profile_tool.data, tool_data) then
                            return profile
                        end
                    elseif profile_tool.data == tool_data then
                        return profile
                    end
                end
            end
        end
    end
    return nil
end

--- Ensure a profile exists for this configuration set + tool, materializing if needed.
--- Does NOT activate the profile.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:ensure_profile(tool_entry)
    if not self._workspace then
        return nil
    end

    local profile = self:find_profile(tool_entry)
    if profile then return profile end

    -- Materialize from structured data
    self._workspace:_materialize_from_data(self, tool_entry)

    return self:find_profile(tool_entry)
end

--- Activate this configuration set, optionally with a tool.
--- Materializes the profile if it doesn't exist yet.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:activate(tool_entry)
    local profile = self:ensure_profile(tool_entry)
    if profile then
        profile:activate()
    end
    return profile
end

return ConfigurationSet
