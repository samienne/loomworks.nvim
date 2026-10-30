--- loomworks/ui/sections/projects.lua — Projects section renderer.
---
--- Renders from the workspace view's `projects` rows
--- (`loomworks.view.Workspace/1`, spec §19.13 "The workspace view"): the
--- project's configurations, presets, launches, deploy steps, variables and
--- editable type_config fields. The actions (editors, dialogs, mutations)
--- are kept apart. The routed writes (step 5o C2b: removals of
--- configurations and launch configurations, variables, `type_config`
--- fields; C2b2-1: the configuration editor's save; C2b2-2: the launch and
--- deploy editors' saves) name their project, configuration or launch by
--- its view row (loomworks.ui.model_calls) and are offered on a row that
--- can be named (helpers.actionable); their dialogs read the project
--- through `Projects/1.declaration` (the configuration editor all it shows,
--- with the view's configuration sets for a rename's effects; the launch
--- editor its fields and variables, a deploy change the declared deploy),
--- the workspace view's rows (the deploy editor's projects, configurations,
--- targets and source preview) and `Projects/1.expand_preview` (the path
--- previews). The project's removal (`D`, step 5o C2c-2) is
--- `Maintenance/1.execute_deletion { project }` by the row too
--- (loomworks.ui.actions.delete_project).

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")
local model = require("loomworks.ui.model_calls")

-- ---------------------------------------------------------------------------
-- Actions (editors, dialogs, mutations)
-- ---------------------------------------------------------------------------

--- The preview of templates expanded for the project of the view row
--- `prow` (`Projects/1.expand_preview`, under the active profile): the
--- editors' `preview(template, cb)`, `cb(nil)` when it is refused.
--- @param prow table
--- @return fun(template: string, cb: fun(value: string|nil))
local function previewer(prow)
    return function(template, cb)
        model.call(nil, "Projects/1.expand_preview", { project = prow, templates = { template } }, function(r)
            cb(r.outcome == "ok" and type(r.values) == "table" and r.values[1] or nil)
        end)
    end
end

--- What the launch and deploy editors read of the workspace view `view`:
--- its project rows, profile rows and each project row's preview.
local function deploy_context(view)
    return { projects = view.projects or {}, profiles = view.profiles or {}, preview_for = previewer }
end

--- The declaration's entry of the launch row `lrow`: by its id (a daemon's
--- view and declaration share them), or by its name where neither carries
--- one (the in-process view and declaration).
--- @param decl table
--- @param lrow table
--- @return table|nil
local function declared_launch(decl, lrow)
    for _, l in ipairs(decl.launches or {}) do
        if (lrow.id ~= nil and l.id == lrow.id) or (lrow.id == nil and l.id == nil and l.key == lrow.key) then
            return l
        end
    end
    return nil
end

