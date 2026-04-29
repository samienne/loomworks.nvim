--- loomworks/ui/v2/view_model/inspector_kinds/config_set.lua
---
--- Read-only configuration-set inspector. Shows the set name and its
--- mappings (project → configuration). Identifies whether any profile
--- references this set.

local M = {}

--- @param workspace loomworks.Workspace
--- @param name string
--- @return loomworks.ConfigurationSet|nil
local function find_set(workspace, name)
    if not workspace or not workspace._config_sets then return nil end
    for _, cs in pairs(workspace._config_sets) do
        if cs.name == name then return cs end
    end
    return nil
end

--- @param workspace loomworks.Workspace
--- @param cs loomworks.ConfigurationSet
--- @return string[]
local function profiles_using(workspace, cs)
    local out = {}
    for _, p in pairs(workspace._profiles or {}) do
        if p._configuration_set_name == cs.name then
            out[#out + 1] = p.key
        end
    end
    table.sort(out)
    return out
end

--- @param project loomworks.Project
--- @return string[]
local function project_configuration_names(project)
    local out = {}
    for _, cfg in ipairs(project:get_configurations() or {}) do
        out[#out + 1] = cfg.name
    end
    table.sort(out)
    return out
end

--- @param cs loomworks.ConfigurationSet
--- @return table[]
local function mappings_block(cs)
    local out = {}
    for project, config in pairs(cs.mappings or {}) do
        out[#out + 1] = {
            project_key  = project.key,
            variant_name = config and config.name or nil,
            config_ref   = config and {
                kind = "configuration",
                project_key = project.key,
                config_name = config.name,
            } or nil,
            edit = {
                id      = "mapping:" .. project.key,
                label   = project.key,
                value   = config and config.name or "",
                kind    = "picker",
                choices = project_configuration_names(project),
                subject = {
                    kind        = "config_set_mapping",
                    set_name    = cs.name,
                    project_key = project.key,
                },
            },
        }
    end
    table.sort(out, function(a, b) return a.project_key < b.project_key end)
    return out
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "config_set", key: string }
--- @return table
function M.build(workspace, ref)
    local cs = find_set(workspace, ref.key)
    if not cs then
        return {
            kind     = "config_set",
            subject  = ref.key,
            missing  = true,
            hint_bar = {},
        }
    end
    local subject_ref = { kind = "config_set", key = cs.name }
    return {
        kind         = "config_set",
        subject      = cs.name,
        missing      = false,
        mappings     = mappings_block(cs),
        used_by      = profiles_using(workspace, cs),
        intent       = cs._intent or "local",
        publishable  = true,
        add_actions  = {
            mapping = {
                kind   = "config_set_mapping",
                parent = subject_ref,
                label  = "+ Add mapping",
            },
        },
        hint_bar     = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
