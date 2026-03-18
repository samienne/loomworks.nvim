--- loomworks/target.lua — Target class.
--- Represents a discovered build target from a module (cmake target, etc.).
--- Owns the build action for this specific target.

--- @class loomworks.Target
--- @field id string opaque target identifier (module-specific)
--- @field type string "executable"|"static_library"|"shared_library"|"module_library"|"object_library"|"interface_library"
--- @field dependencies? string[] project-owned targets this links against
--- @field artifact? string output file path (relative to build dir)
--- @field _config_unit loomworks.ConfigUnit back-reference to owning unit
local Target = {}
Target.__index = Target

--- Create a new Target from raw parse data.
--- @param config_unit loomworks.ConfigUnit owning unit
--- @param id string opaque target identifier
--- @param raw { type: string, dependencies?: string[], artifact?: string }
--- @return loomworks.Target
function Target.new(config_unit, id, raw)
    local self = setmetatable({}, Target)
    self._config_unit = config_unit
    self.id = id
    self.type = raw.type
    self.dependencies = raw.dependencies
    self.artifact = raw.artifact
    return self
end

function Target:__tostring()
    return "Target(" .. self.id .. ")"
end

--- Check if this target is an executable.
--- @return boolean
function Target:is_executable()
    return self.type == "executable"
end

--- Check if this target is a library (any library type).
--- @return boolean
function Target:is_library()
    return self.type == "static_library"
        or self.type == "shared_library"
        or self.type == "module_library"
        or self.type == "object_library"
        or self.type == "interface_library"
end

--- Get a display name for this target.
--- @return string
function Target:display_name()
    return self.id
end

--- Build this target.
--- Delegates to the module's build_target_task via overseer.
--- Falls back to full configuration build if module doesn't support it.
function Target:build()
    local unit = self._config_unit
    if not unit or not unit._project then return end

    local modules = require("loomworks.modules")
    local mod = modules.get(unit._project.type)
    if not mod then return end

    if mod.build_target_task then
        local ws = unit._core:get_workspace()
        if not ws then return end
        local project_ctx = unit._project:to_module_context(ws.root)
        project_ctx.configuration = unit.variant
        project_ctx.configuration_key = unit.config_key
        project_ctx.tool_data = unit.tool and unit.tool.data or nil
        project_ctx.env = project_ctx.tool_data and project_ctx.tool_data.env or {}

        local task_def = mod.build_target_task(project_ctx, self.id)
        if task_def then
            require("loomworks.overseer").launch_single_task(task_def, unit)
            return
        end
    end

    -- Fallback: full build
    require("loomworks.overseer").run_configuration_action(unit, "build")
end

--- Launch this target (run the built artifact).
--- Only works for executables with an artifact path.
function Target:launch()
    if not self:is_executable() or not self.artifact then return end
    local unit = self._config_unit
    if not unit then return end

    local build_dir = unit:build_dir()
    if not build_dir then
        vim.notify("loomworks: no build directory for " .. self.id, vim.log.levels.WARN)
        return
    end

    local artifact_path = build_dir .. "/" .. self.artifact
    local project_name = unit._project and unit._project.key or unit.project_key

    local overseer = require("loomworks.overseer")
    return overseer.launch_run_task({
        name = project_name .. ": run " .. self.id,
        cmd = artifact_path,
        cwd = build_dir,
    })
end

return Target
