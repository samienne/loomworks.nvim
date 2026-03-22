local M = {}

--- Collect task definitions for a single project configuration, grouped by action.
--- @param project_key string
--- @param config_key string cache key (variant or variant:tool_key)
--- @return table|nil task_defs_by_action { configure = {...}, build = {...} }
local function collect_configuration_tasks(project_key, config_key)
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
    if not ws then return nil end

    local project_config = ws.config.projects[project_key]
    if not project_config then return nil end

    local mod = modules.get(project_config.type)
    if not mod or not mod.tasks then return nil end

    -- Get variant and tool from ConfigUnit (never parse config_key)
    local unit = loomworks.get_config_unit(project_key, config_key)
    local variant = unit.variant
    local tool = unit:resolve_tool()
    local tool_data = tool and tool.data or nil

    -- Get module info
    local abs_path = ws.root .. "/" .. (project_config.path or project_key)
    local mod_info = mod.info and mod.info(abs_path, project_config.type_config)
            or { configurations = {} }

    local project_ctx = {
        name = project_key,
        path = project_config.path or project_key,
        type = project_config.type,
        configuration = variant,
        configuration_key = config_key,
        configurations = mod_info.configurations or {},
        tool_data = tool_data,
        workspace_root = ws.root,
        env = tool_data and tool_data.env or {},
    }

    local pt = mod.progress_parser
            and mod.progress_parser(project_ctx, variant)
            or nil

    local mod_tasks = mod.tasks(project_ctx, variant)
    local by_action = { configure = {}, build = {} }

    for _, task_def in ipairs(mod_tasks) do
        local lw_meta = task_def.loomworks
        if lw_meta then
            lw_meta.progress_tool = pt
            lw_meta.variant = variant
            lw_meta.tool = tool
            if by_action[lw_meta.action] then
                by_action[lw_meta.action][#by_action[lw_meta.action] + 1] = task_def
            end
        end
    end

    return by_action
end

--- Collect task definitions for a profile, grouped by action.
--- Does not change the active profile. Uses registered ProfileProject and
--- Project objects instead of recomputing from scratch.
--- @param profile loomworks.Profile
--- @return table|nil task_defs_by_action { configure = {...}, build = {...} }
local function collect_profile_tasks(profile)
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
    if not ws then return nil end

    local pps = profile:projects()
    if #pps == 0 then return nil end

    local by_action = { configure = {}, build = {} }

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end

        local mod = modules.get(project.type)
        if not mod or not mod.tasks then goto continue end

        local active_config = pp.variant
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        local tool_data = project_tool and project_tool.data or nil
        local project_ctx = {
            name = pp.project_key,
            path = project.path or pp.project_key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp.config_key,
            configurations = project.configurations,
            tool_data = tool_data,
            workspace_root = ws.root,
            env = tool_data and tool_data.env or {},
        }

        local pt = mod.progress_parser
                and mod.progress_parser(project_ctx, active_config)
                or nil

        local mod_tasks = mod.tasks(project_ctx, active_config)
        for _, task_def in ipairs(mod_tasks) do
            local lw_meta = task_def.loomworks
            if lw_meta then
                lw_meta.progress_tool = pt
                lw_meta.variant = active_config
                lw_meta.tool = project_tool
                if by_action[lw_meta.action] then
                    by_action[lw_meta.action][#by_action[lw_meta.action] + 1] = task_def
                end
            end
        end

        ::continue::
    end

    return by_action
end

--- Collect clean task definitions for a single configuration.
--- @param project_key string
--- @param config_key string
--- @return table[]|nil clean_tasks
local function collect_configuration_clean_tasks(project_key, config_key)
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
    if not ws then return nil end

    local project_config = ws.config.projects[project_key]
    if not project_config then return nil end

    local mod = modules.get(project_config.type)
    if not mod or not mod.clean_tasks then return nil end

    local unit = loomworks.get_config_unit(project_key, config_key)
    local variant = unit.variant
    local tool = unit:resolve_tool()
    local tool_data = tool and tool.data or nil

    local abs_path = ws.root .. "/" .. (project_config.path or project_key)
    local mod_info = mod.info and mod.info(abs_path, project_config.type_config)
            or { configurations = {} }

    local project_ctx = {
        name = project_key,
        path = project_config.path or project_key,
        type = project_config.type,
        configuration = variant,
        configuration_key = config_key,
        configurations = mod_info.configurations or {},
        tool_data = tool_data,
        type_config = project_config.type_config,
        workspace_root = ws.root,
        env = tool_data and tool_data.env or {},
    }

    return mod.clean_tasks(project_ctx, variant)
end

--- Collect clean task definitions for all projects in a profile.
--- @param profile loomworks.Profile
--- @return table[]|nil clean_tasks
local function collect_profile_clean_tasks(profile)
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
    if not ws then return nil end

    local pps = profile:projects()
    if #pps == 0 then return nil end

    local tasks = {}

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end

        local mod = modules.get(project.type)
        if not mod or not mod.clean_tasks then goto continue end

        local active_config = pp.variant
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        local tool_data = project_tool and project_tool.data or nil
        local project_ctx = {
            name = pp.project_key,
            path = project.path or pp.project_key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp.config_key,
            configurations = project.configurations,
            tool_data = tool_data,
            type_config = project.type_config,
            workspace_root = ws.root,
            env = tool_data and tool_data.env or {},
        }

        local clean = mod.clean_tasks(project_ctx, active_config)
        if clean then
            for _, task_def in ipairs(clean) do
                tasks[#tasks + 1] = task_def
            end
        end

        ::continue::
    end

    return #tasks > 0 and tasks or nil
end

--- Build and start a single overseer task from a task definition.
--- @param overseer table overseer module
--- @param task_def table task definition with .builder and .loomworks
--- @param on_complete? function called with boolean success when task completes
local function start_one_task(overseer, task_def, on_complete)
    local lw_meta = task_def.loomworks

    local build_result = task_def.builder()
    build_result.components = build_result.components or { "default" }
    build_result.components[#build_result.components + 1] = {
        "loomworks.task_tracker",
        project_key = lw_meta.project_key,
        action = lw_meta.action,
        configuration_key = lw_meta.configuration_key,
        build_dir = lw_meta.build_dir,
        variant = lw_meta.variant,
        tool = lw_meta.tool,
        cmake = lw_meta.cmake,
        progress_tool = lw_meta.progress_tool,
    }

    build_result.name = task_def.name
    local task = overseer.new_task(build_result)

    if on_complete then
        task:subscribe("on_complete", function(_, status)
            on_complete(status == "SUCCESS")
        end)
    end

    task:start()
end

--- Check whether a task should be launched, skipped, or deferred based on ConfigUnit state.
--- Configure tasks: only launch if unconfigured or configure_failed.
--- Build tasks: skip if already building, defer if currently configuring,
--- block if in unknown state.
--- @param task_def table task definition with .loomworks
--- @return "launch"|"skip"|"defer"|"block"
local function check_task_readiness(task_def)
    local lw = require("loomworks")
    local lw_meta = task_def.loomworks
    local unit = lw.get_config_unit(lw_meta.project_key, lw_meta.configuration_key)
    local state = unit:state()

    -- Unknown state blocks all actions — user must clean/delete first
    if state == "unknown" then return "block" end

    if lw_meta.action == "configure" then
        if state == "unconfigured" or state == "configure_failed" then
            return "launch"
        end
        return "skip"
    end

    -- action == "build"
    if state == "building" then return "skip" end
    if state == "configuring" then return "defer" end
    return "launch"
end

--- Launch a list of task definitions via overseer.
--- Respects ConfigUnit state: skips already-running tasks, defers build tasks
--- that are waiting for an in-progress configure to finish.
--- @param overseer table overseer module
--- @param task_defs table[] task definitions with .builder and .loomworks
--- @param on_all_done? function called when all tasks complete, with boolean all_succeeded
--- @return number launched count of tasks started or deferred
local function launch_tasks(overseer, task_defs, on_all_done)
    local lw = require("loomworks")

    -- Classify each task
    local to_launch, to_defer = {}, {}
    for _, task_def in ipairs(task_defs) do
        if not task_def.loomworks then goto next end
        local readiness = check_task_readiness(task_def)
        if readiness == "launch" then
            to_launch[#to_launch + 1] = task_def
        elseif readiness == "defer" then
            to_defer[#to_defer + 1] = task_def
        elseif readiness == "block" then
            local meta = task_def.loomworks
            vim.notify(
                "loomworks: " .. meta.project_key .. "/" .. meta.configuration_key
                    .. " is in unknown state — clean or delete first",
                vim.log.levels.WARN
            )
        end
        -- "skip" and "block" tasks are dropped
        ::next::
    end

    local total = #to_launch + #to_defer
    if total == 0 then
        if on_all_done then
            vim.schedule(function() on_all_done(true) end)
        end
        return 0
    end

    -- Shared completion tracking across immediate and deferred tasks
    local remaining = total
    local all_ok = true

    local function on_one_done(success)
        if not success then all_ok = false end
        remaining = remaining - 1
        if remaining == 0 and on_all_done then
            vim.schedule(function() on_all_done(all_ok) end)
        end
    end

    -- Launch ready tasks immediately
    for _, task_def in ipairs(to_launch) do
        start_one_task(overseer, task_def, on_all_done and on_one_done or nil)
    end

    -- Defer build tasks waiting for an in-progress configure
    for _, task_def in ipairs(to_defer) do
        local lw_meta = task_def.loomworks
        local unit = lw.get_config_unit(lw_meta.project_key, lw_meta.configuration_key)
        local unsub
        unsub = unit:on_state_change(function(u)
            local new_state = u:state()
            if new_state == "configuring" then return end -- still going
            unsub()
            if new_state == "configure_failed" then
                on_one_done(false)
                return
            end
            start_one_task(overseer, task_def, on_all_done and on_one_done or nil)
        end)
    end

    return total
end

--- Filter task definitions to only those that will actually launch or defer.
--- Excludes "skip" (already done) and "block" (unknown state) tasks.
--- @param task_defs table[]
--- @return table[]
local function filter_launchable_tasks(task_defs)
    local result = {}
    for _, task_def in ipairs(task_defs) do
        if task_def.loomworks then
            local readiness = check_task_readiness(task_def)
            if readiness == "launch" or readiness == "defer" then
                result[#result + 1] = task_def
            end
        end
    end
    return result
end

--- Filter configure tasks to only those whose ConfigUnit needs configuring.
--- @param all_tasks table { configure: table[], build: table[] }
--- @return table[] configure tasks that actually need running
local function filter_unconfigured_tasks(all_tasks)
    local loomworks = require("loomworks")

    local needs_configure = {}
    for _, task_def in ipairs(all_tasks.configure) do
        local lw_meta = task_def.loomworks
        if not lw_meta then goto next end

        local state = loomworks.get_config_unit(lw_meta.project_key, lw_meta.configuration_key):state()
        if state == "unconfigured" or state == "configure_failed" then
            needs_configure[#needs_configure + 1] = task_def
        end

        ::next::
    end

    return needs_configure
end

--- Run an action for a single project configuration.
--- Creates a pinned profile entry if needed, then launches overseer tasks.
--- If building and the configuration is unconfigured, configures first.
--- @param unit loomworks.ConfigUnit
--- @param action string "configure" or "build"
--- @param on_complete? fun(success: boolean) called when all tasks finish
function M.run_configuration_action(unit, action, on_complete)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return
    end

    local loomworks = require("loomworks")

    local function do_action()
        -- Pin config only if not already referenced by a materialized profile
        if #unit:referencing_profiles() == 0 then
            unit:materialize_pinned()
        end

        local all_tasks = collect_configuration_tasks(unit.project_key, unit.config_key)
        if not all_tasks then
            if on_complete then on_complete(false) end
            return
        end

        if action == "configure" then
            launch_tasks(overseer, all_tasks.configure, on_complete)
            return
        end

        if action == "build" then
            -- Check if any projects need configuring first
            local needs_configure = filter_unconfigured_tasks(all_tasks)
            if #needs_configure > 0 then
                launch_tasks(overseer, needs_configure, function(all_succeeded)
                    if not all_succeeded then
                        vim.notify("loomworks: configure failed, skipping build", vim.log.levels.ERROR)
                        if on_complete then on_complete(false) end
                        return
                    end
                    launch_tasks(overseer, all_tasks.build, on_complete)
                end)
            else
                launch_tasks(overseer, all_tasks.build, on_complete)
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
    end

    -- Wait for pending deletions before starting
    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end
end

--- Run clean tasks for a single configuration.
--- Launches module clean_tasks via overseer (no task_tracker — clean tasks
--- don't update ConfigUnit state; the caller handles cache reset).
--- @param unit loomworks.ConfigUnit
--- @param on_complete? fun(success: boolean)
function M.run_configuration_clean(unit, on_complete)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return
    end

    local tasks = collect_configuration_clean_tasks(unit.project_key, unit.config_key)
    if not tasks or #tasks == 0 then
        -- No clean tasks for this module — treat as success
        if on_complete then on_complete(true) end
        return
    end

    local remaining = #tasks
    local all_ok = true

    for _, task_def in ipairs(tasks) do
        local build_result = task_def.builder()
        build_result.components = build_result.components or { "default" }
        build_result.name = task_def.name
        local task = overseer.new_task(build_result)
        task:subscribe("on_complete", function(_, status)
            if status ~= "SUCCESS" then all_ok = false end
            remaining = remaining - 1
            if remaining == 0 and on_complete then
                on_complete(all_ok)
            end
        end)
        task:start()
    end
end

--- Run clean tasks for all projects in a profile.
--- @param profile loomworks.Profile
--- @param on_complete? fun(success: boolean)
function M.run_profile_clean(profile, on_complete)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return
    end

    local tasks = collect_profile_clean_tasks(profile)
    if not tasks or #tasks == 0 then
        if on_complete then on_complete(true) end
        return
    end

    local remaining = #tasks
    local all_ok = true

    for _, task_def in ipairs(tasks) do
        local build_result = task_def.builder()
        build_result.components = build_result.components or { "default" }
        build_result.name = task_def.name
        local task = overseer.new_task(build_result)
        task:subscribe("on_complete", function(_, status)
            if status ~= "SUCCESS" then all_ok = false end
            remaining = remaining - 1
            if remaining == 0 and on_complete then
                on_complete(all_ok)
            end
        end)
        task:start()
    end
end

--- Launch a run/launch task via overseer.
--- Unlike build tasks, this doesn't use task_tracker or ConfigUnit state.
--- Opens the overseer window automatically.
--- @param opts { name: string, cmd: string[], cwd?: string, env?: table }
--- @return number|nil task_id
function M.launch_run_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    -- overseer expects cmd as a list (argv) for direct execution
    local cmd = opts.cmd
    if type(cmd) == "string" then
        cmd = { cmd }
    end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end
    local task = overseer.new_task({
        name = opts.name,
        cmd = cmd,
        cwd = opts.cwd,
        env = opts.env,
        components = { "default" },
    })
    task:start()
    overseer.open({ enter = false })
    return task.id
end

--- Launch a single task definition via overseer.
--- Used by ConfigUnit:build_target for per-target builds.
--- @param task_def table task definition with .builder and .loomworks
--- @param unit loomworks.ConfigUnit the configuration unit being built
--- @param on_complete? function called with boolean success
function M.launch_single_task(task_def, unit, on_complete)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return
    end

    -- Check ConfigUnit state directly (not via check_task_readiness which expects task_def)
    local state = unit:state()
    if state == "unknown" then return end
    if state == "building" then return end

    start_one_task(overseer, task_def, on_complete)
end

--- Collect ConfigUnits and their target states from task definitions.
--- @param task_defs table[] task definitions with .loomworks
--- @param target_state string target ConfigUnit state (e.g. "configured", "built")
--- @return loomworks.ConfigUnit[] units
--- @return table<loomworks.ConfigUnit, string> target_states
local function collect_units_from_tasks(task_defs, target_state)
    local lw = require("loomworks")
    local units = {}
    local target_states = {}
    local seen = {}
    for _, task_def in ipairs(task_defs) do
        local meta = task_def.loomworks
        if meta then
            local key = meta.project_key .. "\0" .. meta.configuration_key
            if not seen[key] then
                seen[key] = true
                local unit = lw.get_config_unit(meta.project_key, meta.configuration_key)
                units[#units + 1] = unit
                target_states[unit] = target_state
            end
        end
    end
    return units, target_states
end

--- Run all tasks of a given action for a profile.
--- The profile must already be materialized (caller ensures this).
--- If building and some projects are unconfigured, configures them first.
--- Creates an Operation to track progress and completion.
--- @param profile loomworks.Profile
--- @param action string "configure" or "build"
function M.run_profile_action(profile, action)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return
    end

    local loomworks = require("loomworks")

    local function do_action()
        -- Re-collect tasks after potential deletion completed (cache may have changed)
        local all_tasks = collect_profile_tasks(profile)
        if not all_tasks then return end

        if action == "configure" then
            -- Filter to tasks that will actually launch (skip already-configured)
            local launchable = filter_launchable_tasks(all_tasks.configure)
            local units, target_states = collect_units_from_tasks(launchable, "configured")
            if #units > 0 then
                loomworks.create_operation(profile, "configure", units, target_states)
            end
            launch_tasks(overseer, all_tasks.configure)
            return
        end

        if action == "build" then
            local needs_configure = filter_unconfigured_tasks(all_tasks)

            -- Filter build tasks to those that will actually launch
            local launchable_builds = filter_launchable_tasks(all_tasks.build)
            local units, target_states = collect_units_from_tasks(launchable_builds, "built")

            if #needs_configure > 0 then
                -- Also include configure units that aren't already in the build set
                local configure_units, configure_targets = collect_units_from_tasks(needs_configure, "built")
                for _, u in ipairs(configure_units) do
                    if not target_states[u] then
                        units[#units + 1] = u
                        target_states[u] = "built"
                    end
                end

                local op
                if #units > 0 then
                    op = loomworks.create_operation(profile, "configure+build", units, target_states)
                end

                launch_tasks(overseer, needs_configure, function(all_succeeded)
                    if not all_succeeded then
                        vim.notify("loomworks: configure failed, skipping build", vim.log.levels.ERROR)
                        -- Cancel the operation — build won't happen, so units
                        -- targeting "built" would be stuck forever.
                        if op and not op.completed then
                            op:cancel("configure failed")
                        end
                        return
                    end
                    launch_tasks(overseer, all_tasks.build)
                end)
            else
                if #units > 0 then
                    loomworks.create_operation(profile, "build", units, target_states)
                end
                launch_tasks(overseer, all_tasks.build)
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
    end

    -- Wait for pending deletions before starting
    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end
end

return M
