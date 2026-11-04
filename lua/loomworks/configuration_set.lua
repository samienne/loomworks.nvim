--- loomworks/configuration_set.lua — ConfigurationSet object.
--- Represents a named mapping of projects to configuration variants.
--- Owns activation via find_profile() + activate().

local description_mod = require("loomworks.description")

--- @class loomworks.ConfigurationSet
--- @field name string configuration set name
--- @field mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration object
--- @field description string|nil normalised description (spec §1.10); stored in
---        the `configuration_set_descriptions` sidecar of the file the set lives in
--- @field _description_invalid any a non-string sidecar value, ignored but
---        written back unchanged until the description is set or cleared
--- @field _workspace loomworks.Workspace back-reference
--- @field _removed boolean
--- @field _source "user"|"shared" provenance: "user" = from user.json, "shared" = from loomworks.json
--- @field _intent? "local"|"shared"|"local+shared" intended publish state; nil before data_model.refresh's first sync
--- @field _removed_upstream? boolean transient session flag — was in old baseline but not in new
local ConfigurationSet = {}
ConfigurationSet.__index = ConfigurationSet

--- Create a new ConfigurationSet.
--- @param workspace loomworks.Workspace
--- @param name string
--- @param resolved_mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration (pre-resolved)
--- @param description_value? any the set's sidecar entry, as read
--- @return loomworks.ConfigurationSet
function ConfigurationSet.new(workspace, name, resolved_mappings, description_value)
    local self = setmetatable({}, ConfigurationSet)
    self._workspace = workspace
    self.name = name
    self._removed = false
    self._source = "shared"
    -- _intent left nil; data_model.refresh assigns and then sticks. Mutation
    -- methods set it explicitly.
    self._intent = nil
    self:_update(resolved_mappings, description_value)
    return self
end

--- Mark this configuration set as in the user.json working copy.
--- Called when any mutation is about to write to user.json. Implements
--- the implicit cascade rule: using a `shared` item materializes it into
--- the working copy with intent local+shared.
function ConfigurationSet:_mark_user_owned()
    if self._intent == "shared" then
        self._intent = "local+shared"
    elseif self._intent == nil then
        self._intent = "local"
    end
    if self._source == "shared" then
        self._source = "user"
    end
end

--- Update mappings in place (preserves table identity).
--- Receives pre-resolved { Project -> Configuration } from _sync_config_sets,
--- and the set's `configuration_set_descriptions` sidecar entry.
--- @param resolved_mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration
--- @param description_value? any sidecar entry as read (normalised here)
function ConfigurationSet:_update(resolved_mappings, description_value)
    self.mappings = resolved_mappings or {}
    self.description, self._description_invalid = description_mod.from_file(description_value)
end

--- The value to write to the sidecar for this set: the description, or a
--- preserved non-string value (spec §1.10), or nil (no entry).
--- @return any
function ConfigurationSet:description_for_file()
    if self.description ~= nil then return self.description end
    return self._description_invalid
end

--- Set or clear (nil / blank) the set's description (spec §1.10). Editing is
--- use: a `shared` set is materialised into the working copy (implicit
--- cascade). Writes nothing when the normalised text is unchanged.
--- @param text string|nil
--- @return boolean|nil changed true when saved, false when unchanged, nil on refusal
--- @return string|nil err
function ConfigurationSet:set_description(text)
    local ws = self._workspace
    if self._removed then
        return nil, "configuration set '" .. self.name .. "' not found"
    end
    local ok, value, err = description_mod.prepare(text)
    if not ok then return nil, err end
    if value == self.description and self._description_invalid == nil then
        return false
    end
    local old, old_invalid = self.description, self._description_invalid
    local old_intent, old_source = self._intent, self._source
    self:_mark_user_owned()
    self.description, self._description_invalid = value, nil
    local saved, save_err = ws:_save_user()
    if not saved then
        self.description, self._description_invalid = old, old_invalid
        self._intent, self._source = old_intent, old_source
        return nil, save_err
    end
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

function ConfigurationSet:__tostring()
    return "ConfigurationSet(" .. self.name .. ")"
end

--- Get the variant name for a project in this set.
--- @param project loomworks.Project
--- @return string|nil
function ConfigurationSet:variant(project)
    local cfg = self.mappings[project]
    return cfg and cfg.name or nil
end

--- Get the Configuration object for a project in this set.
--- @param project loomworks.Project
--- @return loomworks.Configuration|nil
function ConfigurationSet:configuration(project)
    local cfg = self.mappings[project]
    return cfg and not cfg._removed and cfg or nil
end

