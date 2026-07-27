--- loomworks/ui/helpers.lua — Shared rendering helpers for status sections.

local M = {}

--- Format a progress update as a compact string like "[2/10]".
--- @param p loomworks.ProgressUpdate|nil
--- @return string
function M.format_progress(p)
    if not p then return "" end
    if p.current and p.total and p.total > 0 then
        local str = " [" .. p.current .. "/" .. p.total .. "]"
        if p.message then str = str .. " " .. p.message end
        return str
    elseif p.message then
        return " " .. p.message
    end
    return ""
end

--- Format elapsed seconds as a compact duration like "1m23s" or "42s".
--- @param seconds number|nil
--- @return string
function M.format_elapsed(seconds)
    if not seconds then return "" end
    local s = math.floor(seconds)
    if s < 60 then
        return " " .. s .. "s"
    end
    local m = math.floor(s / 60)
    s = s % 60
    if m < 60 then
        return " " .. m .. "m" .. string.format("%02d", s) .. "s"
    end
    local h = math.floor(m / 60)
    m = m % 60
    return " " .. h .. "h" .. string.format("%02d", m) .. "m"
end

--- Compute weighted percentage across multiple ProfileProjects.
--- Configure counts as 10% of overall work, build as 90%.
--- @param pps loomworks.ProfileProject[]
--- @return number|nil percentage 0-100
function M.aggregate_progress(pps)
    local lw = require("loomworks")
    local has_any = false
    local total_pct = 0
    local count = 0
    for _, pp in ipairs(pps) do
        local status = pp:status()
        if status == "configuring" or status == "building" then
            local p = pp._config_unit:progress()
            if p and p.current and p.total and p.total > 0 then
                has_any = true
                local phase_pct = p.current / p.total
                if status == "configuring" then
                    total_pct = total_pct + 10 * phase_pct
                else
                    total_pct = total_pct + 10 + 90 * phase_pct
                end
                count = count + 1
            end
        end
    end
    if not has_any then return nil end
    return math.floor(total_pct / count)
end

M.STATUS_HL = {
    unconfigured     = "LoomworksUnconfigured",
    configured       = "LoomworksConfigured",
    built            = "LoomworksBuilt",
    failed_configure = "LoomworksFailed",
    failed_build     = "LoomworksFailed",
    configuring      = "LoomworksRunning",
    building         = "LoomworksRunning",
    deleting         = "LoomworksDeleting",
    cleaning         = "LoomworksDeleting",
    unknown          = "LoomworksUnknown",
}

M.STATUS_ICON = {
    unconfigured     = "○",
    configured       = "◐",
    built            = "✓",
    failed_configure = "✗",
    failed_build     = "✗",
    unknown          = "?",
}

--- Marker color (separate from row text color). Mapped to the
--- standard Diagnostic groups so the marker reads as severity
--- independent of the row's entity color (profiles green,
--- projects blue, etc.).
M.STATUS_MARKER_HL = {
    unconfigured     = "Comment",
    configured       = "Comment",
    built            = "DiagnosticOk",
    failed_configure = "DiagnosticError",
    failed_build     = "DiagnosticError",
    deleting         = "DiagnosticError",
    cleaning         = "DiagnosticError",
    configuring      = "DiagnosticWarn",
    building         = "DiagnosticWarn",
    unknown          = "DiagnosticWarn",
}

--- Get the marker highlight group for a status. Falls back to
--- `Comment` (calm) when the status is unknown to the table.
--- @param status string
--- @return string
function M.status_marker_hl(status)
    return M.STATUS_MARKER_HL[status] or "Comment"
end

--- Format a status label with its icon prefix.
--- Running/deleting states use the spinner so no icon is added.
--- Composite labels (e.g. "1 building, 1 failed") pass through unchanged.
--- @param status string
--- @return string
function M.format_status(status)
    local icon = M.STATUS_ICON[status]
    if icon then
        return icon .. " " .. status
    end
    return status
