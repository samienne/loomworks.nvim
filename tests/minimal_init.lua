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

-- Hermetic health output: the `lw health` daemon count (spec 19.6.1) scans
-- the machine's processes, which would see the daemons other spec files run
-- at the same time. Spawned lw processes inherit it; tests/daemon_list_spec
-- clears it where it tests the count.
vim.env.LOOMWORKS_TEST_NO_DAEMON_SCAN = "1"

-- No startup housekeeping (spec §16.40) in any lw the suite spawns: it would
-- scan and clean the machine's real temp and socket directories.
-- tests/housekeeping_spec drives it explicitly (`force`, sandboxed dirs).
vim.env.LOOMWORKS_NO_HOUSEKEEPING = "1"

-- Hermetic per-user state: every spec file gets its own data directory (the
-- trust key, the workspace runtime's state and runtime logs, spec §17.2,
-- §19.10) and its own lw settings, so a test run never writes the real
-- %LOCALAPPDATA%\loomworks / ~/.local/share/loomworks, and the developer's
-- own settings (runtime-mode, …) never change what a test does. Its own
-- cache directory too: the machine-level tool cache `tools.json` (spec
-- §16.43) lives under %LOCALAPPDATA% / $XDG_CACHE_HOME, and a test reading
-- or writing the real one would depend on the developer's machine and on the
-- order of the spec files. Spawned helper processes inherit all three.
do
    local base = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(base .. "/data", "p")
    vim.fn.mkdir(base .. "/config", "p")
    vim.fn.mkdir(base .. "/cache", "p")
    vim.env.LOOMWORKS_DATA_DIR = base .. "/data"
    if vim.fn.has("win32") == 1 then
        vim.env.APPDATA = base .. "/config"
    else
        vim.env.XDG_CONFIG_HOME = base .. "/config"
    end
    vim.env.LOCALAPPDATA = base .. "/cache"
    vim.env.XDG_CACHE_HOME = base .. "/cache"
    vim.env.LOOMWORKS_RUNTIME = nil
    vim.env.LOOMWORKS_NO_DAEMON = nil
    vim.env.LOOMWORKS_TEST_STATE_ROOT = base
end