--- Return raw mappings (project_key → variant) for serialization.
--- @return table<string, string>
function ConfigurationSet:raw_mappings()
    local raw = {}
    for project, config in pairs(self.mappings) do
        raw[project.key] = config.name
    end
    return raw
end

--- Validity gate. Returns `(ok, reasons)`. A configuration set
--- is invalid when any of its mappings reference a config that's
--- itself invalid (source-missing stub, removed, unresolved
--- inherits) — operations driven by the set won't have a usable
--- destination.
---
--- The set's own structural integrity (mappings dict exists,
--- not _removed) is also checked.
--- @return boolean ok, string[] reasons
function ConfigurationSet:is_valid()
    local reasons = {}
    if self._removed then
        reasons[#reasons + 1] = "configuration set was removed from the registry"
        return false, reasons
    end
    local stale = {}
    for project, config in pairs(self.mappings) do
        if config._source_missing or config._removed then
            stale[#stale + 1] = project.key .. " → " .. config.name
        end
    end
    if #stale > 0 then
        table.sort(stale)
        reasons[#reasons + 1] = "stale mappings: " .. table.concat(stale, "; ")
            .. " — fix the references in loomworks.json or user.json"
    end
    return #reasons == 0, reasons
end

--- Return a structural diagnostic for this configuration set, or
--- nil when valid. Thin formatter on top of `:is_valid()`. Set-side
--- view of stale mappings — the per-Configuration `:diagnostic()`
--- gives the project-side view for the same condition.
--- @return loomworks.Diagnostic|nil
function ConfigurationSet:diagnostic()
    if self._removed then return nil end
    local ok, reasons = self:is_valid()
    if ok then return nil end
    return {
        severity = "warn",
        source = "ConfigurationSet/" .. self.name,
        message = "configuration set '" .. self.name
            .. "' is invalid: " .. table.concat(reasons, "; "),
        target_fold_key = "set:" .. self.name,
    }
end

--- Update a single project mapping in this configuration set.
--- @param project loomworks.Project
--- @param configuration loomworks.Configuration|nil Configuration object (nil to remove mapping)
--- @return boolean ok, string|nil err
function ConfigurationSet:update_mapping(project, configuration)
    local ws = self._workspace
    if self._removed then
        return false, "configuration set '" .. self.name .. "' not found"
    end

    local old = self.mappings[project]
    self.mappings[project] = configuration
    -- Implicit cascade on use: editing a set's mapping materializes the set,
    -- the project, and the new config.
    self:_mark_user_owned()
    project:_mark_user_owned()
    if configuration and configuration._mark_user_owned then
        configuration:_mark_user_owned()
    end

    -- A change that would refuse another configuration's build directory is
    -- refused, writing nothing (spec §1.7 "Commands refuse to create one").
    local ok, err = false, ws:_new_build_dir_collision()
    if not err then ok, err = ws:_save_user() end
    if not ok then
        self.mappings[project] = old
        return false, err
    end

    -- Rebuild PPs for profiles that reference this config set
    for _, profile in pairs(ws._profiles) do
        if profile._config_set_ref == self then
            -- Re-derive mappings from the updated config set
            profile.mappings, profile.orphaned_set = profile:_resolve_mappings({
                configuration_set = profile._configuration_set_name,
            })
            ws:_rebuild_profile_projects_for(profile)
        end
    end

    -- GC: if the OLD mapping was a source-missing stub and nothing
    -- else references it now, drop it from the project's
    -- _configurations array. Without this the stub lingered until
    -- the next full remerge (file change / restart) — keeping the
    -- project's config list cluttered and the diagnostic firing
    -- after the user already fixed the mapping.
    if old and old ~= configuration and old._source_missing then
        local still_referenced = false
        for _, cs in pairs(ws._config_sets) do
            if not cs._removed
                and cs.mappings
                and cs.mappings[project] == old then
                still_referenced = true
                break
            end
        end
        if not still_referenced then
            for _, cfg in ipairs(project._configurations) do
                if cfg ~= old and not cfg._removed then
                    for _, n in ipairs(cfg.inherits_names or {}) do
                        if n == old.name then
                            still_referenced = true
                            break
                        end
                    end
                    if still_referenced then break end
                end
            end
        end
        if not still_referenced then
            old._removed = true
            for i, cfg in ipairs(project._configurations) do
                if cfg == old then
                    table.remove(project._configurations, i)
                    break
                end
            end
        end
    end

    ws:_sync_build_dir_refs()
    ws:_resolve_active_profile()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Whether tool data `a` and `b` of module type `mod_type` are the same
--- toolchain (the module's `tools_match`, else identity).
--- @param ws loomworks.Workspace
--- @param mod_type string
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function same_tool(ws, mod_type, a, b)
    local mod = ws:find_module(mod_type)
    local impl = mod and mod.impl or nil
    if impl and impl.tools_match then return impl.tools_match(a, b) and true or false end
    return a == b
end

--- Find a profile in the registry matching this set + tool properties.
--- Uses property-based matching, never key computation. An SDK's entry
--- matches the profile whose toolchains are exactly its kit toolchains
--- (`sdk_tools`, spec §1.6).
--- @param tool_entry? loomworks.ToolEntry
--- @return loomworks.Profile|nil
function ConfigurationSet:find_profile(tool_entry)
    local ws = self._workspace
    local tool_data = tool_entry and tool_entry.tool_data or nil
    local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil
    local sdk = tool_entry and tool_entry.sdk or nil
    local sdk_tools = sdk and tool_entry.sdk_tools or nil
    local kit_count = 0
    for _ in pairs(sdk_tools or {}) do kit_count = kit_count + 1 end
    for _, profile in pairs(ws._profiles) do
        if profile._configuration_set_name == self.name then
            local profile_tools = profile:tools_data()
            -- SDK matching: every kit, and nothing else
            if sdk then
                if kit_count > 0 and profile_tools and #(profile._tool_keys or {}) == kit_count then
                    local all = true
                    for mod_type, kit in pairs(sdk_tools) do
                        local pt = profile_tools[mod_type]
                        if not (pt and same_tool(ws, mod_type, pt.data, kit.data)) then
                            all = false
                            break
                        end
                    end
                    if all then return profile end
                end
                goto next
            end
            -- No-SDK matching (host tools)
            if profile._sdk then goto next end
            if not tool_data and not profile_tools and #(profile._tool_keys or {}) == 0 then
                return profile
            end
            if tool_mod_type and profile_tools then
                local profile_tool = profile_tools[tool_mod_type]
                if profile_tool and same_tool(ws, tool_mod_type, profile_tool.data, tool_data) then
                    return profile
                end
            end
        end
        ::next::
    end
    return nil
end

--- Ensure a profile exists for this configuration set + tool, materializing if needed.
--- Does NOT activate the profile. A new profile whose configurations would
--- take a build directory another configuration keeps is refused (spec §1.7
--- "Commands refuse to create one"): it is not added, no unit is
--- materialized, and the refusal is returned.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
--- @return string|nil err the refusal, when the profile was not made
function ConfigurationSet:ensure_profile(tool_entry)
    if not self._workspace then
        return nil
    end

    -- Find matching profile
    local profile = self:find_profile(tool_entry)
    if not profile then
        -- Create a new pinned profile for this config set + tool combination.
        local Profile = require("loomworks.profile").Profile

        -- The entry's toolchains by module type: a host tool's, or an SDK's
        -- kit toolchains — stored as tool keys, which carry the SDK (spec
        -- §1.6), so the profile keeps it across a reload.
        local tools = require("loomworks.workspace").tool_entry_tools(tool_entry)
        -- The SDK is the entry's (`_sdk`); its tool keys carry it.
        local sdk = tool_entry and tool_entry.sdk or nil

        local data = {
            configuration_set = self.name,
            tools = tools,
            _sdk = sdk,
        }

        -- Resolve references for _apply
        data._config_set_ref = self
        if tools then
            local tool_objs = {}
            for mod_type, tool_ref in pairs(tools) do
                local mod = self._workspace:find_module(mod_type)
                if mod then
                    local tool = mod:find_tool(tool_ref.key)
                    if tool then tool_objs[mod] = tool end
                end
            end
            if next(tool_objs) then data._tool_objects = tool_objs end
        end

        profile = Profile.new(self._workspace, data)
        self._workspace._profiles[#self._workspace._profiles + 1] = profile
        -- Checked with the profile in the model, before any unit exists.
        local collision = self._workspace:_new_build_dir_collision(profile)
        if collision then
            self._workspace:_remove_profile(profile)
            return nil, collision
        end
    end

    -- Materialize: ensures skeleton ConfigUnits exist. After the profile is
    -- in the model, so a configuration it refuses a build directory (§1.7)
    -- gets no unit.
    self._workspace:_materialize_from_data(self, tool_entry)
    self._workspace:_rebuild_profile_projects_for(profile)
    return profile
end

--- Activate this configuration set, optionally with a tool.
--- Materializes the profile if it doesn't exist yet.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
--- @return string|nil err the refusal, when no profile was made (`ensure_profile`)
function ConfigurationSet:activate(tool_entry)
    local profile, err = self:ensure_profile(tool_entry)
    if profile then
        profile:activate()
    end
    return profile, err
end

return ConfigurationSet
