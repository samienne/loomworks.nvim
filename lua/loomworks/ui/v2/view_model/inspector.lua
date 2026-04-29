--- loomworks/ui/v2/view_model/inspector.lua — Inspector dispatch.
---
--- Given a ref ({ kind, key }) and the workspace, dispatches to the
--- right inspector kind module to build content. Returns an "empty"
--- inspector when ref is nil.

local M = {}

local kinds = {
    project       = require("loomworks.ui.v2.view_model.inspector_kinds.project"),
    profile       = require("loomworks.ui.v2.view_model.inspector_kinds.profile"),
    config_set    = require("loomworks.ui.v2.view_model.inspector_kinds.config_set"),
    configuration = require("loomworks.ui.v2.view_model.inspector_kinds.configuration"),
    launch        = require("loomworks.ui.v2.view_model.inspector_kinds.launch"),
    variable      = require("loomworks.ui.v2.view_model.inspector_kinds.variable"),
    device        = require("loomworks.ui.v2.view_model.inspector_kinds.device"),
    deploy_step   = require("loomworks.ui.v2.view_model.inspector_kinds.deploy_step"),
}

--- @param workspace loomworks.Workspace|nil
--- @param ref table|nil   { kind, ...kind-specific fields... }
--- @return table
function M.build(workspace, ref)
    if not ref then
        return { kind = "empty", subject = nil, hint_bar = {} }
    end
    local kind_mod = kinds[ref.kind]
    if not kind_mod then
        return {
            kind = "unknown",
            subject = ref.key or "?",
            ref_kind = ref.kind,
            hint_bar = {},
        }
    end
    return kind_mod.build(workspace, ref)
end

return M
