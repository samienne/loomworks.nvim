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

    -- Save cursor
    local cursor = vim.api.nvim_win_get_cursor(win)

    local lines, highlights, _, needs_frame = self._widget:render()

    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.bo[self._bufnr].modifiable = false
    -- For acwrite buffers: always mark modified so :w triggers BufWriteCmd
    if self._on_write then
        vim.bo[self._bufnr].modified = true
    end

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns, 0, -1)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            self._bufnr, self._ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end

    -- Restore cursor
    local line_count = #lines
    if cursor[1] > line_count then cursor[1] = line_count end
    pcall(vim.api.nvim_win_set_cursor, win, cursor)

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
