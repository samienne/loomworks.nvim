--- loomworks/ui/helpers.lua — Shared rendering helpers for status sections.

local M = {}

--- Format a progress update as a compact string like "[2/10]".
--- @param p loomworks.ProgressUpdate|nil
--- @return string
function M.format_progress(p)
  if not p then return "" end
  return " [" .. p.current .. "/" .. p.total .. "]"
end

--- Format elapsed seconds as a compact duration like "1m23s" or "42s".
--- @param seconds number|nil
--- @return string
function M.format_elapsed(seconds)
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
--- @param pps loomworks.ProfileProject[]
--- @return number|nil percentage 0-100
function M.aggregate_progress(pps)
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

M.STATUS_HL = {
  unconfigured     = "LoomworksUnconfigured",
  configured       = "LoomworksConfigured",
  built            = "LoomworksBuilt",
  failed_configure = "LoomworksFailed",
  failed_build     = "LoomworksFailed",
  configuring      = "LoomworksRunning",
  building         = "LoomworksRunning",
  deleting         = "LoomworksDeleting",
}

M.STATUS_ICON = {
  unconfigured     = "○",
  configured       = "◆",
  built            = "✔",
  failed_configure = "✘",
  failed_build     = "✘",
}

--- Format a status label with its icon prefix.
--- Running/deleting states use the spinner so no icon is added.
--- Composite labels (e.g. "1 building, 1 failed") pass through unchanged.
--- @param status string
--- @return string
function M.format_status(status)
  local icon = M.STATUS_ICON[status]
  if icon then
    return icon .. " " .. status
  end
  return status
end

--- Resolve the live status for a ConfigUnit.
--- Used by both profile and project sections — ConfigUnit is the single source of truth.
--- @param unit loomworks.ConfigUnit
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_unit_status(unit)
  local state = unit:state()
  if state == "deleting" then
    return "deleting", M.STATUS_HL.deleting, "", true
  end
  if state == "configuring" or state == "building" then
    local progress_str = M.format_progress(unit:progress())
        .. M.format_elapsed(unit:elapsed())
    return state, M.STATUS_HL[state] or "DiagnosticWarn", progress_str, true
  end
  -- Map ConfigUnit state names back to cache state names for HL lookup
  local cache_state = state
  if state == "configure_failed" then cache_state = "failed_configure" end
  if state == "build_failed" then cache_state = "failed_build" end
  return cache_state, M.STATUS_HL[cache_state] or "Comment", "", false
end

--- Resolve the live status for a ProfileProject.
--- @param pp loomworks.ProfileProject
--- @param cached loomworks.CachedConfig|nil (unused, kept for API compat)
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status(pp, cached)
  local lw = require("loomworks")
  local unit = lw.get_config_unit(pp.project_key, pp.config_key)
  return M.resolve_unit_status(unit)
end

--- Resolve the live status for a project+config (profile-agnostic).
--- @param project_key string
--- @param config_key string
--- @param cached loomworks.CachedConfig|nil (unused, kept for API compat)
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status_global(project_key, config_key, cached)
  local lw = require("loomworks")
  local unit = lw.get_config_unit(project_key, config_key)
  return M.resolve_unit_status(unit)
end

--- Render cached configuration details as leaf lines.
--- @param tree loomworks.Tree
--- @param config_status string
--- @param status_hl string
--- @param cached loomworks.CachedConfig|nil
function M.render_cached_details(tree, config_status, status_hl, cached)
  tree:leaf("Status: " .. M.format_status(config_status), status_hl)
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

return M
