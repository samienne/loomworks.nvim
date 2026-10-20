--- loomworks/ui/sections/projects.lua — Projects section renderer.
---
--- Renders from the workspace view's `projects` rows
--- (`loomworks.view.Workspace/1`, spec §19.13 "The workspace view"): the
--- project's configurations, presets, launches, deploy steps, variables and
--- editable type_config fields. The actions (editors, dialogs, mutations)
--- are kept apart and reach the domain objects only through `ctx.ref(row)`
--- (in-process) and the workspace `ctx.ws`.

local helpers = require("loomworks.ui.helpers")
local workspace_view = require("loomworks.workspace_view")

-- ---------------------------------------------------------------------------
-- Actions (editors, dialogs, mutations)
-- ---------------------------------------------------------------------------

--- Open the launch editor for an existing or new launch config.
--- @param project loomworks.Project
--- @param launch? loomworks.LaunchConfiguration nil for new config
local function edit_launch_config(project, launch)
    local project_key = project.key
    local launch_name = launch and launch.name or nil

    local ctx = workspace_view.compute_edit_launch_context(project, launch)

    local lw = require("loomworks")
    local ws = lw.get_workspace()

    require("loomworks.ui.launch_editor").open({
        title = launch_name
            and ('Edit "' .. launch_name .. '" — ' .. project_key)
            or ("New launch — " .. project_key),
        name = ctx.name,
        command = ctx.command,
        args = ctx.args,
        working_dir = ctx.working_dir,
        env = ctx.env,
        deploy = ctx.deploy,
        debug = ctx.debug,
        projects = ws and ws:get_projects() or {},
        profile = ws and lw.get_active_profile() or nil,
        workspace = ws,
        launch_project = project,
        original_name = launch_name,
        validate = function(result)
            if result.name ~= (launch_name or "") then
                if project:find_launch(result.name) then
                    return false, "launch config '" .. result.name .. "' already exists"
                end
                -- A new name must be valid (spec §8.7).
                local vok, verr = require("loomworks.project").validate_launch_name(result.name)
                if not vok then return false, verr end
            end
            return true
        end,
        on_accept = function(result)
            local ok, err = workspace_view.execute_save_launch_config(
                project, launch, result.name, {
                    command = result.command,
                    args = result.args,
                    working_dir = result.working_dir,
                    env = result.env,
                    deploy = result.deploy,
                    debug = result.debug,
                })
            if ok then
                local verb = launch_name and "updated" or "created"
                vim.notify("loomworks: launch config '" .. result.name .. "' " .. verb,
                    vim.log.levels.INFO)
            else
                vim.notify("loomworks: " .. (err or "failed to save launch config"),
                    vim.log.levels.ERROR)
            end
        end,
        on_cancel = function() end,
    })
end

--- Delete a launch config with confirmation.
--- @param project loomworks.Project
--- @param launch loomworks.LaunchConfiguration
local function delete_launch_config(project, launch)
    local project_key = project.key
    local launch_name = launch.name

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = {
            "  Delete launch config: " .. launch_name,
            "",
            "  Project: " .. project_key,
            "",
            "  Press y to confirm, q to cancel",
        },
        highlights = {
            { line = 1, hl_group = "DiagnosticWarn" },
            { line = 3, hl_group = "Comment" },
        },
        keys = {
            n = "close",
            y = function(self)
                self:close()
                local ok, err = workspace_view.execute_delete_launch_config(project, launch)
                if ok then
                    vim.notify("loomworks: launch config '" .. launch_name .. "' deleted",
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to delete"),
                        vim.log.levels.ERROR)
                end
            end,
        },
    })
end

--- Open the variable editor for an existing or new variable.
--- @param project loomworks.Project
--- @param var_name? string nil for new variable
local function edit_variable(project, var_name)
    local ctx = workspace_view.compute_edit_variable_context(project, var_name)

    require("loomworks.ui.variable_editor").open({
        title = var_name
            and ('Edit "' .. var_name .. '" — ' .. project.key)
            or ("New variable — " .. project.key),
        name = ctx.name,
        type = ctx.type,
        default = ctx.default,
        validate = function(result)
            if result.name ~= (var_name or "")
                    and project.variables
                    and project.variables[result.name] then
                return false, "variable '" .. result.name .. "' already exists"
            end
            local vars_mod = require("loomworks.variables")
            if vars_mod.RESERVED_NAMES[result.name] then
                return false, "'" .. result.name .. "' is a reserved name"
            end
            return true
        end,
        on_accept = function(result)
            local ok, err = workspace_view.execute_save_variable(
                project, var_name, result.name, {
                    type = result.type,
                    default = result.default,
                })
            if ok then
                local verb = var_name and "updated" or "created"
                vim.notify("loomworks: variable '" .. result.name .. "' " .. verb,
                    vim.log.levels.INFO)
            else
                vim.notify("loomworks: " .. (err or "failed to save variable"),
                    vim.log.levels.ERROR)
            end
        end,
        on_cancel = function() end,
    })