--- Open the launch editor on the project's declaration `decl`
--- (Projects/1.declaration) for the launch row `lrow` (nil: a new one).
--- @param ctx table the section context (`view`, `ws`)
--- @param prow table the project's view row
--- @param lrow table|nil
--- @param decl table
local function open_launch_editor(ctx, prow, lrow, decl)
    local project_key = prow.key
    local launch_name = lrow and lrow.key or nil
    local fields = {}
    if lrow then
        local entry = declared_launch(decl, lrow)
        if not entry or not entry.fields then
            vim.notify("loomworks: launch config '" .. launch_name .. "' is not declared as a table in project '"
                .. project_key .. "'", vim.log.levels.ERROR)
            return
        end
        fields = entry.fields
    end
    local taken = {}
    for _, l in ipairs(decl.launches or {}) do taken[l.key] = true end
    local ws = ctx.ws
    local dctx = deploy_context(ctx.view)

    require("loomworks.ui.launch_editor").open({
        title = launch_name
            and ('Edit "' .. launch_name .. '" — ' .. project_key)
            or ("New launch — " .. project_key),
        name = launch_name or "",
        command = fields.command or "",
        args = vim.deepcopy(fields.args or {}),
        working_dir = fields.working_dir or "",
        env = vim.deepcopy(fields.env or {}),
        deploy = vim.deepcopy(fields.deploy or {}),
        debug = vim.deepcopy(fields.debug or {}),
        describe_item = lrow and helpers.row_item("launch configuration", lrow, project_key .. ":" .. lrow.key) or nil,
        variables = decl.variables,
        preview = previewer(prow),
        projects = dctx.projects,
        profiles = dctx.profiles,
        preview_for = dctx.preview_for,
        -- A target-backed launch resolves ${target_dir} (§8.7); a
        -- command-type (or new) one does not.
        target_context = fields.target ~= nil,
        -- (No `ws` in `daemon` mode: the editor holds no model, step 6b-alpha.)
        debug_adapters = function()
            local ops = require("loomworks.daemon.editor_ops")
            if not ws and not ops.daemon_of(nil) then return nil end
            return (ops.debug_adapters(ws))
        end,
        -- Every known language, for "Add debug language".
        debug_languages = function(cb)
            local ops = require("loomworks.daemon.editor_ops")
            if not ws and not ops.daemon_of(nil) then return cb(nil, "no workspace") end
            ops.debug_languages(ws, cb)
        end,
        -- The daemon's records arrive after the dialog opens: it re-renders.
        on_debug_adapters = function(arrived)
            local daemon, obs = require("loomworks.daemon.editor_ops").daemon_of(ws)
            if daemon and obs and obs.state ~= "stopped" and obs:can_call("adapters") then
                obs:with_debug_adapters(function() arrived() end)
            end
        end,
        validate = function(result)
            if result.name ~= (launch_name or "") then
                if taken[result.name] then
                    return false, "launch config '" .. result.name .. "' already exists"
                end
                -- A new name must be valid (spec §8.7).
                local vok, verr = require("loomworks.project").validate_launch_name(result.name)
                if not vok then return false, verr end
            end
            return true
        end,
        on_accept = function(result)
            model.call(nil, "Projects/1.launch_save", {
                project = prow, launch = lrow, name = result.name, data = {
                    command = result.command,
                    args = result.args,
                    working_dir = result.working_dir,
                    env = result.env,
                    deploy = result.deploy,
                    debug = result.debug,
                } }, function(r)
                local ok, err = model.result(r)
                if ok then
                    local verb = launch_name and "updated" or "created"
                    vim.notify("loomworks: launch config '" .. result.name .. "' " .. verb,
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to save launch config"),
                        vim.log.levels.ERROR)
                end
            end)
        end,
        on_cancel = function() end,
    })
end

--- Open the launch editor for the launch row `lrow` of the project row
--- `prow` (nil: a new launch config), once its declaration is read.
--- @param ctx table the section context
--- @param prow table
--- @param lrow table|nil
local function edit_launch_config(ctx, prow, lrow)
    model.call(nil, "Projects/1.declaration", { project = prow }, function(r)
        if r.outcome ~= "ok" then
            vim.notify("loomworks: " .. tostring(r.message or "the project's declaration is unavailable"),
                vim.log.levels.ERROR)
            return
        end
        open_launch_editor(ctx, prow, lrow, r)
    end)
end

--- Delete a launch config with confirmation.
--- @param prow table the project's view row
--- @param lrow table the launch configuration's view row
local function delete_launch_config(prow, lrow)
    local project_key = prow.key
    local launch_name = lrow.key

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
                model.call(nil, "Projects/1.launch_remove", { project = prow, launch = lrow }, function(r)
                    local ok, err = model.result(r)
                    if ok then
                        vim.notify("loomworks: launch config '" .. launch_name .. "' deleted",
                            vim.log.levels.INFO)
                    else
                        vim.notify("loomworks: " .. (err or "failed to delete"),
                            vim.log.levels.ERROR)
                    end
                end)
            end,
        },
    })
end

