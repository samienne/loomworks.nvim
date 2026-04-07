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
--- @param active_profile loomworks.Profile|nil
local function render_tool_entry(tree, cs, entry, active_profile)
    local profile = entry.profile or nil
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
--- @param active_profile loomworks.Profile|nil
local function render_no_tool_entry(tree, cs, profile, active_profile)
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
--- @param active_profile loomworks.Profile|nil
--- @param lw table loomworks API
local function render_set_details(tree, cs, tool_entries, active_profile, lw)
    local set_name = cs.name
    tree:group("Projects:", "Comment", function()
        local sorted = {}
        for project, config in pairs(cs.mappings) do
            sorted[#sorted + 1] = { project = project, config = config }
        end
        table.sort(sorted, function(a, b) return a.project.key < b.project.key end)
        for _, entry in ipairs(sorted) do
            local variant = entry.config.name
            if entry.config._removed then
                tree:leaf(entry.project.key .. " → " .. variant .. " (missing)", "DiagnosticWarn")
            else
                tree:leaf(entry.project.key .. " → " .. variant, "Comment")
            end
        end
    end)

    if #tool_entries > 0 then
        tree:group({{"Tools:  ", "LoomworksActionable"}, {"[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
            for _, entry in ipairs(tool_entries) do
                render_tool_entry(tree, cs, entry, active_profile)
            end
        end)
    else
        -- No keyed tools — render a single activatable entry for the set itself
        local profile = cs:find_profile(nil)
        render_no_tool_entry(tree, cs, profile, active_profile)
    end

end

--- Open the config set editor for an existing set.
--- @param cs loomworks.ConfigurationSet
local function edit_config_set(cs)
    local set_name = cs.name
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local workspace_view = require("loomworks.workspace_view")
    local ctx = workspace_view.compute_edit_config_set_context(ws, set_name)
    if not ctx then return end

    local old_mappings = {}
    for project, config in pairs(ctx.mappings) do
        old_mappings[project] = config
    end

    require("loomworks.ui.config_set_editor").open({
        title = "Edit configuration set",
        name = set_name,
        projects = ctx.projects,
        mappings = ctx.mappings,
        available_configs = ctx.available_configs,
        validate = function(result)
            if result.name ~= set_name then
                for _, existing_cs in pairs(ws._config_sets) do
                    if existing_cs.name == result.name then
                        return false, "configuration set '" .. result.name .. "' already exists"
                    end
                end
            end
            return true
        end,
        on_accept = function(result)
            local new_name = result.name
            local ok, err = workspace_view.execute_edit_config_set(
                cs, new_name, result.mappings, old_mappings)
            if not ok then
                vim.notify("loomworks: " .. (err or "failed to edit config set"),
                    vim.log.levels.ERROR)
            elseif new_name ~= set_name then
                vim.notify("loomworks: configuration set renamed to '" .. new_name .. "'",
                    vim.log.levels.INFO)
            end
        end,
        on_cancel = function() end,
    })
end

--- Show confirmation and delete a config set.
--- @param cs loomworks.ConfigurationSet
local function delete_config_set(cs)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local workspace_view = require("loomworks.workspace_view")
    local ctx = workspace_view.compute_delete_config_set_context(ws, cs)
    if not ctx then return end

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = ctx.lines,
        highlights = ctx.highlights,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                local ok, err = workspace_view.execute_delete_config_set(ws, cs)
                if ok then
                    vim.notify("loomworks: configuration set '" .. cs.name .. "' removed",
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to delete config set"),
                        vim.log.levels.ERROR)
                end
            end,
        },
    })
end

--- Create a new config set via the editor dialog.
local function create_config_set()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local workspace_view = require("loomworks.workspace_view")
    local ctx = workspace_view.compute_create_config_set_context(ws)

    require("loomworks.ui.config_set_editor").open({
        title = "New configuration set",
        name = "",
        projects = ctx.projects,
        mappings = ctx.mappings,
        available_configs = ctx.available_configs,
        validate = function(result)
            for _, existing_cs in pairs(ws._config_sets) do
                if existing_cs.name == result.name then
                    return false, "configuration set '" .. result.name .. "' already exists"
                end
            end
            return true
        end,
        on_accept = function(result)
            local name = result.name
            local cs_new, err = workspace_view.execute_create_config_set(ws, name, result.mappings)
            if cs_new then
                vim.notify("loomworks: configuration set '" .. name .. "' created",
                    vim.log.levels.INFO)
            else
                vim.notify("loomworks: " .. (err or "failed to create config set"),
                    vim.log.levels.ERROR)
            end
        end,
        on_cancel = function() end,
    })
end

--- Render the configuration sets section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile, config_sets, tool_entries }
return function(tree, ctx)
    local config_sets = ctx.config_sets
    local has_sets = config_sets and next(config_sets)

    -- Show section only when there are sets or projects (to offer create)
    if not has_sets then return end

    local all_profiles = ctx.all_profiles
    local active_profile = ctx.active_profile
    local tool_entries = ctx.tool_entries or {}
    local lw = ctx.lw

    tree:leaf("Configuration Sets", "Title")
    tree:blank()

    local sorted = {}
    for _, cs in pairs(config_sets) do
        sorted[#sorted + 1] = cs
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)

    local ws = lw.get_workspace()

    for _, cs in ipairs(sorted) do
        local is_active_set = active_profile
                and active_profile._config_set_ref == cs
        local cs_dimmed = not cs._in_user_json
        local set_hl = is_active_set and "LoomworksActive"
                or cs_dimmed and "Comment"
                or "LoomworksActionable"
        local sname = cs.name
        local cs_modified = ws and ws:is_config_set_modified(cs) and "+" or ""

        tree:node(cs_modified .. cs.name, {
            fold_key = "set:" .. cs.name,
            hl = set_hl,
            enter_label = "Edit mappings",
            on_enter = function() edit_config_set(cs) end,
            on_create = function()
                local all_tool_entries = lw.get_tool_entries()
                local is_first = not next(all_profiles)
                actions._create_profile_step2(cs, sname, all_tool_entries, is_first)
            end,
            on_delete = function() delete_config_set(cs) end,
        }, function()
            render_set_details(tree, cs,
                tool_entries[cs.name] or {}, active_profile, lw)
        end)
    end

    tree:item("▸ Create configuration set", {
        hl = "LoomworksActionable",
        direct = true,
        on_enter = create_config_set,
    })

    tree:blank()
end
