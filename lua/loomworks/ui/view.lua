--- loomworks/ui/view.lua — Generic view backed by Snacks.win.
---
--- Manages a Tree widget, refresh cycle, event subscriptions, and
--- animation timer. Delegates window lifecycle to Snacks.win.
---
--- Accepts a content widget that implements:
---   widget:render()              → lines, highlights, line_meta, needs_frame
---   widget:on_key(action, line)  → { refresh?, restore_fold? }
---   widget.line_meta             — table<number, table>

--- @class loomworks.View
--- @field _widget table content widget
--- @field _keymaps table<string, string> key → action name
--- @field _events string[] event names that trigger refresh
--- @field _win_opts table Snacks.win config overrides
--- @field _filetype string buffer filetype
--- @field _timer_interval number milliseconds between animation frames
--- @field _bufnr number|nil
--- @field _snacks_win snacks.win|nil
--- @field _timer number|nil
--- @field _refresh_scheduled boolean
--- @field _event_handlers table[] { event_name, handler } for cleanup
--- @field _ns number namespace id
local View = {}
View.__index = View

--- @param opts table
--- @return loomworks.View
function View.new(opts)
    return setmetatable({
        _widget = opts.widget,
        _keymaps = opts.keymaps or {},
        _events = opts.events or {},
        _win_opts = opts.win or {},
        _on_close = opts.on_close,
        _on_write = opts.on_write,
        _on_revert = opts.on_revert,
        _is_modified = opts.is_modified,
        _lock_to_items = opts.lock_to_items or false,
        _filetype = opts.filetype or "loomworks",
        _timer_interval = opts.timer_interval or 80,
        _bufnr = nil,
        _snacks_win = nil,
        _timer = nil,
        _refresh_scheduled = false,
        _snapping = false,
        _event_handlers = {},
        _cursor_autocmd = nil,
        _ns = vim.api.nvim_create_namespace("loomworks_view"),
    }, View)
end

--- Open the view window. Focuses existing window if already open.
--- @param win_overrides? table Snacks.win config overrides for this open call
function View:open(win_overrides)
    if self._snacks_win and self._snacks_win:valid() then
        self._snacks_win:focus()
        self:refresh()
        return
    end

    -- Create buffer if needed
    if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then
        self._bufnr = vim.api.nvim_create_buf(false, true)
        if self._on_write then
            vim.api.nvim_buf_set_name(self._bufnr, "loomworks://status")
        end
    end

    -- Build Snacks.win keys from our keymap table
    local keys = { q = "close" }
    for key, action in pairs(self._keymaps) do
        local a = action
        keys[key] = function() self:_dispatch(a) end
    end

    -- lock_to_items: j/k navigate between actionable items only
    if self._lock_to_items then
        keys["j"] = function() self:_dispatch("next_item") end
        keys["k"] = function() self:_dispatch("prev_item") end
    end

    -- Merge: defaults < constructor opts < open() overrides < non-overridable
    local win_config = vim.tbl_deep_extend("force", {
        position = "float",
        width = 80,
        height = 0.9,
        border = "rounded",
        title = " loomworks ",
        title_pos = "center",
    }, self._win_opts, win_overrides or {})

    -- Non-overridable fields (we own the buffer and lifecycle)
    win_config.buf = self._bufnr
    win_config.enter = true
    win_config.keys = keys
    win_config.bo = {
        buftype = self._on_write and "acwrite" or "nofile",
        bufhidden = "wipe",
        swapfile = false,
        filetype = self._filetype,
        modifiable = false,
    }
    win_config.wo = vim.tbl_extend("force", {
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = false,
        cursorline = true,
    }, win_config.wo or {})
    win_config.on_close = function()
        self:_cleanup()
        if self._on_close then self._on_close() end
    end

    self._snacks_win = Snacks.win(win_config)
    self:_setup_events()
    if self._lock_to_items then
        self:_setup_cursor_lock()
    end
    -- Set up BufWriteCmd for :w support (acwrite buftype)
    if self._on_write and self._bufnr then
        local on_write = self._on_write
        local view = self
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = self._bufnr,
            callback = function()
                on_write()
                view:refresh()
            end,
        })
    end
    -- Set up BufReadCmd for :e / :e! support. Vim refuses :e on a modified
    -- buffer (E37) and only fires this autocmd on :e!. The acwrite buffer's
    -- modified flag mirrors `is_modified`, which returns true whenever the
    -- workspace has any divergence from the published baseline. So this
    -- handler runs only when the user said "yes, force-revert".
    if self._on_revert and self._bufnr then
        local on_revert = self._on_revert
        local view = self
        vim.api.nvim_create_autocmd("BufReadCmd", {
            buffer = self._bufnr,
            callback = function()
                on_revert()
                view:refresh()
            end,
        })
    end
    self:refresh()
