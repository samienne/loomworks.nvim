local M = {}

local modules = require("loomworks.modules")

--- Build a profile key from configuration set name and tool key.
--- @param set_name string
--- @param tool_key string|nil
--- @return string
function M.profile_key(set_name, tool_key)
  if tool_key then
    return set_name .. ":" .. tool_key
  end
  return set_name
end


--- Build a pinned profile key from project and config keys.
--- @param project_key string
--- @param config_key string
--- @return string
function M.pinned_key(project_key, config_key)
  return project_key .. "/" .. config_key
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
--- Each module's detect_tools() is called and results enriched with
--- tool_key and tool_label from the module's interface functions.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @return table<string, loomworks.DetectedTool[]> tools_by_type
function M.detect_tools(config, cache)
  local module_types = collect_module_types(config, cache)
  local tools_by_type = {}

  for mod_type in pairs(module_types) do
    local mod = modules.get(mod_type)
    if mod and mod.detect_tools then
      local raw_tools = mod.detect_tools()
      local enriched = {}
      for _, raw in ipairs(raw_tools) do
        enriched[#enriched + 1] = {
          tool_data = raw.tool_data,
          tool_key = mod.tool_key and mod.tool_key(raw.tool_data) or nil,
          tool_label = mod.tool_label and mod.tool_label(raw.tool_data) or nil,
        }
      end
      if #enriched > 0 then
        tools_by_type[mod_type] = enriched
      end
    end
  end

  return tools_by_type
end

