--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Supports module targets (e.g. cmake executables from file-api), command-type launch
--- configs from loomworks.json.

local expand = require("loomworks.expand")
local debug_mod = require("loomworks.debug")

--- @class loomworks.LaunchTarget
--- @field _workspace loomworks.Workspace
--- @field _profile loomworks.Profile direct reference
--- @field _project loomworks.Project|nil direct reference
--- @field _config_unit loomworks.ConfigUnit|nil direct reference
--- @field _target loomworks.Target|nil direct reference (module targets)
--- @field _target_id string|nil fallback identifier for re-resolution
--- @field _launch_config table|nil launch config from loomworks.json
--- @field _launch_name string|nil name of the launch config
--- @field _device_target_id string|nil device target ID (module-generated)
--- @field _device_target_label string|nil display label for device target
--- @field _launch_task_id number|nil overseer task ID of running launch
--- @field _removed boolean
local LaunchTarget = {}
LaunchTarget.__index = LaunchTarget

--- Create a new LaunchTarget from a descriptor.
--- @param workspace loomworks.Workspace
--- @param profile loomworks.Profile
--- @param descriptor { project: string, target?: string, launch?: string, device_target?: string, device_target_label?: string }
--- @return loomworks.LaunchTarget
function LaunchTarget.new(workspace, profile, descriptor)
    local self = setmetatable({}, LaunchTarget)
    self._workspace = workspace
    self._profile = profile
    self._removed = false
    self._launch_task_id = nil
    self:_update(descriptor)
    return self
end

--- Resolve references from descriptor (disk data → object references).
--- @param descriptor { project: string, target?: string, launch?: string, device_target?: string, device_target_label?: string }
function LaunchTarget:_update(descriptor)
    self._target_id = descriptor.target
    self._launch_name = descriptor.launch
    self._device_target_id = descriptor.device_target
    self._device_target_label = descriptor.device_target_label

    -- Resolve project from descriptor key (deserialization from user.json)
    self._project = nil
    for _, p in pairs(self._workspace._projects) do
        if p.key == descriptor.project then
            self._project = p
            break
        end
    end

    -- Resolve ConfigUnit via ProfileProject reference chain
    self._config_unit = nil
    self._target = nil
    if self._project then
        local pp = self._profile:project(descriptor.project)
        if pp then
            self._config_unit = pp._config_unit
            if self._config_unit and self._config_unit.targets and self._target_id then
                self._target = self._config_unit.targets[self._target_id]
            end
        end
    end

    -- Resolve launch config from project domain object
    self._launch_config = nil
    if self._launch_name and self._project then
        if self._project.launch and self._project.launch[self._launch_name] then
            self._launch_config = self._project.launch[self._launch_name]
        end
    end
end

function LaunchTarget:__tostring()
    local project_name = self._project and self._project.key or "?"
    if self._launch_name then
        return "LaunchTarget(" .. project_name .. " launch:" .. self._launch_name .. ")"
    end
    return "LaunchTarget(" .. project_name .. ": " .. (self._target_id or "?") .. ")"
end

