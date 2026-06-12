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
--- @field _tool_compat_error string|nil tool/configuration compatibility error for this (profile, configuration) pair, or nil when compatible. Recomputed every sync.
--- @field _removed boolean
local ProfileProject = {}
ProfileProject.__index = ProfileProject

--- Create a ProfileProject.
--- @param workspace loomworks.Workspace
--- @param project_key string used for identity and fallback resolution
--- @param data { profile: loomworks.Profile, project?: loomworks.Project, configuration?: loomworks.Configuration, config_unit?: loomworks.ConfigUnit, tool_compat_error?: string }
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
--- @param data { profile: loomworks.Profile, project?: loomworks.Project, configuration?: loomworks.Configuration, config_unit?: loomworks.ConfigUnit, tool_compat_error?: string }
function ProfileProject:_apply(data)
    self._profile = data.profile
    self._project = data.project
    self._configuration = data.configuration
    self._config_unit = data.config_unit
    -- Compat error is recomputed each sync — preserve nil when the
    -- module didn't report one, set the reason when it did.
    self._tool_compat_error = data.tool_compat_error
end

--- Get the tool/configuration compatibility error for this
--- (profile, configuration) pair, if any. Non-nil means this
--- profile's resolved tool can't honor the configuration's
--- contract — build actions on this profile-project are blocked.
--- See spec §3 `validate_config_tool`.
--- @return string|nil reason
function ProfileProject:tool_compat_error()
    return self._tool_compat_error
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
--- @field _tool_keys string[] authoritative list of tool keys this profile uses.
---        Order is user-controlled (used by first-match-per-language
---        resolution). Stored on disk as a flat string array.
--- @field _sdk loomworks.SDK|nil SDK domain object reference (resolved at sync time
---        from the first kit-derived tool in `_tool_keys`)
--- @field _sdk_key string|nil cached SDK key for runtime queries
--- @field _default_target_descriptor table|nil user.json default target for this profile
--- @field _device_serial string|nil selected device serial for this profile
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
--- @field _intent? "local"|"shared"|"local+shared" intended publish state; nil before data_model.refresh's first sync
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
    -- _intent left nil; data_model.refresh assigns and then sticks
    -- (specification.md §2.4). Mutation methods set it explicitly.
    self._intent = nil
    if data then self:_apply(data) end
    return self
end

--- Mark this profile as in the user.json working copy.
--- Called when any mutation is about to write to user.json. Profiles
--- default to local intent (per spec §2.4 — profiles are personal by
--- default), but a `shared` profile that's being used must be promoted
--- to `local+shared` so its data lands in the working copy.
function Profile:_mark_user_owned()
    if self._intent == "shared" then
        self._intent = "local+shared"
    elseif self._intent == nil then
        self._intent = "local"
    end
end

