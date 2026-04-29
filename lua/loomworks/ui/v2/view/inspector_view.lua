--- loomworks/ui/v2/view/inspector_view.lua — Inspector rendering.
---
--- Plain-text rendering with extmark highlights. Read-only in this
--- slice — no edit affordances, no fields editable in place.

local M = {}

local STATE_HL = {
    unconfigured     = "LoomworksUnconfigured",
    configured       = "LoomworksConfigured",
    built            = "LoomworksBuilt",
    configure_failed = "LoomworksFailed",
    build_failed     = "LoomworksFailed",
    deleting         = "LoomworksDeleting",
    configuring      = "LoomworksRunning",
    building         = "LoomworksRunning",
    unknown          = "LoomworksUnknown",
}

local function pad_label(label, width)
    return string.format("%-" .. width .. "s", label)
end

local function new_ctx()
    local ctx = {
        lines = {},
        highlights = {},
        selectable_at_line = {},
        editable_at_line   = {},
        add_at_line        = {},
    }

    function ctx:add(text)
        self.lines[#self.lines + 1] = text or ""
    end

    --- Add a drillable line tied to a ref. <CR> on this line dispatches drill_in.
    function ctx:add_selectable(text, ref)
        self:add(text)
        if ref then
            self.selectable_at_line[#self.lines] = ref
        end
    end

    --- Add an editable line tied to a field descriptor. `e` on this line
    --- prompts and dispatches set_field.
    --- @param text string
    --- @param field table { id, label, value, kind, subject }
    function ctx:add_editable(text, field)
        self:add(text)
        if field then
            self.editable_at_line[#self.lines] = field
        end
    end

    --- Add an "+ Add X" sentinel line. <CR> on this line dispatches add_item.
    --- @param text string
    --- @param descriptor table { kind, parent }
    function ctx:add_creator(text, descriptor)
        self:add(text)
        if descriptor then
            self.add_at_line[#self.lines] = descriptor
        end
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

    function ctx:title(text)
        self:add(text)
        self:hl_last_line("Title")
    end

    function ctx:comment(text)
        self:add(text)
        self:hl_last_line("Comment")
    end

    function ctx:section(text)
        self:add(text)
        self:hl_last_line("Identifier")
    end

    return ctx
end

local function render_project(insp, ctx)
    ctx:title("Project: " .. tostring(insp.subject))
    ctx:add("")
    if insp.missing then
        ctx:comment("(project no longer exists in workspace)")
        return
    end

    ctx:add(pad_label("Type:", 14) .. (insp.type or "?"))
    ctx:add(pad_label("Path:", 14) .. (insp.path or "?"))
    ctx:add("")

    ctx:section("Configurations  (" .. tostring(#insp.configurations) .. ")")
    if #insp.configurations == 0 then
        ctx:comment("  (none)")
    else
        for _, cfg in ipairs(insp.configurations) do
            local prefix = cfg.prefix and (" [" .. cfg.prefix .. "]") or ""
            local missing = cfg.source_missing and "  ⚠ source missing" or ""
            ctx:add_selectable("  " .. cfg.name .. prefix .. missing, cfg.ref)
            if cfg.source_missing then
                ctx:hl_last_line("LoomworksFailed")
            elseif cfg.prefix then
                ctx:hl_last_line("Comment")
            end
        end
    end
    if insp.add_actions and insp.add_actions.configuration then
        ctx:add_creator("  " .. insp.add_actions.configuration.label,
            insp.add_actions.configuration)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")

    ctx:section("Configuration set membership")
    if #insp.set_membership == 0 then
        ctx:comment("  (not in any set)")
    else
        for _, m in ipairs(insp.set_membership) do
            ctx:add_selectable(string.format("  %-16s → %s", m.set_name, m.variant_name), m.ref)
        end
    end
    ctx:add("")

    ctx:section("Launch configs  (" .. tostring(#insp.launches) .. ")")
    if #insp.launches == 0 then
        ctx:comment("  (none)")
    else
        for _, l in ipairs(insp.launches) do
            ctx:add_selectable("  " .. l.name, l.ref)
        end
    end
    if insp.add_actions and insp.add_actions.launch then
        ctx:add_creator("  " .. insp.add_actions.launch.label, insp.add_actions.launch)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")

    ctx:section("Variables  (" .. tostring(#insp.variables) .. ")")
    if #insp.variables == 0 then
        ctx:comment("  (none)")
    else
        for _, v in ipairs(insp.variables) do
            ctx:add_selectable(
                string.format("  %-16s %s  default=%s",
                    v.name, "[" .. v.type .. "]", tostring(v.default or "")),
                v.ref)
        end
    end
    if insp.add_actions and insp.add_actions.variable then
        ctx:add_creator("  " .. insp.add_actions.variable.label, insp.add_actions.variable)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")
    if insp.publishable then
        ctx:add(pad_label("Published:", 14) .. tostring(insp.intent or "local"))
        ctx:hl_last_line("Identifier")
    end
end

local function render_profile(insp, ctx)
    ctx:title("Profile: " .. tostring(insp.subject))
    ctx:add("")
    if insp.missing then
        ctx:comment("(profile no longer exists)")
        return
    end

    ctx:add(pad_label("Configuration set:", 22) .. (insp.configuration_set or "?"))
    if insp.orphaned_set then
        ctx:comment(pad_label("", 22) .. "[stale: set removed]")
    end
    ctx:add(pad_label("Active:", 22) .. (insp.is_active and "yes" or "no"))
    if insp.is_active then ctx:hl_last_line("LoomworksActive") end
    ctx:add(pad_label("Status:", 22) .. (insp.status_label or ""))
    if insp.device_editable then
        local device_field
        for _, f in ipairs(insp.editable_fields or {}) do
            if f.id == "device_serial" then device_field = f; break end
        end
        ctx:add_editable(
            pad_label("Device:", 22) .. (insp.device_serial or "(none)"),
            device_field)
    elseif insp.device_serial then
        ctx:add(pad_label("Device:", 22) .. insp.device_serial)
    end
    ctx:add("")

    if insp.tools and #insp.tools > 0 then
        ctx:section("Tools")
        for _, t in ipairs(insp.tools) do
            ctx:add(string.format("  %-12s %s", t.module, t.label or t.key or "(default)"))
        end
        ctx:add("")
    end

    ctx:section("Mappings  (" .. tostring(#insp.mappings) .. ")")
    if #insp.mappings == 0 then
        ctx:comment("  (no mappings)")
    else
        for _, m in ipairs(insp.mappings) do
            ctx:add_selectable(
                string.format("  %-16s %-16s %s",
                    m.project_key, m.variant or "—", m.state or "?"),
                m.config_ref or m.project_ref)
            local hl = STATE_HL[m.state]
            if hl then ctx:hl_last_line(hl) end
        end
    end
    ctx:add("")
    if insp.publishable then
        ctx:add(pad_label("Published:", 22) .. tostring(insp.intent or "local"))
        ctx:hl_last_line("Identifier")
    end
end

local function render_config_set(insp, ctx)
    ctx:title("Configuration set: " .. tostring(insp.subject))
    ctx:add("")
    if insp.missing then
        ctx:comment("(set no longer exists)")
        return
    end
    ctx:section("Mappings  (" .. tostring(#insp.mappings) .. ")")
    if #insp.mappings == 0 then
        ctx:comment("  (none)")
    else
        for _, m in ipairs(insp.mappings) do
            -- Editable: e changes the variant; <CR> drills into the
            -- configuration. The renderer can only attach one descriptor
            -- per line, so prefer the edit descriptor (more useful in the
            -- mapping table); the drill ref is exposed via the inspector
            -- content for any callers that want it.
            ctx:add_editable(
                string.format("  %-16s → %s", m.project_key, m.variant_name or "—"),
                m.edit)
        end
    end
    if insp.add_actions and insp.add_actions.mapping then
        ctx:add_creator("  " .. insp.add_actions.mapping.label, insp.add_actions.mapping)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")
    if #insp.used_by > 0 then
        ctx:section("Used by profiles  (" .. tostring(#insp.used_by) .. ")")
        for _, key in ipairs(insp.used_by) do
            ctx:add_selectable("  " .. key, { kind = "profile", key = key })
        end
    else
        ctx:comment("Used by profiles: (none)")
    end
    ctx:add("")
    if insp.publishable then
        ctx:add(pad_label("Published:", 14) .. tostring(insp.intent or "local"))
        ctx:hl_last_line("Identifier")
    end
end

local function render_configuration(insp, ctx)
    ctx:title("Configuration: " .. tostring(insp.subject))
    ctx:comment("  in project " .. tostring(insp.project_key))
    ctx:add("")
    if insp.missing then
        ctx:comment("(configuration no longer exists)")
        return
    end
    if insp.prefix then
        ctx:add(pad_label("Prefix:", 22) .. insp.prefix)
        ctx:add(pad_label("Base name:", 22) .. (insp.base_name or ""))
    end
    local kind_label
    if insp.is_user then         kind_label = "user"
    elseif insp.from_preset then kind_label = "preset (auto-gen)"
    elseif insp.is_default then  kind_label = "default (auto-gen)"
    else                         kind_label = "auto-gen"
    end
    ctx:add(pad_label("Kind:", 22) .. kind_label)
    if insp.role then
        ctx:add(pad_label("Role:", 22) .. insp.role)
    end
    if insp.source_missing then
        ctx:add("  ⚠ source missing — config exists only in cache")
        ctx:hl_last_line("LoomworksFailed")
    end
    ctx:add("")

    ctx:section("Inherits  (" .. tostring(#insp.inherits) .. ")")
    if #insp.inherits == 0 then
        ctx:comment("  (none)")
    else
        for _, name in ipairs(insp.inherits) do
            ctx:add("  " .. name)
        end
    end
    if #insp.unresolved_inherits > 0 then
        ctx:add("  ⚠ unresolved: " .. table.concat(insp.unresolved_inherits, ", "))
        ctx:hl_last_line("LoomworksFailed")
    end
    ctx:add("")

    ctx:section("Options  (" .. tostring(#insp.options) .. ")")
    if #insp.options == 0 then
        ctx:comment("  (none)")
    else
        for _, o in ipairs(insp.options) do
            ctx:add_editable(string.format("  %-22s = %s", o.key, o.value), o.edit)
        end
    end
    if insp.publishable then
        ctx:add("")
        ctx:add(pad_label("Published:", 14) .. tostring(insp.intent or "local"))
        ctx:hl_last_line("Identifier")
    end
end

local function render_launch(insp, ctx)
    ctx:title("Launch: " .. tostring(insp.subject))
    ctx:comment("  in project " .. tostring(insp.project_key))
    ctx:add("")
    if insp.missing then
        ctx:comment("(launch no longer exists)")
        return
    end
    -- Find editable fields by id for emitting in line order.
    local function field(id)
        for _, f in ipairs(insp.editable_fields or {}) do
            if f.id == id then return f end
        end
    end
    do
        local f = field("command")
        ctx:add_editable(pad_label("Command:", 14) .. tostring(insp.command or ""), f)
    end
    if insp.working_dir or field("working_dir") then
        local f = field("working_dir")
        ctx:add_editable(pad_label("Working dir:", 14) .. tostring(insp.working_dir or ""), f)
    end
    ctx:add("")

    ctx:section("Args  (" .. tostring(#insp.args) .. ")")
    if #insp.args == 0 then
        ctx:comment("  (none)")
    else
        for _, a in ipairs(insp.args) do
            ctx:add_editable("  " .. tostring(a.value), a.edit)
        end
    end
    if insp.add_actions and insp.add_actions.arg then
        ctx:add_creator("  " .. insp.add_actions.arg.label, insp.add_actions.arg)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")

    ctx:section("Env  (" .. tostring(#insp.env) .. ")")
    if #insp.env == 0 then
        ctx:comment("  (none)")
    else
        for _, e in ipairs(insp.env) do
            ctx:add_editable(string.format("  %s = %s", e.key, tostring(e.value)), e.edit)
        end
    end
    if insp.add_actions and insp.add_actions.env then
        ctx:add_creator("  " .. insp.add_actions.env.label, insp.add_actions.env)
        ctx:hl_last_line("LoomworksActionable")
    end
    ctx:add("")

    if #insp.debug > 0 then
        ctx:add("Debug languages: " .. table.concat(insp.debug, ", "))
    end
    ctx:section("Deploy steps  (" .. tostring(insp.deploy_count) .. ")")
    if insp.deploy_steps and #insp.deploy_steps > 0 then
        for _, step in ipairs(insp.deploy_steps) do
            ctx:add_selectable("  " .. step.destination, step.ref)
        end
    elseif insp.deploy_count == 0 then
        ctx:comment("  (none)")
    end
    if insp.add_actions and insp.add_actions.deploy_step then
        ctx:add_creator("  " .. insp.add_actions.deploy_step.label,
            insp.add_actions.deploy_step)
        ctx:hl_last_line("LoomworksActionable")
    end
end

local function render_variable(insp, ctx)
    ctx:title("Variable: " .. tostring(insp.subject))
    ctx:comment("  in project " .. tostring(insp.project_key))
    ctx:add("")
    if insp.missing then
        ctx:comment("(variable no longer exists)")
        return
    end
    ctx:add(pad_label("Type:", 14) .. tostring(insp.type or "string"))
    do
        local f
        for _, ef in ipairs(insp.editable_fields or {}) do
            if ef.id == "default" then f = ef; break end
        end
        ctx:add_editable(pad_label("Default:", 14) .. tostring(insp.default or ""), f)
    end
    ctx:add("")

    ctx:section("Configuration overrides  (" .. tostring(#insp.overrides) .. ")")
    if #insp.overrides == 0 then
        ctx:comment("  (none)")
    else
        for _, o in ipairs(insp.overrides) do
            ctx:add(string.format("  %-20s = %s",
                o.configuration_name, tostring(o.value or "")))
        end
    end
end

local function render_device(insp, ctx)
    ctx:title("Device: " .. tostring(insp.subject))
    ctx:add("")
    if insp.missing then
        ctx:comment("(device not in current scan)")
        return
    end
    ctx:add(pad_label("Display name:", 14) .. tostring(insp.display_name or ""))
    ctx:add(pad_label("Provider:", 14)     .. tostring(insp.provider or ""))
    ctx:add(pad_label("State:", 14)        .. tostring(insp.state or ""))
    if insp.state == "online" then
        ctx:hl_last_line("LoomworksBuilt")
    elseif insp.state == "offline" then
        ctx:hl_last_line("Comment")
    end
    ctx:add("")

    ctx:section("Properties  (" .. tostring(#insp.properties) .. ")")
    if #insp.properties == 0 then
        ctx:comment("  (none)")
    else
        for _, p in ipairs(insp.properties) do
            ctx:add(string.format("  %-20s = %s", p.key, p.value))
        end
    end
    ctx:add("")
    if #insp.pinned_by > 0 then
        ctx:section("Pinned by profiles  (" .. tostring(#insp.pinned_by) .. ")")
        for _, key in ipairs(insp.pinned_by) do
            ctx:add("  " .. key)
        end
    else
        ctx:comment("Pinned by profiles: (none)")
    end
end

local function render_deploy_step(insp, ctx)
    ctx:title("Deploy step: " .. tostring(insp.subject))
    local scope = insp.scope == "launch"
        and ("  in launch " .. tostring(insp.launch_name) .. " of " .. tostring(insp.project_key))
        or  ("  project-level on " .. tostring(insp.project_key))
    ctx:comment(scope)
    ctx:add("")
    if insp.missing then
        ctx:comment("(deploy step no longer defined)")
        return
    end
    ctx:add(pad_label("Destination:", 14) .. tostring(insp.subject))
    ctx:add("")
    ctx:section("Sources  (" .. tostring(#insp.sources) .. ")")
    if #insp.sources == 0 then
        ctx:comment("  (none)")
    else
        for i, s in ipairs(insp.sources) do
            local rhs = s.target and ("target=" .. s.target)
                     or  s.path   and ("path="   .. s.path)
                     or  "(no target/path)"
            local config = s.configuration and ("  configuration=" .. s.configuration) or ""
            local phase = s.pre_build and "pre-build" or "post-build"
            ctx:add_selectable(
                string.format("  [%d] project=%s  %s%s  phase=%s",
                    i, tostring(s.project or "?"), rhs, config, phase),
                s.ref)
        end
    end
end

local function render_wire_deploy(insp, ctx)
    ctx:title("Wire: " .. tostring(insp.subject))
    ctx:add("")
    if insp.missing then
        ctx:comment("(form was closed)")
        return
    end

    -- Find editable fields by id for in-order rendering.
    local function field(id)
        for _, f in ipairs(insp.editable_fields or {}) do
            if f.id == id then return f end
        end
    end

    ctx:section("Destination")
    ctx:add_editable(pad_label("  pattern:", 16) .. tostring(insp.destination or ""), field("destination"))
    if insp.resolved and insp.resolved ~= insp.destination then
        ctx:comment(pad_label("  resolved:", 16) .. tostring(insp.resolved or ""))
    end
    ctx:add("")

    ctx:section("Source")
    ctx:add_editable(pad_label("  project:", 16) .. tostring(insp.source_project or ""), field("source_project"))
    ctx:add_editable(pad_label("  target:", 16) .. tostring(insp.target or ""), field("target"))
    ctx:add_editable(pad_label("  path:", 16) .. tostring(insp.path or ""), field("path"))
    ctx:add_editable(pad_label("  configuration:", 16) .. tostring(insp.configuration or ""), field("configuration"))
    ctx:add("")

    ctx:section("Phase")
    ctx:add_editable(pad_label("  pre-build:", 16) .. (insp.pre_build and "true" or "false"), field("pre_build"))
    ctx:add("")

    -- Commit actions — emitted as creator sentinels so <CR> activates them.
    if insp.commit_actions then
        for _, cm in ipairs(insp.commit_actions) do
            ctx:add_creator("  " .. cm.label, { kind = cm.kind })
            ctx:hl_last_line("LoomworksActionable")
        end
    end
end

local function render_empty(_, ctx)
    ctx:title("Inspector")
    ctx:add("")
    ctx:comment("  (no selection)")
end

local function render_unknown(insp, ctx)
    ctx:title("Inspector")
    ctx:add("")
    ctx:comment("  unknown ref kind: " .. tostring(insp.ref_kind))
end

local KIND_RENDERERS = {
    empty         = render_empty,
    project       = render_project,
    profile       = render_profile,
    config_set    = render_config_set,
    configuration = render_configuration,
    launch        = render_launch,
    variable      = render_variable,
    device        = render_device,
    deploy_step   = render_deploy_step,
    wire_deploy   = render_wire_deploy,
}

--- Render an inspector content table to lines + highlights + drill / edit / add maps.
--- @param inspector table
--- @return string[] lines
--- @return table[] highlights         { line, col_start, col_end, hl_group }
--- @return table<integer, table> selectable_at_line   line → drill ref
--- @return table<integer, table> editable_at_line     line → editable field descriptor
--- @return table<integer, table> add_at_line          line → "+ Add ..." descriptor
function M.render(inspector)
    local ctx = new_ctx()
    local fn = inspector and KIND_RENDERERS[inspector.kind] or render_unknown
    fn(inspector or {}, ctx)
    return ctx.lines, ctx.highlights,
        ctx.selectable_at_line, ctx.editable_at_line, ctx.add_at_line
end

return M
