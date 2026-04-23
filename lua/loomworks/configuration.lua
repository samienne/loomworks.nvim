--- loomworks/configuration.lua — Configuration domain object.
--- Represents a build variant (Debug, Release, Debug-asan) within a Project.
--- Created from module.info() output + loomworks.json user overrides.
--- Owned by Project._configurations registry.

--- Build the canonical name for a configuration from a (prefix, base)
--- pair. Prefixed canonical names take the form `prefix:base` and
--- identify auto-generated configurations (module-emitted). User
--- configurations are unprefixed — their canonical name is just the
--- base name. Callers that already have a canonical string should
--- use `split_canonical` to get the parts back.
--- @param prefix string|nil  nil → user config
--- @param base string
--- @return string
local function canonical(prefix, base)
    if prefix and prefix ~= "" then
        return prefix .. ":" .. base
    end
    return base
end

--- Inverse of `canonical`. Given the canonical name string, returns
--- `(prefix, base)`. `prefix` is nil when the name contains no `:`
--- (user config). The first `:` is the separator — prefixes don't
--- themselves contain `:`, but base names may (defensive; we ban
--- `:` in user-declared names separately).
--- @param name string
--- @return string|nil prefix, string base
local function split_canonical(name)
    local p, b = name:match("^([^:]+):(.+)$")
    if p then return p, b end
    return nil, name
end

--- @class loomworks.Configuration
--- @field name string canonical configuration name ("variant:Debug" for
---        auto-gens, bare name for user configs)
--- @field prefix string|nil tier prefix — nil for user configs,
---        module-specified for auto-gens (e.g. "variant", "preset",
---        "auto", or the module id as fallback)
--- @field base_name string the bare name (portion after the prefix),
---        for compact display and user interaction
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
--- @field _source_missing boolean true when this Configuration exists as
---        a skeleton — created because a config_set mapping,
---        inherits reference, or similar pointed at its name, but
---        no module-emitted `info()` entry nor user.json declaration
---        currently backs it. Cleared when the backing reappears.
--- @field _intent "local"|"shared"|"local+shared" intended publish state
local Configuration = {}
Configuration.__index = Configuration

--- Create a new Configuration.
--- @param project loomworks.Project owning project
--- @param name string canonical configuration name
--- @param data table configuration data from module.info()
--- @return loomworks.Configuration
function Configuration.new(project, name, data)
    local self = setmetatable({}, Configuration)
    self._project = project
    self.name = name
    local prefix, base = split_canonical(name)
    self.prefix = prefix
    self.base_name = base
    self._removed = false
    self._intent = "local"
    self:_update(data)
    return self
end

--- True iff this configuration was emitted by the module (auto-gen),
--- as opposed to declared in user.json / loomworks.json by the user.
--- Auto-gens carry a prefix; user configs don't (ban on `:` in user
--- names enforced at config.validate).
--- @return boolean
function Configuration:is_auto_gen()
    return self.prefix ~= nil
end

Configuration.canonical = canonical
Configuration.split_canonical = split_canonical

--- Canonicalise a module's configuration table.
---
--- Intended to be called from each module's `info()` to transform
--- the auto-gen output of `default_configurations` into
--- canonical-keyed form. Takes:
---   * `auto_configs`  bare-keyed table of the module's auto-gens.
---     Each entry may carry `prefix` in its data — if present, it
---     wins. Otherwise the module's id is used as the prefix
---     (harmony → "harmony:default-entry-arm64-v8a" when the module
---     doesn't opt into "auto:").
---   * `user_overrides` user.json / loomworks.json
---     type_config.configurations dict. Keys must already be
---     validated free of `:` (enforced in config.validate). Each
---     entry becomes a standalone user config in the output, keyed
---     by its bare name — it no longer silently shadows an auto-gen
---     that happens to share a name, which was the whole point of
---     the strict-separation design.
---   * `module_id` string, used as the default prefix when an
---     auto-gen entry has no explicit `prefix`.
---
--- Returns a canonical-keyed dict suitable for returning from
--- `info()`: auto-gen keys look like `prefix:base`, user keys are
--- bare.
--- @param auto_configs table<string, table>
--- @param user_overrides table<string, table>|nil
--- @param module_id string
--- @return table<string, table>
function Configuration.canonicalize(auto_configs, user_overrides, module_id)
    local result = {}
    for name, cfg in pairs(auto_configs or {}) do
        -- Shallow-copy so the module's defaults table isn't mutated
        -- across calls (modules that cache their defaults otherwise
        -- end up with stale `prefix`/`base_name` on re-merge).
        local entry = {}
        for k, v in pairs(cfg) do entry[k] = v end
        local prefix = entry.prefix or module_id
        entry.prefix = prefix
        entry.base_name = name
        entry.is_default = true  -- auto-gens are always defaults
        result[canonical(prefix, name)] = entry
    end
    if user_overrides then
        for name, override in pairs(user_overrides) do
            local entry = {}
            for k, v in pairs(override) do entry[k] = v end
            entry.is_user = true
            result[name] = entry
        end
    end
    return result
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
        prefix = true, base_name = true,
    }
    for k, v in pairs(data) do
        if not generic[k] then
            module_config[k] = v
        end
    end
    self.module_config = module_config

    -- A refresh that finds this config in module output OR user.json
    -- proves it's backed — clear any lingering source-missing flag.
    -- An ensure_configuration stub that never gets backed keeps the
    -- flag (see Project:ensure_configuration).
    if self.is_default or self.is_user or self.from_preset then
        self._source_missing = false
    end
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

--- Return the list of `inherits` base names that couldn't be
--- resolved — the caller asked us to inherit from names that don't
--- exist in the project's configuration registry. Empty list on
--- success. The reference usually stayed valid until someone
--- renamed (e.g. auto-gen became canonical-keyed) or removed the
--- base config; orphaned names are actionable at the UI layer via
--- rename / rebase.
--- @return string[]
function Configuration:unresolved_inherits_names()
    local resolved = {}
    for _, c in ipairs(self._inherits or {}) do
        resolved[c.name] = true
    end
    local missing = {}
    for _, name in ipairs(self.inherits_names or {}) do
        if not resolved[name] then
            missing[#missing + 1] = name
        end
    end
    return missing
end

--- Check if this configuration is abstract (no variant — mixin only).
--- @return boolean
function Configuration:is_abstract()
    return not self.module_config or self.module_config.variant == nil
end

--- Serialize the user-override portion for loomworks.json.
--- Returns the entry that would appear under type_config.configurations[name].
--- Returns nil for configs with no user customization. Includes default
--- configs that have been extended with options, variables, inherits, etc.
--- @return table|nil
function Configuration:serialize_user_override()
    if self.from_preset then return nil end
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
    if self.variables and next(self.variables) then entry.variables = self.variables end
    if self.role then entry.role = self.role end
    -- Only emit if there's something beyond the bare default
    if not next(entry) then return nil end
    return entry
end

function Configuration:__tostring()
    return "Configuration(" .. self._project.key .. "/" .. self.name .. ")"
end

function Configuration:__eq(other)
    return self._project == other._project and self.name == other.name
end

return Configuration
