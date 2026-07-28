--- loomworks/data_model.lua — Deserialization module.
--- Pure-data _sync_* logic. Entry point: M.refresh(). Also exposes
--- sync_build_dir_refs() for use by mutation methods.

local M = {}

local BuildDir = require("loomworks.build_dir")
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
--- @param current table { modules, projects, config_sets, profiles, config_units, profile_projects, build_dirs }
--- @return table ctx
local function build_ctx(current)
    local ctx = {
        modules = {},
        projects = {},
        config_sets = {},
        profiles = {},
        config_units = {},
        profile_projects = {},
        build_dirs = {},  -- rel_path → BuildDir
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
    for _, bd in pairs(current.build_dirs or {}) do ctx.build_dirs[bd.rel_path] = bd end
    return ctx
end

-- ===========================================================================
-- Sync functions
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
--- Once-per-session dedup for stale config_set mapping warnings.
--- Keyed by `<set_name>|<project_key>|<variant>` so a remerge or
--- file refresh doesn't repeat the notification. Cleared on
--- workspace re-init by re-requiring the module — fresh load
--- gets a fresh report.
--- @type table<string, boolean>
local _reported_stale_mappings = {}

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
                    -- Stale mapping: the configuration_set names a variant
                    -- the project no longer has. Create a `_source_missing`
                    -- stub so references don't break, and warn once — left
                    -- silent it produces malformed build dirs / phantom
                    -- configurations on the status page.
                    local key = name .. "|" .. project_key .. "|" .. tostring(variant)
                    if not _reported_stale_mappings[key] then
                        _reported_stale_mappings[key] = true
                        vim.notify(
                            "loomworks: configuration_set '" .. name
                                .. "' references unknown configuration '"
                                .. tostring(variant) .. "' for project '"
                                .. project_key
                                .. "' — fix the mapping in loomworks.json or user.json",
                            vim.log.levels.WARN)
                    end
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
--- @param device_data table|nil raw device map from user.json (profile_key -> serial)
--- @return table[] profiles array
local function sync_profiles(ctx, workspace, all_defs, cache, default_target_data, device_data)
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
            if vim.islist and vim.islist(data.tools) then
                -- New flat array shape: ["key1", "key2"]. Each key
                -- resolves once per module that has it in its
                -- registry — multiple modules can share a key (e.g.
                -- a kit-from-SDK that's materialized in multiple
                -- modules' tool registries).
                for _, tool_key in ipairs(data.tools) do
                    for _, mod in pairs(ctx.modules) do
                        if not tool_objs[mod] then
                            local tool = mod:find_tool(tool_key)
                            if tool then tool_objs[mod] = tool end
                        end
                    end
                end
            else
                -- Legacy dict shape: { module_id → { key, data, label } }
                for mod_type, tool_ref in pairs(data.tools) do
                    local mod = ctx.modules[mod_type]
                    if mod and type(tool_ref) == "table" then
                        local tool = mod:find_tool(tool_ref.key)
                        if tool then tool_objs[mod] = tool end
                    end
                end
            end
            if next(tool_objs) then data._tool_objects = tool_objs end
        end
        data._config_set_ref = nil
        if data.configuration_set then
            data._config_set_ref = ctx.config_sets[data.configuration_set]
        end

        data._sdk = nil
        if data.sdk then
            data._sdk = workspace:find_sdk(data.sdk)
            if data._sdk then
                workspace._core._deps.log:debug("Profile '%s': SDK '%s' resolved", key, data.sdk)
            else
                workspace._core._deps.log:warn("Profile '%s': SDK key '%s' not found in workspace (have %d SDKs)", key, data.sdk, #workspace._sdks)
            end
        else
            workspace._core._deps.log:debug("Profile '%s': no SDK field in data", key)
        end

        local existing = ctx.profiles[key]
        if existing then
            existing:_apply(data)
        else
            local profile = Profile.new(workspace, data)
            ctx.profiles[profile.key] = profile
        end
    end

    -- Populate _default_target_descriptor and _device_serial from user.json data
    for key, profile in pairs(ctx.profiles) do
        profile._default_target_descriptor = default_target_data
            and default_target_data[key] or nil
        profile._device_serial = device_data
            and device_data[key] or nil
    end

    local arr = {}
    for _, p in pairs(ctx.profiles) do arr[#arr + 1] = p end
    return arr
end

--- Sync BuildDir domain objects from cache entries.
--- Every cache.build_dirs entry with state becomes a BuildDir object.
--- Existing BuildDirs are preserved (identity stable); new ones created as needed.
--- BuildDirs whose cache entry disappears are marked _removed.
--- @param ctx table deserialization context
--- @param workspace table workspace reference
--- @param cache table parsed cache data
--- @return table[] build_dirs array of all BuildDir objects
local function sync_build_dirs(ctx, workspace, cache)
    local cache_mod = require("loomworks.cache")
    local seen = {}

    if cache and cache.build_dirs then
        for rel_path, entry in pairs(cache.build_dirs) do
            if entry.state and entry.state ~= "unconfigured" then
                local existing = ctx.build_dirs[rel_path]
                if existing then
                    existing.state = entry.state
                    existing.last_configured = entry.last_configured
                    existing.last_built = entry.last_built
                    existing.module_info = entry.module_info
                    existing.options_snapshot = entry.options
                    existing.module_config_snapshot = entry.module_config
                    if entry.tool_key then
                        existing.tool_snapshot = { key = entry.tool_key, data = entry.tool_data }
                    end
                    existing.project_key = entry.project_key
                    existing.variant = entry.variant
                    existing.config_key = entry.config_key
                    existing.mod_type = entry.type
                    existing._removed = false
                else
                    local abs_path = entry.build_dir
                        or cache_mod.absolute_build_dir(rel_path, workspace.root)
                    local bd = BuildDir.new(rel_path, abs_path, entry)
                    ctx.build_dirs[rel_path] = bd
                end
                seen[rel_path] = true
            end
        end
    end

    for rel_path, bd in pairs(ctx.build_dirs) do
        if not seen[rel_path] then
            bd._removed = true
        end
    end

    local arr = {}
    for _, bd in pairs(ctx.build_dirs) do
        if not bd._removed then
            arr[#arr + 1] = bd
        end
    end
    return arr
end

--- Sync profile projects and config units together.
--- ConfigUnits are created from profile resolution (what profiles need),
--- NOT from cache entries. Cache entries are linked afterward by build_dir match.
--- @param ctx table deserialization context with O(1) lookups
--- @param workspace table workspace reference for domain object constructors
--- @param cache table parsed cache data
--- @param deps table { compute_build_dir }
--- @return table[] config_units array
--- @return table[] profile_projects array
local function sync_profile_projects_and_config_units(ctx, workspace, cache, deps)
    local cache_mod = require("loomworks.cache")
    local expected_units = {}  -- build_dir_id → apply_data
    local expected_pps = {}    -- reg_key → pp_data

    -- Build config_units from profile resolution
    for _, profile in pairs(ctx.profiles) do
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                local project = ctx.projects[project_key]
                local configuration = nil
                if project then
                    configuration = project:get_configuration(variant)
                end

                -- Resolve the effective tool set this project needs.
                -- Language-aware: walks `profile._tool_keys` and for each
                -- language declared by the configuration picks the first
                -- tool that provides it. Falls back to the old single-tool
                -- `tool_for(project.type)` path when the configuration
                -- isn't resolved yet (so we can still compute a build_dir
                -- for orphaned / partially-resolved units).
                local tool_data = nil
                local tool_key = nil
                local effective_tools = nil
                if project then
                    if configuration and profile.tools_for then
                        local tools = profile:tools_for(configuration)
                        if tools and #tools > 0 then
                            effective_tools = {}
                            for _, t in ipairs(tools) do
                                effective_tools[#effective_tools + 1] = {
                                    key = t.key,
                                    data = t.data,
                                }
                            end
                            tool_data = tools[1].data
                            tool_key = tools[1].key
                        end
                    end
                    if not tool_data then
                        local tool_ref = profile:tool_for(project.type)
                        if tool_ref then
                            tool_data = tool_ref.data
                            tool_key = tool_ref.key
                        end
                    end
                end

                local build_dir_id = nil
                local abs_path = nil
                if project and deps.compute_build_dir then
                    -- Pass the effective tools list when we have one
                    -- (multi-tool path); otherwise fall back to the
                    -- legacy single-tool_data call.
                    local arg = effective_tools and #effective_tools > 0
                        and effective_tools or tool_data
                    build_dir_id, abs_path = deps.compute_build_dir(project, variant, arg)
                end

                -- Resolve tool domain object (used for both the
                -- ConfigUnit accumulator below and the per-PP compat
                -- check). Even when expected_units[build_dir_id] is
                -- already populated by a different profile, we still
                -- need the tool object for *this* profile's PP.
                local tool = nil
                if tool_key then
                    local mod = project and project._module or nil
                    if mod then tool = mod:find_tool(tool_key) end
                end

                -- Per-(profile, config) compatibility check. Stored
                -- on the ProfileProject, not the ConfigUnit — the
                -- same unit can be valid in one profile and invalid
                -- in another (each profile picks its own tool).
                -- Module-agnostic via `validate_config_tool` hook.
                local tool_compat_error = M.compute_tool_compat_error(
                    project, configuration, tool)

                -- Accumulate ConfigUnit data (dedup by build_dir_id).
                -- This block is iteration-order-sensitive by design:
                -- the unit's stored `_tool_data` reflects whichever
                -- profile happened to resolve first. The compat
                -- error, in contrast, lives on PP and is correctly
                -- scoped to (profile, config) below.
                local config_unit_ref = nil
                if build_dir_id then
                    if not expected_units[build_dir_id] then
                        local cache_entry = cache and cache.build_dirs
                            and cache.build_dirs[build_dir_id] or nil
                        local enriched = nil
                        if cache_entry then
                            enriched = vim.tbl_extend("keep", cache_entry, {
                                build_dir = abs_path or cache_mod.absolute_build_dir(build_dir_id, workspace.root),
                            })
                        end

                        local build_dir_obj = ctx.build_dirs[build_dir_id]

                        expected_units[build_dir_id] = {
                            project_key = project_key,
                            cached = enriched,
                            project = project,
                            tool = tool,
                            configuration = configuration,
                            build_dir = build_dir_obj,
                            build_dir_value = abs_path or cache_mod.absolute_build_dir(build_dir_id, workspace.root),
                        }
                    end
                    config_unit_ref = build_dir_id
                end

                local reg_key = profile.key .. "\0" .. project_key
                expected_pps[reg_key] = {
                    project_key = project_key,
                    profile = profile,
                    project = project,
                    configuration = configuration,
                    config_unit_ref = config_unit_ref,  -- resolved after unit creation
                    tool_compat_error = tool_compat_error,
                }
            end
        end
    end

    -- Create/update/remove ConfigUnit objects
    for id, unit in pairs(ctx.config_units) do
        if not expected_units[id] and not unit:is_running() and not unit:is_deleting() then
            unit._removed = true
            ctx.config_units[id] = nil
        end
    end

    for id, data in pairs(expected_units) do
        local existing = ctx.config_units[id]
        if existing then
            existing:_apply(data)
            existing._removed = false
        else
            local unit = ConfigUnit.new(workspace, id, data.project_key)
            unit:_apply(data)
            ctx.config_units[id] = unit
        end
    end

    local config_units_arr = {}
    for _, unit in pairs(ctx.config_units) do config_units_arr[#config_units_arr + 1] = unit end

    -- Create/update/remove ProfileProject objects
    for reg_key, pp in pairs(ctx.profile_projects) do
        if not expected_pps[reg_key] then
            pp._removed = true
            ctx.profile_projects[reg_key] = nil
        end
    end

    for reg_key, data in pairs(expected_pps) do
        data.config_unit = data.config_unit_ref and ctx.config_units[data.config_unit_ref] or nil
        data.config_unit_ref = nil

        local existing = ctx.profile_projects[reg_key]
        if existing then
            existing:_apply(data)
        else
            ctx.profile_projects[reg_key] = ProfileProject.new(
                workspace, data.project_key, data)
        end
    end

    local profile_projects_arr = {}
    for _, pp in pairs(ctx.profile_projects) do profile_projects_arr[#profile_projects_arr + 1] = pp end

    -- Build per-Profile direct lists
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

    return config_units_arr, profile_projects_arr
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

--- Compute the per-(profile, configuration) tool compatibility error
--- by invoking the module's `validate_config_tool` hook. Modules that
--- don't implement the hook are permissive (returns nil). Used by
--- both the full `data_model.refresh` path and the targeted
--- `Workspace:_rebuild_profile_projects_for` path so a mapping change
--- updates the compat state without a full file-driven remerge.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool loomworks.Tool|nil
--- @return string|nil reason
function M.compute_tool_compat_error(project, configuration, tool)
    if not project or not configuration or not tool then return nil end
    local impl = project._module and project._module.impl or nil
    if not impl or not impl.validate_config_tool then return nil end
    local ok, err = impl.validate_config_tool(configuration, tool)
    if ok == false then
        return err or "tool incompatible with configuration"
    end
    return nil
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
--- @param deps table { modules_registry, normalize, tools_by_type, default_target_data, device_data }
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
    local profiles = sync_profiles(ctx, workspace, all_profile_defs, cache, deps.default_target_data, deps.device_data)
    local build_dirs = sync_build_dirs(ctx, workspace, cache)
    local config_units, profile_projects = sync_profile_projects_and_config_units(
        ctx, workspace, cache, deps)
    local build_dir_refs = M.sync_build_dir_refs(config_units, deps.normalize)

    -- Set _source and _intent on projects, config_sets, and profiles
    local user_project_keys = deps.user_project_keys or {}
    local user_cs_names = deps.user_cs_names or {}
    local user_provenance = deps.user_provenance or {}
    local shared_baseline = deps.shared_baseline
    local intent_overrides = deps.intent_overrides or {}
    local intent_projects = intent_overrides.projects or {}
    local intent_configs = intent_overrides.configurations or {}
    local intent_sets = intent_overrides.configuration_sets or {}
    local intent_profiles = intent_overrides.profiles or {}

    --- Compute default intent from file presence.
    --- Used only when an item has no prior intent — for newly-created objects
    --- on first refresh. After that intent is sticky: explicit overrides win,
    --- then prior intent, then default-from-presence as a last resort.
    local function default_intent(in_user, in_baseline)
        if in_user and in_baseline then return "local+shared" end
        if in_user then return "local" end
        if in_baseline then return "shared" end
        return "local"
    end

    for _, p in pairs(projects) do
        p._source = user_project_keys[p.key] and "user" or "shared"
        local in_baseline = shared_baseline
            and shared_baseline.projects
            and shared_baseline.projects[p.key] ~= nil
        local in_user = user_project_keys[p.key] or false
        p._intent = intent_projects[p.key]
            or p._intent
            or default_intent(in_user, in_baseline)

        -- Per-configuration _intent
        local prov = user_provenance[p.key] or {}
        local baseline_configs = shared_baseline
            and shared_baseline.projects
            and shared_baseline.projects[p.key]
            and shared_baseline.projects[p.key].type_config
            and shared_baseline.projects[p.key].type_config.configurations
        for _, cfg in ipairs(p._configurations or {}) do
            local cfg_in_user = prov.user_configs and prov.user_configs[cfg.name] or false
            local cfg_in_baseline = baseline_configs and baseline_configs[cfg.name] ~= nil or false
            local cfg_key = p.key .. "/" .. cfg.name
            cfg._intent = intent_configs[cfg_key]
                or cfg._intent
                or default_intent(cfg_in_user, cfg_in_baseline)
        end
    end
    for _, cs in pairs(config_sets) do
        cs._source = user_cs_names[cs.name] and "user" or "shared"
        local in_baseline = shared_baseline
            and shared_baseline.configuration_sets
            and shared_baseline.configuration_sets[cs.name] ~= nil
        local in_user = user_cs_names[cs.name] or false
        cs._intent = intent_sets[cs.name]
            or cs._intent
            or default_intent(in_user, in_baseline)
    end
    local user_profile_keys = deps.user_profile_keys or {}
    for _, prof in pairs(profiles) do
        local in_baseline = shared_baseline
            and shared_baseline.profiles
            and shared_baseline.profiles[prof.key] ~= nil
        local in_user = user_profile_keys[prof.key] or false
        prof._intent = intent_profiles[prof.key]
            or prof._intent
            or default_intent(in_user, in_baseline)
    end

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
        build_dirs = build_dirs,
        profiles = profiles,
        config_units = config_units,
        profile_projects = profile_projects,
        build_dir_refs = build_dir_refs,
        active_profile = active_profile,
    }
end

return M
