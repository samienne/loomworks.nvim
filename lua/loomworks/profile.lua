--- loomworks/profile.lua — Profile and ProfileProject objects.
--- Profile represents a configuration_set × kit combination.
--- ProfileProject represents a single project within a profile.

local merge = require("loomworks.merge")

-- ========================== ProfileProject ==========================

--- @class loomworks.ProfileProject
--- @field project_key string
--- @field variant string configuration variant name
--- @field config_key string precomputed cache key (variant or variant:kit_id)
local ProfileProject = {}
ProfileProject.__index = ProfileProject

--- Create a ProfileProject.
--- @param profile loomworks.Profile parent Profile
--- @param project_key string
--- @param variant string configuration variant name
--- @return loomworks.ProfileProject
function ProfileProject.new(profile, project_key, variant)
  local self = setmetatable({}, ProfileProject)
  self._profile = profile
  self._core = profile._core
  self.project_key = project_key
  self.variant = variant
  -- Only modules with keyed tools get the tool_key suffix
  local ws = profile._core:get_workspace()
  local config_projects = ws and ws.config and ws.config.projects
  local project_def = config_projects and config_projects[project_key]
  if profile.tool_key and project_def
      and profile._core:module_has_keyed_tools(project_def.type) then
    self.config_key = variant .. ":" .. profile.tool_key
  else
    self.config_key = variant
  end
  return self
end

function ProfileProject:__tostring()
  return "ProfileProject(" .. self.project_key .. " @ " .. self._profile.key .. ")"
end

--- Get the resolved status for this project-in-profile.
--- Delegates to ConfigUnit for the single source of truth.
--- @return loomworks.ConfigUnitState status
function ProfileProject:status()
  local unit = self._core:get_config_unit(self.project_key, self.config_key)
  return unit:state()
end

--- Get the running action for this project-in-profile.
--- Delegates to ConfigUnit — running state is shared across all profiles
--- that reference the same (project_key, config_key) pair.
--- @return string|nil action
function ProfileProject:running_action()
  local unit = self._core:get_config_unit(self.project_key, self.config_key)
  return unit:running_action()
end

--- Check if this project-in-profile is being deleted.
--- @return boolean
function ProfileProject:is_deleting()
  local unit = self._core:get_config_unit(self.project_key, self.config_key)
  return unit:is_deleting()
end

--- Get cached state from the workspace cache.
--- @return loomworks.CachedConfig|nil
function ProfileProject:cached_state()
  local ws = self._core:get_workspace()
  if not ws or not ws.cache.projects then return nil end
  local proj = ws.cache.projects[self.project_key]
  if not proj or not proj.configurations then return nil end
  return proj.configurations[self.config_key]
end

--- Get the build directory from cache.
--- @return string|nil
function ProfileProject:build_dir()
  local cached = self:cached_state()
  return cached and cached.build_dir
end

-- ========================== Profile ==========================

--- @class loomworks.Profile
--- @field key string profile key
--- @field configuration_set? string nil for ad-hoc profiles
--- @field ad_hoc boolean true for lightweight single-config pins
--- @field project_key? string only for ad-hoc profiles
--- @field config_key? string only for ad-hoc profiles
--- @field tool_key? string cache key suffix from the keyed module
--- @field tool_data? table opaque module-specific tool data
--- @field tool_label? string display label for the tool
--- @field tool_mod_type? string which module type owns this tool
--- @field explicit boolean
--- @field mappings? table<string, string> project_key -> variant name
local Profile = {}
Profile.__index = Profile

-- Status highlight groups (semantic severity levels)
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

--- Create a new Profile object.
--- @param core loomworks.Core
--- @param key string profile key
--- @param data? { configuration_set?: string, ad_hoc?: boolean, project_key?: string, config_key?: string, tool_key?: string, tool_data?: table, tool_label?: string, tool_mod_type?: string, explicit?: boolean, mappings?: table<string, string> }
--- @return loomworks.Profile
function Profile.new(core, key, data)
  local self = setmetatable({}, Profile)
  self._core = core
  self.key = key
  self._removed = false
  if data then self:_update(data) end
  return self
