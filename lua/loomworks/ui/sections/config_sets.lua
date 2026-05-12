--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param cs loomworks.ConfigurationSet
--- @param tool_entries loomworks.ToolEntry[] (unused — kept in the
---        signature so callers that still pass it don't break;
---        profile creation now goes through the `Create profile from
---        set` action on the set node directly)
--- @param active_profile loomworks.Profile|nil (unused — see above)
--- @param lw table loomworks API (unused)
local function render_set_details(tree, cs, tool_entries, active_profile, lw)
    tree:group("Projects:", "LoomworksSection", function()
        local sorted = {}
        for project, config in pairs(cs.mappings) do
            sorted[#sorted + 1] = { project = project, config = config }
        end
        table.sort(sorted, function(a, b) return a.project.key < b.project.key end)
        for _, entry in ipairs(sorted) do
            local variant = entry.config.name
            local cfg = entry.config
            -- Orphan states, strongest first:
            --   _removed        → underlying object was torn down
            --   _source_missing → stub reference that no source backs
            local is_orphan = cfg._removed or cfg._source_missing
            if is_orphan then
                tree:leaf({
                    { entry.project.key, "LoomworksProject" },
                    { " → " .. variant .. " ⚠ missing", "WarningMsg" },
                })
            else
                tree:leaf({
                    { entry.project.key, "LoomworksProject" },
                    { " → ", "Comment" },
                    { variant, "LoomworksVariant" },
                })
            end
        end
    end)

    -- Trailing blank line gives unfolded config sets breathing room
    -- before the next set or the `▸ Create configuration set` sentinel.
    tree:blank()
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

--- Create a config set from a template (auto-detected mappings).
--- Template mappings are already raw {project_key → variant_name} strings
--- so we call add_configuration_set directly (not execute_create_config_set
--- which expects domain objects).
--- @param ws loomworks.Workspace
--- @param name string set name
--- @param mappings table<string, string> project_key → variant
local function create_from_template(ws, name, mappings)
    local cs_new, err = ws:add_configuration_set(name, mappings)
    if cs_new then
        vim.notify("loomworks: configuration set '" .. name .. "' created",
            vim.log.levels.INFO)
    else
        vim.notify("loomworks: " .. (err or "failed to create config set"),
            vim.log.levels.ERROR)
    end
end

--- Create a config set via the manual editor dialog.
--- @param ws loomworks.Workspace
local function create_custom_config_set(ws)
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

--- Create a new config set: offer templates then custom option.
local function create_config_set()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    -- Collect existing set names for filtering
    local existing_names = {}
    for _, cs in pairs(ws._config_sets) do
        existing_names[cs.name] = true
    end

    -- Generate auto-detected templates
    local auto_sets = ws:generate_default_config_sets()
    local choices = {}
    local template_data = {}

    if auto_sets then
        for name, mappings in pairs(auto_sets) do
            if not existing_names[name] then
                -- Build description from mappings
                local parts = {}
                local keys = {}
                for k in pairs(mappings) do keys[#keys + 1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    parts[#parts + 1] = k .. " → " .. mappings[k]
                end
                local desc = table.concat(parts, ", ")
                choices[#choices + 1] = name .. " (" .. desc .. ")"
                template_data[choices[#choices]] = { name = name, mappings = mappings }
            end
        end
        table.sort(choices)
    end

    -- Always offer custom option
    local custom_label = "Custom..."
    choices[#choices + 1] = custom_label

    if #choices == 1 then
        -- Only custom option — go straight to editor
        create_custom_config_set(ws)
        return
    end

    vim.ui.select(choices, { prompt = "Create configuration set:" }, function(choice)
        if not choice then return end
        if choice == custom_label then
            create_custom_config_set(ws)
        else
            local data = template_data[choice]
            if data then
                create_from_template(ws, data.name, data.mappings)
            end
        end
    end)
end

--- Render the configuration sets section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile, config_sets, tool_entries }
return function(tree, ctx)
    local config_sets = ctx.config_sets
    local has_sets = config_sets and next(config_sets)

    -- Show section when sets exist OR when projects exist (to offer create)
    local lw_for_check = ctx.lw
    local has_projects = false
    local projects = lw_for_check.get_projects()
    if projects then
        for _ in pairs(projects) do has_projects = true; break end
    end
    if not has_sets and not has_projects then return end

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

    helpers.render_grouped(tree, sorted, function(t, cs, group)
        local is_active_set = active_profile
                and active_profile._config_set_ref == cs
        local is_shared_only = group == "shared"
        local set_hl = is_active_set and "LoomworksActive"
                or is_shared_only and "Comment"
                or "LoomworksActionable"
        local sname = cs.name
        local cs_modified = ws and ws:is_config_set_modified(cs) and "+" or ""

        t:node(cs_modified .. cs.name, {
            fold_key = "set:" .. cs.name,
            hl = set_hl,
            enter_label = "Edit mappings",
            on_enter = function() edit_config_set(cs) end,
            publish_label = helpers.intent_action_label(cs),
            on_publish = function()
                helpers.cycle_intent(cs)
                if ws then
                    ws:_save_user()
                    ws._core._deps.events.emit("active_set_changed", ws._active_set)
                end
            end,
            on_publish_now = function()
                if not ws then return end
                local ok, err = ws:publish_one(cs)
                if not ok then
                    vim.notify("loomworks: publish failed: " ..
                        (err or "unknown"), vim.log.levels.ERROR)
                end
            end,
            on_revert_one = function()
                if not ws then return end
                local ok, err = ws:revert_one(cs)
                if not ok then
                    vim.notify("loomworks: revert failed: " ..
                        (err or "unknown"), vim.log.levels.ERROR)
                end
            end,
            on_create = function()
                local all_tool_entries = lw.get_tool_entries()
                local is_first = not next(all_profiles)
                actions._create_profile_step2(cs, sname, all_tool_entries, is_first)
            end,
            on_delete = function() delete_config_set(cs) end,
        }, function()
            render_set_details(t, cs,
                tool_entries[cs.name] or {}, active_profile, lw)
        end)
    end)

    tree:item("▸ Create configuration set", {
        hl = "LoomworksAdd",
        direct = true,
        on_enter = create_config_set,
    })

    tree:blank()
end
