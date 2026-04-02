--- loomworks/ui/path_editor.lua — Reusable segment-based path editor dialog.
---
--- Builds a path from segments: variables (${workspace_root}, ${variant}, etc.)
--- or literal text. Shows resolved preview. Used by deploy editor, launch
--- editor working_dir, and anywhere a variable-expanded path is needed.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local expand = require("loomworks.expand")

local M = {}

-- Built-in variable definitions
local BUILTIN_VARIABLES = {
    { var = "workspace_root", label = "Workspace root",     root_only = true },
    { var = "build_dir",      label = "Build directory",    root_only = true },
    { var = "project_path",   label = "Project path",       root_only = true },
    { var = "variant",        label = "Variant",            root_only = false },
    { var = "config_set",     label = "Configuration set",  root_only = false },
}

--- Build variable list including user-defined project variables.
--- @param project table|nil project with .variables
--- @return table[]
function M.build_variable_list(project)
    local vars = {}
    for _, v in ipairs(BUILTIN_VARIABLES) do
        vars[#vars + 1] = v
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

--- Find variable definition by name.
local function find_var_def(var_name, var_list)
    for _, v in ipairs(var_list) do
        if v.var == var_name then return v end
    end
    return nil
end

--- Parse a path template string into segments.
--- @param path string e.g. "${workspace_root}/Plugins/${variant}/lib.node"
--- @return table[] segments
function M.parse_segments(path)
    if not path or path == "" then return {} end

    local segments = {}
    local pos = 1
    local len = #path

    while pos <= len do
        if path:sub(pos, pos + 1) == "${" then
            local close = path:find("}", pos + 2, true)
            if close then
                local var_name = path:sub(pos + 2, close - 1)
                segments[#segments + 1] = { type = "var", var = var_name }
                pos = close + 1
                if pos <= len and path:sub(pos, pos) == "/" then
                    pos = pos + 1
                end
                goto continue
            end
        end

        local next_var = path:find("${", pos, true)
        local literal
        if next_var then
            literal = path:sub(pos, next_var - 1)
            pos = next_var
        else
            literal = path:sub(pos)
            pos = len + 1
        end

        for part in literal:gmatch("[^/]+") do
            segments[#segments + 1] = { type = "literal", value = part }
        end
        if literal:sub(-1) == "/" and pos > len then
            segments[#segments + 1] = { type = "literal", value = "" }
        end

        ::continue::
    end

    return segments
end

--- Compose segments back into a path template string.
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

--- Open the path editor dialog.
--- @param opts table
---   title?: string — dialog title
---   path: string — initial path template
---   project?: loomworks.Project — for user-defined variables
---   workspace?: loomworks.Workspace — for preview resolution
---   profile?: loomworks.Profile — for preview resolution
---   on_accept: fun(path: string) — called with composed path
---   on_cancel: fun()
function M.open(opts)
    local segments = M.parse_segments(opts.path or "")
    local all_variables = M.build_variable_list(opts.project)
    local ws = opts.workspace
    local profile = opts.profile
    local project = opts.project

    local accepted = false
    local tree, view

    local function edit_string(prompt, current, on_done)
        vim.ui.input({ prompt = prompt, default = current }, function(value)
            if value then
                on_done(value)
                if view then view:refresh() end
            end
        end)
    end

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
                        local parts = {}
                        for part in text:gmatch("[^/]+") do
                            parts[#parts + 1] = { type = "literal", value = part }
                        end
                        on_done(parts)
                    end
                end)
            else
                local seg = choice_map[choice]
                if seg then on_done({ seg }) end
            end
        end)
    end

    local function render_fn(t)
        t._level = 1
        t:leaf(opts.title or "Path", "Title")
        t:blank()

        for i, seg in ipairs(segments) do
            local captured_i = i
            local prefix = i == 1 and "  " or "  / "
            t:item(prefix .. segment_display(seg, all_variables) .. " ▸", {
                hl = segment_hl(seg),
                direct = true,
                on_enter = function()
                    if seg.type == "literal" then
                        edit_string("Text: ", seg.value, function(v)
                            if v == "" then
                                table.remove(segments, captured_i)
                            else
                                segments[captured_i] = { type = "literal", value = v }
                            end
                        end)
                    else
                        pick_segment(captured_i == 1, function(new_segs)
                            segments[captured_i] = new_segs[1]
                            for j = 2, #new_segs do
                                table.insert(segments, captured_i + j - 1, new_segs[j])
                            end
                            if view then view:refresh() end
                        end)
                    end
                end,
                on_delete = function()
                    table.remove(segments, captured_i)
                    if view then view:refresh() end
                end,
            })
        end

        t:item("  ▸ Add segment", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                pick_segment(#segments == 0, function(new_segs)
                    for _, seg in ipairs(new_segs) do
                        segments[#segments + 1] = seg
                    end
                    if view then view:refresh() end
                end)
            end,
        })

        -- Preview
        if ws and profile and project then
            local template = M.compose_segments(segments)
            if template ~= "" then
                local ctx = expand.launch_context(ws, profile, project)
                local resolved = expand.expand_string(template, ctx)
                if not resolved:find("%${") then
                    t:leaf("  → " .. resolved, "NonText")
                end
            end
        end

        t:blank()
        t:leaf("[Enter] edit  [D] remove  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            accepted = true
            view:close()
            opts.on_accept(M.compose_segments(segments))
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
            height = 16,
            zindex = 75,
            backdrop = 75,
            title = " " .. (opts.title or "Path") .. " ",
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
