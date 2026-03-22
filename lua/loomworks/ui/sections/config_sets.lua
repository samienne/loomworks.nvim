--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Resolve display state for a profile (status label, highlight, marker, suffix).
--- Shared by tool and no-tool entry renderers.
--- @param profile loomworks.Profile|nil
--- @param is_active boolean
--- @return string suffix, string hl, string|nil marker, boolean spinning
local function resolve_profile_display(profile, is_active)
    if not profile then
        return "", "LoomworksUnconfigured", helpers.status_marker("unconfigured"), false
    end

    local profile_running = profile:is_running()
    local already_configured = profile:is_configured()

    if profile_running then
        local status_label = select(1, profile:status())
        local marker = helpers.status_marker(status_label)
        local suffix = " (" .. status_label .. ")"
        local pps = profile:projects()
        local pct = helpers.aggregate_progress(pps)
        if pct then suffix = suffix .. " " .. pct .. "%" end
        suffix = suffix .. helpers.format_elapsed(profile:operation_elapsed())
        local hl = is_active and "LoomworksActive" or "LoomworksRunning"
        return suffix, hl, marker, true
    elseif is_active then
        local op = profile:operation()
        local p_label = already_configured and select(1, profile:status()) or "unconfigured"
        local marker = helpers.status_marker(p_label)
        local suffix
        if op and op.message then
            suffix = " — " .. op.message
        else
            suffix = " (" .. p_label .. ")"
        end
        return suffix, "LoomworksActive", marker, false
    elseif already_configured then
        local p_label = select(1, profile:status())
        local marker = helpers.status_marker(p_label)
        local op = profile:operation()
        local suffix
        if op and op.message then
            suffix = " — " .. op.message
        else
            suffix = " (" .. p_label .. ")"
        end
        local hl
        if p_label == "failed_configure" or p_label == "failed_build"
                or p_label:match("failed") then
            hl = "LoomworksFailed"
        else
            hl = "LoomworksConfigured"
        end
        return suffix, hl, marker, false
    else
        return "", "LoomworksUnconfigured", helpers.status_marker("unconfigured"), false
    end
end

--- Render a single keyed-tool entry line within a config set.
--- @param tree loomworks.Tree
--- @param cs loomworks.ConfigurationSet
--- @param entry loomworks.ToolEntry
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile loomworks.Profile|nil
local function render_tool_entry(tree, cs, entry, all_profiles, active_profile)
    local profile = entry.cached and all_profiles[entry.profile_key] or nil
    local is_active = profile ~= nil and profile == active_profile
    local suffix, hl, marker, spinning = resolve_profile_display(profile, is_active)
    local display = entry.tool_label or entry.tool_key

    tree:item(display .. suffix, {
        marker = marker,
        spinning = spinning,
        hl = hl,
        enter_label = "Activate",
        on_enter = profile and actions.activate(profile)
                or actions.activate_new(cs, entry),
        on_build = profile and actions.build(profile)
                or actions.build_new(cs, entry),
        on_configure = profile and actions.configure(profile)
                or actions.configure_new(cs, entry),
        on_rebuild = profile and actions.rebuild(profile) or nil,
        on_clean = profile and actions.clean(profile) or nil,
        on_delete = profile and actions.delete_profile(profile) or nil,
    })
end

--- Render an actionable entry for a config set with no keyed tools.
--- Shows the set as directly activatable (no tool selection needed).
--- @param tree loomworks.Tree
--- @param cs loomworks.ConfigurationSet
--- @param profile loomworks.Profile|nil existing no-tool profile
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile loomworks.Profile|nil
local function render_no_tool_entry(tree, cs, profile, all_profiles, active_profile)
    local is_active = profile ~= nil and profile == active_profile
    local suffix, hl, marker, spinning = resolve_profile_display(profile, is_active)

    -- For no-tool entries, show status as the display text (no tool label prefix)
    local display
    if not profile then
        display = "[Enter] activate  [b] build  [c] configure"
    else
        -- Strip leading space from suffix: " (built)" → "(built)"
        display = suffix ~= "" and suffix:match("^%s*(.+)$") or "unconfigured"
    end

    tree:item(display, {
        marker = marker,
        spinning = spinning,
        hl = hl,
        enter_label = "Activate",
        on_enter = profile and actions.activate(profile)
                or actions.activate_new(cs, nil),
        on_build = profile and actions.build(profile)
                or actions.build_new(cs, nil),
        on_configure = profile and actions.configure(profile)
                or actions.configure_new(cs, nil),
        on_rebuild = profile and actions.rebuild(profile) or nil,
        on_clean = profile and actions.clean(profile) or nil,
        on_delete = profile and actions.delete_profile(profile) or nil,
    })
end

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param cs loomworks.ConfigurationSet
--- @param tool_entries loomworks.ToolEntry[]
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile loomworks.Profile|nil
--- @param lw table loomworks API
local function render_set_details(tree, cs, tool_entries, all_profiles, active_profile, lw)
    local set_name = cs.name
    tree:group("Projects:", "Comment", function()
        local proj_names = {}
        for project, variant in pairs(cs.mappings) do
            proj_names[#proj_names + 1] = { key = project.key, variant = variant }
        end
        table.sort(proj_names, function(a, b) return a.key < b.key end)
        for _, entry in ipairs(proj_names) do
            tree:leaf(entry.key .. " → " .. entry.variant, "Comment")
        end
    end)

    if #tool_entries > 0 then
        tree:group({{"Tools:  ", "LoomworksActionable"}, {"[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
            for _, entry in ipairs(tool_entries) do
                render_tool_entry(tree, cs, entry, all_profiles, active_profile)
            end
        end)
    else
        -- No keyed tools — render a single activatable entry for the set itself
        local profile = cs:find_profile(nil)
        render_no_tool_entry(tree, cs, profile, all_profiles, active_profile)
    end
end

--- Render the configuration sets section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile, config_sets, tool_entries }
return function(tree, ctx)
    local config_sets = ctx.config_sets
    if not config_sets or not next(config_sets) then return end

    local all_profiles = ctx.all_profiles
    local active_profile = ctx.active_profile
    local tool_entries = ctx.tool_entries or {}
    local lw = ctx.lw

    tree:leaf("Configuration Sets", "Title")
    tree:blank()

    local sorted = {}
    for name, cs in pairs(config_sets) do
        sorted[#sorted + 1] = { name = name, cs = cs }
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(sorted) do
        local cs = entry.cs
        local is_active_set = active_profile
                and active_profile.configuration_set == cs.name
        local set_hl = is_active_set and "LoomworksActive" or "LoomworksActionable"

        tree:node(cs.name, {
            fold_key = "set:" .. cs.name,
            hl = set_hl,
        }, function()
            render_set_details(tree, cs,
                tool_entries[cs.name] or {}, all_profiles, active_profile, lw)
        end)
    end

    tree:blank()
end
