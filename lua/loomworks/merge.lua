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
--- @param cache_entry loomworks.CachedConfig|nil
--- @return loomworks.Status
local function resolve_status(cache_entry)
  if not cache_entry then return "unconfigured" end
  if cache_entry.state then return cache_entry.state end
  return "unconfigured"
end

--- Check if any cmake project exists in config.
--- @param config loomworks.Config
--- @return boolean
local function has_cmake_projects(config)
  for _, project in pairs(config.projects) do
    if project.type == "cmake" then return true end
  end
  return false
end

--- Check if a cached profile matches a configuration_set and tool_id by value.
--- @param cached_profile loomworks.CachedProfile
--- @param configuration_set string
--- @param tool_id string|nil
--- @return boolean
function M.cached_profile_matches(cached_profile, configuration_set, tool_id)
  if cached_profile.configuration_set ~= configuration_set then
    return false
  end
  local cached_tool_id = cached_profile.tool and cached_profile.tool.id
  return cached_tool_id == tool_id
end

--- Find a cached profile that matches a configuration_set and tool_id.
--- Matches by stored values, not by cache key.
--- @param cache loomworks.CacheData|nil
--- @param configuration_set string
--- @param tool_id string|nil
--- @return loomworks.CachedProfile|nil, string|nil cache_key
function M.find_cached_profile(cache, configuration_set, tool_id)
  if not cache or not cache.profiles then return nil, nil end
  for key, cp in pairs(cache.profiles) do
    if M.cached_profile_matches(cp, configuration_set, tool_id) then
      return cp, key
    end
  end
  return nil, nil
end

--- Resolve a tool by id: check cache first, fall back to live detection.
--- @param cache loomworks.CacheData|nil
--- @param tool_id string
--- @return loomworks.CachedTool|nil
local function resolve_tool(cache, tool_id)
  if not tool_id then return nil end

  -- Check cached profiles first (single lookup by tool id)
  if cache and cache.profiles then
    for _, profile in pairs(cache.profiles) do
      if profile.tool and profile.tool.id == tool_id then
        return profile.tool
      end
    end
  end

  -- Check cached configurations for stored tool info
  if cache and cache.projects then
    for _, cached_project in pairs(cache.projects) do
      if cached_project.configurations then
        for _, cached_config in pairs(cached_project.configurations) do
          if cached_config.tool and cached_config.tool.id == tool_id then
            return cached_config.tool
          end
        end
      end
    end
  end

  -- Fall back to live detection
  local ok, cmake_kits_mod = pcall(require, "loomworks.cmake_kits")
  if not ok then return nil end
  local tool = cmake_kits_mod.get_by_id(tool_id)
  -- Strip empty env table to avoid noisy JSON serialization
  if tool and tool.env and not next(tool.env) then
    tool.env = nil
  end
  return tool
end

--- Auto-generate profiles from configuration_sets × detected kits.
--- @param config loomworks.Config
--- @return table<string, loomworks.ProfileDef>
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

--- Get all available profiles (auto-generated from detection + explicit from loomworks.json + cached).
--- Explicit profiles override auto-generated ones with the same key.
--- Cached profiles are matched by value (configuration_set + tool properties).
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @return table<string, loomworks.ProfileDef>
function M.get_all_profiles(config, cache)
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

  -- Merge cached profiles: mark matches as materialized, add unmatched as cached-only
  if cache and cache.profiles then
    for cache_key, cached_profile in pairs(cache.profiles) do
      -- Find matching auto/explicit profile by value comparison
      local matched_key = nil
      for key, profile in pairs(profiles) do
        local profile_tool_id = profile.kit_id
        local cached_tool_id = cached_profile.tool and cached_profile.tool.id
        if profile.configuration_set == cached_profile.configuration_set
            and profile_tool_id == cached_tool_id then
          matched_key = key
          break
        end
      end

      if matched_key then
        profiles[matched_key].materialized = true
      else
        -- Cached profile with no auto/explicit counterpart (tool no longer detected)
        profiles[cache_key] = {
          configuration_set = cached_profile.configuration_set,
          kit_id = cached_profile.tool and cached_profile.tool.id or nil,
          auto_generated = false,
          materialized = true,
        }
      end
    end
  end

  return profiles
end

--- Merge all three files into the active profile projection.
--- @param workspace loomworks.Workspace
--- @return loomworks.ActiveSet
function M.merge(workspace)
  local config = workspace.config
  local user = workspace.user
  local cache = workspace.cache

  -- Get all available profiles (from detection + explicit + cached)
  local all_profiles = M.get_all_profiles(config, cache)

  -- Determine active profile — only if explicitly set in user.json
  local active_profile_key = user.active_profile
  local active_profile = nil

  if active_profile_key and all_profiles[active_profile_key] then
    active_profile = all_profiles[active_profile_key]
  else
    active_profile_key = nil
  end

  -- Resolve configuration set mappings
  local set_name = active_profile and active_profile.configuration_set or nil
  local set_mappings = nil
  if set_name and config.configuration_sets and config.configuration_sets[set_name] then
    set_mappings = config.configuration_sets[set_name]
  end

  -- Resolve tool: cache first (locked-in), detection fallback (new profiles)
  local kit_id = active_profile and active_profile.kit_id or nil
  local tool = resolve_tool(cache, kit_id)

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
      tool_id = project.type == "cmake" and kit_id or nil,
      tool = project.type == "cmake" and tool or nil,
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

  return {
    name = active_profile_key,
    profile = active_profile,
    all_profiles = all_profiles,
    kit = tool,
    kit_id = kit_id,
    projects = projects,
    configuration_sets = config.configuration_sets,
  }
end

--- Resolve project contexts for a specific profile without changing the active profile.
--- Used for running tasks against a non-active profile.
--- @param ws loomworks.Workspace
--- @param profile_key string
--- @return table<string, loomworks.MergedProjectData>|nil
function M.resolve_profile_projects(ws, profile_key)
  local all_profiles = M.get_all_profiles(ws.config, ws.cache)
  local profile = all_profiles[profile_key]
  if not profile then return nil end

  local set_name = profile.configuration_set
  local set_mappings = nil
  if set_name and ws.config.configuration_sets and ws.config.configuration_sets[set_name] then
    set_mappings = ws.config.configuration_sets[set_name]
  end

  local kit_id = profile.kit_id
  local tool = resolve_tool(ws.cache, kit_id)

  local projects = {}
  for key, project in pairs(ws.config.projects) do
    local mod = modules.get(project.type)
    local abs_path = ws.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config) or { configurations = {} }

    local active_configuration = set_mappings and set_mappings[key] or nil

    local cache_config_key = nil
    if active_configuration then
      if kit_id and project.type == "cmake" then
        cache_config_key = active_configuration .. ":" .. kit_id
      else
        cache_config_key = active_configuration
      end
    end

    projects[key] = {
      type = project.type,
      path = project.path,
      configuration = active_configuration,
      configuration_key = cache_config_key,
      tool_id = project.type == "cmake" and kit_id or nil,
      tool = project.type == "cmake" and tool or nil,
      configurations = mod_info.configurations or {},
    }
  end

  return projects
end

return M
