--- loomworks/ui/v2/view/activity_view.lua — Activity strip rendering.
---
--- v0: live mode only. Lists currently-running ConfigUnit tasks with
--- progress + elapsed. Empty state when nothing is running.

local M = {}

local STATE_HL = {
    configuring = "LoomworksRunning",
    building    = "LoomworksRunning",
    deleting    = "LoomworksDeleting",
}

local function fmt_elapsed(seconds)
    if not seconds then return "" end
    local s = math.floor(seconds + 0.5)
    if s < 60 then return string.format("%ds", s) end
    return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end

local function fmt_progress(row)
    if row.percent then
        if row.current and row.total then
            return string.format("[%d/%d] %d%%", row.current, row.total, row.percent)
        end
        return string.format("%d%%", row.percent)
    end
    if row.current and row.total then
        return string.format("[%d/%d]", row.current, row.total)
    end
    return ""
end

local function new_ctx()
    local ctx = { lines = {}, highlights = {} }
    function ctx:add(text)
        self.lines[#self.lines + 1] = text or ""
    end
    function ctx:hl_last_line(hl_group, col_start, col_end)
        local line_no = #self.lines
        local text = self.lines[line_no] or ""
        self.highlights[#self.highlights + 1] = {
            line = line_no,
            col_start = col_start or 0,
            col_end = col_end or #text,
            hl_group = hl_group,
        }
    end
    return ctx
end

--- @param activity table presentation.activity
--- @return string[] lines
--- @return table[] highlights
function M.render(activity)
    local ctx = new_ctx()

    if not activity or not activity.has_workspace then
        ctx:add("Activity")
        ctx:hl_last_line("Title")
        ctx:add("")
        ctx:add("  (no workspace)")
        ctx:hl_last_line("Comment")
        return ctx.lines, ctx.highlights
    end

    local count = activity.running_count or 0
    ctx:add(string.format("Activity  (%d running)", count))
    ctx:hl_last_line("Title")

    if count == 0 then
        ctx:add("")
        ctx:add("  no running tasks")
        ctx:hl_last_line("Comment")
    else
        for _, row in ipairs(activity.running or {}) do
            local action = row.action or row.state or "?"
            local subject = string.format("%s · %s", row.project_key, row.config_key)
            local progress = fmt_progress(row)
            local elapsed = fmt_elapsed(row.elapsed)
            local message = row.message and ("  " .. row.message) or ""
            local line = string.format("  %-9s %-40s %-12s %s%s",
                action, subject, progress, elapsed, message)
            ctx:add(line)
            local hl = STATE_HL[row.state]
            if hl then ctx:hl_last_line(hl) end
        end
    end

    -- Recent results
    if activity.recent_count and activity.recent_count > 0 then
        ctx:add("")
        ctx:add(string.format("Recent  (%d)", activity.recent_count))
        ctx:hl_last_line("Identifier")
        for _, r in ipairs(activity.recent or {}) do
            local mark = r.success and "✓" or "✗"
            local subject = string.format("%s · %s",
                r.project_key or "?", r.configuration_key or "?")
            local action = r.action or "?"
            local line = string.format("  %s %-9s %s", mark, action, subject)
            ctx:add(line)
            ctx:hl_last_line(r.success and "LoomworksBuilt" or "LoomworksFailed")
        end
    end

    return ctx.lines, ctx.highlights
end

return M
