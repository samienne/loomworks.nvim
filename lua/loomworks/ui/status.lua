local M = {}

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")

--- @type number|nil buffer number for the status window
M._bufnr = nil

--- @type table<string, boolean> fold key -> folded state
--- Keys: "project:<key>", "config:<project>:<config>", "set:<name>", "profile:<key>"
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
}

local STATUS_HL = {
  unconfigured     = "Comment",
  configured       = "DiagnosticInfo",
  built            = "DiagnosticOk",
  failed_configure = "DiagnosticError",
  failed_build     = "DiagnosticError",
  configuring      = "DiagnosticWarn",
  building         = "DiagnosticWarn",
}

--- Get the current spinner character.
--- @return string
local function spinner()
  return SPINNER_FRAMES[M._spinner_frame] .. " "
end

--- Sort project keys: non-orphaned first (alphabetical), orphaned last.
--- @param projects table
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

--- Check if a profile key has any configured entries in cache.
--- Matches only when a cached config's variant belongs to the profile's
--- configuration set AND the kit matches.
--- @param profile_key string
--- @param all_profiles table
--- @param cache table
--- @param config_sets table|nil
--- @return boolean
local function is_profile_configured(profile_key, all_profiles, cache, config_sets)
  local profile = all_profiles[profile_key]
  if not profile then return false end
  if not cache.projects then return false end

  -- Collect variants that belong to this profile's configuration set
  local valid_variants = {}
  if profile.configuration_set and config_sets then
    local mappings = config_sets[profile.configuration_set]
    if mappings then
      for _, variant in pairs(mappings) do
        valid_variants[variant] = true
      end
    end
  end

  for _, cached_proj in pairs(cache.projects) do
    if cached_proj.configurations then
      for config_key, _ in pairs(cached_proj.configurations) do
        local variant, kit_id = merge.parse_profile_key(config_key)
        if kit_id == profile.kit_id and valid_variants[variant] then
          return true
        end
        -- For kitless profiles, match variant only
        if not profile.kit_id and not kit_id and valid_variants[variant] then
          return true
        end
      end
    end
  end
  return false
end

--- Resolve the cached state for a configuration.
--- @param proj table project data from merge
--- @param cname string configuration name
--- @return table|nil cached_state
local function resolve_cached_config(proj, cname)
  if not proj.cached_configurations then return nil end
  if proj.kit_id then
    local cached = proj.cached_configurations[cname .. ":" .. proj.kit_id]
    if cached then return cached end
  end
  return proj.cached_configurations[cname]
end

