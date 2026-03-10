--- loomworks/ui/actions.lua — Action factories and deletion dialog.
---
--- Action factories capture context at render time and return closures
--- for deferred execution at action time. They call loomworks API
--- functions; the event system triggers UI refresh automatically.

local M = {}

-- ---------------------------------------------------------------------------
-- Action factories
-- ---------------------------------------------------------------------------

function M.activate(profile_key)
  return function()
    require("loomworks").activate_profile(profile_key)
  end
end

function M.build(profile_key)
  return function()
    require("loomworks.overseer").run_profile_action(profile_key, "build")
  end
end

function M.configure(profile_key)
  return function()
    require("loomworks.overseer").run_profile_action(profile_key, "configure")
  end
end

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

function M.delete_profile(profile_key)
  return function()
    local lw = require("loomworks")
    local profile = lw.get_profile(profile_key)
    if not profile then return end
    local plan = profile:plan_deletion()
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
      return
    end
    M._show_delete_confirmation("Delete profile: " .. profile.key, plan, function(p)
      lw.execute_deletion(p, { deactivate_profile = profile.key }, function()
        vim.notify("loomworks: profile '" .. profile.key .. "' cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

function M.delete_config(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local plan = lw.plan_config_deletion(project_key, config_key)
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end
    M._show_delete_confirmation("Delete: " .. project_key .. " / " .. config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

function M.delete_configuration(project_key, config_name)
  return function()
    local lw = require("loomworks")
    local proj = lw.get_project(project_key)
    if not proj then return end
    local config_key = proj:config_cache_key(config_name)
    local plan = lw.plan_config_deletion(project_key, config_key)
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end
    M._show_delete_confirmation(
      "Delete configuration: " .. project_key .. " / " .. config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
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
--- @param on_confirm fun(plan: loomworks.DeletionPlan)
function M._show_delete_confirmation(title, plan, on_confirm)
  local lw = require("loomworks")
  local items = plan.items
  local defined_in_config = plan.defined_in_config
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

  local to_delete = {}
  local shared = {}

  for _, item in ipairs(items) do
    if item.shared_by and #item.shared_by > 0 then
      shared[#shared + 1] = item
    else
      to_delete[#to_delete + 1] = item
    end
  end

  if #to_delete > 0 then
    add("  Will clean:", "Title")
    for _, item in ipairs(to_delete) do
      add("    " .. item.project_key .. "  " .. item.config_key, "DiagnosticError")
      if item.build_dir then
        add("      " .. rel_path(item.build_dir), "Comment")
      else
        add("      (no build directory)", "Comment")
      end
      if item.affected_profiles and #item.affected_profiles > 0 then
        add("      affects profiles: " .. table.concat(item.affected_profiles, ", "),
          "DiagnosticWarn")
      end
    end
    add("")
  end

  if #shared > 0 then
    add("  Shared (kept):", "Title")
    for _, item in ipairs(shared) do
      add("    " .. item.project_key .. "  " .. item.config_key, "DiagnosticInfo")
      add("      used by: " .. table.concat(item.shared_by, ", "), "Comment")
    end
    add("")
  end

  if #to_delete > 0 then
    local dirs = {}
    for _, item in ipairs(to_delete) do
      if item.build_dir then
        dirs[#dirs + 1] = rel_path(item.build_dir)
      end
    end
    if #dirs > 0 then
      add("  Directories to delete:", "DiagnosticError")
      for _, dir in ipairs(dirs) do
        add("    " .. dir, "Comment")
      end
      add("")
    end
  end

  if #to_delete == 0 then
    add("  Nothing to delete — all configurations are shared.", "Comment")
    add("")
    add("  Press q to close", "Comment")
  else
    if defined_in_config then
      add("  Note: defined in loomworks.json — remains available for reconfiguration.", "Comment")
      add("")
    end
    add("  Press y to confirm, q to cancel", "Comment")
  end

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

  if #to_delete > 0 then
    vim.keymap.set("n", "y", function()
      close()
      on_confirm(plan)
    end, map_opts)
  end
end

return M
