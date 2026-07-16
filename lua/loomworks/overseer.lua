local M = {}

local nice = require("loomworks.nice")

--- Action set that gets the nice/ionice wrapper. Configure, build and
--- clean are the long-running ones competing with the editor for CPU
--- and disk; test runs are wrapped at the loomtest runner instead
--- (because they don't pass through this module's action dispatch).
--- Detection probes (parse_targets, get_options, version checks) are
--- intentionally excluded — those are short and user-blocking, so
--- niceing them just makes the editor feel slow.
local NICE_ACTIONS = { configure = true, build = true, clean = true }

--- Wrap the `cmd` field of a task builder result with nice/ionice when
--- the action qualifies. No-op on non-Linux or when the wrapper
--- binaries are missing (see `loomworks.nice`).
--- @param build_result table builder() output with optional `cmd`
--- @param action string|nil loomworks action tag
--- @return table the same build_result (mutated in place)
local function apply_nice(build_result, action)
    if not action or not NICE_ACTIONS[action] then return build_result end
    if type(build_result.cmd) ~= "table" then return build_result end
    build_result.cmd = nice.wrap_cmd(build_result.cmd)
    return build_result
end

--- Resolve user-declared project variables for the active configuration.
--- Returns nil when the project has no variable declarations so module
--- contexts stay lean. The Configuration object is the inheritance root —
--- pass nil to get project-default values only.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @return table<string, { value: string, type: string }>|nil
local function resolve_project_variables(project, configuration)
    if not project or not project.variables or not next(project.variables) then
        return nil
    end
    local variables = require("loomworks.variables")
    local resolved = variables.resolve(project, configuration)
    if not next(resolved) then return nil end
    -- Drop the source_config reference: modules shouldn't depend on
    -- Configuration object identity, and the value is what's load-bearing
    -- for command expansion.
    local out = {}
    for name, entry in pairs(resolved) do
        out[name] = { value = entry.value, type = entry.type }
    end
    return out
end

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
        resolved_variables = resolve_project_variables(project, unit._configuration),
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