end

--- Update all data fields in place (preserves table identity).
--- @param data { configuration_set?: string, ad_hoc?: boolean, project_key?: string, config_key?: string, tool_key?: string, tool_data?: table, tool_label?: string, tool_mod_type?: string, explicit?: boolean, mappings?: table<string, string> }
function Profile:_update(data)
  self._generation = self._core._generation
  self.configuration_set = data.configuration_set
  self.ad_hoc = data.ad_hoc or false
  self.project_key = data.project_key
  self.config_key = data.config_key
  self.tool_key = data.tool_key
  self.tool_data = data.tool_data
  self.tool_label = data.tool_label
  self.tool_mod_type = data.tool_mod_type
  self.explicit = data.explicit or false
  self.mappings = data.mappings

  -- Precompute valid variants for is_configured checks
  self._valid_variants = {}
  if self.mappings then
    for _, variant in pairs(self.mappings) do
      self._valid_variants[variant] = true
    end
  end
end

function Profile:__tostring()
  return "Profile(" .. self.key .. ")"
end

function Profile:__eq(other)
  return self.key == other.key
end

--- Check if this object's data may be outdated.
--- @return boolean
function Profile:is_stale()
  return self._generation ~= self._core._generation
end

--- Compute the cache key for a variant, accounting for kit_id.
--- @param variant string
--- @return string
function Profile:config_key(variant)
  if self.tool_key then
    return variant .. ":" .. self.tool_key
  end
  return variant
end

-- ---------------------------------------------------------------------------
-- Child access
-- ---------------------------------------------------------------------------

--- Get a ProfileProject for a specific project in this profile.
--- @param project_key string
--- @return loomworks.ProfileProject|nil
function Profile:project(project_key)
  if not self.mappings or not self.mappings[project_key] then return nil end
  return ProfileProject.new(self, project_key, self.mappings[project_key])
end

