--- loomworks/ui/tree.lua — Foldable tree widget.
---
--- Persistent widget that owns fold state and spinner animation.
--- Accepts a render callback that populates tree content using builder
--- methods (leaf, node, item, group, blank).
---
--- Widget interface:
---   tree:render()              → lines, highlights, line_meta, needs_frame
---   tree:on_key(action, line)  → { refresh?, restore_fold? }

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Ordered list of actions for the Enter picker.
--- The `enter` action label is overridden per-widget via enter_label.
local ACTION_ORDER = {
    { action = "enter",     label = "Activate" },
    { action = "build",     label = "Build" },
    { action = "configure", label = "Configure" },
    { action = "task",      label = "Open task output" },
    { action = "pin",       label = "Pin as profile" },
    { action = "options",   label = "Show build options" },
    { action = "rebuild",   label = "Rebuild (clean + build)" },
    { action = "clean",     label = "Clean" },
    { action = "delete",    label = "Delete" },
}

--- Fields consumed by the tree builder for rendering only.
local RENDER_KEYS = { hl = true, spinning = true, marker = true, enter_label = true }

--- @class loomworks.Tree
--- @field _render_fn fun(tree: loomworks.Tree)
--- @field _folds table<string, boolean>
--- @field _spinner_frame number
--- @field _needs_frame boolean
--- @field _level number
--- @field lines string[]
--- @field highlights table[]
--- @field line_meta table<number, table>
local Tree = {}
Tree.__index = Tree

--- @param render_fn fun(tree: loomworks.Tree)
--- @return loomworks.Tree
function Tree.new(render_fn)
    return setmetatable({
        _render_fn = render_fn,
        _folds = {},
        _spinner_frame = 0,
        _needs_frame = false,
        _level = 0,
        lines = {},
        highlights = {},
        line_meta = {},
    }, Tree)
end