--- Return a raw build command spec for a ConfigUnit.
--- Intended for callers that want to invoke a plain overseer task
--- without going through the loomworks task tracker (e.g. loomtest
--- auto-building tests). Delegates to the module via `build_target_task`
--- when a specific target is requested and the module supports it,
--- otherwise falls back to the "build" action from `module.tasks()`.
--- @param unit loomworks.ConfigUnit
--- @param target_id? string optional target to build in isolation
--- @return table|nil spec `{ cmd, cwd?, env? }` or nil when unavailable
function M.build_spec_for(unit, target_id)
    local project = unit._project
    if not project then return nil end
    local mod = project._module and project._module.impl or nil
    if not mod then return nil end

    -- Build a ctx the module's tasks can consume (same shape as
    -- collect_configuration_tasks uses).
    local ws = unit._workspace
    if not ws then return nil end
    local variant = unit:variant()
    local tool = unit._tool
    local tool_data = tool and tool.data or unit:tool_data()

    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local tc_for_module = project._type_config_for_module
        and project:_type_config_for_module() or (project.type_config or {})

    local mod_info = { configurations = {} }
    if mod.info then
        local ok, result = pcall(mod.info, abs_path, tc_for_module)
        if ok and result then mod_info = result end
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
        resolved_variables = resolve_project_variables(project, unit._configuration),
    }

    --- Validate spec types and coerce missing cwd to the workspace root.
    --- overseer's new_task rejects userdata fields with opaque messages,
    --- so normalize early and reject with a helpful one. Also applies
    --- the nice/ionice wrap — `build_spec_for` is only ever called for
    --- builds (per-target, or the build action fallback), so we wrap
    --- here unconditionally rather than threading an action arg through.
    --- @param spec table|nil
    --- @return table|nil normalized spec, string|nil err
    local function normalize(spec)
        if type(spec) ~= "table" or type(spec.cmd) ~= "table" then
            return nil, "builder returned no cmd array"
        end
        for i, c in ipairs(spec.cmd) do
            if type(c) ~= "string" then
                return nil, ("cmd[%d] is %s, not string"):format(i, type(c))
            end
        end
        -- cwd: coerce to string if sensible, else fall back to workspace root
        if spec.cwd == nil or type(spec.cwd) ~= "string" or spec.cwd == "" then
            spec.cwd = ws.root
        end
        if spec.env ~= nil and type(spec.env) ~= "table" then
            spec.env = nil
        end
        spec.cmd = nice.wrap_cmd(spec.cmd)
        return spec, nil
    end

    -- Prefer a per-target build when possible
    if target_id and mod.build_target_task then
        local ok, task_def = pcall(mod.build_target_task, project_ctx, target_id)
        if ok and task_def and task_def.builder then
            local ok2, spec = pcall(task_def.builder)
            if ok2 then
                local norm, err = normalize(spec)
                if norm then return norm end
                if err then
                    vim.notify("loomworks: build_target_task spec invalid: " .. err,
                        vim.log.levels.WARN)
                end
            end
        end
    end

    -- Fall back to the full "build" action from tasks()
    if not mod.tasks then return nil end
    local ok_t, mod_tasks = pcall(mod.tasks, project_ctx, variant)
    if not ok_t or type(mod_tasks) ~= "table" then return nil end
    for _, t in ipairs(mod_tasks) do
        if t.loomworks and t.loomworks.action == "build" and t.builder then
            local ok2, spec = pcall(t.builder)
            if ok2 then
                local norm, err = normalize(spec)
                if norm then return norm end
                if err then
                    vim.notify("loomworks: build task spec invalid: " .. err,
                        vim.log.levels.ERROR)
                    return nil
                end
            end
        end
    end
    return nil
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
            resolved_variables = resolve_project_variables(project, pp._configuration),
        }

        local pt = mod.progress_parser
                and mod.progress_parser(project_ctx, active_config)
                or nil

        local ok_t, mod_tasks = pcall(mod.tasks, project_ctx, active_config)
        if not ok_t or not mod_tasks then
            vim.notify("loomworks: module '" .. (project.type or "?") .. "' tasks() failed: " .. tostring(mod_tasks),
                vim.log.levels.ERROR)
            goto continue
        end
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
        resolved_variables = resolve_project_variables(project, unit._configuration),
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
            resolved_variables = resolve_project_variables(project, pp._configuration),
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
            apply_nice(build_result, lw_meta.action)
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
                        module_info = lw_meta.module_info,
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

        -- Protected start: catch errors so the Future always resolves/rejects.
        -- Surface the error to the user too — without this, a throw between
        -- `overseer.new_task()` and `task:start()` leaves the task wedged in
        -- PENDING with no visible signal (the Future rejects but Operations
        -- only observe ConfigUnit state changes, which never happen). The
        -- silent failure made the original `progress_parser` bug invisible.
        local function safe_start()
            local ok, err = pcall(do_start)
            if not ok then
                local msg = "loomworks: task start failed: " .. tostring(err)
                vim.schedule(function()
                    vim.notify(msg, vim.log.levels.ERROR)
                end)
                reject(msg)
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
--- @param opts? { force?: boolean } force=true bypasses readiness checks
--- @return loomworks.Future, number launched
local function launch_tasks(overseer, task_defs, on_all_done, opts)
    local future_mod = require("loomworks.future")
    local force = opts and opts.force or false

    -- Classify each task
    local to_launch, to_defer = {}, {}
    for _, task_def in ipairs(task_defs) do
        if not task_def.loomworks then goto next end
        if force then
            to_launch[#to_launch + 1] = task_def
        else
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

--- Build an ordered, overseer-free execution plan for a profile "build".
--- Mirrors run_profile_action("build") sequencing: configure the units that
--- need it (unconfigured / failed / stale), then build. Each step carries a
--- ready-to-spawn `{cmd, cwd, env}`. Intended for headless runners
--- (specification.md §16) — it requires no overseer.nvim and launches nothing.
--- @param profile loomworks.Profile
--- @return table[]|nil steps list of { kind, name, unit, cmd, cwd, env }
function M.plan_profile_build(profile)
    local all_tasks = collect_profile_tasks(profile)
    if not all_tasks then return nil end
    local needs_configure = filter_unconfigured_tasks(all_tasks)

    local steps = {}
    local function add(task_defs, kind)
        for _, td in ipairs(task_defs or {}) do
            if td.builder then
                local ok, spec = pcall(td.builder)
                if ok and type(spec) == "table" and type(spec.cmd) == "table" then
                    steps[#steps + 1] = {
                        kind = kind,
                        name = td.name,
                        unit = td.loomworks and td.loomworks.unit or nil,
                        cmd = spec.cmd,
                        cwd = (type(spec.cwd) == "string" and spec.cwd ~= "")
                            and spec.cwd or nil,
                        env = spec.env,
                    }
                end
            end
        end
    end
    add(needs_configure, "configure")
    add(all_tasks.build, "build")
    return steps
end

--- Build a headless "run all tests" plan for a profile: one step per buildable
--- unit's native test runner (TestUnit:run_command_all, spec §16.16). Assumes
--- the profile has already been built. Returns the test steps plus the number
--- of buildable units seen, so a caller can tell "all passed" from "no tests".
--- @param profile loomworks.Profile
--- @return table[]|nil steps, integer units_seen
function M.plan_profile_test(profile)
    local all_tasks = collect_profile_tasks(profile)
    if not all_tasks then return nil, 0 end

    -- Unique ConfigUnits from the build tasks.
    local seen, units = {}, {}
    for _, td in ipairs(all_tasks.build or {}) do
        local unit = td.loomworks and td.loomworks.unit
        if unit and not seen[unit] then seen[unit] = true; units[#units + 1] = unit end
    end

    local steps = {}
    for _, unit in ipairs(units) do
        local label = (unit._project and unit._project.key or "?") .. ":" .. tostring(unit:variant())
        for _, tu in ipairs(unit:test_units()) do
            if tu.run_command_all then
                local ok, spec = pcall(function() return tu:run_command_all() end)
                if ok and type(spec) == "table" and type(spec.cmd) == "table" then
                    steps[#steps + 1] = {
                        kind = "test",
                        name = label,
                        unit = unit,
                        cmd = spec.cmd,
                        cwd = (type(spec.cwd) == "string" and spec.cwd ~= "") and spec.cwd or nil,
                        env = spec.env,
                    }
                end
            end
        end
    end
    return steps, #units
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
function M.run_configuration_action(unit, action, on_complete, opts)
    local future_mod = require("loomworks.future")

    -- Tool/configuration compatibility gate. Refuse build/configure/
    -- rebuild when the active profile's tool can't honor the
    -- configuration's contract — going further would queue tasks
    -- that either fail opaquely or silently produce wrong-platform
    -- artefacts. The diagnostic already surfaces the same reason on
    -- the status page; this is the belt-and-braces path for users
    -- who act before reading the diagnostic. Runs before the
    -- overseer check because it's about the unit's state, not about
    -- task queueing. Compat error is per-(profile, configuration);
    -- ConfigUnit:tool_compat_error() resolves against the workspace's
    -- active profile.
    local compat_err = unit and unit.tool_compat_error
        and unit:tool_compat_error() or nil
    if compat_err then
        vim.notify(
            "loomworks: " .. compat_err
                .. " — change the profile's tool to match the configuration",
            vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected(compat_err)
    end

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local ws = unit._workspace
        local log = ws and ws._core and ws._core._deps.log
        if log then log:debug("run_configuration_action: %s for %s/%s",
            action, unit._init_project_key or "?", unit:variant() or "?") end

        local all_tasks = collect_configuration_tasks(unit)
        if not all_tasks then
            if log then log:warn("run_configuration_action: no tasks returned for %s", action) end
            f:_reject("no tasks for " .. action)
            return
        end

        if log then
            local n_conf = all_tasks.configure and #all_tasks.configure or 0
            local n_build = all_tasks.build and #all_tasks.build or 0
            log:debug("run_configuration_action: %d configure, %d build tasks", n_conf, n_build)
        end

        if action == "configure" then
            -- Force=true: explicit configure always runs, even if already configured
            launch_tasks(overseer, all_tasks.configure, nil, { force = true }):next(
                function() f:_resolve(true) end,
                function(err) f:_reject(err) end
            )
            return
        end

        if action == "build" then
            -- Apply parallel_jobs override
            if opts and opts.parallel_jobs then
                local jobs = tostring(opts.parallel_jobs)
                for _, task_def in ipairs(all_tasks.build or {}) do
                    local orig_builder = task_def.builder
                    task_def.builder = function()
                        local result = orig_builder()
                        result.cmd = result.cmd or {}
                        result.cmd[#result.cmd + 1] = "--"
                        result.cmd[#result.cmd + 1] = "-j" .. jobs
                        return result
                    end
                end
            end

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

    -- Clean invokes the module's build system, which needs the
    -- right SDK env to know where it's pointing. A
    -- mismatched tool would clean the wrong tree or fail opaquely.
    -- ConfigUnit:delete (rm-rf of the cached dir) is independent and
    -- remains allowed — see spec §3 `validate_config_tool`.
    local compat_err = unit and unit.tool_compat_error
        and unit:tool_compat_error() or nil
    if compat_err then
        vim.notify(
            "loomworks: " .. compat_err
                .. " — change the profile's tool to match the configuration",
            vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected(compat_err)
    end

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
            apply_nice(build_result, "clean")
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
            apply_nice(build_result, "clean")
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

--- Run a simple command as an overseer task. Returns a Future.
--- Used for device install/launch operations.
--- Supports `check_output(lines)` to detect failures when exit code is
--- unreliable (e.g., some device connectors return 0 on partial failure).
--- The function returns an error string to reject, or nil/true for success.
--- @param opts { name: string, cmd: string|string[], args?: string[], cwd?: string, env?: table, check_output?: fun(lines: string[]): string|nil }
--- @return loomworks.Future
function M.run_cmd_task(opts)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return future_mod.rejected("overseer.nvim not found")
    end

    local cmd = opts.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end

    return future_mod.create(function(resolve, reject)
        local output_lines = {}
        local task = overseer.new_task({
            name = opts.name,
            cmd = cmd,
            cwd = opts.cwd,
            env = opts.env,
            components = { "default" },
        })
        if opts.check_output then
            task:subscribe("on_output_lines", function(_, lines)
                for _, line in ipairs(lines or {}) do
                    output_lines[#output_lines + 1] = line
                end
            end)
        end
        task:subscribe("on_complete", function(_, status)
            if status ~= "SUCCESS" then
                reject(opts.name .. " failed (" .. tostring(status) .. ")")
                return
            end
            if opts.check_output then
                local err = opts.check_output(output_lines)
                if err then
                    reject(opts.name .. ": " .. err)
                    return
                end
            end
            resolve(true)
        end)
        task:start()
        overseer.open({ enter = false })
    end)
end

--- Run a long-running streaming task: every line of stdout is
--- forwarded to `opts.on_line` instead of displayed via overseer's
--- default output buffer. The overseer task itself still exists
--- (shows up in the task list, killable there) so the user has a
--- unified "what's running" view, but actual rendering happens in a
--- caller-owned surface (e.g. the device-log view).
---
--- Unlike `run_cmd_task` this does not return a Future — streaming
--- tasks don't have a meaningful "done" value; the caller holds the
--- task handle and tears it down when the owning session ends.
---
--- `on_complete(status)` fires when the task finishes (process exit,
--- user-stop, or error) — useful for the caller to invalidate its
--- own state, not for chaining.
--- @param opts { name: string, cmd: string|string[], args?: string[], cwd?: string, env?: table, on_line: fun(line: string), on_complete?: fun(status: string) }
--- @return table|nil overseer task handle
function M.run_streaming_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    local cmd = opts.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end

    -- Minimal component set: we want the task lifecycle (on_start /
    -- on_output_lines / on_complete hooks) but don't want the default
    -- output-to-buffer rendering — the caller is rendering lines
    -- somewhere else and duplicating them into a hidden task buffer
    -- is wasted memory for a firehose log tail.
    --
    -- `use_terminal = false` is CRITICAL for log tailing. Overseer's
    -- default jobstart strategy runs the process under a pty sized
    -- to the current nvim window, which hard-wraps long stdout lines
    -- at `vim.o.columns - 4` and emits ANSI cursor-positioning
    -- sequences between records. For line-oriented log output —
    -- lines routinely >200 chars — that turns every record into two or three
    -- fragments, none of which parse. A non-terminal jobstart uses
    -- a plain stdout pipe and gives us raw newline-separated output.
    local task = overseer.new_task({
        name = opts.name,
        cmd = cmd,
        cwd = opts.cwd,
        env = opts.env,
        strategy = { "jobstart", use_terminal = false },
        components = { "on_output_summarize", "on_exit_set_status" },
    })

    task:subscribe("on_output_lines", function(_, lines)
        for _, line in ipairs(lines or {}) do
            if opts.on_line then
                local ok_cb, err = pcall(opts.on_line, line)
                if not ok_cb then
                    vim.notify("loomworks: streaming on_line error: " .. tostring(err),
                        vim.log.levels.WARN)
                end
            end
        end
    end)

    if opts.on_complete then
        task:subscribe("on_complete", function(_, status)
            pcall(opts.on_complete, status)
        end)
    end

    task:start()
    return task
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
function M.run_profile_action(profile, action, opts)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local ws = loomworks.get_workspace()
        local log = ws and ws._core and ws._core._deps.log
        if log then log:debug("run_profile_action: %s for profile '%s'", action, profile.key) end

        local all_tasks = collect_profile_tasks(profile)
        if not all_tasks then
            if log then log:warn("run_profile_action: no tasks collected for profile '%s'", profile.key) end
            f:_reject("no tasks")
            return
        end

        -- Apply parallel_jobs override: wrap build task builders to append -jN
        if opts and opts.parallel_jobs then
            local jobs = tostring(opts.parallel_jobs)
            for _, task_def in ipairs(all_tasks.build or {}) do
                local orig_builder = task_def.builder
                task_def.builder = function()
                    local result = orig_builder()
                    result.cmd = result.cmd or {}
                    result.cmd[#result.cmd + 1] = "--"
                    result.cmd[#result.cmd + 1] = "-j" .. jobs
                    return result
                end
            end
        end

        if log then
            local n_conf = all_tasks.configure and #all_tasks.configure or 0
            local n_build = all_tasks.build and #all_tasks.build or 0
            log:debug("run_profile_action: %d configure, %d build tasks for '%s'", n_conf, n_build, profile.key)
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
