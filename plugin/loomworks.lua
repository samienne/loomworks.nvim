-- loomworks.nvim — auto-loaded entry point
-- Creates user-facing commands on startup.

if vim.g.loaded_loomworks then return end
vim.g.loaded_loomworks = true

-- Status highlight groups (default links, user can override)
local hl = vim.api.nvim_set_hl

-- Legacy status-as-color groups — still used by older sections.
hl(0, "LoomworksActive",       { link = "DiagnosticOk",    default = true })
hl(0, "LoomworksBuilt",        { link = "DiagnosticOk",    default = true })
hl(0, "LoomworksConfigured",   { link = "DiagnosticInfo",  default = true })
hl(0, "LoomworksUnconfigured", { link = "Comment",         default = true })
hl(0, "LoomworksFailed",       { link = "DiagnosticError", default = true })
hl(0, "LoomworksRunning",      { link = "DiagnosticWarn",  default = true })
hl(0, "LoomworksDeleting",     { link = "DiagnosticError", default = true })
hl(0, "LoomworksUnknown",      { link = "DiagnosticWarn",  default = true })
hl(0, "LoomworksActionable",   { link = "Normal",          default = true })

-- Entity-color scheme:
--   * Active profile  → `DiagnosticOk` green + bold (the "this is
--     where you are" row, brightest and heaviest)
--   * Inactive profile → `LoomworksActionable` (defaults to Normal),
--     i.e. the same look as the `Projects:` label and other
--     actionable text in the tree. Keeps inactive profiles
--     readable without competing with the active green.
--   * Project rows → `DiagnosticInfo` blue.
-- Severity stays on the marker icon's color, never on the row text.
local function _fg(name)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok then return nil end
    return h.fg
end

local _profile_fg = _fg("DiagnosticOk")   or "#5fd700"
local _project_fg = _fg("DiagnosticInfo") or "#00afff"

hl(0, "LoomworksProfile",         { fg = _profile_fg, bold = true, default = true })
hl(0, "LoomworksProfileInactive", { link = "LoomworksActionable",  default = true })
hl(0, "LoomworksProject",         { fg = _project_fg,              default = true })

-- Sub-section labels and sentinels inside an unfolded profile:
-- distinct theme-aware accents so they don't all read as plain
-- text (which is what `LoomworksActionable` defaults to and what
-- inactive profile rows now use).
--   * `LoomworksSection`  — group labels like "Projects:"
--   * `LoomworksAdd`      — actionable sentinels ("+ Add tool",
--                          "▸ Create new profile")
--   * `LoomworksTarget`   — the "Target: <name>" row when a target
--                          is selected
-- Linked to common syntax groups so they track the colorscheme;
-- the user can override any single one without touching the rest.
hl(0, "LoomworksSection", { link = "Statement", default = true })
hl(0, "LoomworksAdd",     { link = "Constant",  default = true })
hl(0, "LoomworksTarget",  { link = "Comment",   default = true })
hl(0, "LoomworksVariant", { link = "Type",      default = true })

vim.api.nvim_create_user_command("LoomworksInit", function(cmd)
  local path = cmd.args ~= "" and cmd.args or nil
  require("loomworks").setup({ root = path })
end, {
  nargs = "?",
  complete = "dir",
  desc = "loomworks: initialize workspace from directory (default: cwd)",
  force = true,
})

vim.api.nvim_create_user_command("LoomworksInfo", function()
  require("loomworks").open()
end, {
  desc = "loomworks: show workspace status page",
  force = true,
})

vim.api.nvim_create_user_command("LoomworksFidgetClear", function()
  -- Recovery hatch for stuck fidget popups. The fidget integration
  -- relies on event sequences (operation_finished, task_stopped, dap
  -- event_initialized/event_terminated) firing in a specific order;
  -- when something disrupts that order, a handle is orphaned and the
  -- popup spins forever even after every overseer task has completed.
  -- Cancels every tracked handle so the user can recover without
  -- restarting Neovim.
  local cleared = require("loomworks.fidget").clear()
  if cleared == 0 then
    vim.notify("loomworks: no fidget handles to clear", vim.log.levels.INFO)
  else
    vim.notify("loomworks: cleared " .. cleared .. " stuck fidget handle(s)",
      vim.log.levels.INFO)
  end
end, {
  desc = "loomworks: cancel any stuck fidget progress popups",
  force = true,
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
  force = true,
})

vim.api.nvim_create_user_command("LoomworksReload", function()
  require("loomworks.reload").reload()
end, {
  desc = "loomworks: tear down active workspace and reload plugin code (dev hatch)",
  force = true,
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