--- The variable editor for `var_name` of the project `prow`, on its
--- declaration's `variables` (`Projects/1.declaration`).
--- @param prow table the project's view row
--- @param var_name string|nil nil for new variable
--- @param variables table<string, { type: string, default?: string }>
local function open_variable_editor(prow, var_name, variables)
    local decl = var_name and variables[var_name] or nil
    require("loomworks.ui.variable_editor").open({
        title = var_name
            and ('Edit "' .. var_name .. '" — ' .. prow.key)
            or ("New variable — " .. prow.key),
        name = decl and var_name or "",
        type = decl and decl.type or "string",
        default = decl and decl.default or "",
        validate = function(result)
            if result.name ~= (var_name or "") and variables[result.name] then
                return false, "variable '" .. result.name .. "' already exists"
            end
            local vars_mod = require("loomworks.variables")
            if vars_mod.RESERVED_NAMES[result.name] then
                return false, "'" .. result.name .. "' is a reserved name"
            end
            return true
        end,
        on_accept = function(result)
            model.call(nil, "Projects/1.variable_save", {
                project = prow, variable = var_name, name = result.name, data = {
                    type = result.type,
                    default = result.default,
                } }, function(r)
                local ok, err = model.result(r)
                if ok then
                    local verb = var_name and "updated" or "created"
                    vim.notify("loomworks: variable '" .. result.name .. "' " .. verb,
                        vim.log.levels.INFO)
                else
                    vim.notify("loomworks: " .. (err or "failed to save variable"),
                        vim.log.levels.ERROR)
                end
            end)
        end,
        on_cancel = function() end,
    })
end

--- Open the variable editor for an existing or new variable of the project
--- `prow`, once its declaration is read.
--- @param prow table the project's view row
--- @param var_name? string nil for new variable
local function edit_variable(prow, var_name)
    model.call(nil, "Projects/1.declaration", { project = prow }, function(r)
        if r.outcome ~= "ok" then
            vim.notify("loomworks: " .. tostring(r.message or "the project's declaration is unavailable"),
                vim.log.levels.ERROR)
            return
        end
        open_variable_editor(prow, var_name, r.variables or {})
    end)
end

--- Delete a project variable with confirmation.
--- @param prow table the project's view row
--- @param var_name string
local function delete_variable(prow, var_name)
    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = {
            "  Delete variable: " .. var_name,
            "",
            "  Project: " .. prow.key,
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
                model.call(nil, "Projects/1.variable_remove", { project = prow, variable = var_name }, function(r)
                    local ok, err = model.result(r)
                    if ok then
                        vim.notify("loomworks: variable '" .. var_name .. "' deleted",
                            vim.log.levels.INFO)
                    else
                        vim.notify("loomworks: " .. (err or "failed to delete"),
                            vim.log.levels.ERROR)
                    end
                end)
            end,
        },
    })
end

