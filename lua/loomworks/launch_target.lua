--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Supports module targets (cmake executables) and command-type launch
--- configs from loomworks.json.

local expand = require("loomworks.expand")

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

    -- Resolve project string to Project object
    self._project = self._workspace._projects[descriptor.project]

    -- Resolve ConfigUnit and Target
    self._config_unit = nil
    self._target = nil
    if self._project and self._profile.mappings then
        local variant = self._profile.mappings[descriptor.project]
        if variant then
            local config_key = self._profile:config_key(variant, self._project.type)
            self._config_unit = self._workspace:get_config_unit(descriptor.project, config_key)
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
function LaunchTarget:build(on_complete)
    local function build_self(cb)
        if self._target then
            self._target:build(cb)
        elseif self._config_unit then
            require("loomworks.overseer").run_configuration_action(
                self._config_unit, "build", cb)
        elseif cb then
            vim.schedule(function() cb(true) end)
        end
    end

    -- Check for dependencies that need building first
    if self._project and self._project.depends_on then
        self:_build_deps(self._project.depends_on, 1, function(success)
            if not success then
                if on_complete then on_complete(false) end
                return
            end
            build_self(on_complete)
        end)
    else
        build_self(on_complete)
    end
end

--- Build dependency projects sequentially.
--- @param deps loomworks.Project[] dependency projects to build
--- @param idx number current index
--- @param on_complete fun(success: boolean)
function LaunchTarget:_build_deps(deps, idx, on_complete)
    if idx > #deps then
        on_complete(true)
        return
    end

    local dep = deps[idx]
    -- Find the ConfigUnit for this dependency in the active profile
    local pp = self._profile:project(dep.key)
    if not pp then
        -- Dependency not in this profile, skip
        self:_build_deps(deps, idx + 1, on_complete)
        return
    end

    local unit = self._workspace:get_config_unit(pp.project_key, pp.config_key)
    local state = unit:state()

    -- Already built or configured — skip
    if state == "built" or state == "configured" then
        self:_build_deps(deps, idx + 1, on_complete)
        return
    end

    -- Need to build this dependency
    vim.notify("loomworks: building dependency " .. dep.key, vim.log.levels.INFO)
    require("loomworks.overseer").run_configuration_action(unit, "build",
        function(success)
            if not success then
                vim.notify("loomworks: dependency " .. dep.key .. " build failed",
                    vim.log.levels.ERROR)
                on_complete(false)
                return
            end
            self:_build_deps(deps, idx + 1, on_complete)
        end)
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
