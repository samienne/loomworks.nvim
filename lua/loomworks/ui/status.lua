--- loomworks/ui/status.lua — Workspace status page.
---
--- Thin wiring: creates a Tree widget inside a View, assembles sections
--- with data from the loomworks API. All rendering logic lives in
--- section files; all UI machinery lives in View and Tree.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local actions = require("loomworks.ui.actions")

local M = {}

-- ---------------------------------------------------------------------------
-- Render function — assembles sections
-- ---------------------------------------------------------------------------

local function render_fn(tree)
  local lw = require("loomworks")
  local ws = lw.get_workspace()
  if not ws then
    local err = lw.get_setup_error()
    if err then
      tree._level = 1
      tree:leaf("loomworks.nvim " .. lw._version, "Title")
      tree:blank()
      tree:leaf("Failed to load workspace", "DiagnosticError")
      tree:leaf("Root: " .. err.root, "Comment")
      tree:blank()
      tree:leaf(err.message, "DiagnosticWarn")
    else
      tree:leaf("No workspace loaded.", "Comment")
      tree:blank()
      tree:leaf("Press L to load from:", "Comment")
      tree:leaf("  " .. vim.fn.getcwd(), "DiagnosticInfo")
    end
    return
  end

  local active_set = lw.get_active_configuration_set()
  if not active_set then
    tree:leaf("No workspace loaded.", "Comment")
    return
  end

  tree._level = 1

  -- Header
  tree:leaf("loomworks.nvim " .. lw._version, "Title")
  tree:blank()
  tree:leaf("Workspace: " .. ws.name, "Type")
  tree:leaf("Root:      " .. ws.root, "Comment")
  tree:blank()

  local ctx = {
    lw = lw,
    all_profiles = lw.get_profiles(),
    active_profile_key = active_set.name or "",
    active_set = active_set,
    config_sets = active_set.configuration_sets,
    tool_entries = lw.get_tool_entries(),
  }

  require("loomworks.ui.sections.profiles")(tree, ctx)
  require("loomworks.ui.sections.orphaned")(tree, ctx)
  require("loomworks.ui.sections.config_sets")(tree, ctx)

  ctx.projects = lw.get_projects()
  require("loomworks.ui.sections.projects")(tree, ctx)
end

-- ---------------------------------------------------------------------------
-- View instance
-- ---------------------------------------------------------------------------

local tree = Tree.new(render_fn)

local view = View.new({
  widget = tree,
  keymaps = {
    ["<Tab>"] = "toggle_fold",
    ["<CR>"]  = "enter",
    ["b"]     = "build",
    ["R"]     = "rebuild",
    ["c"]     = "configure",
    ["C"]     = "clean",
    ["D"]     = "delete",
    ["p"]     = "pin",
    ["L"]     = "load",
    ["<C-n>"] = "nuke",
    ["?"]     = "help",
  },
  events = {
    "task_started",
    "task_stopped",
    "task_result",
    "task_progress",
    "deletion_started",
    "deletion_completed",
    "active_set_changed",
    "operation_started",
    "operation_finished",
  },
})

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()    view:open() end
function M.close()   view:close() end
function M.toggle()  view:toggle() end
function M.refresh() view:refresh() end

function M.is_open()
  return view:is_open()
end

--- Delete a profile interactively (with confirmation dialog).
--- @param profile_key string
function M.delete_profile(profile_key)
  local profile = require("loomworks").get_profile(profile_key)
  if not profile then return end
  actions.delete_profile(profile)()
end

--- Delete a configuration interactively (with confirmation dialog).
--- @param project_key string
--- @param config_key string
function M.delete_config(project_key, config_key)
  actions.delete_config(project_key, config_key)()
end

return M
