-- loomworks.nvim — auto-loaded entry point
-- Creates user-facing commands on startup.

if vim.g.loaded_loomworks then return end
vim.g.loaded_loomworks = true

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
