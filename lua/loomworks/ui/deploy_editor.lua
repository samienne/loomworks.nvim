--- loomworks/ui/deploy_editor.lua — Editor for a single deploy step.
---
--- Tree+View dialog for editing a deploy step's destination and source.
--- Projects, configurations and targets are offered as pickers from the
--- workspace view's rows (`loomworks.view.Workspace/1`: the projects, and
--- the profiles' units for the targets and the source preview); the
--- destination is built from segments (variables or literal text) composed
--- into a path, its preview the caller's (`Projects/1.expand_preview`, step
--- 5o C2b2-2), shown once it arrives (path_editor.preview_cache).

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local path_editor = require("loomworks.ui.path_editor")

local M = {}

-- Built-in variable definitions: { var, label, root_only }
-- root_only = true means the variable expands to an absolute path and
-- can only appear as the first segment.
local BUILTIN_VARIABLES = {
    { var = "workspace_root", label = "Workspace root",     root_only = true },
    { var = "build_dir",      label = "Build directory",    root_only = true },
    { var = "project_path",   label = "Project path",       root_only = true },
    { var = "target_dir",     label = "Target directory",   root_only = true },
    { var = "variant",        label = "Variant",            root_only = false },
    { var = "config_set",     label = "Configuration set",  root_only = false },
}

