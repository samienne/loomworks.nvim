--- loomworks/variables.lua — User-defined project variable resolution.
---
--- Projects declare variables with types and defaults. Configurations
--- override values via the inheritance chain. Resolution walks
--- Configuration object references (not name strings). No raw data
--- retained — declarations live on Project, overrides on Configuration.

local M = {}

--- Built-in variable names that user declarations cannot use.
M.RESERVED_NAMES = {
    workspace_root = true,
    build_dir = true,
    variant = true,
    config_set = true,
    project_path = true,
}

local VALID_TYPES = {
    string = true,
    path = true,
}

--- Validate project-level variable declarations.
--- @param variables table<string, { type: string, default: string }>
--- @return boolean ok, string|nil err
function M.validate_declarations(variables)
    if type(variables) ~= "table" then
        return false, "variables must be a table"
    end
    for name, decl in pairs(variables) do
        if type(name) ~= "string" or name == "" then
            return false, "variable name must be a non-empty string"
        end
        if M.RESERVED_NAMES[name] then
            return false, "variable '" .. name .. "' uses a reserved name"
        end
        if type(decl) ~= "table" then
            return false, "variable '" .. name .. "' declaration must be a table"
        end
        if not VALID_TYPES[decl.type] then
            return false, "variable '" .. name .. "' has invalid type '"
                .. tostring(decl.type) .. "' (expected 'string' or 'path')"
        end
        if type(decl.default) ~= "string" then
            return false, "variable '" .. name
                .. "' default must be a string"
        end
    end
    return true
end

--- Validate configuration-level variable overrides against declarations.
--- @param overrides table<string, string> name → value
--- @param declarations table<string, { type: string, default: string }>
--- @return boolean ok, string|nil err
function M.validate_overrides(overrides, declarations)
    if type(overrides) ~= "table" then
        return false, "variable overrides must be a table"
    end
    for name, value in pairs(overrides) do
        if not declarations[name] then
            return false, "variable override '" .. name
                .. "' is not declared in project variables"
        end
        if type(value) ~= "string" then
            return false, "variable override '" .. name
                .. "' must be a string value"
        end
    end
    return true
end

--- Resolve all variables for a (project, configuration) pair.
--- Walks the configuration inheritance chain via object references.
--- @param project loomworks.Project must have .variables declarations
--- @param configuration loomworks.Configuration|nil nil = project defaults only
--- @return table<string, { value: string, source_config: loomworks.Configuration|nil, type: string }>
function M.resolve(project, configuration)
    local declarations = project.variables
    if not declarations or not next(declarations) then return {} end

    local result = {}
    for name, decl in pairs(declarations) do
        local value = decl.default
        local source_config = nil

        if configuration then
            -- Search: this config → inherited configs (depth-first left-to-right)
            local found_value, found_source = M._search_override(
                configuration, name, {})
            if found_value then
                value = found_value
                source_config = found_source
            end
        end

        result[name] = {
            value = value,
            source_config = source_config,
            type = decl.type,
        }
    end

    return result
end

--- Search for a variable override in a configuration and its inheritance chain.
--- Uses object references (_inherits array) for traversal.
--- @param config loomworks.Configuration
--- @param name string variable name
--- @param visited table set of visited configs (cycle protection)
--- @return string|nil value, loomworks.Configuration|nil source_config
function M._search_override(config, name, visited)
    if visited[config] then return nil, nil end
    visited[config] = true

    -- Check this config's overrides
    if config.variables and config.variables[name] then
        return config.variables[name], config
    end

    -- Walk inherited configs (depth-first left-to-right)
    if config._inherits then
        for _, parent in ipairs(config._inherits) do
            local value, source = M._search_override(parent, name, visited)
            if value then return value, source end
        end
    end

    return nil, nil
end

return M
