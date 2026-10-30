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

--- Notify a refused outcome `r` (`what`: the fallback text).
local function report(r, what)
    local _, err = require("loomworks.ui.model_calls").result(r)
    vim.notify("loomworks: " .. tostring(err or what), vim.log.levels.ERROR)
end

--- Whether `name` names a set of the view other than `except` (a row).
--- @param view table the workspace view
--- @param name string
--- @param except? table
--- @return boolean
local function taken(view, name, except)
    for _, other in ipairs(view.config_sets or {}) do
        if other ~= except and other.name == name then return true end
    end
    return false
end

--- A configuration as the set dialog offers it: its name, and its row
--- (`_row`: what a model call sends — its id in `daemon` mode, the bound
--- object in-process). A mapping to a configuration the view does not list
--- (a removed or source-less one) has no row: the call refuses it by name.
--- @param name string
--- @param row? table the configuration's row (`projects[].configurations[]`)
--- @return { name: string, _row?: table }
local function config_choice(name, row)
    return { name = name, _row = row }
end

--- The set dialog's projects and the configurations each offers, from the
--- workspace view's project rows (6b-alpha: no editor-model read).
--- @param view table the workspace view
--- @return table[] projects, table<table, table[]> available_configs
local function dialog_projects(view)
    local projects, available = {}, {}
    for _, p in ipairs(view.projects or {}) do
        projects[#projects + 1] = p
        local configs = {}
        for _, c in ipairs(p.configurations or {}) do configs[#configs + 1] = config_choice(c.key, c) end
        available[p] = configs
    end
    return projects, available
end

--- Open the config set editor for an existing set: its projects and
--- configurations are the view's rows, its mappings the set row's (project
--- key -> configuration name, the view's own form, joined to the rows of
--- the same view); the update names the set by its row.
--- @param ctx table the page context
--- @param row table the set's view row
local function edit_config_set(ctx, row)
    local set_name = row.name
    local ws = ctx.ws

    local projects, available_configs = dialog_projects(ctx.view)
    local mappings = {}
    for _, p in ipairs(projects) do
        local name = (row.mappings or {})[p.key]
        if name ~= nil then
            for _, c in ipairs(available_configs[p]) do
                if c.name == name then mappings[p] = c; break end
            end
            mappings[p] = mappings[p] or config_choice(name)
        end
    end

    require("loomworks.ui.config_set_editor").open({
        title = "Edit configuration set",
        item = helpers.row_item("configuration set", row),
        name = set_name,
        projects = projects,
        mappings = mappings,
        available_configs = available_configs,
        validate = function(result)
            if result.name ~= set_name and taken(ctx.view, result.name, row) then
                return false, "configuration set '" .. result.name .. "' already exists"
            end
            return true
        end,
        on_accept = function(result)
            local new_name = result.name
            local model = require("loomworks.ui.model_calls")
            model.call(ws, "ConfigSets/1.update", { config_set = row, name = new_name, mappings = result.mappings },
                function(r)
                    local ok = model.result(r)
                    if not ok then
                        report(r, "failed to edit config set")
                    elseif new_name ~= set_name then
                        vim.notify("loomworks: configuration set renamed to '" .. new_name .. "'",
                            vim.log.levels.INFO)
                    end
                end)
        end,
        on_cancel = function() end,
    })
end

--- The confirmation of a set's deletion, from the view: the profiles made of
--- it (they stay, with a missing set) and its cached configurations.
--- @param view table the workspace view
--- @param row table the set's view row
--- @return string[] lines, table[] highlights
local function delete_lines(view, row)
    local affected = {}
    for _, p in ipairs(view.profiles or {}) do
        if p.config_set == row.name then affected[#affected + 1] = p.key end
    end
    table.sort(affected)
    local lines = { "  Delete configuration set: " .. row.name }
    local highlights = { { line = 1, hl_group = "DiagnosticWarn" } }
    -- The set's description summary (spec/ui.md §1.16).
    local summary = helpers.picker_summary(row.description, 70)
    if summary ~= "" then
        lines[#lines + 1] = "  " .. summary
        highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    end
    lines[#lines + 1] = ""
    if #affected > 0 then
        lines[#lines + 1] = "  Profiles that will become orphaned:"
        highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        for _, key in ipairs(affected) do
            lines[#lines + 1] = "    " .. key
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "  Cached configs will become orphaned."
    highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    lines[#lines + 1] = "  Use 'Clean orphaned configs' to remove them later."
    highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Press y to confirm, q to cancel"
    return lines, highlights
end

--- Show confirmation and delete a config set.
--- @param ctx table the page context
--- @param row table the set's view row
local function delete_config_set(ctx, row)
    local lines, highlights = delete_lines(ctx.view, row)
    require("loomworks.ui.dialog").show({
        title = "Confirm Delete",
        lines = lines,
        highlights = highlights,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                local model = require("loomworks.ui.model_calls")
                model.call(ctx.ws, "ConfigSets/1.remove", { config_set = row }, function(r)
                    if model.result(r) then
                        vim.notify("loomworks: configuration set '" .. row.name .. "' removed",
                            vim.log.levels.INFO)
                    else
                        report(r, "failed to delete config set")
                    end
                end)
            end,
        },
    })
end

--- Add a configuration set (`name`, `mappings`) and report it.
--- @param ws loomworks.Workspace|nil
--- @param name string
--- @param mappings table the dialog's project row → configuration choice, or a template's project key → configuration name
local function add_config_set(ws, name, mappings)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "ConfigSets/1.add", { name = name, mappings = mappings }, function(r)
        if r.config_set then
            vim.notify("loomworks: configuration set '" .. name .. "' created", vim.log.levels.INFO)
        else
            report(r, "failed to create config set")
        end
    end)
end

--- Create a config set via the manual editor dialog (the view's projects
--- and their configurations, nothing mapped).
--- @param ctx table the page context
local function create_custom_config_set(ctx)
    local ws = ctx.ws
    local projects, available_configs = dialog_projects(ctx.view)

    require("loomworks.ui.config_set_editor").open({
        title = "New configuration set",
        name = "",
        projects = projects,
        mappings = {},
        available_configs = available_configs,
        validate = function(result)
            if taken(ctx.view, result.name) then
                return false, "configuration set '" .. result.name .. "' already exists"
            end
            return true
        end,
        on_accept = function(result) add_config_set(ws, result.name, result.mappings) end,
        on_cancel = function() end,
    })
end

--- Create a new config set: offer templates then custom option. *(Transition.)*
--- The templates are the sets the editor's model's projects suggest (project
--- key → configuration name, as generated): `ConfigSets/1.candidates` names
--- the automatic sets but carries no mappings, and `ConfigSets/1.add` takes
--- no candidate token, so the daemon cannot serve this read yet.
--- @param ctx table the page context
local function create_config_set(ctx)
    local ws = ctx.ws
    if not ws then return end

    local auto_sets = ws:generate_default_config_sets()
    local choices = {}
    local template_data = {}

    if auto_sets then
        for name, mappings in pairs(auto_sets) do
            if not taken(ctx.view, name) then
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

    local custom_label = "Custom..."
    choices[#choices + 1] = custom_label

    if #choices == 1 then
        -- Only the custom option remains — go straight to the editor.
        create_custom_config_set(ctx)
        return
    end

    vim.ui.select(choices, { prompt = "Create configuration set:" }, function(choice)
        if not choice then return end
        if choice == custom_label then
            create_custom_config_set(ctx)
        else
            local data = template_data[choice]
            if data then add_config_set(ws, data.name, data.mappings) end
        end
    end)
end

--- The actions of a configuration set row (its model writes name the set by
--- the row, step 5o C2a).
--- @param ctx table the page context
--- @param row table the set's view row
--- @return table
local function set_actions(ctx, row)
    return helpers.describe_action({
        on_enter = function() edit_config_set(ctx, row) end,
        on_publish = function() helpers.cycle_intent(row, ctx.ws) end,
        on_publish_now = function() helpers.publish_one(row, ctx.ws) end,
        on_revert_one = function() helpers.revert_one(row, ctx.ws) end,
        on_create = function()
            actions._create_profile_step2(ctx.ws, row, #(ctx.view.profiles or {}) == 0)
        end,
        on_delete = function() delete_config_set(ctx, row) end,
    }, helpers.row_item("configuration set", row))
end

--- Render the configuration sets section (from the workspace view's
--- `config_sets`; the actions name the set by its row).
--- @param tree loomworks.Tree
--- @param ctx table { lw, view, mode, ws, all_profiles, ... }
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
        for k, v in pairs(set_actions(ctx, row)) do opts[k] = v end

        t:node((row.modified and "+" or "") .. row.name, opts, function()
            t:description(row.description)
            render_set_details(t, row)
        end)
    end)

    tree:item("▸ Create configuration set", {
        hl = "LoomworksAdd",
        direct = true,
        on_enter = function() create_config_set(ctx) end,
    })

    tree:blank()
end
