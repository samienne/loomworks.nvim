--- loomworks/ui/v2/view_model/inspector_kinds/wire_deploy.lua
---
--- Form inspector for editing a deploy step. Reads its content from a
--- draft table maintained on the view model. The form is "live" — the
--- user edits fields, sees them update in the inspector, and explicitly
--- commits via the Save row or discards via Cancel.
---
--- Each editable row is wired into the standard set_field machinery via
--- a synthetic subject `{ kind = "wire_draft", field = <field_name> }`,
--- so the layout's existing `e` handler prompts and dispatches as
--- usual. The view model recognises this synthetic subject and writes
--- back to the in-memory draft instead of the workspace.
---
--- Save / Cancel are emitted as `+ Add` sentinels so `<CR>` triggers
--- them, but with kinds `wire_save` / `wire_cancel` so the layout
--- routes them through dispatch instead of as new-item creation.

local M = {}

--- Find a project by key in the workspace.
--- @param workspace loomworks.Workspace|nil
--- @param key string
--- @return loomworks.Project|nil
local function find_project(workspace, key)
    if not workspace or not key or key == "" then return nil end
    for _, p in pairs(workspace._projects or {}) do
        if p.key == key then return p end
    end
    return nil
end

--- Resolve the destination string against the active profile + launch
--- project context. Returns the raw string when expansion fails (no
--- active profile, project not found, etc.) so the user always sees
--- something useful in the preview.
--- @param workspace loomworks.Workspace|nil
--- @param draft table
--- @return string
local function default_resolved(workspace, draft)
    local raw = draft.destination or ""
    if raw == "" or not workspace then return raw end
    local profile = workspace._active_profile
    if not profile then return raw end
    -- The launch belongs to draft.parent.project_key — that's the
    -- project context against which deploy destinations expand.
    local launch_project_key = draft.parent and draft.parent.project_key
    local project = find_project(workspace, launch_project_key)
    if not project then return raw end

    local ok, expand = pcall(require, "loomworks.expand")
    if not ok then return raw end
    local ok_ctx, ctx = pcall(expand.launch_context, workspace, profile, project)
    if not ok_ctx or not ctx then return raw end
    local ok_exp, expanded = pcall(expand.expand_string, raw, ctx)
    return ok_exp and expanded or raw
end

--- Sorted list of project keys in the workspace.
--- @param workspace loomworks.Workspace|nil
--- @return string[]
local function workspace_project_keys(workspace)
    local out = {}
    if workspace and workspace._projects then
        for _, p in pairs(workspace._projects) do
            out[#out + 1] = p.key
        end
        table.sort(out)
    end
    return out
end

--- Configurations for a given project, returned as canonical name strings.
--- @param workspace loomworks.Workspace|nil
--- @param project_key string
--- @return string[]
local function project_configuration_names(workspace, project_key)
    if not workspace or project_key == "" then return {} end
    for _, p in pairs(workspace._projects or {}) do
        if p.key == project_key then
            local out = {}
            for _, cfg in ipairs(p:get_configurations() or {}) do
                out[#out + 1] = cfg.name
            end
            table.sort(out)
            return out
        end
    end
    return {}
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "wire_deploy" }
--- @param draft table|nil  the view model's wire draft state
--- @return table
function M.build(workspace, ref, draft)
    if not draft then
        return {
            kind = "wire_deploy",
            subject = "(closed)",
            missing = true,
            hint_bar = {},
        }
    end

    local subject_label
    if draft.mode == "add" then
        subject_label = "new deploy step"
    else
        subject_label = "editing " .. tostring(draft.existing and draft.existing.destination or "")
    end

    local function field(id, label, value, kind, choices)
        return {
            id      = id,
            label   = label,
            value   = tostring(value or ""),
            kind    = kind or "string",
            choices = choices,
            subject = { kind = "wire_draft", field = id },
        }
    end

    local fields = {
        field("destination",    "Destination",    draft.destination,    "string"),
        field("source_project", "Source project", draft.source_project, "picker",
            workspace_project_keys(workspace)),
        field("target",         "Target",         draft.target,         "string"),
        field("path",           "Path",           draft.path,           "string"),
        field("configuration",  "Configuration",  draft.configuration,  "picker",
            project_configuration_names(workspace, draft.source_project or "")),
        -- pre_build is a boolean — the layout will handle the toggle.
        {
            id = "pre_build", label = "Pre-build phase",
            value = draft.pre_build and "true" or "false",
            kind = "boolean",
            subject = { kind = "wire_draft", field = "pre_build" },
        },
    }

    return {
        kind            = "wire_deploy",
        subject         = subject_label,
        missing         = false,
        mode            = draft.mode,
        destination     = draft.destination,
        resolved        = default_resolved(workspace, draft),
        source_project  = draft.source_project,
        target          = draft.target,
        path            = draft.path,
        configuration   = draft.configuration,
        pre_build       = draft.pre_build == true,
        editable_fields = fields,
        commit_actions  = {
            { kind = "wire_save",   label = "+ Save"   },
            { kind = "wire_cancel", label = "+ Cancel" },
        },
        hint_bar = {
            { key = "e",      label = "edit field" },
            { key = "<CR>",   label = "save / cancel" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
