--- loomworks/configuration.lua — Configuration domain object.
--- Represents a build variant (Debug, Release, Debug-asan) within a Project.
--- Created from module.info() output + loomworks.json user overrides.
--- Owned by Project._configurations registry.

--- @class loomworks.Configuration
--- @field name string configuration name (e.g., "Debug", "Debug-asan")
--- @field _project loomworks.Project back-reference
--- @field _inherits loomworks.Configuration[] resolved base configuration references
--- @field inherits_names string[] raw base config names (from module data)
--- @field options table<string, string>|nil generic options (from loomworks.json)
--- @field module_config table opaque module-specific data (cmake: toolchain, generator, etc.)
--- @field is_default boolean from module detection (not user-defined)
--- @field is_user boolean from loomworks.json user override
--- @field from_preset boolean from CMakePresets.json
--- @field variables table<string, string>|nil variable overrides (name → value)
--- @field role string|nil special role (e.g., "compile_commands")
--- @field _removed boolean
local Configuration = {}
Configuration.__index = Configuration

--- Create a new Configuration.
--- @param project loomworks.Project owning project
--- @param name string configuration name
--- @param data table configuration data from module.info()
--- @return loomworks.Configuration
function Configuration.new(project, name, data)
    local self = setmetatable({}, Configuration)
    self._project = project
    self.name = name
    self._removed = false
    self:_update(data)
    return self
end

--- Update configuration data in place (preserves table identity).
--- @param data table configuration data from module.info()
function Configuration:_update(data)
    data = data or {}
    self.is_default = data.is_default or false
    self.is_user = data.is_user or false
    self.from_preset = data.from_preset or false
    self.role = data.role or nil

    -- Store raw inherits names for deferred resolution
    if data.inherits then
        if type(data.inherits) == "string" then
            self.inherits_names = { data.inherits }
        elseif type(data.inherits) == "table" then
            self.inherits_names = data.inherits
        else
            self.inherits_names = {}
        end
    else
        self.inherits_names = {}
    end

    -- Options (generic, not module-specific)
    self.options = data.options or nil

    -- Variable overrides (generic, not module-specific)
    self.variables = data.variables or nil

    -- Module-specific config: everything except the generic fields above
    local module_config = {}
    local generic = {
        is_default = true, is_user = true, from_preset = true,
        role = true, inherits = true, options = true, variables = true,
    }
    for k, v in pairs(data) do
        if not generic[k] then
            module_config[k] = v
        end
    end
    self.module_config = module_config
end

--- Resolve inheritance references from the project's configuration registry.
--- Must be called after all Configuration objects for the project are created.
function Configuration:_resolve_inherits()
    self._inherits = {}
    if not self._project then return end
    for _, base_name in ipairs(self.inherits_names) do
        local base = self._project:get_configuration(base_name)
        if base then
            self._inherits[#self._inherits + 1] = base
        end
    end
end

--- Check if this configuration is abstract (no variant — mixin only).
--- @return boolean
function Configuration:is_abstract()
    return not self.module_config or self.module_config.variant == nil
end

--- Serialize the user-override portion for loomworks.json.
--- Returns the entry that would appear under type_config.configurations[name].
--- Returns nil for non-user configs (defaults, presets, cache-only stubs).
--- @return table|nil
function Configuration:serialize_user_override()
    if not self.is_user then return nil end
    local entry = {}
    -- module_config holds module-specific fields (cmake: variant, toolchain, generator)
    -- excluding generic fields (is_default, is_user, from_preset, role, inherits, options)
    for k, v in pairs(self.module_config) do
        entry[k] = v
    end
    -- Generic fields stored on the Configuration object directly
    if self.inherits_names and #self.inherits_names > 0 then
        entry.inherits = #self.inherits_names == 1 and self.inherits_names[1] or self.inherits_names
    end
    if self.options and next(self.options) then entry.options = self.options end
    if self.role then entry.role = self.role end
    return entry
end

function Configuration:__tostring()
    return "Configuration(" .. self._project.key .. "/" .. self.name .. ")"
end

function Configuration:__eq(other)
    return self._project == other._project and self.name == other.name
end

return Configuration