end

--- Delete a project variable with confirmation.
--- @param project loomworks.Project
--- @param var_name string
local function delete_variable(project, var_name)
    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = {
            "  Delete variable: " .. var_name,
            "",
            "  Project: " .. project.key,
            "  Config overrides for this variable will also be removed.",
            "",
            "  Press y to confirm, q to cancel",
        },
        highlights = {
            { line = 1, hl_group = "DiagnosticWarn" },
            { line = 3, hl_group = "Comment" },
            { line = 4, hl_group = "Comment" },
        },
        keys = {
            n = "close",
            y = function(self)
                self:close()
                local ok, err = workspace_view.execute_delete_variable(project, var_name)
                if ok then
                    vim.notify("loomworks: variable '" .. var_name .. "' deleted",
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to delete"),
                        vim.log.levels.ERROR)
                end
            end,
        },
    })
end

--- Open the configuration editor for a project configuration.
--- @param project loomworks.Project
--- @param cfg? loomworks.Configuration nil for new configuration
local function edit_project_configuration(project, cfg)
    local project_key = project.key
    local config_name = cfg and cfg.name or nil
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local ctx = workspace_view.compute_edit_configuration_context(project, config_name)
    if not ctx then return end

    require("loomworks.ui.config_editor_dialog").open({
        item = cfg,
        title = config_name
            and ('Edit "' .. config_name .. '" — ' .. project_key)
            or ("New configuration — " .. project_key),
        name = ctx.name,
        variant = ctx.variant,
        inherits = ctx.inherits,
        options = ctx.options,
        variables = ctx.variables,
        toolchain = ctx.toolchain,
        generator = ctx.generator,
        languages = ctx.languages,
        module_languages = ctx.module_languages,
        build_dir = ctx.build_dir,
        is_default = ctx.is_default and config_name ~= nil,
        has_options = ctx.has_options,
        available_configs = ctx.available_configs,
        project_options = ctx.project_options,
        inherited_options = ctx.inherited_options,
        project_variables = ctx.project_variables,
        resolved_variables = ctx.resolved_variables,
        rename_effects = config_name and function(new_name)
            if new_name == config_name or new_name == "" then return nil end
            local effects = {}
            for _, cs_obj in pairs(ws._config_sets) do
                if cs_obj.mappings then
                    for proj, config in pairs(cs_obj.mappings) do
                        if proj.key == project_key and config.name == config_name then
                            effects[#effects + 1] = "Config set '" .. cs_obj.name .. "' mapping → " .. new_name
                        end
                    end
                end
            end
            for _, cfg in ipairs(project:get_configurations()) do
                if cfg.name ~= config_name and cfg.inherits_names then
                    for _, base in ipairs(cfg.inherits_names) do
                        if base == config_name then
                            effects[#effects + 1] = "Config '" .. cfg.name .. "' inherits → " .. new_name
                            break
                        end
                    end
                end
            end
            return #effects > 0 and effects or nil
        end or nil,
        validate = function(result)
            if result.name ~= (config_name or "") then
                local existing = project:get_configuration(result.name)
                if existing and existing.is_user then
                    return false, "configuration '" .. result.name .. "' already exists"
                end
            end
            return true
        end,
        on_accept = function(result)
            -- The save changes only the fields the dialog edits; every other
            -- declared field (env, overrides, description, …) is kept.
            local ok, err = workspace_view.execute_save_configuration(
                project, cfg, result.name, result)
            if ok then
                local verb = config_name and "updated" or "created"
                vim.notify("loomworks: configuration '" .. result.name .. "' " .. verb,
                    vim.log.levels.INFO)
            else
                vim.notify("loomworks: " .. (err or "failed to save configuration"),
                    vim.log.levels.ERROR)
            end
        end,
        on_cancel = function() end,
    })
end

--- Delete a user-defined project configuration with confirmation.
--- @param project loomworks.Project
--- @param cfg loomworks.Configuration
local function delete_project_configuration(project, cfg)
    local project_key = project.key
    local config_name = cfg.name

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = {
            "  Delete configuration: " .. config_name,
            "",
            "  Project: " .. project_key,
            "  Cached configs for this configuration will become orphaned.",
            "",
            "  Press y to confirm, q to cancel",
        },
        highlights = {
            { line = 1, hl_group = "DiagnosticWarn" },
            { line = 3, hl_group = "Comment" },
            { line = 4, hl_group = "Comment" },
        },
        keys = {
            n = "close",
            y = function(self)
                self:close()
                local ok, err = workspace_view.execute_delete_configuration(project, cfg)
                if ok then
                    vim.notify("loomworks: configuration '" .. config_name .. "' deleted",
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to delete"),
                        vim.log.levels.ERROR)
                end
            end,
        },
    })
