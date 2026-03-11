--- loomworks/ui/actions.lua — Action factories and deletion dialog.
---
--- Action factories capture context at render time and return closures
--- for deferred execution at action time. They call loomworks API
--- functions; the event system triggers UI refresh automatically.

local M = {}

-- ---------------------------------------------------------------------------
-- Profile action factories (take Profile objects)
-- ---------------------------------------------------------------------------

--- @param profile_key string takes a key because activate may materialize a new profile
function M.activate(profile_key)
  return function()
    require("loomworks").activate_profile(profile_key)
  end
end

--- @param profile loomworks.Profile
function M.build(profile)
  return function() profile:build() end
end

--- @param profile loomworks.Profile
function M.configure(profile)
  return function() profile:configure() end
end

--- @param profile loomworks.Profile
function M.rebuild(profile)
  return function() profile:rebuild() end
end

--- @param profile loomworks.Profile
function M.clean(profile)
  return function() profile:clean() end
end

--- @param profile loomworks.Profile
function M.delete_profile(profile)
  return function()
    local plan = profile:plan_deletion()
    M._show_delete_confirmation("Delete profile: " .. profile.key, plan, function()
      require("loomworks").execute_deletion(plan, { deactivate_profile = profile.key }, function()
        vim.notify("loomworks: profile '" .. profile.key .. "' removed", vim.log.levels.INFO)
      end)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Configuration action factories (take project_key + config_key strings)
-- ---------------------------------------------------------------------------

function M.build_configuration(project_key, config_key)
  return function()
    require("loomworks.overseer").run_configuration_action(project_key, config_key, "build")
  end
end

function M.configure_configuration(project_key, config_key)
  return function()
    require("loomworks.overseer").run_configuration_action(project_key, config_key, "configure")
  end
end

function M.rebuild_configuration(project_key, config_key)
  return function()
    require("loomworks").clean_config(project_key, config_key, function()
      require("loomworks.overseer").run_configuration_action(project_key, config_key, "build")
    end)
  end
end

function M.clean_configuration(project_key, config_key)
  return function()
    require("loomworks").clean_config(project_key, config_key)
  end
end

function M.delete_config(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local plan = lw.plan_config_deletion(project_key, config_key)
    M._show_delete_confirmation(
      "Delete: " .. project_key .. " / " .. config_key, plan, function()
      lw.delete_config(project_key, config_key, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

--- @param project loomworks.Project
--- @param config_name string
function M.delete_configuration(project, config_name)
  return function()
    local lw = require("loomworks")
    local config_key = project:config_cache_key(config_name)
    local plan = lw.plan_config_deletion(project.key, config_key)
    M._show_delete_confirmation(
      "Delete: " .. project.key .. " / " .. config_key, plan, function()
      lw.delete_config(project.key, config_key, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

function M.pin_config(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local adhoc_key = require("loomworks.merge").adhoc_key(project_key, config_key)
    local existing = lw.get_profile(adhoc_key)
    if existing then
      vim.notify("loomworks: already pinned " .. project_key .. " / " .. config_key, vim.log.levels.INFO)
      return
    end
    lw.materialize_adhoc(project_key, config_key)
    vim.notify("loomworks: pinned " .. project_key .. " / " .. config_key, vim.log.levels.INFO)
  end
end

-- ---------------------------------------------------------------------------
-- Deletion confirmation dialog
-- ---------------------------------------------------------------------------

--- Make a path relative to workspace root for display.
--- @param abs string|nil
--- @return string|nil
local function rel_path(abs)
  if not abs then return abs end
  local lw = require("loomworks")
  local ws = lw.get_workspace()
  if not ws then return abs end
  local ws_root = vim.fs.normalize(ws.root)
  local normalized = vim.fs.normalize(abs)
  if normalized:sub(1, #ws_root) == ws_root then
    local rel = normalized:sub(#ws_root + 1)
    if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
    return rel ~= "" and rel or "."
  end
  return abs
end

--- Show a confirmation dialog for deleting configurations.
--- @param title string
--- @param plan loomworks.DeletionPlan
--- @param on_confirm fun()
function M._show_delete_confirmation(title, plan, on_confirm)
  local lw = require("loomworks")
  local items = plan.items
  local lines = {}
  local highlights = {}

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { line = #lines, hl_group = hl }
    end
  end

  add("  " .. title, "DiagnosticWarn")
  add("")

  local running_tasks = lw.find_running_tasks_for_items(items)
  local running_task_ids = {}
  for task_id in pairs(running_tasks) do
    running_task_ids[#running_task_ids + 1] = task_id
  end

  if #running_task_ids > 0 then
    add("  Will stop running tasks:", "DiagnosticWarn")
    for _, info in pairs(running_tasks) do
      add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key,
        "DiagnosticWarn")
    end
    add("")
  end

  -- Split items by disposition
  local clean_items, reset_items, keep_items = {}, {}, {}
  for _, item in ipairs(items) do
    if item.disposition == "keep" then
      keep_items[#keep_items + 1] = item
    elseif item.disposition == "reset" then
      reset_items[#reset_items + 1] = item
    else
      clean_items[#clean_items + 1] = item
    end
  end

  if #clean_items > 0 then
    add("  Will remove:", "DiagnosticError")
    for _, item in ipairs(clean_items) do
      local dir = item.build_dir and rel_path(item.build_dir) or nil
      local suffix = dir and ("  " .. dir) or ""
      add("    " .. item.project_key .. " / " .. item.config_key .. suffix, "DiagnosticError")
    end
    add("")
  end

  if #reset_items > 0 then
    add("  Will reset to unconfigured:", "DiagnosticWarn")
    for _, item in ipairs(reset_items) do
      local dir = item.build_dir and rel_path(item.build_dir) or nil
      local suffix = dir and ("  " .. dir) or ""
      add("    " .. item.project_key .. " / " .. item.config_key .. suffix, "DiagnosticWarn")
    end
    add("")
  end

  if #keep_items > 0 then
    add("  Will keep (referenced by another profile):", "Comment")
    for _, item in ipairs(keep_items) do
      add("    " .. item.project_key .. " / " .. item.config_key, "Comment")
    end
    add("")
  end

  if #items == 0 and plan.profile_key then
    add("  No configurations to clean.", "Comment")
    add("")
  end

  add("  Press y to confirm, q to cancel", "Comment")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line + 2)
  end
  width = math.min(width, 80)
  local height = math.min(#lines, 20)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Confirm Delete ",
    title_pos = "center",
  })

  local ns = vim.api.nvim_create_namespace("loomworks_delete_confirm")
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl.hl_group, hl.line - 1, 0, -1)
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
  vim.keymap.set("n", "n", close, map_opts)
  vim.keymap.set("n", "y", function()
    close()
    on_confirm()
  end, map_opts)
end

return M
