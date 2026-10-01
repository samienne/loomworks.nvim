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

-- Hermetic per-user state: every spec file gets its own data directory (the
-- trust key, the workspace runtime's state and runtime logs, spec §17.2,
-- §19.10) and its own lw settings, so a test run never writes the real
-- %LOCALAPPDATA%\loomworks / ~/.local/share/loomworks, and the developer's
-- own settings (runtime-mode, …) never change what a test does. Spawned
-- helper processes inherit both.
do
    local base = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(base .. "/data", "p")
    vim.fn.mkdir(base .. "/config", "p")
    vim.env.LOOMWORKS_DATA_DIR = base .. "/data"
    if vim.fn.has("win32") == 1 then
        vim.env.APPDATA = base .. "/config"
    else
        vim.env.XDG_CONFIG_HOME = base .. "/config"
    end
    vim.env.LOOMWORKS_RUNTIME = nil
    vim.env.LOOMWORKS_NO_DAEMON = nil
    vim.env.LOOMWORKS_TEST_STATE_ROOT = base
end
