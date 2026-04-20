--- loomworks/ui/sections/projects.lua — Projects section renderer.
---
--- Shows cached state and detected tools. Uses active profile context
--- only for highlight coloring (active vs non-active).

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")
local workspace_view = require("loomworks.workspace_view")

--- Sort project keys: non-orphaned first (alphabetical), orphaned last.
--- @param projects table<string, loomworks.Project>
--- @return loomworks.Project[]
local function sorted_projects(projects)
    local normal, orphaned = {}, {}
    for _, proj in pairs(projects) do
        if proj.orphaned then
            orphaned[#orphaned + 1] = proj
        else
            normal[#normal + 1] = proj
        end
    end
    table.sort(normal, function(a, b) return a.key < b.key end)
    table.sort(orphaned, function(a, b) return a.key < b.key end)
    for _, proj in ipairs(orphaned) do
        normal[#normal + 1] = proj
    end
    return normal
end

--- Look up a tool display label from detected tools.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param mod_type string
--- @param tool_key string
--- @return string
local function get_tool_display(tools_by_type, mod_type, tool_key)
    local tools = tools_by_type[mod_type]
    if tools then
        for _, dt in ipairs(tools) do
            if dt.tool_key == tool_key then
                return dt.tool_label or tool_key
            end
        end
    end
    return tool_key
end

--- Collect tool entries for a keyed-tool variant: cached entries + unconfigured detected tools.
--- Uses case-insensitive matching for variants because configuration_set variant
--- names may differ in case from module-detected configuration names (e.g. cmake
--- presets use "Debug" but the configuration set may map to "debug").
--- @param proj loomworks.Project
--- @param variant string
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table[] entries { unit?, tool_key, display_label, cached }
local function collect_tool_entries(proj, variant, tools_by_type)
    local entries = {}
    local seen_tool_keys = {}
    local variant_lower = variant:lower()

    -- 1. ConfigUnits for this configuration (from project scan)
    local cfg = proj:get_configuration(variant)
    for _, unit in ipairs(cfg and proj:config_units_for_configuration(cfg) or {}) do
        local tk = unit:tool_key()
        if tk then
            entries[#entries + 1] = {
                unit = unit,
                tool_key = tk,
                display_label = get_tool_display(tools_by_type, proj.type, tk),
                has_cache = unit._config_key ~= nil,
            }
            seen_tool_keys[tk] = true
        end
    end

    -- Also check cached_configurations for entries whose variant matches
    -- but may not have a ConfigUnit yet (e.g., orphaned cache entries)
    if proj.cached_configurations then
        for _, cached_config in pairs(proj.cached_configurations) do
            local v = cached_config.variant
            local tk = cached_config.tool_key
            if v and tk and v:lower() == variant_lower and not seen_tool_keys[tk] then
                entries[#entries + 1] = {
                    unit = nil, -- will be created on demand
                    tool_key = tk,
                    display_label = get_tool_display(tools_by_type, proj.type, tk),
                    cached = cached_config,
                }
                seen_tool_keys[tk] = true
            end
        end
    end

    -- 2. Detected tools not yet cached for this variant
    local relevant_tools = tools_by_type[proj.type] or {}
    for _, dt in ipairs(relevant_tools) do
        if dt.tool_key and not seen_tool_keys[dt.tool_key] then
            entries[#entries + 1] = {
                unit = nil, -- will be created on demand
                tool_key = dt.tool_key,
                display_label = dt.tool_label or dt.tool_key,
                cached = nil,
            }
        end
    end

    table.sort(entries, function(a, b) return a.tool_key < b.tool_key end)
    return entries
end

--- Open the launch editor for an existing or new launch config.
--- @param project loomworks.Project
--- @param launch_name? string nil for new config
local function edit_launch_config(project, launch_name)
    local project_key = project.key

    local ctx = workspace_view.compute_edit_launch_context(project, launch_name)

    -- Get workspace projects and active profile for deploy editor pickers
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
        validate = function(result)
            if result.name ~= (launch_name or "")
                    and project.launch
                    and project.launch[result.name] then
                return false, "launch config '" .. result.name .. "' already exists"
            end
            return true
        end,
        on_accept = function(result)
            local ok, err = workspace_view.execute_save_launch_config(
                project, launch_name, result.name, {
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
--- @param launch_name string
local function delete_launch_config(project, launch_name)
    local project_key = project.key

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
                local ok, err = workspace_view.execute_delete_launch_config(project, launch_name)
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
--- @param config_name? string nil for new configuration
local function edit_project_configuration(project, config_name)
    local project_key = project.key
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local ctx = workspace_view.compute_edit_configuration_context(project, config_name)
    if not ctx then return end

    require("loomworks.ui.config_editor_dialog").open({
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
            -- Config sets that reference this variant
            for _, cs_obj in pairs(ws._config_sets) do
                if cs_obj.mappings then
                    for proj, config in pairs(cs_obj.mappings) do
                        if proj.key == project_key and config.name == config_name then
                            effects[#effects + 1] = "Config set '" .. cs_obj.name .. "' mapping → " .. new_name
                        end
                    end
                end
            end
            -- Sibling configs that inherit from this name
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
            local ok, err = workspace_view.execute_save_configuration(
                project, config_name, result.name, {
                    variant = result.variant,
                    inherits = result.inherits,
                    options = result.options,
                    variables = result.variables,
                    toolchain = result.toolchain,
                    generator = result.generator,
                })
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
--- @param config_name string
local function delete_project_configuration(project, config_name)
    local project_key = project.key

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
                local ok, err = workspace_view.execute_delete_configuration(project, config_name)
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


--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, projects, active_profile_key }
return function(tree, ctx)
    local lw = ctx.lw
    local projects = ctx.projects
    if not projects or not next(projects) then
        tree:leaf("Projects", "Title")
        tree:blank()
        tree:item("▸ Add project", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = open_add_project,
        })
        tree:blank()
        return
    end

    tree:leaf("Projects", "Title")
    tree:blank()

    local tools_by_type = lw.get_tools_by_type()
    local sorted = sorted_projects(projects)
    local active_tool_key = ctx.active_profile and ctx.active_profile.tool
            and ctx.active_profile.tool.key or nil
    local ws = lw.get_workspace()

    helpers.render_grouped(tree, sorted, function(t, proj, group)
        local key = proj.key
        local proj_running = proj:running_action()
        local is_active_project = proj.configuration ~= nil and not proj.orphaned
        local is_shared_only = group == "shared"
        local proj_hl = proj_running and "LoomworksRunning"
                or is_shared_only and "Comment"
                or (is_active_project and "LoomworksActive" or "LoomworksActionable")

        local modified_tag = ws and ws:is_project_modified(proj) and "+" or ""
        local type_tag = "[" .. proj.type .. "]"
        local orphan_tag = proj.orphaned and " (orphaned)" or ""
        local refresh_tag = proj.needs_refresh and " !" or ""
        t:node(modified_tag .. key .. " " .. type_tag .. orphan_tag .. refresh_tag, {
            fold_key = "project:" .. key,
            spinning = proj_running ~= nil,
            hl = proj_hl,
            publish_label = helpers.intent_action_label(proj),
            on_publish = function()
                helpers.cycle_intent(proj)
                if ws then
                    ws:_save_user()
                    ws._core._deps.events.emit("active_set_changed", ws._active_set)
                end
            end,
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
        }, function()
            tree:leaf("Path: " .. (proj.path or key), "Comment")

            if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
                for _, reason in ipairs(proj.refresh_reasons) do
                    tree:leaf("! " .. reason, "DiagnosticWarn")
                end
            end

            if proj.configurations and next(proj.configurations) then
                t:group({{"Configurations:  ", "LoomworksActionable"}, {"[D] delete", "Comment"}}, function()
                    -- Build sorted config list with Configuration objects for grouping
                    local config_list = {}
                    for cname, cdata in pairs(proj.configurations) do
                        local cfg_obj = proj:get_configuration(cname)
                        config_list[#config_list + 1] = {
                            name = cname,
                            data = cdata,
                            cfg = cfg_obj,
                            _intent = cfg_obj and cfg_obj._intent or "shared",
                        }
                    end
                    table.sort(config_list, function(a, b) return a.name < b.name end)

                    helpers.render_grouped(t, config_list, function(ct, cfg_entry, cfg_group)
                        local cname = cfg_entry.name
                        local cdata = cfg_entry.data
                        local cname_cfg = cfg_entry.cfg
                        local tool_entries = collect_tool_entries(proj, cname, tools_by_type)
                        local has_tool_entries = #tool_entries > 0

                        -- Check running state across all ConfigUnits for this configuration
                        local config_has_running = false
                        if cname_cfg then
                            for _, cu in ipairs(proj:config_units_for_configuration(cname_cfg) or {}) do
                                if cu:is_running() then
                                    config_has_running = true
                                    break
                                end
                            end
                        end

                        -- Abstract configs have no variant (mixin only)
                        local is_abstract = not cdata.variant
                        local config_hl = is_abstract and "Comment"
                                or cfg_group == "shared" and "Comment"
                                or (config_has_running and "LoomworksRunning" or "LoomworksActionable")

                        local brief = {}
                        if is_abstract then
                            brief[#brief + 1] = "abstract"
                        elseif cdata.variant and cdata.variant ~= cname then
                            brief[#brief + 1] = cdata.variant
                        end
                        if cdata.inherits then
                            local inh = cdata.inherits
                            if type(inh) == "table" then inh = table.concat(inh, ", ") end
                            brief[#brief + 1] = "inherits: " .. inh
                        end
                        if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
                        if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
                        local brief_str = #brief > 0
                                and ("  (" .. table.concat(brief, ", ") .. ")") or ""
                        local cfg_modified_tag = ws and cname_cfg
                                and ws:is_config_modified(proj, cname_cfg) and "+" or ""

                        local project = proj  -- capture for closure
                        local cfg_name = cname
                        local cfg_obj = cname_cfg
                        local has_user_entry = cfg_obj and cfg_obj.is_user or false

                        ct:node(cfg_modified_tag .. cname .. brief_str, {
                            fold_key = "config:" .. key .. ":" .. cname,
                            spinning = not is_abstract and config_has_running or false,
                            hl = config_hl,
                            enter_label = "Edit configuration",
                            on_enter = function() edit_project_configuration(project, cfg_name) end,
                            publish_label = cname_cfg and helpers.intent_action_label(cname_cfg) or nil,
                            on_publish = cname_cfg and function()
                                helpers.cycle_intent(cname_cfg)
                                if ws then
                                    ws:_save_user()
                                    ws._core._deps.events.emit("active_set_changed", ws._active_set)
                                end
                            end or nil,
                            on_delete = has_user_entry
                                    and function() delete_project_configuration(project, cfg_name) end
                                    or nil,
                        }, function()
                            if is_abstract then
                                tree:leaf("Abstract mixin — not directly buildable", "Comment")
                            end

                            -- Configuration details
                            if cdata.variant then
                                tree:leaf("Variant: " .. cdata.variant, "Comment")
                            end
                            if cdata.toolchain then
                                tree:leaf("Toolchain: " .. tostring(cdata.toolchain), "Comment")
                            end
                            if cdata.generator then
                                tree:leaf("Generator: " .. cdata.generator, "Comment")
                            end
                            -- Show all resolved options (own + inherited) with source
                            local mod_impl = proj._module and proj._module.impl or nil
                            if mod_impl and mod_impl.resolve_options_with_sources then
                                local tc = proj:_type_config_for_module()
                                local all_opts = mod_impl.resolve_options_with_sources(
                                    tc, proj.configurations or {}, cname)
                                if next(all_opts) then
                                    local opt_keys = {}
                                    for k in pairs(all_opts) do opt_keys[#opt_keys + 1] = k end
                                    table.sort(opt_keys)
                                    local own = cdata.options or {}
                                    for _, k in ipairs(opt_keys) do
                                        local info = all_opts[k]
                                        if own[k] then
                                            tree:leaf(k .. "=" .. info.value, "Comment")
                                        else
                                            tree:leaf(k .. "=" .. info.value
                                                .. "  (" .. info.source .. ")", "NonText")
                                        end
                                    end
                                end
                            elseif cdata.options and next(cdata.options) then
                                local opt_keys = {}
                                for k in pairs(cdata.options) do opt_keys[#opt_keys + 1] = k end
                                table.sort(opt_keys)
                                for _, k in ipairs(opt_keys) do
                                    tree:leaf(k .. "=" .. cdata.options[k], "Comment")
                                end
                            end
                            -- Show resolved variables for this configuration
                            if proj.variables and next(proj.variables) then
                                local vars_mod = require("loomworks.variables")
                                local cfg_obj = proj:get_configuration(cname)
                                if cfg_obj then
                                    local resolved = vars_mod.resolve(proj, cfg_obj)
                                    local var_names = {}
                                    for vn in pairs(resolved) do var_names[#var_names + 1] = vn end
                                    table.sort(var_names)
                                    for _, vn in ipairs(var_names) do
                                        local entry = resolved[vn]
                                        local source_label
                                        if entry.source_config then
                                            source_label = entry.source_config.name
                                        else
                                            source_label = "project"
                                        end
                                        if cfg_obj.variables and cfg_obj.variables[vn] then
                                            tree:leaf("${" .. vn .. "} = " .. entry.value, "Comment")
                                        else
                                            tree:leaf("${" .. vn .. "} = " .. entry.value
                                                .. "  (" .. source_label .. ")", "NonText")
                                        end
                                    end
                                end
                            end
                            -- Show cached tool count for keyed-tool modules
                            if has_tool_entries then
                                local cached_count = 0
                                for _, entry in ipairs(tool_entries) do
                                    if entry.has_cache then cached_count = cached_count + 1 end
                                end
                                if cached_count > 0 then
                                    tree:leaf(cached_count .. " tool(s) configured", "Comment")
                                end
                            end
                        end)
                    end)
                    -- "Add configuration" sentinel
                    if not proj.orphaned then
                        local project = proj
                        tree:item("▸ Add configuration", {
                            hl = "LoomworksActionable",
                            direct = true,
                            on_enter = function() edit_project_configuration(project, nil) end,
                        })
                    end
                end)
            end

            -- Preset configurations (separate, read-only group)
            if proj.preset_configurations and next(proj.preset_configurations) then
                tree:group("Presets:", "Comment", function()
                    local preset_names = {}
                    for name in pairs(proj.preset_configurations) do
                        preset_names[#preset_names + 1] = name
                    end
                    table.sort(preset_names)
                    for _, pname in ipairs(preset_names) do
                        local pdata = proj.preset_configurations[pname]
                        local brief = {}
                        if pdata.generator then brief[#brief + 1] = pdata.generator end
                        if pdata.toolchain_locked then brief[#brief + 1] = "toolchain" end
                        local brief_str = #brief > 0
                                and ("  (" .. table.concat(brief, ", ") .. ")") or ""
                        tree:leaf(pname .. brief_str .. "  (CMakePresets.json)", "Comment")
                    end
                end)
            end

            -- Launch configurations
            local launches = workspace_view.get_launch_configs(proj)
            if #launches > 0 or not proj.orphaned then
                local project = proj  -- capture for closure
                tree:group("Launch:", "Comment", function()
                    for _, lc in ipairs(launches) do
                        local lname = lc.name
                        local desc = lc.config.command or ""
                        if lc.config.args and #lc.config.args > 0 then
                            desc = desc .. " " .. table.concat(lc.config.args, " ")
                        end
                        tree:item(lname .. "  " .. desc, {
                            hl = "LoomworksActionable",
                            enter_label = "Edit launch config",
                            on_enter = function() edit_launch_config(project, lname) end,
                            on_delete = function() delete_launch_config(project, lname) end,
                        })
                    end
                    tree:item("▸ Add launch config", {
                        hl = "LoomworksActionable",
                        direct = true,
                        on_enter = function() edit_launch_config(project, nil) end,
                    })
                end)
            end

            -- Project-level deploy steps
            local deploy = proj.deploy
            local has_deploy = deploy and next(deploy) ~= nil
            if has_deploy or not proj.orphaned then
                local project = proj  -- capture for closure
                local deploy_mod = require("loomworks.deploy")
                tree:group("Deploy:", "Comment", function()
                    local function format_source(src)
                        local display = src.project or "?"
                        if src.target then display = display .. " : " .. src.target
                        elseif src.path then display = display .. " : " .. src.path end
                        if src.configuration then display = display .. " (" .. src.configuration .. ")" end
                        if src.pre_build then display = display .. " [pre-build]" end
                        return display
                    end

                    -- Work on a deep copy so mutations can be reverted on save failure
                    local function get_editable_copy()
                        return project.deploy and vim.deepcopy(project.deploy) or {}
                    end

                    local function save(new_deploy)
                        if not next(new_deploy) then new_deploy = nil end
                        project:save_deploy(new_deploy)
                    end

                    local dest_keys = {}
                    if deploy then
                        for k in pairs(deploy) do dest_keys[#dest_keys + 1] = k end
                        table.sort(dest_keys)
                    end

                    for _, dest in ipairs(dest_keys) do
                        local sources = deploy_mod.normalize_sources(deploy[dest])
                        local captured_dest = dest
                        -- Destination on its own line (may be long)
                        tree:leaf("  " .. dest, "Comment")
                        for si, src in ipairs(sources) do
                            local captured_si = si
                            tree:item("    <- " .. format_source(src), {
                                hl = "LoomworksActionable",
                                enter_label = "Edit deploy step",
                                on_enter = function()
                                    require("loomworks.ui.deploy_editor").open({
                                        destination = captured_dest,
                                        source = vim.deepcopy(src),
                                        projects = lw.get_projects() or {},
                                        profile = lw.get_active_profile(),
                                        workspace = lw.get_workspace(),
                                        launch_project = project,
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
                            })
                        end
                    end

                    if not proj.orphaned then
                        tree:item("▸ Add deploy step", {
                            hl = "LoomworksActionable",
                            direct = true,
                            on_enter = function()
                                require("loomworks.ui.deploy_editor").open({
                                    destination = "",
                                    source = nil,
                                    projects = lw.get_projects() or {},
                                    profile = lw.get_active_profile(),
                                    workspace = lw.get_workspace(),
                                    launch_project = project,
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
                            end,
                        })
                    end
                end)
            end

            -- Project variables
            local vars = workspace_view.get_variables(proj)
            if #vars > 0 or not proj.orphaned then
                local project = proj  -- capture for closure
                tree:group("Variables:", "Comment", function()
                    for _, v in ipairs(vars) do
                        local vname = v.name  -- capture
                        local display = v.name .. "  (" .. v.type .. ") = " .. v.default
                        tree:item(display, {
                            hl = "LoomworksActionable",
                            enter_label = "Edit variable",
                            on_enter = function() edit_variable(project, vname) end,
                            on_delete = function() delete_variable(project, vname) end,
                        })
                    end
                    tree:item("▸ Add variable", {
                        hl = "LoomworksActionable",
                        direct = true,
                        on_enter = function() edit_variable(project, nil) end,
                    })
                end)
            end

            -- Build environment (cmake_env from type_config)
            local cmake_env = proj.type_config and proj.type_config.cmake_env
            if cmake_env and next(cmake_env) or not proj.orphaned then
                local project = proj  -- capture for closure
                local env = cmake_env or {}
                tree:group("Build environment:", "Comment", function()
                    local keys = {}
                    for k in pairs(env) do keys[#keys + 1] = k end
                    table.sort(keys)
                    for _, k in ipairs(keys) do
                        local ek = k  -- capture
                        tree:item(k .. "=" .. env[k], {
                            hl = "LoomworksActionable",
                            enter_label = "Edit env var",
                            direct = true,
                            on_enter = function()
                                vim.ui.input({ prompt = ek .. "=", default = env[ek] }, function(val)
                                    if not val then return end
                                    local new_env = vim.deepcopy(env)
                                    if val == "" then
                                        new_env[ek] = nil
                                    else
                                        new_env[ek] = val
                                    end
                                    project:save_type_config_field("cmake_env", new_env)
                                end)
                            end,
                            on_delete = function()
                                local new_env = vim.deepcopy(env)
                                new_env[ek] = nil
                                project:save_type_config_field("cmake_env", new_env)
                            end,
                        })
                    end
                    if not proj.orphaned then
                        tree:item("▸ Add env variable", {
                            hl = "LoomworksActionable",
                            direct = true,
                            on_enter = function()
                                vim.ui.input({ prompt = "Variable name: " }, function(name)
                                    if not name or name == "" then return end
                                    vim.ui.input({ prompt = name .. "=" }, function(val)
                                        if not val then return end
                                        local new_env = vim.deepcopy(env)
                                        new_env[name] = val
                                        project:save_type_config_field("cmake_env", new_env)
                                    end)
                                end)
                            end,
                        })
                    end
                end)
            end

            tree:blank()
        end)
    end)

    tree:item("▸ Add project", {
        hl = "LoomworksActionable",
        enter_label = "Add project",
        on_enter = open_add_project,
    })
    tree:blank()
end
