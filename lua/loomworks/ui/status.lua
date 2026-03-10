--- loomworks/ui/status.lua — Pure rendering for the workspace status page.
--- All business logic accessed via require("loomworks") API.

local M = {}

local merge = require("loomworks.merge")

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

--- @type table<number, { kind: string, key: string, project?: string, set_name?: string }>
M._line_meta = {}

--- @type number|nil timer handle for spinner
M._spinner_timer = nil

--- @type number spinner frame index
M._spinner_frame = 1

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 80

local STATUS_ICONS = {
  unconfigured     = "  ",
  configured       = "  ",
  built            = "  ",
  failed_configure = "  ",
  failed_build     = "  ",
  configuring      = "  ",
  building         = "  ",
  deleting         = "  ",
}

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

--- Get the current spinner character.
--- @return string
local function spinner()
  return SPINNER_FRAMES[M._spinner_frame] .. " "
end

--- Resolve the live status for a project+config_key combination.
--- This is the single source of truth for configuration status resolution,
--- used by both the Projects and Profiles sections.
--- @param project_key string
--- @param config_key string
--- @param cached loomworks.CachedConfig|nil
--- @return string status, string icon, string hl_group, string progress_str
local function resolve_config_status(project_key, config_key, cached)
  local lw = require("loomworks")

  if lw.is_deleting(project_key, config_key) then
    return "deleting", spinner(), STATUS_HL.deleting, ""
  end

  local running_action = lw.get_running_action(project_key, config_key)
  if running_action then
    local status = running_action == "configure" and "configuring" or "building"
    local progress_str = format_progress(lw.get_progress(project_key, config_key))
        .. format_elapsed(lw.get_elapsed(project_key, config_key))
    return status, spinner(), STATUS_HL[status] or "DiagnosticWarn", progress_str
  end

  local status = cached and cached.state or "unconfigured"
  return status, STATUS_ICONS[status] or "  ", STATUS_HL[status] or "Comment", ""
end

--- Render the expanded details for a cached configuration.
--- @param add function
--- @param config_status string
--- @param status_hl string
--- @param cached loomworks.CachedConfig|nil
local function render_cached_details(add, config_status, status_hl, cached)
  add("            Status: " .. config_status, status_hl)
  if not cached then return end

  if cached.build_dir then
    add("            Build dir: " .. cached.build_dir, "Comment")
  end
  if cached.last_configured then
    add("            Last configured: " .. cached.last_configured, "Comment")
  end
  if cached.last_built then
    add("            Last built: " .. cached.last_built, "Comment")
  end
  if cached.cmake then
    if cached.cmake.generator then
      add("            Generator: " .. cached.cmake.generator, "Comment")
    end
    if cached.cmake.compiler then
      add("            Compiler: " .. cached.cmake.compiler, "Comment")
    end
  end
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

--- Render profile details when expanded.
--- @param add function
--- @param profile loomworks.Profile
local function render_profile_details(add, profile)
  if profile.configuration_set then
    add("      Set: " .. profile.configuration_set, "Comment")
  end

  -- Kit info
  if profile.kit then
    add("      Kit: " .. profile.kit.display, "Comment")
    if profile.kit.generator then
      add("      Generator: " .. profile.kit.generator, "Comment")
    end
    if profile.kit.compiler_id then
      add("      Compiler: " .. profile.kit.compiler_id, "Comment")
    end
  end

  -- Operation result
  local lw = require("loomworks")
  local op = lw.get_operation(profile.key)
  if op and op.message then
    local op_hl = op.success and "DiagnosticOk" or "DiagnosticError"
    add("      Last: " .. op.message, op_hl)
  end

  -- Project mappings — uses same resolve_config_status as project configurations section
  local pps = profile:projects()
  if #pps > 0 then
    add("      Projects:", "Comment")

    for _, pp in ipairs(pps) do
      local cached = pp:cached_state()
      local config_status, status_icon, status_hl, progress_str =
          resolve_config_status(pp.project_key, pp.config_key, cached)

      local fold_key = "profile_proj:" .. profile.key .. ":" .. pp.project_key
      local folded = M._folds[fold_key] ~= false

      local fold_char = folded and "▶" or "▼"
      add("        " .. fold_char .. " " .. status_icon .. pp.project_key .. " → " .. pp.variant .. progress_str, status_hl,
        { kind = "profile_project", key = pp.project_key, project = profile.key })

      if not folded then
        render_cached_details(add, config_status, status_hl, cached)
      end
    end
  end
