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
hl(0, "LoomworksUnknown",     { link = "DiagnosticWarn",  default = true })
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

vim.api.nvim_create_user_command("LoomworksDeviceLogLevel", function(cmd)
  local lw = require("loomworks")
  local arg = cmd.args
  if not arg or arg == "" then
    vim.notify("loomworks: device log level is " .. lw.get_device_log_level(),
      vim.log.levels.INFO)
    return
  end
  arg = arg:upper()
  local ok, err = lw.set_device_log_level(arg)
  if not ok then
    vim.notify("loomworks: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  vim.notify("loomworks: device log level set to " .. arg, vim.log.levels.INFO)
end, {
  nargs = "?",
  complete = function() return { "D", "I", "W", "E", "F" } end,
  desc = "loomworks: get/set on-device hilog level (D|I|W|E|F)",
})

vim.api.nvim_create_user_command("LoomworksLog", function()
  local lw = require("loomworks")
  local ws = lw.get_workspace()
  if not ws then
    vim.notify("loomworks: no workspace loaded", vim.log.levels.WARN)
    return
  end
  local path = ws.root .. "/.nvim/loomworks.log"
  if not vim.uv.fs_stat(path) then
    vim.notify("loomworks: no log file yet", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for line in io.lines(path) do
    lines[#lines + 1] = line
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "loomworks_log"

  local width = math.min(120, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " loomworks.log ",
    title_pos = "center",
  })

  -- Scroll to bottom
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf })
end, {
  desc = "loomworks: open workspace log file",
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
