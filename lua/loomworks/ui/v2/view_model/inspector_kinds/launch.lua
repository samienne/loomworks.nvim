--- loomworks/ui/v2/view_model/inspector_kinds/launch.lua
---
--- Launch inspector. Shows command, args, env, working_dir, debug
--- adapter list, and deploy steps.
---
--- ref: { kind = "launch", project_key, launch_name }

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

--- @param project loomworks.Project
--- @param launch_name string
--- @return table|nil
local function find_launch(project, launch_name)
    local launches = project._launch_configs or project.launch
    if type(launches) ~= "table" then return nil end
    return launches[launch_name]
end

--- @param launch table
--- @param subject_ref table  the launch's subject ref (project_key, launch_name)
--- @return table[]   { value, edit }
local function args_list(launch, subject_ref)
    local out = {}
    if type(launch.args) == "table" then
        for i, a in ipairs(launch.args) do
            out[i] = {
                value = tostring(a),
                edit = {
                    id    = "arg:" .. tostring(i),
                    label = "Arg " .. tostring(i),
                    value = tostring(a),
                    kind  = "string",
                    subject = {
                        kind        = "launch_arg",
                        project_key = subject_ref.project_key,
                        launch_name = subject_ref.launch_name,
                        index       = i,
                    },
                },
            }
        end
    end
    return out
end

--- @param launch table
--- @param subject_ref table
--- @return table[]   { key, value, edit }
local function env_list(launch, subject_ref)
    local out = {}
    if type(launch.env) == "table" then
        for k, v in pairs(launch.env) do
            out[#out + 1] = {
                key = k,
                value = tostring(v),
                edit = {
                    id    = "env:" .. k,
                    label = "Env " .. k,
                    value = tostring(v),
                    kind  = "string",
                    subject = {
                        kind        = "launch_env",
                        project_key = subject_ref.project_key,
                        launch_name = subject_ref.launch_name,
                        key         = k,
                    },
                },
            }
        end
        table.sort(out, function(a, b) return a.key < b.key end)
    end
    return out
end

--- @param launch table
--- @return integer
local function deploy_count(launch)
    if type(launch.deploy) == "table" then
        local n = 0
        for _ in pairs(launch.deploy) do n = n + 1 end
        return n
    end
    return 0
end

--- Build drillable rows for each deploy step.
--- @param launch table
--- @param project_key string
--- @param launch_name string
--- @return table[]   { destination, ref }
local function deploy_rows(launch, project_key, launch_name)
    local out = {}
    if type(launch.deploy) ~= "table" then return out end
    for dest, _ in pairs(launch.deploy) do
        out[#out + 1] = {
            destination = dest,
            ref = {
                kind = "deploy_step",
                project_key = project_key,
                launch_name = launch_name,
                destination = dest,
            },
        }
    end
    table.sort(out, function(a, b) return a.destination < b.destination end)
    return out
end

--- @param launch table
--- @return string[]
local function debug_languages(launch)
    if type(launch.debug) ~= "table" then return {} end
    local out = {}
    for i, d in ipairs(launch.debug) do out[i] = tostring(d) end
    return out
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "launch", project_key: string, launch_name: string }
--- @return table
function M.build(workspace, ref)
    local project = find_project(workspace, ref.project_key)
    if not project then
        return {
            kind        = "launch",
            subject     = ref.launch_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end
    local launch = find_launch(project, ref.launch_name)
    if not launch then
        return {
            kind        = "launch",
            subject     = ref.launch_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end

    local subject_ref = {
        kind = "launch",
        project_key = project.key,
        launch_name = ref.launch_name,
    }
    return {
        kind            = "launch",
        subject         = ref.launch_name,
        project_key     = project.key,
        missing         = false,
        command         = launch.command,
        working_dir     = launch.working_dir,
        args            = args_list(launch, subject_ref),
        env             = env_list(launch, subject_ref),
        debug           = debug_languages(launch),
        deploy_count    = deploy_count(launch),
        deploy_steps    = deploy_rows(launch, project.key, ref.launch_name),
        editable_fields = {
            { id = "command",     label = "Command",
              value = launch.command,     kind = "string", subject = subject_ref },
            { id = "working_dir", label = "Working dir",
              value = launch.working_dir, kind = "string", subject = subject_ref },
        },
        add_actions = {
            arg = {
                kind = "launch_arg",
                parent = subject_ref,
                label = "+ Add arg",
            },
            env = {
                kind = "launch_env",
                parent = subject_ref,
                label = "+ Add env var",
            },
            deploy_step = {
                kind = "deploy_step",
                parent = subject_ref,
                label = "+ Add deploy step",
            },
        },
        hint_bar        = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
