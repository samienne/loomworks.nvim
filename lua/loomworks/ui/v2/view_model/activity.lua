--- loomworks/ui/v2/view_model/activity.lua — Activity strip presentation.
---
--- Two modes: `live` (running tasks + recent results) and `plan` (the
--- active profile's execution chain). The view model owns the mode
--- state; this module is a pure presentation builder.

local M = {}

--- @param unit loomworks.ConfigUnit
--- @return table row
local function row_from_unit(unit)
    local pkey = unit:project() and unit:project().key
        or unit._init_project_key
        or "?"
    local ckey = unit:config_key() or unit.id or "?"
    local progress = unit:progress()
    local elapsed = unit:elapsed()
    local state = unit:state()
    local pct
    if progress and progress.current and progress.total and progress.total > 0 then
        pct = math.floor((progress.current / progress.total) * 100 + 0.5)
    end
    return {
        project_key = pkey,
        config_key  = ckey,
        action      = unit:running_action(),
        state       = state,
        message     = progress and progress.message or nil,
        current     = progress and progress.current or nil,
        total       = progress and progress.total or nil,
        percent     = pct,
        elapsed     = elapsed,
        ref         = { kind = "config_unit", project_key = pkey, config_key = ckey },
    }
end

--- Build the live-mode presentation: running tasks + recent buffer.
--- @param workspace loomworks.Workspace|nil
--- @param recent_results table[]|nil
--- @return table
local function build_live(workspace, recent_results)
    local rows = {}
    for _, unit in pairs(workspace._config_units or {}) do
        if unit:running_action() then
            rows[#rows + 1] = row_from_unit(unit)
        end
    end
    table.sort(rows, function(a, b)
        if a.project_key ~= b.project_key then return a.project_key < b.project_key end
        return a.config_key < b.config_key
    end)
    local recent = recent_results or {}
    return {
        mode          = "live",
        running       = rows,
        running_count = #rows,
        recent        = recent,
        recent_count  = #recent,
        has_workspace = true,
    }
end

--- Source descriptors of a deploy step are either a single object or an
--- array; normalise to an array.
--- @param descriptor any
--- @return table[]
local function source_rows(descriptor)
    if type(descriptor) ~= "table" then return {} end
    if descriptor[1] ~= nil then return descriptor end
    return { descriptor }
end

--- Resolve a deploy destination against the launch project context.
--- Returns nil when expansion can't be done.
--- @param workspace loomworks.Workspace
--- @param profile loomworks.Profile
--- @param project loomworks.Project
--- @param raw_destination string
--- @return string|nil expanded
local function resolve_destination(workspace, profile, project, raw_destination)
    if not raw_destination or raw_destination == "" then return nil end
    local ok_expand, expand = pcall(require, "loomworks.expand")
    if not ok_expand then return raw_destination end
    local ok_ctx, ctx = pcall(expand.launch_context, workspace, profile, project)
    if not ok_ctx or not ctx then return raw_destination end
    local ok_exp, expanded = pcall(expand.expand_string, raw_destination, ctx)
    return ok_exp and expanded or raw_destination
end

--- Apply the workspace's path normaliser when available, otherwise identity.
--- @param workspace loomworks.Workspace
--- @param path string
--- @return string
local function normalize_path(workspace, path)
    local n = workspace and workspace._core and workspace._core._deps
        and workspace._core._deps.normalize
    if type(n) == "function" then
        local ok, result = pcall(n, path)
        if ok and type(result) == "string" then return result end
    end
    return path
end

--- Compute the freshness state for a deploy step entry.
--- v0: records[normalized_dest] present → "fresh", else → "pending".
--- A real freshness check would compare source_build_dir / source_rel_path /
--- source_mtime to the current source, which requires module-aware target
--- resolution; deferred.
--- @param workspace loomworks.Workspace
--- @param profile loomworks.Profile
--- @param launch_project loomworks.Project
--- @param raw_destination string
--- @return string state
local function deploy_state(workspace, profile, launch_project, raw_destination)
    local resolved = resolve_destination(workspace, profile, launch_project, raw_destination)
    if not resolved then return "pending" end
    local key = normalize_path(workspace, resolved)
    local records = workspace._deploy_records or {}
    return records[key] and "fresh" or "pending"
end

--- Build plan steps: build per project, pre-build deploy, post-build deploy, launch.
--- @param workspace loomworks.Workspace
--- @return table[]   { kind, label, state, ... }
local function build_plan_steps(workspace)
    local steps = {}
    local profile = workspace._active_profile
    if not profile then return steps end

    -- Build steps per project in the active profile.
    for _, pp in ipairs(profile:projects()) do
        steps[#steps + 1] = {
            kind        = "build",
            label       = pp:project_key() .. " (build)",
            project_key = pp:project_key(),
            state       = pp:status(),
            running     = pp:running_action(),
        }
    end

    -- Find the launch chosen as the default target, if any. Deploy steps
    -- and the launch row only make sense when there's a default target.
    local descriptor = profile._default_target_descriptor
    if not descriptor or not descriptor.project then return steps end

    -- Look up the launch project + launch config.
    local target_project
    for _, p in pairs(workspace._projects or {}) do
        if p.key == descriptor.project then target_project = p; break end
    end
    if not target_project then return steps end

    local launch = target_project.launch and descriptor.launch
        and target_project.launch[descriptor.launch] or nil

    if launch and type(launch.deploy) == "table" then
        local pre, post = {}, {}
        for dest, src in pairs(launch.deploy) do
            local state = deploy_state(workspace, profile, target_project, dest)
            for _, source in ipairs(source_rows(src)) do
                local entry = {
                    kind        = source.pre_build and "deploy_pre" or "deploy_post",
                    label       = (source.pre_build and "pre-build " or "post-build ")
                                  .. dest .. "  ←  " .. tostring(source.project or "?"),
                    destination = dest,
                    source      = source,
                    state       = state,
                }
                if source.pre_build then pre[#pre + 1] = entry
                else                     post[#post + 1] = entry end
            end
        end
        for _, e in ipairs(pre)  do steps[#steps + 1] = e end
        for _, e in ipairs(post) do steps[#steps + 1] = e end
    end

    -- Launch step
    local launch_label = descriptor.project ..
        (descriptor.launch and ("." .. descriptor.launch) or
         descriptor.target and ("/" .. descriptor.target) or "")
    steps[#steps + 1] = {
        kind        = "launch",
        label       = "Launch " .. launch_label,
        project_key = descriptor.project,
        launch_name = descriptor.launch,
        target      = descriptor.target,
        state       = "pending",
    }

    return steps
end

--- @param workspace loomworks.Workspace
--- @return table
local function build_plan(workspace)
    local profile = workspace._active_profile
    return {
        mode          = "plan",
        has_workspace = true,
        profile_key   = profile and profile.key or nil,
        plan_steps    = build_plan_steps(workspace),
    }
end

--- @param workspace loomworks.Workspace|nil
--- @param recent_results table[]|nil
--- @param mode string|nil  "live" (default) or "plan"
--- @return table
function M.build(workspace, recent_results, mode)
    if not workspace then
        return {
            mode = mode or "live",
            running = {}, running_count = 0,
            recent  = {}, recent_count  = 0,
            plan_steps = {},
            has_workspace = false,
        }
    end
    if mode == "plan" then
        return build_plan(workspace)
    end
    return build_live(workspace, recent_results)
end

return M
