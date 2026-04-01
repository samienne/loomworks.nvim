--- loomworks/ui/deploy_editor.lua — Editor for a single deploy step.
---
--- Tree+View dialog for editing a deploy step's destination and source.
--- Operates on domain objects: projects, configurations, targets are
--- offered as pickers when available. Destination is built from segments
--- (variables or literal text) composed into a path.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local expand = require("loomworks.expand")

local M = {}

-- Variable definitions: { var, label, root_only }
-- root_only = true means the variable expands to an absolute path and
-- can only appear as the first segment.
local VARIABLES = {
    { var = "workspace_root", label = "Workspace root",     root_only = true },
    { var = "build_dir",      label = "Build directory",    root_only = true },
    { var = "project_path",   label = "Project path",       root_only = true },
    { var = "variant",        label = "Variant",            root_only = false },
    { var = "config_set",     label = "Configuration set",  root_only = false },
}

--- Find variable definition by var name.
local function find_var_def(var_name)
    for _, v in ipairs(VARIABLES) do
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
        -- Check for variable reference
        if dest:sub(pos, pos + 1) == "${" then
            local close = dest:find("}", pos + 2, true)
            if close then
                local var_name = dest:sub(pos + 2, close - 1)
                segments[#segments + 1] = { type = "var", var = var_name }
                pos = close + 1
                -- Skip trailing /
                if pos <= len and dest:sub(pos, pos) == "/" then
                    pos = pos + 1
                end
                goto continue
            end
        end

        -- Literal segment: collect until next ${
        local next_var = dest:find("${", pos, true)
        local literal
        if next_var then
            literal = dest:sub(pos, next_var - 1)
            pos = next_var
        else
            literal = dest:sub(pos)
            pos = len + 1
        end

        -- Split literal by / into multiple segments
        -- e.g. "Plugins/lib.node" → ["Plugins", "lib.node"]
        for part in literal:gmatch("[^/]+") do
            segments[#segments + 1] = { type = "literal", value = part }
        end
        -- Preserve trailing / only if this is the end of the entire string
        -- (directory destination marker). Internal trailing slashes before
        -- the next ${var} are just separators and should not create empty segments.
        if literal:sub(-1) == "/" and pos > len then
            segments[#segments + 1] = { type = "literal", value = "" }
        end

        ::continue::
    end

    -- Remove empty trailing literal if it's the only artifact of splitting
    if #segments > 0 and segments[#segments].type == "literal"
            and segments[#segments].value == "" then
        -- Keep it — represents trailing / (directory destination)
    end

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
    -- If last segment was empty literal (trailing /), add it
    if #segments > 0 and segments[#segments].type == "literal"
            and segments[#segments].value == "" then
        if result ~= "" then result = result .. "/" end
    end
    return result
end

--- Get display text for a segment.
local function segment_display(seg)
    if seg.type == "var" then
        local def = find_var_def(seg.var)
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

--- Resolve the config unit for a (project, configuration) pair in a profile.
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
local function resolve_dest_preview(segments, ws, prof, launch_project)
    if not ws or not prof or not launch_project then return nil end
    local template = M.compose_segments(segments)
    if template == "" then return nil end
    local ctx = expand.launch_context(ws, prof, launch_project)
    local resolved = expand.expand_string(template, ctx)
    if resolved:find("%${") then return nil end
    return resolved
end

--- Build a resolved source preview string.
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

    -- Parse destination into segments
    local dest_segments = M.parse_segments(opts.destination or "")

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

    local function get_targets(project)
        local seen = {}
        local result = {}
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

    --- Show the segment picker at a given position.
    --- @param idx number position to insert/replace (0-based: 0 = first)
    --- @param is_first boolean whether this will be the first segment
    --- @param on_done fun(seg: table) callback with the new segment
    local function pick_segment(is_first, on_done)
        local choices = {}
        local choice_map = {}

        -- Variable choices
        for _, vdef in ipairs(VARIABLES) do
            if not vdef.root_only or is_first then
                local label = vdef.label .. "  (${" .. vdef.var .. "})"
                choices[#choices + 1] = label
                choice_map[label] = { type = "var", var = vdef.var }
            end
        end

        -- Custom text option
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

        -- Destination segments
        t:leaf("Destination:", "Comment")

        for i, seg in ipairs(dest_segments) do
            local captured_i = i
            local prefix = i == 1 and "  " or "  / "
            t:item(prefix .. segment_display(seg) .. " ▸", {
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
                        -- Re-pick variable
                        pick_segment(captured_i == 1, function(new_segs)
                            dest_segments[captured_i] = new_segs[1]
                            -- If custom text was multi-part, insert extras
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

        -- Destination preview
        local dest_preview = resolve_dest_preview(
            dest_segments, ws, profile, launch_project)
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