--- Get all ProfileProjects in this profile, sorted by project_key.
--- @return loomworks.ProfileProject[]
function Profile:projects()
  if not self.mappings then return {} end
  local result = {}
  for pname, variant in pairs(self.mappings) do
    result[#result + 1] = ProfileProject.new(self, pname, variant)
  end
  table.sort(result, function(a, b) return a.project_key < b.project_key end)
  return result
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Activate this profile.
function Profile:activate()
  self._core:activate_profile(self.key)
end

--- Deactivate this profile if it is currently active.
function Profile:deactivate()
  self._core:deactivate_profile(self.key)
end

--- Build all projects in this profile via overseer.
function Profile:build()
  require("loomworks.overseer").run_profile_action(self.key, "build")
end

--- Configure all projects in this profile via overseer.
function Profile:configure()
  require("loomworks.overseer").run_profile_action(self.key, "configure")
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Check if this profile has any configured entries in cache.
--- Uses cached profile references (value matching) instead of key parsing.
--- @return boolean
function Profile:is_configured()
  local ws = self._core:get_workspace()
  if not ws or not ws.cache then return false end

  -- Find the materialized profile in cache by value matching
  local cached_profile = merge.find_cached_profile(
    ws.cache, self.configuration_set, self.tool_data)
  if not cached_profile or not cached_profile.projects then return false end

  -- Check if any referenced configuration has actual build state
  for project_key, proj_ref in pairs(cached_profile.projects) do
    local cached_proj = ws.cache.projects and ws.cache.projects[project_key]
    if cached_proj and cached_proj.configurations then
      local cached_config = cached_proj.configurations[proj_ref.config_key]
      if cached_config and cached_config.state
          and cached_config.state ~= "unconfigured" then
        return true
      end
    end
  end
  return false
end

--- Check if this profile has any running tasks.
--- @return boolean
function Profile:is_running()
  if not self.mappings then return false end
  for _, pp in ipairs(self:projects()) do
    if pp:running_action() then return true end
  end
  return false
end

--- Compute aggregate status label and highlight group for UI display.
--- @return string label, string hl_group vim highlight group name
function Profile:status()
  local pps = self:projects()
  if #pps == 0 then return "empty", "Comment" end

  local total = #pps
  local counts = {
    unconfigured = 0,
    configured = 0,
    built = 0,
    configure_failed = 0,
    build_failed = 0,
    configuring = 0,
    building = 0,
    deleting = 0,
  }

  for _, pp in ipairs(pps) do
    local s = pp:status()
    counts[s] = (counts[s] or 0) + 1
  end

  if counts.deleting > 0 then
    return counts.deleting .. "/" .. total .. " deleting", STATUS_HL.deleting
  end

  local running = counts.configuring + counts.building
  local failed = counts.configure_failed + counts.build_failed

  if running > 0 then
    local parts = {}
    if counts.configuring > 0 then parts[#parts + 1] = counts.configuring .. " configuring" end
    if counts.building > 0 then parts[#parts + 1] = counts.building .. " building" end
    if failed > 0 then parts[#parts + 1] = failed .. " failed" end
    return table.concat(parts, ", "), STATUS_HL.configuring
  end

  if counts.built == total then return "built", STATUS_HL.built end
  if counts.configured == total then return "configured", STATUS_HL.configured end
  if counts.unconfigured == total then return "unconfigured", STATUS_HL.unconfigured end

  if failed > 0 then
    local parts = {}
    if counts.configure_failed > 0 then
      parts[#parts + 1] = counts.configure_failed .. " failed configure"
    end
    if counts.build_failed > 0 then
      parts[#parts + 1] = counts.build_failed .. " failed build"
    end
    local ok_count = counts.built + counts.configured
    if ok_count > 0 then
      parts[#parts + 1] = ok_count .. "/" .. total .. " ok"
    end
    return table.concat(parts, ", "), STATUS_HL.failed_configure
  end

  local parts = {}
  if counts.built > 0 then parts[#parts + 1] = counts.built .. " built" end
  if counts.configured > 0 then parts[#parts + 1] = counts.configured .. " configured" end
  if counts.unconfigured > 0 then parts[#parts + 1] = counts.unconfigured .. " unconfigured" end
  return table.concat(parts, ", "), STATUS_HL.configured
end

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

--- Plan a deletion of this profile's cached configs.
--- Returns a plan object with items, shared analysis, and metadata.
--- @return loomworks.DeletionPlan
function Profile:plan_deletion()
  local ws = self._core:get_workspace()
  local empty = { items = {}, profile_key = self.key, defined_in_config = false }
  if not ws then return empty end
  if not self.mappings then return empty end

  -- Build lookup: which configs are referenced by OTHER profiles.
  local other_refs = {}
  local all_profiles = self._core:get_profiles()
  for _, other in pairs(all_profiles) do
    if other.key ~= self.key then
      for _, other_pp in ipairs(other:projects()) do
        other_refs[other_pp.project_key .. "\0" .. other_pp.config_key] = true
      end
    end
  end

  -- Include ALL project/config combos with disposition
  local items = {}
  for _, pp in ipairs(self:projects()) do
    local lookup = pp.project_key .. "\0" .. pp.config_key
    items[#items + 1] = {
      project_key = pp.project_key,
      config_key = pp.config_key,
      build_dir = pp:build_dir(),
      disposition = other_refs[lookup] and "keep" or "clean",
    }
  end

  table.sort(items, function(a, b) return a.project_key < b.project_key end)

  local defined_in_config = ws.config.profiles and ws.config.profiles[self.key] or false

  return {
    items = items,
    profile_key = self.key,
    defined_in_config = defined_in_config and true or false,
  }
end

--- Delete this profile (plan + execute, no UI confirmation).
--- @param on_done? function
function Profile:delete(on_done)
  self._core:execute_deletion(
    self:plan_deletion(), { deactivate_profile = self.key }, on_done)
end

--- Clean this profile's configs: delete build dirs and reset to unconfigured.
--- Does NOT remove the profile itself.
--- @param on_done? function
function Profile:clean(on_done)
  self._core:clean_profile(self.key, on_done)
end

--- Rebuild: clean then build.
function Profile:rebuild()
  self:clean(function()
    self:build()
  end)
end

return { Profile = Profile, ProfileProject = ProfileProject }