end

--- Close the view window if open.
function View:close()
    if self._snacks_win and self._snacks_win:valid() then
        self._snacks_win:close()
    end
end

--- @return boolean
function View:is_open()
    return self._snacks_win ~= nil and self._snacks_win:valid()
end

function View:toggle()
    if self:is_open() then self:close() else self:open() end
end

--- Render the widget and write output to the buffer.
function View:refresh()
    if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    if not self._snacks_win or not self._snacks_win:valid() then return end

    local win = self._snacks_win.win

    -- Save cursor and identify current item by fold_key for stable tracking.
    -- Store the offset from the fold_key line so non-actionable lines
    -- (blanks, comments) don't snap to the parent item.
    local cursor = vim.api.nvim_win_get_cursor(win)
    local saved_fold_key = nil
    local saved_offset = 0
    local meta = self._widget.line_meta
    if meta then
        for l = cursor[1], 1, -1 do
            local w = meta[l]
            if w and w.fold_key then
                saved_fold_key = w.fold_key
                saved_offset = cursor[1] - l
                break
            end
        end
    end

    local lines, highlights, _, needs_frame = self._widget:render()

    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.bo[self._bufnr].modifiable = false
    -- For acwrite buffers: mark modified only when there are publishable changes.
    -- This enables :w when needed but avoids blocking :qa when clean.
    if self._on_write then
        vim.bo[self._bufnr].modified = self._is_modified and self._is_modified() or false
    end

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns, 0, -1)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            self._bufnr, self._ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end

    -- Restore cursor — try to find the same item by fold_key + offset
    local line_count = #lines
    local restored = false
    if saved_fold_key and self._widget.line_meta then
        for l, w in pairs(self._widget.line_meta) do
            if w.fold_key == saved_fold_key then
                local target = math.min(l + saved_offset, line_count)
                pcall(vim.api.nvim_win_set_cursor, win, { target, cursor[2] })
                restored = true
                break
            end
        end
    end
    if not restored then
        if cursor[1] > line_count then cursor[1] = line_count end
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end

    -- Snap to nearest actionable line when locked
    if self._lock_to_items then
        self:_snap_cursor()
    end

    -- Manage animation timer based on needs_frame
    if needs_frame and not self._timer then
        self._timer = vim.fn.timer_start(self._timer_interval, function()
            vim.schedule(function() self:refresh() end)
        end, { ["repeat"] = -1 })
    elseif not needs_frame and self._timer then
        vim.fn.timer_stop(self._timer)
        self._timer = nil
    end
end

--- Schedule a coalesced refresh on the next event loop tick.
function View:schedule_refresh()
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    vim.schedule(function()
        self._refresh_scheduled = false
        self:refresh()
    end)
end

--- Dispatch a key action to the content widget.
--- @param action string
function View:_dispatch(action)
    if not self._snacks_win or not self._snacks_win:valid() then return end
    local win = self._snacks_win.win
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local result = self._widget:on_key(action, line)
    if result.cursor then
        pcall(vim.api.nvim_win_set_cursor, win, { result.cursor, 0 })
    end
    if result.refresh then
        self:refresh()
        if result.restore_fold then
            for ln, w in pairs(self._widget.line_meta) do
                if w.fold_key == result.restore_fold then
                    pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
                    break
                end
            end
        end
    end
    if result.hover then
        self:_open_hover(result.hover)
    end
end

