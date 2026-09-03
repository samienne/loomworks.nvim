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

--- Known compiler families a configuration `overrides` block may key on.
--- Sourced from the shared compiler module so there is a single definition;
--- clang-cl is not a key of its own (it folds to `clang`).
M.KNOWN_FAMILIES = require("loomworks.cpp_compilers").KNOWN_FAMILIES

--- Validate a configuration's compiler-family `overrides` block against the
--- project's variable declarations (core §1.3.1). Shape is
--- `family → { name → value }`. Every overridden `name` MUST be declared in
--- the project `variables` — this is enforced at edit time so a bad block
--- never reaches the working copy. Unknown family keys are NOT rejected here;
--- they surface later as a workspace diagnostic (see
--- `Workspace:diagnostics`), so a hand-edited file with a typo'd family is
--- flagged rather than silently dropped.
--- @param overrides table<string, table<string, string>>
--- @param declarations table<string, { type: string, default: string }>|nil
--- @return boolean ok, string|nil err
function M.validate_compiler_overrides(overrides, declarations)
    if type(overrides) ~= "table" then
        return false, "overrides must be a table"
    end
    declarations = declarations or {}
    for family, entries in pairs(overrides) do
        if type(family) ~= "string" or family == "" then
            return false, "overrides family key must be a non-empty string"
        end
        if type(entries) ~= "table" then
            return false, "overrides['" .. tostring(family)
                .. "'] must be a table of name → value"
        end
        for name, value in pairs(entries) do
            if not declarations[name] then
                return false, "compiler override '" .. name .. "' (family '"
                    .. family .. "') is not declared in project variables"
            end
            if type(value) ~= "string" then
                return false, "compiler override '" .. name .. "' (family '"
                    .. family .. "') must be a string value"
            end
        end
    end
    return true
end

--- Return the sorted list of unknown family keys in a compiler `overrides`
--- block (keys not in `KNOWN_FAMILIES`). Empty when clean. Drives the
--- workspace diagnostic — the block is preserved verbatim, only flagged.
--- @param overrides table<string, table>|nil
--- @return string[]
function M.unknown_families(overrides)
    local out = {}
    if type(overrides) ~= "table" then return out end
    for family in pairs(overrides) do
        if type(family) == "string" and not M.KNOWN_FAMILIES[family:lower()] then
            out[#out + 1] = family
        end
    end
    table.sort(out)
    return out
end

--- Resolve all variables for a (project, configuration) pair, optionally
--- honouring compiler-specific `overrides` for the active compiler family.
--- Walks the configuration inheritance chain via object references
--- (most-specific → least); the project `default` is the final fallback.
--- Within a single chain level a matching `overrides[active_family][name]`
--- wins over the compiler-agnostic `variables[name]`; chain position
--- dominates compiler-specificity (core §1.3.1).
--- @param project loomworks.Project must have .variables declarations
--- @param configuration loomworks.Configuration|nil nil = project defaults only
--- @param active_family? "clang"|"gcc"|"msvc"|nil active compiler family; nil = no overrides
--- @return table<string, { value: string, source_config: loomworks.Configuration|nil, type: string, from_override: boolean }>
function M.resolve(project, configuration, active_family)
    local declarations = project.variables
    if not declarations or not next(declarations) then return {} end

    local result = {}
    for name, decl in pairs(declarations) do
        local value = decl.default
        local source_config = nil
        local from_override = false

        if configuration then
            -- Search: this config → inherited configs (depth-first left-to-right)
            local found_value, found_source, found_override = M._search_override(
                configuration, name, active_family, {})
            if found_value ~= nil then
                value = found_value
                source_config = found_source
                from_override = found_override or false
            end
        end

        result[name] = {
            value = value,
            source_config = source_config,
            type = decl.type,
            from_override = from_override,
        }
    end

    return result
end

--- Search for a variable value in a configuration and its inheritance chain.
--- Uses object references (_inherits array) for traversal. At each level the
--- compiler-specific `overrides[active_family][name]` is preferred over the
--- plain `variables[name]`, but the whole level (override + plain) is checked
--- before descending — so a nearer plain value shadows a farther override.
--- @param config loomworks.Configuration
--- @param name string variable name
--- @param active_family string|nil active compiler family
--- @param visited table set of visited configs (cycle protection)
--- @return string|nil value, loomworks.Configuration|nil source_config, boolean|nil from_override
function M._search_override(config, name, active_family, visited)
    if visited[config] then return nil, nil, nil end
    visited[config] = true

    -- 1. Compiler-specific override at this level wins (intra-level tiebreaker).
    if active_family and config._overrides then
        local family_entries = config._overrides[active_family]
        if family_entries and family_entries[name] ~= nil then
            return family_entries[name], config, true
        end
    end

    -- 2. Compiler-agnostic value at this level.
    if config.variables and config.variables[name] ~= nil then
        return config.variables[name], config, false
    end

    -- 3. Walk inherited configs (depth-first left-to-right).
    if config._inherits then
        for _, parent in ipairs(config._inherits) do
            local value, source, is_override =
                M._search_override(parent, name, active_family, visited)
            if value ~= nil then return value, source, is_override end
        end
    end

    return nil, nil, nil
end

return M
