--- loomworks/ui/status.lua — Pure rendering for the workspace status page.
--- All business logic accessed via require("loomworks") API.
--- Tree nodes register action callbacks as widgets; keybinding handlers
--- dispatch to them without knowledge of node types.

local M = {}

local TreeBuilder = require("loomworks.ui.tree")

--- Format a progress update as a compact string like "[2/10]".
--- @param p loomworks.ProgressUpdate|nil
--- @return string empty string if no progress
local function format_progress(p)
  if not p then return "" end
  return " [" .. p.current .. "/" .. p.total .. "]"
end

--- Format elapsed seconds as a compact duration like "1m23s" or "42s".
--- @param seconds number|nil
--- @return string empty string if nil
local function format_elapsed(seconds)
  if not seconds then return "" end
  local s = math.floor(seconds)
  if s < 60 then
    return " " .. s .. "s"
  end
  local m = math.floor(s / 60)
  s = s % 60
  if m < 60 then
    return " " .. m .. "m" .. string.format("%02d", s) .. "s"
  end
  local h = math.floor(m / 60)
  m = m % 60
  return " " .. h .. "h" .. string.format("%02d", m) .. "m"
end

--- Compute weighted percentage across multiple ProfileProjects.
--- Configure counts as 10% of overall work, build as 90%.
--- Returns nil if no progress data is available for any project.
--- @param pps loomworks.ProfileProject[]
--- @return number|nil percentage 0-100
local function aggregate_progress(pps)
  local lw = require("loomworks")
  local has_any = false
  local total_pct = 0
  local count = 0
  for _, pp in ipairs(pps) do
    local status = pp:status()
    if status == "configuring" or status == "building" then
      local p = lw.get_progress(pp.project_key, pp.config_key)
      if p then
        has_any = true
        local phase_pct = p.current / p.total
        if status == "configuring" then
          total_pct = total_pct + 10 * phase_pct
        else
          total_pct = total_pct + 10 + 90 * phase_pct
        end
        count = count + 1
      end
    end
  end
  if not has_any then return nil end
  return math.floor(total_pct / count)
end

--- @type number|nil buffer number for the status window
M._bufnr = nil

--- @type table<string, boolean> fold key -> folded state
M._folds = {}

--- @type table<number, table> line number -> widget (fold_key + action callbacks)
M._line_meta = {}

--- @type number|nil timer handle for spinner
M._spinner_timer = nil

--- @type number spinner frame index
M._spinner_frame = 1

local SPINNER_INTERVAL_MS = 80

local STATUS_HL = {
  unconfigured     = "Comment",
  configured       = "DiagnosticInfo",
  built            = "DiagnosticOk",
  failed_configure = "DiagnosticError",
  failed_build     = "DiagnosticError",
  configuring      = "DiagnosticWarn",
  building         = "DiagnosticWarn",
  deleting         = "DiagnosticError",
}

--- Resolve the live status for a project+config_key combination.
--- @param project_key string
--- @param config_key string
--- @param cached loomworks.CachedConfig|nil
--- @return string status, string hl_group, string progress_str, boolean is_spinning
local function resolve_config_status(project_key, config_key, cached)
  local lw = require("loomworks")

  if lw.is_deleting(project_key, config_key) then
    return "deleting", STATUS_HL.deleting, "", true
  end

  local running_action = lw.get_running_action(project_key, config_key)
  if running_action then
    local status = running_action == "configure" and "configuring" or "building"
    local progress_str = format_progress(lw.get_progress(project_key, config_key))
        .. format_elapsed(lw.get_elapsed(project_key, config_key))
    return status, STATUS_HL[status] or "DiagnosticWarn", progress_str, true
  end

  local status = cached and cached.state or "unconfigured"
  return status, STATUS_HL[status] or "Comment", "", false
end