--- The configuration-set mappings and the inheriting configurations a
--- rename of the configuration `crow` (named `config_name`) to `new_name`
--- also updates: the view's configuration sets whose mapping names that
--- configuration (helpers.same_entity: by id in `daemon` mode, the bound
--- object in-process) and the declaration's configurations' `inherits`.
--- @param view table|nil the workspace view
--- @param crow table the configuration's view row
--- @param decl table the project's declaration (Projects/1.declaration)
--- @param config_name string
--- @param new_name string
--- @return string[]|nil
local function config_rename_effects(view, crow, decl, config_name, new_name)
    if new_name == config_name or new_name == "" then return nil end
    local effects = {}
    for _, cs in ipairs(view and view.config_sets or {}) do
        for _, entry in ipairs(cs.mappings or {}) do
            if helpers.same_entity(entry.configuration, crow) then
                effects[#effects + 1] = "Config set '" .. cs.name .. "' mapping → " .. new_name
                break
            end
        end
    end
    for _, c in ipairs(decl.configurations or {}) do
        local inherits = c.fields and c.fields.inherits
        if type(inherits) == "string" then inherits = { inherits } end
        if c.key ~= config_name and type(inherits) == "table" and vim.tbl_contains(inherits, config_name) then
            effects[#effects + 1] = "Config '" .. c.key .. "' inherits → " .. new_name
        end
    end
    return #effects > 0 and effects or nil
end

--- The declaration's entry of the configuration row `crow`: by its id (a
--- daemon's view and declaration share them), or by its name where neither
--- carries one (the in-process view and declaration).
--- @param decl table
--- @param crow table
--- @return table|nil
local function declared_configuration(decl, crow)
    for _, c in ipairs(decl.configurations or {}) do
        if (crow.id ~= nil and c.id == crow.id) or (crow.id == nil and c.id == nil and c.key == crow.key) then
            return c
        end
    end
    return nil
end

--- Open the configuration editor on the project's declaration `decl`
--- (Projects/1.declaration): its declared fields (a user configuration's;
--- any other shows only its variables and languages) and what it derives
--- (variant and its source, inherited options, resolved variables, build
--- directories, the module's languages and options, the compiler family).
--- @param prow table the project's view row
--- @param crow table|nil the configuration's view row; nil for a new one
--- @param decl table
--- @param view table|nil the workspace view (rename effects)
local function open_configuration_editor(prow, crow, decl, view)
    local project_key = prow.key
    local config_name = crow and crow.key or nil
    local entry = crow and declared_configuration(decl, crow) or nil
    if crow and not entry then
        vim.notify("loomworks: configuration '" .. crow.key .. "' is no longer declared", vim.log.levels.ERROR)
        return
    end
    local fields = entry and entry.fields or {}
    local own = (entry and entry.user) and fields or {}
    local inherited = {}
    for _, o in ipairs(entry and entry.inherited_options or {}) do
        inherited[o.key] = { value = o.value,
            source = o.from == "configuration" and (o.configuration and o.configuration.key or "?") or "project" }
    end
    local resolved = {}
    for _, v in ipairs(entry and entry.resolved_variables or {}) do
        resolved[v.name] = { value = v.value, from = v.from, configuration = v.configuration and v.configuration.key }
    end
    local available = {}
    for _, c in ipairs(decl.configurations or {}) do
        if not c.source_missing then available[#available + 1] = c.key end
    end
    local module = decl.module or {}

    require("loomworks.ui.config_editor_dialog").open({
        item = crow and helpers.row_item("configuration", crow, project_key .. "/" .. crow.key) or nil,
        title = config_name
            and ('Edit "' .. config_name .. '" — ' .. project_key)
            or ("New configuration — " .. project_key),
        name = config_name or "",
        variant = entry and entry.variant or "",
        variant_source = entry and entry.variant_from and entry.variant_from.key or nil,
        inherits = own.inherits or "",
        options = vim.deepcopy(own.options or {}),
        variables = vim.deepcopy(fields.variables or {}),
        toolchain = own.toolchain or "",
        generator = own.generator or "",
        languages = fields.languages and #fields.languages > 0 and vim.deepcopy(fields.languages) or nil,
        module_languages = module.languages or {},
        build_dirs = entry and entry.build_dirs or nil,
        is_default = entry and entry.default or false,
        has_options = module.has_options or false,
        available_configs = available,
        project_options = decl.options or {},
        inherited_options = inherited,
        project_variables = decl.variables or {},
        resolved_variables = resolved,
        config_compiler_overrides = fields.overrides or {},
        active_compiler_family = decl.compiler_family,
        rename_effects = config_name and function(new_name)
            return config_rename_effects(view, crow, decl, config_name, new_name)
        end or nil,
        validate = function(result)
            if result.name ~= (config_name or "") then
                for _, c in ipairs(decl.configurations or {}) do
                    if c.key == result.name and c.user then
                        return false, "configuration '" .. result.name .. "' already exists"
                    end
                end
            end
            return true
        end,
        on_accept = function(result)
            -- The save changes only the fields the dialog edits; every other
            -- declared field (env, overrides, description, …) is kept. The
            -- name is the call's, not a field.
            local edits = {}
            for k, v in pairs(result) do
                if k ~= "name" then edits[k] = v end
            end
            model.call(nil, "Projects/1.configuration_save",
                { project = prow, configuration = crow, name = result.name, fields = edits }, function(r)
                    local ok, err = model.result(r)
                    if ok then
                        local verb = config_name and "updated" or "created"
                        vim.notify("loomworks: configuration '" .. result.name .. "' " .. verb,
                            vim.log.levels.INFO)
                    else
                        vim.notify("loomworks: " .. (err or "failed to save configuration"),
                            vim.log.levels.ERROR)
                    end
                end)
        end,
        on_cancel = function() end,
    })
end

--- Open the configuration editor for a configuration of the project `prow`
--- (or a new one), once its declaration is read (Projects/1.declaration).
--- @param prow table the project's view row
--- @param crow? table the configuration's view row; nil for a new configuration
--- @param view? table the workspace view
local function edit_project_configuration(prow, crow, view)
    model.call(nil, "Projects/1.declaration", { project = prow }, function(r)
        if r.outcome ~= "ok" then
            vim.notify("loomworks: " .. tostring(r.message or "the project's declaration is unavailable"),
                vim.log.levels.ERROR)
            return
        end
        open_configuration_editor(prow, crow, r, view)
    end)
end

--- Delete a user-defined project configuration with confirmation.
--- @param prow table the project's view row
--- @param crow table the configuration's view row
local function delete_project_configuration(prow, crow)
    local project_key = prow.key
    local config_name = crow.key

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
                model.call(nil, "Projects/1.configuration_remove", { project = prow, configuration = crow },
                    function(r)
                        local ok, err = model.result(r)
                        if ok then
                            vim.notify("loomworks: configuration '" .. config_name .. "' deleted",
                                vim.log.levels.INFO)
                        else
                            vim.notify("loomworks: " .. (err or "failed to delete"),
                                vim.log.levels.ERROR)
                        end
                    end)
            end,
        },
    })
end

--- Open the project browser for adding a project, at the loaded
--- workspace's root (in `daemon` mode the observed one: the editor holds
--- no model, step 6b-alpha).
local function open_add_project()
    local root = require("loomworks").loaded_root()
    if root then
        require("loomworks.ui.project_browser").open(root)
    end
