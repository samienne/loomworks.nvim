--- loomworks/ui/v2/view/activity_view.lua — Activity strip rendering.
---
--- Renders both modes:
---   * live  — running ConfigUnit tasks + recent results
---   * plan  — active profile's execution chain (build → deploy → launch)

local M = {}

local STATE_HL = {
    configuring      = "LoomworksRunning",
    building         = "LoomworksRunning",
    deleting         = "LoomworksDeleting",
    built            = "LoomworksBuilt",
    configured       = "LoomworksConfigured",
    configure_failed = "LoomworksFailed",
    build_failed     = "LoomworksFailed",
    unconfigured     = "LoomworksUnconfigured",
    unknown          = "LoomworksUnknown",
    fresh            = "LoomworksBuilt",
    stale            = "LoomworksUnknown",
    pending          = "Comment",
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

local function render_live(activity, ctx)
    local count = activity.running_count or 0
    ctx:add(string.format("Activity (live)  (%d running)", count))
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
end

local PLAN_STATE_GLYPH = {
    built            = "✓",
    configured       = "●",
    unconfigured     = "—",
    configure_failed = "✗",
    build_failed     = "✗",
    configuring      = "⏳",
    building         = "⏳",
    pending          = "—",
    fresh            = "✓",
    stale            = "⚠",
    unknown          = "?",
    deleting         = "⌫",
}

local function render_plan(activity, ctx)
    local profile_label = activity.profile_key or "(no active profile)"
    ctx:add("Activity (plan)  for " .. tostring(profile_label))
    ctx:hl_last_line("Title")
    ctx:add("")

    local steps = activity.plan_steps or {}
    if #steps == 0 then
        ctx:add("  (no plan — set an active profile and a default target)")
        ctx:hl_last_line("Comment")
        return
    end

    local section
    for _, step in ipairs(steps) do
        local new_section
        if step.kind == "build" then     new_section = "Build"
        elseif step.kind == "deploy_pre"  then new_section = "Deploy (pre-build)"
        elseif step.kind == "deploy_post" then new_section = "Deploy (post-build)"
        elseif step.kind == "launch"      then new_section = "Launch"
        else                                   new_section = "Other"
        end
        if new_section ~= section then
            section = new_section
            ctx:add(section)
            ctx:hl_last_line("Identifier")
        end

        local glyph = PLAN_STATE_GLYPH[step.state] or "?"
        ctx:add(string.format("  %s  %s", glyph, step.label or "?"))
        local hl = STATE_HL[step.state]
        if hl then ctx:hl_last_line(hl) end
    end
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

    if activity.mode == "plan" then
        render_plan(activity, ctx)
    else
        render_live(activity, ctx)
    end
    return ctx.lines, ctx.highlights
end

return M
