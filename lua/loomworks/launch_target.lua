--- loomworks/launch_target.lua — LaunchTarget class.
--- Represents a user's selected build/launch target for a profile.
--- Supports module targets (cmake executables) and command-type launch
--- configs from loomworks.json.

local expand = require("loomworks.expand")

--- @class loomworks.LaunchTarget
--- @field _core loomworks.Core
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
--- @param core loomworks.Core
--- @param profile loomworks.Profile
--- @param descriptor { project: string, target?: string, launch?: string }
--- @return loomworks.LaunchTarget
function LaunchTarget.new(core, profile, descriptor)
    local self = setmetatable({}, LaunchTarget)
    self._core = core
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
    self._project = self._core._projects[descriptor.project]

    -- Resolve ConfigUnit and Target
    self._config_unit = nil
    self._target = nil
    if self._project and self._profile.mappings then
        local variant = self._profile.mappings[descriptor.project]
        if variant then
            local config_key = self._profile:config_key(variant, self._project.type)
            self._config_unit = self._core:get_config_unit(descriptor.project, config_key)
            if self._config_unit and self._config_unit.targets and self._target_id then
                self._target = self._config_unit.targets[self._target_id]
            end
        end
    end

    -- Resolve launch config from loomworks.json project definition
    self._launch_config = nil
    if self._launch_name and self._project then
        local ws = self._core:get_workspace()
        if ws then
            local proj_cfg = ws.config.projects[self._project.key]
            if proj_cfg and proj_cfg.launch and proj_cfg.launch[self._launch_name] then
                self._launch_config = proj_cfg.launch[self._launch_name]
            end
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

--- Build this target.
--- Delegates to the Target object's build method (module targets only).
function LaunchTarget:build()
    if self._target then
        self._target:build()
    end
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

    local ws = self._core:get_workspace()
    if not ws then return end

    -- Build expansion context
    local ctx = expand.launch_context(ws, self._profile, self._project.key)

    -- Expand variables
    local cmd = { expand.expand_string(cfg.command, ctx) }
    local args = expand.expand_array(cfg.args, ctx)
    if args then
        for _, arg in ipairs(args) do
            cmd[#cmd + 1] = arg
        end
    end

    local cwd = cfg.working_dir
        and (ws.root .. "/" .. expand.expand_string(cfg.working_dir, ctx))
        or (ws.root .. "/" .. (self._project.path or self._project.key))

    local env = expand.expand_dict(cfg.env, ctx)

    local task_name = self._project.key .. ": " .. (self._launch_name or "launch")

    local overseer = require("loomworks.overseer")
    self._launch_task_id = overseer.launch_run_task({
        name = task_name,
        cmd = cmd,
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
--- @return boolean
function LaunchTarget:is_buildable()
    return self._target ~= nil
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
