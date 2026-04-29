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

local function default_resolved(workspace, draft)
    -- v0: no live ${...} expansion. Show the raw destination so the user
    -- knows what was typed; the spec calls for live preview which we
    -- defer to a follow-up slice.
    return draft.destination or ""
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

    local function field(id, label, value, kind)
        return {
            id    = id,
            label = label,
            value = tostring(value or ""),
            kind  = kind or "string",
            subject = { kind = "wire_draft", field = id },
        }
    end

    local fields = {
        field("destination",    "Destination",    draft.destination,    "string"),
        field("source_project", "Source project", draft.source_project, "string"),
        field("target",         "Target",         draft.target,         "string"),
        field("path",           "Path",           draft.path,           "string"),
        field("configuration",  "Configuration",  draft.configuration,  "string"),
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
