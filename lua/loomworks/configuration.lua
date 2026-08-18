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
--- @field _derived table|nil module fields inherited from a base rather than
---        declared here; kept at runtime but skipped by serialization
--- @field languages string[]|nil explicit list of languages this
---        configuration needs (e.g. {"c", "c++", "rust"}). When nil,
---        falls through to `Project._module.languages` at resolution.
---        Determines which tools in `profile.tools` are "in scope"
---        for ConfigUnits derived from this configuration.
--- @field role string|nil special role (e.g., "compile_commands")
--- @field _detected_languages string[]|nil languages actually enabled
---        by the last successful configure (filled by
---        `module.detect_languages` post-configure). Runtime-only
---        in v1 — not persisted to cache yet. Drives the soft
---        "language declared vs enabled" diagnostic.
--- @field _removed boolean
--- @field _source_missing boolean true when this Configuration exists as
---        a skeleton — created because a config_set mapping,
---        inherits reference, or similar pointed at its name, but
---        no module-emitted `info()` entry nor user.json declaration
---        currently backs it. Cleared when the backing reappears.
--- @field _intent? "local"|"shared"|"local+shared" intended publish state; nil before data_model.refresh's first sync
--- @field _removed_upstream? boolean transient session flag — was in old baseline but not in new
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
    -- _intent left nil; data_model.refresh assigns and then sticks. Mutation
    -- methods set it explicitly when creating outside refresh.
    self._intent = nil
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