--- Compute an aggregate status for a profile from its constituent project states.
--- @param profile_key string
--- @param profile table
--- @param config_sets table|nil
--- @param cache table
--- @return string label, string hl_group
local function resolve_profile_status(profile_key, profile, config_sets, cache)
  if not profile.configuration_set or not config_sets then
    return "unconfigured", "Comment"
  end

  local mappings = config_sets[profile.configuration_set]
  if not mappings then return "unconfigured", "Comment" end

  local lw = require("loomworks")
  local total = 0
  local counts = {
    unconfigured = 0,
    configured = 0,
    built = 0,
    failed_configure = 0,
    failed_build = 0,
    configuring = 0,
    building = 0,
  }

  for pname, variant in pairs(mappings) do
    total = total + 1
    local config_key = profile.kit_id and (variant .. ":" .. profile.kit_id) or variant

    -- Check running state first
    local running_action = lw.get_running_action(pname, config_key)
    if running_action then
      local state = running_action == "configure" and "configuring" or "building"
      counts[state] = counts[state] + 1
    else
      local state = "unconfigured"
      if cache.projects and cache.projects[pname] and cache.projects[pname].configurations then
        local cached = cache.projects[pname].configurations[config_key]
        if cached and cached.state then
          state = cached.state
        end
      end
      counts[state] = (counts[state] or 0) + 1
    end
  end

  if total == 0 then return "empty", "Comment" end

  local running = counts.configuring + counts.building
  local failed = counts.failed_configure + counts.failed_build

  -- Running tasks take priority in display
  if running > 0 then
    local parts = {}
    if counts.configuring > 0 then parts[#parts + 1] = "configuring " .. counts.configuring end
    if counts.building > 0 then parts[#parts + 1] = "building " .. counts.building end
    if failed > 0 then parts[#parts + 1] = failed .. " failed" end
    return table.concat(parts, ", "), "DiagnosticWarn"
  end

  -- All same state
  if counts.built == total then return "built", STATUS_HL.built end
  if counts.configured == total then return "configured", STATUS_HL.configured end
  if counts.unconfigured == total then return "unconfigured", STATUS_HL.unconfigured end

  -- Failures present
  if failed > 0 then
    local parts = {}
    if counts.failed_configure > 0 then
      parts[#parts + 1] = counts.failed_configure .. " failed configure"
    end
    if counts.failed_build > 0 then
      parts[#parts + 1] = counts.failed_build .. " failed build"
    end
    local ok_count = counts.built + counts.configured
    if ok_count > 0 then
      parts[#parts + 1] = ok_count .. "/" .. total .. " ok"
    end
    return table.concat(parts, ", "), "DiagnosticError"
  end

  -- Mixed positive states
  local parts = {}
  if counts.built > 0 then parts[#parts + 1] = counts.built .. " built" end
  if counts.configured > 0 then parts[#parts + 1] = counts.configured .. " configured" end
  if counts.unconfigured > 0 then parts[#parts + 1] = counts.unconfigured .. " unconfigured" end
  return table.concat(parts, ", "), "DiagnosticInfo"
end

--- Render profile details when expanded.
--- @param add function
--- @param profile_key string
--- @param profile table
--- @param config_sets table|nil
--- @param detected_kits table
--- @param cache table
local function render_profile_details(add, profile_key, profile, config_sets, detected_kits, cache)
  if profile.configuration_set then
    add("      Set: " .. profile.configuration_set, "Comment")
  end

  -- Kit info
  if profile.kit_id then
    for _, kit in ipairs(detected_kits) do
      if kit.id == profile.kit_id then
        add("      Kit: " .. kit.display, "Comment")
        add("      Generator: " .. kit.generator, "Comment")
        if kit.compiler_id then
          add("      Compiler: " .. kit.compiler_id, "Comment")
        end
        break
      end
    end
  end

  -- Project mappings from configuration set, foldable with config details
  if profile.configuration_set and config_sets then
    local mappings = config_sets[profile.configuration_set]
    if mappings then
      add("      Projects:", "Comment")
      local proj_names = {}
      for name in pairs(mappings) do
        proj_names[#proj_names + 1] = name
      end
      table.sort(proj_names)

      local lw = require("loomworks")

      for _, pname in ipairs(proj_names) do
        local variant = mappings[pname]
        local config_key = profile.kit_id and (variant .. ":" .. profile.kit_id) or variant

        -- Look up cached state
        local cached_state = nil
        if cache.projects and cache.projects[pname] and cache.projects[pname].configurations then
          cached_state = cache.projects[pname].configurations[config_key]
        end

        -- Check running state
        local running_action = lw.get_running_action(pname, config_key)

        local config_status
        local status_icon
        if running_action then
          config_status = running_action == "configure" and "configuring" or "building"
          status_icon = spinner()
        else
          config_status = cached_state and cached_state.state or "unconfigured"
          status_icon = STATUS_ICONS[config_status] or "  "
        end
        local status_hl = STATUS_HL[config_status] or "Comment"

        local fold_key = "profile_proj:" .. profile_key .. ":" .. pname
        local folded = M._folds[fold_key] ~= false

        local fold_char = folded and "▶" or "▼"
        add("        " .. fold_char .. " " .. status_icon .. pname .. " → " .. variant, status_hl,
          { kind = "profile_project", key = pname, project = profile_key })

        if not folded and cached_state then
          add("            Status: " .. (cached_state.state or "unconfigured"), status_hl)
          if cached_state.build_dir then
            add("            Build dir: " .. cached_state.build_dir, "Comment")
          end
          if cached_state.last_configured then
            add("            Last configured: " .. cached_state.last_configured, "Comment")
          end
          if cached_state.last_built then
            add("            Last built: " .. cached_state.last_built, "Comment")
          end
          if cached_state.cmake then
            if cached_state.cmake.generator then
              add("            Generator: " .. cached_state.cmake.generator, "Comment")
            end
            if cached_state.cmake.compiler then
              add("            Compiler: " .. cached_state.cmake.compiler, "Comment")
            end
          end
        end
      end
    end
  end
end

--- Render configuration set details when expanded.
--- @param add function
--- @param set_name string
--- @param mappings table
--- @param detected_kits table
--- @param all_profiles table
--- @param active_profile_key string
--- @param cache table
--- @param config_sets table|nil
local function render_set_details(add, set_name, mappings, detected_kits, all_profiles, active_profile_key, cache, config_sets)
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
      local already_configured = is_profile_configured(profile_key, all_profiles, cache, config_sets)
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
  local ws = workspace.get()
  if not ws then
    return { "  No workspace loaded.", "  Use :LoomworksInit to initialize." }, {}
  end

  local active_set = merge.merge(ws)
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
  add("  loomworks.nvim " .. require("loomworks")._version, "Title")
  add("")

  -- Workspace info
  add("  Workspace: " .. ws.name, "Type")
  add("  Root:      " .. ws.root, "Comment")
  add("")

  local all_profiles = active_set.all_profiles or {}
  local active_profile_key = active_set.name or ""
  local config_sets = active_set.configuration_sets
  local detected_kits = active_set.detected_kits or {}

  local lw = require("loomworks")

  -- Check if a profile has any running tasks
  local function is_profile_running(profile_key)
    local profile = all_profiles[profile_key]
    if not profile then return false end
    local set_mappings = profile.configuration_set
        and config_sets and config_sets[profile.configuration_set]
    if not set_mappings then return false end

    local profile_variants = {}
    for _, variant in pairs(set_mappings) do
      profile_variants[variant] = true
    end

    for _, info in pairs(lw._running_tasks) do
      local task_variant, task_kit = merge.parse_profile_key(info.configuration_key)
      if profile_variants[task_variant] and task_kit == profile.kit_id then
        return true
      end
    end
    return false
  end

  -- Collect profiles to show: configured (cache) OR currently running OR active profile
  local configured_profiles = {}
  local configured_set = {}
  for profile_key, _ in pairs(all_profiles) do
    local dominated = is_profile_configured(profile_key, all_profiles, ws.cache, config_sets)
        or is_profile_running(profile_key)
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
      local profile_running = is_profile_running(profile_key)

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
      local status_label, status_hl = resolve_profile_status(profile_key, profile, config_sets, ws.cache)
      display = display .. " (" .. status_label .. ")"
      -- Use status hl if no stronger signal (running/active)
      if not hl then
        hl = status_hl
      end

      add("   " .. marker .. fold_char .. display, hl, { kind = "profile", key = profile_key })

      if not folded then
        render_profile_details(add, profile_key, profile, config_sets, detected_kits, ws.cache)
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
          all_profiles, active_profile_key, ws.cache, config_sets)
      end
    end
    add("")
  end

  -- Active profile details
  if active_set.kit then
    add("  Active Kit: " .. active_set.kit.display, "DiagnosticInfo")
    add("")
  end

  -- Projects
  add("  Projects", "Title")
  add("")

  local loomworks = require("loomworks")

  local sorted = sorted_project_keys(active_set.projects)
  for _, key in ipairs(sorted) do
    local proj = active_set.projects[key]
    local proj_fold_key = "project:" .. key
    local proj_folded = M._folds[proj_fold_key] ~= false

    local kit_display = ""
    if proj.kit then
      kit_display = " | " .. proj.kit.display
    end

    -- Check if any task is running for this project
    local proj_running = loomworks.get_project_running_action(key)
    local proj_status = proj.status
    local proj_icon
    if proj_running then
      proj_status = proj_running == "configure" and "configuring" or "building"
      proj_icon = spinner()
    else
      proj_icon = STATUS_ICONS[proj_status] or "  "
    end

    local fold_char = proj_folded and "▶ " or "▼ "
    local type_tag = "[" .. proj.type .. "]"
    local config_tag = proj.configuration and (" " .. proj.configuration) or ""
    local orphan_tag = proj.orphaned and " (orphaned)" or ""
    local refresh_tag = proj.needs_refresh and " !" or ""

    local header = "  " .. fold_char .. proj_icon .. key .. " " .. type_tag .. config_tag .. kit_display .. orphan_tag .. refresh_tag
    add(header, STATUS_HL[proj_status], { kind = "project", key = key })

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
          local cached_state = resolve_cached_config(proj, cname)

          -- Resolve the config key for running task lookup
          local config_cache_key = cname
          if proj.kit_id then
            config_cache_key = cname .. ":" .. proj.kit_id
          end
          local running_action = loomworks.get_running_action(key, config_cache_key)

          local config_status
          local status_icon
          local status_hl
          if running_action then
            config_status = running_action == "configure" and "configuring" or "building"
            status_icon = spinner()
            status_hl = STATUS_HL[config_status] or "DiagnosticWarn"
          else
            config_status = cached_state and cached_state.state or "unconfigured"
            status_icon = STATUS_ICONS[config_status] or "  "
            status_hl = STATUS_HL[config_status] or "Comment"
          end

          local active_marker = cname == proj.configuration and "●" or "○"

          local config_fold_key = "config:" .. key .. ":" .. cname
          local config_folded = M._folds[config_fold_key] ~= false

          local config_fold_char = config_folded and "▶" or "▼"

          local brief = {}
          if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
          if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
          local brief_str = #brief > 0 and ("  (" .. table.concat(brief, ", ") .. ")") or ""

          add("        " .. active_marker .. " " .. config_fold_char .. " " .. status_icon .. cname .. brief_str, status_hl,
            { kind = "configuration", key = cname, project = key })

          if not config_folded then
            add("            Status: " .. config_status, status_hl)

            if cached_state then
              if cached_state.build_dir then
                add("            Build dir: " .. cached_state.build_dir, "Comment")
              end
              if cached_state.last_configured then
                add("            Last configured: " .. cached_state.last_configured, "Comment")
              end
              if cached_state.last_built then
                add("            Last built: " .. cached_state.last_built, "Comment")
              end
              if cached_state.cmake then
                local cmake = cached_state.cmake
                if cmake.generator then
                  add("            Generator: " .. cmake.generator, "Comment")
                end
                if cmake.compiler then
                  add("            Compiler: " .. cmake.compiler, "Comment")
                end
              end
            end

            if cdata.toolchain then
              add("            Toolchain: " .. tostring(cdata.toolchain), "Comment")
            end
            if cdata.generator then
              add("            Generator (config): " .. cdata.generator, "Comment")
            end
          end
        end
      end

      if proj.cmake and proj.cmake.targets and next(proj.cmake.targets) then
        add("      Targets:", "Comment")
        local target_names = {}
        for name in pairs(proj.cmake.targets) do
          target_names[#target_names + 1] = name
        end
        table.sort(target_names)
        for _, tname in ipairs(target_names) do
          local tdata = proj.cmake.targets[tname]
          local built_icon = tdata.built and "" or ""
          add("        " .. built_icon .. " " .. tname .. " [" .. (tdata.type or "?") .. "]", "Comment")
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
  else
    return
  end

  M._folds[fold_key] = M._folds[fold_key] == false and true or false
  M.refresh()

  -- Keep cursor on same item
  for ln, m in pairs(M._line_meta) do
    if m.kind == meta.kind and m.key == meta.key then
      if meta.kind == "configuration" or meta.kind == "profile_project" then
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

  if meta.kind == "profile" then
    require("loomworks").activate_profile(meta.key)
    M.refresh()

  elseif meta.kind == "set_kit" then
    local profile_key = merge.profile_key(meta.set_name, meta.key)
    require("loomworks").activate_profile(profile_key)
    M.refresh()
  end
end

--- Resolve the profile key from the cursor's line metadata.
--- Works for profile lines, set_kit lines, and child lines within a profile fold.
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
      -- meta.project holds the profile_key for profile_project items
      return meta.project
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

--- Show a confirmation dialog for deleting configurations.
--- Detects running tasks, shows them in the dialog, and stops them before deleting.
--- @param title string dialog title
--- @param items table[] from collect_profile_delete_items or collect_config_delete_items
--- @param defined_in_config boolean whether the profile/config is defined in loomworks.json
--- @param on_confirm function called with items to delete
local function show_delete_confirmation(title, items, defined_in_config, on_confirm)
  local lw = require("loomworks")
  local lines = {}
  local highlights = {}

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then
      highlights[#highlights + 1] = { line = #lines, hl_group = hl }
    end
  end

  -- Make paths relative to workspace root for readability
  local ws = workspace.get()
  local ws_root = ws and vim.fs.normalize(ws.root) or nil
  local function rel_path(abs)
    if not abs or not ws_root then return abs end
    local normalized = vim.fs.normalize(abs)
    if normalized:sub(1, #ws_root) == ws_root then
      local rel = normalized:sub(#ws_root + 1)
      if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
      return rel ~= "" and rel or "."
    end
    return abs
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

  -- Separate shared (blocked) from deletable, and collect affected-profile warnings
  local to_delete = {}
  local shared = {}

  for _, item in ipairs(items) do
    if item.shared_by and #item.shared_by > 0 then
      -- Profile deletion: shared configs are blocked
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
      -- Show affected profiles as warning for single-config deletions
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
      if #running_task_ids > 0 then
        vim.notify("loomworks: stopping " .. #running_task_ids .. " running task(s)...", vim.log.levels.INFO)
        lw.stop_tasks_then(running_task_ids, function()
          on_confirm(to_delete)
        end)
      else
        on_confirm(to_delete)
      end
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
    local profile_key = meta.key
    local items = lw.collect_profile_delete_items(profile_key)
    if #items == 0 then
      vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
      return
    end

    -- Check if profile is explicitly defined in loomworks.json
    local ws = lw.get_workspace()
    local defined_in_config = ws and ws.config.profiles and ws.config.profiles[profile_key] or false

    show_delete_confirmation(
      "Delete profile: " .. profile_key,
      items,
      defined_in_config,
      function(to_delete)
        lw.deactivate_profile(profile_key)
        lw.delete_cached_configs(to_delete)
        vim.notify("loomworks: profile '" .. profile_key .. "' cleaned", vim.log.levels.INFO)
      end
    )
    return
  end

  -- Case 2: cursor on a configuration line within Projects section
  if meta and meta.kind == "configuration" then
    local project_key = meta.project
    local config_name = meta.key

    -- Resolve the config key (may include kit_id)
    local ws = lw.get_workspace()
    local active_set = lw.get_active_configuration_set()
    local proj = active_set and active_set.projects[project_key]
    local config_key = config_name
    if proj and proj.kit_id then
      config_key = config_name .. ":" .. proj.kit_id
    end

    local items = lw.collect_config_delete_items(project_key, config_key)
    if #items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end

    -- Check if this config is defined in loomworks.json
    local defined_in_config = ws and ws.config.projects[project_key] ~= nil

    show_delete_confirmation(
      "Delete configuration: " .. project_key .. " / " .. config_key,
      items,
      defined_in_config,
      function(to_delete)
        lw.delete_cached_configs(to_delete)
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end
    )
    return
  end

  -- Case 3: cursor on a profile_project line
  if meta and meta.kind == "profile_project" then
    local profile_key = meta.project
    local project_key = meta.key

    local ws = lw.get_workspace()
    local all_profiles = merge.get_all_profiles(ws.config)
    local profile = all_profiles[profile_key]
    if not profile then return end

    local config_sets = ws.config.configuration_sets
    local mappings = profile.configuration_set and config_sets and config_sets[profile.configuration_set]
    if not mappings or not mappings[project_key] then return end

    local variant = mappings[project_key]
    local config_key = profile.kit_id and (variant .. ":" .. profile.kit_id) or variant

    local items = lw.collect_config_delete_items(project_key, config_key)
    if #items == 0 then
      vim.notify("loomworks: nothing to delete", vim.log.levels.INFO)
      return
    end

    local defined_in_config = ws and ws.config.projects[project_key] ~= nil

    show_delete_confirmation(
      "Delete: " .. project_key .. " / " .. config_key,
      items,
      defined_in_config,
      function(to_delete)
        lw.delete_cached_configs(to_delete)
        vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
      end
    )
    return
  end

  -- Case 4: try to resolve enclosing profile
  local profile_key = resolve_profile_at_cursor()
  if profile_key then
    local items = lw.collect_profile_delete_items(profile_key)
    if #items == 0 then
      vim.notify("loomworks: nothing to delete for profile", vim.log.levels.INFO)
      return
    end

    local ws = lw.get_workspace()
    local defined_in_config = ws and ws.config.profiles and ws.config.profiles[profile_key] or false

    show_delete_confirmation(
      "Delete profile: " .. profile_key,
      items,
      defined_in_config,
      function(to_delete)
        lw.deactivate_profile(profile_key)
        lw.delete_cached_configs(to_delete)
        vim.notify("loomworks: profile '" .. profile_key .. "' cleaned", vim.log.levels.INFO)
      end
    )
    return
  end

  vim.notify("loomworks: nothing to delete under cursor", vim.log.levels.WARN)
end

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

  -- Stop spinner when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = M._bufnr,
    callback = function()
      M.stop_spinner()
      M._bufnr = nil
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
  local loomworks = require("loomworks")
  if next(loomworks._running_tasks) then
    M.start_spinner()
  end

  M.refresh()
end

return M
