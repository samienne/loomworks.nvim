-- loomworks.nvim — auto-loaded entry point
-- Creates user-facing commands on startup.

if vim.g.loaded_loomworks then return end
vim.g.loaded_loomworks = true

-- Status highlight groups (default links, user can override)
local hl = vim.api.nvim_set_hl
hl(0, "LoomworksActive",       { link = "DiagnosticOk",    default = true })
hl(0, "LoomworksBuilt",        { link = "DiagnosticOk",    default = true })
hl(0, "LoomworksConfigured",   { link = "DiagnosticInfo",  default = true })
hl(0, "LoomworksUnconfigured", { link = "Comment",         default = true })
hl(0, "LoomworksFailed",       { link = "DiagnosticError", default = true })
hl(0, "LoomworksRunning",      { link = "DiagnosticWarn",  default = true })
hl(0, "LoomworksDeleting",     { link = "DiagnosticError", default = true })
hl(0, "LoomworksActionable",  { link = "Normal",         default = true })

vim.api.nvim_create_user_command("LoomworksInit", function(cmd)
  local path = cmd.args ~= "" and cmd.args or nil
  require("loomworks").setup({ root = path })
end, {
  nargs = "?",
  complete = "dir",
  desc = "loomworks: initialize workspace from directory (default: cwd)",
})

vim.api.nvim_create_user_command("LoomworksInfo", function()
  require("loomworks").open()
end, {
  desc = "loomworks: show workspace status page",
})
