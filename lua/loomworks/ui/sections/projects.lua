--- loomworks/ui/sections/projects.lua — Projects section renderer.
---
--- Shows cached state and detected tools. Uses active profile context
--- only for highlight coloring (active vs non-active).

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")
local merge = require("loomworks.merge")

--- Sort project keys: non-orphaned first (alphabetical), orphaned last.
--- @param projects table<string, loomworks.Project>
--- @return string[]
local function sorted_project_keys(projects)
    local normal, orphaned = {}, {}
    for key, proj in pairs(projects) do
        if proj.orphaned then
            orphaned[#orphaned + 1] = key
        else
            normal[#normal + 1] = key
        end
    end
    table.sort(normal)
    table.sort(orphaned)
    for _, key in ipairs(orphaned) do
        normal[#normal + 1] = key
    end
    return normal
end

--- Look up a tool display label from detected tools.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param mod_type string
--- @param tool_key string
--- @return string
local function get_tool_display(tools_by_type, mod_type, tool_key)
    local tools = tools_by_type[mod_type]
    if tools then
        for _, dt in ipairs(tools) do
            if dt.tool_key == tool_key then
                return dt.tool_label or tool_key
            end
        end
    end
    return tool_key
end

--- Collect tool entries for a keyed-tool variant: cached entries + unconfigured detected tools.
--- Uses case-insensitive matching for variants because configuration_set variant
--- names may differ in case from module-detected configuration names (e.g. cmake
--- presets use "Debug" but the configuration set may map to "debug").
--- @param proj loomworks.Project
--- @param variant string
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table[] entries { config_key, tool_key, display_label, cached }
local function collect_tool_entries(proj, variant, tools_by_type)
    local entries = {}
    local seen_tool_keys = {}
    local variant_lower = variant:lower()

    -- 1. Cached entries for this variant (case-insensitive match)
    if proj.cached_configurations then
        for config_key, cached_config in pairs(proj.cached_configurations) do
            local v = cached_config.variant
            local tk = cached_config.tool_key
            if v and tk and v:lower() == variant_lower then
                entries[#entries + 1] = {
                    config_key = config_key,
                    tool_key = tk,
                    display_label = get_tool_display(tools_by_type, proj.type, tk),
                    cached = cached_config,
                }
                seen_tool_keys[tk] = true
            end
        end
    end

    -- 2. Detected tools not yet cached for this variant
    local relevant_tools = tools_by_type[proj.type] or {}
    for _, dt in ipairs(relevant_tools) do
        if dt.tool_key and not seen_tool_keys[dt.tool_key] then
            entries[#entries + 1] = {
                config_key = variant .. ":" .. dt.tool_key,
                tool_key = dt.tool_key,
                display_label = dt.tool_label or dt.tool_key,
                cached = nil,
            }
        end
    end

    table.sort(entries, function(a, b) return a.config_key < b.config_key end)
    return entries
end

--- Determine the display highlight for a config entry.
--- Running/deleting entries keep their status_hl; others are colored by active state.
--- @param config_status string
--- @param status_hl string
--- @param is_spinning boolean
--- @param is_active boolean
--- @return string hl_group
local function entry_highlight(config_status, status_hl, is_spinning, is_active)
    if is_spinning then return status_hl end
    if is_active then return "LoomworksActive" end
    if config_status == "failed_configure" or config_status == "failed_build" then
        return "LoomworksFailed"
    end
    if config_status == "unconfigured" then return "LoomworksUnconfigured" end
    return "LoomworksConfigured"
end

--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, projects, active_profile_key }
return function(tree, ctx)
    local lw = ctx.lw
    local projects = ctx.projects
    if not projects or not next(projects) then return end

    tree:leaf("Projects", "Title")
    tree:blank()

    local tools_by_type = lw.get_tools_by_type()
    local sorted = sorted_project_keys(projects)
    local active_tool_key = ctx.active_profile and ctx.active_profile.tool
            and ctx.active_profile.tool.key or nil

    for _, key in ipairs(sorted) do
        local proj = projects[key]
        local proj_running = proj:running_action()
        local is_active_project = proj.configuration ~= nil and not proj.orphaned
        local proj_hl = proj_running and "LoomworksRunning"
                or (is_active_project and "LoomworksActive" or "LoomworksActionable")

        local type_tag = "[" .. proj.type .. "]"
        local orphan_tag = proj.orphaned and " (orphaned)" or ""
        local refresh_tag = proj.needs_refresh and " !" or ""

        tree:node(key .. " " .. type_tag .. orphan_tag .. refresh_tag, {
            fold_key = "project:" .. key,
            spinning = proj_running ~= nil,
            hl = proj_hl,
        }, function()
            tree:leaf("Path: " .. (proj.path or key), "Comment")

            if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
                for _, reason in ipairs(proj.refresh_reasons) do
                    tree:leaf("! " .. reason, "DiagnosticWarn")
                end
            end

            if proj.configurations and next(proj.configurations) then
                tree:group({{"Configurations:  ", "LoomworksActionable"}, {"[b] build  [c] configure  [p] pin  [o] options  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
                    local config_names = {}
                    for name in pairs(proj.configurations) do
                        config_names[#config_names + 1] = name
                    end
                    table.sort(config_names)

                    local project_has_keyed_tools = lw.module_has_keyed_tools(proj.type)

                    for _, cname in ipairs(config_names) do
                        local cdata = proj.configurations[cname]

                        -- Check running state across all config_keys for this variant
                        local config_has_running = false
                        if project_has_keyed_tools then
                            local entries = collect_tool_entries(proj, cname, tools_by_type)
                            for _, entry in ipairs(entries) do
                                if lw.get_config_unit(key, entry.config_key):is_running() then
                                    config_has_running = true
                                    break
                                end
                            end
                        else
                            if lw.get_config_unit(key, cname):is_running() then
                                config_has_running = true
                            end
                        end

                        local config_hl = config_has_running and "LoomworksRunning" or "LoomworksActionable"

                        local brief = {}
                        if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
                        if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
                        local brief_str = #brief > 0
                                and ("  (" .. table.concat(brief, ", ") .. ")") or ""

                        tree:node(cname .. brief_str, {
                            fold_key = "config:" .. key .. ":" .. cname,
                            spinning = config_has_running,
                            hl = config_hl,
                            on_delete = not project_has_keyed_tools
                                    and actions.delete_config(lw.get_config_unit(key, cname)) or nil,
                        }, function()
                            if cdata.toolchain then
                                tree:leaf("Toolchain: " .. tostring(cdata.toolchain), "Comment")
                            end
                            if cdata.generator then
                                tree:leaf("Generator: " .. cdata.generator, "Comment")
                            end

                            if project_has_keyed_tools then
                                -- Keyed-tool modules: show each tool (cached + unconfigured)
                                local is_active_variant = is_active_project
                                        and proj.configuration:lower() == cname:lower()
                                local entries = collect_tool_entries(proj, cname, tools_by_type)
                                for _, entry in ipairs(entries) do
                                    local unit = lw.get_config_unit(key, entry.config_key)
                                    -- Ensure variant/tool are set for uncached entries
                                    if not unit.variant then
                                        unit.variant = cname
                                        unit.tool = entry.tool_key and { key = entry.tool_key } or nil
                                    end
                                    local config_status, status_hl, progress_str, is_spinning =
                                            helpers.resolve_config_status_global(unit, entry.cached)
                                    local is_active = is_active_variant
                                            and active_tool_key == entry.tool_key
                                    local hl = entry_highlight(config_status, status_hl, is_spinning, is_active)

                                    tree:node(entry.display_label .. progress_str, {
                                        fold_key = "config_tool:" .. key .. ":" .. entry.config_key,
                                        spinning = is_spinning,
                                        hl = hl,
                                        on_build = actions.build_configuration(unit),
                                        on_rebuild = actions.rebuild_configuration(unit),
                                        on_clean = actions.clean_configuration(unit),
                                        on_configure = actions.configure_configuration(unit),
                                        on_delete = entry.cached and actions.delete_config(unit) or nil,
                                        on_pin = actions.pin_config(unit),
                                        on_options = entry.cached and actions.show_options(unit) or nil,
                                    }, function()
                                        helpers.render_cached_details(tree, config_status, status_hl, entry.cached,
                                            key .. ":" .. entry.config_key, unit)
                                    end)
                                end
                            else
                                -- Non-keyed modules: show single status
                                local unit = lw.get_config_unit(key, cname)
                                local cached = proj.cached_configurations
                                        and proj.cached_configurations[cname]
                                local config_status, status_hl, progress_str, is_spinning =
                                        helpers.resolve_config_status_global(unit, cached)
                                local is_active_variant = is_active_project
                                        and proj.configuration:lower() == cname:lower()
                                local hl = entry_highlight(config_status, status_hl, is_spinning, is_active_variant)

                                tree:node("Status: " .. config_status .. progress_str, {
                                    fold_key = "config_status:" .. key .. ":" .. cname,
                                    spinning = is_spinning,
                                    hl = hl,
                                    on_build = actions.build_configuration(unit),
                                    on_rebuild = actions.rebuild_configuration(unit),
                                    on_clean = actions.clean_configuration(unit),
                                    on_configure = actions.configure_configuration(unit),
                                    on_delete = cached and actions.delete_config(unit) or nil,
                                    on_pin = actions.pin_config(unit),
                                    on_options = cached and actions.show_options(unit) or nil,
                                }, function()
                                    helpers.render_cached_details(tree, config_status, status_hl, cached, nil, unit)
                                end)
                            end
                        end)
                    end
                end)
            end

            tree:blank()
        end)
    end
end
