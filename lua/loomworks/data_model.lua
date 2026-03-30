--- loomworks/data_model.lua — Deserialization module.
--- Extracts the _sync_* deserialization logic from workspace.lua into a
--- standalone, pure-data module. Exposes a single entry point: M.refresh().
--- Also exposes sync_build_dir_refs() for use by mutation methods.

local M = {}

local ConfigUnit = require("loomworks.config_unit")
local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local Project = require("loomworks.project")
local ConfigurationSet = require("loomworks.configuration_set")
local Tool = require("loomworks.tool")
local Module = require("loomworks.module")

-- ===========================================================================
-- Deserialization context
-- ===========================================================================

--- Build a temporary deserialization context from existing arrays.
--- The ctx provides O(1) key->object lookups for identity matching during sync.
--- Discarded after refresh completes.
--- @param current table { modules, projects, config_sets, profiles, config_units, profile_projects }
--- @return table ctx
local function build_ctx(current)
    local ctx = {
        modules = {},
        projects = {},
        config_sets = {},
        profiles = {},
        config_units = {},
        profile_projects = {},
    }
    for _, mod in pairs(current.modules or {}) do ctx.modules[mod.id] = mod end
    for _, p in pairs(current.projects or {}) do ctx.projects[p.key] = p end
    for _, cs in pairs(current.config_sets or {}) do ctx.config_sets[cs.name] = cs end
    for _, pr in pairs(current.profiles or {}) do ctx.profiles[pr.key] = pr end
    for _, cu in pairs(current.config_units or {}) do ctx.config_units[cu.id] = cu end
    for _, pp in pairs(current.profile_projects or {}) do
        local reg_key = pp._profile.key .. "\0" .. pp._init_project_key
        ctx.profile_projects[reg_key] = pp
    end
    return ctx
end

-- ===========================================================================
-- Sync functions (extracted from Workspace methods)
-- ===========================================================================