end


--- `opts` with the entries of `acts` added.
local function with(opts, acts)
    for k, v in pairs(acts or {}) do opts[k] = v end
    return opts
end

--- Save a type_config field of the project `prow` (its view row; `bound`
--- false: no action, as for any row the editor's model lacks).
local function field_saver(prow, name, bound)
    if not bound then return nil end
    return function(value)
        model.call(nil, "Projects/1.type_config_set", { project = prow, field = name, value = value }, function(r)
            local ok, err = model.result(r)
            if not ok then
                vim.notify("loomworks: " .. tostring(err or "failed to save " .. name), vim.log.levels.ERROR)
            end
        end)
    end
end

--- The publish / revert actions shared by project and configuration rows,
--- naming the item by its view row (step 5o C2a). In `daemon` mode (no
--- model, step 6b-alpha) a row with an id (helpers.actionable).
--- @param ctx table the section context
--- @param row table the project's or configuration's view row
local function publish_actions(ctx, row)
    local ws = ctx.ws
    if not ws and not (ctx.mode == "daemon" and helpers.actionable(ctx, row)) then return {} end
    return {
        on_publish = function() helpers.cycle_intent(row, ws) end,
        on_publish_now = function() helpers.publish_one(row, ws) end,
        on_revert_one = function() helpers.revert_one(row, ws) end,
    }
end

--- The actions of a project row: publish / revert / describe and its
--- removal (`D`: its build state, then its declaration, then its profiles'
--- toolchain downgrade — `Maintenance/1.execute_deletion { project }`, step
--- 5o C2c-2), all by the row (the removal on an actionable row).
--- @param ctx table the section context
--- @param prow table the project's view row
local function project_actions(ctx, prow)
    local ws = ctx.ws
    local acts = helpers.describe_action(publish_actions(ctx, prow), helpers.row_item("project", prow))
    if helpers.actionable(ctx, prow) then acts.on_delete = actions.delete_project(prow, ws) end
    return acts
end

--- The actions of a configuration row: its editor and removal are routed
--- (by the rows, helpers.actionable — in `daemon` mode a row with an id,
--- even of a project the editor's model does not have yet).
--- @param ctx table the section context
--- @param prow table the project's view row
--- @param crow table the configuration's view row
local function configuration_actions(ctx, prow, crow)
    if not (helpers.actionable(ctx, prow) and helpers.actionable(ctx, crow)) then return {} end
    local acts = {
        on_enter = function() edit_project_configuration(prow, crow, ctx.view) end,
        on_delete = crow.user and function() delete_project_configuration(prow, crow) end or nil,
    }
    local item = helpers.row_item("configuration", crow, prow.key .. "/" .. crow.key)
    return helpers.describe_action(with(acts, publish_actions(ctx, crow)), item)
end

--- `cb(decl)` with the project row `prow`'s declaration as read now
--- (Projects/1.declaration); a failed read is notified.
--- @param prow table
--- @param cb fun(decl: table)
local function with_declaration(prow, cb)
    model.call(nil, "Projects/1.declaration", { project = prow }, function(r)
        if r.outcome ~= "ok" then
            vim.notify("loomworks: " .. tostring(r.message or "the project's declaration is unavailable"),
                vim.log.levels.ERROR)
            return
        end
        cb(r)
    end)
end

--- Change the deploy declaration of the project row `prow`: `mutate(deploy)`
--- on an editable copy of the declared one (Projects/1.declaration — never
--- the view's, whose sources are normalized to arrays: saving those would
--- rewrite the file's shape), then saved whole (Projects/1.deploy_save).
--- @param prow table
--- @param mutate fun(deploy: table): boolean? false: nothing saved
local function update_deploy(prow, mutate)
    with_declaration(prow, function(r)
        local editable = vim.deepcopy(r.deploy or {})
        if mutate(editable) == false then return end
        model.call(nil, "Projects/1.deploy_save", { project = prow, deploy = editable }, function(sr)
            local ok, err = model.result(sr)
            if not ok then
                vim.notify("loomworks: " .. tostring(err or "failed to save deploy steps"), vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Put `source` under `dest` of `deploy`: the destination's only source, or
--- appended to the ones it has.
local function add_source(deploy, dest, source)
    local existing = deploy[dest]
    if existing then
        local arr = require("loomworks.deploy").normalize_sources(existing)
        arr[#arr + 1] = source
        deploy[dest] = arr
    else
        deploy[dest] = source
    end
end

--- Set `dest` of `deploy` to the sources `cur`: removed when none, the one
--- source itself, else the array.
local function set_sources(deploy, dest, cur)
    if #cur == 0 then
        deploy[dest] = nil
    elseif #cur == 1 then
        deploy[dest] = cur[1]
    else
        deploy[dest] = cur
    end
end

--- The deploy editor's opts common to a project's steps; its variables
--- the declaration's `decl` (as the launch editor's).
local function deploy_editor_opts(ctx, prow, dest_keys, decl)
    local dctx = deploy_context(ctx.view)
    return {
        projects = dctx.projects,
        profiles = dctx.profiles,
        preview_for = dctx.preview_for,
        variables = decl.variables,
        preview = previewer(prow),
        -- A project-level step also runs for its build targets (§8.7),
        -- so ${target_dir} is offered; it also runs for command launches,
        -- where ${target_dir} is unresolved and fails that deploy.
        target_context = true,
        existing_destinations = dest_keys,
        on_cancel = function() end,
    }
end

--- The index in `cur` (a destination's sources, as re-read from the
--- declaration) of the shown source `src`: the shown index `si` when it
--- still holds `src`, else the first source equal to it; nil when gone.
local function locate_source(cur, si, src)
    if cur[si] ~= nil and vim.deep_equal(cur[si], src) then return si end
    for i, s in ipairs(cur) do
        if vim.deep_equal(s, src) then return i end
    end
    return nil
end

--- The actions of one deploy step (`dest`, the shown source `src` at index
--- `si`) of the project row `prow` (routed by the row, helpers.actionable).
--- The write runs on the declaration as re-read, so the source is found
--- there by its content; one no longer there is refused, never guessed.
local function deploy_step_actions(ctx, prow, dest_keys, dest, si, src)
    if not helpers.actionable(ctx, prow) then return {} end
    local deploy_mod = require("loomworks.deploy")
    --- `edit(editable, cur, i)` on the re-read sources of `dest`, `i` the
    --- shown source's index there; false when it is gone.
    local function on_source(edit)
        update_deploy(prow, function(editable)
            local cur = editable[dest] and deploy_mod.normalize_sources(editable[dest]) or {}
            local i = locate_source(cur, si, src)
            if not i then
                vim.notify("loomworks: the deploy step '" .. dest .. "' changed since shown; reopen it",
                    vim.log.levels.WARN)
                return false
            end
            edit(editable, cur, i)
        end)
    end
    return {
        on_enter = function() with_declaration(prow, function(decl)
            local opts = deploy_editor_opts(ctx, prow, dest_keys, decl)
            opts.destination = dest
            opts.source = vim.deepcopy(src)
            opts.current_destination = dest
            opts.on_accept = function(new_dest, new_source)
                on_source(function(editable, cur, i)
                    if new_dest ~= dest then
                        table.remove(cur, i)
                        set_sources(editable, dest, cur)
                        add_source(editable, new_dest, new_source)
                    else
                        cur[i] = new_source
                        set_sources(editable, dest, cur)
                    end
                end)
            end
            require("loomworks.ui.deploy_editor").open(opts)
        end) end,
        on_delete = function()
            on_source(function(editable, cur, i)
                table.remove(cur, i)
                set_sources(editable, dest, cur)
            end)
        end,
    }
end

--- "▸ Add deploy step" of the project row `prow`.
local function add_deploy_action(ctx, prow, dest_keys)
    if not helpers.actionable(ctx, prow) then return nil end
    return function() with_declaration(prow, function(decl)
        local opts = deploy_editor_opts(ctx, prow, dest_keys, decl)
        opts.destination = ""
        opts.on_accept = function(new_dest, new_source)
            update_deploy(prow, function(editable) add_source(editable, new_dest, new_source) end)
        end
        require("loomworks.ui.deploy_editor").open(opts)
    end) end
end

-- ---------------------------------------------------------------------------
-- Rendering (from the view rows)
-- ---------------------------------------------------------------------------

--- Render an env_dict editable type_config field: a group of name/value
--- string pairs with per-entry edit/delete and an Add button.
--- @param tree loomworks.Tree
--- @param prow table the project's view row
--- @param field table the field's view entry ({ name, label, kind, value })
--- @param bound boolean the editor's model has the project (actions)
local function render_env_dict_field(tree, prow, field, bound)
    local current = field.value or {}
    if not next(current) and prow.orphaned then return end
    local save = field_saver(prow, field.name, bound)

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
local function render_string_field(tree, prow, field, bound)
    local current = field.value
    if not current and prow.orphaned then return end
    local save = field_saver(prow, field.name, bound)

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
local function render_cmd_array_field(tree, prow, field, bound)
    local current = field.value
    if not current and prow.orphaned then return end
    local save = field_saver(prow, field.name, bound)

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
local function render_editable_type_config_field(tree, prow, field, bound)
    if field.kind == "env_dict" then
        render_env_dict_field(tree, prow, field, bound)
    elseif field.kind == "string" then
        render_string_field(tree, prow, field, bound)
    elseif field.kind == "cmd_array" then
        render_cmd_array_field(tree, prow, field, bound)
    else
        tree:leaf(field.label .. ": (unsupported kind: "
            .. tostring(field.kind) .. ")", "DiagnosticWarn")
    end
end

--- Render one configuration of a project (`prow.configurations[]`).
local function render_configuration(tree, ct, ctx, prow, crow, cfg_group)
    local key = prow.key
    local cname = crow.key

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
    ct:node(config_chunks, with(opts, configuration_actions(ctx, prow, crow)), function()
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
    -- The project's rows act by the row (helpers.actionable): in `daemon`
    -- mode a row with an id, even of a project the editor's model does not
    -- have yet.
    local actionable = helpers.actionable(ctx, prow)
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
                    on_enter = actionable
                        and function() edit_project_configuration(prow, nil, ctx.view) end or nil,
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
                -- The editor and the removal name it by its row (step 5o
                -- C2b / C2b2-2).
                if actionable and helpers.actionable(ctx, l) then
                    opts.on_enter = function() edit_launch_config(ctx, prow, l) end
                    opts.on_delete = function() delete_launch_config(prow, l) end
                end
                helpers.describe_action(opts, helpers.row_item("launch configuration", l, prow.key .. ":" .. lname))
                -- The summary is rendered as a column above, not appended.
                opts.description = nil
                -- K: the full description, else the full command line.
                if not l.description then opts.hover = full end
                tree:item(rows[lname], opts)
            end
            tree:item("▸ Add launch config", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = actionable and function() edit_launch_config(ctx, prow, nil) end or nil,
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
                    }, deploy_step_actions(ctx, prow, dest_keys, d.destination, si, src)))
                end
            end

            if not prow.orphaned then
                tree:item("▸ Add deploy step", {
                    hl = "LoomworksAdd",
                    direct = true,
                    on_enter = add_deploy_action(ctx, prow, dest_keys),
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
                    on_enter = actionable and function() edit_variable(prow, vname) end or nil,
                    on_delete = actionable and function() delete_variable(prow, vname) end or nil,
                })
            end
            tree:item("▸ Add variable", {
                hl = "LoomworksAdd",
                direct = true,
                on_enter = actionable and function() edit_variable(prow, nil) end or nil,
            })
        end)
    end

    for _, field in ipairs(prow.type_config.fields) do
        render_editable_type_config_field(tree, prow, field, actionable)
    end

    tree:blank()
end

--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, view, mode, ws }
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
        }, prow.description, prow.description_from_module), project_actions(ctx, prow)), function()
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
