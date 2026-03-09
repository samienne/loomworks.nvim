-- Minimal init for plenary.busted tests.
-- Sets up runtime path so require("loomworks.*") works.

-- Add the plugin itself to rtp
vim.opt.rtp:prepend(".")

-- Add plenary (try lazy.nvim install location, then packpath)
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.rtp:prepend(plenary_path)
end

-- Disable swap files and shada for test runs
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