--- Render the tree. Resets state, bumps spinner, calls render_fn.
--- @return string[] lines, table[] highlights, table<number,table> line_meta, boolean needs_frame
function Tree:render()
    self._level = 0
    self.lines = {}
    self.highlights = {}
    self.line_meta = {}
    self._needs_frame = false
    self._spinner_frame = (self._spinner_frame % #SPINNER_FRAMES) + 1

    self._render_fn(self)

    return self.lines, self.highlights, self.line_meta, self._needs_frame
end

--- Handle an input action at the given line.
--- @param action string
--- @param line number
--- @return table result with optional refresh, restore_fold fields
function Tree:on_key(action, line)
    if action == "next_item" then
        local total = #self.lines
        for l = line + 1, total do
            if self.line_meta[l] then return { cursor = l } end
        end
        return {}

    elseif action == "prev_item" then
        for l = line - 1, 1, -1 do
            if self.line_meta[l] then return { cursor = l } end
        end
        return {}

    elseif action == "open_fold" then
        local w = self.line_meta[line]
        if not w or not w.fold_key then return {} end
        if self._folds[w.fold_key] then return {} end -- already open
        self._folds[w.fold_key] = true
        return { refresh = true, restore_fold = w.fold_key }

    elseif action == "close_fold" then
        -- If current line is foldable, fold it
        local w = self.line_meta[line]
        if w and w.fold_key then
            if not self._folds[w.fold_key] then return {} end -- already closed
            self._folds[w.fold_key] = false
            return { refresh = true, restore_fold = w.fold_key }
        end
        -- Otherwise walk upward to find the nearest foldable node
        for l = line - 1, 1, -1 do
            local parent = self.line_meta[l]
            if parent and parent.fold_key then
                self._folds[parent.fold_key] = false
                return { refresh = true, restore_fold = parent.fold_key }
            end
        end
        return {}

    elseif action == "toggle_fold" then
        local w = self.line_meta[line]
        if not w or not w.fold_key then return {} end
        local fk = w.fold_key
        self._folds[fk] = not self._folds[fk]
        return { refresh = true, restore_fold = fk }

    elseif action == "enter" then
        -- Walk up from cursor to find nearest widget with on_* callbacks
        local w
        for l = line, 1, -1 do
            if self.line_meta[l] then
                w = self.line_meta[l]
                break
            end
        end
        if not w then return {} end

        -- Collect available actions
        local items = {}
        for _, entry in ipairs(ACTION_ORDER) do
            local cb = w["on_" .. entry.action]
            if cb then
                local label = entry.label
                if entry.action == "enter" and w.enter_label then
                    label = w.enter_label
                end
                items[#items + 1] = { label = label, callback = cb }
            end
        end
        if #items == 0 then return {} end

        -- Direct-invoke when: widget is marked direct, or only one
        -- non-destructive action exists.
        if w.direct then
            items[1].callback()
            return {}
        end
        if #items == 1 and items[1].label ~= "Delete" then
            items[1].callback()
            return {}
        end

        vim.ui.select(items, {
            prompt = "Action:",
            format_item = function(item) return item.label end,
        }, function(choice)
            if choice then choice.callback() end
        end)
        return {}

    elseif action == "create_workspace" then
        self:_create_workspace()
        return {}

    elseif action == "load" then
        local lw = require("loomworks")
        if lw.get_workspace() then
            lw.rescan_tools()
        else
            lw.setup({ root = vim.fn.getcwd() })
        end
        return { refresh = true }

    elseif action == "nuke" then
        self:_confirm_nuke()
        return {}

    elseif action == "delete_user_prefs" then
        self:_confirm_delete_user_prefs()
        return {}

    elseif action == "help" then
        self:_show_help()
        return {}

    else
        -- Walk upward from line to find nearest widget with the action callback.
        local action_key = "on_" .. action
        for l = line, 1, -1 do
            local w = self.line_meta[l]
            if w then
                if w[action_key] then w[action_key]() end
                return {}
            end
        end
        return {}
    end
end

-- -----------------------------------------------------------------------
-- Create workspace
-- -----------------------------------------------------------------------

function Tree:_create_workspace()
    local lw = require("loomworks")
    if lw.get_workspace() then
        vim.notify("loomworks: workspace already exists", vim.log.levels.INFO)
        return
    end

    local root = vim.fn.getcwd()
    local ok, err = require("loomworks.workspace").create_workspace_config(root)
    if ok then
        lw.setup({ root = root })
    else
        vim.notify("loomworks: " .. (err or "failed to create workspace"), vim.log.levels.ERROR)
    end
end

-- -----------------------------------------------------------------------
-- Help dialog
-- -----------------------------------------------------------------------

function Tree:_show_help()
    local dialog = require("loomworks.ui.dialog")

    local lines = {
        "  Keybindings",
        "",
        "  <Tab>   Next item",
        "  <S-Tab> Previous item",
        "  l       Open fold",
        "  h       Close fold",
        "  <CR>    Actions menu",
        "",
        "  b       Build",
        "  c       Configure",
        "  t       Open task output",
        "  p       Pin configuration",
        "  o       Show build options",
        "  L       Load / rescan workspace",
        "",
        "  N       Create new workspace",
        "",
        "  R       Rebuild (clean + build)",
        "  C       Clean (run module clean tasks)",
        "  D       Delete",
        "  U       Delete user preferences",
        "  <C-n>   Nuke cache + build dirs",
        "",
        "  q       Close",
        "  ?       Show this help",
    }

    local highlights = {
        { line = 1, hl_group = "Title" },
    }
    for i, line in ipairs(lines) do
        if line:match("^  [RCDU]%s") or line:match("^  <C%-") then
            local key_end = line:find("%s%s", 3) or #line
            highlights[#highlights + 1] = { line = i, hl_group = "DiagnosticWarn", col_start = 2, col_end = key_end }
        end
    end

    dialog.show({
        title = "Help",
        lines = lines,
        highlights = highlights,
        keys = { ["?"] = "close" },
    })
end

-- -----------------------------------------------------------------------
-- Cache nuke confirmation dialog
-- -----------------------------------------------------------------------

function Tree:_confirm_nuke()
    local dialog = require("loomworks.ui.dialog")
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    local err = lw.get_setup_error()
    local root = (ws and ws.root) or (err and err.root) or require("loomworks.workspace").resolve_root()

    local lines = {
        "  Reset workspace cache",
        "",
        "  This will permanently delete:",
        "    " .. root .. "/.nvim/build/",
        "    " .. root .. "/.nvim/loomworks.cache.json",
        "",
        "  Press y to confirm, q to cancel",
    }

    dialog.show({
        title = "Confirm Reset",
        lines = lines,
        highlights = {
            { line = 1, hl_group = "DiagnosticError" },
            { line = 3, hl_group = "DiagnosticWarn" },
            { line = 4, hl_group = "DiagnosticWarn" },
            { line = 5, hl_group = "DiagnosticWarn" },
        },
        keys = {
            n = "close",
            y = function(self)
                self:close()
                lw.nuke_cache(root)
            end,
        },
    })
end

-- -----------------------------------------------------------------------
-- User preferences deletion confirmation
-- -----------------------------------------------------------------------

function Tree:_confirm_delete_user_prefs()
    local dialog = require("loomworks.ui.dialog")
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    local err = lw.get_setup_error()
    local root = (ws and ws.root) or (err and err.root) or require("loomworks.workspace").resolve_root()
    local user_path = require("loomworks.user").filepath(root)

    local lines = {
        "  Delete user preferences",
        "",
        "  This will delete:",
        "    " .. user_path,
        "",
        "  Active profile and default targets will be reset.",
        "",
        "  Press y to confirm, q to cancel",
    }

    dialog.show({
        title = "Confirm Delete",
        lines = lines,
        highlights = {
            { line = 1, hl_group = "DiagnosticWarn" },
            { line = 3, hl_group = "DiagnosticWarn" },
            { line = 4, hl_group = "DiagnosticWarn" },
            { line = 6, hl_group = "Comment" },
        },
        keys = {
            n = "close",
            y = function(self)
                self:close()
                lw.delete_user_prefs(root)
            end,
        },
    })
end

-- -----------------------------------------------------------------------
-- Builder methods
-- -----------------------------------------------------------------------

--- @return string
function Tree:_pad()
    return string.rep("  ", self._level)
end

--- @return string spinner character with trailing space
function Tree:_spinner()
    return SPINNER_FRAMES[self._spinner_frame] .. " "
end

--- Extract non-rendering fields from opts as the line widget.
--- @param opts table
--- @return table|nil
function Tree:_make_widget(opts)
    local w = nil
    for k, v in pairs(opts) do
        if not RENDER_KEYS[k] then
            w = w or {}
            w[k] = v
        end
    end
    return w
end

--- @param text string
--- @param hl? string
--- @param widget? table
function Tree:_add(text, hl, widget)
    self.lines[#self.lines + 1] = text
    local ln = #self.lines
    if hl then
        self.highlights[#self.highlights + 1] = {
            line = ln, col_start = 0, col_end = -1, hl_group = hl,
        }
    end
    if widget then
        self.line_meta[ln] = widget
    end
end

--- Add a line from {text, hl} chunks at current indentation.
--- @param chunks {[1]: string, [2]: string}[]
--- @param widget? table
function Tree:_add_chunks(chunks, widget)
    local pad = self:_pad()
    local parts = { pad }
    for _, chunk in ipairs(chunks) do
        parts[#parts + 1] = chunk[1]
    end
    self.lines[#self.lines + 1] = table.concat(parts)
    local ln = #self.lines
    local col = #pad
    for _, chunk in ipairs(chunks) do
        local len = #chunk[1]
        if chunk[2] then
            self.highlights[#self.highlights + 1] = {
                line = ln, col_start = col, col_end = col + len, hl_group = chunk[2],
            }
        end
        col = col + len
    end
    if widget then
        self.line_meta[ln] = widget
    end
end

--- Add a plain text line at current indentation.
--- Accepts either (text, hl) or a list of {text, hl} chunks.
--- @param text_or_chunks string|{[1]: string, [2]: string}[]
--- @param hl? string
function Tree:leaf(text_or_chunks, hl)
    if type(text_or_chunks) == "table" then
        self:_add_chunks(text_or_chunks)
    else
        self:_add(self:_pad() .. text_or_chunks, hl)
    end
end

--- Add a blank line.
function Tree:blank()
    self:_add("")
end

--- Add a foldable node. children_fn is called when unfolded.
--- @param text string
--- @param opts table
--- @param children_fn fun()
function Tree:node(text, opts, children_fn)
    if opts.spinning then self._needs_frame = true end

    local folded = not self._folds[opts.fold_key]
    local fold_char = folded and "▶ " or "▼ "

    local prefix
    local slots
    if opts.marker then
        prefix = (opts.spinning and self:_spinner() or opts.marker) .. fold_char
        slots = 2
    else
        prefix = opts.spinning and self:_spinner() or fold_char
        slots = 1
    end

    self:_add(self:_pad() .. prefix .. text, opts.hl, self:_make_widget(opts))

    if not folded then
        local indent = slots + 1
        self._level = self._level + indent
        children_fn()
        self._level = self._level - indent
    end
end

--- Add a non-foldable item with optional marker prefix.
--- @param text string
--- @param opts table
function Tree:item(text, opts)
    if opts.spinning then self._needs_frame = true end
    local prefix = opts.spinning and self:_spinner() or (opts.marker or "")
    self:_add(self:_pad() .. prefix .. text, opts.hl, self:_make_widget(opts))
end

--- Add a labeled sub-section that increases indentation for its children.
--- Accepts either (label, hl, children_fn) or (chunks, children_fn).
--- @param label_or_chunks string|{[1]: string, [2]: string}[]
--- @param hl_or_fn string|fun()
--- @param children_fn? fun()
function Tree:group(label_or_chunks, hl_or_fn, children_fn)
    if type(label_or_chunks) == "table" then
        -- chunks form: group(chunks, children_fn)
        self:leaf(label_or_chunks)
        self._level = self._level + 1
        hl_or_fn() -- this is actually children_fn
        self._level = self._level - 1
    else
        -- simple form: group(label, hl, children_fn)
        self:leaf(label_or_chunks, hl_or_fn)
        self._level = self._level + 1
        children_fn()
        self._level = self._level - 1
    end
end

return Tree
