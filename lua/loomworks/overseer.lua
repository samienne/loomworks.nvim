local M = {}

--- Collect task definitions for a single project configuration, grouped by action.
--- @param unit loomworks.ConfigUnit
--- @return table|nil task_defs_by_action { configure = {...}, build = {...} }
local function collect_configuration_tasks(unit)
    local modules = require("loomworks.modules")

    local project = unit._project
    if not project then return nil end

    local ws = unit._workspace
    if not ws then return nil end

    local mod = project._module and project._module.impl or nil
    if not mod or not mod.tasks then return nil end

    local variant = unit:variant()
    local tool = unit._tool
    local tool_data = tool and tool.data or unit:tool_data()

    -- Get module info (reconstruct type_config with configurations for module)
    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local tc_for_module = project:_type_config_for_module()
    local mod_info = { configurations = {} }
    if mod.info then
        local ok, result = pcall(mod.info, abs_path, tc_for_module)
        if ok and result then
            mod_info = result
        end
    end

    local project_ctx = {
        name = project.key,
        path = project.path or project.key,
        type = project.type,
        configuration = variant,
        configuration_key = unit:config_key(),
        configurations = mod_info.configurations or {},
        type_config = tc_for_module,
        tool_data = tool_data,
        workspace_root = ws.root,
        env = tool_data and tool_data.env or {},
        cached_build_dir = unit:build_dir(),
    }

    local pt = mod.progress_parser
            and mod.progress_parser(project_ctx, variant)
            or nil

    local ok_tasks, mod_tasks = pcall(mod.tasks, project_ctx, variant)
    if not ok_tasks or not mod_tasks then
        vim.notify("loomworks: module '" .. project.type .. "' tasks() failed: " .. tostring(mod_tasks),
            vim.log.levels.ERROR)
        return nil, nil
    end
    local by_action = { configure = {}, build = {} }

    local tool_ref = tool and tool:to_ref() or (unit:tool_key() and {
        key = unit:tool_key(), data = unit:tool_data(),
    }) or nil

    for _, task_def in ipairs(mod_tasks) do
        local lw_meta = task_def.loomworks
        if lw_meta then
            lw_meta.unit = unit
            lw_meta.progress_tool = pt
            lw_meta.variant = variant
            lw_meta.tool = tool_ref
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

        local mod = project._module and project._module.impl or nil
        if not mod or not mod.tasks then goto continue end

        local active_config = pp:variant_name()
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        local tool_data = project_tool and project_tool.data or nil
        local project_ctx = {
            name = project.key,
            path = project.path or project.key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp:config_key(),
            configurations = project.configurations,
            type_config = project:_type_config_for_module(),
            tool_data = tool_data,
            workspace_root = ws.root,
            env = tool_data and tool_data.env or {},
            cached_build_dir = pp:build_dir(),
        }

        local pt = mod.progress_parser
                and mod.progress_parser(project_ctx, active_config)
                or nil

        local mod_tasks = mod.tasks(project_ctx, active_config)
        for _, task_def in ipairs(mod_tasks) do
            local lw_meta = task_def.loomworks
            if lw_meta then
                lw_meta.unit = pp._config_unit
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
--- @param unit loomworks.ConfigUnit
--- @return table[]|nil clean_tasks
local function collect_configuration_clean_tasks(unit)
    local modules = require("loomworks.modules")

    local project = unit._project
    if not project then return nil end

    local ws = unit._workspace
    if not ws then return nil end

    local mod = project._module and project._module.impl or nil
    if not mod or not mod.clean_tasks then return nil end

    local variant = unit:variant()
    local tool = unit._tool
    local tool_data = tool and tool.data or unit:tool_data()

    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local mod_info = mod.info and mod.info(abs_path, project.type_config)
            or { configurations = {} }

    local project_ctx = {
        name = project.key,
        path = project.path or project.key,
        type = project.type,
        configuration = variant,
        configuration_key = unit:config_key(),
        configurations = mod_info.configurations or {},
        tool_data = tool_data,
        type_config = project.type_config,
        workspace_root = ws.root,
        env = tool_data and tool_data.env or {},
        cached_build_dir = unit:build_dir(),
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

        local mod = project._module and project._module.impl or nil
        if not mod or not mod.clean_tasks then goto continue end

        local active_config = pp:variant_name()
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        local tool_data = project_tool and project_tool.data or nil
        local project_ctx = {
            name = project.key,
            path = project.path or project.key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp:config_key(),
            configurations = project.configurations,
            tool_data = tool_data,
            type_config = project.type_config,
            workspace_root = ws.root,
            env = tool_data and tool_data.env or {},
            cached_build_dir = pp:build_dir(),
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

--- Determine the lock type for a task action.
--- @param action string "configure", "build", "clean", etc.
--- @return "exclusive"|"shared"
local function lock_type_for_action(action)
    return action == "build" and "shared" or "exclusive"
end

--- Build and start a single overseer task from a task definition.
--- Acquires a build dir lock before starting. If the lock can't be acquired
--- immediately, the task is queued and started when the lock becomes available.
--- Uses event subscriptions (not a component) for loomworks integration —
--- the overseer task stays pure and the ConfigUnit is captured directly.
--- @param overseer table overseer module
--- @param task_def table task definition with .builder and .loomworks
--- @param on_complete? function called with boolean success when task completes
--- Start a single overseer task. Returns a Future that resolves with
--- boolean success when the task completes.
--- @param overseer table overseer module
--- @param task_def table task definition
--- @param on_complete? function legacy callback (deprecated, use Future)
--- @return loomworks.Future
local function start_one_task(overseer, task_def, on_complete)
    local future_mod = require("loomworks.future")
    local lw_meta = task_def.loomworks
    local unit = lw_meta.unit

    local f = future_mod.create(function(resolve, reject, token)
        local function do_start()
            if token:is_cancelled() then
                reject("cancelled")
                return
            end

            local build_result = task_def.builder()
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)

            -- Register cancel callback to stop the overseer task
            token:on_cancel(function()
                if task and not task:is_complete() then
                    task:stop()
                end
            end)

            local progress_parser = lw_meta.progress_tool
                and require("loomworks.progress").get(lw_meta.progress_tool) or nil

            local lock_released = false
            local function release_lock()
                if lock_released or not lw_meta.build_dir then return end
                lock_released = true
                local ws = unit._workspace
                if ws then
                    local dir = ws._core._deps.normalize(lw_meta.build_dir)
                    ws:release_build_dir_lock(dir, lock_type_for_action(lw_meta.action))
                end
            end

            local function emit(event, data)
                unit._workspace._core._deps.events.emit(event, data)
            end

            task:subscribe("on_start", function()
                if lw_meta.build_dir then
                    unit.build_dir_value = lw_meta.build_dir
                    unit._workspace:_save_cache()
                end
                unit:register_task(task.id, lw_meta.action)
                emit("task_started", { task_id = task.id, unit = unit, action = lw_meta.action })
            end)

            if progress_parser then
                task:subscribe("on_output_lines", function(_, lines)
                    for i = #lines, 1, -1 do
                        local update = progress_parser(lines[i])
                        if update then
                            unit:update_progress(task.id, update)
                            emit("task_progress", { task_id = task.id, unit = unit, progress = update })
                            return
                        end
                    end
                end)
            end

            task:subscribe("on_complete", function(_, status)
                if status ~= "CANCELED" then
                    unit._workspace:record_task_result({
                        unit = unit,
                        action = lw_meta.action,
                        variant = lw_meta.variant,
                        tool = lw_meta.tool,
                        build_dir = lw_meta.build_dir,
                        cmake = lw_meta.cmake,
                        success = status == "SUCCESS",
                    })
                end
                unit:unregister_task(task.id)
                emit("task_stopped", { task_id = task.id, unit = unit })
                release_lock()
                if status == "SUCCESS" then resolve(true)
                else reject(lw_meta.action .. " failed") end
            end)

            task:subscribe("on_dispose", function()
                unit:unregister_task(task.id)
                emit("task_stopped", { task_id = task.id, unit = unit })
                release_lock()
            end)

            task:start()
        end

        -- Protected start: catch errors so the Future always resolves/rejects
        local function safe_start()
            local ok, err = pcall(do_start)
            if not ok then
                reject("task start failed: " .. tostring(err))
            end
        end

        -- Acquire build dir lock if task has a build directory
        if lw_meta.build_dir then
            local ws = unit._workspace
            if ws then
                local dir = ws._core._deps.normalize(lw_meta.build_dir)
                ws:acquire_build_dir_lock(dir, lock_type_for_action(lw_meta.action), safe_start)
                return
            end
        end

        safe_start()
    end)

    -- Legacy callback support
    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end

    return f
end

--- Check whether a task should be launched, skipped, or deferred based on ConfigUnit state.
--- Configure tasks: only launch if unconfigured or configure_failed.
--- Build tasks: skip if already building, defer if currently configuring,
--- block if in unknown state.
--- @param task_def table task definition with .loomworks
--- @return "launch"|"skip"|"defer"|"block"
local function check_task_readiness(task_def)
    local lw_meta = task_def.loomworks
    local unit = lw_meta.unit
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
--- Returns a Future that resolves with boolean (all succeeded).
--- Respects ConfigUnit state: skips already-running tasks, defers build tasks
--- that are waiting for an in-progress configure to finish.
--- @param overseer table overseer module
--- @param task_defs table[] task definitions with .builder and .loomworks
--- @param on_all_done? function legacy callback (deprecated, use Future)
--- @return loomworks.Future, number launched
local function launch_tasks(overseer, task_defs, on_all_done)
    local future_mod = require("loomworks.future")

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
        ::next::
    end

    local total = #to_launch + #to_defer
    if total == 0 then
        if on_all_done then
            vim.schedule(function() on_all_done(true) end)
        end
        return future_mod.resolved(true), 0
    end

    -- Collect Futures for all tasks (immediate + deferred)
    local task_futures = {}

    for _, task_def in ipairs(to_launch) do
        task_futures[#task_futures + 1] = start_one_task(overseer, task_def)
    end

    for _, task_def in ipairs(to_defer) do
        local deferred_f = future_mod.Future.new()
        task_futures[#task_futures + 1] = deferred_f

        local unit = task_def.loomworks.unit
        local unsub
        unsub = unit:on_state_change(function(u)
            local new_state = u:state()
            if new_state == "configuring" then return end
            unsub()
            if new_state == "configure_failed" then
                deferred_f:_reject("configure failed")
                return
            end
            -- Start the deferred task, chain its Future to ours
            start_one_task(overseer, task_def):next(
                function(...) deferred_f:_resolve(...) end,
                function(err) deferred_f:_reject(err) end
            )
        end)
    end

    -- Combine all task Futures — resolve when all complete
    local result_f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if all_ok then return true
        else error("one or more tasks failed") end
    end)

    -- Legacy callback support
    if on_all_done then
        result_f:next(function() on_all_done(true) end)
               :catch(function() on_all_done(false) end)
    end

    return result_f, total
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
--- Includes units that are unconfigured, configure_failed, or stale
--- (configuration options changed since last configure).
--- @param all_tasks table { configure: table[], build: table[] }
--- @return table[] configure tasks that actually need running
local function filter_unconfigured_tasks(all_tasks)
    local needs_configure = {}
    for _, task_def in ipairs(all_tasks.configure) do
        local lw_meta = task_def.loomworks
        if not lw_meta then goto next end

        local unit = lw_meta.unit
        local state = unit:state()
        local project_needs_refresh = unit._project and unit._project.needs_refresh
        if state == "unconfigured" or state == "configure_failed"
                or unit:is_stale() or project_needs_refresh then
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
--- Run a configure or build action on a single ConfigUnit.
--- Returns a Future that resolves on success, rejects on failure.
--- @param unit loomworks.ConfigUnit
--- @param action "configure"|"build"
--- @param on_complete? function legacy callback (deprecated)
--- @return loomworks.Future
function M.run_configuration_action(unit, action, on_complete)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local all_tasks = collect_configuration_tasks(unit)
        if not all_tasks then
            f:_reject("no tasks for " .. action)
            return
        end

        if action == "configure" then
            launch_tasks(overseer, all_tasks.configure):next(
                function() f:_resolve(true) end,
                function(err) f:_reject(err) end
            )
            return
        end

        if action == "build" then
            local needs_configure = filter_unconfigured_tasks(all_tasks)
            if #needs_configure > 0 then
                launch_tasks(overseer, needs_configure):next(function()
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    function() f:_resolve(true) end,
                    function(err)
                        vim.notify("loomworks: configure failed, skipping build", vim.log.levels.ERROR)
                        f:_reject(err)
                    end
                )
            else
                launch_tasks(overseer, all_tasks.build):next(
                    function() f:_resolve(true) end,
                    function(err) f:_reject(err) end
                )
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
        f:_reject("unknown action: " .. action)
    end

    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end

    -- Legacy callback support
    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end

    return f
end

--- Run clean tasks for a single configuration. Returns a Future.
--- @param unit loomworks.ConfigUnit
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @return loomworks.Future
function M.run_configuration_clean(unit, on_complete)
    local future_mod = require("loomworks.future")
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local tasks = collect_configuration_clean_tasks(unit)
    if not tasks or #tasks == 0 then
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    local task_futures = {}
    for _, task_def in ipairs(tasks) do
        local tf = future_mod.create(function(resolve, reject, token)
            local build_result = task_def.builder()
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)
            token:on_cancel(function()
                if task and not task:is_complete() then task:stop() end
            end)
            task:subscribe("on_complete", function(_, status)
                if status == "SUCCESS" then resolve(true)
                else reject("clean task failed") end
            end)
            task:start()
        end)
        task_futures[#task_futures + 1] = tf
    end

    local f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if all_ok then return true else error("clean failed") end
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Run clean tasks for all projects in a profile. Returns a Future.
--- @param profile loomworks.Profile
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @return loomworks.Future
function M.run_profile_clean(profile, on_complete)
    local future_mod = require("loomworks.future")
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local tasks = collect_profile_clean_tasks(profile)
    if not tasks or #tasks == 0 then
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    local task_futures = {}
    for _, task_def in ipairs(tasks) do
        local tf = future_mod.create(function(resolve, reject, token)
            local build_result = task_def.builder()
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)
            token:on_cancel(function()
                if task and not task:is_complete() then task:stop() end
            end)
            task:subscribe("on_complete", function(_, status)
                if status == "SUCCESS" then resolve(true)
                else reject("clean task failed") end
            end)
            task:start()
        end)
        task_futures[#task_futures + 1] = tf
    end

    local f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if all_ok then return true else error("clean failed") end
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
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
--- Launch a single task definition via overseer. Returns a Future.
--- @param task_def table task definition
--- @param unit loomworks.ConfigUnit
--- @param on_complete? function legacy callback (deprecated)
--- @return loomworks.Future
function M.launch_single_task(task_def, unit, on_complete)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local state = unit:state()
    if state == "unknown" or state == "building" then
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("unit in " .. state .. " state")
    end

    if task_def.loomworks then
        task_def.loomworks.unit = unit
    end

    local f = start_one_task(overseer, task_def)
    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Collect ConfigUnits and their target states from task definitions.
--- @param task_defs table[] task definitions with .loomworks
--- @param target_state string target ConfigUnit state (e.g. "configured", "built")
--- @return loomworks.ConfigUnit[] units
--- @return table<loomworks.ConfigUnit, string> target_states
local function collect_units_from_tasks(task_defs, target_state)
    local units = {}
    local target_states = {}
    local seen = {} -- unit -> true (dedup by identity)
    for _, task_def in ipairs(task_defs) do
        local meta = task_def.loomworks
        if meta and meta.unit and not seen[meta.unit] then
            seen[meta.unit] = true
            units[#units + 1] = meta.unit
            target_states[meta.unit] = target_state
        end
    end
    return units, target_states
end

--- Run all tasks of a given action for a profile. Returns a Future.
--- Creates an Operation to track progress and completion.
--- @param profile loomworks.Profile
--- @param action string "configure" or "build"
--- @return loomworks.Future
function M.run_profile_action(profile, action)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local all_tasks = collect_profile_tasks(profile)
        if not all_tasks then
            f:_reject("no tasks")
            return
        end

        if action == "configure" then
            local launchable = filter_launchable_tasks(all_tasks.configure)
            local units, target_states = collect_units_from_tasks(launchable, "configured")
            if #units > 0 then
                loomworks.create_operation(profile, "configure", units, target_states)
            end
            launch_tasks(overseer, all_tasks.configure):next(
                function() f:_resolve(true) end,
                function(err) f:_reject(err) end
            )
            return
        end

        if action == "build" then
            local needs_configure = filter_unconfigured_tasks(all_tasks)
            local launchable_builds = filter_launchable_tasks(all_tasks.build)
            local units, target_states = collect_units_from_tasks(launchable_builds, "built")

            if #needs_configure > 0 then
                local configure_units = collect_units_from_tasks(needs_configure, "built")
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

                launch_tasks(overseer, needs_configure):next(function()
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    function() f:_resolve(true) end,
                    function(err)
                        vim.notify("loomworks: configure failed, skipping build", vim.log.levels.ERROR)
                        if op and not op.completed then
                            op:cancel("configure failed")
                        end
                        f:_reject(err)
                    end
                )
            else
                if #units > 0 then
                    loomworks.create_operation(profile, "build", units, target_states)
                end
                launch_tasks(overseer, all_tasks.build):next(
                    function() f:_resolve(true) end,
                    function(err) f:_reject(err) end
                )
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
        f:_reject("unknown action: " .. action)
    end

    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end

    return f
end

return M
