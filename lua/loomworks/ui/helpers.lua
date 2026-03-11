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
  unconfigured     = "Comment",
  configured       = "DiagnosticInfo",
  built            = "DiagnosticOk",
  failed_configure = "DiagnosticError",
  failed_build     = "DiagnosticError",
  configuring      = "DiagnosticWarn",
  building         = "DiagnosticWarn",
  deleting         = "DiagnosticError",
}

--- Resolve the live status for a ProfileProject.
--- Uses profile-scoped running check to prevent cross-profile state leakage.
--- @param pp loomworks.ProfileProject
--- @param cached loomworks.CachedConfig|nil
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status(pp, cached)
  local lw = require("loomworks")

  if pp:is_deleting() then
    return "deleting", M.STATUS_HL.deleting, "", true
  end

  local running_action = pp:running_action()
  if running_action then
    local status = running_action == "configure" and "configuring" or "building"
    local progress_str = M.format_progress(lw.get_progress(pp.project_key, pp.config_key))
        .. M.format_elapsed(lw.get_elapsed(pp.project_key, pp.config_key))
    return status, M.STATUS_HL[status] or "DiagnosticWarn", progress_str, true
  end

  local status = cached and cached.state or "unconfigured"
  return status, M.STATUS_HL[status] or "Comment", "", false
end

--- Resolve the live status for a project+config using global running check.
--- Used by the Projects section which is profile-agnostic.
--- @param project_key string
--- @param config_key string
--- @param cached loomworks.CachedConfig|nil
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.resolve_config_status_global(project_key, config_key, cached)
  local lw = require("loomworks")

  if lw.is_deleting(project_key, config_key) then
    return "deleting", M.STATUS_HL.deleting, "", true
  end

  local running_action = lw.get_running_action(project_key, config_key)
  if running_action then
    local status = running_action == "configure" and "configuring" or "building"
    local progress_str = M.format_progress(lw.get_progress(project_key, config_key))
        .. M.format_elapsed(lw.get_elapsed(project_key, config_key))
    return status, M.STATUS_HL[status] or "DiagnosticWarn", progress_str, true
  end

  local status = cached and cached.state or "unconfigured"
  return status, M.STATUS_HL[status] or "Comment", "", false
end

--- Render cached configuration details as leaf lines.
--- @param tree loomworks.Tree
--- @param config_status string
--- @param status_hl string
--- @param cached loomworks.CachedConfig|nil
function M.render_cached_details(tree, config_status, status_hl, cached)
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

return M
