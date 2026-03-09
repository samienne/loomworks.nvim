local M = {}

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")

--- @type number|nil buffer number for the status window
M._bufnr = nil

--- @type table<string, boolean> fold key -> folded state
--- Keys: "project:<key>", "config:<project>:<config>", "set:<name>"
M._folds = {}

--- @type table<number, { kind: string, key: string, project?: string, set_name?: string }>
M._line_meta = {}

local STATUS_ICONS = {
  unconfigured     = "  ",
  configured       = "  ",
  built            = "  ",
  failed_configure = "  ",
  failed_build     = "  ",
}

local STATUS_HL = {
  unconfigured     = "Comment",
  configured       = "DiagnosticInfo",
  built            = "DiagnosticOk",
  failed_configure = "DiagnosticError",
  failed_build     = "DiagnosticError",
}

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
--- @param profile_key string
--- @param all_profiles table
--- @param cache table
--- @return boolean
local function is_profile_configured(profile_key, all_profiles, cache)
  local profile = all_profiles[profile_key]
  if not profile or not profile.kit_id then return false end
  if not cache.projects then return false end

  for _, cached_proj in pairs(cache.projects) do
    if cached_proj.configurations then
      for config_key, _ in pairs(cached_proj.configurations) do
        if config_key:find(profile.kit_id, 1, true) then
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

  -- Collect configured profiles (have cache entries)
  local configured_profiles = {}
  for profile_key, _ in pairs(all_profiles) do
    if is_profile_configured(profile_key, all_profiles, ws.cache) then
      configured_profiles[#configured_profiles + 1] = profile_key
    end
  end
  table.sort(configured_profiles)

  -- Also include explicit profiles that may not have cache entries yet
  local explicit_profiles = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile.explicit and not is_profile_configured(profile_key, all_profiles, ws.cache) then
      explicit_profiles[#explicit_profiles + 1] = profile_key
    end
  end
  table.sort(explicit_profiles)

  -- Configured profiles section
  if #configured_profiles > 0 or #explicit_profiles > 0 then
    add("  Profiles", "Title")
    add("")

    for _, profile_key in ipairs(configured_profiles) do
      local is_active = profile_key == active_profile_key
      local marker = is_active and "   ● " or "   ○ "
      local hl = is_active and "DiagnosticOk" or nil

      local profile = all_profiles[profile_key]
      local display = profile_key
      if profile.explicit then
        display = display .. " [explicit]"
      end

      add(marker .. display, hl, { kind = "profile", key = profile_key })
    end

    for _, profile_key in ipairs(explicit_profiles) do
      local is_active = profile_key == active_profile_key
      local marker = is_active and "   ● " or "   ○ "
      local hl = is_active and "DiagnosticOk" or "Comment"
      add(marker .. profile_key .. " [explicit]", hl, { kind = "profile", key = profile_key })
    end

    add("")
  end

  -- Configuration sets section (for creating new profiles)
  local config_sets = active_set.configuration_sets
  local detected_kits = active_set.detected_kits or {}

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
      local set_folded = M._folds[set_fold_key] ~= false -- default folded

      -- Check if the active profile belongs to this set
      local active_profile = all_profiles[active_profile_key]
      local is_active_set = active_profile and active_profile.configuration_set == set_name

      local fold_char = set_folded and "▶ " or "▼ "
      local set_hl = is_active_set and "DiagnosticOk" or nil
      add("   " .. fold_char .. set_name, set_hl, { kind = "set", key = set_name })

      if not set_folded then
        if #detected_kits > 0 then
          for _, kit in ipairs(detected_kits) do
            local profile_key = merge.profile_key(set_name, kit.id)
            local is_active = profile_key == active_profile_key
            local already_configured = is_profile_configured(profile_key, all_profiles, ws.cache)
            local marker = is_active and "●" or "○"
            local kit_hl = is_active and "DiagnosticOk" or (already_configured and "DiagnosticInfo" or "Comment")

            local suffix = already_configured and " (configured)" or ""
            add("      " .. marker .. " " .. kit.display .. suffix, kit_hl,
              { kind = "set_kit", key = kit.id, set_name = set_name })
          end
        else
          -- No kits available, selecting the set directly creates a kitless profile
          local profile_key = set_name
          local is_active = profile_key == active_profile_key
          local marker = is_active and "●" or "○"
          local hl = is_active and "DiagnosticOk" or "Comment"
          add("      " .. marker .. " (no kits detected)", hl,
            { kind = "profile", key = profile_key })
        end
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

  local sorted = sorted_project_keys(active_set.projects)
  for _, key in ipairs(sorted) do
    local proj = active_set.projects[key]
    local proj_fold_key = "project:" .. key
    local proj_folded = M._folds[proj_fold_key] ~= false -- default folded

    -- Resolve active kit display for header
    local kit_display = ""
    if proj.kit then
      kit_display = " | " .. proj.kit.display
    end

    -- Project header line
    local fold_char = proj_folded and "▶ " or "▼ "
    local icon = STATUS_ICONS[proj.status] or "  "
    local type_tag = "[" .. proj.type .. "]"
    local config_tag = proj.configuration and (" " .. proj.configuration) or ""
    local orphan_tag = proj.orphaned and " (orphaned)" or ""
    local refresh_tag = proj.needs_refresh and " !" or ""

    local header = "  " .. fold_char .. icon .. key .. " " .. type_tag .. config_tag .. kit_display .. orphan_tag .. refresh_tag
    add(header, STATUS_HL[proj.status], { kind = "project", key = key })

    -- Expanded project content
    if not proj_folded then
      add("      Path: " .. (proj.path or key), "Comment")

      if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
        for _, reason in ipairs(proj.refresh_reasons) do
          add("      ! " .. reason, "DiagnosticWarn")
        end
      end

      -- Show all configurations with per-configuration status
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

          local config_status = cached_state and cached_state.state or "unconfigured"
          local status_icon = STATUS_ICONS[config_status] or "  "
          local status_hl = STATUS_HL[config_status] or "Comment"

          local active_marker = cname == proj.configuration and "●" or "○"

          local config_fold_key = "config:" .. key .. ":" .. cname
          local config_folded = M._folds[config_fold_key] ~= false -- default folded

          local config_fold_char = config_folded and "▶" or "▼"

          -- Brief details on the header line
          local brief = {}
          if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
          if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
          local brief_str = #brief > 0 and ("  (" .. table.concat(brief, ", ") .. ")") or ""

          add("        " .. active_marker .. " " .. config_fold_char .. " " .. status_icon .. cname .. brief_str, status_hl,
            { kind = "configuration", key = cname, project = key })

          -- Expanded configuration content
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

      -- Show cached targets
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

  local lines, highlights = render()
  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
  vim.bo[M._bufnr].modifiable = false
  apply_highlights(M._bufnr, highlights)
end

--- Handle <CR> — context-dependent action based on cursor line.
local function on_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local meta = M._line_meta[line]
  if not meta then return end

  if meta.kind == "project" then
    local fold_key = "project:" .. meta.key
    M._folds[fold_key] = M._folds[fold_key] == false and true or false
    M.refresh()
    for ln, m in pairs(M._line_meta) do
      if m.kind == "project" and m.key == meta.key then
        pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
        break
      end
    end

  elseif meta.kind == "configuration" then
    local fold_key = "config:" .. meta.project .. ":" .. meta.key
    M._folds[fold_key] = M._folds[fold_key] == false and true or false
    M.refresh()
    for ln, m in pairs(M._line_meta) do
      if m.kind == "configuration" and m.key == meta.key and m.project == meta.project then
        pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
        break
      end
    end

  elseif meta.kind == "profile" then
    require("loomworks").activate_profile(meta.key)
    M.refresh()

  elseif meta.kind == "set" then
    -- Toggle fold on configuration set
    local fold_key = "set:" .. meta.key
    M._folds[fold_key] = M._folds[fold_key] == false and true or false
    M.refresh()
    for ln, m in pairs(M._line_meta) do
      if m.kind == "set" and m.key == meta.key then
        pcall(vim.api.nvim_win_set_cursor, 0, { ln, 0 })
        break
      end
    end

  elseif meta.kind == "set_kit" then
    -- Selecting a kit under a config set activates that profile
    local profile_key = merge.profile_key(meta.set_name, meta.key)
    require("loomworks").activate_profile(profile_key)
    M.refresh()
  end
end

--- Jump to the next/previous interactive line.
--- @param direction number 1 for forward, -1 for backward
local function jump_section(direction)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(M._bufnr)
  local line = cur + direction

  while line >= 1 and line <= line_count do
    if M._line_meta[line] then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
    line = line + direction
  end
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

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local map_opts = { buffer = M._bufnr, nowait = true, silent = true }

  vim.keymap.set("n", "<CR>", on_enter, map_opts)
  vim.keymap.set("n", "<Tab>", function() jump_section(1) end, map_opts)
  vim.keymap.set("n", "<S-Tab>", function() jump_section(-1) end, map_opts)
  vim.keymap.set("n", "r", function() M.refresh() end, map_opts)
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(0, true) end, map_opts)

  M.refresh()
end

return M