--- Build full variable list including user-defined project variables.
--- `${target_dir}` is offered only when `opts.target_context` says the launch
--- context resolves a build target (spec §8.7: unavailable for a command-type
--- launch).
--- @param project table|nil the launch project with .variables
--- @param opts? { target_context?: boolean }
--- @return table[] variable definitions
function M.build_variable_list(project, opts)
    local vars = {}
    local with_target = opts and opts.target_context
    for _, v in ipairs(BUILTIN_VARIABLES) do
        if v.var ~= "target_dir" or with_target then vars[#vars + 1] = v end
    end
    if project and project.variables then
        local names = {}
        for name in pairs(project.variables) do
            names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local decl = project.variables[name]
            vars[#vars + 1] = {
                var = name,
                label = name,
                root_only = decl.type == "path",
                user_defined = true,
            }
        end
    end
    return vars
end

--- Find variable definition by var name in a variable list.
local function find_var_def(var_name, var_list)
    for _, v in ipairs(var_list) do
        if v.var == var_name then return v end
    end
    return nil
end

--- Parse a destination template string into segments.
--- Segments are either { type="var", var="workspace_root" }
--- or { type="literal", value="some/text" }.
--- @param dest string e.g. "${workspace_root}/Plugins/${variant}/lib.node"
--- @return table[] segments
function M.parse_segments(dest)
    if not dest or dest == "" then return {} end

    local segments = {}
    local pos = 1
    local len = #dest

    while pos <= len do
        if dest:sub(pos, pos + 1) == "${" then
            local close = dest:find("}", pos + 2, true)
            if close then
                local var_name = dest:sub(pos + 2, close - 1)
                segments[#segments + 1] = { type = "var", var = var_name }
                pos = close + 1
                if pos <= len and dest:sub(pos, pos) == "/" then
                    pos = pos + 1
                end
                goto continue
            end
        end

        local next_var = dest:find("${", pos, true)
        local literal
        if next_var then
            literal = dest:sub(pos, next_var - 1)
            pos = next_var
        else
            literal = dest:sub(pos)
            pos = len + 1
        end

        for part in literal:gmatch("[^/]+") do
            segments[#segments + 1] = { type = "literal", value = part }
        end
        -- Preserve trailing / only at the very end of the string (directory
        -- destination marker). Internal trailing slashes before the next
        -- ${var} are separators and must not create empty segments.
        if literal:sub(-1) == "/" and pos > len then
            segments[#segments + 1] = { type = "literal", value = "" }
        end

        ::continue::
    end

    -- A trailing empty literal (from a trailing /) is intentionally kept: it
    -- marks a directory destination.
    return segments
end

--- Compose segments back into a destination template string.
--- @param segments table[]
--- @return string
function M.compose_segments(segments)
    local parts = {}
    for _, seg in ipairs(segments) do
        if seg.type == "var" then
            parts[#parts + 1] = "${" .. seg.var .. "}"
        elseif seg.value ~= "" then
            parts[#parts + 1] = seg.value
        end
    end
    local result = table.concat(parts, "/")
    if #segments > 0 and segments[#segments].type == "literal"
            and segments[#segments].value == "" then
        if result ~= "" then result = result .. "/" end
    end
    return result
end

--- Get display text for a segment.
--- @param seg table segment
--- @param var_list? table[] variable definitions (for label lookup)
local function segment_display(seg, var_list)
    if seg.type == "var" then
        local def = find_var_def(seg.var, var_list or BUILTIN_VARIABLES)
        return def and def.label or seg.var
    end
    if seg.value == "" then return "(trailing /)" end
    return seg.value
end

--- Get highlight for a segment.
local function segment_hl(seg)
    if seg.type == "var" then return "Type" end
    return "LoomworksActionable"
end

--- The active profile's unit row (view `profiles[].units[]`) of the
--- project `project_key` — of the configuration `config_name` when one is
--- named (the profile maps the project to it).
--- @param profiles table[]|nil the view's profile rows
--- @param project_key string
--- @param config_name string "" for the profile's own
--- @return table|nil
local function active_unit(profiles, project_key, config_name)
    for _, prow in ipairs(profiles or {}) do
        if prow.active then
            for _, u in ipairs(prow.units or {}) do
                if u.project == project_key and (config_name == "" or u.configuration == config_name) then
                    return u
                end
            end
            return nil
        end
    end
    return nil
end

--- Build a resolved source preview string (from the active profile's unit
--- row: its build directory and its targets' artifacts).
local function resolve_source_preview(profiles, project_key, config_name, source_type, source_target, source_path)
    if project_key == "" then return nil end
    local unit = active_unit(profiles, project_key, config_name)
    if not unit then return nil end
    local build_dir = unit.build_dir
    if not build_dir then return nil end
    if source_type == "target" and source_target ~= "" then
        if unit.targets and unit.targets[source_target] then
            local artifact = unit.targets[source_target].artifact
            if artifact then
                return require("loomworks.paths").artifact_path(build_dir, artifact)
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
---   source: table|nil — { project: string, target?: string, path?: string, configuration?: string, pre_build?: boolean }
---   projects: table[] — the workspace view's project rows (`key`,
---     `configurations[].key`, `variables`)
---   profiles: table[]|nil — the workspace view's profile rows (their
---     `units[]`: the targets offered, the active one's the source preview)
---   variables: table<string, { type: string }>|nil — the variables of the
---     project owning the step (destination segments)
---   preview: fun(template: string, cb: fun(value: string|nil))|nil — a
---     destination expanded for that project (none: no preview)
---   preview_for: (fun(project_row: table): fun(template: string, cb: fun(value: string|nil)))|nil
---     — the source project's preview (its source path editor)
---   existing_destinations: string[]|nil — destinations already in use (for duplicate detection)
---   current_destination: string|nil — the destination being edited (excluded from duplicate check)
---   target_context: boolean|nil — the launch context may resolve a build
---     target, so the destination picker offers `${target_dir}` (spec §8.7)
---   on_accept: fun(dest: string, source: table)
---   on_cancel: fun()
function M.open(opts)
    local source_project_key = opts.source and opts.source.project or ""
    local source_target = opts.source and opts.source.target or ""
    local source_path = opts.source and opts.source.path or ""
    local source_configuration = opts.source and opts.source.configuration or ""
    local source_pre_build = opts.source and opts.source.pre_build == true
    local source_type = source_target ~= "" and "target" or "path"
    local projects = opts.projects or {}
    local all_variables = M.build_variable_list({ variables = opts.variables },
        { target_context = opts.target_context })

    local dest_segments = M.parse_segments(opts.destination or "")
    local dest_error = nil

    local existing_set = {}
    for _, d in ipairs(opts.existing_destinations or {}) do
        existing_set[d] = true
    end
    local current_dest = opts.current_destination

    local function validate_destination()
        local composed = M.compose_segments(dest_segments)
        if composed == "" then
            dest_error = nil  -- empty will be caught on accept
            return
        end
        if current_dest and composed == current_dest then
            dest_error = nil
            return
        end
        if existing_set[composed] then
            dest_error = "destination already has sources — this will be added to the group"
        else
            dest_error = nil
        end
    end
    validate_destination()

    local accepted = false
    local tree, view
    local dest_preview_of = path_editor.preview_cache(opts.preview, function() if view then view:refresh() end end)

    local function find_project(key)
        for _, p in pairs(projects) do
            if p.key == key then return p end
        end
        return nil
    end

    local function get_config_names(project)
        local names = {}
        for _, cfg in ipairs(project and project.configurations or {}) do
            names[#names + 1] = cfg.key
        end
        table.sort(names)
        return names
    end

    --- The targets the profiles' units of `project` (a view row) know.
    local function get_targets(project)
        local seen = {}
        local result = {}
        for _, prow in ipairs(opts.profiles or {}) do
            for _, unit in ipairs(prow.units or {}) do
                if unit.project == project.key and unit.targets then
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

    --- Show the segment picker.
    --- @param is_first boolean whether this will be the first segment
    --- @param on_done fun(seg: table) callback with the new segment
    local function pick_segment(is_first, on_done)
        local choices = {}
        local choice_map = {}

        for _, vdef in ipairs(all_variables) do
            if not vdef.root_only or is_first then
                local label = vdef.label .. "  (${" .. vdef.var .. "})"
                choices[#choices + 1] = label
                choice_map[label] = { type = "var", var = vdef.var }
            end
        end

        choices[#choices + 1] = "Custom text..."

        vim.ui.select(choices, { prompt = "Path segment:" }, function(choice)
            if not choice then return end
            if choice == "Custom text..." then
                vim.ui.input({ prompt = "Text: " }, function(text)
                    if text and text ~= "" then
                        -- Split by / in case user types "dir/subdir"
                        local parts = {}
                        for part in text:gmatch("[^/]+") do
                            parts[#parts + 1] = { type = "literal", value = part }
                        end
                        on_done(parts)
                    end
                end)
            else
                local seg = choice_map[choice]
                if seg then
                    on_done({ seg })
                end
            end
        end)
    end

    local function render_fn(t)
        t._level = 1

        t:leaf("Deploy Step", "Title")
        t:blank()

        t:leaf("Destination:", "Comment")

        for i, seg in ipairs(dest_segments) do
            local captured_i = i
            local prefix = i == 1 and "  " or "  / "
            t:item(prefix .. segment_display(seg, all_variables) .. " ▸", {
                hl = segment_hl(seg),
                direct = true,
                on_enter = function()
                    if seg.type == "literal" then
                        edit_string("Text: ", seg.value, function(v)
                            if v == "" then
                                table.remove(dest_segments, captured_i)
                            else
                                dest_segments[captured_i] = { type = "literal", value = v }
                            end
                        end)
                    else
                        pick_segment(captured_i == 1, function(new_segs)
                            dest_segments[captured_i] = new_segs[1]
                            for j = 2, #new_segs do
                                table.insert(dest_segments, captured_i + j - 1, new_segs[j])
                            end
                            if view then view:refresh() end
                        end)
                    end
                end,
                on_delete = function()
                    table.remove(dest_segments, captured_i)
                    if view then view:refresh() end
                end,
            })
        end

        t:item("  ▸ Add segment", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                local is_first = #dest_segments == 0
                pick_segment(is_first, function(new_segs)
                    for _, seg in ipairs(new_segs) do
                        dest_segments[#dest_segments + 1] = seg
                    end
                    if view then view:refresh() end
                end)
            end,
        })

        validate_destination()
        local dest_preview = dest_preview_of(M.compose_segments(dest_segments))
        if dest_preview then
            t:leaf("  → " .. dest_preview, "NonText")
        end
        if dest_error then
            t:leaf("  " .. dest_error, "DiagnosticWarn")
        end

        t:blank()
        t:leaf("Source:", "Comment")

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

        local pre_val = source_pre_build and "yes" or "no"
        t:item("  Pre-build      " .. pre_val .. " ▸", {
            hl = source_pre_build and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                source_pre_build = not source_pre_build
                if view then view:refresh() end
            end,
        })

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
                    local src_project = find_project(source_project_key)
                    path_editor.open({
                        title = "Source Path (relative to build dir)",
                        path = source_path,
                        variables = src_project and src_project.variables or nil,
                        preview = src_project and opts.preview_for and opts.preview_for(src_project) or nil,
                        on_accept = function(path)
                            -- Strip build_dir prefix if user picked it
                            path = path:gsub("^%${build_dir}/", "")
                            source_path = path
                            if view then view:refresh() end
                        end,
                        on_cancel = function() end,
                    })
                end,
            })
            t:leaf("  (relative to source build directory)", "NonText")
        end

        local src_preview = resolve_source_preview(
            opts.profiles, source_project_key, source_configuration,
            source_type, source_target, source_path)
        if src_preview then
            t:leaf("  → " .. src_preview, "NonText")
        end

        t:blank()
        t:leaf("[Enter] edit  [D] remove segment  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            local destination = M.compose_segments(dest_segments)
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
            if source_pre_build then
                source.pre_build = true
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
            height = 20,
            zindex = 70,
            backdrop = 70,
            title = " Deploy Step ",
            title_pos = "center",
            wo = {
                wrap = true,
                linebreak = true,
                breakindent = true,
                showbreak = "  ↳ ",
            },
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

return M
