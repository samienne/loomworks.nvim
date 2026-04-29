--- loomworks/ui/v2/view_model/overview.lua — Overview presentation.
---
--- Pure function: workspace state + UI section_state in, presentation
--- tree out. The view renders the tree; the view model never knows
--- about buffers.
---
--- Section kinds:
---   "active_profile_card"  — profile header + participating project rows
---   "no_active_profile"    — empty-state CTA card
---   "no_workspace"         — workspace not loaded
---   "devices"              — collapsible (default expanded)
---   "cleanup"              — collapsible (default collapsed)
---   "other_profiles"       — collapsible (default collapsed)
---   "other_projects"       — collapsible (default collapsed)
---   "config_sets"          — collapsible (default collapsed)
---
--- Collapsible sections carry:
---   collapsible = true
---   collapsed   = boolean (effective state after applying section_state + defaults)
---
--- Each section has a `selectable` table of refs aligned with rows so
--- callers can resolve `(section, row_index)` → `{ kind, key }`.

local M = {}

--- Default collapsed state per kind.
local DEFAULT_COLLAPSED = {
    devices        = false,
    cleanup        = true,
    other_profiles = true,
    other_projects = true,
    config_sets    = true,
}

--- Effective collapsed state = explicit user choice (if any) else default.
--- @param section_state table<string, boolean>
--- @param kind string
--- @return boolean
local function effective_collapsed(section_state, kind)
    local explicit = section_state and section_state[kind]
    if explicit ~= nil then return explicit end
    return DEFAULT_COLLAPSED[kind] or false
end

--- Convert a ProfileProject into a project row for the active card.
--- @param pp loomworks.ProfileProject
--- @return table
local function project_row_from_pp(pp)
    local pkey    = pp:project_key()
    local variant = pp:variant_name()
    local state   = pp:status()
    local running = pp:running_action()
    return {
        project_key = pkey,
        variant     = variant,
        state       = state,
        running     = running,
        ref         = { kind = "project", key = pkey },
    }
end