--- Detect tools from all modules asynchronously.
--- Calls each module's detect_tools_async sequentially, enriches results,
--- and calls callback(tools_by_type) when all complete.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param callback fun(tools_by_type: table<string, loomworks.DetectedTool[]>)
function M.detect_tools_async(config, cache, callback)
  local module_types = collect_module_types(config, cache)
  local tools_by_type = {}

  -- Collect types into a list for sequential iteration
  local type_list = {}
  for mod_type in pairs(module_types) do
    type_list[#type_list + 1] = mod_type
  end

  local idx = 0
  local function next_module()
    idx = idx + 1
    if idx > #type_list then
      callback(tools_by_type)
      return
    end

    local mod_type = type_list[idx]
    local mod = modules.get(mod_type)
    if mod and mod.detect_tools_async then
      mod.detect_tools_async(function(raw_tools)
        local enriched = {}
        for _, raw in ipairs(raw_tools) do
          enriched[#enriched + 1] = {
            tool_data = raw.tool_data,
            tool_key = mod.tool_key and mod.tool_key(raw.tool_data) or nil,
            tool_label = mod.tool_label and mod.tool_label(raw.tool_data) or nil,
          }
        end
        if #enriched > 0 then
          tools_by_type[mod_type] = enriched
        end
        next_module()
      end)
    else
      next_module()
    end
  end

  next_module()
end

--- Check if a module type has keyed tools (static, no detection needed).
--- @param mod_type string
--- @return boolean
function M.module_has_keyed_tools(mod_type)
  local mod = modules.get(mod_type)
  return mod and mod.has_keyed_tools or false
end

--- Compare two tool_data objects using the module's comparator.
--- @param mod_type string
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function module_tools_match(mod_type, a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  local mod = modules.get(mod_type)
  if mod and mod.tools_match then
    return mod.tools_match(a, b)
  end
  return true -- no comparator = always match
end

--- Find a detected tool matching a cached tool_data by module comparator.
--- @param mod_type string
--- @param detected_tools loomworks.DetectedTool[]
--- @param cached_tool_data table|nil
--- @return loomworks.DetectedTool|nil
function M.find_matching_tool(mod_type, detected_tools, cached_tool_data)
  if not cached_tool_data then return nil end
  for _, dt in ipairs(detected_tools) do
    if module_tools_match(mod_type, dt.tool_data, cached_tool_data) then
      return dt
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Profile matching (property-based, via module comparator)
-- ---------------------------------------------------------------------------

--- Check if a cached profile matches a configuration_set and tool_data.
--- @param cached_profile loomworks.CachedProfile
--- @param configuration_set string
--- @param tool_data table|nil
--- @return boolean
function M.cached_profile_matches(cached_profile, configuration_set, tool_data)
  if cached_profile.configuration_set ~= configuration_set then
    return false
  end
  local mod_type = cached_profile.tool_mod_type
  if mod_type then
    return module_tools_match(mod_type, cached_profile.tool_data, tool_data)
  end
  -- No mod_type stored: both nil = match
  return cached_profile.tool_data == nil and tool_data == nil
end

--- Find a cached profile that matches a configuration_set and tool_data.
--- @param cache loomworks.CacheData|nil
--- @param configuration_set string
--- @param tool_data table|nil
--- @return loomworks.CachedProfile|nil, string|nil cache_key
function M.find_cached_profile(cache, configuration_set, tool_data)
  if not cache or not cache.profiles then return nil, nil end
  for key, cp in pairs(cache.profiles) do
    if M.cached_profile_matches(cp, configuration_set, tool_data) then
      return cp, key
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Tool resolution
-- ---------------------------------------------------------------------------

--- Resolve a detected tool by tool_key from tools_by_type.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param tool_key string|nil
--- @return loomworks.DetectedTool|nil, string|nil mod_type
function M.resolve_detected_tool(tools_by_type, tool_key)
  if not tool_key then return nil, nil end
  for mod_type, tools in pairs(tools_by_type) do
    for _, tool in ipairs(tools) do
      if tool.tool_key == tool_key then
        return tool, mod_type
      end
    end
  end
  return nil, nil
end

--- Resolve tool_data by tool_key: check detected tools first, then cache.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param cache loomworks.CacheData|nil
--- @param tool_key string|nil
--- @return table|nil tool_data, string|nil tool_label, string|nil mod_type
local function resolve_tool(tools_by_type, cache, tool_key)
  if not tool_key then return nil, nil, nil end

  -- Check detected tools (same session)
  local dt, mod_type = M.resolve_detected_tool(tools_by_type, tool_key)
  if dt then
    return dt.tool_data, dt.tool_label, mod_type
  end

  -- Check cached profiles (tool may no longer be detected)
  if cache and cache.profiles then
    for _, profile in pairs(cache.profiles) do
      if profile.tool_key == tool_key then
        return profile.tool_data, profile.tool_label, profile.tool_mod_type
      end
    end
  end

  return nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Profile collection (cached + explicit only)
-- ---------------------------------------------------------------------------

--- Get all profiles: cached profiles + explicit profiles from loomworks.json.
--- No auto-generation — profiles only exist when materialized or declared.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table<string, loomworks.ProfileDef>
function M.get_all_profiles(config, cache, tools_by_type)
  tools_by_type = tools_by_type or {}
  local profiles = {}

  -- Cached profiles (all materialized by definition)
  if cache and cache.profiles then
    for cache_key, cp in pairs(cache.profiles) do
      local mod = cp.tool_mod_type and modules.get(cp.tool_mod_type) or nil
      profiles[cache_key] = {
        configuration_set = cp.configuration_set,
        mappings = cp.mappings,
        tool_key = cp.tool_key
            or (mod and mod.tool_key and cp.tool_data
              and mod.tool_key(cp.tool_data))
            or nil,
        tool_data = cp.tool_data,
        tool_label = cp.tool_label
            or (mod and mod.tool_label and cp.tool_data
              and mod.tool_label(cp.tool_data))
            or nil,
        tool_mod_type = cp.tool_mod_type,
        _cached_projects = cp.projects,
      }
    end
  end

  -- Explicit profiles from loomworks.json
  if config.profiles then
    for name, profile in pairs(config.profiles) do
      local tk = profile.kit_id or (profile.cmake and profile.cmake.kit_id) or nil
      local td, tl, tmt = resolve_tool(tools_by_type, cache, tk)
      profiles[name] = {
        configuration_set = profile.configuration_set,
        tool_key = tk,
        tool_data = td,
        tool_label = tl,
        tool_mod_type = tmt,
        explicit = true,
      }
    end
  end

  return profiles
end

--- Get tool entries for the configuration sets UI.
--- Returns detected tools with their materialized profile key (if cached).
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function M.get_tool_entries(config, cache, tools_by_type)
  tools_by_type = tools_by_type or {}
  local result = {}
  if not config.configuration_sets then return result end

  -- Collect keyed tools
  local keyed_tools = {}
  local keyed_mod_type = nil
  for mod_type, tools in pairs(tools_by_type) do
    for _, tool in ipairs(tools) do
      if tool.tool_key then
        keyed_tools[#keyed_tools + 1] = tool
        keyed_mod_type = mod_type
      end
    end
  end

  for set_name in pairs(config.configuration_sets) do
    local entries = {}
    if #keyed_tools > 0 then
      for _, tool in ipairs(keyed_tools) do
        local pkey = M.profile_key(set_name, tool.tool_key)
        -- Check if a cached profile exists for this combination
        local cached = cache and cache.profiles and cache.profiles[pkey] or nil
        entries[#entries + 1] = {
          profile_key = pkey,
          tool_key = tool.tool_key,
          tool_data = tool.tool_data,
          tool_label = tool.tool_label,
          tool_mod_type = keyed_mod_type,
          cached = cached ~= nil,
        }
      end
    end
    result[set_name] = entries
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Config key helpers
-- ---------------------------------------------------------------------------

--- Build a config key for a project given its module type and the profile's tool_key.
--- Modules with keyed tools get the suffix; modules without don't.
--- @param mod_type string
--- @param variant string
--- @param tool_key string|nil
--- @return string config_key
function M.build_config_key(mod_type, variant, tool_key)
  if tool_key and M.module_has_keyed_tools(mod_type) then
    return variant .. ":" .. tool_key
  end
  return variant
end

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

--- Merge all three files into the active profile projection.
--- @param workspace loomworks.Workspace
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return loomworks.ActiveSet active_set
--- @return table<string, loomworks.ProfileDef> all_profiles
function M.merge(workspace, tools_by_type)
  tools_by_type = tools_by_type or {}

  local config = workspace.config
  local user = workspace.user
  local cache = workspace.cache

  -- Get all available profiles
  local all_profiles = M.get_all_profiles(config, cache, tools_by_type)

  -- Determine active profile
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
  local tool_key = active_profile and active_profile.tool_key or nil
  local tool_data = active_profile and active_profile.tool_data or nil
  local tool_label = active_profile and active_profile.tool_label or nil
  local tool_mod_type = active_profile and active_profile.tool_mod_type or nil

  local projects = {}

  -- Process configured projects
  for key, project in pairs(config.projects) do
    local mod = modules.get(project.type)
    local abs_path = workspace.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config)
        or { configurations = {} }

    local active_configuration = set_mappings and set_mappings[key] or nil

    local cache_config_key = nil
    if active_configuration then
      cache_config_key = M.build_config_key(
        project.type, active_configuration, tool_key)
    end

    local cached_project = cache.projects and cache.projects[key] or nil
    local cached_config_data = nil
    local status = "unconfigured"

    if cached_project and cached_project.configurations and cache_config_key then
      cached_config_data = cached_project.configurations[cache_config_key]
      status = resolve_status(cached_config_data)
    end

    local needs_refresh = false
    local refresh_reasons = {}
    if mod and mod.inspect and cached_project and cached_project.configurations then
      local inspect_result = mod.inspect(abs_path, project.type_config, cached_project.configurations)
      needs_refresh = inspect_result.needs_refresh
      refresh_reasons = inspect_result.reasons
    end

    local cached_configurations = cached_project and cached_project.configurations or {}

    -- Only include tool info for projects whose module has keyed tools
    local has_keyed = M.module_has_keyed_tools(project.type)

    projects[key] = {
      type = project.type,
      path = project.path,
      configuration = active_configuration,
      configuration_key = cache_config_key,
      tool_key = has_keyed and tool_key or nil,
      tool_data = has_keyed and tool_data or nil,
      tool_label = has_keyed and tool_label or nil,
      tool_mod_type = has_keyed and tool_mod_type or nil,
      status = status,
      orphaned = false,
      needs_refresh = needs_refresh,
      refresh_reasons = refresh_reasons,
      configurations = mod_info.configurations or {},
      cached = cached_config_data,
      cached_configurations = cached_configurations,
    }

    -- Add module-specific info (cmake compile_commands, targets, etc.)
    local has_cmake_info = (mod and (mod_info.compile_commands_from or mod_info.clangd))
        or (cached_config_data and cached_config_data.cmake)
    if has_cmake_info then
      projects[key].cmake = {
        compile_commands_from = mod_info and mod_info.compile_commands_from or nil,
        clangd = mod_info and mod_info.clangd or nil,
        targets = cached_config_data and cached_config_data.cmake
            and cached_config_data.cmake.targets or nil,
      }
    end
  end

  -- Find orphaned projects (in cache but not in config)
  if cache.projects then
    for key, cached_project in pairs(cache.projects) do
      if not config.projects[key] then
        local ptype = cached_project.type or "unknown"
        local status = "unconfigured"

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
    tool_key = tool_key,
    projects = projects,
  }, all_profiles
end

--- Resolve project contexts for a specific profile without changing the active profile.
--- Accepts any table with configuration_set, tool/tool_key, tool_data, and mappings fields.
--- Profile objects duck-type as this.
--- @param ws loomworks.Workspace
--- @param profile_data table profile data (or Profile object) with configuration_set, mappings, etc.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table<string, loomworks.MergedProjectData>|nil
function M.resolve_profile_projects(ws, profile_data, tools_by_type)
  tools_by_type = tools_by_type or {}

  local set_name = profile_data.configuration_set
  local mappings = nil
  if set_name and ws.config.configuration_sets and ws.config.configuration_sets[set_name] then
    mappings = ws.config.configuration_sets[set_name]
  elseif profile_data.mappings then
    mappings = profile_data.mappings
  end
  if not mappings then return nil end

  -- Support both .tool.key (Profile objects) and .tool_key (raw data)
  local tk = profile_data.tool_key
      or (profile_data.tool and profile_data.tool.key)
  local td = profile_data.tool_data
      or (profile_data.tool and profile_data.tool.data)

  local projects = {}
  for key, project in pairs(ws.config.projects) do
    local mod = modules.get(project.type)
    local abs_path = ws.root .. "/" .. project.path
    local mod_info = mod and mod.info and mod.info(abs_path, project.type_config)
        or { configurations = {} }

    local active_configuration = mappings[key] or nil

    local cache_config_key = nil
    if active_configuration then
      cache_config_key = M.build_config_key(
        project.type, active_configuration, tk)
    end

    local has_keyed = M.module_has_keyed_tools(project.type)

    projects[key] = {
      type = project.type,
      path = project.path,
      configuration = active_configuration,
      configuration_key = cache_config_key,
      tool_key = has_keyed and tk or nil,
      tool_data = has_keyed and td or nil,
      configurations = mod_info.configurations or {},
    }
  end

  return projects
end

return M
