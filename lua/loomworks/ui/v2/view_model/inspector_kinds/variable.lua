--- loomworks/ui/v2/view_model/inspector_kinds/variable.lua
---
--- Read-only variable inspector. Shows the variable's declaration plus
--- per-configuration overrides found across the project's configurations.
---
--- ref: { kind = "variable", project_key, var_name }

local M = {}

--- @param workspace loomworks.Workspace|nil
--- @param project_key string
--- @return loomworks.Project|nil
local function find_project(workspace, project_key)
    if not workspace or not workspace._projects then return nil end
    for _, p in pairs(workspace._projects) do
        if p.key == project_key then return p end
    end
    return nil
end

--- Walk the project's configurations and collect overrides for var_name.
--- @param project loomworks.Project
--- @param var_name string
--- @return table[]   { configuration_name, value }
local function collect_overrides(project, var_name)
    local out = {}
    for _, cfg in ipairs(project:get_configurations() or {}) do
        if cfg.variables and cfg.variables[var_name] ~= nil then
            out[#out + 1] = {
                configuration_name = cfg.name,
                value              = cfg.variables[var_name],
            }
        end
    end
    table.sort(out, function(a, b) return a.configuration_name < b.configuration_name end)
    return out
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "variable", project_key: string, var_name: string }
--- @return table
function M.build(workspace, ref)
    local project = find_project(workspace, ref.project_key)
    if not project then
        return {
            kind        = "variable",
            subject     = ref.var_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end
    local decl = project.variables and project.variables[ref.var_name]
    if not decl then
        return {
            kind        = "variable",
            subject     = ref.var_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end

    local subject_ref = {
        kind = "variable",
        project_key = project.key,
        var_name = ref.var_name,
    }
    return {
        kind        = "variable",
        subject     = ref.var_name,
        project_key = project.key,
        missing     = false,
        type        = decl.type or "string",
        default     = decl.default,
        overrides   = collect_overrides(project, ref.var_name),
        editable_fields = {
            { id = "default", label = "Default",
              value = decl.default, kind = "string", subject = subject_ref },
        },
        hint_bar    = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
