--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Supports module targets (cmake executables) and command-type launch
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
--- @field _launch_task_id number|nil overseer task ID of running launch
--- @field _removed boolean
local LaunchTarget = {}
LaunchTarget.__index = LaunchTarget

--- Create a new LaunchTarget from a descriptor.
--- @param workspace loomworks.Workspace
--- @param profile loomworks.Profile
--- @param descriptor { project: string, target?: string, launch?: string }
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
--- @param descriptor { project: string, target?: string, launch?: string }
function LaunchTarget:_update(descriptor)
    self._target_id = descriptor.target
    self._launch_name = descriptor.launch

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

    local function build_self()
        if self._target then
            return self._target:build()
        elseif self._config_unit then
            return overseer.run_configuration_action(self._config_unit, "build")
        else
            return future_mod.resolved(true)
        end
    end

    -- Collect ALL dependencies: explicit + deploy source projects
    local all_deps = {}
    local seen = {}
    if self._project then
        if self._project.depends_on then
            for _, dep in ipairs(self._project.depends_on) do
                if not seen[dep.key] then
                    seen[dep.key] = true
                    all_deps[#all_deps + 1] = dep
                end
            end
        end
        local deploy_deps = self:_deploy_source_projects()
        for _, dep in ipairs(deploy_deps) do
            if not seen[dep.key] then
                seen[dep.key] = true
                all_deps[#all_deps + 1] = dep
            end
        end
    end

    local f = self:_build_deps(all_deps):next(function()
        return build_self()
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Build dependency projects sequentially. Returns a Future.
--- @param deps loomworks.Project[]
--- @return loomworks.Future
function LaunchTarget:_build_deps(deps)
    local future_mod = require("loomworks.future")
    if #deps == 0 then return future_mod.resolved(true) end

    local overseer = require("loomworks.overseer")
    local chain = future_mod.resolved(true)

    for _, dep in ipairs(deps) do
        local captured_dep = dep
        chain = chain:next(function()
            local pp = self._profile:project(captured_dep.key)
            if not pp or not pp._config_unit then return true end

            local unit = pp._config_unit
            local state = unit:state()
            local project_needs_refresh = unit._project and unit._project.needs_refresh
            if state == "built" and not unit:is_stale() and not project_needs_refresh then
                return true
            end

            vim.notify("loomworks: building dependency " .. captured_dep.key, vim.log.levels.INFO)
            return overseer.run_configuration_action(unit, "build")
        end)
    end

    return chain
end

--- Collect unique source projects from deploy steps that need building.
--- Returns Project[] of deploy source projects not yet built.
--- @return loomworks.Project[]
function LaunchTarget:_deploy_source_projects()
    local cfg = self._launch_config
    if not cfg or not cfg.deploy or not next(cfg.deploy) then return {} end

    local deploy_mod = require("loomworks.deploy")
    local seen = {}
    local result = {}

    for _, source_val in pairs(cfg.deploy) do
        local sources = deploy_mod.normalize_sources(source_val)
        for _, src in ipairs(sources) do
            if src.project and not seen[src.project] then
                seen[src.project] = true
                -- Find project domain object
                for _, p in pairs(self._workspace._projects) do
                    if p.key == src.project and p ~= self._project then
                        result[#result + 1] = p
                        break
                    end
                end
            end
        end
    end
    return result
end

--- Execute deploy steps before launching. Returns a Future.
--- Source projects should already be built (build() handles all deps).
--- @param on_complete? fun(ok: boolean, err?: string) legacy callback (deprecated)
--- @return loomworks.Future
function LaunchTarget:deploy(on_complete)
    local future_mod = require("loomworks.future")
    local cfg = self._launch_config
    if not cfg or not cfg.deploy or not next(cfg.deploy) then
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    if not self._project then
        if on_complete then on_complete(false, "no project for deploy") end
        return future_mod.rejected("no project for deploy")
    end

    local deploy_mod = require("loomworks.deploy")
    local ws = self._workspace
    local ctx = {
        workspace = ws,
        profile = self._profile,
        launch_project = self._project,
    }

    local f = deploy_mod.execute_deploy_steps(
        cfg.deploy, ctx, ws._deploy_records, ws._core._deps.normalize)

    f:next(function() ws:_save_cache() end)

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

--- Debug from a command-type config (loomworks.json launch section).
function LaunchTarget:_debug_command()
    local cfg = self._launch_config
    if not cfg or not cfg.command then return end

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
    local mod_type = self._project._module and self._project._module.mod_type or "cmake"

    debug_mod.run({
        name = self._project.key .. ": debug " .. (self._launch_name or "launch"),
        program = cmd,
        args = args,
        cwd = cwd,
        env = env,
        adapter = debug_mod.resolve_adapter(ws, mod_type),
    })
end

--- Debug a module target (cmake executable).
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
    local mod_type = unit._project and unit._project._module and unit._project._module.mod_type or "cmake"

    debug_mod.run({
        name = project_name .. ": debug " .. target.id,
        program = artifact_path,
        cwd = build_dir,
        adapter = debug_mod.resolve_adapter(self._workspace, mod_type),
    })
end

--- Check if this target is still valid.
--- @return boolean
function LaunchTarget:is_valid()
    if self._launch_config then return true end
    return self._target ~= nil
end

--- Check if this target has a build step.
--- Module targets build via Target:build(). Command-type launches build
--- the whole project configuration via overseer.
--- @return boolean
function LaunchTarget:is_buildable()
    if self._target then return true end
    return self._config_unit ~= nil
end

--- Check if this target can be launched.
--- @return boolean
function LaunchTarget:is_launchable()
    if self._launch_config then return true end
    return self._target ~= nil and self._target:is_executable()
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

--- Get a display name for this target.
--- @return string
function LaunchTarget:display_name()
    local project_name = self._project and self._project.key or "?"
    if self._launch_name then
        return project_name .. ": " .. self._launch_name
    end
    if self._target then
        return project_name .. ": " .. self._target:display_name()
    end
    return project_name .. ": " .. (self._target_id or "?")
end

return LaunchTarget
