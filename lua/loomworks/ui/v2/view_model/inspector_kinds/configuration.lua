--- loomworks/ui/v2/view_model/inspector_kinds/configuration.lua
---
--- Read-only configuration inspector. Shows the canonical name,
--- inheritance chain, options (from cached state when available),
--- and source-missing flag. Belongs to a project.
---
--- ref: { kind = "configuration", project_key, config_name }

local M = {}

--- @param workspace loomworks.Workspace|nil
--- @param project_key string
--- @return loomworks.Project|nil
local function find_project(workspace, project_key)
    if not workspace or not workspace._projects then return nil end
    for _, p in pairs(workspace._projects) do
        if p.key == project_key then return p end
    end
    return nil
end

--- @param config loomworks.Configuration
--- @return string[]
local function inherits_chain(config)
    local out = {}
    for _, cfg in ipairs(config._inherits or {}) do
        out[#out + 1] = cfg.name
    end
    return out
end

--- @param config loomworks.Configuration
--- @return table[]
local function options_block(config)
    local out = {}
    if type(config.options) == "table" then
        for k, v in pairs(config.options) do
            out[#out + 1] = { key = k, value = tostring(v) }
        end
        table.sort(out, function(a, b) return a.key < b.key end)
    end
    return out
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "configuration", project_key: string, config_name: string }
--- @return table
function M.build(workspace, ref)
    local project = find_project(workspace, ref.project_key)
    if not project then
        return {
            kind        = "configuration",
            subject     = ref.config_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end
    local cfg = project:get_configuration(ref.config_name)
    if not cfg then
        return {
            kind        = "configuration",
            subject     = ref.config_name or "?",
            project_key = ref.project_key,
            missing     = true,
            hint_bar    = {},
        }
    end

    return {
        kind             = "configuration",
        subject          = cfg.name,
        project_key      = project.key,
        missing          = false,
        prefix           = cfg.prefix,
        base_name        = cfg.base_name,
        is_user          = cfg.is_user == true,
        is_default       = cfg.is_default == true,
        from_preset      = cfg.from_preset == true,
        source_missing   = cfg._source_missing == true,
        role             = cfg.role,
        unresolved_inherits = cfg:unresolved_inherits_names() or {},
        inherits         = inherits_chain(cfg),
        options          = options_block(cfg),
        intent           = cfg._intent or "local",
        publishable      = true,
        hint_bar         = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