--- Mark this configuration as in the user.json working copy.
--- Called when any mutation is about to write to user.json. Implements
--- the implicit cascade rule: using a `shared` item materializes it into
--- the working copy with intent local+shared.
function Configuration:_mark_user_owned()
    if self._intent == "shared" then
        self._intent = "local+shared"
    elseif self._intent == nil then
        -- Newly created outside of refresh; mutation is the first sighting.
        self._intent = "local"
    end
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
---     (cmake → "cmake:Debug" when the module doesn't opt into
---     "auto:").
---   * `user_overrides` user.json / loomworks.json
---     type_config.configurations dict. Keys must already be
---     validated free of `:` (enforced in config.validate). Each
---     entry becomes a standalone user config in the output, keyed
---     by its bare name — it does not shadow an auto-gen that
---     happens to share a name.
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

    -- Languages this configuration requires. Explicit nil keeps the
    -- "no override" state — resolution falls through to module default.
    -- Sanitize defensively: only accept arrays of strings.
    if type(data.languages) == "table" then
        local list = {}
        for _, lang in ipairs(data.languages) do
            if type(lang) == "string" and lang ~= "" then
                list[#list + 1] = lang
            end
        end
        self.languages = #list > 0 and list or nil
    else
        self.languages = nil
    end

    -- Module fields this configuration got from a base rather than declaring.
    -- Modules propagate inherited values (cmake: variant/toolchain/generator,
    -- meson: variant/buildtype) so the build path has something concrete, but
    -- a derived value must not be serialized: that writes a copy of the base's
    -- value into user.json, and if the base later changes the stale copy wins
    -- silently. Runtime keeps it; `serialize_user_override` skips it.
    self._derived = type(data._derived) == "table" and data._derived or nil

    -- Module-specific config: everything except the generic fields above
    local module_config = {}
    local generic = {
        is_default = true, is_user = true, from_preset = true,
        role = true, inherits = true, options = true, variables = true,
        languages = true,
        prefix = true, base_name = true, _derived = true,
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
--- success. Orphaned names are actionable at the UI layer via
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

--- Return direct dependents — the other configurations in the
--- same project whose `inherits` chain references this one by name.
--- Uses the raw `inherits_names` so stale (`_source_missing`)
--- dependents are still visible: their reference is part of
--- user.json / loomworks.json and matters to the user even if the
--- resolution didn't link up. `_removed` configs are excluded; the
--- caller has already dropped those from the registry.
--- @return loomworks.Configuration[]
function Configuration:dependents()
    if not self._project then return {} end
    local result = {}
    for _, cfg in ipairs(self._project:get_configurations()) do
        if cfg ~= self and not cfg._removed then
            for _, base_name in ipairs(cfg.inherits_names or {}) do
                if base_name == self.name then
                    result[#result + 1] = cfg
                    break
                end
            end
        end
    end
    return result
end

--- Check if this configuration is abstract (no variant — mixin only).
--- @return boolean
function Configuration:is_abstract()
    -- Presets are module-emitted and self-contained: cmake fully
    -- specifies the build via `--preset`, so a missing loomworks
    -- variant is expected, not a mixin. Per spec, no module emits
    -- an abstract configuration.
    if self.from_preset then return false end
    return not self.module_config or self.module_config.variant == nil
end

--- Get the effective list of languages this configuration needs.
--- Explicit `languages` on the configuration wins; otherwise falls
--- through to the project module's static declaration.
---
--- Distinguishes from `self.languages` (the override slot) so the
--- editor can show empty/inherited state separately. Resolution
--- consumers (build dir, profile validity, tool lookup) call this
--- accessor — never `self.languages` directly — so the fallback is
--- centralized.
--- @return string[] never nil; empty list means "no language needed"
function Configuration:effective_languages()
    if self.languages and #self.languages > 0 then
        return self.languages
    end
    local mod = self._project and self._project._module
    if mod and mod.languages and #mod.languages > 0 then
        return mod.languages
    end
    return {}
end

--- Validity gate for build/configure/clean operations and UI
--- enable-state. Returns `(ok, reasons)` where `reasons` is a list
--- of human-readable strings explaining why the configuration is
--- invalid. An empty list means valid.
---
--- Invalid states:
---   * `_removed`: object was torn down by a previous sync.
---     Continuing to act on it is a use-after-free in spirit.
---   * `_source_missing`: a config_set or inherits chain referenced
---     this canonical name, but no live source emits it. The stub
---     exists so references stay graph-sound (branch-switch
---     resilience) but it isn't buildable.
---   * unresolved inherits: one or more bases don't resolve. The
---     module's resolution would either skip or error mid-build.
---
--- Other things the UI surfaces inline (auto-gen dim, abstract
--- "mixin only" tag) are NOT validity issues — auto-gens are
--- fine, abstract is fine when used as a base. They're rendering
--- distinctions, not gates.
--- @return boolean ok, string[] reasons
function Configuration:is_valid()
    local reasons = {}
    if self._removed then
        reasons[#reasons + 1] = "configuration was removed from the project registry"
    end
    if self._source_missing then
        reasons[#reasons + 1] = "configuration '" .. self.name
            .. "' is referenced but not defined — fix the reference "
            .. "or restore the configuration"
    end
    local unresolved = self:unresolved_inherits_names()
    if #unresolved > 0 then
        reasons[#reasons + 1] = "inherits from unknown bases: "
            .. table.concat(unresolved, ", ")
    end
    return #reasons == 0, reasons
end

--- Return a structural diagnostic for this configuration, or nil
--- when valid. Thin formatter on top of `:is_valid()` — keeps the
--- diagnostic surface and the operation-gate in sync (one
--- predicate, two views).
---
--- Suppression rule: if the only reason this config is invalid is
--- `_source_missing` AND a `ConfigurationSet` references it, return
--- nil. The set's own `:diagnostic()` already surfaces the same
--- condition with a more actionable fix-it ("fix the mapping in
--- loomworks.json"), and emitting both was reading as a duplicate
--- on the status page. The sibling-inherits case (a different
--- config inheriting from this missing name) is *not* covered by
--- any set diagnostic, so we keep the project-side surface for it.
--- @return loomworks.Diagnostic|nil
function Configuration:diagnostic()
    local ok, reasons = self:is_valid()
    if ok then return nil end

    local proj_key = self._project and self._project.key or "?"

    -- Find referrer (if any) for both target-jump and dedup decisions.
    local set_referrer = nil
    local sibling_referrer = nil
    if self._source_missing and self._project and self._project._workspace then
        local ws = self._project._workspace
        for _, cs in pairs(ws._config_sets or {}) do
            if not cs._removed
                and cs.mappings
                and cs.mappings[self._project] == self then
                set_referrer = cs
                break
            end
        end
        if not set_referrer then
            for _, sib in ipairs(self._project._configurations or {}) do
                if sib ~= self and not sib._removed then
                    for _, n in ipairs(sib.inherits_names or {}) do
                        if n == self.name then
                            sibling_referrer = sib
                            break
                        end
                    end
                    if sibling_referrer then break end
                end
            end
        end
    end

    -- Dedup: if source_missing is the only invalidity AND a config_set
    -- already covers it, skip — set-side diagnostic is enough.
    if self._source_missing and set_referrer then
        local only_source_missing = (#reasons == 1)
        if only_source_missing then return nil end
    end

    -- Pick the jump target: referrer beats self for source-missing.
    local target_fold_key = "config:" .. proj_key .. ":" .. self.name
    if set_referrer then
        target_fold_key = "set:" .. set_referrer.name
    elseif sibling_referrer then
        target_fold_key = "config:" .. proj_key .. ":" .. sibling_referrer.name
    end

    return {
        severity = "warn",
        source = "Project/" .. proj_key .. "/" .. self.name,
        message = "configuration '" .. self.name .. "' on project '"
            .. proj_key .. "' is invalid: " .. table.concat(reasons, "; "),
        target_fold_key = target_fold_key,
    }
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
        -- Skip values propagated from a base (see `_derived` in `_apply`) —
        -- they are the base's, and persisting them would freeze a copy.
        if not (self._derived and self._derived[k]) then
            entry[k] = v
        end
    end
    -- Generic fields stored on the Configuration object directly
    if self.inherits_names and #self.inherits_names > 0 then
        entry.inherits = #self.inherits_names == 1 and self.inherits_names[1] or self.inherits_names
    end
    if self.options and next(self.options) then entry.options = self.options end
    if self.variables and next(self.variables) then entry.variables = self.variables end
    if self.languages and #self.languages > 0 then entry.languages = self.languages end
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
