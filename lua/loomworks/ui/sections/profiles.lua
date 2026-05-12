--- loomworks/ui/sections/profiles.lua — Profiles section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Local helper: linear `contains` on a small string array. The
--- profile.tool_keys list is short enough that hashing isn't worth
--- the allocation overhead at render time.
--- @param list string[]|nil
--- @param item string
--- @return boolean
local function contains(list, item)
    if not list then return false end
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end

--- Render profile details when expanded.
--- @param tree loomworks.Tree
--- @param profile loomworks.Profile
--- @param lw table loomworks API
local function render_profile_details(tree, profile, lw)
    if profile.orphaned_set then
        tree:leaf("Set '" .. (profile._configuration_set_name or "?")
            .. "' removed from loomworks.json", "DiagnosticWarn")
    elseif profile._config_set_ref then
        tree:leaf("Set: " .. profile._config_set_ref.name, "Comment")
    end

    -- Toolchain section: one row per tool in `profile._tool_keys`.
    -- Each row is a single tool selection; the user adds and removes
    -- entries. Resolution is language-keyed — at build time each
    -- ConfigUnit picks the first tool in the array that provides one
    -- of its configuration's required languages.
    local ws = profile._workspace
    local needing = profile:tool_needing_modules()
    local entries = profile:toolchain_entries()

    if #needing > 0 or #entries > 0 then
        -- Toolchain fold: collapsed shows a single summary row;
        -- expanded reveals per-tool rows with add/remove.
        -- Most profiles use a single tool that's already part of
        -- the profile name, so the collapsed shape is the common
        -- case — only widening when the user actually wants to
        -- edit the list.
        local summary_parts = {}
        local any_unresolved = false
        for _, entry in ipairs(entries) do
            local part = entry.label
            if not entry.resolved then
                part = part .. " (unresolved)"
                any_unresolved = true
            end
            summary_parts[#summary_parts + 1] = part
        end
        local summary
        if #summary_parts == 0 then
            summary = "(none)"
        else
            summary = table.concat(summary_parts, " + ")
        end
        local header_hl = any_unresolved and "DiagnosticWarn" or "Comment"

        tree:node("Toolchain: " .. summary, {
            fold_key = "toolchain:" .. profile.key,
            hl = header_hl,
        }, function()
            for _, entry in ipairs(entries) do
                local lang_suffix = ""
                if #entry.languages > 0 then
                    lang_suffix = "  [" .. table.concat(entry.languages, ", ") .. "]"
                end
                local hl = entry.resolved and "Comment" or "DiagnosticWarn"
                local label = entry.label .. lang_suffix
                if not entry.resolved then
                    label = label .. " (unresolved)"
                end

                tree:item(label, {
                    hl = hl,
                    direct = true,
                    enter_label = "Tool actions",
                    on_enter = function()
                        local key = entry.key
                        local actions = {
                            { label = "Delete tool",
                              do_it = function()
                                  profile:remove_tool(key)
                                  ws:_save_user()
                                  ws:remerge()
                              end },
                            { label = "Cancel", do_it = function() end },
                        }
                        vim.ui.select(actions, {
                            prompt = "Tool '" .. entry.label .. "':",
                            format_item = function(a) return a.label end,
                        }, function(choice)
                            if choice and choice.do_it then choice.do_it() end
                        end)
                    end,
                    on_delete = function()
                        profile:remove_tool(entry.key)
                        ws:_save_user()
                        ws:remerge()
                    end,
                })
            end

            tree:item("+ Add tool", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = function()
                    local items = {}
                    local seen_keys = {}
                    for _, mod in pairs(ws._modules or {}) do
                        for _, tool in pairs(mod._tools or {}) do
                            if tool.key and not tool._removed
                                    and not seen_keys[tool.key]
                                    and not contains(profile._tool_keys or {}, tool.key) then
                                seen_keys[tool.key] = true
                                items[#items + 1] = {
                                    key = tool.key,
                                    label = tool.label or tool.key,
                                    languages = tool.languages or {},
                                    module_id = mod.id,
                                }
                            end
                        end
                    end

                    if #items == 0 then
                        vim.notify(
                            "loomworks: no tools available to add. Detect "
                            .. "host tools or add an SDK.",
                            vim.log.levels.INFO)
                        return
                    end

                    table.sort(items, function(a, b) return a.label < b.label end)

                    vim.ui.select(items, {
                        prompt = "Add tool:",
                        format_item = function(item)
                            local langs = ""
                            if #item.languages > 0 then
                                langs = "  [" .. table.concat(item.languages, ", ") .. "]"
                            end
                            return item.label .. langs
                        end,
                    }, function(choice)
                        if not choice then return end
                        profile:add_tool(choice.key)
                        ws:_save_user()
                        ws:remerge()
                    end)
                end,
            })
        end)
    end

    -- Device selection: per-profile, gated on the profile actually
    -- containing a device-capable module project. A cmake-only profile
    -- in a workspace that also has harmony shouldn't show this row.
    if profile:has_device_module() then
        local device = profile:device()
        local device_text, device_hl
        if device and device:is_online() then
            device_text = "Device: " .. device.display_name
            if device.display_name ~= device.serial then
                device_text = device_text .. " (" .. device.serial .. ")"
            end
            device_hl = "DiagnosticOk"
        elseif profile:device_serial() then
            device_text = "Device: " .. profile:device_serial() .. " (offline)"
            device_hl = "DiagnosticWarn"
        else
            device_text = "Device: (none selected)"
            device_hl = "Comment"
        end
        tree:item(device_text, {
            hl = device_hl,
            direct = true,
            enter_label = "Pick device",
            on_enter = function()
                vim.notify("loomworks: scanning for devices...", vim.log.levels.INFO)
                ws:scan_devices(function(devices)
                    local online = {}
                    for _, d in ipairs(devices) do
                        if d:is_online() then
                            online[#online + 1] = d
                        end
                    end
                    if #online == 0 then
                        vim.notify("loomworks: no devices found", vim.log.levels.INFO)
                        return
                    end
                    -- Include a "clear" option if a device is currently set
                    local items = vim.list_extend({}, online)
                    if profile:device_serial() then
                        items[#items + 1] = { clear = true }
                    end
                    vim.ui.select(items, {
                        prompt = "Select device for profile:",
                        format_item = function(d)
                            if d.clear then return "(clear selection)" end
                            local mark = (profile:device_serial() == d.serial) and " (current)" or ""
                            return d.display_name .. " (" .. d.serial .. ")" .. mark
                        end,
                    }, function(choice)
                        if not choice then return end
                        if choice.clear then
                            profile:clear_device()
                        else
                            profile:set_device(choice.serial)
                        end
                        ws._core._deps.events.emit("active_set_changed", ws._active_set)
                    end)
                end)
            end,
        })
    end

    -- (Last-operation message is already shown in the profile header
    -- line — see the `display` assembly in the profiles section's main
    -- render function — so we don't repeat it here.)

    -- Default target line
    local launch_target = profile:default_target()
    local target_display, target_hl
    if launch_target and launch_target:is_valid() then
        target_display = "Target: " .. launch_target:display_name()
        target_hl = "LoomworksTarget"
    elseif launch_target then
        target_display = "Target: " .. launch_target:display_name() .. " (stale)"
        target_hl = "DiagnosticWarn"
    else
        target_display = "Target: (no target set)"
        target_hl = "Comment"
    end
    tree:item(target_display, {
        hl = target_hl,
        -- `direct = true` skips the tree-level action menu when both
        -- on_enter and on_build are present — otherwise the tree
        -- shows its own "Activate / Build" prompt before our nested
        -- "Build / Switch target" prompt, which doubles up.
        direct = true,
        -- Enter = action picker (Build / Switch target). When the
        -- target is unset or invalid, the action picker drops to the
        -- target picker directly since "Build" wouldn't apply.
        on_enter = function() lw.pick_target_action() end,
        -- `b` = direct build, skipping the action picker. Mirrors
        -- the per-config `b` action in the Projects section.
        on_build = function() lw.build_target() end,
    })

    local pps = profile:projects()
    if #pps > 0 then
        tree:group({{"Projects:  ", "LoomworksSection"}, {"[b] build  [c] configure  [t] task output  [o] options  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
            for _, pp in ipairs(pps) do
                local config_status, _status_hl, progress_str, is_spinning =
                        helpers.resolve_config_status(pp, nil)

                local unit = pp._config_unit
                local type_tag = pp._project and pp._project.type
                    and (" [" .. pp._project.type .. "]") or ""
                local pp_pkey = pp._project and pp._project.key or "?"
                local variant_display = pp:variant_name() or "?"
                if pp:is_configuration_missing() then
                    variant_display = variant_display .. " (missing)"
                end
                -- Status moves into the header line (parallel to the
                -- profile-level "(status)" suffix), so the expansion
                -- doesn't have to repeat it as a child leaf.
                local status_suffix = config_status
                    and (" (" .. config_status .. ")") or ""
                -- Project rows: always blue. Severity is in the marker
                -- icon's color, not the row text. Missing configurations
                -- still surface a warn-colored marker via the status
                -- "unconfigured"/missing mapping in helpers.
                local pp_marker = helpers.status_marker(config_status)
                local pp_marker_hl = pp:is_configuration_missing()
                    and "DiagnosticWarn"
                    or helpers.status_marker_hl(config_status)
                tree:node(pp_pkey .. type_tag .. " → " .. variant_display
                        .. status_suffix .. progress_str, {
                    fold_key = "profile_proj:" .. profile.key .. ":" .. pp_pkey,
                    marker = pp_marker,
                    marker_hl = pp_marker_hl,
                    spinning = is_spinning,
                    hl = "LoomworksProject",
                    enter_label = "Open task output",
                    on_enter = actions.open_task(unit),
                    on_task = actions.open_task(unit),
                    on_build = actions.build_configuration(unit),
                    on_build_serial = actions.build_serial_configuration(unit),
                    on_rebuild = actions.rebuild_configuration(unit),
                    on_clean = actions.clean_configuration(unit),
                    on_configure = actions.configure_configuration(unit),
                    on_delete = actions.delete_config(unit),
                    on_options = actions.show_options(unit),
                }, function()
                    -- Per-ConfigUnit tool(s): the specific tools
                    -- this (project, configuration) is actually
                    -- using out of the profile's array. For most
                    -- profiles this is one tool; for multi-language
                    -- configurations (e.g. cmake+rust) it's the
                    -- set that covers the configuration's required
                    -- languages.
                    local cfg = pp._configuration
                    if cfg and not cfg._removed and profile.tools_for then
                        local tools = profile:tools_for(cfg)
                        if #tools > 0 then
                            local labels = {}
                            for _, t in ipairs(tools) do
                                labels[#labels + 1] = t.label or t.key or "?"
                            end
                            local kw = #tools == 1 and "Tool" or "Tools"
                            tree:leaf(kw .. ": " .. table.concat(labels, ", "), "Comment")
                        end
                    end
                    helpers.render_cached_details(tree, config_status, status_hl, nil, nil, unit)
                end)
            end
        end)
    end
end

--- Render the profiles section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile, config_sets, tool_entries }
return function(tree, ctx)
    local lw = ctx.lw
    local all_profiles = ctx.all_profiles

    -- All profiles are shown
    local profiles = {}
    for _, profile in pairs(all_profiles) do
        profiles[#profiles + 1] = profile
    end
    table.sort(profiles, function(a, b) return a.key < b.key end)

    tree:leaf("Profiles", "Title")
    tree:leaf("[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment")
    tree:blank()

    -- Check if we have projects at all
    local has_projects = false
    local projects = lw.get_projects()
    if projects then
        for _ in pairs(projects) do
            has_projects = true
            break
        end
    end

    local ws = lw.get_workspace()

    helpers.render_grouped(tree, profiles, function(t, profile, group)
        local is_active = profile == ctx.active_profile
        local profile_running = profile:is_running()
        local has_operation = profile:has_active_operation()

        local status_label, _status_hl = profile:status()
        local marker = helpers.status_marker(status_label)
        local marker_hl = helpers.status_marker_hl(status_label)

        local prof_modified = ws and ws:is_profile_modified(profile) and "+" or ""
        local display = prof_modified .. profile.key
        if profile.orphaned_set then
            display = display .. " [stale]"
        end
        if not profile:is_complete() then
            display = display .. " [incomplete]"
        end

        display = display .. " (" .. status_label .. ")"
        if has_operation then
            local pps = profile:projects()
            local pct = helpers.aggregate_progress(pps)
            if pct then
                display = display .. " " .. pct .. "%"
            end
            display = display .. helpers.format_elapsed(profile:operation_elapsed())
        else
            local op = profile:operation()
            if op and op.message then
                display = display .. " — " .. op.message
            end
        end

        -- Profile rows: active profile gets bold green
        -- (`LoomworksProfile`). Inactive profiles use
        -- `LoomworksProfileInactive` — linked to `LoomworksActionable`
        -- (Normal text), matching the `Projects:` label so inactive
        -- profile rows read as plain interactive items rather than
        -- competing with the active green.
        local hl
        if group == "shared" then
            hl = "Comment"
        elseif is_active then
            hl = "LoomworksProfile"
        else
            hl = "LoomworksProfileInactive"
        end

        t:node(display, {
            fold_key = "profile:" .. profile.key,
            marker = marker,
            marker_hl = marker_hl,
            spinning = profile_running or has_operation,
            hl = hl,
            enter_label = "Activate",
            on_enter = actions.activate(profile),
            publish_label = helpers.intent_action_label(profile),
            on_publish = function()
                helpers.cycle_intent(profile)
                if ws then
                    ws:_save_user()
                    ws._core._deps.events.emit("active_set_changed", ws._active_set)
                end
            end,
            on_build = actions.build(profile),
            on_build_serial = actions.build_serial(profile),
            on_rebuild = actions.rebuild(profile),
            on_clean = actions.clean(profile),
            on_configure = actions.configure(profile),
            on_delete = actions.delete_profile(profile),
        }, function()
            render_profile_details(t, profile, lw)
        end)
    end)

    -- Sentinel line for profile creation
    if not has_projects then
        tree:leaf("No projects yet. Add projects first.", "Comment")
    else
        tree:item("▸ Create new profile", {
            hl = "LoomworksAdd",
            direct = true,
            on_enter = actions.create_profile(ctx),
        })
    end

    tree:blank()
end
