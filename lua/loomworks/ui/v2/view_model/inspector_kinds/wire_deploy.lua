--- loomworks/ui/v2/view_model/inspector_kinds/wire_deploy.lua
---
--- Form inspector for editing a deploy step. Reads its content from a
--- draft table maintained on the view model. The form is "live" — the
--- user edits fields, sees them update in the inspector, and explicitly
--- commits via the Save row or discards via Cancel.
---
--- Each editable row is wired into the standard set_field machinery via
--- a synthetic subject. Top-level fields (destination) use
--- `{ kind = "wire_draft", field = ... }`; per-source fields use
--- `{ kind = "wire_draft_source", index = i, field = ... }` so the layout
--- can route them to the right slot in the draft.
---
--- Multi-source support: draft.sources is an array. The form renders one
--- block per source plus a `+ Add source` sentinel. Save serialises as a
--- single object when the array has one element and as an array when it
--- has more than one (matching the deploy step file format).

local M = {}

local function find_project(workspace, key)
    if not workspace or not key or key == "" then return nil end
    for _, p in pairs(workspace._projects or {}) do
        if p.key == key then return p end
    end
    return nil
end

local function default_resolved(workspace, draft)
    local raw = draft.destination or ""
    if raw == "" or not workspace then return raw end
    local profile = workspace._active_profile
    if not profile then return raw end
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

local function workspace_project_keys(workspace)
    local out = {}
    if workspace and workspace._projects then
        for _, p in pairs(workspace._projects) do out[#out + 1] = p.key end
        table.sort(out)
    end
    return out
end

local function project_configuration_names(workspace, project_key)
    if not workspace or project_key == "" or not project_key then return {} end
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

--- Build editable fields for one source at `index` in the sources array.
--- @param workspace loomworks.Workspace|nil
--- @param source table
--- @param index integer
--- @return table[]
local function source_fields(workspace, source, index)
    local function field(field_name, label, value, kind, choices)
        return {
            id      = string.format("source[%d].%s", index, field_name),
            label   = string.format("Source %d %s", index, label),
            value   = tostring(value or ""),
            kind    = kind or "string",
            choices = choices,
            subject = {
                kind  = "wire_draft_source",
                index = index,
                field = field_name,
            },
        }
    end

    return {
        field("project",       "project",       source.project,       "picker",
            workspace_project_keys(workspace)),
        field("target",        "target",        source.target,        "string"),
        field("path",          "path",          source.path,          "string"),
        field("configuration", "configuration", source.configuration, "picker",
            project_configuration_names(workspace, source.project or "")),
        {
            id    = string.format("source[%d].pre_build", index),
            label = string.format("Source %d pre_build", index),
            value = source.pre_build and "true" or "false",
            kind  = "boolean",
            subject = {
                kind  = "wire_draft_source",
                index = index,
                field = "pre_build",
            },
        },
    }
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "wire_deploy" }
--- @param draft table|nil
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

    -- Top-level destination field
    local editable_fields = {
        {
            id      = "destination",
            label   = "Destination",
            value   = tostring(draft.destination or ""),
            kind    = "string",
            subject = { kind = "wire_draft", field = "destination" },
        },
    }

    -- Per-source rows
    local sources = draft.sources or {}
    local source_blocks = {}
    for i, source in ipairs(sources) do
        source_blocks[#source_blocks + 1] = {
            index  = i,
            source = source,
            fields = source_fields(workspace, source, i),
        }
        for _, f in ipairs(source_blocks[#source_blocks].fields) do
            editable_fields[#editable_fields + 1] = f
        end
    end

    return {
        kind            = "wire_deploy",
        subject         = subject_label,
        missing         = false,
        mode            = draft.mode,
        destination     = draft.destination,
        resolved        = default_resolved(workspace, draft),
        sources         = sources,
        source_blocks   = source_blocks,
        editable_fields = editable_fields,
        add_actions     = {
            source = { kind = "wire_source", parent = { kind = "wire_draft" }, label = "+ Add source" },
        },
        commit_actions  = {
            { kind = "wire_save",   label = "+ Save"   },
            { kind = "wire_cancel", label = "+ Cancel" },
        },
        hint_bar = {
            { key = "e",      label = "edit field" },
            { key = "<CR>",   label = "save / cancel / add" },
            { key = "<C-w>w", label = "cycle pane" },
        },
    }
end

return M
