local M = {}

local modules = require("loomworks.modules")

--- Build a profile key from configuration set name and kit id.
--- @param set_name string
--- @param kit_id string|nil
--- @return string
function M.profile_key(set_name, kit_id)
  if kit_id then
    return set_name .. ":" .. kit_id
  end
  return set_name
end

--- Parse a profile key into its components.
--- @param key string
--- @return string set_name, string|nil kit_id
function M.parse_profile_key(key)
  local set_name, kit_id = key:match("^([^:]+):(.+)$")
  if set_name then
    return set_name, kit_id
  end
  return key, nil
end

--- Determine project status from cache entry.
--- @param cache_entry table|nil
--- @return string status enum
local function resolve_status(cache_entry)
  if not cache_entry then return "unconfigured" end
  if cache_entry.state then return cache_entry.state end
  return "unconfigured"
end

--- Check if any cmake project exists in config.
--- @param config table
--- @return boolean
local function has_cmake_projects(config)
  for _, project in pairs(config.projects) do
    if project.type == "cmake" then return true end
  end
  return false
end

--- Auto-generate profiles from configuration_sets × detected kits.
--- @param config table workspace config
--- @return table<string, table> profile_key -> profile definition
local function generate_auto_profiles(config)
  local profiles = {}

  if not config.configuration_sets then return profiles end

  local cmake_present = has_cmake_projects(config)

  -- Detect kits if cmake projects exist
  local kits = {}
  if cmake_present then
    local ok, cmake_kits_mod = pcall(require, "loomworks.cmake_kits")
    if ok then
      kits = cmake_kits_mod.detect()
    end
  end

  for set_name, _ in pairs(config.configuration_sets) do
    if cmake_present and #kits > 0 then
      -- Generate one profile per set × kit
      for _, kit in ipairs(kits) do
        local key = M.profile_key(set_name, kit.id)
        profiles[key] = {
          configuration_set = set_name,
          kit_id = kit.id,
          auto_generated = true,
          cmake = {
            kit_id = kit.id,
          },
        }
      end
    else
      -- No cmake or no kits: one profile per set
      profiles[set_name] = {
        configuration_set = set_name,
        kit_id = nil,
        auto_generated = true,
      }
    end
  end

  return profiles
end

--- Get all available profiles (auto-generated + explicit from loomworks.json).
--- Explicit profiles override auto-generated ones with the same key.
--- @param config table workspace config
--- @return table<string, table> all profiles
function M.get_all_profiles(config)
  local profiles = generate_auto_profiles(config)

  -- Merge explicit profiles from loomworks.json (they win over auto-generated)
  if config.profiles then
    for name, profile in pairs(config.profiles) do
      profiles[name] = {
        configuration_set = profile.configuration_set,
        cmake = profile.cmake,
        kit_id = profile.cmake and profile.cmake.kit_id or nil,
        explicit = true,
      }
    end
  end

  return profiles
end

--- Resolve a kit object from kit_id.
--- @param kit_id string|nil
--- @return table|nil kit
local function resolve_kit(kit_id)
  if not kit_id then return nil end
  local ok, cmake_kits_mod = pcall(require, "loomworks.cmake_kits")
  if not ok then return nil end
  return cmake_kits_mod.get_by_id(kit_id)
end

