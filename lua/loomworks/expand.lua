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

--- Build a launch expansion context from workspace state.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param project_key string
--- @return table<string, string>
function M.launch_context(ws, profile, project_key)
    local ctx = {
        workspace_root = ws.root,
    }

    -- Project path
    local proj_cfg = ws.config.projects[project_key]
    if proj_cfg then
        ctx.project_path = proj_cfg.path or project_key
    end

    -- Configuration set name
    if profile.configuration_set then
        ctx.config_set = profile.configuration_set
    end

    -- Variant for this project in the active config set
    if profile.mappings and profile.mappings[project_key] then
        ctx.variant = profile.mappings[project_key]
    end

    return ctx
end

return M
