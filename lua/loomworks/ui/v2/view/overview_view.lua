--- loomworks/ui/v2/view/overview_view.lua — Overview rendering.
---
--- Walks the overview presentation tree and produces:
---   - lines               : buffer text
---   - highlights          : list of { line, col_start, col_end, hl_group } (1-based line)
---   - selectable_at_line  : line → { section, row } for selectable rows
---   - section_at_line     : line → section_kind for any line in a section
---     (including the section header), used by `o` to toggle the section
---     under the cursor.

local M = {}

local STATE_BADGE = {
    unconfigured     = { text = "—",                  hl = "LoomworksUnconfigured" },
    configured       = { text = "● configured",       hl = "LoomworksConfigured" },
    built            = { text = "✓ built",            hl = "LoomworksBuilt" },
    configure_failed = { text = "✗ configure failed", hl = "LoomworksFailed" },
    build_failed     = { text = "✗ build failed",     hl = "LoomworksFailed" },
    deleting         = { text = "⌫ deleting",         hl = "LoomworksDeleting" },
    configuring      = { text = "⏳ configuring",     hl = "LoomworksRunning" },
    building         = { text = "⏳ building",        hl = "LoomworksRunning" },
    unknown          = { text = "? unknown",          hl = "LoomworksUnknown" },
}

local function badge_for(state)
    return STATE_BADGE[state] or { text = tostring(state), hl = nil }
end

local function collapse_glyph(collapsed)
    return collapsed and "▶" or "▼"
end