--- Build this target, including dependencies.
--- Builds dependency projects first (in order), then builds this target.
--- @param on_complete? fun(success: boolean) called when build finishes
--- Build this target and all its dependencies. Returns a Future.
--- Dependencies include explicit (depends_on) and implicit (deploy sources).
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @return loomworks.Future
function LaunchTarget:build(on_complete)
    local future_mod = require("loomworks.future")
    local overseer = require("loomworks.overseer")

    -- Profile completeness gate. Defense-in-depth — session_tracker
    -- already calls Profile:assert_buildable before invoking
    -- target:build, but this protects callers that go straight to
    -- target:build without that guard (e.g. status-page actions
    -- that build a single target).
    if self._profile then
        local ok, err = self._profile:assert_buildable()
        if not ok then
            if on_complete then on_complete(false) end
            return future_mod.rejected(err)
        end
    end

    -- Guard: if the selected ConfigUnit points at an abstract
    -- Configuration (no `variant` set on module_config — the state
    -- we end up in when harmony's default_configurations couldn't
    -- parse build-profile.json5 and the profile references a stub
    -- user config), bail out with a specific error rather than
    -- handing a no-op variant to the module and watching the chain
    -- hang on a phantom task. A clear message beats a silent spinner.
    if self._config_unit and self._config_unit._configuration
        and self._config_unit._configuration.is_abstract
        and self._config_unit._configuration:is_abstract() then
        local cfg_name = self._config_unit._configuration.name or "?"
        local proj_name = self._project and self._project.key or "?"
        local err = string.format(
            "configuration '%s' on project '%s' is abstract "
            .. "(no variant resolved) — can't build. "
            .. "Check module auto-detection (e.g. `:messages` for "
            .. "harmony parse warnings).",
            cfg_name, proj_name)
        if on_complete then on_complete(false) end
        return future_mod.rejected(err)
    end

    local function build_self()
        if self._target then
            return self._target:build()
        elseif self._config_unit then
            return overseer.run_configuration_action(self._config_unit, "build")
        else
            return future_mod.resolved(true)
        end
    end

    -- Collect ALL dependencies: explicit + deploy source projects.
    -- Explicit `depends_on` entries use the active profile's mapping
    -- (no config hint); deploy source entries may pin
    -- `configuration:` in the descriptor so they can be built even
    -- when the source project isn't part of the active profile.
    local all_deps = {}
    local seen = {}
    if self._project then
        if self._project.depends_on then
            for _, dep in ipairs(self._project.depends_on) do
                local key = dep.key .. "\0"
                if not seen[key] then
                    seen[key] = true
                    all_deps[#all_deps + 1] = { project = dep, config_hint = nil }
                end
            end
        end
        local deploy_deps = self:_deploy_source_projects()
        for _, entry in ipairs(deploy_deps) do
            local key = entry.project.key .. "\0" .. (entry.config_hint or "")
            if not seen[key] then
                seen[key] = true
                all_deps[#all_deps + 1] = entry
            end
        end
    end

    local f = self:_build_deps(all_deps)
        :next(function() return self:_deploy_phase("pre_build") end)
        :next(function() return build_self() end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Build dependency projects sequentially. Returns a Future.
---
--- Each entry can be a Project or `{ project = Project, config_hint
--- = string|nil }`. `config_hint` is used to resolve a ConfigUnit
--- when the dep isn't part of the active profile (e.g. a deploy
--- source that pinned its `configuration:` in the descriptor). A
--- bare Project means "use the active profile's mapping for this
--- project" and errors if the project isn't in the profile.
---
--- Build invocation is unconditional — we hand the build off to
--- the module's build command (`cmake --build`, `ninja`, `hvigor`)
--- and let the build system decide whether anything actually
--- needs rebuilding. Short-circuiting on `state == "built"` would
--- miss source-file changes (ConfigUnit's `is_stale` only watches
--- options / module_config), and the build tool already handles
--- the "nothing to do" case fast enough that invoking it
--- unconditionally is cheaper than a stale-artifact correctness
--- bug.
--- @param deps (loomworks.Project | { project: loomworks.Project, config_hint: string|nil })[]
--- @return loomworks.Future
function LaunchTarget:_build_deps(deps)
    local future_mod = require("loomworks.future")
    if #deps == 0 then return future_mod.resolved(true) end

    local overseer = require("loomworks.overseer")
    local chain = future_mod.resolved(true)

    for _, raw in ipairs(deps) do
        local dep, hint
        if raw.project then
            dep, hint = raw.project, raw.config_hint
        else
            dep, hint = raw, nil
        end
        local captured_dep = dep
        local captured_hint = hint
        chain = chain:next(function()
            local unit = self:_resolve_dep_config_unit(captured_dep, captured_hint)
            if not unit then
                return future_mod.rejected(string.format(
                    "cannot resolve a configuration to build for "
                    .. "dependency '%s' — either add it to the active "
                    .. "profile's configuration_set, or pin "
                    .. "`configuration:` in the deploy source descriptor",
                    captured_dep.key))
            end
            vim.notify("loomworks: building dependency " .. captured_dep.key,
                vim.log.levels.INFO)
            return overseer.run_configuration_action(unit, "build")
        end)
    end

    return chain
end

--- Resolve a ConfigUnit for a dependency project. Prefers the
--- active profile's mapping for the project; falls back to the
--- deploy descriptor's `configuration:` hint by searching the
--- workspace's ConfigUnit registry for a match. Returns nil when
--- neither route yields a unit — the caller treats that as a hard
--- error with a clear message.
--- @param project loomworks.Project
--- @param config_hint string|nil canonical configuration name
--- @return loomworks.ConfigUnit|nil
function LaunchTarget:_resolve_dep_config_unit(project, config_hint)
    -- 1. Preferred: the project is in the active profile.
    local pp = self._profile:project(project.key)
    if pp and pp._config_unit then return pp._config_unit end

    -- 2. Pinned configuration in the deploy descriptor: find the
    --    matching ConfigUnit (or create one) in the workspace.
    if config_hint then
        local ws = self._workspace
        if ws and ws.find_config_unit then
            local cfg = project:get_configuration(config_hint)
            if cfg then
                local unit = ws:find_config_unit(project, cfg, nil)
                if unit then return unit end
                -- No existing ConfigUnit for this combo — materialise one.
                if ws.ensure_config_unit then
                    return ws:ensure_config_unit(project, cfg, nil)
                end
            end
        end
    end

    return nil
end

--- Collect the merged deploy dict (project-level + launch-level).
--- Returns nil when no deploy steps are declared at either level.
--- @return table<string, table[]>|nil
function LaunchTarget:_resolved_deploy()
    local deploy_mod = require("loomworks.deploy")
    local project_deploy = self._project and self._project.deploy or nil
    local launch_deploy = self._launch_config and self._launch_config.deploy or nil
    if not project_deploy and not launch_deploy then return nil end
    local merged = deploy_mod.merge_deploy_sources(project_deploy, launch_deploy)
    if not next(merged) then return nil end
    return merged
end

--- Collect source projects from deploy steps that need building,
--- paired with any `configuration:` hint from the deploy source
--- descriptor. De-dupes by (project, config_hint) — the same
--- source project built against two different variants legitimately
--- produces two build actions; the same project with no hint
--- collapses to a single entry.
--- @return { project: loomworks.Project, config_hint: string|nil }[]
function LaunchTarget:_deploy_source_projects()
    local deploy = self:_resolved_deploy()
    if not deploy then return {} end

    local seen = {}
    local result = {}

    for _, sources in pairs(deploy) do
        for _, src in ipairs(sources) do
            if src.project then
                local key = src.project .. "\0" .. (src.configuration or "")
                if not seen[key] then
                    seen[key] = true
                    for _, p in pairs(self._workspace._projects) do
                        if p.key == src.project and p ~= self._project then
                            result[#result + 1] = {
                                project = p,
                                config_hint = src.configuration,
                            }
                            break
                        end
                    end
                end
            end
        end
    end
    return result
end

--- Execute deploy steps for a single phase. Returns a Future.
--- @param phase "pre_build"|"post_build"
--- @return loomworks.Future
function LaunchTarget:_deploy_phase(phase)
    local future_mod = require("loomworks.future")
    local deploy = self:_resolved_deploy()
    if not deploy then return future_mod.resolved(true) end

    local deploy_mod = require("loomworks.deploy")
    local pre_dict, post_dict = deploy_mod.partition_by_phase(deploy)
    local phase_dict = phase == "pre_build" and pre_dict or post_dict
    if not next(phase_dict) then return future_mod.resolved(true) end

    if not self._project then
        return future_mod.rejected("no project for deploy")
    end

    local ws = self._workspace
    local ctx = {
        workspace = ws,
        profile = self._profile,
        launch_project = self._project,
    }

    local f = deploy_mod.execute_deploy_steps(
        phase_dict, ctx, ws._deploy_records, ws._core._deps.normalize)

    f:next(function() ws:_save_cache() end)

    return f
end

--- Execute post-build deploy steps before launching. Returns a Future.
--- Pre-build steps are handled inside build().
--- @param on_complete? fun(ok: boolean, err?: string) legacy callback (deprecated)
--- @return loomworks.Future
function LaunchTarget:deploy(on_complete)
    local f = self:_deploy_phase("post_build")
    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function(err) on_complete(false, err) end)
    end
    return f
end

--- Launch this target.
--- For command-type: constructs and runs overseer task from launch config.
--- For module targets: delegates to Target:launch().
--- Expands variables in command, args, env, working_dir.
function LaunchTarget:launch()
    if self._launch_config then
        self:_launch_command()
    elseif self._target and self._target:is_executable() then
        self._target:launch()
    end
end

--- Launch from a command-type config (loomworks.json launch section).
function LaunchTarget:_launch_command()
    local cfg = self._launch_config
    if not cfg or not cfg.command then return end

    local ws = self._workspace

    -- Build expansion context
    local ctx = expand.launch_context(ws, self._profile, self._project)

    -- Expand variables
    local cmd = expand.expand_string(cfg.command, ctx)
    local args = expand.expand_array(cfg.args, ctx) or {}

    local cwd
    if cfg.working_dir then
        local expanded_cwd = expand.expand_string(cfg.working_dir, ctx)
        -- If expansion produced an absolute path, use as-is; otherwise prepend workspace root
        if expanded_cwd:match("^/") or expanded_cwd:match("^%a:") then
            cwd = expanded_cwd
        else
            cwd = ws.root .. "/" .. expanded_cwd
        end
    else
        cwd = ws.root .. "/" .. (self._project.path or self._project.key)
    end

    local env = expand.expand_dict(cfg.env, ctx)

    -- Dispose previous completed launch task
    if self._launch_task_id then
        local ok_os, overseer_mod = pcall(require, "overseer")
        if ok_os then
            local task_list = require("overseer.task_list")
            local prev = task_list.get(self._launch_task_id)
            if prev and prev:is_complete() then
                prev:dispose()
            end
        end
    end

    local task_name = self._project.key .. ": " .. (self._launch_name or "launch")

    local overseer = require("loomworks.overseer")
    self._launch_task_id = overseer.launch_run_task({
        name = task_name,
        cmd = cmd,
        args = args,
        cwd = cwd,
        env = env,
    })
end

--- Debug this target via nvim-dap.
--- Falls back to launch() if nvim-dap is not available.
function LaunchTarget:debug()
    if not debug_mod.available() then
        self:launch()
        return
    end
    if self._launch_config then
        self:_debug_command()
    elseif self._target and self._target:is_executable() then
        self:_debug_target()
    end
end

--- Build the resolved spec data for debug from a command-type launch config.
--- Returns adapter-agnostic data. Adapter-specific transforms happen in debug.run().
--- @return table spec_data { command, args, cwd, env }
--- @return string adapter resolved adapter type
function LaunchTarget:_resolve_debug_spec()
    local cfg = self._launch_config
    local ws = self._workspace
    local ctx = expand.launch_context(ws, self._profile, self._project)

    local cmd = expand.expand_string(cfg.command, ctx)
    local args = expand.expand_array(cfg.args, ctx) or {}

    local cwd
    if cfg.working_dir then
        local expanded_cwd = expand.expand_string(cfg.working_dir, ctx)
        if expanded_cwd:match("^/") or expanded_cwd:match("^%a:") then
            cwd = expanded_cwd
        else
            cwd = ws.root .. "/" .. expanded_cwd
        end
    else
        cwd = ws.root .. "/" .. (self._project.path or self._project.key)
    end

    local env = expand.expand_dict(cfg.env, ctx)
    local lang = self._project._module and self._project._module:primary_language() or "c++"
    local adapter = debug_mod.resolve_adapter(ws, lang)

    return {
        program = cmd,
        args = args,
        cwd = cwd,
        env = env,
    }, adapter
end

--- Debug from a command-type config (loomworks.json launch section).
--- Check if this launch target has a multi-adapter debug config.
--- @return boolean
function LaunchTarget:is_multi_adapter()
    local cfg = self._launch_config
    return cfg and cfg.debug and type(cfg.debug) == "table" and #cfg.debug > 1
end

--- Get the resolved multi-adapter specs for this launch target.
--- Returns adapter entries and the base spec data for the primary adapter.
--- @return { adapter: string }[] adapters, table spec_data
function LaunchTarget:multi_adapter_specs()
    local cfg = self._launch_config
    local spec_data = self:_resolve_debug_spec()
    local ws = self._workspace
    local parsed = {}
    for _, entry in ipairs(cfg.debug) do
        local language = type(entry) == "string" and entry or entry.language
        parsed[#parsed + 1] = { adapter = debug_mod.resolve_adapter(ws, language) }
    end
    return parsed, spec_data
end

--- Debug from a command-type config (loomworks.json launch section).
--- Only handles single-adapter. Multi-adapter is handled by session_tracker.
function LaunchTarget:_debug_command()
    local cfg = self._launch_config
    if not cfg or not cfg.command then return end

    local spec_data, adapter = self:_resolve_debug_spec()

    -- Single adapter: use debug[] first entry if present, else module default
    if cfg.debug and type(cfg.debug) == "table" and #cfg.debug == 1 then
        local entry = cfg.debug[1]
        local language = type(entry) == "string" and entry or entry.language
        adapter = debug_mod.resolve_adapter(self._workspace, language)
    end

    debug_mod.run({
        name = self._project.key .. ": debug " .. (self._launch_name or "launch"),
        adapter = adapter,
        program = spec_data.program,
        args = spec_data.args,
        cwd = spec_data.cwd,
        env = spec_data.env,
        extra = spec_data.extra,
    })
end

--- Debug a module target (executable produced by a module, e.g. cmake).
function LaunchTarget:_debug_target()
    local target = self._target
    if not target:is_executable() or not target.artifact then return end

    local unit = target._config_unit
    if not unit then return end

    local build_dir = unit:build_dir()
    if not build_dir then
        vim.notify("loomworks: no build directory for " .. target.id, vim.log.levels.WARN)
        return
    end

    local artifact_path = build_dir .. "/" .. target.artifact
    local project_name = unit._project and unit._project.key or unit._init_project_key or "?"
    local lang = unit._project and unit._project._module and unit._project._module:primary_language() or "c++"

    debug_mod.run({
        name = project_name .. ": debug " .. target.id,
        program = artifact_path,
        cwd = build_dir,
        adapter = debug_mod.resolve_adapter(self._workspace, lang),
    })
end

--- Check if this target is still valid.
--- @return boolean
function LaunchTarget:is_valid()
    if self._launch_config then return true end
    if self._device_target_id then return self._config_unit ~= nil end
    return self._target ~= nil
end

--- Check if this target has a build step.
--- Module targets build via Target:build(). Command-type launches build
--- the whole project configuration via overseer.
--- Device targets build via config unit (assembleHap).
--- @return boolean
function LaunchTarget:is_buildable()
    if self._target then return true end
    return self._config_unit ~= nil
end

--- Check if this target can be launched.
--- @return boolean
function LaunchTarget:is_launchable()
    if self._launch_config then return true end
    if self._device_target_id then return self._config_unit ~= nil end
    return self._target ~= nil and self._target:is_executable()
end

--- Check if this target requires a device for deployment.
--- @return boolean
function LaunchTarget:requires_device()
    return self._device_target_id ~= nil
end

--- Check if the launched process is currently running.
--- @return boolean
function LaunchTarget:is_running()
    if not self._launch_task_id then return false end
    local ok, overseer = pcall(require, "overseer")
    if not ok then return false end
    local task_list = require("overseer.task_list")
    local task = task_list.get(self._launch_task_id)
    return task ~= nil and not task:is_complete()
end

--- Stop the running launch task.
function LaunchTarget:stop()
    if not self._launch_task_id then return end
    local ok, overseer = pcall(require, "overseer")
    if not ok then return end
    local task_list = require("overseer.task_list")
    local task = task_list.get(self._launch_task_id)
    if task and not task:is_complete() then
        task:stop()
    end
    self._launch_task_id = nil
end

-- ---------------------------------------------------------------------------
-- Device target operations
-- ---------------------------------------------------------------------------

--- Install the built artifact onto a device. Returns a Future.
--- Resolves the artifact path via the module, then runs the install command.
--- @param device_serial string
--- @return loomworks.Future
function LaunchTarget:device_install(device_serial)
    local future_mod = require("loomworks.future")
    local overseer = require("loomworks.overseer")

    local mod = self._project and self._project._module and self._project._module.impl
    if not mod or not mod.device_install or not mod.resolve_artifact then
        return future_mod.rejected("module does not support device install")
    end

    local unit = self._config_unit
    if not unit then
        return future_mod.rejected("no config unit for device install")
    end

    -- Build module context for resolve_artifact
    local ws = self._workspace
    local pp = self._profile:project(self._project.key)
    local config_info = unit._configuration and unit._configuration.module_config or {}
    local project_ctx = {
        path = self._project.path or self._project.key,
        workspace_root = ws.root,
        tool_data = unit._tool_data or {},
        build_dir = unit:build_dir(),
        config_info = config_info,
        configuration_key = unit._configuration and unit._configuration.name,
    }

    local artifact = mod.resolve_artifact(project_ctx, project_ctx.configuration_key)
    if not artifact then
        return future_mod.rejected("could not resolve artifact for device install")
    end

    local spec = mod.device_install(project_ctx.tool_data, device_serial, artifact)
    if not spec or not spec.cmd then
        return future_mod.rejected("module returned invalid device_install spec")
    end

    local task_name = self._project.key .. ": install on " .. device_serial
    return overseer.run_cmd_task({
        name = task_name,
        cmd = spec.cmd,
        args = spec.args,
        cwd = ws.root .. "/" .. (self._project.path or self._project.key),
        env = spec.env,
        check_output = spec.check_output,
    })
end

--- Resolve module-specific launch info (bundle_name, ability_name) for
--- this target. Shared by `device_launch` and the log-session flow
--- that needs `bundle_name` to look up the running app's PID.
--- @return table|nil
function LaunchTarget:device_launch_info()
    local mod = self._project and self._project._module and self._project._module.impl
    if not mod or not mod.resolve_launch_info then return nil end
    local unit = self._config_unit
    if not unit then return nil end
    local ws = self._workspace
    if not ws then return nil end
    local config_info = unit._configuration and unit._configuration.module_config or {}
    local project_path = ws.root .. "/" .. (self._project.path or self._project.key)
    return mod.resolve_launch_info(project_path, config_info, unit._tool_data or {})
end

--- Launch the app on a device. Returns a Future.
--- Resolves launch info via the module, then runs the launch command.
--- @param device_serial string
--- @return loomworks.Future
function LaunchTarget:device_launch(device_serial)
    local future_mod = require("loomworks.future")
    local overseer = require("loomworks.overseer")

    local mod = self._project and self._project._module and self._project._module.impl
    if not mod or not mod.device_launch or not mod.resolve_launch_info then
        return future_mod.rejected("module does not support device launch")
    end

    local unit = self._config_unit
    if not unit then
        return future_mod.rejected("no config unit for device launch")
    end

    local launch_info = self:device_launch_info()
    if not launch_info then
        return future_mod.rejected("could not resolve launch info for device")
    end

    local ws = self._workspace
    local project_path = ws.root .. "/" .. (self._project.path or self._project.key)

    local spec = mod.device_launch(unit._tool_data or {}, device_serial, launch_info)
    if not spec or not spec.cmd then
        return future_mod.rejected("module returned invalid device_launch spec")
    end

    local task_name = self._project.key .. ": launch on " .. device_serial
    return overseer.run_cmd_task({
        name = task_name,
        cmd = spec.cmd,
        args = spec.args,
        cwd = project_path,
        env = spec.env,
        check_output = spec.check_output,
    })
end

--- Resolve the PID of the launched app on the device. Polls the
--- module's `device_pid` command a few times — `aa start` returns
--- before the app is actually up, so the very first `pidof` often
--- yields nothing.
--- @param device_serial string
--- @param bundle_name string
--- @param opts? { tries?: number, interval_ms?: number }
--- @return loomworks.Future resolves with number (pid) or nil (app never appeared)
function LaunchTarget:device_resolve_pid(device_serial, bundle_name, opts)
    local future_mod = require("loomworks.future")
    local mod = self._project and self._project._module and self._project._module.impl
    if not mod or not mod.device_pid then
        return future_mod.resolved(nil)
    end

    local unit = self._config_unit
    local td = unit and unit._tool_data or {}
    local pid_spec = mod.device_pid(td, device_serial, bundle_name)
    if not pid_spec or not pid_spec.cmd then
        return future_mod.resolved(nil)
    end

    opts = opts or {}
    local tries = opts.tries or 6
    local interval_ms = opts.interval_ms or 300

    local cmd = vim.list_extend({ pid_spec.cmd }, pid_spec.args or {})

    return future_mod.create(function(resolve)
        local attempt = 0
        local function try_once()
            attempt = attempt + 1
            vim.system(cmd, { text = true, timeout = 3000 }, function(result)
                vim.schedule(function()
                    local pid
                    if result.code == 0 and result.stdout then
                        for line in result.stdout:gmatch("[^\r\n]+") do
                            local n = tonumber(vim.trim(line))
                            if n and n > 0 then pid = n; break end
                        end
                    end
                    if pid then
                        resolve(pid)
                    elseif attempt >= tries then
                        resolve(nil)
                    else
                        vim.defer_fn(try_once, interval_ms)
                    end
                end)
            end)
        end
        try_once()
    end)
end

-- Note: `device_log_start` used to live here. It was replaced by
-- `session_tracker` driving `loomworks.device_log.start` directly —
-- the log view + its overseer task now live in the device_log
-- module so they can share a ring buffer and a dedicated split,
-- rather than relying on overseer's default output-to-buffer view.

--- Stop the app on a device. Returns a Future.
--- Delegates to the module's `device_stop` (harmony:
--- `hdc shell aa force-stop -b <bundle>`). Session tracker calls
--- this from `stop_run()` when it knows the active run is a
--- device launch; it's fire-and-forget from the user's
--- perspective — we don't block teardown on the RPC.
--- @param device_serial string
--- @param bundle_name string
--- @return loomworks.Future
function LaunchTarget:device_stop(device_serial, bundle_name)
    local future_mod = require("loomworks.future")
    local overseer = require("loomworks.overseer")

    local mod = self._project and self._project._module and self._project._module.impl
    if not mod or not mod.device_stop then
        return future_mod.resolved(true)
    end
    local unit = self._config_unit
    local td = unit and unit._tool_data or {}
    local spec = mod.device_stop(td, device_serial, bundle_name)
    if not spec or not spec.cmd then
        return future_mod.resolved(true)
    end

    return overseer.run_cmd_task({
        name = self._project.key .. ": stop on " .. device_serial,
        cmd = spec.cmd,
        args = spec.args,
        check_output = spec.check_output,
    })
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

--- Get a display name for this target.
--- @return string
function LaunchTarget:display_name()
    local project_name = self._project and self._project.key or "?"
    if self._launch_name then
        return project_name .. ": " .. self._launch_name
    end
    if self._device_target_label then
        return project_name .. ": " .. self._device_target_label
    end
    if self._device_target_id then
        return project_name .. ": " .. self._device_target_id
    end
    if self._target then
        return project_name .. ": " .. self._target:display_name()
    end
    return project_name .. ": " .. (self._target_id or "?")
end

return LaunchTarget
