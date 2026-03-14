--- loomworks/ui/dialog.lua — Snacks.win-based dialog helper.
---
--- Provides a single `show()` function for all floating dialogs
--- (help, confirm, options). Eliminates duplicated float creation code.

local M = {}

--- Show a dialog float with content, highlights, and keymaps.
--- @param opts table
---   title?: string — window title
---   lines: string[] — content lines
---   highlights?: table[] — { line (1-based), hl_group, col_start? (0-based), col_end? }
---   keys?: table<string, function|string> — additional keymaps beyond q/Esc
---   max_width?: number — max width cap (default 80)
---   max_height?: number — max height cap
--- @return snacks.win
function M.show(opts)
  local lines = opts.lines

  -- Auto-calculate width from content
  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then width = #l end
  end
  width = math.min(width + 2, opts.max_width or 80)

  local max_height = opts.max_height or math.floor(vim.o.lines * 0.8)
  local height = math.min(#lines, max_height)

  -- Build keys: always include q and Esc to close
  local keys = { q = "close", ["<Esc>"] = "close" }
  if opts.keys then
    for k, v in pairs(opts.keys) do
      keys[k] = v
    end
  end

  local ns = vim.api.nvim_create_namespace("loomworks_dialog")

  return Snacks.win({
    position = "float",
    width = width,
    height = height,
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = "center",
    enter = true,
    zindex = 60,
    backdrop = 60,
    text = lines,
    bo = { modifiable = false, bufhidden = "wipe" },
    keys = keys,
    on_buf = function(self)
      if opts.highlights then
        for _, hl in ipairs(opts.highlights) do
          vim.api.nvim_buf_add_highlight(
            self.buf, ns, hl.hl_group or hl[2],
            (hl.line or hl[1]) - 1,
            hl.col_start or hl[3] or 0,
            hl.col_end or hl[4] or -1
          )
        end
      end
    end,
  })
end

return M
