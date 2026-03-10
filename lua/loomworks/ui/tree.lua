--- loomworks/ui/tree.lua — Foldable tree builder for status UI.
---
--- Provides a TreeBuilder that tracks indentation level, fold state,
--- and spinner animation. Nodes increment level by their prefix slot
--- count so children's text aligns with the parent's name column.
---
--- Non-rendering fields in opts (callbacks, fold_key) are stored as the
--- line's "widget" in line_meta — keybinding handlers dispatch to these.

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Fields consumed by the tree builder for rendering only.
local RENDER_KEYS = { hl = true, spinning = true, marker = true }

--- @class loomworks.TreeBuilder
--- @field _folds table<string, boolean>
--- @field _spinner_frame number
--- @field _level number
--- @field lines string[]
--- @field highlights table[]
--- @field line_meta table<number, table>
local TreeBuilder = {}
TreeBuilder.__index = TreeBuilder

--- @param folds table<string, boolean>
--- @param spinner_frame number
--- @return loomworks.TreeBuilder
function TreeBuilder.new(folds, spinner_frame)
  return setmetatable({
    _folds = folds,
    _spinner_frame = spinner_frame,
    _level = 0,
    lines = {},
    highlights = {},
    line_meta = {},
  }, TreeBuilder)
end

--- @return string
function TreeBuilder:_pad()
  return string.rep("  ", self._level)
end

--- @return string spinner character with trailing space
function TreeBuilder:_spinner()
  return SPINNER_FRAMES[self._spinner_frame] .. " "
end

--- Extract non-rendering fields from opts as the line widget.
--- @param opts table
--- @return table|nil
function TreeBuilder:_make_widget(opts)
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
function TreeBuilder:_add(text, hl, widget)
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
function TreeBuilder:leaf(text, hl)
  self:_add(self:_pad() .. text, hl)
end

--- Add a blank line.
function TreeBuilder:blank()
  self:_add("")
end

--- Add a foldable node. children_fn is called when unfolded.
--- Level increments by prefix slot count (1 for fold-only, 2 for marker+fold).
--- Non-rendering fields in opts are stored as the line widget.
--- @param text string
--- @param opts table
--- @param children_fn fun()
function TreeBuilder:node(text, opts, children_fn)
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
--- Non-rendering fields in opts are stored as the line widget.
--- @param text string
--- @param opts table
function TreeBuilder:item(text, opts)
  local prefix = opts.spinning and self:_spinner() or (opts.marker or "")
  self:_add(self:_pad() .. prefix .. text, opts.hl, self:_make_widget(opts))
end

--- Add a labeled sub-section that increases indentation for its children.
--- @param label string
--- @param hl? string
--- @param children_fn fun()
function TreeBuilder:group(label, hl, children_fn)
  self:leaf(label, hl)
  self._level = self._level + 1
  children_fn()
  self._level = self._level - 1
end

TreeBuilder.SPINNER_FRAMES = SPINNER_FRAMES

return TreeBuilder
