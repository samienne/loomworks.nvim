--- loomworks/expand.lua — Variable expansion for strings and tables.
---
--- Expands ${VAR} patterns in strings. Supports environment variables
--- and workspace-level context variables.

local M = {}

--- Expand ${VAR} patterns in a string using a context table.
--- Falls back to environment variables for unknown keys.
--- @param s string input string
--- @param ctx? table<string, string> context variables (e.g., config_set, variant)
--- @return string expanded
function M.expand_string(s, ctx)
    if not s or type(s) ~= "string" then return s end
    return s:gsub("%${([^}]+)}", function(var)
        if ctx and ctx[var] then
            return ctx[var]
        end
        return os.getenv(var) or "${" .. var .. "}"
    end)
end

--- Expand variables in a table of strings (array).
--- @param arr string[]|nil
--- @param ctx? table<string, string>
--- @return string[]|nil
function M.expand_array(arr, ctx)
    if not arr then return nil end
    local result = {}
    for i, s in ipairs(arr) do
        result[i] = M.expand_string(s, ctx)
    end
    return result
end

--- Expand variables in a dict of string values.
--- @param dict table<string, string>|nil
--- @param ctx? table<string, string>
--- @return table<string, string>|nil
function M.expand_dict(dict, ctx)
    if not dict then return nil end
    local result = {}
    for k, v in pairs(dict) do
        result[k] = M.expand_string(v, ctx)
    end
    return result
end

--- The host directory of a resolved build target's artifact (spec §8.7
--- `${target_dir}`), or nil while it is not known: no artifact, no build
--- directory, or a unit not configured on this machine.
--- @param target loomworks.Target|nil
--- @param unit loomworks.ConfigUnit|nil the unit the target belongs to (fallback)
--- @return string|nil
function M.target_dir(target, unit)
    if type(target) ~= "table" or type(target.artifact) ~= "string" or target.artifact == "" then
        return nil
    end
    local u = target._config_unit or unit
    local paths = require("loomworks.paths")
    local artifact = target.artifact
    if not paths.is_absolute(artifact) then
        if not u then return nil end
        if type(u.configured_here) == "function" and not u:configured_here() then return nil end
        local bd = type(u.build_dir) == "function" and u:build_dir() or u.build_dir_value
        if type(bd) ~= "string" or bd == "" then return nil end
        artifact = paths.artifact_path(bd, artifact)
    end
    artifact = artifact:gsub("\\", "/")
    return artifact:match("^(.*)/[^/]*$") or nil
end

--- Build a launch expansion context from workspace state.
--- `opts.target` is the build target the thing being run resolves to (a
--- target-backed launch's, a default target's, a saved entry's, a named test
--- target's): it defines `${target_dir}` (spec §8.7), absent otherwise — so
--- a reference to it is unresolved, never empty.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param project loomworks.Project
--- @param opts? { target?: loomworks.Target|nil }
--- @return table<string, string>
function M.launch_context(ws, profile, project, opts)
    local ctx = {
        workspace_root = ws.root,
    }

    -- Project path
    ctx.project_path = project.path or project.key

    -- Configuration set name
    if profile._config_set_ref then
        ctx.config_set = profile._config_set_ref.name
    end

    -- Variant for this project in the active config set
    if profile.mappings and profile.mappings[project.key] then
        ctx.variant = profile.mappings[project.key]
    end

    -- Build directory for this project in this profile
    local pp = profile:project(project.key)
    if pp and pp._config_unit then
        ctx.build_dir = pp._config_unit.build_dir_value or ""
    end

    -- The resolved build target's artifact directory (built-in, before the
    -- project variables so they may reference it).
    if opts and opts.target then
        ctx.target_dir = M.target_dir(opts.target, pp and pp._config_unit or nil)
    end

    -- User-defined project variables (resolved via configuration inheritance,
    -- honouring compiler-specific overrides for the active tool's family).
    if project.variables and next(project.variables) then
        local unit = pp and pp._config_unit or nil
        local configuration = unit and unit._configuration or nil
        local tool_data = unit and (unit._tool and unit._tool.data or unit._tool_data) or nil
        local family = require("loomworks.cpp_compilers").family_from_tool_data(tool_data)
        local variables = require("loomworks.variables")
        -- The launch context resolves within the active profile, so its
        -- blank-variable fill values (§1.3.1) apply. A still-blank value is
        -- skipped (left out of the context).
        local resolved = variables.resolve(project, configuration, family, profile)
        for name, entry in pairs(resolved) do
            -- Two-pass: variable values can reference built-in variables
            if entry.value ~= nil then
                ctx[name] = M.expand_string(entry.value, ctx)
            end
        end
    end

    return ctx
end

--- Return the sorted list of `${name}` references in a string that cannot be
--- resolved from `ctx` nor from the process environment. These are the
--- "undeclared variable" references (core §1.3.1) — a `${name}` that is
--- neither a built-in, a declared project variable (both provided via `ctx`),
--- nor an environment variable. Callers use this to raise a diagnostic rather
--- than let the reference expand to a literal `${name}`.
--- @param s string|nil
--- @param ctx? table<string, string>
--- @return string[]
function M.unresolved_vars(s, ctx)
    local out, seen = {}, {}
    if type(s) ~= "string" then return out end
    for var in s:gmatch("%${([^}]+)}") do
        local resolved = (ctx and ctx[var] ~= nil) or (os.getenv(var) ~= nil)
        if not resolved and not seen[var] then
            seen[var] = true
            out[#out + 1] = var
        end
    end
    table.sort(out)
    return out
end

return M