--- Rendering context — accumulates lines, highlights, and the line maps.
local function new_ctx()
    local ctx = {
        lines = {},
        highlights = {},
        selectable_at_line = {},
        section_at_line = {},
        add_at_line = {},
        section_idx = 0,
    }

    function ctx:add(text, section_kind, sel)
        self.lines[#self.lines + 1] = text or ""
        local line_no = #self.lines
        if section_kind then self.section_at_line[line_no] = section_kind end
        if sel then self.selectable_at_line[line_no] = sel end
    end

    function ctx:add_creator(text, descriptor, section_kind)
        self.lines[#self.lines + 1] = text or ""
        local line_no = #self.lines
        if section_kind then self.section_at_line[line_no] = section_kind end
        if descriptor then self.add_at_line[line_no] = descriptor end
    end

    function ctx:hl(line_no, col_start, col_end, hl_group)
        self.highlights[#self.highlights + 1] = {
            line = line_no, col_start = col_start, col_end = col_end, hl_group = hl_group,
        }
    end

    --- Add a whole-line highlight on the most recently added line.
    function ctx:hl_last_line(hl_group, col_start, col_end)
        local line_no = #self.lines
        local text = self.lines[line_no] or ""
        self:hl(line_no, col_start or 0, col_end or #text, hl_group)
    end

    return ctx
end

--- Render the active-profile card.
local function render_active_card(section, ctx)
    local p = section.profile
    local profile_label = "▶ " .. (p.key or "?")
    if p.status_label and p.status_label ~= "" then
        profile_label = profile_label .. "    " .. p.status_label
    end
    ctx:add(profile_label, section.kind, { section = ctx.section_idx, row = 1 })
    ctx:hl_last_line("LoomworksActive")

    if p.set then
        ctx:add("  set: " .. p.set, section.kind)
        ctx:hl_last_line("Comment")
    end
    ctx:add("", section.kind)

    for i, proj in ipairs(section.projects) do
        local variant = proj.variant or "—"
        local state = proj.state or "unconfigured"
        local badge = badge_for(state)
        local row = string.format("  %-12s %-16s %s", proj.project_key, variant, badge.text)
        ctx:add(row, section.kind, { section = ctx.section_idx, row = i + 1 })
        if badge.hl then
            -- Highlight just the badge portion (after the variant column).
            local badge_col = 2 + 12 + 1 + 16 + 1 -- "  " + name + " " + variant + " "
            ctx:hl(#ctx.lines, badge_col, #row, badge.hl)
        end
    end
end

local function render_no_active_card(section, ctx)
    ctx:add("No active profile.", section.kind)
    ctx:hl_last_line("Comment")
    ctx:add("", section.kind)
    for _, action in ipairs(section.actions or {}) do
        ctx:add("  " .. action.label, section.kind)
        if action.hint then ctx:hl_last_line("Comment") end
    end
end

local function render_no_workspace(section, ctx)
    ctx:add("No workspace loaded.", section.kind)
    ctx:hl_last_line("Comment")
    ctx:add("", section.kind)
    for _, action in ipairs(section.actions or {}) do
        ctx:add("  " .. action.label, section.kind)
        if action.hint then ctx:hl_last_line("Comment") end
    end
end

--- Render a generic collapsible section header (with glyph + count).
local function render_section_header(text, ctx, section_kind, collapsed)
    ctx:add(text, section_kind)
    if collapsed then
        ctx:hl_last_line("Comment")
    end
end

local function render_devices(section, ctx)
    local glyph = collapse_glyph(section.collapsed)
    local header = string.format("%s Devices  (%d online · %d offline)",
        glyph, section.online_count or 0, section.offline_count or 0)
    render_section_header(header, ctx, section.kind, section.collapsed)
    if section.collapsed then return end

    for i, d in ipairs(section.devices or {}) do
        local serial = d.serial or "?"
        if #serial > 12 then serial = serial:sub(1, 12) .. "…" end
        local row = string.format("  %-13s %-7s %s",
            serial, d.state or "?", d.display_name or "")
        ctx:add(row, section.kind, { section = ctx.section_idx, row = i })
        if d.state ~= "online" then
            ctx:hl_last_line("Comment")
        end
    end
end

local function render_cleanup(section, ctx)
    local glyph = collapse_glyph(section.collapsed)
    local size = section.size_bytes
        and string.format(" · %.1f MB", section.size_bytes / 1024 / 1024)
        or ""
    local header = string.format("%s Cleanup candidates  (%d%s)", glyph, section.count or 0, size)
    render_section_header(header, ctx, section.kind, section.collapsed)
    if section.collapsed then return end
    for i, item in ipairs(section.items or {}) do
        ctx:add(string.format("  %s  %s", item.project_key or "?", item.config_key or "?"),
            section.kind, { section = ctx.section_idx, row = i })
        ctx:hl_last_line("Comment")
    end
end

local function render_other_profiles(section, ctx)
    local glyph = collapse_glyph(section.collapsed)
    local header = string.format("%s Other profiles  (%d)", glyph, section.count or 0)
    render_section_header(header, ctx, section.kind, section.collapsed)
    if section.collapsed then return end
    for i, item in ipairs(section.items or {}) do
        local stale = item.stale and "  [stale]" or ""
        ctx:add(string.format("  %-32s %s%s", item.key, item.status_label or "", stale),
            section.kind, { section = ctx.section_idx, row = i })
        if item.stale then ctx:hl_last_line("Comment") end
    end
end

local function render_other_projects(section, ctx)
    local glyph = collapse_glyph(section.collapsed)
    local header = string.format("%s Other projects  (%d not in profile)", glyph, section.count or 0)
    render_section_header(header, ctx, section.kind, section.collapsed)
    if section.collapsed then return end
    for i, item in ipairs(section.items or {}) do
        local type_str = item.type and (" [" .. item.type .. "]") or ""
        ctx:add("  " .. item.key .. type_str,
            section.kind, { section = ctx.section_idx, row = i })
    end
    if section.add_action then
        ctx:add_creator("  " .. section.add_action.label, section.add_action, section.kind)
        ctx:hl_last_line("LoomworksActionable")
    end
end

local function render_config_sets(section, ctx)
    local glyph = collapse_glyph(section.collapsed)
    local header = string.format("%s Configuration sets  (%d)", glyph, section.count or 0)
    render_section_header(header, ctx, section.kind, section.collapsed)
    if section.collapsed then return end
    for i, item in ipairs(section.items or {}) do
        ctx:add(string.format("  %-32s (%d project%s)",
                item.name, item.mapping_count or 0, item.mapping_count == 1 and "" or "s"),
            section.kind, { section = ctx.section_idx, row = i })
    end
    if section.add_action then
        ctx:add_creator("  " .. section.add_action.label, section.add_action, section.kind)
        ctx:hl_last_line("LoomworksActionable")
    end
end

local RENDERERS = {
    active_profile_card = render_active_card,
    no_active_profile   = render_no_active_card,
    no_workspace        = render_no_workspace,
    devices             = render_devices,
    cleanup             = render_cleanup,
    other_profiles      = render_other_profiles,
    other_projects      = render_other_projects,
    config_sets         = render_config_sets,
}

--- Render the overview presentation tree.
--- @param overview table presentation.overview
--- @param selection table presentation.selection
--- @return string[] lines
--- @return table[] highlights        list of { line, col_start, col_end, hl_group }
--- @return table<integer, { section: integer, row: integer }> selectable_at_line
--- @return table<integer, string> section_at_line
--- @return table<integer, table> add_at_line   line → "+ Add ..." descriptor
function M.render(overview, selection)
    local ctx = new_ctx()

    -- Header
    ctx:add(overview.workspace_name or "loomworks")
    ctx:hl_last_line("Title")
    ctx:add(string.rep("─", 60))
    ctx:hl_last_line("Comment")

    for si, section in ipairs(overview.sections or {}) do
        ctx.section_idx = si
        local fn = RENDERERS[section.kind]
        if fn then
            fn(section, ctx)
            if si < #overview.sections then
                ctx:add("")
            end
        end
    end

    -- Pin marker on the row matching the pinned ref, if visible.
    if selection and selection.pinned then
        for line_no, ref in pairs(ctx.selectable_at_line) do
            if ref.section ~= nil then
                -- Selectable refs in this map are { section, row } indices, not the
                -- ref itself. We can't compare here without re-resolving — skip
                -- pin markers in the renderer; the inspector subject already
                -- reflects the pinned ref.
            end
        end
    end

    return ctx.lines, ctx.highlights,
        ctx.selectable_at_line, ctx.section_at_line, ctx.add_at_line
end

return M
