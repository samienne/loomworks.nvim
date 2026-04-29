--- loomworks/ui/v2/view/layout.lua — Two-pane vertical layout.
---
--- Opens a new tab with two windows side by side: overview (left) and
--- inspector (right). Each pane has its own scratch buffer. Subscribes
--- to the view model and re-renders on change. Tracks cursor moves on
--- the overview window and dispatches `cursor_to` to the view model.
---
--- Read-only in this slice. No editing, no extmarks, no highlights.
--- Filetype is `loomworks-v2` so users can target it for syntax later.

local overview_view  = require("loomworks.ui.v2.view.overview_view")
local inspector_view = require("loomworks.ui.v2.view.inspector_view")
local activity_view  = require("loomworks.ui.v2.view.activity_view")

--- @class loomworks.uiv2.Layout
--- @field _vm loomworks.uiv2.ViewModel
--- @field _overview_buf integer|nil
--- @field _inspector_buf integer|nil
--- @field _activity_buf integer|nil
--- @field _overview_win integer|nil
--- @field _inspector_win integer|nil
--- @field _activity_win integer|nil
--- @field _tabpage integer|nil
--- @field _line_map table<integer, { section: integer, row: integer }>
--- @field _section_line_map table<integer, string>
--- @field _overview_add_map table<integer, table>
--- @field _inspector_drill_map table<integer, table>
--- @field _inspector_edit_map table<integer, table>
--- @field _inspector_add_map table<integer, table>
--- @field _unsubscribe (fun())|nil
--- @field _refresh_scheduled boolean
--- @field _autocmd_group integer|nil
--- @field _suppress_cursor boolean
local Layout = {}
Layout.__index = Layout

local FILETYPE = "loomworks-v2"

--- @param vm loomworks.uiv2.ViewModel
--- @return loomworks.uiv2.Layout
function Layout.new(vm)
    return setmetatable({
        _vm = vm,
        _overview_buf = nil,
        _inspector_buf = nil,
        _activity_buf = nil,
        _overview_win = nil,
        _inspector_win = nil,
        _activity_win = nil,
        _tabpage = nil,
        _line_map = {},
        _section_line_map = {},
        _overview_add_map = {},
        _inspector_drill_map = {},
        _inspector_edit_map = {},
        _inspector_add_map = {},
        _unsubscribe = nil,
        _refresh_scheduled = false,
        _autocmd_group = nil,
        _suppress_cursor = false,
    }, Layout)
end

local function valid_win(win)
    return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
end

