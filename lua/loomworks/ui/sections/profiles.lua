--- loomworks/ui/sections/profiles.lua — Profiles section renderer.
---
--- Renders from the workspace view's `profiles` rows
--- (`loomworks.view.Workspace/1`, spec §19.13 "The workspace view"); the
--- actions below are kept apart. The model writes go through
--- loomworks/ui/model_calls.lua naming the profile by its row (step 5o C2a);
--- the deletions go through it too, naming the profile or unit by its row
--- (step 5o C2c-2), and so do its builds, configures, cleans and rebuilds,
--- in `daemon` mode by the profile row's id or the unit row's `unit_id`
--- (step 5o C2d-1); the cancels, task output, options and device choice
--- still reach the domain objects through `ctx.ref(row)` until step 5o
--- C2d-2.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")
local model = require("loomworks.ui.model_calls")

-- ---------------------------------------------------------------------------
-- Actions (keymaps / mutations)
-- ---------------------------------------------------------------------------

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

--- Remove a tool from a profile's toolchain.
--- @param ws loomworks.Workspace|nil
--- @param row table the profile's view row
--- @param key string the tool's key
local function remove_tool(ws, row, key)
    model.call(ws, "Profiles/1.remove_tool", { profile = row, tool = key }, function(r)
        local ok, err = model.result(r)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "the tool was not removed"), vim.log.levels.ERROR)
        end
    end)
end

--- The actions of a toolchain entry row.
local function tool_actions(ws, row, entry)
    return {
        on_enter = function()
            local key = entry.key
            local choices = {
                { label = "Delete tool", do_it = function() remove_tool(ws, row, key) end },
                { label = "Cancel", do_it = function() end },
            }
            vim.ui.select(choices, {
                prompt = "Tool '" .. entry.label .. "':",
                format_item = function(a) return a.label end,
            }, function(choice)
                if choice and choice.do_it then choice.do_it() end
            end)
        end,
        on_delete = function() remove_tool(ws, row, entry.key) end,
    }
end

--- "+ Add tool": pick one of the workspace's tools the profile lacks (its
--- toolchain as the view lists it). *(Transition, until step 5o C2c.)* The
--- tools offered are the editor's model's detected ones.
--- @param ws loomworks.Workspace|nil
--- @param row table the profile's view row
local function add_tool_action(ws, row)
    if not ws then return nil end
    return function()
        local items = {}
        local seen_keys = {}
        local have = {}
        for _, entry in ipairs(row.toolchain or {}) do have[#have + 1] = entry.key end
        for _, mod in pairs(ws._modules or {}) do
            for _, tool in pairs(mod._tools or {}) do
                if tool.key and not tool._removed
                        and not seen_keys[tool.key]
                        and not contains(have, tool.key) then
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
            model.call(ws, "Profiles/1.add_tool", { profile = row, tool = choice.key }, function(r)
                local ok, err = model.result(r)
                if not ok then
                    vim.notify("loomworks: " .. tostring(err or "the tool was not added"), vim.log.levels.ERROR)
                end
            end)
        end)
    end
end

