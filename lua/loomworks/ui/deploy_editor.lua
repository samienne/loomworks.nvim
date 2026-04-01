--- loomworks/ui/deploy_editor.lua — Editor for a single deploy step.
---
--- Tree+View dialog for editing a deploy step's destination and source.
--- Operates on domain objects: projects, configurations, targets are
--- offered as pickers when available. Destination uses a base path picker
--- (workspace root, build dir, etc.) plus a relative path.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local expand = require("loomworks.expand")

local M = {}

-- Known base path options: { variable, display_name }
local BASE_PATHS = {
    { var = "${workspace_root}", label = "Workspace root" },
    { var = "${build_dir}",      label = "Build directory" },
    { var = "${project_path}",   label = "Project path" },
}

--- Parse a destination template into base + relative.
--- @param dest string full destination template
--- @return string base_var the ${variable} prefix, or "" for none
--- @return string rel the relative portion after the base
local function parse_destination(dest)
    for _, bp in ipairs(BASE_PATHS) do
        local prefix = bp.var .. "/"
        if dest == bp.var then
            return bp.var, ""
        elseif dest:sub(1, #prefix) == prefix then
            return bp.var, dest:sub(#prefix + 1)
        end
    end
    return "", dest
end

--- Combine base + relative into a destination template.
--- @param base_var string the ${variable} or ""
--- @param rel string relative path
--- @return string
local function combine_destination(base_var, rel)
    if base_var == "" then return rel end
    if rel == "" then return base_var end
    return base_var .. "/" .. rel
end

--- Find the display label for a base variable.
--- @param base_var string
--- @return string
local function base_label(base_var)
    if base_var == "" then return "(none)" end
    for _, bp in ipairs(BASE_PATHS) do
        if bp.var == base_var then return bp.label end
    end
    return base_var
end

--- Resolve the config unit for a (project, configuration) pair in a profile.
--- @param profile loomworks.Profile
--- @param project loomworks.Project
--- @param config_name string|nil nil means profile default
--- @return loomworks.ConfigUnit|nil
local function resolve_config_unit(profile, project, config_name)
    local pp = profile:project(project.key)
    if not pp or not pp._config_unit then return nil end
    if not config_name or config_name == "" then
        return pp._config_unit
    end
    if pp._config_unit._variant == config_name then
        return pp._config_unit
    end
    return nil
end

--- Build a resolved destination preview string.
--- @param base_var string
--- @param rel string
--- @param ws table|nil workspace
--- @param prof table|nil profile
--- @param launch_project table|nil project
--- @return string|nil
local function resolve_dest_preview(base_var, rel, ws, prof, launch_project)
    if not ws or not prof or not launch_project then return nil end
    local template = combine_destination(base_var, rel)
    if template == "" then return nil end
    local ctx = expand.launch_context(ws, prof, launch_project)
    local resolved = expand.expand_string(template, ctx)
    -- If nothing was expanded (still has ${...}), don't show
    if resolved:find("%${") then return nil end
    return resolved
end

--- Build a resolved source preview string.
--- @param prof table|nil profile
--- @param project table|nil project
--- @param config_name string
--- @param source_type string
--- @param source_target string
--- @param source_path string
--- @return string|nil
local function resolve_source_preview(prof, project, config_name, source_type, source_target, source_path)
    if not prof or not project then return nil end
    local unit = resolve_config_unit(prof, project, config_name)
    if not unit then return nil end
    local build_dir = unit.build_dir_value
    if not build_dir then return nil end
    if source_type == "target" and source_target ~= "" then
        if unit.targets and unit.targets[source_target] then
            local artifact = unit.targets[source_target].artifact
            if artifact then
                return build_dir .. "/" .. artifact
            end
        end
        return build_dir .. "/" .. source_target .. " (?)"
    elseif source_type == "path" and source_path ~= "" then
        return build_dir .. "/" .. source_path
    end
    return nil
end

--- Open the deploy step editor.
--- @param opts table
---   destination: string — destination path template
---   source: table|nil — { project: string, target?: string, path?: string, configuration?: string }
---   projects: loomworks.Project[] — available projects (domain objects)
---   profile: loomworks.Profile|nil — active profile for resolving config units
---   workspace: loomworks.Workspace|nil — for destination preview resolution
---   launch_project: loomworks.Project|nil — the project owning this launch config
---   on_accept: fun(dest: string, source: table)
---   on_cancel: fun()
function M.open(opts)
    local source_project_key = opts.source and opts.source.project or ""
    local source_target = opts.source and opts.source.target or ""
    local source_path = opts.source and opts.source.path or ""
    local source_configuration = opts.source and opts.source.configuration or ""
    local source_type = source_target ~= "" and "target" or "path"
    local projects = opts.projects or {}
    local profile = opts.profile
    local ws = opts.workspace
    local launch_project = opts.launch_project

    -- Parse destination into base + relative
    local dest_base, dest_rel = parse_destination(opts.destination or "")

    local accepted = false
    local tree, view

    local function find_project(key)
        for _, p in pairs(projects) do
            if p.key == key then return p end
        end
        return nil
    end

    local function get_config_names(project)
        if not project or not project._configurations then return {} end
        local names = {}
        for _, cfg in ipairs(project._configurations) do
            if not cfg._removed then
                names[#names + 1] = cfg.name
            end
        end
        table.sort(names)
        return names
    end

    --- Get targets from all config units for a project (union).
    --- Different configurations may have different targets parsed; taking
    --- the union maximizes what's available in the picker.
    local function get_targets(project)
        local seen = {}
        local result = {}
        -- Walk all config units in the workspace that belong to this project
        local ws_units = ws and ws._config_units or {}
        for _, unit in pairs(ws_units) do
            if unit._project == project and unit.targets then
                for id, target in pairs(unit.targets) do
                    if not seen[id] then
                        seen[id] = true
                        result[#result + 1] = {
                            id = id,
                            display = id .. "  (" .. (target.type or "?") .. ")",
                        }
                    end
                end
            end
        end
        table.sort(result, function(a, b) return a.id < b.id end)
        return result
    end

    local function edit_string(prompt, current, on_done)
        vim.ui.input({
            prompt = prompt,
            default = current,
        }, function(value)
            if value then
                on_done(value)
                if view then view:refresh() end
            end
        end)
    end

    local function render_fn(t)
        t._level = 1

        t:leaf("Deploy Step", "Title")
        t:blank()

        -- Destination: base path picker
        t:leaf("Destination:", "Comment")
        t:item("  Base path      " .. base_label(dest_base) .. " ▸", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                local choices = { "(none)" }
                for _, bp in ipairs(BASE_PATHS) do
                    choices[#choices + 1] = bp.label
                end
                vim.ui.select(choices, { prompt = "Base path:" }, function(choice)
                    if not choice then return end
                    if choice == "(none)" then
                        dest_base = ""
                    else
                        for _, bp in ipairs(BASE_PATHS) do
                            if bp.label == choice then
                                dest_base = bp.var
                                break
                            end
                        end
                    end
                    if view then view:refresh() end
                end)
            end,
        })

        -- Destination: relative path
        local rel_val = dest_rel ~= "" and dest_rel or "(empty)"
        t:item("  Relative path  " .. rel_val .. " ▸", {
            hl = dest_rel ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Relative path: ", dest_rel, function(v)
                    dest_rel = v
                end)
            end,
        })

        -- Destination preview
        local dest_preview = resolve_dest_preview(
            dest_base, dest_rel, ws, profile, launch_project)
        if dest_preview then
            t:leaf("  → " .. dest_preview, "NonText")
        end

        t:blank()
        t:leaf("Source:", "Comment")

        -- Project picker
        local proj_val = source_project_key ~= "" and source_project_key or "(none)"
        t:item("  Project        " .. proj_val .. " ▸", {
            hl = source_project_key ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                local keys = {}
                for _, p in pairs(projects) do
                    keys[#keys + 1] = p.key
                end
                table.sort(keys)
                if #keys == 0 then
                    vim.notify("loomworks: no projects available", vim.log.levels.WARN)
                    return
                end
                vim.ui.select(keys, { prompt = "Source project:" }, function(choice)
                    if choice then
                        source_project_key = choice
                        source_target = ""
                        source_path = ""
                        if view then view:refresh() end
                    end
                end)
            end,
        })

        -- Configuration picker
        local cfg_val = source_configuration ~= ""
            and source_configuration or "(profile default)"
        t:item("  Configuration  " .. cfg_val .. " ▸", {
            hl = source_configuration ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                local project = find_project(source_project_key)
                if not project then
                    vim.notify("loomworks: select a project first", vim.log.levels.WARN)
                    return
                end
                local names = get_config_names(project)
                table.insert(names, 1, "(profile default)")
                vim.ui.select(names, { prompt = "Configuration:" }, function(choice)
                    if choice then
                        if choice == "(profile default)" then
                            source_configuration = ""
                        else
                            source_configuration = choice
                        end
                        source_target = ""
                        if view then view:refresh() end
                    end
                end)
            end,
            on_delete = function()
                source_configuration = ""
                if view then view:refresh() end
            end,
        })

        -- Source type toggle
        t:item("  Type           " .. source_type .. " ▸", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                vim.ui.select({ "target", "path" }, {
                    prompt = "Source type:",
                }, function(choice)
                    if choice then
                        source_type = choice
                        if choice == "target" then
                            source_path = ""
                        else
                            source_target = ""
                        end
                        if view then view:refresh() end
                    end
                end)
            end,
        })

        -- Target picker or path input
        if source_type == "target" then
            local tgt_val = source_target ~= "" and source_target or "(none)"
            t:item("  Target         " .. tgt_val .. " ▸", {
                hl = source_target ~= "" and "LoomworksActionable" or "Comment",
                direct = true,
                on_enter = function()
                    local project = find_project(source_project_key)
                    if not project then
                        vim.notify("loomworks: select a project first", vim.log.levels.WARN)
                        return
                    end
                    local targets = get_targets(project)
                    if #targets > 0 then
                        local displays = {}
                        for _, tgt in ipairs(targets) do
                            displays[#displays + 1] = tgt.display
                        end
                        vim.ui.select(displays, { prompt = "Target:" }, function(choice, idx)
                            if choice and idx then
                                source_target = targets[idx].id
                                if view then view:refresh() end
                            end
                        end)
                    else
                        edit_string("Target name: ", source_target, function(v)
                            source_target = v
                        end)
                    end
                end,
            })
        else
            local path_val = source_path ~= "" and source_path or "(empty)"
            t:item("  Path           " .. path_val .. " ▸", {
                hl = source_path ~= "" and "LoomworksActionable" or "Comment",
                direct = true,
                on_enter = function()
                    edit_string("Path (relative to build dir): ", source_path, function(v)
                        source_path = v
                    end)
                end,
            })
        end

        -- Source preview
        local src_project = find_project(source_project_key)
        local src_preview = resolve_source_preview(
            profile, src_project, source_configuration,
            source_type, source_target, source_path)
        if src_preview then
            t:leaf("  → " .. src_preview, "NonText")
        end

        t:blank()
        t:leaf("[Enter] change  [D] clear config  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            local destination = combine_destination(dest_base, dest_rel)
            if destination == "" then
                vim.notify("loomworks: destination cannot be empty", vim.log.levels.ERROR)
                return {}
            end
            if source_project_key == "" then
                vim.notify("loomworks: source project is required", vim.log.levels.ERROR)
                return {}
            end
            local has_target = source_type == "target" and source_target ~= ""
            local has_path = source_type == "path" and source_path ~= ""
            if not has_target and not has_path then
                vim.notify("loomworks: source target or path is required", vim.log.levels.ERROR)
                return {}
            end

            accepted = true
            view:close()

            local source = { project = source_project_key }
            if source_type == "target" then
                source.target = source_target
            else
                source.path = source_path
            end
            if source_configuration ~= "" then
                source.configuration = source_configuration
            end

            opts.on_accept(destination, source)
            return {}
        end
        return orig_on_key(self, action, line)
    end

    local parent_win = vim.api.nvim_get_current_win()

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = 80,
            height = 18,
            zindex = 70,
            backdrop = 70,
            title = " Deploy Step ",
            title_pos = "center",
        },
        keymaps = {
            ["<CR>"]    = "enter",
            ["D"]       = "delete",
            ["y"]       = "accept",
        },
        events = {},
        on_close = function()
            if parent_win and vim.api.nvim_win_is_valid(parent_win) then
                vim.api.nvim_set_current_win(parent_win)
            end
            if not accepted then
                opts.on_cancel()
            end
        end,
    })

    view:open()
end

--- Exported for testing.
M._parse_destination = parse_destination
M._combine_destination = combine_destination

return M