local function set_buf_options(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = FILETYPE
    pcall(vim.api.nvim_buf_set_name, buf, name)
end

local function set_win_options(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixbuf = true
end

--- @return boolean
function Layout:is_open()
    return valid_win(self._overview_win)
        and valid_win(self._inspector_win)
        and valid_win(self._activity_win)
end

function Layout:_setup_keymaps(buf, kind)
    local function map(key, fn)
        vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
    end
    map("q", function() self:close() end)
    if kind == "overview" then
        map("o",     function() self:_toggle_current_section() end)
        map("<CR>",  function() self:_select_or_toggle_under_cursor() end)
        map("a",     function() self._vm:dispatch("act_under_cursor", { action = "activate"  }) end)
        map("b",     function() self._vm:dispatch("act_under_cursor", { action = "build"     }) end)
        map("c",     function() self._vm:dispatch("act_under_cursor", { action = "configure" }) end)
        map("D",     function() self:_confirm_then_dispatch("delete") end)
        map("C",     function() self:_confirm_then_dispatch("clean")  end)
    elseif kind == "inspector" then
        map("<CR>", function() self:_drill_inspector_under_cursor() end)
        map("e",    function() self:_edit_inspector_under_cursor() end)
        map("E",    function() self:_open_wire_form_for_subject() end)
        map("D",    function() self:_confirm_then_delete_inspector_subject() end)
    end
end

--- Open wire-mode editor for the inspector's current subject when applicable.
--- Currently supports deploy_step → wire_deploy.
function Layout:_open_wire_form_for_subject()
    local p = self._vm:presentation()
    local insp = p.inspector
    if not insp or insp.missing then return end
    if insp.kind == "deploy_step" then
        self._vm:dispatch("open_wire_deploy_edit", {
            subject = {
                kind = "deploy_step",
                project_key = insp.project_key,
                launch_name = insp.launch_name,
                destination = insp.subject,
            },
        })
    end
end

--- Confirm + dispatch deletion of whatever the inspector is showing.
function Layout:_confirm_then_delete_inspector_subject()
    local p = self._vm:presentation()
    local insp = p.inspector
    if not insp or insp.kind == "empty" or insp.missing then return end
    -- Limit to kinds the view model can delete.
    local supported = {
        deploy_step = true, variable = true, launch = true, configuration = true,
    }
    if not supported[insp.kind] then return end
    local desc
    if insp.kind == "deploy_step" then
        desc = string.format("delete deploy step '%s' from %s.%s?",
            insp.subject, insp.project_key, insp.launch_name)
    elseif insp.kind == "variable" then
        desc = string.format("delete variable '%s' from project '%s'?",
            insp.subject, insp.project_key)
    elseif insp.kind == "launch" then
        desc = string.format("delete launch '%s' from project '%s'?",
            insp.subject, insp.project_key)
    elseif insp.kind == "configuration" then
        desc = string.format("delete configuration '%s' from project '%s'?",
            insp.subject, insp.project_key)
    end
    if vim.fn.confirm(desc, "&Yes\n&No", 2) == 1 then
        self._vm:dispatch("delete_inspector_subject")
    end
end

--- Resolve the inspector cursor's line. If it points at an editable
--- field, prompt (or toggle for booleans) and dispatch set_field.
--- Otherwise fall back to cycling publish for the current subject.
function Layout:_edit_inspector_under_cursor()
    if not valid_win(self._inspector_win) then return end
    local row = vim.api.nvim_win_get_cursor(self._inspector_win)[1]
    local field = self._inspector_edit_map[row]
    if field then
        if field.kind == "boolean" then
            -- Toggle directly without prompting.
            local current = field.value
            local was_true = current == true or current == "true" or current == "1"
            self._vm:dispatch("set_field", {
                subject  = field.subject,
                field_id = field.id,
                value    = (not was_true) and "true" or "false",
            })
            return
        end
        if field.kind == "picker" and type(field.choices) == "table" and #field.choices > 0 then
            local prompt = "Pick " .. (field.label or field.id or "value")
            vim.ui.select(field.choices, { prompt = prompt }, function(choice)
                if choice == nil then return end -- cancelled
                self._vm:dispatch("set_field", {
                    subject  = field.subject,
                    field_id = field.id,
                    value    = choice,
                })
            end)
            return
        end
        local prompt = (field.label or field.id or "value") .. ": "
        vim.ui.input({ prompt = prompt, default = tostring(field.value or "") }, function(input)
            if input == nil then return end -- cancelled
            self._vm:dispatch("set_field", {
                subject  = field.subject,
                field_id = field.id,
                value    = input,
            })
        end)
        return
    end
    -- No editable field under cursor → fall back to publish cycle
    -- when the inspector subject is publishable.
    self._vm:dispatch("cycle_publish")
end

--- Show a yes/no confirmation, then dispatch the action on yes.
--- @param action_name "delete"|"clean"
function Layout:_confirm_then_dispatch(action_name)
    local target = self._vm:resolve_action_target()
    if not target then return end
    local desc
    if target.kind == "profile" then
        desc = string.format("%s profile '%s'?", action_name, target.target.key)
    elseif target.kind == "config_unit" then
        local pkey = target.target:project() and target.target:project().key or "?"
        local ckey = target.target:config_key() or target.target.id or "?"
        desc = string.format("%s config %s/%s?", action_name, pkey, ckey)
    elseif target.kind == "orphan_config" then
        desc = string.format("delete orphaned cache entry '%s'?", tostring(target.target))
    else
        return
    end
    local ok = vim.fn.confirm(desc, "&Yes\n&No", 2) == 1
    if ok then
        self._vm:dispatch("act_under_cursor", { action = action_name })
    end
end

--- Drill into whatever ref is at the inspector cursor's current line, or
--- trigger an Add flow if the line is an "+ Add ..." sentinel.
function Layout:_drill_inspector_under_cursor()
    if not valid_win(self._inspector_win) then return end
    local row = vim.api.nvim_win_get_cursor(self._inspector_win)[1]
    -- Add sentinels take precedence — they're not selectable refs.
    local add = self._inspector_add_map[row]
    if add then
        self:_handle_add(add)
        return
    end
    local ref = self._inspector_drill_map[row]
    if ref then
        self._vm:dispatch("drill_in", { ref = ref })
    end
end

--- Prompt for the minimal info required and dispatch add_item.
--- Defaults are sensible; user can edit other fields with `e` afterward.
--- @param descriptor table { kind, parent }
function Layout:_handle_add(descriptor)
    -- Wire-form commit actions emitted as sentinels with synthetic kinds.
    if descriptor.kind == "wire_save" then
        self._vm:dispatch("wire_save")
        return
    elseif descriptor.kind == "wire_cancel" then
        self._vm:dispatch("wire_cancel")
        return
    end
    if descriptor.kind == "deploy_step" then
        -- + Add deploy step now opens wire mode instead of chaining prompts.
        self._vm:dispatch("open_wire_deploy_add", { parent = descriptor.parent })
        return
    end
    -- Workspace-level adds with extra picker chains.
    if descriptor.kind == "project" and descriptor.parent and descriptor.parent.kind == "workspace" then
        self:_handle_add_project(descriptor)
        return
    end
    if descriptor.kind == "config_set" and descriptor.parent and descriptor.parent.kind == "workspace" then
        vim.ui.input({ prompt = "New configuration set name: " }, function(name)
            if not name or name == "" then return end
            self._vm:dispatch("add_item", {
                kind   = descriptor.kind,
                parent = descriptor.parent,
                name   = name,
            })
        end)
        return
    end
    local prompt
    if descriptor.kind == "variable" then
        prompt = "New variable name: "
    elseif descriptor.kind == "launch" then
        prompt = "New launch name: "
    elseif descriptor.kind == "configuration" then
        prompt = "New configuration name: "
    elseif descriptor.kind == "launch_arg" then
        prompt = "New arg value: "
    elseif descriptor.kind == "launch_env" then
        prompt = "New env variable name: "
    else
        return
    end
    vim.ui.input({ prompt = prompt }, function(name)
        if not name or name == "" then return end
        self._vm:dispatch("add_item", {
            kind   = descriptor.kind,
            parent = descriptor.parent,
            name   = name,
        })
    end)
end

--- Prompt for the data needed to add a project at the workspace level.
--- Asks for name, then picks the type from registered modules.
--- @param descriptor table { kind = "project", parent = { kind = "workspace" } }
function Layout:_handle_add_project(descriptor)
    vim.ui.input({ prompt = "New project name (also default path): " }, function(name)
        if not name or name == "" then return end
        local ok, modules = pcall(require, "loomworks.modules")
        local types = ok and modules.list and modules.list() or {}
        if #types == 0 then
            self._vm:dispatch("add_item", {
                kind = descriptor.kind, parent = descriptor.parent, name = name,
                extra = { type = "cmake" },
            })
            return
        end
        vim.ui.select(types, { prompt = "Project type" }, function(t)
            if not t then return end
            self._vm:dispatch("add_item", {
                kind = descriptor.kind, parent = descriptor.parent, name = name,
                extra = { type = t },
            })
        end)
    end)
end

--- Chained prompts for adding a deploy step. Asks for destination,
--- source project, and target/path. pre_build defaults to false; can be
--- toggled via `e` later.
--- @param descriptor table { kind = "deploy_step", parent }
function Layout:_handle_add_deploy_step(descriptor)
    vim.ui.input({ prompt = "Destination path (use ${build_dir}, ${project_path}, ...): " },
    function(destination)
        if not destination or destination == "" then return end
        vim.ui.input({ prompt = "Source project key: " }, function(src_project)
            if not src_project or src_project == "" then return end
            vim.ui.input({ prompt = "Target name (or empty for path): " }, function(target)
                if target == nil then return end
                if target ~= "" then
                    self._vm:dispatch("add_item", {
                        kind   = descriptor.kind,
                        parent = descriptor.parent,
                        name   = destination,
                        extra  = { source_project = src_project, target = target },
                    })
                    return
                end
                vim.ui.input({ prompt = "Source path (relative to source build dir): " },
                function(path)
                    if not path or path == "" then return end
                    self._vm:dispatch("add_item", {
                        kind   = descriptor.kind,
                        parent = descriptor.parent,
                        name   = destination,
                        extra  = { source_project = src_project, path = path },
                    })
                end)
            end)
        end)
    end)
end

--- Toggle the section currently under the overview cursor.
function Layout:_toggle_current_section()
    if not valid_win(self._overview_win) then return end
    local row = vim.api.nvim_win_get_cursor(self._overview_win)[1]
    local section_kind = self._section_line_map[row]
    if section_kind then
        self._vm:dispatch("toggle_section", { kind = section_kind })
    end
end

--- `<CR>` in overview: triage the row under the cursor —
---   1. add sentinel  → run the add flow
---   2. selectable    → select + open inspector
---   3. section line  → toggle expand/collapse
function Layout:_select_or_toggle_under_cursor()
    if not valid_win(self._overview_win) then return end
    local row = vim.api.nvim_win_get_cursor(self._overview_win)[1]
    local add = self._overview_add_map[row]
    if add then
        self:_handle_add(add)
        return
    end
    if self._line_map[row] then
        self._vm:dispatch("select_under_cursor")
        return
    end
    local section_kind = self._section_line_map[row]
    if section_kind then
        self._vm:dispatch("toggle_section", { kind = section_kind })
    end
end

function Layout:_install_cursor_autocmd()
    if self._autocmd_group then
        vim.api.nvim_del_augroup_by_id(self._autocmd_group)
    end
    self._autocmd_group = vim.api.nvim_create_augroup("loomworks_uiv2_layout", { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = self._autocmd_group,
        buffer = self._overview_buf,
        callback = function()
            if self._suppress_cursor then return end
            self:_on_cursor_moved()
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = self._autocmd_group,
        buffer = self._overview_buf,
        callback = function() self:close() end,
    })
end

function Layout:_on_cursor_moved()
    if not valid_win(self._overview_win) then return end
    local row = vim.api.nvim_win_get_cursor(self._overview_win)[1]
    local ref = self._line_map[row]
    if ref then
        self._vm:dispatch("cursor_to", ref)
    end
end

function Layout:open()
    if self:is_open() then
        vim.api.nvim_set_current_win(self._overview_win)
        return
    end

    -- Open in a new tab so we don't disturb existing layouts.
    vim.cmd("tabnew")
    self._tabpage = vim.api.nvim_get_current_tabpage()

    -- Replace the empty buffer of the new tab with our overview buffer.
    self._overview_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(self._overview_buf, "loomworks://overview")
    self._overview_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._overview_win, self._overview_buf)
    set_win_options(self._overview_win)

    -- Vertical split for inspector on the right.
    vim.cmd("rightbelow vsplit")
    self._inspector_win = vim.api.nvim_get_current_win()
    self._inspector_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(self._inspector_buf, "loomworks://inspector")
    vim.api.nvim_win_set_buf(self._inspector_win, self._inspector_buf)
    set_win_options(self._inspector_win)

    -- Bottom-spanning horizontal split for the activity strip.
    vim.cmd("botright split")
    self._activity_win = vim.api.nvim_get_current_win()
    self._activity_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(self._activity_buf, "loomworks://activity")
    vim.api.nvim_win_set_buf(self._activity_win, self._activity_buf)
    set_win_options(self._activity_win)
    -- Keep the strip compact: ~25% of viewport height, capped at 12 lines.
    local strip_h = math.min(12, math.max(6, math.floor(vim.o.lines * 0.25)))
    pcall(vim.api.nvim_win_set_height, self._activity_win, strip_h)

    -- Width split for the top: focus overview, set ~40/60.
    vim.api.nvim_set_current_win(self._overview_win)
    local total = vim.o.columns
    local target = math.floor(total * 0.40)
    if target > 20 then
        pcall(vim.api.nvim_win_set_width, self._overview_win, target)
    end

    self:_setup_keymaps(self._overview_buf, "overview")
    self:_setup_keymaps(self._inspector_buf, "inspector")
    self:_setup_keymaps(self._activity_buf, "activity")

    self._unsubscribe = self._vm:subscribe(function() self:schedule_refresh() end)
    self:_install_cursor_autocmd()
    self:refresh()

    -- On first open, snap the cursor to the first selectable line in the
    -- overview (typically the active-profile row). Without this the cursor
    -- lands on the workspace-name header which is not selectable.
    self:_snap_to_first_selectable()
end

--- Snap overview cursor to the first selectable row and seed the inspector.
--- Without this, the inspector stays empty until the user presses <CR>;
--- on first open we want it to show the active profile (the natural
--- starting point of the workspace view).
function Layout:_snap_to_first_selectable()
    if not valid_win(self._overview_win) then return end
    local first
    for l = 1, vim.api.nvim_buf_line_count(self._overview_buf) do
        if self._line_map[l] then first = l; break end
    end
    if first then
        self._suppress_cursor = true
        pcall(vim.api.nvim_win_set_cursor, self._overview_win, { first, 0 })
        self._suppress_cursor = false
        -- Sync the view model's cursor and explicitly select that row so
        -- the inspector populates on first open.
        self:_on_cursor_moved()
        self._vm:dispatch("select_under_cursor")
    end
end

function Layout:close()
    if self._unsubscribe then
        self._unsubscribe()
        self._unsubscribe = nil
    end
    if self._autocmd_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._autocmd_group)
        self._autocmd_group = nil
    end
    -- Close the entire tabpage (this disposes both windows).
    if self._tabpage and vim.api.nvim_tabpage_is_valid(self._tabpage) then
        local current = vim.api.nvim_get_current_tabpage()
        if current == self._tabpage then
            pcall(vim.cmd, "tabclose")
        else
            -- Find tab number and close it
            for i, tp in ipairs(vim.api.nvim_list_tabpages()) do
                if tp == self._tabpage then
                    pcall(vim.cmd, i .. "tabclose")
                    break
                end
            end
        end
    end
    -- Wipeout buffers if they still exist.
    if valid_buf(self._overview_buf) then
        pcall(vim.api.nvim_buf_delete, self._overview_buf, { force = true })
    end
    if valid_buf(self._inspector_buf) then
        pcall(vim.api.nvim_buf_delete, self._inspector_buf, { force = true })
    end
    if valid_buf(self._activity_buf) then
        pcall(vim.api.nvim_buf_delete, self._activity_buf, { force = true })
    end
    self._overview_buf, self._inspector_buf, self._activity_buf = nil, nil, nil
    self._overview_win, self._inspector_win, self._activity_win = nil, nil, nil
    self._tabpage = nil
    self._line_map = {}
    self._section_line_map = {}
    self._overview_add_map = {}
    self._inspector_drill_map = {}
    self._inspector_edit_map = {}
    self._inspector_add_map = {}
