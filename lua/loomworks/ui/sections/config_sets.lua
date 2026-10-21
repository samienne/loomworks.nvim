--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param row table the set's view row (`mappings`: project -> configuration)
local function render_set_details(tree, row)
    tree:group("Projects:", "LoomworksSection", function()
        local projects = {}
        for project in pairs(row.mappings) do projects[#projects + 1] = project end
        table.sort(projects)
        for _, project in ipairs(projects) do
            local variant = row.mappings[project]
            -- A mapping to a removed or source-less configuration.
            if row.missing[project] then
                tree:leaf({
                    { project, "LoomworksProject" },
                    { " → " .. variant .. " ⚠ missing", "WarningMsg" },
                })
            else
                tree:leaf({
                    { project, "LoomworksProject" },
                    { " → ", "Comment" },
                    { variant, "LoomworksVariant" },
                })
            end
        end
    end)

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

    require("loomworks.ui.config_set_editor").open({
        title = "Edit configuration set",
        item = cs,
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
            local model = require("loomworks.ui.model_calls")
            model.call(ws, "ConfigSets/1.update", { config_set = cs, name = new_name, mappings = result.mappings },
                function(r)
                    local ok, err = model.result(r)
                    if not ok then
                        vim.notify("loomworks: " .. (err or "failed to edit config set"),
                            vim.log.levels.ERROR)
                    elseif new_name ~= set_name then
                        vim.notify("loomworks: configuration set renamed to '" .. new_name .. "'",
                            vim.log.levels.INFO)
                    end
                end)
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
                local model = require("loomworks.ui.model_calls")
                model.call(ws, "ConfigSets/1.remove", { config_set = cs }, function(r)
                    local ok, err = model.result(r)
                    if ok then
                        vim.notify("loomworks: configuration set '" .. cs.name .. "' removed",
                            vim.log.levels.INFO)
                    else
                        vim.notify("loomworks: " .. (err or "failed to delete config set"),
                            vim.log.levels.ERROR)
                    end
                end)
            end,
        },
    })
end

--- Create a config set from a template (an auto-detected set, named by its
--- candidate token).
--- @param ws loomworks.Workspace
--- @param name string set name
--- @param candidate string the template's candidate token
local function create_from_template(ws, name, candidate)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "ConfigSets/1.add", { candidate = candidate }, function(r)
        if r.config_set then
            vim.notify("loomworks: configuration set '" .. name .. "' created",
                vim.log.levels.INFO)
        else
            local _, err = model.result(r)
            vim.notify("loomworks: " .. (err or "failed to create config set"),
                vim.log.levels.ERROR)
        end
    end)
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
            local model = require("loomworks.ui.model_calls")
            model.call(ws, "ConfigSets/1.add", { name = name, mappings = result.mappings }, function(r)
                if r.config_set then
                    vim.notify("loomworks: configuration set '" .. name .. "' created",
                        vim.log.levels.INFO)
                else
                    local _, err = model.result(r)
                    vim.notify("loomworks: " .. (err or "failed to create config set"),
                        vim.log.levels.ERROR)
                end
            end)
        end,
        on_cancel = function() end,
    })
end

--- Create a new config set: offer templates then custom option.
local function create_config_set()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local existing_names = {}
    for _, cs in pairs(ws._config_sets) do
        existing_names[cs.name] = true
    end

    local auto_sets = ws:generate_default_config_sets()
    local choices = {}
    local template_data = {}

    if auto_sets then
        for name, mappings in pairs(auto_sets) do
            if not existing_names[name] then
                local parts = {}
                local keys = {}
                for k in pairs(mappings) do keys[#keys + 1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    parts[#parts + 1] = k .. " → " .. mappings[k]
                end
                local desc = table.concat(parts, ", ")
                choices[#choices + 1] = name .. " (" .. desc .. ")"
                template_data[choices[#choices]] = { name = name,
                    candidate = require("loomworks.workspace_view").candidate_token(name, mappings) }
            end
        end
        table.sort(choices)
    end

    local custom_label = "Custom..."
    choices[#choices + 1] = custom_label

    if #choices == 1 then
        -- Only the custom option remains — go straight to the editor.
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
                create_from_template(ws, data.name, data.candidate)
            end
        end
    end)
end

--- The actions of a configuration set row.
--- @param ctx table the page context
--- @param cs loomworks.ConfigurationSet|nil the row's object (nil: none)
--- @return table
local function set_actions(ctx, cs)
    if not cs then return {} end
    local ws, lw, all_profiles = ctx.ws, ctx.lw, ctx.all_profiles
    local sname = cs.name
    return helpers.describe_action({
        on_enter = function() edit_config_set(cs) end,
        on_publish = function() helpers.cycle_intent(cs) end,
        on_publish_now = function() helpers.publish_one(cs) end,
        on_revert_one = function() helpers.revert_one(cs) end,
        on_create = function()
            local all_tool_entries = lw.get_tool_entries()
            local is_first = not next(all_profiles)
            actions._create_profile_step2(cs, sname, all_tool_entries, is_first)
        end,
        on_delete = function() delete_config_set(cs) end,
    }, cs)
end

--- Render the configuration sets section (from the workspace view's
--- `config_sets`; the actions reach the set through `ctx.ref(row)`).
--- @param tree loomworks.Tree
--- @param ctx table { lw, view, ref, ws, all_profiles, ... }
return function(tree, ctx)
    local view = ctx.view
    -- Show the section when sets exist, or when projects exist so create is offered.
    if #view.config_sets == 0 and #view.projects == 0 then return end

    tree:leaf("Configuration Sets", "Title")
    tree:blank()

    helpers.render_grouped(tree, view.config_sets, function(t, row, group)
        local is_shared_only = group == "shared"
        local set_hl = row.active and "LoomworksActive"
                or is_shared_only and "Comment"
                or "LoomworksActionable"
        local opts = helpers.describe({
            fold_key = "set:" .. row.name,
            hl = set_hl,
            enter_label = "Edit mappings",
            publish_label = helpers.intent_action_label(row.intent),
        }, row.description)
        for k, v in pairs(set_actions(ctx, ctx.ref(row))) do opts[k] = v end

        t:node((row.modified and "+" or "") .. row.name, opts, function()
            t:description(row.description)
            render_set_details(t, row)
        end)
    end)

    tree:item("▸ Create configuration set", {
        hl = "LoomworksAdd",
        direct = true,
        on_enter = create_config_set,
    })

    tree:blank()
end
