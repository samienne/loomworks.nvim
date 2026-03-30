local M = {}

local modules = require("loomworks.modules")
local cache_mod = require("loomworks.cache")

--- Build a profile key from configuration set name and tools dict.
--- Single keyed module: "set_name:tool_key" (same as before).
--- Multi keyed modules: "set_name:tool_key1+tool_key2" (sorted by module type).
--- @param set_name string
--- @param tools table<string, { key: string }>|nil tools dict keyed by module type
--- @return string
function M.profile_key(set_name, tools)
    if not tools or not next(tools) then return set_name end
    local mod_types = {}
    for mt in pairs(tools) do mod_types[#mod_types + 1] = mt end
    table.sort(mod_types)
    local parts = {}
    for _, mt in ipairs(mod_types) do parts[#parts + 1] = tools[mt].key end
    return set_name .. ":" .. table.concat(parts, "+")
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
    if cache and cache.build_dirs then
        for _, cached_config in pairs(cache.build_dirs) do
            if cached_config.type then
                types[cached_config.type] = true
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

--- Check if a cached profile matches a configuration_set and tools dict.
--- @param cached_profile loomworks.CachedProfile
--- @param configuration_set string
--- @param tools table<string, { data: table }>|nil
--- @return boolean
function M.cached_profile_matches(cached_profile, configuration_set, tools)
    if cached_profile.configuration_set ~= configuration_set then
        return false
    end
    -- Both nil = match
    if not cached_profile.tools and not tools then return true end
    if not cached_profile.tools or not tools then return false end
    -- Check all tool entries match (both directions)
    for mod_type, tool in pairs(tools) do
        local cached_tool = cached_profile.tools[mod_type]
        if not cached_tool then return false end
        if not module_tools_match(mod_type, cached_tool.data, tool.data) then return false end
    end
    for mod_type in pairs(cached_profile.tools) do
        if not tools[mod_type] then return false end
    end
    return true
end

--- Find a cached profile that matches a configuration_set and tools dict.
--- @param cache loomworks.CacheData|nil
--- @param configuration_set string
--- @param tools table<string, { data: table }>|nil
--- @return loomworks.CachedProfile|nil, string|nil cache_key
function M.find_cached_profile(cache, configuration_set, tools)
    if not cache or not cache.profiles then return nil, nil end
    for key, cp in pairs(cache.profiles) do
        if M.cached_profile_matches(cp, configuration_set, tools) then
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
            if profile.tools then
                for mod_type, tool in pairs(profile.tools) do
                    if tool.key == tool_key then
                        return tool.data, tool.label, mod_type
                    end
                end
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
            -- Enrich tools dict: fill in missing key/label from module functions
            local tools = nil
            if cp.tools then
                tools = {}
                for mod_type, tool in pairs(cp.tools) do
                    local mod = modules.get(mod_type)
                    tools[mod_type] = {
                        key = tool.key
                            or (mod and mod.tool_key and tool.data
                                and mod.tool_key(tool.data))
                            or nil,
                        data = tool.data,
                        label = tool.label
                            or (mod and mod.tool_label and tool.data
                                and mod.tool_label(tool.data))
                            or nil,
                    }
                end
            end
            profiles[cache_key] = {
                configuration_set = cp.configuration_set,
                mappings = cp.mappings,
                tools = tools,
                _cached_configurations = cp.configurations,
            }
        end
    end

    -- Explicit profiles from loomworks.json
    if config.profiles then
        for name, profile in pairs(config.profiles) do
            local tk = profile.kit_id or (profile.cmake and profile.cmake.kit_id) or nil
            local td, tl, tmt = resolve_tool(tools_by_type, cache, tk)
            local tools = nil
            if tk and tmt then
                tools = { [tmt] = { key = tk, data = td, label = tl } }
            end
            profiles[name] = {
                configuration_set = profile.configuration_set,
                tools = tools,
                explicit = true,
                explicit_def = profile,
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

    -- Build set of module types present in config.projects
    local active_types = {}
    if config.projects then
        for _, proj in pairs(config.projects) do
            active_types[proj.type] = true
        end
    end

    -- Collect keyed tools only for module types with active projects
    local keyed_tools = {}
    local keyed_mod_type = nil
    for mod_type, tools in pairs(tools_by_type) do
        if active_types[mod_type] then
            for _, tool in ipairs(tools) do
                if tool.tool_key then
                    keyed_tools[#keyed_tools + 1] = tool
                    keyed_mod_type = mod_type
                end
            end
        end
    end

    for set_name in pairs(config.configuration_sets) do
        local entries = {}
        if #keyed_tools > 0 then
            for _, tool in ipairs(keyed_tools) do
                -- Build tools dict for profile_key computation
                local tools_dict = { [keyed_mod_type] = { key = tool.tool_key } }
                local pkey = M.profile_key(set_name, tools_dict)
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

--- Build a config key for a project given the variant and tool_key.
--- When tool_key is non-nil, it is appended as a suffix; otherwise bare variant.
--- @param variant string
--- @param tool_key string|nil
--- @return string config_key
function M.build_config_key(variant, tool_key)
    if tool_key then
        return variant .. ":" .. tool_key
    end
    return variant
end

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

--- Merge all three files into the active profile projection.
--- @param config loomworks.Config parsed config
--- @param active_profile_key_input string|nil active profile key from user state
--- @param cache loomworks.CacheData parsed cache data
--- @param root string workspace root path
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return loomworks.ActiveSet active_set
--- @return table<string, loomworks.ProfileDef> all_profiles
function M.merge(config, active_profile_key_input, cache, root, tools_by_type)
    tools_by_type = tools_by_type or {}

    -- Get all available profiles
    local all_profiles = M.get_all_profiles(config, cache, tools_by_type)

    -- Determine active profile
    local active_profile_key = active_profile_key_input
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

    -- Resolve tools dict for active profile
    local active_tools = active_profile and active_profile.tools or nil

    local projects = {}

    -- Process configured projects
    for key, project in pairs(config.projects) do
        local mod = modules.get(project.type)
        local abs_path = root .. "/" .. project.path
        local mod_info = mod and mod.info and mod.info(abs_path, project.type_config)
                or { configurations = {} }

        local active_configuration = set_mappings and set_mappings[key] or nil

        -- Look up tool for this project's module type from the profile's tools dict
        local project_tool = active_tools and active_tools[project.type] or nil
        local project_tool_key = project_tool and project_tool.key or nil

        local cache_config_key = nil
        if active_configuration then
            cache_config_key = M.build_config_key(
                active_configuration, project_tool_key)
        end

        local cached_config_data = nil
        local status = "unconfigured"

        -- Find matching cache entry by project_key + variant + tool_key
        if cache.build_dirs and active_configuration then
            for _, cc in pairs(cache.build_dirs) do
                if cc.project_key == key and cc.variant == active_configuration
                        and (cc.tool_key or nil) == project_tool_key then
                    cached_config_data = cc
                    break
                end
            end
            status = resolve_status(cached_config_data)
        end

        -- Collect all cached configs for this project from the flat dict
        local cached_configurations = {}
        if cache.build_dirs then
            for _, cc in pairs(cache.build_dirs) do
                if cc.project_key == key then
                    -- Build a config_key for backward compat with callers
                    local ck = M.build_config_key(cc.variant, cc.tool_key)
                    cached_configurations[ck] = cc
                end
            end
        end

        local needs_refresh = false
        local refresh_reasons = {}
        if mod and mod.inspect and next(cached_configurations) then
            local inspect_result = mod.inspect(abs_path, project.type_config, cached_configurations)
            needs_refresh = inspect_result.needs_refresh
            refresh_reasons = inspect_result.reasons
        end

        projects[key] = {
            type = project.type,
            path = project.path,
            type_config = project.type_config,
            launch = project.launch,
            configuration = active_configuration,
            configuration_key = cache_config_key,
            tool_key = project_tool_key,
            tool_data = project_tool and project_tool.data or nil,
            tool_label = project_tool and project_tool.label or nil,
            tool_mod_type = project_tool_key and project.type or nil,
            status = status,
            orphaned = false,
            needs_refresh = needs_refresh,
            refresh_reasons = refresh_reasons,
            configurations = mod_info.configurations or {},
            preset_configurations = mod_info.preset_configurations or nil,
            cached = cached_config_data,
            cached_configurations = cached_configurations,
            depends_on = project.depends_on,
        }

        -- Add module-specific info (cmake compile_commands, etc.)
        local has_cmake_info = (mod and (mod_info.compile_commands_from or mod_info.clangd))
                or (cached_config_data and cached_config_data.cmake)
        if has_cmake_info then
            projects[key].cmake = {
                compile_commands_from = mod_info and mod_info.compile_commands_from or nil,
                clangd = mod_info and mod_info.clangd or nil,
            }
        end
    end

    -- Find orphaned projects (in cache but not in config)
    if cache.build_dirs then
        -- Collect unique project_keys from cache that aren't in config
        local orphaned_projects = {} -- project_key -> { type, status }
        for _, cc in pairs(cache.build_dirs) do
            local pk = cc.project_key
            if pk and not config.projects[pk] and not orphaned_projects[pk] then
                orphaned_projects[pk] = {
                    type = cc.type or "unknown",
                    status = cc.state or "unconfigured",
                }
            elseif pk and orphaned_projects[pk] and cc.state then
                orphaned_projects[pk].status = cc.state
            end
        end

        for key, info in pairs(orphaned_projects) do
            projects[key] = {
                type = info.type,
                status = info.status,
                orphaned = true,
                needs_refresh = false,
                refresh_reasons = { "not in current loomworks.json" },
                configurations = {},
            }
        end
    end

    return {
        name = active_profile_key,
        tools = active_tools,
        projects = projects,
    }, all_profiles
end

return M
