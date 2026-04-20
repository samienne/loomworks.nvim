--- loomworks/ui/sections/profiles.lua — Profiles section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

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

    -- SDK display
    local sdk = profile:sdk()
    if sdk then
        tree:item("SDK: " .. sdk:display_name(), {
            hl = sdk:is_resolved() and "Comment" or "DiagnosticWarn",
            on_enter = function()
                -- Pick a different SDK
                local ws = profile._workspace
                local candidates = {}
                for _, s in ipairs(ws:sdks()) do
                    if s:is_resolved() then
                        candidates[#candidates + 1] = s
                    end
                end
                candidates[#candidates + 1] = { key = nil, display_name = function() return "(none — host build)" end }
                vim.ui.select(candidates, {
                    prompt = "Select SDK for profile:",
                    format_item = function(s)
                        if s.key == nil then return "(none — host build)" end
                        local mark = (sdk and s.key == sdk.key) and " (current)" or ""
                        return s:display_name() .. mark
                    end,
                }, function(choice)
                    if not choice then return end
                    if choice.key == nil then
                        profile:set_sdk(nil)
                    else
                        profile:set_sdk(choice)
                    end
                    profile:_derive_key()
                    ws:_save_user()
                    ws:remerge()
                end)
            end,
        })
    else
        tree:item("SDK: (none)", {
            hl = "Comment",
            on_enter = function()
                local ws = profile._workspace
                local candidates = {}
                for _, s in ipairs(ws:sdks()) do
                    if s:is_resolved() then
                        candidates[#candidates + 1] = s
                    end
                end
                if #candidates == 0 then
                    vim.notify("loomworks: no SDKs available. Add one from the SDKs section.", vim.log.levels.INFO)
                    return
                end
                vim.ui.select(candidates, {
                    prompt = "Select SDK for profile:",
                    format_item = function(s) return s:display_name() end,
                }, function(choice)
                    if not choice then return end
                    profile:set_sdk(choice)
                    profile:_derive_key()
                    ws:_save_user()
                    ws:remerge()
                end)
            end,
        })
    end

    local tools_data = profile:tools_data()
    if tools_data then
        for mod_type, tool in pairs(tools_data) do
            if tool.label then
                tree:leaf("Tool: " .. tool.label, "Comment")
            end
            if tool.data then
                if tool.data.generator then
                    tree:leaf("Generator: " .. tool.data.generator, "Comment")
                end
                if tool.data.compiler_id then
                    tree:leaf("Compiler: " .. tool.data.compiler_id, "Comment")
                end
            end
        end
    end

    -- Device selection (only when workspace has device-capable modules)
    local ws = profile._workspace
    if ws:has_device_modules() then
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

    local op = profile:operation()
    if op and op.message then
        local op_hl = op.success and "DiagnosticOk" or "DiagnosticError"
        tree:leaf("Last: " .. op.message, op_hl)
    end

    -- Default target line
    local launch_target = profile:default_target()
    local target_display, target_hl
    if launch_target and launch_target:is_valid() then
        target_display = "Target: " .. launch_target:display_name()
        target_hl = "LoomworksActionable"
    elseif launch_target then
        target_display = "Target: " .. launch_target:display_name() .. " (stale)"
        target_hl = "DiagnosticWarn"
    else
        target_display = "Target: (no target set)"
        target_hl = "Comment"
    end
    tree:item(target_display, {
        hl = target_hl,
        on_enter = function()
            lw.build_target()
        end,
    })

    local pps = profile:projects()
    if #pps > 0 then
        tree:group({{"Projects:  ", "LoomworksActionable"}, {"[b] build  [c] configure  [t] task output  [o] options  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
            for _, pp in ipairs(pps) do
                local config_status, status_hl, progress_str, is_spinning =
                        helpers.resolve_config_status(pp, nil)

                local unit = pp._config_unit
                local type_tag = pp._project and pp._project.type
                    and (" [" .. pp._project.type .. "]") or ""
                local pp_pkey = pp._project and pp._project.key or "?"
                local variant_display = pp:variant_name() or "?"
                if pp:is_configuration_missing() then
                    variant_display = variant_display .. " (missing)"
                end
                tree:node(pp_pkey .. type_tag .. " → " .. variant_display .. progress_str, {
                    fold_key = "profile_proj:" .. profile.key .. ":" .. pp_pkey,
                    spinning = is_spinning,
                    hl = pp:is_configuration_missing() and "DiagnosticWarn" or status_hl,
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

        local status_label, status_hl = profile:status()
        local marker = helpers.status_marker(status_label)
        local hl

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
            hl = is_active and "LoomworksActive" or "LoomworksRunning"
            local pps = profile:projects()
            local pct = helpers.aggregate_progress(pps)
            if pct then
                display = display .. " " .. pct .. "%"
            end
            display = display .. helpers.format_elapsed(profile:operation_elapsed())
        elseif is_active then
            hl = "LoomworksActive"
            local op = profile:operation()
            if op and op.message then
                display = display .. " — " .. op.message
            end
        else
            if status_label == "failed_configure" or status_label == "failed_build"
                    or status_label:match("failed") then
                hl = "LoomworksFailed"
            elseif status_label == "unconfigured" then
                hl = "LoomworksUnconfigured"
            else
                hl = "LoomworksConfigured"
            end
            local op = profile:operation()
            if op and op.message then
                display = display .. " — " .. op.message
            end
        end

        t:node(display, {
            fold_key = "profile:" .. profile.key,
            marker = marker,
            spinning = profile_running or has_operation,
            hl = group == "shared" and "Comment" or hl,
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
            hl = "LoomworksActionable",
            direct = true,
            on_enter = actions.create_profile(ctx),
        })
    end

    tree:blank()
end