--- Open a wrapping hover popup near the cursor with the given content.
--- Content is a string or array of strings — each entry becomes a
--- buffer line, and vim's `wrap` handles overflow. Closes on any
--- subsequent keypress (Snacks's standard `keys.q` plus a one-shot
--- autocmd on CursorMoved).
--- @param content string|string[]
function View:_open_hover(content)
    if not self._snacks_win or not self._snacks_win:valid() then return end
    local lines
    if type(content) == "string" then
        lines = vim.split(content, "\n", { plain = true })
    elseif type(content) == "table" then
        lines = content
    else
        return
    end
    if #lines == 0 then return end

    -- Width: cap at min(80, available columns - 8). Height:
    -- approximate wrapped-line count so the popup hugs its content.
    local max_w = math.max(20, math.min(80, vim.o.columns - 8))
    local wrapped = 0
    for _, l in ipairs(lines) do
        local len = vim.fn.strdisplaywidth(l)
        wrapped = wrapped + math.max(1, math.ceil(len / max_w))
    end
    local h = math.min(wrapped, math.max(3, math.floor(vim.o.lines * 0.4)))

    local hover_win = Snacks.win({
        position = "float",
        relative = "cursor",
        row = 1,
        col = 0,
        width = max_w,
        height = h,
        border = "rounded",
        wo = {
            wrap = true,
            linebreak = true,
            cursorline = false,
        },
        bo = {
            buftype = "nofile",
            bufhidden = "wipe",
            modifiable = false,
            filetype = "loomworks_hover",
        },
        keys = {
            q = "close",
            ["<Esc>"] = "close",
        },
        enter = false,
    })

    -- Snacks creates the buffer lazily — set lines after open.
    if hover_win and hover_win.buf then
        vim.bo[hover_win.buf].modifiable = true
        vim.api.nvim_buf_set_lines(hover_win.buf, 0, -1, false, lines)
        vim.bo[hover_win.buf].modifiable = false
    end

    -- Close on next cursor move (mirrors LSP hover behaviour).
    local group = vim.api.nvim_create_augroup("loomworks_hover_close", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
        group = group,
        once = true,
        callback = function()
            if hover_win and hover_win.valid and hover_win:valid() then
                hover_win:close()
            end
        end,
    })
end

--- Find the nearest actionable line to the given line.
--- @param line number current cursor line (1-based)
--- @return number|nil nearest actionable line
function View:_nearest_item(line)
    local meta = self._widget.line_meta
    if meta[line] then return line end

    -- Search outward from current line
    local total = #self._widget.lines
    for offset = 1, total do
        local down = line + offset
        local up = line - offset
        if down <= total and meta[down] then return down end
        if up >= 1 and meta[up] then return up end
    end
    return nil
end

--- Snap cursor to the nearest actionable line if not already on one.
function View:_snap_cursor()
    if not self._snacks_win or not self._snacks_win:valid() then return end
    local win = self._snacks_win.win
    local cursor = vim.api.nvim_win_get_cursor(win)
    local target = self:_nearest_item(cursor[1])
    if target and target ~= cursor[1] then
        self._snapping = true
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        self._snapping = false
    elseif cursor[2] ~= 0 then
        self._snapping = true
        pcall(vim.api.nvim_win_set_cursor, win, { cursor[1], 0 })
        self._snapping = false
    end
end

--- Set up CursorMoved autocmd to lock cursor to actionable lines.
function View:_setup_cursor_lock()
    if not self._bufnr then return end
    self._cursor_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = self._bufnr,
        callback = function()
            if self._snapping then return end
            self:_snap_cursor()
        end,
    })
end

function View:_setup_events()
    local events = require("loomworks.events")
    self._event_handlers = {}
    for _, event_name in ipairs(self._events) do
        local handler = function()
            self:schedule_refresh()
        end
        events.on(event_name, handler)
        self._event_handlers[#self._event_handlers + 1] = { event_name, handler }
    end
end

function View:_cleanup()
    if self._timer then
        vim.fn.timer_stop(self._timer)
        self._timer = nil
    end
    if self._cursor_autocmd then
        pcall(vim.api.nvim_del_autocmd, self._cursor_autocmd)
        self._cursor_autocmd = nil
    end
    local events = require("loomworks.events")
    for _, entry in ipairs(self._event_handlers) do
        events.off(entry[1], entry[2])
    end
    self._event_handlers = {}
    self._bufnr = nil
    self._snacks_win = nil
end

return View