--- Read the canonical `_tool_keys` array from a profile's raw data.
--- Accepts both the new array shape (`tools: ["key1", "key2"]`) and
--- the legacy dict shape (`tools: { module_id → {key, data, label} }`)
--- so existing user.json files migrate transparently on first load.
--- Returns a deduplicated array; order is preserved from the input.
--- @param tools_data any
--- @return string[]
local function read_tool_keys(tools_data)
    if not tools_data then return {} end
    local result = {}
    local seen = {}
    if vim.islist and vim.islist(tools_data) then
        for _, k in ipairs(tools_data) do
            if type(k) == "string" and k ~= "" and not seen[k] then
                seen[k] = true
                result[#result + 1] = k
            end
        end
        return result
    end
    if type(tools_data) == "table" then
        -- Legacy dict: { module_id → ref }. Collect keys in module-id
        -- sort order so the migration is deterministic across loads.
        local mod_ids = {}
        for mid in pairs(tools_data) do mod_ids[#mod_ids + 1] = mid end
        table.sort(mod_ids)
        for _, mid in ipairs(mod_ids) do
            local ref = tools_data[mid]
            local k = type(ref) == "table" and ref.key or nil
            if type(k) == "string" and k ~= "" and not seen[k] then
                seen[k] = true
                result[#result + 1] = k
            end
        end
    end
    return result
end

--- Update all data fields in place (preserves table identity).
--- Pre-resolved fields (_tool_objects, _config_set_ref) are set by _sync_profiles.
--- @param data loomworks.ProfileDef
function Profile:_apply(data)
    self._configuration_set_name = data.configuration_set
    self._tool_keys = read_tool_keys(data.tools)
    self._sdk_key = data.sdk or nil
    -- SDK domain object resolved during _sync_profiles or set_sdk()
    if data._sdk then
        self._sdk = data._sdk
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
--- Format: `<set>:<sorted-deduped-tool-keys>` joined with `+`.
--- The SDK key is NOT included separately — tool keys carry SDK
--- provenance via their kit_id prefix (e.g. `ninja-clang-18`).
function Profile:_derive_key()
    if not self._configuration_set_name then
        self.key = "unnamed"
        return
    end

    local parts = {}
    local seen = {}
    for _, k in ipairs(self._tool_keys or {}) do
        if not seen[k] then
            seen[k] = true
            parts[#parts + 1] = k
        end
    end
    table.sort(parts)

    if #parts > 0 then
        self.key = self._configuration_set_name .. ":" .. table.concat(parts, "+")
    else
        self.key = self._configuration_set_name
    end

    if self._workspace and self._workspace._core then
        self._workspace._core._deps.log:debug(
            "Profile key derived: '%s' (tool_keys=%s)",
            self.key, vim.inspect(self._tool_keys))
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

--- Find a module domain object by id within the workspace.
--- @param workspace loomworks.Workspace
--- @param mod_type string
--- @return loomworks.Module|nil
local function find_module(workspace, mod_type)
    if not workspace or not workspace._modules then return nil end
    for _, m in pairs(workspace._modules) do
        if m.id == mod_type then return m end
    end
    return nil
end

--- Legacy compat shim: synthesize the per-module `tools` dict from
--- the new `_tool_keys` array. For each key in the array, find every
--- module that has a Tool by that key in its registry; emit one
--- dict entry per (module, key) pair (first key per module wins so
--- the shape matches the historic invariant of "one tool per module
--- type"). Callers should migrate to `Profile:tools_for(configuration)`
--- (language-aware) or read `_tool_keys` directly.
--- @return table<string, loomworks.ToolRef>|nil
function Profile:tools_data()
    if not self._tool_keys or #self._tool_keys == 0 then return nil end
    local ws = self._workspace
    if not ws or not ws._modules then return nil end

    local result = {}
    for _, key in ipairs(self._tool_keys) do
        for _, mod in pairs(ws._modules) do
            if not result[mod.id] then
                local tool = mod:find_tool(key)
                if tool and not tool._removed then
                    result[mod.id] = {
                        key = tool.key,
                        data = tool.data,
                        label = tool.label,
                    }
                end
            end
        end
    end
    return next(result) and result or nil
end

--- Generate a definition suitable for loomworks.json.
--- @return table definition { configuration_set?, tools? }
function Profile:to_config_def()
    local def = {}
    if self._configuration_set_name then
        def.configuration_set = self._configuration_set_name
    end
    if self._tool_keys and #self._tool_keys > 0 then
        def.tools = vim.list_extend({}, self._tool_keys)
    end
    if self._default_target_descriptor then
        def.default_target = self._default_target_descriptor
    end
    return def
end

--- Get the ToolRef for a specific module type. Compatibility shim
--- for callers that haven't moved to the language-aware
--- `tools_for(configuration)` API yet.
---
--- Resolution order:
--- 1. Pre-resolved `_tool_objects` (set by `sync_profiles` during
---    refresh — this is the only path that works mid-refresh, because
---    `workspace._modules` isn't assigned until the refresh finishes).
--- 2. `_tool_keys` against `workspace._modules` — used post-refresh
---    when mutations have happened (e.g. add_tool) and we haven't
---    been through sync_profiles since.
--- 3. SDK-derived materialization for legacy profiles where the SDK
---    is set but no tool key is stored.
--- @param mod_type string module type (e.g. "cmake")
--- @return loomworks.ToolRef|nil
function Profile:tool_for(mod_type)
    if self._tool_objects then
        for mod, tool in pairs(self._tool_objects) do
            if mod.id == mod_type and not tool._removed then
                return { key = tool.key, data = tool.data, label = tool.label }
            end
        end
    end
    local mod = find_module(self._workspace, mod_type)
    if mod then
        for _, key in ipairs(self._tool_keys or {}) do
            local tool = mod:find_tool(key)
            if tool and not tool._removed then
                return { key = tool.key, data = tool.data, label = tool.label }
            end
        end
    end
    return self:_resolve_sdk_tool(mod_type)
end

--- Language-aware resolution. Returns the array of effective Tool
--- objects for a configuration — for each language the configuration
--- needs, the first tool in `_tool_keys` that provides it (resolved
--- against the project's module registry).
--- Languages already covered by an earlier tool aren't re-scanned —
--- one tool can cover multiple languages (`clang` covers c, c++).
--- @param configuration loomworks.Configuration
--- @return loomworks.Tool[] effective tools (ordered; deduped)
function Profile:tools_for(configuration)
    if not configuration then return {} end
    local langs = configuration:effective_languages()
    if #langs == 0 then return {} end
    local mod = configuration._project and configuration._project._module
    if not mod then return {} end

    local result = {}
    local added = {}
    local covered = {}
    for _, key in ipairs(self._tool_keys or {}) do
        local tool = mod:find_tool(key)
        if tool and not tool._removed then
            local covers_some = false
            for _, lang in ipairs(langs) do
                if not covered[lang] and tool:provides_language(lang) then
                    covered[lang] = true
                    covers_some = true
                end
            end
            if covers_some and not added[tool] then
                added[tool] = true
                result[#result + 1] = tool
            end
        end
    end
    return result
end

--- Identify languages required by a configuration that no tool in
--- this profile covers. Returned strings come straight from the
--- configuration's `effective_languages()` — no normalization.
---
--- Shim modules (typescript) declare `languages` for DAP routing
--- but have no build tool to "cover" them — neither `has_keyed_tools`
--- nor `kits_from_sdk`. For those we return no gaps regardless of
--- the configuration's language list: there's nothing the user could
--- pick to satisfy them.
--- @param configuration loomworks.Configuration
--- @return string[] missing
function Profile:missing_languages_for(configuration)
    if not configuration then return {} end
    local mod = configuration._project and configuration._project._module
    if not mod then return {} end

    local needs_tool = mod.has_keyed_tools
        or (mod.impl and mod.impl.kits_from_sdk)
    if not needs_tool then return {} end

    local langs = configuration:effective_languages()
    if #langs == 0 then return {} end

    local covered = {}
    for _, key in ipairs(self._tool_keys or {}) do
        local tool = mod:find_tool(key)
        if tool and not tool._removed then
            for _, lang in ipairs(tool.languages or {}) do
                covered[lang] = true
            end
        end
    end
    local missing = {}
    for _, lang in ipairs(langs) do
        if not covered[lang] then missing[#missing + 1] = lang end
    end
    return missing
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
    -- Implicit cascade on use (specification.md §2.4): activating a
    -- profile materializes it and the items it transitively references
    -- into the working copy.
    self:_mark_user_owned()
    if self._config_set_ref then
        self._config_set_ref:_mark_user_owned()
        for project, cfg in pairs(self._config_set_ref.mappings or {}) do
            project:_mark_user_owned()
            if cfg and cfg._mark_user_owned then
                cfg:_mark_user_owned()
            end
        end
    end
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
--- Refuses to start when the profile is incomplete — the build
--- chain otherwise runs with nil tool_data and produces malformed
--- on-disk artefacts. Module-agnostic via Profile:assert_buildable.
--- @return loomworks.Future
function Profile:build(opts)
    local ok, err = self:assert_buildable()
    if not ok then
        return require("loomworks.future").rejected(err)
    end
    return require("loomworks.overseer").run_profile_action(self, "build", opts)
end

--- Configure all projects in this profile via overseer.
--- Same buildability gate as Profile:build — running configure on
--- an incomplete profile is what produces the malformed build dirs
--- in the first place (the artefacts are created by configure, not
--- build).
--- @return loomworks.Future
function Profile:configure()
    local ok, err = self:assert_buildable()
    if not ok then
        return require("loomworks.future").rejected(err)
    end
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
    -- Need a target (module target), launch config name, or device target
    if not descriptor.target and not descriptor.launch and not descriptor.device_target then
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

--- Set the default target descriptor directly.
--- Used for non-standard descriptors like device targets.
--- @param descriptor table
function Profile:set_default_target_descriptor(descriptor)
    self._default_target_descriptor = descriptor
    self._workspace:_save_user()
end

-- ---------------------------------------------------------------------------
-- Device selection
-- ---------------------------------------------------------------------------

--- Get the selected device serial for this profile.
--- @return string|nil
function Profile:device_serial()
    return self._device_serial
end

--- Set the selected device for this profile.
--- @param serial string device serial
function Profile:set_device(serial)
    self._device_serial = serial
    self._workspace:_save_user()
end

--- Clear the selected device for this profile.
function Profile:clear_device()
    self._device_serial = nil
    self._workspace:_save_user()
end

--- Get the Device domain object for the selected device serial.
--- Returns nil if no device is selected or the device is not in the registry.
--- @return loomworks.Device|nil
function Profile:device()
    if not self._device_serial then return nil end
    return self._workspace:find_device(self._device_serial)
end

--- Does this profile contain a project from a device-capable module?
--- Used to gate the Device line in the UI per-profile (rather than
--- per-workspace), so a multi-module workspace doesn't surface
--- a meaningless Device row under its cmake profile.
--- @return boolean
function Profile:has_device_module()
    for _, pp in ipairs(self:projects()) do
        local project = pp._project
        if project and project._module
                and project._module.impl
                and project._module.impl.has_devices then
            return true
        end
    end
    return false
end

--- Emit `profile_renamed` so listeners (e.g. the status tree) can
--- migrate string-keyed UI state (fold keys, jumplist marks) tied
--- to the previous key. The active-profile and other workspace
--- references are object pointers — they stay valid across the
--- key change without our intervention; `_save_user` and `remerge`
--- read the live `_active_profile.key` directly.
--- @param old_key string|nil
function Profile:_after_key_rename(old_key)
    if not old_key or old_key == self.key then return end
    local ws = self._workspace
    if not ws then return end
    if ws._core and ws._core._deps and ws._core._deps.events then
        ws._core._deps.events.emit("profile_renamed", {
            old_key = old_key, new_key = self.key,
        })
    end
end

--- Append a tool key to the profile's tool list. No-op if already
--- present (the list is deduplicated). Re-derives the profile key
--- and signals the rename so UI fold state and active-profile state
--- track the new identity.
--- @param tool_key string
function Profile:add_tool(tool_key)
    if not tool_key or tool_key == "" then return end
    self._tool_keys = self._tool_keys or {}
    for _, k in ipairs(self._tool_keys) do
        if k == tool_key then return end
    end
    local old_key = self.key
    self._tool_keys[#self._tool_keys + 1] = tool_key
    self:_derive_key()
    self:_after_key_rename(old_key)
end

--- Remove a tool key from the profile's tool list. No-op if absent.
--- Re-derives the profile key.
--- @param tool_key string
function Profile:remove_tool(tool_key)
    if not tool_key or not self._tool_keys then return end
    local kept = {}
    local found = false
    for _, k in ipairs(self._tool_keys) do
        if k ~= tool_key then kept[#kept + 1] = k else found = true end
    end
    if not found then return end
    local old_key = self.key
    self._tool_keys = #kept > 0 and kept or {}
    -- Re-derive SDK key from remaining tools (first tool with sdk_key wins).
    local new_sdk_key, new_sdk = nil, nil
    for _, k in ipairs(self._tool_keys) do
        local ws = self._workspace
        if ws and ws._modules then
            for _, mod in pairs(ws._modules) do
                local tool = mod:find_tool(k)
                if tool and tool.data and tool.data.sdk_key then
                    new_sdk_key = tool.data.sdk_key
                    new_sdk = ws:find_sdk(new_sdk_key)
                    break
                end
            end
            if new_sdk_key then break end
        end
    end
    self._sdk = new_sdk
    self._sdk_key = new_sdk_key
    self:_derive_key()
    self:_after_key_rename(old_key)
end

--- Describe the profile's current toolchain selection as a list of
--- entries the UI can render. Returns one entry per key in
--- `_tool_keys`, each annotated with what the registry knows about
--- the tool. Unresolved keys (registry doesn't have them) are still
--- reported so the UI can surface them as broken references rather
--- than hide them.
--- @return { key: string, label: string, languages: string[], resolved: boolean }[]
function Profile:toolchain_entries()
    local entries = {}
    local ws = self._workspace
    for _, key in ipairs(self._tool_keys or {}) do
        local label, languages, resolved = key, {}, false
        if ws and ws._modules then
            for _, mod in pairs(ws._modules) do
                local tool = mod:find_tool(key)
                if tool and not tool._removed then
                    label = tool.label or tool.key or key
                    languages = tool.languages or {}
                    resolved = true
                    break
                end
            end
        end
        entries[#entries + 1] = {
            key = key,
            label = label,
            languages = languages,
            resolved = resolved,
        }
    end
    return entries
end

--- Enumerate the unique Modules in this profile that need a tool/SDK
--- selection (keyed-tool modules and/or SDK-consuming modules). Modules
--- that don't carry a toolchain concept (typescript shim) are excluded.
--- Used by the Toolchain section in the UI.
--- @return loomworks.Module[]
function Profile:tool_needing_modules()
    local seen = {}
    local result = {}
    for _, pp in ipairs(self:projects()) do
        local project = pp._project
        if project and project._module then
            local mod = project._module
            local needs = mod.has_keyed_tools
                or (mod.impl and mod.impl.kits_from_sdk)
            if needs and not seen[mod] then
                seen[mod] = true
                result[#result + 1] = mod
            end
        end
    end
    return result
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
--- A profile is incomplete when:
--- * any of its projects' configurations declares a language no tool
---   in `_tool_keys` provides (the canonical language-keyed check), OR
--- * a project's module needs a tool but no entry in `_tool_keys`
---   resolves under that module's registry. This second check
---   handles modules that haven't declared `languages` yet or
---   profiles whose configurations aren't resolved yet — the
---   pre-language fallback that keeps existing tests passing.
--- @return boolean
function Profile:is_complete()
    if #self:language_gaps() > 0 then return false end
    for _, pp in ipairs(self:projects()) do
        local project = pp._project
        local cfg = pp._configuration
        local langs_known = cfg and not cfg._removed
            and #cfg:effective_languages() > 0
        if not langs_known and project and project._module then
            local mod = project._module
            local needs_tools = mod.has_keyed_tools
                or (mod.impl and mod.impl.kits_from_sdk)
            if needs_tools and not self:tool_for(project.type) then
                return false
            end
        end
    end
    return true
end

--- Enumerate missing-language gaps across the profile's
--- (project, configuration) pairs. Returns a list of
--- `{ project, configuration, languages }` entries — one per
--- configuration that needs languages not covered by `_tool_keys`.
--- Empty list means the profile is language-complete.
--- @return { project: loomworks.Project, configuration: loomworks.Configuration, languages: string[] }[]
function Profile:language_gaps()
    local gaps = {}
    for _, pp in ipairs(self:projects()) do
        local cfg = pp._configuration
        if cfg and not cfg._removed then
            local missing = self:missing_languages_for(cfg)
            if #missing > 0 then
                gaps[#gaps + 1] = {
                    project = pp._project,
                    configuration = cfg,
                    languages = missing,
                }
            end
        end
    end
    return gaps
end

--- List tools in `_tool_keys` that no configuration in this profile
--- needs. Non-blocking — purely informational, but lets the
--- diagnostics surface flag dead weight to the user. Tools whose
--- registry entry is unresolved are skipped (they get their own
--- "unresolved tool" diagnostic via `toolchain_entries()`).
--- @return string[] tool keys
function Profile:unused_tools()
    local ws = self._workspace
    if not ws then return {} end

    -- Gather every language used across the profile's configurations.
    local used = {}
    for _, pp in ipairs(self:projects()) do
        local cfg = pp._configuration
        if cfg and not cfg._removed then
            for _, lang in ipairs(cfg:effective_languages()) do
                used[lang] = true
            end
        end
    end

    local unused = {}
    for _, key in ipairs(self._tool_keys or {}) do
        local covers_used = false
        if ws._modules then
            for _, mod in pairs(ws._modules) do
                local tool = mod:find_tool(key)
                if tool and not tool._removed then
                    for _, lang in ipairs(tool.languages or {}) do
                        if used[lang] then
                            covers_used = true
                            break
                        end
                    end
                    if covers_used then break end
                end
            end
        end
        if not covers_used then unused[#unused + 1] = key end
    end
    return unused
end

--- Validity gate. Returns `(ok, reasons)`. A profile is invalid
--- when:
---   * is_complete() returns false (some project's module needs a
---     tool/SDK that isn't resolved).
---   * any of its referenced configurations are themselves invalid
---     (source-missing stub, etc.) — the profile would fail mid-
---     build with a confusing message.
---   * its configuration_set (if pinned) is invalid.
---
--- Operation methods (`:build`, `:configure`) refuse to run when
--- not valid, surfacing the reasons.
--- @return boolean ok, string[] reasons
function Profile:is_valid()
    local reasons = {}
    if self._removed then
        reasons[#reasons + 1] = "profile was removed from the registry"
        return false, reasons
    end

    -- Language-coverage gaps: per-configuration missing-language
    -- diagnostic (the canonical check when modules declare
    -- `languages` and configurations resolve).
    for _, gap in ipairs(self:language_gaps()) do
        local pk = gap.project and gap.project.key or "?"
        local cn = gap.configuration and gap.configuration.name or "?"
        reasons[#reasons + 1] = "incomplete — no tool provides "
            .. table.concat(gap.languages, ", ")
            .. " for " .. pk .. "/" .. cn
    end

    -- Legacy fallback: a project's module needs a tool but no
    -- entry in `_tool_keys` resolves there. Only fires for
    -- projects whose configuration didn't contribute languages
    -- (configuration unresolved or module hasn't declared
    -- `languages` yet), so it doesn't double-report with the
    -- language-gap check above.
    local legacy_missing = {}
    for _, pp in ipairs(self:projects()) do
        local project = pp._project
        local cfg = pp._configuration
        local langs_known = cfg and not cfg._removed
            and #cfg:effective_languages() > 0
        if not langs_known and project and project._module then
            local mod = project._module
            local needs_tools = mod.has_keyed_tools
                or (mod.impl and mod.impl.kits_from_sdk)
            if needs_tools and not self:tool_for(project.type) then
                legacy_missing[#legacy_missing + 1] = project.key or "?"
            end
        end
    end
    if #legacy_missing > 0 then
        reasons[#reasons + 1] = "incomplete — no tool/SDK selected for: "
            .. table.concat(legacy_missing, ", ")
    end

    -- Referenced ConfigurationSet validity
    if self._config_set_ref and self._config_set_ref.is_valid then
        local set_ok, set_reasons = self._config_set_ref:is_valid()
        if not set_ok then
            reasons[#reasons + 1] = "configuration set '"
                .. self._config_set_ref.name .. "': "
                .. table.concat(set_reasons, "; ")
        end
    end
    return #reasons == 0, reasons
end

--- Return a structural diagnostic for this profile, or nil when
--- valid. Thin formatter on top of `:is_valid()`.
--- @return loomworks.Diagnostic|nil
function Profile:diagnostic()
    local ok, reasons = self:is_valid()
    if ok then return nil end
    return {
        severity = "warn",
        source = "Profile/" .. self.key,
        message = "profile '" .. self.key .. "' is invalid: "
            .. table.concat(reasons, "; "),
        target_fold_key = "profile:" .. self.key,
    }
end

--- Buildability gate: refuse to start configure/build/launch/debug
--- on an invalid profile. Now folds into `:is_valid()` — that
--- predicate covers both incompleteness (no tool/SDK) and stale
--- references (invalid configurations / config set). Single check
--- before the build chain runs.
---
--- Kept as a separate method so the (boolean, single-string)
--- shape stays usable from call sites that just want "go / no-go
--- + reason". Internally collapses the reasons list into one
--- newline-separated message.
--- @return boolean ok, string|nil err human-readable reason
function Profile:assert_buildable()
    local ok, reasons = self:is_valid()
    if ok then return true end
    return false, "profile '" .. self.key
        .. "' is not buildable: " .. table.concat(reasons, "; ")
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
