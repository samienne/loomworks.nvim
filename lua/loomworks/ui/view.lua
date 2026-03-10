--- loomworks/ui/view.lua — Generic view widget.
---
--- Manages a buffer, window, highlight namespace, animation timer,
--- and input dispatch. Knows nothing about loomworks concepts.
---
--- Accepts a content widget that implements:
---   widget:render()              → lines, highlights, line_meta, needs_frame
---   widget:on_key(action, line)  → { refresh?, restore_fold? }
---   widget.line_meta             — table<number, table>

--- @class loomworks.View
--- @field _widget table content widget
--- @field _keymaps table<string, string> key → action name
--- @field _events string[] event names that trigger refresh
--- @field _width number window width
--- @field _filetype string buffer filetype
--- @field _timer_interval number milliseconds between animation frames
--- @field _bufnr number|nil
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
    _width = opts.width or 60,
    _filetype = opts.filetype or "loomworks",
    _timer_interval = opts.timer_interval or 80,
    _bufnr = nil,
    _timer = nil,
    _refresh_scheduled = false,
    _event_handlers = {},
    _ns = vim.api.nvim_create_namespace("loomworks_view"),
  }, View)
end

--- Open the view window. Focuses existing window if already open.
function View:open()
  if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == self._bufnr then
        vim.api.nvim_set_current_win(win)
        self:refresh()
        return
      end
    end
  else
    self._bufnr = vim.api.nvim_create_buf(false, true)
  end

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, self._bufnr)
  vim.api.nvim_win_set_width(win, self._width)

  vim.bo[self._bufnr].buftype = "nofile"
  vim.bo[self._bufnr].bufhidden = "wipe"
  vim.bo[self._bufnr].swapfile = false
  vim.bo[self._bufnr].filetype = self._filetype
  vim.bo[self._bufnr].modifiable = false

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  self:_setup_keymaps()
  self:_setup_events()
  self:_setup_cleanup()
  self:refresh()
end

--- Close the view window if open.
function View:close()
  if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == self._bufnr then
        vim.api.nvim_win_close(win, true)
        return
      end
    end
  end
end

--- @return boolean
function View:is_open()
  if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == self._bufnr then
      return true
    end
  end
  return false
end

function View:toggle()
  if self:is_open() then self:close() else self:open() end
end

--- Render the widget and write output to the buffer.
function View:refresh()
  if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then return end

  -- Save cursor
  local cursor
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == self._bufnr then
      cursor = vim.api.nvim_win_get_cursor(win)
      break
    end
  end

  local lines, highlights, _, needs_frame = self._widget:render()

  vim.bo[self._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
  vim.bo[self._bufnr].modifiable = false

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(
      self._bufnr, self._ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
  end

  -- Restore cursor
  if cursor then
    local line_count = #lines
    if cursor[1] > line_count then cursor[1] = line_count end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == self._bufnr then
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
        break
      end
    end
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
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local result = self._widget:on_key(action, line)
  if result.refresh then
    self:refresh()
    if result.restore_fold then
      for ln, w in pairs(self._widget.line_meta) do
        if w.fold_key == result.restore_fold then
          pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
          break
        end
      end
    end
  end
end

function View:_setup_keymaps()
  local map_opts = { buffer = self._bufnr, nowait = true, silent = true }

  -- Built-in keys
  vim.keymap.set("n", "r", function() self:refresh() end, map_opts)
  vim.keymap.set("n", "q", function() self:close() end, map_opts)

  -- Widget action keys
  for key, action in pairs(self._keymaps) do
    vim.keymap.set("n", key, function() self:_dispatch(action) end, map_opts)
  end
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

function View:_setup_cleanup()
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = self._bufnr,
    callback = function()
      if self._timer then
        vim.fn.timer_stop(self._timer)
        self._timer = nil
      end
      local events = require("loomworks.events")
      for _, entry in ipairs(self._event_handlers) do
        events.off(entry[1], entry[2])
      end
      self._event_handlers = {}
      self._bufnr = nil
    end,
  })
end

return View
