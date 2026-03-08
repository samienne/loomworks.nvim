-- loomworks.nvim — auto-loaded entry point
-- Creates user-facing commands on startup.

if vim.g.loaded_loomworks then return end
vim.g.loaded_loomworks = true

vim.api.nvim_create_user_command("LoomworksHello", function()
    require("loomworks").hello()
end, { desc = "loomworks: say hello (verify plugin is loaded)" })