--- Sort project keys: non-orphaned first (alphabetical), orphaned last.
--- @param projects table<string, loomworks.Project>
--- @return string[]
local function sorted_project_keys(projects)
  local normal, orphaned = {}, {}
  for key, proj in pairs(projects) do
    if proj.orphaned then
      orphaned[#orphaned + 1] = key
    else
      normal[#normal + 1] = key
    end
  end
  table.sort(normal)
  table.sort(orphaned)
  for _, key in ipairs(orphaned) do
    normal[#normal + 1] = key
  end
  return normal
end

-- ---------------------------------------------------------------------------
-- Deletion dialog
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
--- @param title string dialog title
--- @param plan loomworks.DeletionPlan
--- @param on_confirm fun(plan: loomworks.DeletionPlan)
local function show_delete_confirmation(title, plan, on_confirm)
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
      add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key, "DiagnosticWarn")
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
        add("      affects profiles: " .. table.concat(item.affected_profiles, ", "), "DiagnosticWarn")
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

-- ---------------------------------------------------------------------------
-- Action factories — capture context at render time, execute at action time
-- ---------------------------------------------------------------------------

local function activate_action(profile_key)
  return function()
    require("loomworks").activate_profile(profile_key)
    M.refresh()
  end
end

local function build_action(profile_key)
  return function()
    require("loomworks.overseer").run_profile_action(profile_key, "build")
  end
end

local function configure_action(profile_key)
  return function()
    require("loomworks.overseer").run_profile_action(profile_key, "configure")
  end
end

local function delete_profile_action(profile_key)
  return function()
    local lw = require("loomworks")
    local profile = lw.get_profile(profile_key)
    if not profile then return end
    local plan = profile:plan_deletion()
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
      return
    end
    show_delete_confirmation("Delete profile: " .. profile.key, plan, function(p)
      lw.execute_deletion(p, { deactivate_profile = profile.key }, function()
        vim.notify("loomworks: profile '" .. profile.key .. "' cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

local function delete_config_action(project_key, config_key)
  return function()
    local lw = require("loomworks")
    local plan = lw.plan_config_deletion(project_key, config_key)
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end
    show_delete_confirmation("Delete: " .. project_key .. " / " .. config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

local function delete_configuration_action(project_key, config_name)
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
    show_delete_confirmation("Delete configuration: " .. project_key .. " / " .. config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Render helpers
-- ---------------------------------------------------------------------------

--- Render cached configuration details as leaf lines.
--- @param tree loomworks.TreeBuilder
--- @param config_status string
--- @param status_hl string
--- @param cached loomworks.CachedConfig|nil
local function render_cached_details(tree, config_status, status_hl, cached)
  tree:leaf("Status: " .. config_status, status_hl)
  if not cached then return end

  if cached.build_dir then
    tree:leaf("Build dir: " .. cached.build_dir, "Comment")
  end
  if cached.last_configured then
    tree:leaf("Last configured: " .. cached.last_configured, "Comment")
  end
  if cached.last_built then
    tree:leaf("Last built: " .. cached.last_built, "Comment")
  end
  if cached.cmake then
    if cached.cmake.generator then
      tree:leaf("Generator: " .. cached.cmake.generator, "Comment")
    end
    if cached.cmake.compiler then
      tree:leaf("Compiler: " .. cached.cmake.compiler, "Comment")
    end
  end
end

--- Render profile details when expanded.
--- @param tree loomworks.TreeBuilder
--- @param profile loomworks.Profile
local function render_profile_details(tree, profile)
  if profile.configuration_set then
    tree:leaf("Set: " .. profile.configuration_set, "Comment")
  end

  if profile.kit then
    tree:leaf("Kit: " .. profile.kit.display, "Comment")
    if profile.kit.generator then
      tree:leaf("Generator: " .. profile.kit.generator, "Comment")
    end
    if profile.kit.compiler_id then
      tree:leaf("Compiler: " .. profile.kit.compiler_id, "Comment")
    end
  end

  local lw = require("loomworks")
  local op = lw.get_operation(profile.key)
  if op and op.message then
    local op_hl = op.success and "DiagnosticOk" or "DiagnosticError"
    tree:leaf("Last: " .. op.message, op_hl)
  end

  local pps = profile:projects()
  if #pps > 0 then
    tree:group("Projects:", "Comment", function()
      for _, pp in ipairs(pps) do
        local cached = pp:cached_state()
        local config_status, status_hl, progress_str, is_spinning =
            resolve_config_status(pp.project_key, pp.config_key, cached)

        tree:node(pp.project_key .. " → " .. pp.variant .. progress_str, {
          fold_key = "profile_proj:" .. profile.key .. ":" .. pp.project_key,
          spinning = is_spinning,
          hl = status_hl,
          on_build = build_action(profile.key),
          on_configure = configure_action(profile.key),
          on_delete = delete_config_action(pp.project_key, pp.config_key),
        }, function()
          render_cached_details(tree, config_status, status_hl, cached)
        end)
      end
    end)
  end
end

--- Render configuration set details when expanded.
--- @param tree loomworks.TreeBuilder
--- @param set_name string
--- @param mappings table<string, string>
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile_key string
local function render_set_details(tree, set_name, mappings, all_profiles, active_profile_key)
  tree:group("Projects:", "Comment", function()
    local proj_names = {}
    for name in pairs(mappings) do
      proj_names[#proj_names + 1] = name
    end
    table.sort(proj_names)
    for _, pname in ipairs(proj_names) do
      tree:leaf(pname .. " → " .. mappings[pname], "Comment")
    end
  end)

  -- Collect profiles belonging to this set with tools
  local tool_profiles = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile.configuration_set == set_name and profile.kit_id then
      tool_profiles[#tool_profiles + 1] = { key = profile_key, profile = profile }
    end
  end
  table.sort(tool_profiles, function(a, b) return a.key < b.key end)

  if #tool_profiles > 0 then
    local lw = require("loomworks")
    tree:group("Tools:", "Comment", function()
      for _, entry in ipairs(tool_profiles) do
        local profile_key = entry.key
        local profile = entry.profile
        local is_active = profile_key == active_profile_key
        local profile_running = profile:is_running()
        local already_configured = profile:is_configured()

        local marker = is_active and "● " or "○ "

        local suffix, hl
        if profile_running then
          local status_label = select(1, profile:status())
          suffix = " (" .. status_label .. ")"
          local pps = profile:projects()
          local pct = aggregate_progress(pps)
          if pct then suffix = suffix .. " " .. pct .. "%" end
          suffix = suffix .. format_elapsed(lw.get_operation_elapsed(profile_key))
          hl = "DiagnosticWarn"
        elseif already_configured then
          local op = lw.get_operation(profile_key)
          if op and op.message then
            suffix = " — " .. op.message
          else
            suffix = " (configured)"
          end
          hl = is_active and "DiagnosticOk" or "DiagnosticInfo"
        else
          suffix = ""
          hl = is_active and "DiagnosticOk" or "Comment"
        end

        local display = profile.kit_id
        if profile.kit and profile.kit.display then
          display = profile.kit.display
        end

        tree:item(display .. suffix, {
          marker = marker,
          spinning = profile_running,
          hl = hl,
          on_enter = activate_action(profile_key),
          on_build = build_action(profile_key),
          on_configure = configure_action(profile_key),
          on_delete = delete_profile_action(profile_key),
        })
      end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Main render
-- ---------------------------------------------------------------------------

--- Build the status page lines and highlights.
--- @return string[] lines, table[] highlights
local function render()
  local lw = require("loomworks")
  local ws = lw.get_workspace()
  if not ws then
    return { "  No workspace loaded.", "  Use :LoomworksInit to initialize." }, {}
  end

  local active_set = lw.get_active_configuration_set()
  if not active_set then
    return { "  No workspace loaded.", "  Use :LoomworksInit to initialize." }, {}
  end

  local tree = TreeBuilder.new(M._folds, M._spinner_frame)
  tree._level = 1 -- base indentation

  -- Header
  tree:leaf("loomworks.nvim " .. lw._version, "Title")
  tree:blank()
  tree:leaf("Workspace: " .. ws.name, "Type")
  tree:leaf("Root:      " .. ws.root, "Comment")
  tree:blank()

  local all_profiles = lw.get_profiles()
  local active_profile_key = active_set.name or ""
  local config_sets = active_set.configuration_sets

  -- Collect profiles to show: configured OR currently running OR active
  local configured_profiles = {}
  local configured_set = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile:is_configured() or profile:is_running() or profile_key == active_profile_key then
      configured_profiles[#configured_profiles + 1] = profile_key
      configured_set[profile_key] = true
    end
  end
  table.sort(configured_profiles)

  local explicit_unconfigured = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile.explicit and not configured_set[profile_key] then
      explicit_unconfigured[#explicit_unconfigured + 1] = profile_key
    end
  end
  table.sort(explicit_unconfigured)

  -- Profiles section
  if #configured_profiles > 0 or #explicit_unconfigured > 0 then
    tree:leaf("Profiles", "Title")
    tree:blank()

    local function render_profile_node(profile_key)
      local profile = all_profiles[profile_key]
      local is_active = profile_key == active_profile_key
      local profile_running = profile:is_running()

      local marker = is_active and "● " or "○ "
      local hl = profile_running and "DiagnosticWarn" or (is_active and "DiagnosticOk" or nil)

      local display = profile_key
      if profile.explicit then
        display = display .. " [explicit]"
      end

      local status_label, status_hl = profile:status()
      display = display .. " (" .. status_label .. ")"
      if profile_running then
        local pps = profile:projects()
        local pct = aggregate_progress(pps)
        if pct then
          display = display .. " " .. pct .. "%"
        end
        display = display .. format_elapsed(lw.get_operation_elapsed(profile_key))
      else
        local op = lw.get_operation(profile_key)
        if op and op.message then
          display = display .. " — " .. op.message
        end
      end
      if not hl then
        hl = status_hl
      end

      tree:node(display, {
        fold_key = "profile:" .. profile_key,
        marker = marker,
        spinning = profile_running,
        hl = hl,
        on_enter = activate_action(profile_key),
        on_build = build_action(profile_key),
        on_configure = configure_action(profile_key),
        on_delete = delete_profile_action(profile_key),
      }, function()
        render_profile_details(tree, profile)
      end)
    end

    for _, profile_key in ipairs(configured_profiles) do
      render_profile_node(profile_key)
    end
    for _, profile_key in ipairs(explicit_unconfigured) do
      render_profile_node(profile_key)
    end

    tree:blank()
  end

  -- Configuration sets section
  if config_sets and next(config_sets) then
    tree:leaf("Configuration Sets", "Title")
    tree:blank()

    local set_names = {}
    for name in pairs(config_sets) do
      set_names[#set_names + 1] = name
    end
    table.sort(set_names)

    for _, set_name in ipairs(set_names) do
      local active_profile = all_profiles[active_profile_key]
      local is_active_set = active_profile and active_profile.configuration_set == set_name
      local set_hl = is_active_set and "DiagnosticOk" or nil

      tree:node(set_name, {
        fold_key = "set:" .. set_name,
        hl = set_hl,
      }, function()
        render_set_details(tree, set_name, config_sets[set_name],
          all_profiles, active_profile_key)
      end)
    end
    tree:blank()
  end

  -- Active tool details
  if active_set.kit then
    tree:leaf("Active Tool: " .. active_set.kit.display, "DiagnosticInfo")
    tree:blank()
  end

  -- Projects section
  tree:leaf("Projects", "Title")
  tree:blank()

  local projects = lw.get_projects()
  local sorted = sorted_project_keys(projects)
  for _, key in ipairs(sorted) do
    local proj = projects[key]
    local proj_running = proj:running_action()
    local is_active_project = proj.configuration ~= nil and not proj.orphaned
    local proj_hl = proj_running and "DiagnosticWarn" or (is_active_project and "DiagnosticOk" or nil)

    local type_tag = "[" .. proj.type .. "]"
    local orphan_tag = proj.orphaned and " (orphaned)" or ""
    local refresh_tag = proj.needs_refresh and " !" or ""

    tree:node(key .. " " .. type_tag .. orphan_tag .. refresh_tag, {
      fold_key = "project:" .. key,
      spinning = proj_running ~= nil,
      hl = proj_hl,
    }, function()
      tree:leaf("Path: " .. (proj.path or key), "Comment")

      if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
        for _, reason in ipairs(proj.refresh_reasons) do
          tree:leaf("! " .. reason, "DiagnosticWarn")
        end
      end

      if proj.configurations and next(proj.configurations) then
        tree:group("Configurations:", "Comment", function()
          local config_names = {}
          for name in pairs(proj.configurations) do
            config_names[#config_names + 1] = name
          end
          table.sort(config_names)

          for _, cname in ipairs(config_names) do
            local cdata = proj.configurations[cname]

            -- Check if any profile has a running task for this variant
            local config_has_running = false
            for _, profile in pairs(all_profiles) do
              local pp = profile:project(key)
              if pp and pp.variant == cname then
                if lw.get_running_action(pp.project_key, pp.config_key) then
                  config_has_running = true
                  break
                end
              end
            end

            local config_hl = config_has_running and "DiagnosticWarn" or "Comment"

            local brief = {}
            if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
            if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
            local brief_str = #brief > 0 and ("  (" .. table.concat(brief, ", ") .. ")") or ""

            tree:node(cname .. brief_str, {
              fold_key = "config:" .. key .. ":" .. cname,
              spinning = config_has_running,
              hl = config_hl,
              on_delete = delete_configuration_action(key, cname),
            }, function()
              if cdata.toolchain then
                tree:leaf("Toolchain: " .. tostring(cdata.toolchain), "Comment")
              end
              if cdata.generator then
                tree:leaf("Generator: " .. cdata.generator, "Comment")
              end

              -- List all profiles that map to this variant
              local profile_entries = {}
              for profile_key, profile in pairs(all_profiles) do
                local pp = profile:project(key)
                if pp and pp.variant == cname then
                  profile_entries[#profile_entries + 1] = {
                    profile_key = profile_key,
                    pp = pp,
                    is_active = profile_key == active_profile_key,
                  }
                end
              end

              table.sort(profile_entries, function(a, b)
                if a.is_active ~= b.is_active then return a.is_active end
                return a.profile_key < b.profile_key
              end)

              for _, entry in ipairs(profile_entries) do
                local pp = entry.pp
                local cached = pp:cached_state()
                local config_status, status_hl, progress_str, is_spinning =
                    resolve_config_status(pp.project_key, pp.config_key, cached)

                if entry.is_active and not is_spinning then
                  status_hl = "DiagnosticOk"
                end

                tree:node(entry.profile_key .. progress_str, {
                  fold_key = "config_profile:" .. key .. ":" .. cname .. ":" .. entry.profile_key,
                  spinning = is_spinning,
                  hl = status_hl,
                  on_enter = activate_action(entry.profile_key),
                  on_build = build_action(entry.profile_key),
                  on_configure = configure_action(entry.profile_key),
                  on_delete = delete_config_action(pp.project_key, pp.config_key),
                }, function()
                  render_cached_details(tree, config_status, status_hl, cached)
                end)
              end
            end)
          end
        end)
      end

      tree:blank()
    end)
  end

  M._line_meta = tree.line_meta
  return tree.lines, tree.highlights
end

-- ---------------------------------------------------------------------------
-- Buffer management
-- ---------------------------------------------------------------------------

--- Apply highlights to the buffer.
--- @param bufnr number
--- @param highlights table[]
local function apply_highlights(bufnr, highlights)
  local ns = vim.api.nvim_create_namespace("loomworks_status")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
  end
end

--- Refresh the status buffer content.
function M.refresh()
  if not M._bufnr or not vim.api.nvim_buf_is_valid(M._bufnr) then return end

  local cursor
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == M._bufnr then
      cursor = vim.api.nvim_win_get_cursor(win)
      break
    end
  end

  local lines, highlights = render()
  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
  vim.bo[M._bufnr].modifiable = false
  apply_highlights(M._bufnr, highlights)

  if cursor then
    local line_count = #lines
    if cursor[1] > line_count then cursor[1] = line_count end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == M._bufnr then
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
        break
      end
    end
  end
end

--- Start the spinner timer for animated progress display.
function M.start_spinner()
  if M._spinner_timer then return end
  if not M._bufnr or not vim.api.nvim_buf_is_valid(M._bufnr) then return end

  M._spinner_timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
    M._spinner_frame = (M._spinner_frame % #TreeBuilder.SPINNER_FRAMES) + 1
    vim.schedule(function()
      M.refresh()
    end)
  end, { ["repeat"] = -1 })
end

--- Stop the spinner timer.
function M.stop_spinner()
  if M._spinner_timer then
    vim.fn.timer_stop(M._spinner_timer)
    M._spinner_timer = nil
  end
  vim.schedule(function()
    M.refresh()
  end)
end

-- ---------------------------------------------------------------------------
-- Keybinding handlers — pure widget dispatch
-- ---------------------------------------------------------------------------

--- Toggle fold for the item under cursor.
local function on_toggle_fold()
  local w = M._line_meta[vim.api.nvim_win_get_cursor(0)[1]]
  if not w or not w.fold_key then return end
  local fk = w.fold_key
  M._folds[fk] = not M._folds[fk]
  M.refresh()
  -- Restore cursor to same widget by fold_key
  for ln, w2 in pairs(M._line_meta) do
    if w2.fold_key == fk then
      pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
      break
    end
  end
end

--- Handle <CR> — activate the item under cursor.
local function on_enter()
  local w = M._line_meta[vim.api.nvim_win_get_cursor(0)[1]]
  if w and w.on_enter then w.on_enter() end
end

--- Walk upward from cursor to find the nearest widget with the given action.
--- Stops at the first widget found (acts as a section boundary).
--- @param action_name string
--- @return function|nil
local function find_action(action_name)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for l = line, 1, -1 do
    local w = M._line_meta[l]
    if w then return w[action_name] end
  end
  return nil
end

local function on_build()
  local action = find_action("on_build")
  if action then action()
  else vim.notify("loomworks: no buildable item under cursor", vim.log.levels.WARN) end
end

local function on_configure()
  local action = find_action("on_configure")
  if action then action()
  else vim.notify("loomworks: no configurable item under cursor", vim.log.levels.WARN) end
end

local function on_delete()
  local action = find_action("on_delete")
  if action then action()
  else vim.notify("loomworks: nothing to delete under cursor", vim.log.levels.WARN) end
end

-- ---------------------------------------------------------------------------
-- Window management
-- ---------------------------------------------------------------------------

--- Open the status window.
function M.open()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == M._bufnr then
        vim.api.nvim_set_current_win(win)
        M.refresh()
        return
      end
    end
  else
    M._bufnr = vim.api.nvim_create_buf(false, true)
  end

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, M._bufnr)
  vim.api.nvim_win_set_width(win, 60)

  vim.bo[M._bufnr].buftype = "nofile"
  vim.bo[M._bufnr].bufhidden = "wipe"
  vim.bo[M._bufnr].swapfile = false
  vim.bo[M._bufnr].filetype = "loomworks"
  vim.bo[M._bufnr].modifiable = false

  local events = require("loomworks.events")

  local function on_task_started()
    M.start_spinner()
  end
  local function on_task_stopped(data)
    if not data.has_running then
      M.stop_spinner()
    end
  end
  local function on_task_result()
    M.refresh()
  end
  local function on_deletion_started()
    M.start_spinner()
    M.refresh()
  end
  local function on_deletion_completed()
    if not require("loomworks").has_running_tasks() then
      M.stop_spinner()
    end
    M.refresh()
  end
  local function on_active_set_changed()
    M.refresh()
  end

  events.on("task_started", on_task_started)
  events.on("task_stopped", on_task_stopped)
  events.on("task_result", on_task_result)
  events.on("deletion_started", on_deletion_started)
  events.on("deletion_completed", on_deletion_completed)
  events.on("active_set_changed", on_active_set_changed)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = M._bufnr,
    callback = function()
      M.stop_spinner()
      M._bufnr = nil
      events.off("task_started", on_task_started)
      events.off("task_stopped", on_task_stopped)
      events.off("task_result", on_task_result)
      events.off("deletion_started", on_deletion_started)
      events.off("deletion_completed", on_deletion_completed)
      events.off("active_set_changed", on_active_set_changed)
    end,
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local map_opts = { buffer = M._bufnr, nowait = true, silent = true }

  vim.keymap.set("n", "<CR>", on_enter, map_opts)
  vim.keymap.set("n", "<Tab>", on_toggle_fold, map_opts)
  vim.keymap.set("n", "B", on_build, map_opts)
  vim.keymap.set("n", "C", on_configure, map_opts)
  vim.keymap.set("n", "D", on_delete, map_opts)
  vim.keymap.set("n", "r", function() M.refresh() end, map_opts)
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(0, true) end, map_opts)

  if require("loomworks").has_running_tasks() then
    M.start_spinner()
  end

  M.refresh()
end

--- Close the status window if open.
function M.close()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == M._bufnr then
        vim.api.nvim_win_close(win, true)
        return
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Public API for programmatic deletion
-- ---------------------------------------------------------------------------

--- Delete a profile interactively (with confirmation dialog).
--- @param profile_key string
function M.delete_profile(profile_key)
  delete_profile_action(profile_key)()
end

--- Delete a configuration interactively (with confirmation dialog).
--- @param project_key string
--- @param config_key string
function M.delete_config(project_key, config_key)
  delete_config_action(project_key, config_key)()
end

return M
