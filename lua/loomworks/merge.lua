local M = {}

local modules = require("loomworks.modules")
local cache_mod = require("loomworks.cache")

--- Build a profile key from configuration set name and tools dict.
--- Single keyed module: "set_name:tool_key".
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

-- Segment separators in a profile key (`set:generator-family-version+tool2`).
-- A selector matches only when it aligns to these boundaries (or string
-- start/end), so a version-truncated selector resolves deterministically and
-- never crosses into a different segment.
local PROFILE_BOUNDARY = { [":"] = true, ["-"] = true, ["."] = true, ["+"] = true }

--- Match a profile selector against a list of profile keys.
--- Exact key wins; otherwise the selector must occur aligned to segment
--- boundaries on both sides — so `Debug:ninja-clang-18` resolves to
--- `Debug:ninja-clang-18.1.7` (the `.` boundary) and `…-clang-1` never matches
--- `…-clang-18`. This lets a CI matrix name a toolchain by major version
--- without pinning the runner's exact patch, while `clang-19` shorthand still
--- works interactively.
--- @param keys string[] candidate profile keys
--- @param selector string
--- @return string|nil unique_match, string[]|nil ambiguous_candidates
function M.match_profile(keys, selector)
    for _, k in ipairs(keys) do
        if k == selector then return k end
    end
    local hits = {}
    for _, k in ipairs(keys) do
        local from = 1
        while true do
            local s, e = k:find(selector, from, true)
            if not s then break end
            local before = (s == 1) and "" or k:sub(s - 1, s - 1)
            local after = (e == #k) and "" or k:sub(e + 1, e + 1)
            if (before == "" or PROFILE_BOUNDARY[before])
                and (after == "" or PROFILE_BOUNDARY[after]) then
                hits[#hits + 1] = k
                break
            end
            from = s + 1
        end
    end
    if #hits == 1 then return hits[1] end
    if #hits > 1 then return nil, hits end
    return nil, nil
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

--- Find a detected tool matching a cached tool_data by module comparator.
--- @param mod_type string
--- @param detected_tools loomworks.DetectedTool[]
--- @param cached_tool_data table|nil
--- @return loomworks.DetectedTool|nil
function M.find_matching_tool(mod_type, detected_tools, cached_tool_data)
    if not cached_tool_data then return nil end
    local mod = modules.get(mod_type)
    for _, dt in ipairs(detected_tools) do
        local match
        if mod and mod.tools_match then
            match = mod.tools_match(dt.tool_data, cached_tool_data)
        else
            match = true
        end
        if match then return dt end
    end
    return nil
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

--- Resolve tool_data by tool_key: check detected tools first, then cache build_dirs.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param cache loomworks.CacheData|nil
--- @param tool_key string|nil
--- @return table|nil tool_data, string|nil tool_label, string|nil mod_type
local function resolve_tool(tools_by_type, cache, tool_key)
    if not tool_key then return nil, nil, nil end

    local dt, mod_type = M.resolve_detected_tool(tools_by_type, tool_key)
    if dt then
        return dt.tool_data, dt.tool_label, mod_type
    end

    -- Fall back to cache: the tool may no longer be detected
    if cache and cache.build_dirs then
        for _, cc in pairs(cache.build_dirs) do
            if cc.tool_key == tool_key and cc.type then
                return cc.tool_data, nil, cc.type
            end
        end
    end

    return nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Tool collection helpers
-- ---------------------------------------------------------------------------

--- Collect keyed tools from tools_by_type, filtered to module types with active projects.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param config_projects table<string, table>|nil
--- @return loomworks.DetectedTool[] keyed_tools, string|nil keyed_mod_type
local function collect_keyed_tools(tools_by_type, config_projects)
    local active_types = {}
    if config_projects then
        for _, proj in pairs(config_projects) do
            active_types[proj.type] = true
        end
    end
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
    return keyed_tools, keyed_mod_type
end

-- ---------------------------------------------------------------------------
-- Profile collection (derived from config_sets x tools)
-- ---------------------------------------------------------------------------

--- Get all profiles: derived from configuration_sets × detected tools,
--- plus pinned profiles from user.json, plus explicit profiles from config.
--- Profiles are runtime objects — they don't live in cache.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param user_data? loomworks.UserData parsed user.json data
--- @return table<string, loomworks.ProfileDef>
function M.get_all_profiles(config, cache, tools_by_type, user_data)
    tools_by_type = tools_by_type or {}
    local profiles = {}

    -- Profiles from merged config (includes both shared and user via merge_configs).
    -- All profiles are set-based: { configuration_set, tools }.
    -- Legacy kit_id format is converted to tools dict.
    if config.profiles then
        for pkey, profile in pairs(config.profiles) do
            if profile.tools then
                -- New format: tools dict already present
                profiles[pkey] = {
                    configuration_set = profile.configuration_set,
                    tools = profile.tools,
                    sdk = profile.sdk,
                }
            elseif profile.kit_id then
                -- Legacy format: resolve kit_id to tools dict
                local tk = profile.kit_id
                local td, tl, tmt = resolve_tool(tools_by_type, cache, tk)
                local tools = nil
                if tk and tmt then
                    tools = { [tmt] = { key = tk, data = td, label = tl } }
                end
                profiles[pkey] = {
                    configuration_set = profile.configuration_set,
                    tools = tools,
                    sdk = profile.sdk,
                }
            else
                -- Minimal format: just configuration_set (may have SDK)
                profiles[pkey] = {
                    configuration_set = profile.configuration_set,
                    sdk = profile.sdk,
                }
            end
        end
    end

    return profiles
end

--- Get tool entries for the configuration sets UI.
--- Returns detected tools with their profile key.
--- @param config loomworks.Config
--- @param cache loomworks.CacheData|nil
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function M.get_tool_entries(config, cache, tools_by_type)
    tools_by_type = tools_by_type or {}
    local result = {}
    if not config.configuration_sets then return result end

    local keyed_tools, keyed_mod_type = collect_keyed_tools(tools_by_type, config.projects)

    for set_name in pairs(config.configuration_sets) do
        local entries = {}
        if #keyed_tools > 0 then
            for _, tool in ipairs(keyed_tools) do
                local tools_dict = { [keyed_mod_type] = { key = tool.tool_key } }
                local pkey = M.profile_key(set_name, tools_dict)
                entries[#entries + 1] = {
                    profile_key = pkey,
                    tool_key = tool.tool_key,
                    tool_data = tool.tool_data,
                    tool_label = tool.tool_label,
                    tool_mod_type = keyed_mod_type,
                    cached = true, -- profiles exist as runtime objects
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
--- @param user_data? loomworks.UserData parsed user.json data (for pinned profiles)
--- @return loomworks.ActiveSet active_set
--- @return table<string, loomworks.ProfileDef> all_profiles
function M.merge(config, active_profile_key_input, cache, root, tools_by_type, user_data)
    tools_by_type = tools_by_type or {}

    local all_profiles = M.get_all_profiles(config, cache, tools_by_type, user_data)

    local active_profile_key = active_profile_key_input
    local active_profile = nil

    if active_profile_key and all_profiles[active_profile_key] then
        active_profile = all_profiles[active_profile_key]
    else
        active_profile_key = nil
    end

    local set_name = active_profile and active_profile.configuration_set or nil
    local set_mappings = nil
    if set_name and config.configuration_sets and config.configuration_sets[set_name] then
        set_mappings = config.configuration_sets[set_name]
    end

    local active_tools = active_profile and active_profile.tools or nil

    local projects = {}

    for key, project in pairs(config.projects) do
        local mod = modules.get(project.type)
        local abs_path = root .. "/" .. project.path
        local mod_info = { configurations = {} }
        if mod and mod.info then
            local ok, result = pcall(mod.info, abs_path, project.type_config)
            if ok and result then
                mod_info = result
            else
                vim.notify("loomworks: module '" .. (project.type or "?")
                    .. "' info() failed for " .. key .. ": " .. tostring(result),
                    vim.log.levels.WARN)
            end
        end

        local active_configuration = set_mappings and set_mappings[key] or nil

        -- Look up the tool this project's module should consume from
        -- the profile's tools collection. Supports both shapes:
        --   * legacy dict `{ module_id → ref }` — `active_tools[mod]` is
        --     the ref directly.
        --   * new flat array `["key1", "key2"]` — resolve each key
        --     against the detected-tools/cache registry; pick the first
        --     whose module type matches this project.
        local project_tool = nil
        if active_tools then
            if vim.islist and vim.islist(active_tools) then
                for _, tk in ipairs(active_tools) do
                    local td, tl, tmt = resolve_tool(tools_by_type, cache, tk)
                    if tmt == project.type and td then
                        project_tool = { key = tk, data = td, label = tl }
                        break
                    end
                end
            else
                project_tool = active_tools[project.type]
            end
        end
        local project_tool_key = project_tool and project_tool.key or nil

        local cache_config_key = nil
        if active_configuration then
            cache_config_key = M.build_config_key(
                active_configuration, project_tool_key)
        end

        local cached_config_data = nil
        local status = "unconfigured"

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

        local cached_configurations = {}
        if cache.build_dirs then
            for _, cc in pairs(cache.build_dirs) do
                if cc.project_key == key then
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
            deploy = project.deploy,
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
            variables = project.variables,
        }

        -- Module-specific project-level info: modules return it under
        -- `module_info` in their info() output. Core stores opaquely.
        if mod_info and mod_info.module_info then
            projects[key].module_info = mod_info.module_info
        end
    end

    -- Projects in cache but no longer in config: surface them as orphaned
    if cache.build_dirs then
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