end

--- Open the project browser for adding a project.
local function open_add_project()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if ws then
        require("loomworks.ui.project_browser").open(ws.root)
    end
end


--- `opts` with the entries of `acts` added.
local function with(opts, acts)
    for k, v in pairs(acts or {}) do opts[k] = v end
    return opts
end

--- Save a type_config field of `project` (nil project: no action).
local function field_saver(project, name)
    if not project then return nil end
    return function(value)
        local ok, err = workspace_view.save_type_config_field(project, name, value)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "failed to save " .. name), vim.log.levels.ERROR)
        end
    end
end

--- The publish / revert actions shared by project and configuration rows.
--- @param ws loomworks.Workspace|nil
--- @param item table the Project or Configuration
local function publish_actions(ws, item)
    if not ws then return {} end
    return {
        on_publish = function() helpers.cycle_intent(item) end,
        on_publish_now = function() helpers.publish_one(item) end,
        on_revert_one = function() helpers.revert_one(item) end,
    }
end

--- The actions of a project row.
local function project_actions(ws, proj)
    if not proj then return {} end
    local key = proj.key
    return helpers.describe_action(with({
        on_delete = function()
            vim.ui.select({ "Yes", "No" }, {
                prompt = "Remove project '" .. key .. "'?",
            }, function(choice)
                if choice ~= "Yes" then return end
                if ws then
                    local ok, err = ws:remove_project(proj)
                    if ok then
                        vim.notify("loomworks: project '" .. key .. "' removed", vim.log.levels.INFO)
                        require("loomworks.ui.status").refresh()
                    else
                        vim.notify("loomworks: " .. (err or "failed to remove project"), vim.log.levels.ERROR)
                    end
                end
            end)
        end,
    }, publish_actions(ws, proj)), proj)
end

--- The actions of a configuration row.
--- @param ws loomworks.Workspace|nil
--- @param project loomworks.Project|nil
--- @param cfg loomworks.Configuration|nil
--- @param crow table the configuration's view row
local function configuration_actions(ws, project, cfg, crow)
    if not project then return {} end
    local acts = {
        on_enter = cfg and function() edit_project_configuration(project, cfg) end or nil,
        on_delete = (crow.user and cfg) and function() delete_project_configuration(project, cfg) end or nil,
    }
    if cfg then helpers.describe_action(with(acts, publish_actions(ws, cfg)), cfg) end
    return acts
end

--- The deploy dict of `project` as an editable deep copy, and its saver.
local function deploy_editing(project)
    local function get_editable_copy()
        return project.deploy and vim.deepcopy(project.deploy) or {}
    end
    local function save(new_deploy)
        local ok, err = workspace_view.save_deploy(project, new_deploy)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "failed to save deploy steps"), vim.log.levels.ERROR)
        end
    end
    return get_editable_copy, save
end