--- "Pick device": scan, then choose one of the online devices (or clear).
--- Every device read and choice goes through loomworks.device_source — in
--- `daemon` mode a `Devices/1.scan` task, then `Profiles/1.set_device` /
--- `clear_device` (step 5n C2); a refused or failed scan was notified.
local function pick_device_action(ws, profile)
    if not profile then return nil end
    return function()
        local devices = require("loomworks.device_source")
        vim.notify("loomworks: scanning for devices...", vim.log.levels.INFO)
        devices.scan(ws, function(list)
            if not list then return end
            local online = {}
            for _, d in ipairs(list) do
                if d.state == "online" then
                    online[#online + 1] = d
                end
            end
            if #online == 0 then
                vim.notify("loomworks: no devices found", vim.log.levels.INFO)
                return
            end
            local current = devices.chosen_in(ws, profile, list)
            local items = vim.list_extend({}, online)
            if current then
                items[#items + 1] = { clear = true }
            end
            vim.ui.select(items, {
                prompt = "Select device for profile:",
                format_item = function(d)
                    if d.clear then return "(clear selection)" end
                    local mark = (current == d.key) and " (current)" or ""
                    return d.label .. " (" .. d.key .. ")" .. mark
                end,
            }, function(choice)
                if not choice then return end
                if choice.clear then
                    devices.clear(ws, profile)
                else
                    devices.select(ws, profile, choice)
                end
            end)
        end)
    end
end

--- The actions of a profile's project row (its configuration unit): `u` the
--- view's unit row, `pp` its project-in-profile (`ctx.ref`, for the task
--- output, cancel and options until step 5o C2d-2). Its deletion, builds,
--- configure, clean and rebuild name the row (in `daemon` mode by its
--- `unit_id`; none while the profile has no unit there).
local function unit_actions(ctx, u, pp)
    local lw, ws = ctx.lw, ctx.ws
    local unit = pp and pp._config_unit
    local acting
    if ctx.mode == "daemon" then acting = u.unit_id ~= nil else acting = unit ~= nil end
    return {
        on_enter = actions.open_task(unit),
        on_task = actions.open_task(unit),
        on_build = acting and actions.build_configuration(u, ws) or nil,
        on_build_serial = acting and actions.build_serial_configuration(u, ws) or nil,
        on_rebuild = acting and actions.rebuild_configuration(u, ws) or nil,
        on_clean = acting and actions.clean_configuration(u, ws) or nil,
        on_configure = acting and actions.configure_configuration(u, ws) or nil,
        -- Per-config cancel only appears when this unit's
        -- task is live. Single-task cancel suffices —
        -- chained tasks behind it abort via the Future's
        -- cancel token (start_one_task wires
        -- `token:on_cancel` to call `task:stop()`).
        on_cancel = (unit and unit._task_id) and function()
            if lw.cancel_task(unit._task_id) then
                vim.notify("loomworks: cancelled task " ..
                    tostring(unit._task_id))
            end
        end or nil,
        on_delete = acting and actions.delete_config(u, ws) or nil,
        on_options = actions.show_options(unit),
    }
end

--- `opts` with the entries of `acts` added.
local function with(opts, acts)
    for k, v in pairs(acts) do opts[k] = v end
    return opts
end

--- The actions of a profile row: its model writes (always), its deletion
--- and operations by the row (on an actionable row: in `daemon` mode one with
--- an id; step 5o C2d-1), its cancel on its domain object `profile` (only
--- when the editor's model has it, `ctx.ref`; until step 5o C2d-2).
local function profile_actions(ctx, profile, row)
    local lw, ws = ctx.lw, ctx.ws
    local actionable = helpers.actionable(ctx, row)
    local acts = helpers.describe_action({
        on_enter = actions.activate(row, ws),
        on_publish = function() helpers.cycle_intent(row, ws) end,
        on_delete = actionable and actions.delete_profile(row, ws) or nil,
    }, helpers.row_item("profile", row))
    if actionable then
        with(acts, {
            on_build = actions.build(row, ws),
            on_build_serial = actions.build_serial(row, ws),
            on_rebuild = actions.rebuild(row, ws),
            on_clean = actions.clean(row, ws),
            on_configure = actions.configure(row, ws),
        })
    end
    if not profile then return acts end
    return with(acts, {
        -- Cancel only appears in the picker when there's actually
        -- something to cancel. Tasks chained behind a cancelled
        -- one auto-abort via the Future token in start_one_task.
        on_cancel = row.running and function()
            -- Its local tasks, and the tasks the editor started in the
            -- workspace daemon (step 5k: `Tasks/1.cancel`).
            local n = lw.cancel_tasks_for_profile(profile)
                + require("loomworks.daemon.editor_ops").cancel_for_profile(profile)
            vim.notify(string.format(
                "loomworks: cancelled %d task(s) for profile '%s'",
                n, profile.key))
        end or nil,
    })
end

-- ---------------------------------------------------------------------------
-- Rendering (from the view rows)
-- ---------------------------------------------------------------------------

--- Render a profile's project row (one of `row.units`).
local function render_unit(tree, ctx, row, u)
    local config_status, _, progress_str, is_spinning = helpers.unit_status(u, ctx.unit_progress(u))
    local type_tag = u.type and (" [" .. u.type .. "]") or ""
    local pp_pkey = u.project or "?"
    local variant_display = u.configuration or "?"
    local missing_suffix = u.missing and " (missing)" or ""
    -- Status moves into the header line (parallel to the
    -- profile-level "(status)" suffix), so the expansion
    -- doesn't have to repeat it as a child leaf.
    local status_suffix = config_status
        and (" (" .. config_status .. ")") or ""
    -- Severity is in the marker icon's color, not the row
    -- text. Missing configurations still surface a
    -- warn-colored marker via the status mapping.
    -- Compat-error swap: when this profile's tool can't
    -- honor this configuration, the row is unbuildable
    -- regardless of cached state. Swap the marker to
    -- ✗ / DiagnosticError so the row reads as blocked
    -- (matches the severity of the diagnostics-section
    -- entry that reports the same reason).
    -- Stored per-PP because the same ConfigUnit may be
    -- valid in one profile and invalid in another.
    local compat_error = u.compat_error
    local pp_marker, pp_marker_hl
    if compat_error then
        pp_marker = "✗ "
        pp_marker_hl = "DiagnosticError"
    else
        pp_marker = helpers.status_marker(config_status)
        pp_marker_hl = u.missing
            and "DiagnosticWarn"
            or helpers.status_marker_hl(config_status)
    end
    -- Row chunks mirror the config-set project row:
    -- project key in blue, arrow + type tag + status in
    -- Comment, variant in LoomworksVariant. Reads as the
    -- same vocabulary across sections.
    local row_chunks = {
        { pp_pkey, "LoomworksProject" },
        { type_tag, "Comment" },
        { " → ", "Comment" },
        { variant_display, "LoomworksVariant" },
    }
    if missing_suffix ~= "" then
        row_chunks[#row_chunks + 1] = { missing_suffix, "DiagnosticWarn" }
    end
    row_chunks[#row_chunks + 1] = { status_suffix .. progress_str, "Comment" }
    -- Overwritten marker (spec/ui.md §1.5): another unit's build has
    -- clobbered this unit's shared output artifact. The built marker
    -- (✔) is retained; the tag signals the on-disk artifact is no
    -- longer this unit's, so it needs a rebuild to reclaim it.
    if u.overwritten then
        row_chunks[#row_chunks + 1] = { " [overwritten]", "LoomworksConflict" }
    end
    -- Per-configuration compiler-cache mismatch (spec/ui.md): the
    -- resolved launcher differs from the one this unit was built
    -- with, so the next build reconfigures to apply the change.
    -- Resolved for THIS profile (its `cache` fill), not the active one.
    if u.launcher_changed then
        row_chunks[#row_chunks + 1] = { " [stale — reconfigure]", "LoomworksStale" }
    end
    tree:node(row_chunks, with({
        fold_key = "profile_proj:" .. row.key .. ":" .. pp_pkey,
        marker = pp_marker,
        marker_hl = pp_marker_hl,
        spinning = is_spinning,
        hl = "LoomworksProject",
        enter_label = "Open task output",
    }, unit_actions(ctx, u, ctx.ref(u))), function()
        -- Surface the compat-error reason at the top of
        -- the expansion so the user sees *why* the row is
        -- blocked without scrolling to the diagnostics
        -- section.
        if compat_error then
            tree:leaf("✗ " .. compat_error, "DiagnosticError")
        end
        -- Per-ConfigUnit tool(s): the specific tools
        -- this (project, configuration) is actually
        -- using out of the profile's array. For most
        -- profiles this is one tool; for multi-language
        -- configurations (e.g. cmake+rust) it's the
        -- set that covers the configuration's required
        -- languages.
        if u.tools then
            local kw = #u.tools == 1 and "Tool" or "Tools"
            tree:leaf(kw .. ": " .. table.concat(u.tools, ", "), "Comment")
        end
        -- Uniqueify the fold_key prefix per (profile, project)
        -- so the Targets node (and its `ttype:`/`target:`
        -- descendants) doesn't collide across profiles —
        -- otherwise the cursor jumps to the topmost match
        -- when collapsing in any non-first profile.
        local cached_fold_prefix = "profile_proj:"
            .. row.key .. ":" .. pp_pkey
        helpers.render_unit_details(tree, u.build_dir, u.targets, cached_fold_prefix)
    end)
end

--- Render profile details when expanded.
--- @param tree loomworks.Tree
--- @param ctx table the page context
--- @param row table the profile's view row
local function render_profile_details(tree, ctx, row)
    local profile = ctx.ref(row)
    local ws = ctx.ws
    tree:description(row.description)
    if row.orphaned_set then
        tree:leaf("Set '" .. (row.config_set or "?")
            .. "' removed from loomworks.json", "DiagnosticWarn")
    elseif row.config_set then
        tree:leaf("Set: " .. row.config_set, "Comment")
    end

    -- Toolchain section: one row per tool in the profile's tool list.
    -- Each row is a single tool selection; the user adds and removes
    -- entries. Resolution is language-keyed — at build time each
    -- ConfigUnit picks the first tool in the array that provides one
    -- of its configuration's required languages.
    local entries = row.toolchain
    if entries then
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
            fold_key = "toolchain:" .. row.key,
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

                tree:item(label, with({
                    hl = hl,
                    direct = true,
                    enter_label = "Tool actions",
                }, tool_actions(ws, row, entry)))
            end

            tree:item("+ Add tool", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = add_tool_action(ws, row),
            })
        end)
    end

    -- Compiler cache: one profile-level row, sibling to Toolchain, for a
    -- profile that contains a C/C++-caching module (spec/ui.md). Informational
    -- in v1 (no picker) — policy is edited through the variable system. A
    -- launcher mismatch vs the configured units carries a [stale — reconfigure]
    -- hint (LoomworksStale).
    local cache_status = row.compiler_cache
    if cache_status then
        local r = { { cache_status.text, "Comment" } }
        if cache_status.stale then
            r[#r + 1] = { " [stale — reconfigure]", "LoomworksStale" }
        end
        tree:item(r, { direct = true })
    end

    -- Device selection: per-profile, gated on the profile actually
    -- containing a device-capable module project. A cmake-only profile
    -- in a multi-module workspace shouldn't show this row.
    if row.device_capable then
        local device = row.device or {}
        local device_text, device_hl
        if device.state == "online" then
            device_text = "Device: " .. device.label
            if device.label ~= device.key then
                device_text = device_text .. " (" .. device.key .. ")"
            end
            device_hl = "DiagnosticOk"
        elseif device.key then
            device_text = "Device: " .. device.key .. " (offline)"
            device_hl = "DiagnosticWarn"
        else
            device_text = "Device: (none selected)"
            device_hl = "Comment"
        end
        tree:item(device_text, {
            hl = device_hl,
            direct = true,
            enter_label = "Pick device",
            on_enter = pick_device_action(ws, profile),
        })
    end

    -- The last-operation message is already shown in the profile header
    -- line, so it is not repeated here.

    local target = row.default_target
    local target_display, target_hl
    if target and row.default_target_valid then
        -- The launch configuration's description summary (ui §1.5, §1.16).
        target_display = "Target: " .. target
            .. helpers.picker_summary(row.default_target_description)
        target_hl = "LoomworksTarget"
    elseif target then
        target_display = "Target: " .. target .. " (stale)"
        target_hl = "DiagnosticWarn"
    else
        target_display = "Target: (no target set)"
        target_hl = "Comment"
    end
    local lw = ctx.lw
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

    if #row.units > 0 then
        tree:group("Projects:", "LoomworksSection", function()
            for _, u in ipairs(row.units) do
                render_unit(tree, ctx, row, u)
            end
        end)
    end

    tree:blank()
end

--- Render the profiles section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, view, ref, ws, all_profiles, active_profile, config_sets, tool_entries }
return function(tree, ctx)
    local view = ctx.view

    tree:leaf("Profiles", "Title")
    tree:leaf("[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment")
    tree:blank()

    helpers.render_grouped(tree, view.profiles, function(t, row, group)
        local status_label = row.status
        local marker = helpers.status_marker(status_label)
        local marker_hl = helpers.status_marker_hl(status_label)

        -- Profile-level compat-error swap: if any PP in this
        -- profile carries a tool/configuration mismatch, swap the
        -- profile's status marker to ✗ / DiagnosticError so the
        -- problem is visible at a glance without expanding the
        -- profile. The per-PP rows underneath still carry their
        -- own ✗ marker.
        if row.compat_error then
            marker = "✗ "
            marker_hl = "DiagnosticError"
        end

        -- Head = key + text tags ([stale]/[incomplete]); tail = (status) + any
        -- progress/message. A `[conflict]` tag (spec/ui.md §1.5) sits between
        -- them and needs its own `LoomworksConflict` highlight, so the row
        -- becomes a chunk list when a conflict is present (otherwise a plain
        -- string, matching every other profile row).
        local head = (row.modified and "+" or "") .. row.key
        if row.orphaned_set then
            head = head .. " [stale]"
        end
        if row.incomplete then
            head = head .. " [incomplete]"
        end

        -- Static cross-profile output-artifact overlap (spec/ui.md §1.5):
        -- two profiles that would write the same output binary. Absent while
        -- the profile is unconfigured (artifacts unknown until configure).
        local has_conflict = row.artifact_conflict

        local tail = " (" .. status_label .. ")"
        -- A task observed in the workspace daemon counts as the profile's
        -- active Operation (spec/ui.md §1.5), plus its origin marker.
        local origin = row.origin
        -- A running operation's percent and elapsed time are not in the view
        -- (API.md §14.4): the page's progress source gives them. Otherwise
        -- the last finished operation's end message.
        if row.busy then
            local prog = ctx.profile_progress(row) or {}
            if prog.pct then
                tail = tail .. " " .. prog.pct .. "%"
            end
            tail = tail .. helpers.format_elapsed(prog.elapsed)
        elseif row.last_result and row.last_result.message then
            tail = tail .. " — " .. row.last_result.message
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
        elseif row.active then
            hl = "LoomworksProfile"
        else
            hl = "LoomworksProfileInactive"
        end

        -- Assemble the header. With a conflict, the row is a chunk list so the
        -- `[conflict]` tag carries `LoomworksConflict` between the tags and the
        -- status suffix; without one it stays a plain string like every other
        -- profile row.
        local display
        if has_conflict or origin then
            display = { { head, hl } }
            if has_conflict then display[#display + 1] = { " [conflict]", "LoomworksConflict" } end
            display[#display + 1] = { tail, hl }
            if origin then display[#display + 1] = { "  " .. origin, "Comment" } end
        else
            display = head .. tail
        end

        t:node(display, with(helpers.describe({
            fold_key = "profile:" .. row.key,
            marker = marker,
            marker_hl = marker_hl,
            spinning = row.running or row.busy,
            hl = hl,
            enter_label = "Activate",
            publish_label = helpers.intent_action_label(row.intent),
        }, row.description), profile_actions(ctx, ctx.ref(row), row)), function()
            render_profile_details(t, ctx, row)
        end)
    end)

    if #view.projects == 0 then
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
