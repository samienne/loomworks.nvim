--- loomworks/ui/v2/view_model/inspector_kinds/deploy_step.lua
---
--- Deploy-step inspector. Shows destination, source descriptors (one or
--- more, list shape), and phase per source.
---
--- A deploy step is identified by the launch (or project) it belongs
--- to plus the destination key:
---
---   ref: { kind = "deploy_step",
---          project_key, launch_name?, destination }
---
--- launch_name nil → project-level deploy.

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

--- Look up the deploy descriptor (single or array) at `destination`.
--- @param project loomworks.Project
--- @param launch_name string|nil
--- @param destination string
--- @return any|nil descriptor   (raw value from the config)
local function find_descriptor(project, launch_name, destination)
    if launch_name then
        local launches = project._launch_configs or project.launch
        if type(launches) ~= "table" then return nil end
        local launch = launches[launch_name]
        if not launch or type(launch.deploy) ~= "table" then return nil end
        return launch.deploy[destination]
    end
    local pdeploy = project.deploy or project._deploy
    if type(pdeploy) ~= "table" then return nil end
    return pdeploy[destination]
end

--- Build a row for a single source descriptor (with drill ref).
--- @param d table descriptor table
--- @return table
local function source_row(d)
    local row = {
        project       = d.project,
        target        = d.target,
        path          = d.path,
        configuration = d.configuration,
        pre_build     = d.pre_build == true,
    }
    if d.project then
        if d.configuration then
            row.ref = {
                kind = "configuration",
                project_key = d.project,
                config_name = d.configuration,
            }
        else
            row.ref = { kind = "project", key = d.project }
        end
    end
    return row
end

--- Normalise a descriptor (single object or array) to an array of source rows.
--- @param descriptor any
--- @return table[]
local function source_rows(descriptor)
    if type(descriptor) ~= "table" then return {} end
    if descriptor[1] ~= nil then
        local out = {}
        for i, d in ipairs(descriptor) do out[i] = source_row(d) end
        return out
    end
    return { source_row(descriptor) }
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "deploy_step", project_key: string, launch_name: string|nil, destination: string }
--- @return table
function M.build(workspace, ref)
    local project = find_project(workspace, ref.project_key)
    if not project then
        return {
            kind        = "deploy_step",
            subject     = ref.destination or "?",
            project_key = ref.project_key,
            launch_name = ref.launch_name,
            missing     = true,
            hint_bar    = {},
        }
    end
    local descriptor = find_descriptor(project, ref.launch_name, ref.destination)
    if descriptor == nil then
        return {
            kind        = "deploy_step",
            subject     = ref.destination or "?",
            project_key = ref.project_key,
            launch_name = ref.launch_name,
            missing     = true,
            hint_bar    = {},
        }
    end

    return {
        kind        = "deploy_step",
        subject     = ref.destination,
        project_key = project.key,
        launch_name = ref.launch_name,
        scope       = ref.launch_name and "launch" or "project",
        missing     = false,
        sources     = source_rows(descriptor),
        hint_bar    = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
