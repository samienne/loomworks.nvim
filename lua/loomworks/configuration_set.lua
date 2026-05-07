--- loomworks/configuration_set.lua — ConfigurationSet object.
--- Represents a named mapping of projects to configuration variants.
--- Owns activation: find_profile() + activate() replace Core:activate_new_profile.

--- @class loomworks.ConfigurationSet
--- @field name string configuration set name
--- @field mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration object
--- @field _source "user"|"shared" provenance: "user" = from user.json, "shared" = from loomworks.json
--- @field _intent? "local"|"shared"|"local+shared" intended publish state; nil before data_model.refresh's first sync
--- @field _removed_upstream? boolean transient session flag — was in old baseline but not in new
local ConfigurationSet = {}
ConfigurationSet.__index = ConfigurationSet

--- Create a new ConfigurationSet.
--- @param workspace loomworks.Workspace
--- @param name string
--- @param resolved_mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration (pre-resolved)
--- @return loomworks.ConfigurationSet
function ConfigurationSet.new(workspace, name, resolved_mappings)
    local self = setmetatable({}, ConfigurationSet)
    self._workspace = workspace
    self.name = name
    self._removed = false
    self._source = "shared"
    -- _intent left nil; data_model.refresh assigns and then sticks
    -- (specification.md §2.4). Mutation methods set it explicitly.
    self._intent = nil
    self:_update(resolved_mappings)
    return self
end

--- Mark this configuration set as in the user.json working copy.
--- Called when any mutation is about to write to user.json. Implements
--- the implicit cascade rule (specification.md §2.4): using a `shared`
--- item materializes it into the working copy with intent local+shared.
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
--- Receives pre-resolved { Project -> Configuration } from _sync_config_sets.
--- @param resolved_mappings table<loomworks.Project, loomworks.Configuration> project -> Configuration
function ConfigurationSet:_update(resolved_mappings)
    self.mappings = resolved_mappings or {}
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
    -- Implicit cascade on use (specification.md §2.4): editing a set's
    -- mapping materializes the set, the project, and the new config.
    self:_mark_user_owned()
    project:_mark_user_owned()
    if configuration and configuration._mark_user_owned then
        configuration:_mark_user_owned()
    end

    local ok, err = ws:_save_user()
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
    ws:_sync_build_dir_refs()
    ws:_resolve_active_profile()
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

--- Find a profile in the registry matching this set + tool properties.
--- Uses property-based matching, never key computation.
--- @param tool_entry? { tool_key: string, tool_data: table, tool_label: string, tool_mod_type: string }
--- @return loomworks.Profile|nil
function ConfigurationSet:find_profile(tool_entry)
    local tool_data = tool_entry and tool_entry.tool_data or nil
    local tool_mod_type = tool_entry and tool_entry.tool_mod_type or nil
    local sdk = tool_entry and tool_entry.sdk or nil
    for _, profile in pairs(self._workspace._profiles) do
        if profile._configuration_set_name == self.name then
            -- SDK matching
            if sdk then
                if profile._sdk and profile._sdk.key == sdk.key then
                    return profile
                end
                goto next
            end
            -- No-SDK matching (host tools)
            if profile._sdk then goto next end
            local profile_tools = profile:tools_data()
            if not tool_data and not profile_tools then
                return profile
            end
            if tool_mod_type and profile_tools then
                local profile_tool = profile_tools[tool_mod_type]
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
        ::next::
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

    -- Materialize: ensures skeleton ConfigUnits exist
    self._workspace:_materialize_from_data(self, tool_entry)

    -- Find matching profile
    local profile = self:find_profile(tool_entry)
    if not profile then
        -- Create a new pinned profile for this config set + tool combination
        local Profile = require("loomworks.profile").Profile

        -- Build tools dict and SDK from tool_entry
        local tools = nil
        local sdk = nil
        local sdk_key = nil
        if tool_entry and tool_entry.sdk then
            -- SDK-based profile: tools derived from SDK at runtime
            sdk = tool_entry.sdk
            sdk_key = sdk.key
        elseif tool_entry and tool_entry.tool_key then
            -- Host tool-based profile
            local mod_type = tool_entry.tool_mod_type
            tools = {
                [mod_type] = {
                    key = tool_entry.tool_key,
                    data = tool_entry.tool_data,
                    label = tool_entry.tool_label,
                },
            }
        end

        local data = {
            configuration_set = self.name,
            tools = tools,
            sdk = sdk_key,
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
        self._workspace:_rebuild_profile_projects_for(profile)
    end
    return profile
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
