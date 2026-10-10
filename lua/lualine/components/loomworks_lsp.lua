--- lualine component for loomworks — explains a WITHHELD language server.
---
--- Inside a workspace, loomworks starts no clangd at all for a buffer whose
--- compilation database it cannot supply (spec §9.8): the active configuration
--- is not configured on this machine, no database exists yet, or the workspace
--- failed to load. lualine's built-in `lsp_status` lists attached clients only,
--- so a withheld server just looks like "no server". Place this component next
--- to it:
---
---   lualine_x = { "lsp_status", "loomworks_lsp" }
---
--- Renders (in DiagnosticError's foreground on the section's own background,
--- through lualine's component `color` option; spec/ui.md §4):
---   withheld_unconfigured → "(unconfigured)"
---   withheld_no_db        → "(no db)"
---   withheld_error        → "(ws error)"
--- and the empty string otherwise (none / held / ok, outside any workspace, or
--- loomworks not loaded). Reads `loomworks.lsp_buf_state`, which works without
--- an active profile. Refreshed by loomworks' own `redrawstatus` whenever a
--- buffer's LSP status changes; costs nothing while idle.

local M = require("lualine.component"):extend()

--- Per-buffer LSP status → fixed display text. No workspace data is rendered,
--- so nothing here needs statusline escaping.
local TEXT = {
    withheld_unconfigured = "(unconfigured)",
    withheld_no_db        = "(no db)",
    withheld_error        = "(ws error)",
}
M._TEXT = TEXT

local HL = "DiagnosticError"

--- The foreground of `HL` as "#rrggbb", or nil when it has none.
--- @return string|nil
local function hl_fg()
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = HL, link = false })
    if not ok or type(hl) ~= "table" or not hl.fg then return nil end
    return string.format("#%06x", hl.fg)
end
M._hl_fg = hl_fg

--- Default `color`: DiagnosticError's fg only. lualine fills the missing bg
--- from the section and restores the section highlight after the component,
--- so the text neither drops to StatusLine colours nor loses the section bg.
--- A function, so a colourscheme change is picked up on the next redraw.
--- A user-supplied `color` option wins.
local function default_color()
    local fg = hl_fg()
    return fg and { fg = fg } or nil
end
M._default_color = default_color

function M:init(options)
    options = options or {}
    if options.color == nil then options.color = default_color end
    M.super.init(self, options)
end

function M:update_status()
    -- package.loaded (not require) so lazy.nvim's loader is never triggered
    -- from a statusline redraw during startup.
    local lw = package.loaded["loomworks"]
    if type(lw) ~= "table" or type(lw.lsp_buf_state) ~= "function" then return "" end
    local ok, state = pcall(lw.lsp_buf_state, 0)
    if not ok then return "" end
    local text = TEXT[state]
    if not text then return "" end
    return text
end

return M
