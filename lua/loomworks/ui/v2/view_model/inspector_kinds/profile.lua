--- loomworks/ui/v2/view_model/inspector_kinds/profile.lua
---
--- Build the profile inspector content (read-only in this slice).

local M = {}

--- @param workspace loomworks.Workspace
--- @param key string
--- @return loomworks.Profile|nil
local function find_profile(workspace, key)
    if not workspace or not workspace._profiles then return nil end
    for _, p in pairs(workspace._profiles) do
        if p.key == key then return p end
    end
    return nil
end

--- @param profile loomworks.Profile
--- @return table[]
local function mappings_block(profile)
    local out = {}
    for _, pp in ipairs(profile:projects()) do
        local pkey = pp:project_key()
        local variant = pp:variant_name()
        out[#out + 1] = {
            project_key = pkey,
            variant     = variant,
            state       = pp:status(),
            running     = pp:running_action(),
            -- Drill targets:
            project_ref = { kind = "project", key = pkey },
            config_ref  = variant and {
                kind = "configuration", project_key = pkey, config_name = variant,
            } or nil,
        }
    end
    return out
end

--- @param profile loomworks.Profile
--- @return table|nil
local function tools_block(profile)
    local data = profile:tools_data()
    if not data then return nil end
    local out = {}
    for mod_type, ref in pairs(data) do
        out[#out + 1] = {
            module = mod_type,
            key    = ref and ref.key or nil,
            label  = ref and ref.label or nil,
        }
    end
    table.sort(out, function(a, b) return a.module < b.module end)
    return out
end

--- @param profile loomworks.Profile
--- @return string|nil
local function device_serial(profile)
    return profile._device_serial
end

--- Sorted list of device serials in the workspace, prefixed with "(none)"
--- so the user can clear the selection.
--- @param workspace loomworks.Workspace
--- @return string[]
local function device_serial_choices(workspace)
    local out = { "(none)" }
    for _, d in ipairs(workspace:devices() or {}) do
        out[#out + 1] = d.serial
    end
    return out
end

--- All "project.launch" pairs reachable from a profile's project mappings.
--- @param profile loomworks.Profile
--- @return string[]
local function default_target_choices(profile)
    local out = { "(none)" }
    for _, pp in ipairs(profile:projects()) do
        local proj = pp._project
        if proj then
            local launches = proj._launch_configs or proj.launch
            if type(launches) == "table" then
                for name, _ in pairs(launches) do
                    out[#out + 1] = proj.key .. "." .. name
                end
            end
        end
    end
    table.sort(out)
    return out
end

--- Render the current default_target descriptor as a "project.launch" string.
--- @param profile loomworks.Profile
--- @return string
local function default_target_display(profile)
    local d = profile._default_target_descriptor
    if not d or not d.project then return "(none)" end
    if d.launch then return d.project .. "." .. d.launch end
    if d.target then return d.project .. "/" .. d.target end
    return "(none)"
end

--- Build the profile inspector content.
--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "profile", key: string }
--- @return table
function M.build(workspace, ref)
    local key = ref.key
    local profile = find_profile(workspace, key)
    if not profile then
        return {
            kind    = "profile",
            subject = key,
            missing = true,
            hint_bar = {},
        }
    end

    local label, _ = profile:status()
    local subject_ref = { kind = "profile", key = profile.key }
    local has_device_modules = workspace.has_device_modules and workspace:has_device_modules() or false
    local editable_fields = {
        {
            id      = "default_target",
            label   = "Default target",
            value   = default_target_display(profile),
            kind    = "picker",
            choices = default_target_choices(profile),
            subject = {
                kind        = "profile_default_target",
                profile_key = profile.key,
            },
        },
    }
    if has_device_modules then
        editable_fields[#editable_fields + 1] = {
            id      = "device_serial",
            label   = "Device",
            value   = profile._device_serial or "",
            kind    = "picker",
            choices = device_serial_choices(workspace),
            subject = {
                kind        = "profile_device",
                profile_key = profile.key,
            },
        }
    end
    return {
        kind            = "profile",
        subject         = profile.key,
        missing         = false,
        is_active       = workspace._active_profile == profile,
        configuration_set = profile._configuration_set_name,
        orphaned_set    = profile.orphaned_set == true,
        status_label    = label,
        running         = profile:is_running(),
        tools           = tools_block(profile),
        mappings        = mappings_block(profile),
        device_serial   = device_serial(profile),
        device_editable = has_device_modules,
        default_target_label = default_target_display(profile),
        editable_fields = editable_fields,
        intent          = profile._intent or "local",
        publishable     = true,
        hint_bar        = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
