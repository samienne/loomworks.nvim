--- loomworks/target.lua — Target class.
--- Represents a discovered build target from a module (cmake target, etc.).
--- Owns the build action for this specific target.

--- @class loomworks.Target
--- @field id string opaque target identifier (module-specific)
--- @field type string "executable"|"static_library"|"shared_library"|"module_library"|"object_library"|"interface_library"
--- @field dependencies? string[] project-owned targets this links against
--- @field artifact? string output file path (relative to build dir)
--- @field sources? string[] absolute source file paths (for test source mapping)
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
    self.sources = raw.sources
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

--- Build this target. Returns a Future that resolves on success.
--- Delegates to the module's build_target_task via overseer.
--- Falls back to full configuration build if module doesn't support it.
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @return loomworks.Future
function Target:build(on_complete)
    local future_mod = require("loomworks.future")
    local unit = self._config_unit
    if not unit or not unit._project then
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("no config unit or project")
    end

    local mod = unit._project._module and unit._project._module.impl or nil
    if not mod then
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("no module")
    end

    local f
    if mod.build_target_task then
        local ws = unit._workspace
        local project_ctx = unit._project:to_module_context(ws.root)
        project_ctx.configuration = unit:variant()
        project_ctx.configuration_key = unit:config_key()
        project_ctx.tool_data = unit._tool and unit._tool.data or unit:tool_data()
        project_ctx.env = project_ctx.tool_data and project_ctx.tool_data.env or {}

        local task_def = mod.build_target_task(project_ctx, self.id)
        if task_def then
            f = require("loomworks.overseer").launch_single_task(task_def, unit)
        end
    end

    if not f then
        -- Fallback: full build
        f = require("loomworks.overseer").run_configuration_action(unit, "build")
    end

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Directory of a build-relative artifact path, or nil.
--- @param build_dir string
--- @param artifact string
--- @return string|nil
local function artifact_dir(build_dir, artifact)
    local full = (build_dir .. "/" .. artifact):gsub("\\", "/")
    return full:match("^(.*)/[^/]*$")
end

--- Compose the run environment for an executable target (§8.7): prepend to
--- PATH (1) the toolchain runtime dirs the module supplies via `runtime_path`
--- and (2) the build tree's shared-library / module-library output dirs, so a
--- DLL-dependent executable finds its siblings. Returns nil when there is
--- nothing to add (leave the process env inherited as-is).
---
--- Windows only: on Linux/macOS shared libraries are resolved via the rpath
--- meson/cmake bake into the build tree (and LD_LIBRARY_PATH / DYLD_*), NOT via
--- PATH, so there is nothing to do — rpath already makes the binary runnable
--- in place. Breadth here matches `meson devenv` (the whole build tree's lib
--- dirs); dirs are added in a deterministic (sorted) order so PATH precedence
--- is stable rather than hash-order dependent.
--- @param unit loomworks.ConfigUnit
--- @param build_dir string
--- @return table<string,string>|nil
local function compose_run_env(unit, build_dir)
    if vim.fn.has("win32") ~= 1 then return nil end

    local prefix, seen = {}, {}
    local function add(dir)
        if type(dir) == "string" and dir ~= "" and not seen[dir] then
            seen[dir] = true
            prefix[#prefix + 1] = dir
        end
    end

    -- (1) Toolchain runtime dirs (module-specific, e.g. compiler bin dir).
    local mod = unit._project and unit._project._module and unit._project._module.impl
    if mod and mod.runtime_path then
        local ok, dirs = pcall(mod.runtime_path, {
            build_dir = build_dir,
            tool_data = unit._tool_data,
            config_name = unit.variant and unit:variant() or nil,
        })
        if ok and type(dirs) == "table" then
            for _, d in ipairs(dirs) do add(d) end
        end
    end

    -- (2) Shared-library sibling output dirs (generic, from parse_targets).
    -- Sorted so PATH precedence is deterministic (parse output is unordered).
    local lib_dirs = {}
    for _, t in pairs(unit.targets or {}) do
        if (t.type == "shared_library" or t.type == "module_library") and t.artifact then
            local d = artifact_dir(build_dir, t.artifact)
            if d then lib_dirs[#lib_dirs + 1] = d end
        end
    end
    table.sort(lib_dirs)
    for _, d in ipairs(lib_dirs) do add(d) end

    if #prefix == 0 then return nil end
    return require("loomworks.runenv").compose(prefix)
end

--- Resolve the run spec (artifact path, working directory, and run
--- environment) for this executable target. Pure — expands nothing, spawns no
--- task. Shared seam for `Target:launch` (editor) and the headless runner
--- (§16.17): both resolve the same spec, then execute it via their own runner.
--- @param opts? { working_dir?: string } working_dir is a pre-resolved
---   absolute cwd override (§8.7); absent → the owning project's directory.
--- @return { cmd: string, cwd: string, name: string, env: table|nil }|nil spec
--- @return string|nil err
function Target:resolve_run_spec(opts)
    opts = opts or {}
    if not self:is_executable() then
        return nil, "target '" .. tostring(self.id) .. "' is not an executable"
    end
    if not self.artifact then
        return nil, "target '" .. tostring(self.id) .. "' has no built artifact"
    end
    local unit = self._config_unit
    if not unit then
        return nil, "target '" .. tostring(self.id) .. "' has no config unit"
    end
    local build_dir = unit:build_dir()
    if not build_dir then
        return nil, "no build directory for target '" .. tostring(self.id) .. "'"
    end
    local project = unit._project
    local project_name = project and project.key or unit._init_project_key or "?"
    -- Working directory (§8.7): explicit override, else the project directory
    -- (consistent with command-type launches), falling back to the build dir
    -- only if the project dir can't be resolved.
    local cwd = opts.working_dir
    if not cwd or cwd == "" then
        cwd = (project and project.abs_path and project:abs_path()) or build_dir
    end
    return {
        cmd = build_dir .. "/" .. self.artifact,
        cwd = cwd,
        name = project_name .. ": run " .. self.id,
        env = compose_run_env(unit, build_dir),
    }
end

--- Launch this target (run the built artifact).
--- Only works for executables with an artifact path.
--- @param opts? { working_dir?: string } pre-resolved absolute cwd override (§8.7)
function Target:launch(opts)
    local spec, err = self:resolve_run_spec(opts)
    if not spec then
        if err then vim.notify("loomworks: " .. err, vim.log.levels.WARN) end
        return
    end

    local overseer = require("loomworks.overseer")
    return overseer.launch_run_task({
        name = spec.name,
        cmd = spec.cmd,
        cwd = spec.cwd,
        env = spec.env,
    })
end

return Target
