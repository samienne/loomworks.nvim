--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param row table the set's view row (`mappings`: one entry per mapped project, by project key)
local function render_set_details(tree, row)
    tree:group("Projects:", "LoomworksSection", function()
        for _, entry in ipairs(row.mappings or {}) do
            local project, variant = entry.project.key, entry.configuration.key
            -- A mapping to a removed or source-less configuration.
            if entry.missing then
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

--- A configuration as the set dialog offers or maps it: a view entry that
--- names it — a project row's `configurations[]` / `presets[]` row, or a set
--- row's mapping `configuration` (`{ id?, key }`, kept for a configuration
--- the view lists no row of, a source-missing one) — shown by `name`. A
--- model call sends it by its id (daemon) or bound object (in-process),
--- never by name (ui/model_calls.lua).
--- @param ref table the view entry
--- @param name string
--- @return loomworks.ConfigSetChoice
local function config_choice(ref, name)
    local ss = require("loomworks.status_source")
    local choice = { name = name, id = ref.id }
    local obj = ss.object_of(ref)
    if obj then ss.bind(choice, obj) end
    return choice
end

--- The set dialog's projects and the configurations each offers, from the
--- workspace view's project rows (6b-alpha: no editor-model read): a row's
--- `configurations[]` and its cmake presets (`presets[]`, canonical
--- `preset:<name>` configurations the view lists apart).
--- @param view table|nil the workspace view
--- @return table[]|nil projects, table<table, loomworks.ConfigSetChoice[]>|nil available_configs
local function dialog_projects(view)
    if not view then return nil end
    local projects, available = {}, {}
    for _, p in ipairs(view.projects or {}) do
        projects[#projects + 1] = p
        local configs, seen = {}, {}
        local function offer(ref, name)
            if name ~= nil and not seen[name] then
                seen[name] = true
                configs[#configs + 1] = config_choice(ref, name)
            end
        end
        for _, c in ipairs(p.configurations or {}) do offer(c, c.key) end
        for _, pr in ipairs(p.presets or {}) do offer(pr, pr.name) end
        table.sort(configs, function(a, b) return a.name < b.name end)
        available[p] = configs
    end
    return projects, available
end

--- The notice of a set dialog opened while no workspace view is held (in
--- `daemon` mode the editor holds no model to fall back on).
local function no_view()
    vim.notify("loomworks: the workspace view is not available yet; try again when the status page shows it",
        vim.log.levels.WARN)
end

--- Open the config set editor for an existing set: its projects and
--- configurations are the view's rows, its mappings the set row's entries,
--- joined to the rows of the same view by entity (helpers.same_entity: the
--- id in `daemon` mode, the bound object in-process); the update names the
--- set by its row.
--- @param ctx table the page context
--- @param row table the set's view row
local function edit_config_set(ctx, row)
    local set_name = row.name
    local ws = ctx.ws

    local projects, available_configs = dialog_projects(ctx.view)
    if not projects then return no_view() end
    local mappings = {}
    for _, entry in ipairs(row.mappings or {}) do
        for _, p in ipairs(projects) do
            if helpers.same_entity(entry.project, p) then
                for _, c in ipairs(available_configs[p]) do
                    if helpers.same_entity(entry.configuration, c) then mappings[p] = c; break end
                end
                -- A configuration the view lists no row of (source-missing):
                -- kept by the entry's own reference.
                mappings[p] = mappings[p] or config_choice(entry.configuration, entry.configuration.key)
                break
            end
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
        if helpers.same_entity(helpers.profile_set(p), row) then affected[#affected + 1] = p.key end
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

--- Add a configuration set and report it: `params` the dialog's `{ name,
--- mappings }` (project row → configuration choice) or `{ candidate }` (a
--- `ConfigSets/1.candidates` entry, an automatic set).
--- @param ws loomworks.Workspace|nil
--- @param name string
--- @param params table
local function add_config_set(ws, name, params)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "ConfigSets/1.add", params, function(r)
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
    if not projects then return no_view() end

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
        on_accept = function(result)
            add_config_set(ws, result.name, { name = result.name, mappings = result.mappings })
        end,
        on_cancel = function() end,
    })
end

--- Create a new config set: offer the automatic sets
--- `ConfigSets/1.candidates` lists (each with its mappings), then the custom
--- option. A template's pick is `ConfigSets/1.add { candidate }`
--- (spec/ui.md §1.7).
--- @param ctx table the page context
local function create_config_set(ctx)
    if not ctx.view then return no_view() end
    local ws = ctx.ws
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "ConfigSets/1.candidates", {}, function(r)
        if r.outcome ~= "ok" then return report(r, "failed to list the configuration sets") end
        local choices = {}
        for _, set in ipairs(r.sets or {}) do
            if set.auto then
                local parts = {}
                for _, m in ipairs(set.mappings or {}) do
                    parts[#parts + 1] = m.project.key .. " → " .. m.configuration.key
                end
                choices[#choices + 1] = { label = set.name .. " (" .. table.concat(parts, ", ") .. ")", set = set }
            end
        end
        if #choices == 0 then
            -- Only the custom option remains — go straight to the editor.
            return create_custom_config_set(ctx)
        end
        table.sort(choices, function(a, b) return a.label < b.label end)
        local custom = { label = "Custom..." }
        choices[#choices + 1] = custom
        vim.ui.select(choices, { prompt = "Create configuration set:",
            format_item = function(c) return c.label end }, function(choice)
            if not choice then return end
            if choice == custom then
                create_custom_config_set(ctx)
            else
                add_config_set(ws, choice.set.name, { candidate = choice.set })
            end
        end)
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
--- @param ctx table { lw, view, mode, ws, ... }
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
