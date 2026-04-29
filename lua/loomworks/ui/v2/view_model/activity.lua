--- loomworks/ui/v2/view_model/activity.lua — Activity strip presentation.
---
--- Pure function: workspace state in, presentation tree out.
---
--- v0 scope (live mode only):
---   - Walk all ConfigUnits in the workspace
---   - For each unit with a running action, emit a row with state +
---     progress + elapsed
---   - Group nothing for now — flat list keeps the strip readable
---
--- "Recent results" / plan mode are deferred to a later slice (require
--- a ring buffer of completed events tracked by the view model root).

local M = {}

--- @param unit loomworks.ConfigUnit
--- @return table row
local function row_from_unit(unit)
    local pkey = unit:project() and unit:project().key
        or unit._init_project_key
        or "?"
    local ckey = unit:config_key() or unit.id or "?"
    local progress = unit:progress()
    local elapsed = unit:elapsed()
    local state = unit:state()
    local pct
    if progress and progress.current and progress.total and progress.total > 0 then
        pct = math.floor((progress.current / progress.total) * 100 + 0.5)
    end
    return {
        project_key = pkey,
        config_key  = ckey,
        action      = unit:running_action(),
        state       = state,
        message     = progress and progress.message or nil,
        current     = progress and progress.current or nil,
        total       = progress and progress.total or nil,
        percent     = pct,
        elapsed     = elapsed,
        ref         = { kind = "config_unit", project_key = pkey, config_key = ckey },
    }
end

--- @param workspace loomworks.Workspace|nil
--- @return table presentation tree
function M.build(workspace)
    if not workspace then
        return { running = {}, running_count = 0, has_workspace = false }
    end
    local rows = {}
    for _, unit in pairs(workspace._config_units or {}) do
        if unit:running_action() then
            rows[#rows + 1] = row_from_unit(unit)
        end
    end
    table.sort(rows, function(a, b)
        if a.project_key ~= b.project_key then return a.project_key < b.project_key end
        return a.config_key < b.config_key
    end)
    return {
        running       = rows,
        running_count = #rows,
        has_workspace = true,
    }
end

return M