end

--- Get the status icon as a tree marker (icon + trailing space).
--- Returns "○ " for unknown/composite statuses.
--- @param status string
--- @return string marker
function M.status_marker(status)
    return (M.STATUS_ICON[status] or "○") .. " "
end

--- Resolve the live status for a ConfigUnit.
--- Used by both profile and project sections — ConfigUnit is the single source of truth.
--- @param unit loomworks.ConfigUnit
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_unit_status(unit)
    local state = unit:state()
    if state == "deleting" then
        local label = unit:deleting_reason() or "deleting"
        return label, M.STATUS_HL.deleting, "", true
    end
    if state == "configuring" or state == "building" then
        local progress_str = M.format_progress(unit:progress())
                .. M.format_elapsed(unit:elapsed())
        return state, M.STATUS_HL[state] or "DiagnosticWarn", progress_str, true
    end
    -- Map ConfigUnit state names back to cache state names for HL lookup.
    local cache_state = state
    if state == "configure_failed" then cache_state = "failed_configure" end
    if state == "build_failed" then cache_state = "failed_build" end
    return cache_state, M.STATUS_HL[cache_state] or "Comment", "", false
end

--- Resolve the live status for a ProfileProject.
--- @param pp loomworks.ProfileProject
--- @param cached loomworks.CachedConfig|nil (unused, kept for API compat)
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status(pp, cached)
    if not pp._config_unit then
        return "unconfigured", M.STATUS_HL.unconfigured, "", false
    end
    return M.resolve_unit_status(pp._config_unit)
end

--- Resolve the live status for a ConfigUnit (profile-agnostic).
--- @param unit loomworks.ConfigUnit
--- @param cached loomworks.CachedConfig|nil (unused, kept for API compat)
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status_global(unit, cached)
    return M.resolve_unit_status(unit)
end

--- Render cached configuration details as leaf lines.
---
--- Status is *not* rendered here — callers fold it into the parent
--- node's header line (matching the profile-level "(status)" suffix)
--- so the expansion doesn't repeat it.
--- @param tree loomworks.Tree
--- @param config_status string (kept for call-site parity; currently unused)
--- @param status_hl string (likewise unused — see config_status)
--- @param cached loomworks.CachedConfig|nil (deprecated, reads from unit when nil)
--- @param fold_prefix? string prefix for foldable sub-nodes (e.g. "App:Debug:ninja-gcc-12")
--- @param unit? loomworks.ConfigUnit for runtime-only data (targets) and first-class fields
function M.render_cached_details(tree, config_status, status_hl, cached, fold_prefix, unit)
    local build_dir = cached and cached.build_dir or (unit and unit.build_dir_value)

    if build_dir then
        tree:leaf("Build dir: " .. build_dir, "Comment")
    end
    -- The toolchain (generator/compiler/SDK kit) is shown once per profile in
    -- the profile-level Toolchain row, so it's not repeated per config here.

    local targets = unit and unit.targets or nil
    if targets and next(targets) then
        M.render_targets(tree, targets, fold_prefix)
    end
end

--- Map target type to compact display labels.
local TARGET_TYPE_LABELS = {
    executable       = "Executables",
    static_library   = "Static Libraries",
    shared_library   = "Shared Libraries",
    module_library   = "Module Libraries",
    object_library   = "Object Libraries",
    interface_library = "Interface Libraries",
    npm_script       = "Scripts",
    launch_config    = "Launch Configs",
}

--- Display order for target type groups.
local TARGET_TYPE_ORDER = {
    "executable", "npm_script", "launch_config",
    "static_library", "shared_library",
    "module_library", "object_library", "interface_library",
}

