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

-- Auto-load: check cwd on plugin load, directory changes, and session restore
local auto_load = require("loomworks.auto_load")

auto_load.check_cwd()

local auto_load_group = vim.api.nvim_create_augroup("loomworks_auto_load", { clear = true })

vim.api.nvim_create_autocmd("DirChanged", {
  group = auto_load_group,
  callback = function()
    auto_load.check_cwd()
  end,
})

vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = auto_load_group,
  callback = function()
    auto_load.check_cwd()
  end,
})

vim.api.nvim_create_autocmd("User", {
  group = auto_load_group,
  pattern = "ResessionLoadPost",
  callback = function()
    auto_load.check_cwd()
  end,
})