--- Sync Module domain objects from config projects and cache.
--- Creates Module objects for every module type referenced in the workspace.
--- @param ctx table deserialization context with O(1) lookups
--- @param config table parsed config (loomworks.json)
--- @param cache table parsed cache data
--- @param modules_registry table module registry with get() method
--- @return table[] modules array
local function sync_modules(ctx, config, cache, modules_registry)
    local needed = {}
    if config and config.projects then
        for _, project in pairs(config.projects) do
            if project.type then needed[project.type] = true end
        end
    end
    if cache and cache.build_dirs then
        for _, cc in pairs(cache.build_dirs) do
            if cc.type then needed[cc.type] = true end
        end
    end

    for id, mod in pairs(ctx.modules) do
        if not needed[id] then
            mod._removed = true
            ctx.modules[id] = nil
        end
    end

    for id in pairs(needed) do
        local impl = modules_registry.get(id)
        if impl then
            local existing = ctx.modules[id]
            if existing then
                existing:_update(impl)
                existing._removed = false
            else
                ctx.modules[id] = Module.new(id, impl)
            end
        end
    end

    local arr = {}
    for _, mod in pairs(ctx.modules) do arr[#arr + 1] = mod end
    return arr
end

--- Get or create a Tool object, delegating to the Module's tool registry.
--- Helper used by sync_tools (replaces Workspace:get_or_create_tool).
--- @param ctx table deserialization context (modules dict)
--- @param modules_arr table[] current modules array (may be extended)
--- @param modules_registry table module registry with get() method
--- @param mod_type string module type (e.g., "cmake")
--- @param tool_key string|nil opaque identifier (nil for default tools)
--- @param tool_data table module-specific data
--- @param tool_label string|nil display label
--- @return loomworks.Tool
local function get_or_create_tool(ctx, modules_arr, modules_registry, mod_type, tool_key, tool_data, tool_label)
    local mod = ctx.modules[mod_type]
    if not mod then
        local impl = modules_registry.get(mod_type)
        mod = Module.new(mod_type, impl or { id = mod_type })
        modules_arr[#modules_arr + 1] = mod
        ctx.modules[mod_type] = mod
    end
    return mod:get_or_create_tool(tool_key, tool_data, tool_label)
end

--- Sync Tool objects from detected tools (from tools_by_type) and cache data.
--- Delegates tool creation to Module objects (tools owned by modules).
--- @param ctx table deserialization context
--- @param modules_arr table[] current modules array (may be extended)
--- @param tools_by_type table<string, table[]> detected tools per module type
--- @param cache table parsed cache data
--- @param modules_registry table module registry with get() method
local function sync_tools(ctx, modules_arr, tools_by_type, cache, modules_registry)
    local seen = {}

    -- From detected tools
    for mod_type, tools in pairs(tools_by_type) do
        for _, dt in ipairs(tools) do
            local tool = get_or_create_tool(
                ctx, modules_arr, modules_registry,
                mod_type, dt.tool_key, dt.tool_data, dt.tool_label)
            seen[tool] = true
        end
    end

    -- From cache: tool_data stored inline in build_dirs
    if cache.build_dirs then
        for _, cc in pairs(cache.build_dirs) do
            if cc.tool_key and cc.type then
                local tool = get_or_create_tool(
                    ctx, modules_arr, modules_registry,
                    cc.type, cc.tool_key, cc.tool_data or {}, nil)
                seen[tool] = true
            end
        end
    end

    -- Remove tools that are no longer referenced (across all modules)
    for _, mod in pairs(modules_arr) do
        for rk, tool in pairs(mod._tools) do
            if not seen[tool] then
                tool._removed = true
                mod._tools[rk] = nil
            end
        end
    end
end

--- Sync the projects registry with current active set data.
--- Creates new Project objects, updates existing ones in place, removes stale ones.
--- Pre-resolves Module, Tool, and dependency references before calling _update.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param active_set table|nil the active set from merge
--- @return table[] projects array
local function sync_projects(ctx, workspace, active_set)
    if not active_set then return {} end
    local new_data = active_set.projects

    for key, project in pairs(ctx.projects) do
        if not new_data[key] then
            project._removed = true
            ctx.projects[key] = nil
        end
    end

    for key, data in pairs(new_data) do
        local mod = data.type and ctx.modules[data.type] or nil
        data._module = mod
        data._tool = nil
        if data.tool_key and mod then
            data._tool = mod:find_tool(data.tool_key)
        end
        data._depends_on = nil
        if data.depends_on then
            local deps = {}
            for _, dep_key in ipairs(data.depends_on) do
                local dep = ctx.projects[dep_key]
                if dep then deps[#deps + 1] = dep end
            end
            if #deps > 0 then data._depends_on = deps end
        end

        local existing = ctx.projects[key]
        if existing then
            existing:_update(data)
        else
            ctx.projects[key] = Project.new(workspace, key, data)
        end
    end

    local arr = {}
    for _, p in pairs(ctx.projects) do arr[#arr + 1] = p end
    return arr
end

--- Sync the config sets registry with current config data.
--- Runs after sync_projects so Project objects are available.
--- Pre-resolves project_key -> Project before calling _update.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param config table parsed config (loomworks.json)
--- @return table[] config_sets array
local function sync_config_sets(ctx, workspace, config)
    local defs = config.configuration_sets or {}

    for name, cs in pairs(ctx.config_sets) do
        if not defs[name] then
            cs._removed = true
            ctx.config_sets[name] = nil
        end
    end

    for name, raw_mappings in pairs(defs) do
        local resolved = {}
        for project_key, variant in pairs(raw_mappings) do
            local project = ctx.projects[project_key]
            if project then
                local cfg = project:get_configuration(variant)
                if not cfg then
                    cfg = project:ensure_configuration(variant)
                end
                if cfg then
                    resolved[project] = cfg
                end
            end
        end
        local existing = ctx.config_sets[name]
        if existing then
            existing:_update(resolved)
        else
            ctx.config_sets[name] = ConfigurationSet.new(workspace, name, resolved)
        end
    end

    local arr = {}
    for _, cs in pairs(ctx.config_sets) do arr[#arr + 1] = cs end
    return arr
end

--- Sync the profiles registry with current merge data.
--- Creates new Profile objects, updates existing ones in place, removes stale ones.
--- Pre-resolves Tool objects and ConfigurationSet before calling _apply.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param all_defs table<string, loomworks.ProfileDef> profile definitions from merge
--- @param cache table parsed cache data
--- @param default_target_data table|nil raw default_target map from user.json (profile_key -> descriptor)
--- @return table[] profiles array
local function sync_profiles(ctx, workspace, all_defs, cache, default_target_data)
    for key, profile in pairs(ctx.profiles) do
        if not all_defs[key] then
            profile._removed = true
            ctx.profiles[key] = nil
        end
    end

    for key, data in pairs(all_defs) do
        data._tool_objects = nil
        if data.tools then
            local tool_objs = {}
            for mod_type, tool_ref in pairs(data.tools) do
                local mod = ctx.modules[mod_type]
                if mod then
                    local tool = mod:find_tool(tool_ref.key)
                    if tool then tool_objs[mod] = tool end
                end
            end
            if next(tool_objs) then data._tool_objects = tool_objs end
        end
        data._config_set_ref = nil
        if data.configuration_set then
            data._config_set_ref = ctx.config_sets[data.configuration_set]
        end

        local existing = ctx.profiles[key]
        if existing then
            existing:_apply(data)
        else
            ctx.profiles[key] = Profile.new(workspace, key, data)
        end
    end

    -- Populate _default_target_descriptor from user.json data
    for key, profile in pairs(ctx.profiles) do
        profile._default_target_descriptor = default_target_data
            and default_target_data[key] or nil
    end

    local arr = {}
    for _, p in pairs(ctx.profiles) do arr[#arr + 1] = p end
    return arr
end

--- Sync the config units registry.
--- Collects all entries from cache build_dirs,
--- creates/updates/removes ConfigUnit objects. Preserves runtime state.
--- Pre-resolves project, tool, and configuration references before calling _apply.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param cache table parsed cache data
--- @return table[] config_units array
local function sync_config_units(ctx, workspace, cache)
    local expected = {}
    local cache_mod = require("loomworks.cache")

    if cache.build_dirs then
        for build_dir_key, cached_config in pairs(cache.build_dirs) do
            local project_key = cached_config.project_key
            local project = project_key and ctx.projects[project_key] or nil
            local tool = nil
            if cached_config.tool_key then
                local mod = project and project._module
                    or (cached_config.type and ctx.modules[cached_config.type])
                if mod then tool = mod:find_tool(cached_config.tool_key) end
            end
            local configuration = nil
            local variant = cached_config.variant
            if variant and project then
                configuration = project:get_configuration(variant)
            end
            -- Enrich cached_config with build_dir computed from the key
            local enriched = vim.tbl_extend("keep", cached_config, {
                build_dir = cache_mod.absolute_build_dir(build_dir_key, workspace.root),
            })
            expected[build_dir_key] = {
                project_key = project_key,
                cached = enriched,
                project = project,
                tool = tool,
                configuration = configuration,
            }
        end
    end

    for id, unit in pairs(ctx.config_units) do
        if not expected[id] and not unit:is_running() and not unit:is_deleting() then
            unit._removed = true
            ctx.config_units[id] = nil
        end
    end

    for id, data in pairs(expected) do
        local existing = ctx.config_units[id]
        if existing then
            existing:_apply(data)
        else
            local unit = ConfigUnit.new(workspace, id, data.project_key)
            unit:_apply(data)
            ctx.config_units[id] = unit
        end
    end

    local arr = {}
    for _, unit in pairs(ctx.config_units) do arr[#arr + 1] = unit end
    return arr
end

--- Sync the profile projects registry.
--- Derives data from synced profiles' mappings.
--- Runs after sync_profiles so Profile objects and their mappings are available.
--- Also builds per-Profile direct lists.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param deps table { compute_build_dir }
--- @return table[] profile_projects array
local function sync_profile_projects(ctx, workspace, deps)
    local expected = {}
    for _, profile in pairs(ctx.profiles) do
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. project_key
                local project = ctx.projects[project_key]
                local configuration = nil
                if project then
                    configuration = project:get_configuration(variant)
                end
                local config_unit = nil
                if project and deps.compute_build_dir then
                    -- Compute expected build_dir for this (project, variant, tool)
                    local tool_data = nil
                    local tools = profile:tools_data()
                    if tools and tools[project.type] then
                        tool_data = tools[project.type].data
                    end
                    local expected_id = deps.compute_build_dir(project, variant, tool_data)
                    if expected_id then
                        config_unit = ctx.config_units[expected_id]
                    end
                end
                expected[reg_key] = {
                    project_key = project_key,
                    profile = profile,
                    project = project,
                    configuration = configuration,
                    config_unit = config_unit,
                }
            end
        end
    end

    for reg_key, pp in pairs(ctx.profile_projects) do
        if not expected[reg_key] then
            pp._removed = true
            ctx.profile_projects[reg_key] = nil
        end
    end

    for reg_key, data in pairs(expected) do
        local existing = ctx.profile_projects[reg_key]
        if existing then
            existing:_apply(data)
        else
            ctx.profile_projects[reg_key] = ProfileProject.new(
                workspace, data.project_key, data)
        end
    end

    local arr = {}
    for _, pp in pairs(ctx.profile_projects) do arr[#arr + 1] = pp end

    local dependency = require("loomworks.dependency")
    for _, profile in pairs(ctx.profiles) do
        local list = {}
        local by_key = {}
        if profile.mappings then
            for project_key in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. project_key
                local pp = ctx.profile_projects[reg_key]
                if pp then
                    list[#list + 1] = pp
                    by_key[project_key] = pp
                end
            end
        end
        profile._projects_list = dependency.toposort(list)
        profile._projects_by_key = by_key
    end

    return arr
end

--- Rebuild the build dir reverse index from ConfigUnit objects.
--- Maps normalized_build_dir -> array of ConfigUnits that reference it.
--- @param config_units table[] array of ConfigUnit objects
--- @param normalize function path normalization function
--- @return table<string, table[]> build_dir_refs
function M.sync_build_dir_refs(config_units, normalize)
    local refs = {}
    for _, unit in pairs(config_units) do
        local bd = unit:build_dir()
        if bd then
            local dir = normalize(bd)
            if not refs[dir] then refs[dir] = {} end
            refs[dir][#refs[dir] + 1] = unit
        end
    end
    return refs
end

-- ===========================================================================
-- Main entry point
-- ===========================================================================

--- Full deserialization refresh: rebuilds all domain objects from config + cache.
--- Returns a result table with all registry arrays, or nil + error.
--- @param workspace table workspace reference for domain object constructors
--- @param config table parsed config (loomworks.json)
--- @param cache table parsed cache data
--- @param active_set table|nil the active set from merge
--- @param all_profile_defs table<string, loomworks.ProfileDef> profile definitions from merge
--- @param current table { modules, projects, config_sets, profiles, config_units, profile_projects }
--- @param deps table { modules_registry, normalize, tools_by_type, default_target_data }
--- @return table result { modules, projects, config_sets, profiles, config_units, profile_projects, build_dir_refs }
function M.refresh(workspace, config, cache, active_set, all_profile_defs, current, deps)
    local ctx = build_ctx(current)

    local modules = sync_modules(ctx, config, cache, deps.modules_registry)

    sync_tools(ctx, modules, deps.tools_by_type, cache, deps.modules_registry)
    -- Rebuild ctx.modules (new modules may have been created by sync_tools)
    ctx.modules = {}
    for _, mod in pairs(modules) do ctx.modules[mod.id] = mod end

    local projects = sync_projects(ctx, workspace, active_set)
    local config_sets = sync_config_sets(ctx, workspace, config)
    local profiles = sync_profiles(ctx, workspace, all_profile_defs, cache, deps.default_target_data)
    local config_units = sync_config_units(ctx, workspace, cache)
    local profile_projects = sync_profile_projects(ctx, workspace, deps)
    local build_dir_refs = M.sync_build_dir_refs(config_units, deps.normalize)

    -- Set _source flags on projects and config_sets (two-layer merge provenance)
    local user_project_keys = deps.user_project_keys or {}
    local user_cs_names = deps.user_cs_names or {}
    for _, p in pairs(projects) do
        p._source = user_project_keys[p.key] and "user" or "shared"
    end
    for _, cs in pairs(config_sets) do
        cs._source = user_cs_names[cs.name] and "user" or "shared"
    end

    -- Resolve active profile from the active set name
    local active_profile = nil
    if active_set and active_set.name then
        for _, p in pairs(profiles) do
            if p.key == active_set.name then
                active_profile = p
                break
            end
        end
    end

    return {
        modules = modules,
        projects = projects,
        config_sets = config_sets,
        profiles = profiles,
        config_units = config_units,
        profile_projects = profile_projects,
        build_dir_refs = build_dir_refs,
        active_profile = active_profile,
    }
end

return M
