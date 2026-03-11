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

--- Fields consumed by the tree builder for rendering only.
local RENDER_KEYS = { hl = true, spinning = true, marker = true }

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
  if action == "toggle_fold" then
    local w = self.line_meta[line]
    if not w or not w.fold_key then return {} end
    local fk = w.fold_key
    self._folds[fk] = not self._folds[fk]
    return { refresh = true, restore_fold = fk }

  elseif action == "enter" then
    local w = self.line_meta[line]
    if w and w.on_enter then w.on_enter() end
    return {}

  elseif action == "load" then
    local lw = require("loomworks")
    if lw.get_workspace() then
      lw.rescan_tools()
    else
      lw.setup({ root = vim.fn.getcwd() })
    end
    return { refresh = true }

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
-- Help dialog
-- -----------------------------------------------------------------------

function Tree:_show_help()
  local lines = {
    "  Keybindings",
    "",
    "  <Tab>   Toggle fold",
    "  <CR>    Activate profile",
    "",
    "  b       Build",
    "  c       Configure",
    "  p       Pin configuration",
    "  L       Load / rescan workspace",
    "",
    "  R       Rebuild (clean + build)",
    "  C       Clean (reset to unconfigured)",
    "  D       Delete",
    "",
    "  q       Close",
    "  ?       Show this help",
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 38
  local height = #lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Help ",
    title_pos = "center",
  })

  local ns = vim.api.nvim_create_namespace("loomworks_help")
  vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
  -- Highlight destructive keys
  for i, line in ipairs(lines) do
    if line:match("^  [RCD]%s") then
      vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticWarn", i - 1, 2, 3)
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
  vim.keymap.set("n", "?", close, map_opts)
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

--- Add a plain text line at current indentation.
--- @param text string
--- @param hl? string
function Tree:leaf(text, hl)
  self:_add(self:_pad() .. text, hl)
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
--- @param label string
--- @param hl? string
--- @param children_fn fun()
function Tree:group(label, hl, children_fn)
  self:leaf(label, hl)
  self._level = self._level + 1
  children_fn()
  self._level = self._level - 1
end

return Tree