--- Render targets sub-tree, grouped by type.
--- @param tree loomworks.Tree
--- @param targets table<string, loomworks.CachedTarget>
--- @param fold_prefix? string prefix for fold keys
function M.render_targets(tree, targets, fold_prefix)
    local by_type = {}
    local total = 0
    for name, tgt in pairs(targets) do
        local t = tgt.type
        by_type[t] = by_type[t] or {}
        by_type[t][#by_type[t] + 1] = { name = name, tgt = tgt }
        total = total + 1
    end
    for _, list in pairs(by_type) do
        table.sort(list, function(a, b) return a.name < b.name end)
    end

    local prefix = fold_prefix and (fold_prefix .. ":") or ""

    tree:node("Targets (" .. total .. ")", {
        fold_key = prefix .. "targets",
        hl = "Comment",
    }, function()
        for _, type_key in ipairs(TARGET_TYPE_ORDER) do
            local group = by_type[type_key]
            -- Always show Executables (even when empty), only show others if non-empty
            if group or type_key == "executable" then
                local count = group and #group or 0
                local group_label = TARGET_TYPE_LABELS[type_key] or type_key
                tree:node(group_label .. " (" .. count .. ")", {
                    fold_key = prefix .. "ttype:" .. type_key,
                    hl = "Comment",
                }, function()
                    if not group then return end
                    for _, entry in ipairs(group) do
                        local has_deps = entry.tgt.dependencies and #entry.tgt.dependencies > 0
                        local has_artifact = entry.tgt.artifact ~= nil
                        if has_deps or has_artifact then
                            tree:node(entry.name, {
                                fold_key = prefix .. "target:" .. entry.name,
                                hl = "Comment",
                            }, function()
                                if has_artifact then
                                    tree:leaf("Path: " .. entry.tgt.artifact, "Comment")
                                end
                                if has_deps then
                                    tree:leaf("Links: " .. table.concat(entry.tgt.dependencies, ", "), "Comment")
                                end
                            end)
                        else
                            tree:leaf(entry.name, "Comment")
                        end
                    end
                end)
            end
        end
    end)
end

--- Cycle the intent: local → local+shared → shared → local.
--- All three states always available. Data stays in user.json while cycling.
--- @param item table domain object with _intent field
function M.cycle_intent(item)
    if item._intent == "local" then
        item._intent = "local+shared"
    elseif item._intent == "local+shared" then
        item._intent = "shared"
    else
        item._intent = "local"
    end
end

--- Get the label for the next intent transition.
--- @param item table domain object with _intent field
--- @return string
function M.intent_action_label(item)
    if item._intent == "local" then
        return "Share (→ local + shared)"
    elseif item._intent == "local+shared" then
        return "Unpin local (→ shared)"
    else
        return "Pin local (→ local)"
    end
end

--- Classify an item into a display group based on _intent.
--- @param item table domain object with _intent field
--- @return "local+shared"|"local"|"shared"
function M.publish_group(item)
    return item._intent or "local"
end

--- Sort items into intent groups and render with separators.
--- Groups: Local + Shared (with pin icon on user-pinned), Local, Shared (dimmed).
--- Empty groups are hidden.
--- @param tree loomworks.Tree
--- @param items table[] array of items to group
--- @param render_fn fun(tree: loomworks.Tree, item: table, group: string) render a single item
function M.render_grouped(tree, items, render_fn)
    local both = {}
    local local_items = {}
    local shared = {}

    for _, item in ipairs(items) do
        local group = M.publish_group(item)
        if group == "local+shared" then
            both[#both + 1] = item
        elseif group == "local" then
            local_items[#local_items + 1] = item
        else
            shared[#shared + 1] = item
        end
    end

    if #both > 0 then
        tree:leaf("── Local + Shared ──", "NonText")
        for _, item in ipairs(both) do
            render_fn(tree, item, "local+shared")
        end
    end
    if #local_items > 0 then
        tree:leaf("── Local ──", "NonText")
        for _, item in ipairs(local_items) do
            render_fn(tree, item, "local")
        end
    end
    if #shared > 0 then
        tree:leaf("── Shared ──", "NonText")
        for _, item in ipairs(shared) do
            render_fn(tree, item, "shared")
        end
    end
end

return M