--- Merge all three files into the active profile projection.
--- @param workspace table the active workspace { root, config, user, cache }
--- @return table merged active profile data
function M.merge(workspace)
  local config = workspace.config
  local user = workspace.user
  local cache = workspace.cache

  -- Get all available profiles
  local all_profiles = M.get_all_profiles(config)

  -- Determine active profile
  local active_profile_key = user.active_profile
  local active_profile = nil

  if active_profile_key and all_profiles[active_profile_key] then
    active_profile = all_profiles[active_profile_key]
  else
    -- Pick first available profile as default
    local sorted_names = {}
    for name in pairs(all_profiles) do
      sorted_names[#sorted_names + 1] = name
    end
    table.sort(sorted_names)
    if #sorted_names > 0 then
      active_profile_key = sorted_names[1]
      active_profile = all_profiles[active_profile_key]
    end
  end

  -- Resolve configuration set mappings
  local set_name = active_profile and active_profile.configuration_set or nil
  local set_mappings = nil
  if set_name and config.configuration_sets and config.configuration_sets[set_name] then
    set_mappings = config.configuration_sets[set_name]
  end

  -- Resolve kit
  local kit_id = active_profile and active_profile.kit_id or nil
  local kit = resolve_kit(kit_id)

  local projects = {}

  -- Process configured projects
  for key, project in pairs(config.projects) do
    local mod = modules.get(project.type)
    local abs_path = workspace.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config) or { configurations = {} }

    -- Determine active configuration for this project from set mappings
    local active_configuration = set_mappings and set_mappings[key] or nil

    -- Build the configuration key for cache lookup
    local cache_config_key = nil
    if active_configuration then
      if kit_id and project.type == "cmake" then
        cache_config_key = active_configuration .. ":" .. kit_id
      else
        cache_config_key = active_configuration
      end
    end

    -- Get cache data for this project
    local cached_project = cache.projects and cache.projects[key] or nil
    local cached_config_data = nil
    local status = "unconfigured"

    if cached_project and cached_project.configurations and cache_config_key then
      cached_config_data = cached_project.configurations[cache_config_key]
      status = resolve_status(cached_config_data)
    end

    -- Run module inspect if cache exists
    local needs_refresh = false
    local refresh_reasons = {}
    if mod and mod.inspect and cached_project and cached_project.configurations then
      local inspect_result = mod.inspect(abs_path, project.type_config, cached_project.configurations)
      needs_refresh = inspect_result.needs_refresh
      refresh_reasons = inspect_result.reasons
    end

    -- Collect all cached configuration states for this project
    local cached_configurations = cached_project and cached_project.configurations or {}

    projects[key] = {
      type = project.type,
      path = project.path,
      configuration = active_configuration,
      configuration_key = cache_config_key,
      kit_id = project.type == "cmake" and kit_id or nil,
      kit = project.type == "cmake" and kit or nil,
      status = status,
      orphaned = false,
      needs_refresh = needs_refresh,
      refresh_reasons = refresh_reasons,
      configurations = mod_info.configurations or {},
      cached = cached_config_data,
      cached_configurations = cached_configurations,
    }

    -- Add module-specific info
    if project.type == "cmake" then
      projects[key].cmake = {
        compile_commands_from = mod_info.compile_commands_from,
        targets = cached_config_data and cached_config_data.cmake and cached_config_data.cmake.targets or nil,
      }
    end
  end

  -- Find orphaned projects (in cache but not in config)
  if cache.projects then
    for key, cached_project in pairs(cache.projects) do
      if not config.projects[key] then
        local ptype = cached_project.type or "unknown"
        local status = "unconfigured"

        -- Find best status from any cached configuration
        if cached_project.configurations then
          for _, config_data in pairs(cached_project.configurations) do
            if config_data.state then
              status = config_data.state
            end
          end
        end

        projects[key] = {
          type = ptype,
          status = status,
          orphaned = true,
          needs_refresh = false,
          refresh_reasons = { "not in current loomworks.json" },
          configurations = {},
        }
      end
    end
  end

  -- Collect detected kits for UI
  local detected_kits = {}
  if has_cmake_projects(config) then
    local ok_kits, cmake_kits_mod = pcall(require, "loomworks.cmake_kits")
    if ok_kits then
      detected_kits = cmake_kits_mod.detect()
    end
  end

  return {
    name = active_profile_key,
    profile = active_profile,
    all_profiles = all_profiles,
    kit = kit,
    kit_id = kit_id,
    projects = projects,
    configuration_sets = config.configuration_sets,
    detected_kits = detected_kits,
  }
end

return M