--- Build the active-profile card section.
--- @param workspace loomworks.Workspace
--- @param active loomworks.Profile
--- @return table section
local function build_active_card(workspace, active)
    local label, _hl = active:status()
    local set = active._configuration_set_name
    local projects = {}
    local selectable = { { kind = "profile", key = active.key } }
    for _, pp in ipairs(active:projects()) do
        local row = project_row_from_pp(pp)
        projects[#projects + 1] = row
        selectable[#selectable + 1] = row.ref
    end
    return {
        kind = "active_profile_card",
        collapsible = false,
        profile = {
            key           = active.key,
            status_label  = label,
            set           = set,
            running       = active:is_running(),
            ref           = { kind = "profile", key = active.key },
        },
        projects = projects,
        selectable = selectable,
    }
end

--- Build the empty-state card when no profile is active.
--- @return table section
local function build_no_active_card()
    return {
        kind = "no_active_profile",
        collapsible = false,
        actions = {
            { label = "Add project from current directory", action = "add_project_here" },
            { label = "Browse and add project",             action = "add_project_browse" },
            { label = "palette: <leader>wp",                action = nil, hint = true },
        },
        selectable = {},
    }
end

--- @param workspace loomworks.Workspace
--- @param section_state table<string, boolean>
--- @return table|nil
local function build_devices_section(workspace, section_state)
    if not workspace:has_device_modules() then return nil end
    local devices = workspace:devices() or {}
    local online, offline = 0, 0
    local rows = {}
    local selectable = {}
    for _, d in ipairs(devices) do
        if d.state == "online" then online = online + 1 else offline = offline + 1 end
    end
    local collapsed = effective_collapsed(section_state, "devices")
    if not collapsed then
        for _, d in ipairs(devices) do
            rows[#rows + 1] = {
                serial       = d.serial,
                display_name = d.display_name,
                state        = d.state,
                ref          = { kind = "device", key = d.serial },
            }
            selectable[#selectable + 1] = { kind = "device", key = d.serial }
        end
    end
    return {
        kind          = "devices",
        collapsible   = true,
        collapsed     = collapsed,
        online_count  = online,
        offline_count = offline,
        devices       = rows,
        selectable    = selectable,
    }
end

--- Sort profiles by key for stable display.
local function sort_by_key(items)
    table.sort(items, function(a, b) return a.key < b.key end)
    return items
end

--- @param workspace loomworks.Workspace
--- @param active_key string|nil
--- @param section_state table<string, boolean>
--- @return table
local function build_other_profiles_section(workspace, active_key, section_state)
    local list, count = {}, 0
    for _, p in pairs(workspace._profiles or {}) do
        if not active_key or p.key ~= active_key then
            count = count + 1
            list[#list + 1] = p
        end
    end
    sort_by_key(list)
    local collapsed = effective_collapsed(section_state, "other_profiles")
    local items = {}
    local selectable = {}
    if not collapsed then
        for _, p in ipairs(list) do
            local label, _ = p:status()
            items[#items + 1] = {
                key          = p.key,
                status_label = label,
                stale        = p.orphaned_set == true,
                ref          = { kind = "profile", key = p.key },
            }
            selectable[#selectable + 1] = { kind = "profile", key = p.key }
        end
    end
    return {
        kind        = "other_profiles",
        collapsible = true,
        collapsed   = collapsed,
        count       = count,
        items       = items,
        selectable  = selectable,
    }
end

--- Compute project keys participating in the active profile.
--- @param active loomworks.Profile|nil
--- @return table<string, true>
local function active_project_keys(active)
    if not active or not active.mappings then return {} end
    local set = {}
    for k in pairs(active.mappings) do set[k] = true end
    return set
end

--- @param workspace loomworks.Workspace
--- @param active loomworks.Profile|nil
--- @param section_state table<string, boolean>
--- @return table
local function build_other_projects_section(workspace, active, section_state)
    local in_active = active_project_keys(active)
    local list, count = {}, 0
    for key, p in pairs(workspace._projects or {}) do
        if not in_active[key] then
            count = count + 1
            list[#list + 1] = p
        end
    end
    sort_by_key(list)
    local collapsed = effective_collapsed(section_state, "other_projects")
    local items = {}
    local selectable = {}
    if not collapsed then
        for _, p in ipairs(list) do
            items[#items + 1] = {
                key  = p.key,
                type = p._module and p._module.id or nil,
                ref  = { kind = "project", key = p.key },
            }
            selectable[#selectable + 1] = { kind = "project", key = p.key }
        end
    end
    return {
        kind        = "other_projects",
        collapsible = true,
        collapsed   = collapsed,
        count       = count,
        items       = items,
        selectable  = selectable,
    }
end

--- @param workspace loomworks.Workspace
--- @param section_state table<string, boolean>
--- @return table
local function build_config_sets_section(workspace, section_state)
    local list, count = {}, 0
    for _, cs in pairs(workspace._config_sets or {}) do
        count = count + 1
        list[#list + 1] = cs
    end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    local collapsed = effective_collapsed(section_state, "config_sets")
    local items = {}
    local selectable = {}
    if not collapsed then
        for _, cs in ipairs(list) do
            local mapping_count = 0
            for _ in pairs(cs.mappings or {}) do mapping_count = mapping_count + 1 end
            items[#items + 1] = {
                name           = cs.name,
                mapping_count  = mapping_count,
                ref            = { kind = "config_set", key = cs.name },
            }
            selectable[#selectable + 1] = { kind = "config_set", key = cs.name }
        end
    end
    return {
        kind        = "config_sets",
        collapsible = true,
        collapsed   = collapsed,
        count       = count,
        items       = items,
        selectable  = selectable,
    }
end

--- Cleanup candidates section. Stub: orphaned configs only (stray dirs deferred).
--- @param workspace loomworks.Workspace
--- @param section_state table<string, boolean>
--- @return table|nil
local function build_cleanup_section(workspace, section_state)
    local loomworks = require("loomworks")
    local list = loomworks.get_orphaned_configs and loomworks.get_orphaned_configs() or {}
    local count = 0
    for _ in pairs(list) do count = count + 1 end
    if count == 0 then return nil end

    local collapsed = effective_collapsed(section_state, "cleanup")
    local items = {}
    local selectable = {}
    if not collapsed then
        for cache_key, entry in pairs(list) do
            local pkey  = entry and entry.project_key or "?"
            local ckey  = entry and entry.config_key  or cache_key
            items[#items + 1] = {
                project_key = pkey,
                config_key  = ckey,
                cache_key   = cache_key,
                ref         = { kind = "orphan_config", key = cache_key },
            }
            selectable[#selectable + 1] = { kind = "orphan_config", key = cache_key }
        end
    end
    return {
        kind        = "cleanup",
        collapsible = true,
        collapsed   = collapsed,
        count       = count,
        size_bytes  = nil,
        items       = items,
        selectable  = selectable,
    }
end

--- Build the full overview presentation tree.
--- @param workspace loomworks.Workspace|nil
--- @param section_state? table<string, boolean>
--- @return table
function M.build(workspace, section_state)
    section_state = section_state or {}
    if not workspace then
        return {
            workspace_name = nil,
            initialised    = false,
            sections       = {
                {
                    kind = "no_workspace",
                    collapsible = false,
                    actions = { { label = "No workspace loaded", hint = true } },
                    selectable = {},
                },
            },
        }
    end

    local active = workspace._active_profile
    local sections = {}

    if active then
        sections[#sections + 1] = build_active_card(workspace, active)
    else
        sections[#sections + 1] = build_no_active_card()
    end

    local devices = build_devices_section(workspace, section_state)
    if devices then sections[#sections + 1] = devices end

    local cleanup = build_cleanup_section(workspace, section_state)
    if cleanup then sections[#sections + 1] = cleanup end

    sections[#sections + 1] = build_other_profiles_section(workspace,
        active and active.key or nil, section_state)
    sections[#sections + 1] = build_other_projects_section(workspace, active, section_state)
    sections[#sections + 1] = build_config_sets_section(workspace, section_state)

    return {
        workspace_name = workspace._name or "loomworks",
        initialised    = true,
        sections       = sections,
    }
end

--- Resolve a (section, row) cursor position to a selectable ref.
--- @param presentation table overview presentation tree
--- @param section integer
--- @param row integer
--- @return { kind: string, key: string }|nil
function M.ref_at(presentation, section, row)
    local s = presentation.sections and presentation.sections[section]
    if not s then return nil end
    return s.selectable and s.selectable[row] or nil
end

--- Find the (section, row) where a given ref currently lives, or nil.
--- @param presentation table
--- @param ref { kind: string, key: string }|nil
--- @return integer|nil section, integer|nil row
function M.locate_ref(presentation, ref)
    if not ref then return nil, nil end
    for si, s in ipairs(presentation.sections or {}) do
        for ri, r in ipairs(s.selectable or {}) do
            if r.kind == ref.kind and r.key == ref.key then
                return si, ri
            end
        end
    end
    return nil, nil
end

return M