--- The actions of one deploy step (`dest`, source index `si`).
local function deploy_step_actions(lw, project, dest_keys, dest, si, src)
    if not project then return {} end
    local deploy_mod = require("loomworks.deploy")
    local get_editable_copy, save = deploy_editing(project)
    local captured_dest, captured_si = dest, si
    return {
        on_enter = function()
            require("loomworks.ui.deploy_editor").open({
                destination = captured_dest,
                source = vim.deepcopy(src),
                projects = lw.get_projects() or {},
                profile = lw.get_active_profile(),
                workspace = lw.get_workspace(),
                launch_project = project,
                -- A project-level step also runs for its build targets (§8.7),
                -- so ${target_dir} is offered; it also runs for command launches,
                -- where ${target_dir} is unresolved and fails that deploy.
                target_context = true,
                existing_destinations = dest_keys,
                current_destination = captured_dest,
                on_accept = function(new_dest, new_source)
                    local editable = get_editable_copy()
                    local cur = deploy_mod.normalize_sources(editable[captured_dest])
                    cur[captured_si] = new_source
                    if new_dest ~= captured_dest then
                        table.remove(cur, captured_si)
                        if #cur == 0 then
                            editable[captured_dest] = nil
                        elseif #cur == 1 then
                            editable[captured_dest] = cur[1]
                        else
                            editable[captured_dest] = cur
                        end
                        local existing = editable[new_dest]
                        if existing then
                            local arr = deploy_mod.normalize_sources(existing)
                            arr[#arr + 1] = new_source
                            editable[new_dest] = arr
                        else
                            editable[new_dest] = new_source
                        end
                    else
                        if #cur == 1 then
                            editable[captured_dest] = cur[1]
                        else
                            editable[captured_dest] = cur
                        end
                    end
                    save(editable)
                end,
                on_cancel = function() end,
            })
        end,
        on_delete = function()
            local editable = get_editable_copy()
            local cur = deploy_mod.normalize_sources(editable[captured_dest])
            table.remove(cur, captured_si)
            if #cur == 0 then
                editable[captured_dest] = nil
            elseif #cur == 1 then
                editable[captured_dest] = cur[1]
            else
                editable[captured_dest] = cur
            end
            save(editable)
        end,
    }
end

--- "▸ Add deploy step".
local function add_deploy_action(lw, project, dest_keys)
    if not project then return nil end
    local deploy_mod = require("loomworks.deploy")
    local get_editable_copy, save = deploy_editing(project)
    return function()
        require("loomworks.ui.deploy_editor").open({
            destination = "",
            source = nil,
            projects = lw.get_projects() or {},
            profile = lw.get_active_profile(),
            workspace = lw.get_workspace(),
            launch_project = project,
            target_context = true,
            existing_destinations = dest_keys,
            on_accept = function(new_dest, new_source)
                local editable = get_editable_copy()
                local existing = editable[new_dest]
                if existing then
                    local arr = deploy_mod.normalize_sources(existing)
                    arr[#arr + 1] = new_source
                    editable[new_dest] = arr
                else
                    editable[new_dest] = new_source
                end
                save(editable)
            end,
            on_cancel = function() end,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Rendering (from the view rows)
-- ---------------------------------------------------------------------------

--- Render an env_dict editable type_config field: a group of name/value
--- string pairs with per-entry edit/delete and an Add button.
--- @param tree loomworks.Tree
--- @param prow table the project's view row
--- @param field table the field's view entry ({ name, label, kind, value })
--- @param project loomworks.Project|nil the project (actions)
local function render_env_dict_field(tree, prow, field, project)
    local current = field.value or {}
    if not next(current) and prow.orphaned then return end
    local save = field_saver(project, field.name)

    tree:group(field.label .. ":", "LoomworksSection", function()
        local keys = {}
        for k in pairs(current) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local ek = k  -- capture
            -- Chunk the row so the key reads as the named entity
            -- and the value as supplemental detail. Mirrors the
            -- pattern used for configurations and variables.
            tree:item({
                { k,             "LoomworksVariant" },
                { "=",           "Comment" },
                { current[k],    "Comment" },
            }, {
                hl = "LoomworksVariant",
                enter_label = "Edit variable",
                direct = true,
                on_enter = save and function()
                    vim.ui.input({ prompt = ek .. "=", default = current[ek] }, function(val)
                        if not val then return end
                        local new_val = vim.deepcopy(current)
                        if val == "" then
                            new_val[ek] = nil
                        else
                            new_val[ek] = val
                        end
                        save(new_val)
                    end)
                end or nil,
                on_delete = save and function()
                    local new_val = vim.deepcopy(current)
                    new_val[ek] = nil
                    save(new_val)
                end or nil,
            })
        end
        if not prow.orphaned then
            tree:item("▸ Add variable", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = save and function()
                    vim.ui.input({ prompt = "Variable name: " }, function(name)
                        if not name or name == "" then return end
                        vim.ui.input({ prompt = name .. "=" }, function(val)
                            if not val then return end
                            local new_val = vim.deepcopy(current)
                            new_val[name] = val
                            save(new_val)
                        end)
                    end)
                end or nil,
            })
        end
    end)
end

--- Render a single string-valued editable type_config field as a row.
--- Empty values show "(unset)" in Comment hl. Enter opens a prompt
--- pre-filled with the current value; submitting empty clears.
local function render_string_field(tree, prow, field, project)
    local current = field.value
    if not current and prow.orphaned then return end
    local save = field_saver(project, field.name)

    local display = current and current ~= "" and current or "(unset)"
    local hl = current and "LoomworksActionable" or "Comment"
    tree:item({
        { field.label .. ": ", "LoomworksSection" },
        { display, hl },
    }, {
        hl = hl,
        direct = true,
        enter_label = "Edit " .. field.label:lower(),
        on_enter = save and function()
            vim.ui.input({
                prompt = field.label .. ": ",
                default = current or field.placeholder or "",
            }, function(val)
                if val == nil then return end
                local new_val = val
                if new_val == "" then new_val = nil end
                save(new_val)
            end)
        end or nil,
        on_delete = (save and current) and function()
            save(nil)
        end or nil,
    })
end

--- Render a command-array editable type_config field. Displayed as the
--- whitespace-joined command line; editing accepts a joined string and
--- splits on whitespace. Quoted args / escapes are not supported here
--- — for those the user edits user.json / loomworks.json directly.
local function render_cmd_array_field(tree, prow, field, project)
    local current = field.value
    if not current and prow.orphaned then return end
    local save = field_saver(project, field.name)

    local joined = ""
    if type(current) == "table" then
        joined = table.concat(current, " ")
    end
    local display = joined ~= "" and joined or "(unset)"
    local hl = joined ~= "" and "LoomworksActionable" or "Comment"
    tree:item({
        { field.label .. ": ", "LoomworksSection" },
        { display, hl },
    }, {
        hl = hl,
        direct = true,
        enter_label = "Edit " .. field.label:lower(),
        on_enter = save and function()
            vim.ui.input({
                prompt = field.label .. " (space-separated): ",
                default = joined ~= "" and joined or (field.placeholder or ""),
            }, function(val)
                if val == nil then return end
                if val == "" then
                    save(nil)
                    return
                end
                local parts = {}
                for tok in val:gmatch("%S+") do parts[#parts + 1] = tok end
                save(parts)
            end)
        end or nil,
        on_delete = (save and joined ~= "") and function()
            save(nil)
        end or nil,
    })
end

--- Dispatch rendering for an editable type_config field based on its kind.
--- Extend this switch as new kinds are introduced.
local function render_editable_type_config_field(tree, prow, field, project)
    if field.kind == "env_dict" then
        render_env_dict_field(tree, prow, field, project)
    elseif field.kind == "string" then
        render_string_field(tree, prow, field, project)
    elseif field.kind == "cmd_array" then
        render_cmd_array_field(tree, prow, field, project)
    else
        tree:leaf(field.label .. ": (unsupported kind: "
            .. tostring(field.kind) .. ")", "DiagnosticWarn")
    end
end

--- Render one configuration of a project (`prow.configurations[]`).
local function render_configuration(tree, ct, ctx, prow, crow, cfg_group)
    local key = prow.key
    local cname = crow.key
    local project = ctx.ref(prow)
    local cfg = ctx.ref(crow)

    -- Abstract configs have no variant (mixin only)
    local is_abstract = crow.abstract
    local unresolved_set = {}
    local unresolved_inherits = crow.unresolved_inherits or {}
    for _, n in ipairs(unresolved_inherits) do
        unresolved_set[n] = true
    end
    local has_unresolved = #unresolved_inherits > 0
    local dependents = crow.dependents or {}
    -- Reserved compiler keys (options/env) smuggled in by
    -- a hand-edited file. Non-blocking: stripped at build,
    -- the tool's compiler is used. Surfaced as a ⚠ tag.
    local compiler_overrides = crow.compiler_overrides or {}
    local has_compiler_override = #compiler_overrides > 0

    -- Variant-name color: `LoomworksVariant` for
    -- buildable user configs; `Comment` for
    -- shared/auto-gen/abstract entries (dim
    -- because they're not the user's primary
    -- edit targets in this list). Severity
    -- (source-missing, unresolved inherits)
    -- stays on the leading `⚠` prefix —
    -- the variant name keeps its identity color.
    local variant_hl
    if crow.auto_gen or cfg_group == "shared" or is_abstract then
        variant_hl = "Comment"
    else
        variant_hl = "LoomworksVariant"
    end

    --- Format an inherits list inline with ⚠ prefixes
    --- on the names that didn't resolve.
    local function format_inherits(inh)
        local names = inh
        if type(names) == "string" then names = { names } end
        local parts = {}
        for _, n in ipairs(names) do
            parts[#parts + 1] = unresolved_set[n]
                and ("⚠" .. n) or n
        end
        return table.concat(parts, ", ")
    end

    -- Brief-line tag order: missing source, abstract,
    -- inherits, used by. Each tag collapses to one
    -- parenthesised comma-separated group; the
    -- leading `⚠ ` badge only appears for
    -- warning-category states (missing source or
    -- any unresolved inherit) so problems stay
    -- visible even when the line overflows right.
    local brief = {}
    if crow.source_missing then
        brief[#brief + 1] = "missing source"
    end
    if is_abstract then
        brief[#brief + 1] = "abstract"
    end
    if crow.inherits then
        brief[#brief + 1] = "inherits: " .. format_inherits(crow.inherits)
    end
    if #dependents > 0 then
        brief[#brief + 1] = "used by: " .. table.concat(dependents, ", ")
    end
    if crow.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
    if crow.role then brief[#brief + 1] = "role:" .. crow.role end
    if has_compiler_override then
        brief[#brief + 1] = "ignored compiler override ("
            .. table.concat(compiler_overrides, ", ") .. ")"
    end
    local brief_str = #brief > 0
            and ("  (" .. table.concat(brief, ", ") .. ")") or ""
    -- Leading ⚠ for warning states so the badge stays
    -- visible at the left edge even on long overflow
    -- lines where the tags would scroll out of view.
    local warn_prefix = (crow.source_missing or has_unresolved
            or has_compiler_override)
        and "⚠ " or ""

    local config_chunks = {}
    if warn_prefix ~= "" then
        config_chunks[#config_chunks + 1] = { warn_prefix, "DiagnosticWarn" }
    end
    if crow.modified then
        config_chunks[#config_chunks + 1] = { "+", "Comment" }
    end
    config_chunks[#config_chunks + 1] = { cname, variant_hl }
    if brief_str ~= "" then
        config_chunks[#config_chunks + 1] = { brief_str, "Comment" }
    end
    -- Overwritten marker (spec/ui.md §1.8): a config unit
    -- under this configuration was built but another unit's
    -- build has since overwritten its shared output artifact.
    -- Matches the profile-side rendering (§1.5).
    if crow.overwritten then
        config_chunks[#config_chunks + 1] =
            { " [overwritten]", "LoomworksConflict" }
    end

    -- The row carries `auto_gen` (and `user`, ...) exactly when the
    -- Configuration object exists, on both sources ("Two sources, one shape").
    local has_object = crow.auto_gen ~= nil
    local opts = {
        fold_key = "config:" .. key .. ":" .. cname,
        spinning = not is_abstract and crow.running or false,
        hl = variant_hl,
        enter_label = "Edit configuration",
        publish_label = has_object and helpers.intent_action_label(crow.intent) or nil,
    }
    if has_object then helpers.describe(opts, crow.description, crow.description_from_module) end
    ct:node(config_chunks, with(opts, configuration_actions(ctx.ws, project, cfg, crow)), function()
        if has_object then
            tree:description(crow.description, crow.description_from_module)
            -- Saved test targets (read-only, ui "Saved test
            -- targets line"): flagged only when this machine
            -- configured a unit of it (targets known).
            if crow.tests then
                local chunks = helpers.test_targets_chunks(crow.tests, (tree.width or 100) - 12)
                if chunks then tree:leaf(chunks) end
            end
        end
        if is_abstract then
            tree:leaf("Abstract mixin — not directly buildable", "Comment")
        end

        if crow.inherits then
            tree:leaf("Inherits: " .. format_inherits(crow.inherits),
                has_unresolved and "WarningMsg" or "Comment")
        end

        -- Used by: direct dependents in this project.
        -- Includes stale references (`_source_missing`
        -- dependents) so the user sees every link the
        -- config files declare, not just what resolved.
        if #dependents > 0 then
            tree:leaf("Used by: " .. table.concat(dependents, ", "),
                "Comment")
        end

        -- (Variant row intentionally omitted — the
        -- canonical name + inherits chain already
        -- convey the compile mode; showing it here
        -- was redundant with `variant:Debug`-style
        -- names.)
        if crow.toolchain then
            tree:leaf("Toolchain: " .. tostring(crow.toolchain), "Comment")
        end
        if crow.generator then
            tree:leaf("Generator: " .. crow.generator, "Comment")
        end
        -- Options: own ones plain, inherited ones dimmed with their source.
        for _, o in ipairs(crow.options or {}) do
            if o.source then
                tree:leaf(o.key .. "=" .. o.value
                    .. "  (" .. o.source .. ")", "NonText")
            else
                tree:leaf(o.key .. "=" .. o.value, "Comment")
            end
        end
        -- Resolved variables (with the active profile's fill; an
        -- unfilled blank renders as "(blank)").
        for _, v in ipairs(crow.variables or {}) do
            local shown = v.value == nil and "(blank)" or v.value
            if v.own then
                tree:leaf("${" .. v.name .. "} = " .. shown, "Comment")
            else
                tree:leaf("${" .. v.name .. "} = " .. shown
                    .. "  (" .. v.source .. ")", "NonText")
            end
        end
        if (crow.tools_configured or 0) > 0 then
            tree:leaf(crow.tools_configured .. " tool(s) configured", "Comment")
        end
    end)
end

--- Render a project's expansion.
local function render_project_details(tree, t, ctx, prow)
    local lw = ctx.lw
    local project = ctx.ref(prow)
    tree:description(prow.description)
    tree:leaf("Path: " .. prow.path, "Comment")
    -- Project-wide saved test targets (ui "Saved test targets line").
    if prow.tests then
        local chunks = helpers.test_targets_chunks(prow.tests, (tree.width or 100) - 8)
        if chunks then tree:leaf(chunks) end
    end

    for _, reason in ipairs(prow.refresh_reasons or {}) do
        tree:leaf("! " .. reason, "DiagnosticWarn")
    end

    if next(prow.configurations) then
        t:group("Configurations:", "LoomworksSection", function()
            helpers.render_grouped(t, prow.configurations, function(ct, crow, cfg_group)
                render_configuration(tree, ct, ctx, prow, crow, cfg_group)
            end, "shared")
            if not prow.orphaned then
                tree:item("▸ Add configuration", {
                    hl = "LoomworksAdd",
                    direct = true,
                    on_enter = project and function() edit_project_configuration(project, nil) end or nil,
                })
            end
        end)
    end

    if prow.presets then
        tree:group("Presets:", "LoomworksSection", function()
            for _, p in ipairs(prow.presets) do
                local brief = {}
                if p.generator then brief[#brief + 1] = p.generator end
                if p.toolchain_locked then brief[#brief + 1] = "toolchain" end
                local brief_str = #brief > 0
                        and ("  (" .. table.concat(brief, ", ") .. ")") or ""
                tree:leaf(p.name .. brief_str .. "  (CMakePresets.json)", "Comment")
            end
        end)
    end

    local launches = prow.launches
    if #launches > 0 or not prow.orphaned then
        tree:group("Launch:", "LoomworksSection", function()
            -- {name}  {summary}  {runs} (ui §1.8): summary column before
            -- the open-ended command line, which is cut to the window.
            local entries = {}
            for _, l in ipairs(launches) do
                entries[#entries + 1] = { name = l.key, config = { description = l.description,
                    target = l.target, command = l.command, args = l.args } }
            end
            local rows = helpers.launch_row_chunks(entries,
                (tree.width or 100) - vim.fn.strdisplaywidth(tree:_pad()))
            for _, l in ipairs(launches) do
                local lname = l.key
                local full = (l.target and ("target:" .. l.target) or (l.command or ""))
                    .. ((type(l.args) == "table" and #l.args > 0)
                        and (" " .. table.concat(l.args, " ")) or "")
                local opts = helpers.describe({
                    hl = "LoomworksVariant",
                    enter_label = "Edit launch config",
                }, l.description)
                local launch = ctx.ref(l)
                if project and launch then
                    opts.on_enter = function() edit_launch_config(project, launch) end
                    opts.on_delete = function() delete_launch_config(project, launch) end
                    helpers.describe_action(opts, launch)
                end
                -- The summary is rendered as a column above, not appended.
                opts.description = nil
                -- K: the full description, else the full command line.
                if not l.description then opts.hover = full end
                tree:item(rows[lname], opts)
            end
            tree:item("▸ Add launch config", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = project and function() edit_launch_config(project, nil) end or nil,
            })
        end)
    end

    if #prow.deploy > 0 or not prow.orphaned then
        tree:group("Deploy:", "LoomworksSection", function()
            local function format_source(src)
                local display = src.project or "?"
                if src.target then display = display .. " : " .. src.target
                elseif src.path then display = display .. " : " .. src.path end
                if src.configuration then display = display .. " (" .. src.configuration .. ")" end
                if src.pre_build then display = display .. " [pre-build]" end
                return display
            end

            local dest_keys = {}
            for _, d in ipairs(prow.deploy) do dest_keys[#dest_keys + 1] = d.destination end

            for _, d in ipairs(prow.deploy) do
                tree:leaf("  " .. d.destination, "Comment")
                for si, src in ipairs(d.sources) do
                    tree:item("    <- " .. format_source(src), with({
                        hl = "LoomworksActionable",
                        enter_label = "Edit deploy step",
                    }, deploy_step_actions(lw, project, dest_keys, d.destination, si, src)))
                end
            end

            if not prow.orphaned then
                tree:item("▸ Add deploy step", {
                    hl = "LoomworksAdd",
                    direct = true,
                    on_enter = add_deploy_action(lw, project, dest_keys),
                })
            end
        end)
    end

    local vars = {}
    for name, decl in pairs(prow.variables) do
        vars[#vars + 1] = { name = name, type = decl.type, default = decl.default }
    end
    table.sort(vars, function(a, b) return a.name < b.name end)
    if #vars > 0 or not prow.orphaned then
        tree:group("Variables:", "LoomworksSection", function()
            for _, v in ipairs(vars) do
                local vname = v.name  -- capture
                local suffix = "  (" .. v.type .. ") = " .. v.default
                tree:item({
                    { v.name, "LoomworksVariant" },
                    { suffix, "Comment" },
                }, {
                    hl = "LoomworksVariant",
                    enter_label = "Edit variable",
                    on_enter = project and function() edit_variable(project, vname) end or nil,
                    on_delete = project and function() delete_variable(project, vname) end or nil,
                })
            end
            tree:item("▸ Add variable", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = project and function() edit_variable(project, nil) end or nil,
            })
        end)
    end

    for _, field in ipairs(prow.type_config.fields) do
        render_editable_type_config_field(tree, prow, field, project)
    end

    tree:blank()
end

--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, view, ref, ws }
return function(tree, ctx)
    local projects = ctx.view.projects
    if #projects == 0 then
        tree:leaf("Projects", "Title")
        tree:blank()
        tree:item("▸ Add project", {
            hl = "LoomworksAdd",
            direct = true,
            on_enter = open_add_project,
        })
        tree:blank()
        return
    end

    tree:leaf("Projects", "Title")
    tree:blank()

    helpers.render_grouped(tree, projects, function(t, prow, group)
        local key = prow.key
        local is_shared_only = group == "shared"

        local modified_tag = prow.modified and "+" or ""
        local type_tag = " [" .. prow.type .. "]"
        local orphan_tag = prow.orphaned and " (orphaned)" or ""
        local refresh_tag = prow.needs_refresh and " !" or ""

        -- Project header: always blue (`LoomworksProject`) except
        -- when the project is shared-only — those follow the
        -- publish UX and dim to Comment. State (running, orphaned,
        -- needs-refresh) is conveyed via marker spinner or text
        -- tags, not row color. The "active project" distinction
        -- was dropped — the user thinks in profiles, not in which
        -- projects happen to be in scope.
        local row_hl = is_shared_only and "Comment" or "LoomworksProject"
        local row_chunks = {
            { modified_tag, "Comment" },
            { key, row_hl },
            { type_tag, "Comment" },
        }
        if orphan_tag ~= "" then
            row_chunks[#row_chunks + 1] = { orphan_tag, "DiagnosticWarn" }
        end
        if refresh_tag ~= "" then
            row_chunks[#row_chunks + 1] = { refresh_tag, "DiagnosticWarn" }
        end

        t:node(row_chunks, with(helpers.describe({
            fold_key = "project:" .. key,
            spinning = prow.running,
            hl = row_hl,
            publish_label = helpers.intent_action_label(prow.intent),
        }, prow.description, prow.description_from_module), project_actions(ctx.ws, ctx.ref(prow))), function()
            render_project_details(tree, t, ctx, prow)
        end)
    end)

    tree:item("▸ Add project", {
        hl = "LoomworksAdd",
        enter_label = "Add project",
        on_enter = open_add_project,
    })
    tree:blank()
end