end

function Layout:toggle()
    if self:is_open() then self:close() else self:open() end
end

function Layout:schedule_refresh()
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    vim.schedule(function()
        self._refresh_scheduled = false
        if self:is_open() then self:refresh() end
    end)
end

--- True if two refs name the same target.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function ref_eq(a, b)
    if not a or not b then return false end
    if a.kind ~= b.kind then return false end
    if a.key ~= b.key then return false end
    if a.project_key ~= b.project_key then return false end
    if a.config_name ~= b.config_name then return false end
    if a.launch_name ~= b.launch_name then return false end
    if a.var_name ~= b.var_name then return false end
    if a.destination ~= b.destination then return false end
    return true
end

--- Set buffer lines and apply per-line highlights via extmarks.
--- @param buf integer
--- @param lines string[]
--- @param highlights table[]   { line, col_start, col_end, hl_group } (1-based line)
--- @param hint_bar table[]|nil { key, label } pairs to render below the last line
--- @param ns integer namespace
local function set_buf_content(buf, lines, highlights, hint_bar, ns)
    if not valid_buf(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    for _, h in ipairs(highlights or {}) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line - 1, h.col_start, {
            end_col = h.col_end,
            hl_group = h.hl_group,
        })
    end

    if hint_bar and #hint_bar > 0 and #lines > 0 then
        local parts = {}
        for _, h in ipairs(hint_bar) do
            parts[#parts + 1] = "[" .. h.key .. "] " .. h.label
        end
        local hint_text = table.concat(parts, "  ")
        local sep = string.rep("─", math.min(#hint_text, 60))
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, #lines - 1, 0, {
            virt_lines = {
                { { sep,        "Comment" } },
                { { hint_text, "Comment" } },
            },
            virt_lines_above = false,
        })
    end
end

function Layout:_namespace()
    if not self._ns then
        self._ns = vim.api.nvim_create_namespace("loomworks_uiv2")
    end
    return self._ns
end

function Layout:refresh()
    if not self:is_open() then return end
    local p = self._vm:presentation()
    local ns = self:_namespace()

    -- Render overview
    local lines, highlights, line_map, section_line_map, add_line_map =
        overview_view.render(p.overview, p.selection)
    self._line_map = line_map
    self._section_line_map = section_line_map
    self._overview_add_map = add_line_map or {}
    set_buf_content(self._overview_buf, lines, highlights,
        p.overview and p.overview.hint_bar, ns)

    -- Pin marker: locate the line whose ref matches the pinned ref.
    if p.selection and p.selection.pinned and valid_buf(self._overview_buf) then
        for line_no, sec_row in pairs(line_map) do
            local section = p.overview.sections[sec_row.section]
            local ref = section and section.selectable and section.selectable[sec_row.row]
            if ref_eq(ref, p.selection.pinned) then
                pcall(vim.api.nvim_buf_set_extmark, self._overview_buf, ns, line_no - 1, 0, {
                    virt_text = { { "  *pinned*", "LoomworksActive" } },
                    virt_text_pos = "eol",
                })
                break
            end
        end
    end

    -- Render inspector
    local insp_lines, insp_highlights, insp_drill_map, insp_edit_map, insp_add_map =
        inspector_view.render(p.inspector)
    self._inspector_drill_map = insp_drill_map or {}
    self._inspector_edit_map  = insp_edit_map  or {}
    self._inspector_add_map   = insp_add_map   or {}
    -- Augment hint bar with dynamic actions valid for the current inspector.
    local insp_hint = vim.list_extend({}, (p.inspector and p.inspector.hint_bar) or {})
    local has_editable = next(self._inspector_edit_map) ~= nil
    if has_editable and p.inspector and p.inspector.publishable then
        table.insert(insp_hint, 1, { key = "e", label = "edit / cycle publish" })
    elseif has_editable then
        table.insert(insp_hint, 1, { key = "e", label = "edit field" })
    elseif p.inspector and p.inspector.publishable then
        table.insert(insp_hint, 1, { key = "e", label = "cycle publish" })
    end
    local has_drill = next(self._inspector_drill_map) ~= nil
    local has_add   = next(self._inspector_add_map)   ~= nil
    if has_drill and has_add then
        table.insert(insp_hint, 1, { key = "<CR>", label = "drill / add" })
    elseif has_drill then
        table.insert(insp_hint, 1, { key = "<CR>", label = "drill in" })
    elseif has_add then
        table.insert(insp_hint, 1, { key = "<CR>", label = "add" })
    end
    set_buf_content(self._inspector_buf, insp_lines, insp_highlights, insp_hint, ns)

    -- Render activity strip
    local act_lines, act_highlights = activity_view.render(p.activity)
    set_buf_content(self._activity_buf, act_lines, act_highlights,
        p.activity and p.activity.hint_bar, ns)

    -- Cursor handling on refresh: leave the cursor where the user put it.
    -- Non-selectable lines (separators, section headers, blanks) are valid
    -- positions to pass through during j/k navigation; snapping to the
    -- nearest selectable on every refresh fights the user — especially
    -- because background events (task_progress, file_tracker ticks) trigger
    -- refreshes while the user is mid-navigation. Only clamp out-of-bounds
    -- cursors after the buffer shrinks.
    if valid_win(self._overview_win) and #lines > 0 then
        local cur = vim.api.nvim_win_get_cursor(self._overview_win)
        if cur[1] > #lines then
            self._suppress_cursor = true
            pcall(vim.api.nvim_win_set_cursor, self._overview_win, { #lines, 0 })
            self._suppress_cursor = false
        end
    end
end

return Layout
