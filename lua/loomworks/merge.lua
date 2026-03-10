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

-- ---------------------------------------------------------------------------
-- Tool detection (generic, module-driven)
-- ---------------------------------------------------------------------------

--- Collect all unique module types present in config and cache.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @return table<string, boolean> set of module type strings
local function collect_module_types(config, cache)
  local types = {}
  if config.projects then
    for _, project in pairs(config.projects) do
      types[project.type] = true
    end
  end
  if cache and cache.projects then
    for _, cached_project in pairs(cache.projects) do
      if cached_project.type then
        types[cached_project.type] = true
      end
    end
  end
  return types
end

--- Detect tools from all modules present in the workspace.
--- Each module's detect_tools() is called; modules returning empty lists
--- are recorded as having no tools.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @return loomworks.CachedTool[] detected_tools, table<string, boolean> tool_modules
function M.detect_tools(config, cache)
  local module_types = collect_module_types(config, cache)
  local all_tools = {}
  local seen_ids = {}
  local tool_modules = {}

  for mod_type in pairs(module_types) do
    local mod = modules.get(mod_type)
    if mod and mod.detect_tools then
      local tools = mod.detect_tools()
      if #tools > 0 then
        tool_modules[mod_type] = true
        for _, tool in ipairs(tools) do
          if not seen_ids[tool.id] then
            seen_ids[tool.id] = true
            all_tools[#all_tools + 1] = tool
          end
        end
      end
    end
  end

  return all_tools, tool_modules
end

--- Compare two tools by their identity properties (not by id).
--- @param a loomworks.CachedTool|nil
--- @param b loomworks.CachedTool|nil
--- @return boolean
function M.tools_match(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  return a.compiler_path == b.compiler_path
      and a.generator == b.generator
      and (a.vcvarsall or "") == (b.vcvarsall or "")
      and (a.arch or "") == (b.arch or "")
end

--- Find a detected tool matching a cached tool by properties.
--- @param detected_tools loomworks.CachedTool[]
--- @param cached_tool loomworks.CachedTool|nil
--- @return loomworks.CachedTool|nil
function M.find_matching_tool(detected_tools, cached_tool)
  if not cached_tool then return nil end
  for _, dt in ipairs(detected_tools) do
    if M.tools_match(dt, cached_tool) then
      return dt
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Profile matching (property-based, not id-based)
-- ---------------------------------------------------------------------------

--- Check if a cached profile matches a configuration_set and tool by properties.
--- @param cached_profile loomworks.CachedProfile
--- @param configuration_set string
--- @param tool loomworks.CachedTool|nil
--- @return boolean
function M.cached_profile_matches(cached_profile, configuration_set, tool)
  if cached_profile.configuration_set ~= configuration_set then
    return false
  end
  return M.tools_match(cached_profile.tool, tool)
end

--- Find a cached profile that matches a configuration_set and tool by properties.
--- @param cache loomworks.CacheData|nil
--- @param configuration_set string
--- @param tool loomworks.CachedTool|nil
--- @return loomworks.CachedProfile|nil, string|nil cache_key
function M.find_cached_profile(cache, configuration_set, tool)
  if not cache or not cache.profiles then return nil, nil end
  for key, cp in pairs(cache.profiles) do
    if M.cached_profile_matches(cp, configuration_set, tool) then
      return cp, key
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Tool resolution
-- ---------------------------------------------------------------------------

--- Resolve a tool by kit_id: check detected tools first, then cache.
--- @param detected_tools loomworks.CachedTool[]
--- @param cache loomworks.CacheData|nil
--- @param kit_id string|nil
--- @return loomworks.CachedTool|nil
local function resolve_tool(detected_tools, cache, kit_id)
  if not kit_id then return nil end

  -- Check detected tools (same session, ids are consistent)
  for _, tool in ipairs(detected_tools) do
    if tool.id == kit_id then
      return tool
    end
  end

  -- Check cached profiles (tool may no longer be detected)
  if cache and cache.profiles then
    for _, profile in pairs(cache.profiles) do
      if profile.tool and profile.tool.id == kit_id then
        return profile.tool
      end
    end
  end

  -- Check cached configurations
  if cache and cache.projects then
    for _, cached_project in pairs(cache.projects) do
      if cached_project.configurations then
        for _, cached_config in pairs(cached_project.configurations) do
          if cached_config.tool and cached_config.tool.id == kit_id then
            return cached_config.tool
          end
        end
      end
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Profile generation
-- ---------------------------------------------------------------------------

--- Auto-generate profiles from configuration_sets × detected tools.
--- @param config loomworks.Config
--- @param detected_tools loomworks.CachedTool[]
--- @return table<string, loomworks.ProfileDef>
local function generate_auto_profiles(config, detected_tools)
  local profiles = {}

  if not config.configuration_sets then return profiles end

  if #detected_tools > 0 then
    for set_name, _ in pairs(config.configuration_sets) do
      for _, tool in ipairs(detected_tools) do
        local key = M.profile_key(set_name, tool.id)
        profiles[key] = {
          configuration_set = set_name,
          kit_id = tool.id,
          auto_generated = true,
        }
      end
    end
  else
    -- No tools detected from any module: one profile per set
    for set_name, _ in pairs(config.configuration_sets) do
      profiles[set_name] = {
        configuration_set = set_name,
        kit_id = nil,
        auto_generated = true,
      }
    end
  end

  return profiles
end

--- Get all available profiles (auto-generated + explicit + cached).
--- Explicit profiles override auto-generated ones with the same key.
--- Cached profiles are matched by tool properties (not id).
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param detected_tools loomworks.CachedTool[]
--- @return table<string, loomworks.ProfileDef>
function M.get_all_profiles(config, cache, detected_tools)
  local profiles = generate_auto_profiles(config, detected_tools or {})

  -- Merge explicit profiles from loomworks.json (they win over auto-generated)
  if config.profiles then
    for name, profile in pairs(config.profiles) do
      profiles[name] = {
        configuration_set = profile.configuration_set,
        -- Support both new format (kit_id) and legacy (cmake.kit_id)
        kit_id = profile.kit_id or (profile.cmake and profile.cmake.kit_id) or nil,
        explicit = true,
      }
    end
  end

  -- Merge cached profiles: match by tool properties, not by id
  if cache and cache.profiles then
    for cache_key, cached_profile in pairs(cache.profiles) do
      local matched_key = nil
      for key, profile in pairs(profiles) do
        -- Resolve the profile's tool object for property comparison
        local profile_tool = nil
        if profile.kit_id and detected_tools then
          for _, dt in ipairs(detected_tools) do
            if dt.id == profile.kit_id then
              profile_tool = dt
              break
            end
          end
        end
        if profile.configuration_set == cached_profile.configuration_set
            and M.tools_match(profile_tool, cached_profile.tool) then
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

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

--- Merge all three files into the active profile projection.
--- @param workspace loomworks.Workspace
--- @param detected_tools loomworks.CachedTool[]
--- @param tool_modules table<string, boolean>
--- @return loomworks.ActiveSet
function M.merge(workspace, detected_tools, tool_modules)
  detected_tools = detected_tools or {}
  tool_modules = tool_modules or {}

  local config = workspace.config
  local user = workspace.user
  local cache = workspace.cache

  -- Get all available profiles
  local all_profiles = M.get_all_profiles(config, cache, detected_tools)

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

  -- Resolve tool for active profile
  local kit_id = active_profile and active_profile.kit_id or nil
  local tool = resolve_tool(detected_tools, cache, kit_id)

  local projects = {}

  -- Process configured projects
  for key, project in pairs(config.projects) do
    local mod = modules.get(project.type)
    local abs_path = workspace.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config) or { configurations = {} }

    -- Determine active configuration for this project from set mappings
    local active_configuration = set_mappings and set_mappings[key] or nil

    -- Build the configuration key for cache lookup
    -- Only tool-providing modules get kit-qualified config keys
    local has_tools = tool_modules[project.type] or false
    local cache_config_key = nil
    if active_configuration then
      if kit_id and has_tools then
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
      tool_id = has_tools and kit_id or nil,
      tool = has_tools and tool or nil,
      status = status,
      orphaned = false,
      needs_refresh = needs_refresh,
      refresh_reasons = refresh_reasons,
      configurations = mod_info.configurations or {},
      cached = cached_config_data,
      cached_configurations = cached_configurations,
    }

    -- Add module-specific info (cmake compile_commands, targets, etc.)
    if mod and mod_info.compile_commands_from then
      projects[key].cmake = {
        compile_commands_from = mod_info.compile_commands_from,
        targets = cached_config_data and cached_config_data.cmake and cached_config_data.cmake.targets or nil,
      }
    elseif cached_config_data and cached_config_data.cmake then
      projects[key].cmake = {
        targets = cached_config_data.cmake.targets,
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
--- @param detected_tools loomworks.CachedTool[]
--- @param tool_modules table<string, boolean>
--- @return table<string, loomworks.MergedProjectData>|nil
function M.resolve_profile_projects(ws, profile_key, detected_tools, tool_modules)
  detected_tools = detected_tools or {}
  tool_modules = tool_modules or {}

  local all_profiles = M.get_all_profiles(ws.config, ws.cache, detected_tools)
  local profile = all_profiles[profile_key]
  if not profile then return nil end

  local set_name = profile.configuration_set
  local set_mappings = nil
  if set_name and ws.config.configuration_sets and ws.config.configuration_sets[set_name] then
    set_mappings = ws.config.configuration_sets[set_name]
  end

  local kit_id = profile.kit_id
  local tool = resolve_tool(detected_tools, ws.cache, kit_id)

  local projects = {}
  for key, project in pairs(ws.config.projects) do
    local mod = modules.get(project.type)
    local abs_path = ws.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config) or { configurations = {} }

    local active_configuration = set_mappings and set_mappings[key] or nil

    local has_tools = tool_modules[project.type] or false
    local cache_config_key = nil
    if active_configuration then
      if kit_id and has_tools then
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
      tool_id = has_tools and kit_id or nil,
      tool = has_tools and tool or nil,
      configurations = mod_info.configurations or {},
    }
  end

  return projects
end

return M
