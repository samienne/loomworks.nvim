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

--- @param profile_or_key loomworks.Profile|string
function M.build(profile_or_key)
  if type(profile_or_key) == "string" then
    return function()
      require("loomworks.overseer").run_profile_action(profile_or_key, "build")
    end
  end
  return function() profile_or_key:build() end
end

--- @param profile_or_key loomworks.Profile|string
function M.configure(profile_or_key)
  if type(profile_or_key) == "string" then
    return function()
      require("loomworks.overseer").run_profile_action(profile_or_key, "configure")
    end
  end
  return function() profile_or_key:configure() end
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

function M.delete_orphaned_config(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local orphan_items = { {
      project_key = project_key,
      config_key = config_key,
      disposition = "clean",
    } }
    M._show_delete_confirmation(
      "Delete orphaned: " .. project_key .. " / " .. config_key,
      { items = orphan_items, defined_in_config = false },
      function()
        lw.delete_orphaned_config(project_key, config_key, function()
          vim.notify("loomworks: orphaned configuration removed", vim.log.levels.INFO)
        end)
      end)
  end
end

function M.pin_config(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local pkey = require("loomworks.merge").pinned_key(project_key, config_key)
    local existing = lw.get_profile(pkey)
    if existing then
      vim.notify("loomworks: already pinned " .. project_key .. " / " .. config_key, vim.log.levels.INFO)
      return
    end
    lw.materialize_pinned(project_key, config_key)
    vim.notify("loomworks: pinned " .. project_key .. " / " .. config_key, vim.log.levels.INFO)
  end
end

-- ---------------------------------------------------------------------------
-- Options float
-- ---------------------------------------------------------------------------

--- @param project_key string
--- @param config_key string
function M.show_options(project_key, config_key)
  return function()
    local Tree = require("loomworks.ui.tree")
    local View = require("loomworks.ui.view")
    local lw = require("loomworks")
    local option_tree = lw.get_project_options(project_key, config_key)
    if not option_tree or #option_tree == 0 then
      vim.notify("loomworks: no build options available (project may need configure)", vim.log.levels.INFO)
      return
    end

    -- Render function for the options tree
    local function render_options(tree)
      tree._level = 1

      --- Render a single option as a leaf or foldable node.
      local function render_option(opt, fold_prefix)
        local value_str = opt.value
        if opt.choices and #opt.choices > 0 then
          value_str = value_str .. "  (" .. table.concat(opt.choices, ", ") .. ")"
        end

        local hl
        if opt.value_type == "bool" then
          hl = opt.value == "ON" and "DiagnosticOk" or "Comment"
        else
          hl = "Normal"
        end

        local display = opt.key .. " = " .. value_str
        if opt.helpstring then
          tree:node(display, {
            fold_key = fold_prefix .. "opt:" .. opt.key,
            hl = hl,
          }, function()
            tree:leaf(opt.helpstring, "Comment")
          end)
        else
          tree:leaf(display, hl)
        end
      end

      --- Recursively render option tree nodes.
      local function render_node(node, fold_prefix)
        if node.children then
          -- It's a group
          local count = 0
          local function count_leaves(n)
            if n.children then
              for _, child in ipairs(n.children) do count_leaves(child) end
            else
              count = count + 1
            end
          end
          count_leaves(node)

          tree:node(node.label .. " (" .. count .. ")", {
            fold_key = fold_prefix .. "group:" .. node.label,
            hl = "Title",
          }, function()
            for _, child in ipairs(node.children) do
              render_node(child, fold_prefix .. node.label .. ":")
            end
          end)
        else
          -- It's an option
          render_option(node, fold_prefix)
        end
      end

      for _, node in ipairs(option_tree) do
        render_node(node, "options:")
      end
    end

    local tree = Tree.new(render_options)
    local view = View.new({
      widget = tree,
      win = {
        width = 100,
        height = 0.8,
        zindex = 60,
        backdrop = 60,
        title = " " .. project_key .. " — Options ",
        title_pos = "center",
      },
      keymaps = {
        ["<Tab>"] = "toggle_fold",
      },
      events = {},
    })
    view:open()
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

  local dialog = require("loomworks.ui.dialog")
  dialog.show({
    title = "Confirm Delete",
    lines = lines,
    highlights = highlights,
    max_height = 20,
    keys = {
      n = "close",
      y = function(self)
        self:close()
        on_confirm()
      end,
    },
  })
end

return M
