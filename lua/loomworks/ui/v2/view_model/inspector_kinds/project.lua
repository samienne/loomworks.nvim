--- loomworks/ui/v2/view_model/inspector_kinds/project.lua
---
--- Build the project inspector content (read-only in this slice).

local M = {}

--- @param workspace loomworks.Workspace
--- @param key string
--- @return table|nil
local function find_project(workspace, key)
    if not workspace or not workspace._projects then return nil end
    for _, p in pairs(workspace._projects) do
        if p.key == key then return p end
    end
    return nil
end

--- @param project loomworks.Project
--- @return string|nil
local function project_type(project)
    return project._module and project._module.id or nil
end

--- @param project loomworks.Project
--- @return table[]
local function configurations_block(project)
    local rows = {}
    for _, cfg in ipairs(project:get_configurations() or {}) do
        rows[#rows + 1] = {
            name = cfg.name,
            prefix = cfg.prefix,                       -- "variant" | "preset" | "auto" | nil (user)
            source_missing = cfg._source_missing == true,
            ref = { kind = "configuration", project_key = project.key, config_name = cfg.name },
        }
    end
    return rows
end

--- Find configuration sets that map this project.
--- @param workspace loomworks.Workspace
--- @param project loomworks.Project
--- @return table[] memberships { set_name, variant_name }
local function set_membership_block(workspace, project)
    local out = {}
    for _, cs in pairs(workspace._config_sets or {}) do
        local cfg = cs.mappings and cs.mappings[project]
        if cfg then
            out[#out + 1] = {
                set_name = cs.name,
                variant_name = cfg.name,
                ref = { kind = "config_set", key = cs.name },
            }
        end
    end
    table.sort(out, function(a, b) return a.set_name < b.set_name end)
    return out
end

--- @param project loomworks.Project
--- @return table[]
local function launch_block(project)
    local out = {}
    local launches = project._launch_configs or project.launch or {}
    if type(launches) ~= "table" then return out end
    for name, _ in pairs(launches) do
        out[#out + 1] = {
            name = name,
            ref = { kind = "launch", project_key = project.key, launch_name = name },
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- @param project loomworks.Project
--- @return table[]
local function variables_block(project)
    local out = {}
    local vars = project._variables or project.variables or {}
    if type(vars) ~= "table" then return out end
    for name, decl in pairs(vars) do
        out[#out + 1] = {
            name = name,
            type = decl and decl.type or "string",
            default = decl and decl.default or nil,
            ref = { kind = "variable", project_key = project.key, var_name = name },
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Build the project inspector content.
--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "project", key: string }
--- @return table
function M.build(workspace, ref)
    local key = ref.key
    local project = find_project(workspace, key)
    if not project then
        return {
            kind = "project",
            subject = key,
            missing = true,
            hint_bar = {},
        }
    end

    return {
        kind = "project",
        subject = project.key,
        missing = false,
        type = project_type(project),
        path = project.path,
        configurations = configurations_block(project),
        set_membership = set_membership_block(workspace, project),
        launches = launch_block(project),
        variables = variables_block(project),
        intent = project._intent or "local",
        publishable = true,
        hint_bar = {
            { key = "p",  label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