end

--- Render configuration set details when expanded.
--- @param add function
--- @param set_name string
--- @param mappings table<string, string> project_key -> variant
--- @param detected_kits loomworks.CmakeKit[]
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile_key string
local function render_set_details(add, set_name, mappings, detected_kits, all_profiles, active_profile_key)
  -- Project mappings
  add("      Projects:", "Comment")
  local proj_names = {}
  for name in pairs(mappings) do
    proj_names[#proj_names + 1] = name
  end
  table.sort(proj_names)
  for _, pname in ipairs(proj_names) do
    add("        " .. pname .. " → " .. mappings[pname], "Comment")
  end

  -- Available kits
  if #detected_kits > 0 then
    add("      Kits:", "Comment")
    for _, kit in ipairs(detected_kits) do
      local profile_key = merge.profile_key(set_name, kit.id)
      local is_active = profile_key == active_profile_key
      local profile = all_profiles[profile_key]
      local already_configured = profile and profile:is_configured() or false
      local marker = is_active and "●" or "○"
      local kit_hl = is_active and "DiagnosticOk" or (already_configured and "DiagnosticInfo" or "Comment")

      local suffix = already_configured and " (configured)" or ""
      add("        " .. marker .. " " .. kit.display .. suffix, kit_hl,
        { kind = "set_kit", key = kit.id, set_name = set_name })
    end
  else
    local profile_key = set_name
    local is_active = profile_key == active_profile_key
    local marker = is_active and "●" or "○"
    local hl = is_active and "DiagnosticOk" or "Comment"
    add("        " .. marker .. " (no kits detected)", hl,
      { kind = "profile", key = profile_key })
  end
end

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

  local lines = {}
  local highlights = {}
  M._line_meta = {}

  local function add(text, hl, meta)
    lines[#lines + 1] = text
    local ln = #lines
    if hl then
      highlights[#highlights + 1] = { line = ln, col_start = 0, col_end = -1, hl_group = hl }
    end
    if meta then
      M._line_meta[ln] = meta
    end
  end

  -- Header
  add("  loomworks.nvim " .. lw._version, "Title")
  add("")

  -- Workspace info
  add("  Workspace: " .. ws.name, "Type")
  add("  Root:      " .. ws.root, "Comment")
  add("")

  local all_profiles = lw.get_profiles()
  local active_profile_key = active_set.name or ""
  local config_sets = active_set.configuration_sets
  local detected_kits = active_set.detected_kits or {}

  -- Collect profiles to show: configured (cache) OR currently running OR active profile
  local configured_profiles = {}
  local configured_set = {}
  for profile_key, profile in pairs(all_profiles) do
    local dominated = profile:is_configured()
        or profile:is_running()
        or profile_key == active_profile_key
    if dominated then
      configured_profiles[#configured_profiles + 1] = profile_key
      configured_set[profile_key] = true
    end
  end
  table.sort(configured_profiles)

  -- Also include explicit profiles that aren't already shown
  local explicit_unconfigured = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile.explicit and not configured_set[profile_key] then
      explicit_unconfigured[#explicit_unconfigured + 1] = profile_key
    end
  end
  table.sort(explicit_unconfigured)

  -- Profiles section
  if #configured_profiles > 0 or #explicit_unconfigured > 0 then
    add("  Profiles", "Title")
    add("")

    local function render_profile_line(profile_key)
      local profile = all_profiles[profile_key]
      local is_active = profile_key == active_profile_key
      local profile_running = profile:is_running()

      local marker
      if profile_running then
        marker = spinner()
      else
        marker = is_active and "● " or "○ "
      end
      local hl = profile_running and "DiagnosticWarn" or (is_active and "DiagnosticOk" or nil)

      local profile_fold_key = "profile:" .. profile_key
      local folded = M._folds[profile_fold_key] ~= false
      local fold_char = folded and "▶ " or "▼ "

      local display = profile_key
      if profile.explicit then
        display = display .. " [explicit]"
      end

      -- Aggregate profile status
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

      add("   " .. marker .. fold_char .. display, hl, { kind = "profile", key = profile_key })

      if not folded then
        render_profile_details(add, profile)
      end
    end

    for _, profile_key in ipairs(configured_profiles) do
      render_profile_line(profile_key)
    end
    for _, profile_key in ipairs(explicit_unconfigured) do
      render_profile_line(profile_key)
    end

    add("")
  end

  -- Configuration sets section
  if config_sets and next(config_sets) then
    add("  Configuration Sets", "Title")
    add("")

    local set_names = {}
    for name in pairs(config_sets) do
      set_names[#set_names + 1] = name
    end
    table.sort(set_names)

    for _, set_name in ipairs(set_names) do
      local set_fold_key = "set:" .. set_name
      local set_folded = M._folds[set_fold_key] ~= false

      local active_profile = all_profiles[active_profile_key]
      local is_active_set = active_profile and active_profile.configuration_set == set_name

      local fold_char = set_folded and "▶ " or "▼ "
      local set_hl = is_active_set and "DiagnosticOk" or nil
      add("   " .. fold_char .. set_name, set_hl, { kind = "set", key = set_name })

      if not set_folded then
        render_set_details(add, set_name, config_sets[set_name], detected_kits,
          all_profiles, active_profile_key)
      end
    end
    add("")
  end

  -- Active profile details
  if active_set.kit then
    add("  Active Kit: " .. active_set.kit.display, "DiagnosticInfo")
    add("")
  end

  -- Projects (profile-independent structural view)
  add("  Projects", "Title")
  add("")

  local projects = lw.get_projects()
  local sorted = sorted_project_keys(projects)
  for _, key in ipairs(sorted) do
    local proj = projects[key]
    local proj_fold_key = "project:" .. key
    local proj_folded = M._folds[proj_fold_key] ~= false

    -- Show spinner if any task is running for this project
    local proj_running = proj:running_action()
    local proj_icon = proj_running and spinner() or "  "

    -- Highlight if active profile includes this project
    local is_active_project = proj.configuration ~= nil and not proj.orphaned
    local proj_hl = proj_running and "DiagnosticWarn" or (is_active_project and "DiagnosticOk" or nil)

    local fold_char = proj_folded and "▶ " or "▼ "
    local type_tag = "[" .. proj.type .. "]"
    local orphan_tag = proj.orphaned and " (orphaned)" or ""
    local refresh_tag = proj.needs_refresh and " !" or ""

    local header = "  " .. fold_char .. proj_icon .. key .. " " .. type_tag .. orphan_tag .. refresh_tag
    add(header, proj_hl, { kind = "project", key = key })

    if not proj_folded then
      add("      Path: " .. (proj.path or key), "Comment")

      if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
        for _, reason in ipairs(proj.refresh_reasons) do
          add("      ! " .. reason, "DiagnosticWarn")
        end
      end

      if proj.configurations and next(proj.configurations) then
        add("      Configurations:", "Comment")
        local config_names = {}
        for name in pairs(proj.configurations) do
          config_names[#config_names + 1] = name
        end
        table.sort(config_names)

        for _, cname in ipairs(config_names) do
          local cdata = proj.configurations[cname]

          local config_fold_key = "config:" .. key .. ":" .. cname
          local config_folded = M._folds[config_fold_key] ~= false
          local config_fold_char = config_folded and "▶" or "▼"

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

          local config_icon = config_has_running and spinner() or ""
          local config_hl = config_has_running and "DiagnosticWarn" or "Comment"

          local brief = {}
          if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
          if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
          local brief_str = #brief > 0 and ("  (" .. table.concat(brief, ", ") .. ")") or ""

          add("        " .. config_fold_char .. " " .. config_icon .. cname .. brief_str, config_hl,
            { kind = "configuration", key = cname, project = key })

          if not config_folded then
            -- Configuration-specific details (from loomworks.json, not profile)
            if cdata.toolchain then
              add("            Toolchain: " .. tostring(cdata.toolchain), "Comment")
            end
            if cdata.generator then
              add("            Generator: " .. cdata.generator, "Comment")
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

            -- Sort: active first, then alphabetical
            table.sort(profile_entries, function(a, b)
              if a.is_active ~= b.is_active then return a.is_active end
              return a.profile_key < b.profile_key
            end)

            for _, entry in ipairs(profile_entries) do
              local pp = entry.pp
              local cached = pp:cached_state()
              local config_status, status_icon, status_hl, progress_str =
                  resolve_config_status(pp.project_key, pp.config_key, cached)

              -- Highlight active profile entries
              if entry.is_active and config_status ~= "configuring"
                  and config_status ~= "building" and config_status ~= "deleting" then
                status_hl = "DiagnosticOk"
              end

              local profile_fold_key = "config_profile:" .. key .. ":" .. cname .. ":" .. entry.profile_key
              local profile_folded = M._folds[profile_fold_key] ~= false
              local profile_fold_char = profile_folded and "▶" or "▼"

              add("            " .. profile_fold_char .. " " .. status_icon .. entry.profile_key .. progress_str, status_hl,
                { kind = "config_profile", key = entry.profile_key, project = key, config = cname })

              if not profile_folded then
                render_cached_details(add, config_status, status_hl, cached)
              end
            end
          end
        end
      end

      add("")
    end
  end

  return lines, highlights
end

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

  -- Preserve cursor position during refresh
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

  -- Restore cursor position
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
    M._spinner_frame = (M._spinner_frame % #SPINNER_FRAMES) + 1
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
  -- Final refresh to show completed state
  vim.schedule(function()
    M.refresh()
  end)
end

-- ---------------------------------------------------------------------------
-- Keybinding handlers
-- ---------------------------------------------------------------------------

--- Toggle fold for the item under cursor.
local function on_toggle_fold()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local meta = M._line_meta[line]
  if not meta then return end

  local fold_key
  if meta.kind == "profile" then
    fold_key = "profile:" .. meta.key
  elseif meta.kind == "set" then
    fold_key = "set:" .. meta.key
  elseif meta.kind == "project" then
    fold_key = "project:" .. meta.key
  elseif meta.kind == "configuration" then
    fold_key = "config:" .. meta.project .. ":" .. meta.key
  elseif meta.kind == "profile_project" then
    fold_key = "profile_proj:" .. meta.project .. ":" .. meta.key
  elseif meta.kind == "config_profile" then
    fold_key = "config_profile:" .. meta.project .. ":" .. meta.config .. ":" .. meta.key
  else
    return
  end

  M._folds[fold_key] = M._folds[fold_key] == false and true or false
  M.refresh()

  -- Keep cursor on same item
  for ln, m in pairs(M._line_meta) do
    if m.kind == meta.kind and m.key == meta.key then
      if meta.kind == "configuration" or meta.kind == "profile_project" or meta.kind == "config_profile" then
        if m.project == meta.project then
          pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
          break
        end
      else
        pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
        break
      end
    end
  end
end

--- Handle <CR> — select/activate the item under cursor.
local function on_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local meta = M._line_meta[line]
  if not meta then return end

  local lw = require("loomworks")

  if meta.kind == "profile" then
    lw.activate_profile(meta.key)
    M.refresh()

  elseif meta.kind == "set_kit" then
    local profile_key = merge.profile_key(meta.set_name, meta.key)
    lw.activate_profile(profile_key)
    M.refresh()

  elseif meta.kind == "config_profile" then
    lw.activate_profile(meta.key)
    M.refresh()
  end
end

--- Resolve the profile key from the cursor's line metadata.
--- @return string|nil profile_key
local function resolve_profile_at_cursor()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local meta = M._line_meta[line]

  if meta then
    if meta.kind == "profile" then
      return meta.key
    elseif meta.kind == "set_kit" then
      return merge.profile_key(meta.set_name, meta.key)
    elseif meta.kind == "profile_project" then
      return meta.project
    elseif meta.kind == "config_profile" then
      return meta.key
    end
  end

  -- Walk upward to find the enclosing profile
  for l = line - 1, 1, -1 do
    local m = M._line_meta[l]
    if m then
      if m.kind == "profile" then
        return m.key
      elseif m.kind == "set" or m.kind == "project" then
        break
      end
    end
  end

  return nil
end

--- Handle B — build the profile under cursor.
local function on_build()
  local profile_key = resolve_profile_at_cursor()
  if not profile_key then
    vim.notify("loomworks: no profile under cursor", vim.log.levels.WARN)
    return
  end
  require("loomworks.overseer").run_profile_action(profile_key, "build")
end

--- Handle C — configure the profile under cursor.
local function on_configure()
  local profile_key = resolve_profile_at_cursor()
  if not profile_key then
    vim.notify("loomworks: no profile or kit under cursor", vim.log.levels.WARN)
    return
  end
  require("loomworks.overseer").run_profile_action(profile_key, "configure")
end

-- ---------------------------------------------------------------------------
-- Deletion UI
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

  -- Detect running tasks that will need to be stopped
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

  -- Separate shared (blocked) from deletable
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

  -- Consolidated list of directories to be deleted
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

  -- Create floating window
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

  -- Apply highlights
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

--- Handle D — delete the profile or configuration under cursor.
local function on_delete()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local meta = M._line_meta[line]
  local lw = require("loomworks")

  -- Case 1: cursor on a profile line
  if meta and meta.kind == "profile" then
    local profile = lw.get_profile(meta.key)
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
    return
  end

  -- Case 2: cursor on a configuration line within Projects section
  if meta and meta.kind == "configuration" then
    local project_key = meta.project
    local config_name = meta.key

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
    return
  end

  -- Case 3: cursor on a profile_project line
  if meta and meta.kind == "profile_project" then
    local profile_key = meta.project
    local project_key = meta.key

    local profile = lw.get_profile(profile_key)
    if not profile then return end
    local pp = profile:project(project_key)
    if not pp then return end

    local plan = lw.plan_config_deletion(project_key, pp.config_key)
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end

    show_delete_confirmation("Delete: " .. project_key .. " / " .. pp.config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
    return
  end

  -- Case 3b: cursor on a config_profile line (profile entry under a configuration)
  if meta and meta.kind == "config_profile" then
    local profile_key = meta.key
    local project_key = meta.project

    local profile = lw.get_profile(profile_key)
    if not profile then return end
    local pp = profile:project(project_key)
    if not pp then return end

    local plan = lw.plan_config_deletion(project_key, pp.config_key)
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end

    show_delete_confirmation("Delete: " .. project_key .. " / " .. pp.config_key, plan, function(p)
      lw.execute_deletion(p, nil, function()
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end)
    end)
    return
  end

  -- Case 4: try to resolve enclosing profile
  local profile_key = resolve_profile_at_cursor()
  if profile_key then
    local profile = lw.get_profile(profile_key)
    if not profile then return end
    local plan = profile:plan_deletion()
    if #plan.items == 0 then
      vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
      return
    end

    show_delete_confirmation("Delete profile: " .. profile_key, plan, function(p)
      lw.execute_deletion(p, { deactivate_profile = profile_key }, function()
        vim.notify("loomworks: profile '" .. profile_key .. "' cleaned", vim.log.levels.INFO)
      end)
    end)
    return
  end

  vim.notify("loomworks: nothing to delete under cursor", vim.log.levels.WARN)
end

-- ---------------------------------------------------------------------------
-- UI-level deletion API (interactive with confirmation dialog)
-- ---------------------------------------------------------------------------

--- Delete a profile interactively (with confirmation dialog).
--- @param profile_key string
function M.delete_profile(profile_key)
  local lw = require("loomworks")
  local profile = lw.get_profile(profile_key)
  if not profile then return end

  local plan = profile:plan_deletion()
  if #plan.items == 0 then
    vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
    return
  end

  show_delete_confirmation("Delete profile: " .. profile_key, plan, function(p)
    lw.execute_deletion(p, { deactivate_profile = profile_key }, function()
      vim.notify("loomworks: profile '" .. profile_key .. "' cleaned", vim.log.levels.INFO)
    end)
  end)
end

--- Delete a configuration interactively (with confirmation dialog).
--- @param project_key string
--- @param config_key string
function M.delete_config(project_key, config_key)
  local lw = require("loomworks")
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

-- ---------------------------------------------------------------------------
-- Window management
-- ---------------------------------------------------------------------------

--- Open the status window.
function M.open()
  -- Reuse existing buffer if valid
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

  -- Wire up event-driven updates
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

  -- Stop spinner and unregister events when buffer is wiped
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

  -- Start spinner if tasks are already running
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

return M
