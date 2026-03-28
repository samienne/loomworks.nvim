-- Shared test helpers for loomworks tests.

local M = {}

--- Build a minimal valid loomworks.json content string.
--- Projects field is replaced entirely (not deep-merged) to avoid
--- combining multiple type keys on a single project.
--- @param overrides? table merged into the base config
--- @return string JSON content
function M.make_config_json(overrides)
    local base = {
        projects = {
            App = { cmake = {} },
        },
    }
    if overrides then
        -- Replace projects entirely if provided (deep merge would combine type keys)
        local projects_override = overrides.projects
        if projects_override then
            overrides = vim.tbl_extend("force", overrides, { projects = nil })
            base.projects = projects_override
        end
        base = vim.tbl_deep_extend("force", base, overrides)
    end
    return vim.json.encode(base)
end

--- Build a valid user.json content string.
--- @param overrides? table merged into the base
--- @return string JSON content
function M.make_user_json(overrides)
    local base = { _meta = { version = 1 } }
    if overrides then
        base = vim.tbl_deep_extend("force", base, overrides)
    end
    return vim.json.encode(base)
end

--- Build a valid cache.json content string.
--- @param overrides? table merged into the base
--- @return string JSON content
function M.make_cache_json(overrides)
    local base = {
        _meta = { version = 6, loomworks_hash = "", cached_at = "" },
        configurations = {},
    }
    if overrides then
        base = vim.tbl_deep_extend("force", base, overrides)
    end
    return vim.json.encode(base)
end

--- Create a mock Workspace for testing domain objects (Profile, Project, etc.).
--- Domain objects now take a workspace instead of core. The workspace has
--- registries directly on it and a _core sub-table for infrastructure.
--- Business logic methods live on the workspace; _core only holds deps.
--- @param overrides? table
--- @return table mock_workspace
function M.make_mock_workspace(overrides)
    overrides = overrides or {}

    -- Build _core with defaults, allowing overrides
    local core_overrides = overrides._core or {}
    local core = {
        _deps = vim.tbl_deep_extend("force", {
            clock = function() return 0 end,
            events = { emit = function() end },
            merge = { resolve_detected_tool = function() return nil end },
            user = { save = function() return true end },
            cache = {
                config_cache_key = function(pk, ck) return pk .. "/" .. ck end,
                next_available_key = require("loomworks.cache").next_available_key,
            },
            modules = { get = function() return nil end },
            get_overseer_task = function() return nil end,
            normalize = function(p) return p end,
            notify = function() end,
            io = { rm_rf_async = function(_, cb) cb(true, nil) end },
            schedule = function(fn) fn() end,
            now = function() return "2000-01-01T00:00:00Z" end,
        }, core_overrides._deps or {}),
    }
    -- Copy any extra core fields from overrides
    for k, v in pairs(core_overrides) do
        if k ~= "_deps" then
            core[k] = v
        end
    end

    local ws = {
        _core = core,

        -- Workspace data fields
        root = overrides.root or "/test",
        name = overrides.name or "test",
        config = overrides.config or { projects = {} },
        cache = nil,  -- cache is nil after remerge; tests use first-class fields or _serialize_cache()

        -- User state (from user data table or direct override)
        _active_profile_key = overrides._active_profile_key
            or (overrides.user and overrides.user.active_profile or nil),
        _default_target_data = overrides._default_target_data
            or (overrides.user and overrides.user.default_target or nil),

        -- Registries
        _tools_by_type = overrides._tools_by_type or {},
        _tool_objects = overrides._tool_objects or {}, -- legacy, for tests that set up tools directly
        _config_units = overrides._config_units or {},
        _config_sets = overrides._config_sets or {},
        _profiles = overrides._profiles or {},
        _projects = overrides._projects or {},
        _profile_projects = overrides._profile_projects or {},
        _operations = overrides._operations or {},
        _tool_state = overrides._tool_state or "not_scanned",
        _tool_waiters = overrides._tool_waiters or {},
        _delete_waiters = overrides._delete_waiters or {},
        _build_dir_refs = overrides._build_dir_refs or {},
        _build_dir_locks = overrides._build_dir_locks or {},
        _modules = overrides._modules or {},
    }

    -- Add config unit methods (same logic as Workspace)
    local ConfigUnit = require("loomworks.config_unit")
    local cache_mod_h = require("loomworks.cache")
    local merge_h = require("loomworks.merge")
    ws.find_config_unit = function(self, project, configuration, tool)
        for _, unit in pairs(self._config_units) do
            if unit._project == project
                    and unit._configuration == configuration
                    and unit._tool == tool then
                return unit
            end
        end
        return nil
    end
    ws.ensure_config_unit = function(self, project, configuration, tool)
        local existing = self:find_config_unit(project, configuration, tool)
        if existing then return existing end
        local variant = configuration.name
        local tool_key = tool and tool.key or nil
        local config_key = merge_h.build_config_key(variant, tool_key)
        local id = cache_mod_h.config_cache_key(project.key, config_key)
        -- Check if a unit with this id already exists (pre-created from cache data)
        local unit = nil
        for _, u in pairs(self._config_units) do
            if u.id == id then unit = u; break end
        end
        if not unit then
            unit = ConfigUnit.new(self, id, project.key)
            self._config_units[#self._config_units + 1] = unit
        end
        -- Build cache-shaped table for _apply to read from
        local cached_entry = {
            project_key = unit._init_project_key or project.key,
            config_key = unit._config_key or config_key,
            type = project.type,
            variant = unit._variant or variant,
            state = unit.state_value,
            build_dir = unit.build_dir_value,
            last_configured = unit.last_configured,
            last_built = unit.last_built,
        }
        if tool_key then
            cached_entry.tool_key = unit._tool_key or tool_key
            cached_entry.tool_data = unit._tool_data or (tool and tool.data or nil)
        end
        if unit.cmake_info then
            cached_entry.cmake = unit.cmake_info
        end
        unit:_apply({
            cached = cached_entry,
            project = project,
            tool = tool,
            configuration = configuration,
        })
        return unit
    end

    -- Add Module registry methods
    local ModuleClass = require("loomworks.module")
    ws.find_module = function(self, mod_type)
        for _, mod in pairs(self._modules) do
            if mod.id == mod_type then return mod end
        end
    end
    ws.get_or_create_module = function(self, mod_type)
        local existing = self:find_module(mod_type)
        if existing then return existing end
        -- Create a minimal mock impl
        local impl = { id = mod_type, has_keyed_tools = (mod_type == "cmake") }
        local mod = ModuleClass.new(mod_type, impl)
        self._modules[#self._modules + 1] = mod
        return mod
    end

    -- Add find helpers (same as Workspace class)
    -- Add Tool registry methods (delegate through Module objects)
    ws.find_tool = function(self, mod_type, tool_key)
        local mod = self:find_module(mod_type)
        return mod and mod:find_tool(tool_key) or nil
    end
    ws.get_or_create_tool = function(self, mod_type, tool_key, tool_data, tool_label)
        local mod = self:get_or_create_module(mod_type)
        return mod:get_or_create_tool(tool_key, tool_data, tool_label)
    end

    -- Business logic methods now live on workspace.
    -- Allow overrides via core_overrides for backward compatibility,
    -- with sensible defaults.
    ws.remerge = core_overrides.remerge or function() end
    ws._save_cache = core_overrides._save_cache or function() return true end
    ws.create_operation = core_overrides.create_operation or function() end
    ws.execute_deletion = core_overrides.execute_deletion or function() end
    ws.cancel_conflicting_operations = core_overrides.cancel_conflicting_operations or function() end
    ws.find_running_tasks_for_items = core_overrides.find_running_tasks_for_items or function() return {} end
    ws.stop_tasks_then = core_overrides.stop_tasks_then or function(_, _, fn) fn() end
    ws.mark_cached_configs_cleaned = core_overrides.mark_cached_configs_cleaned or function() end
    ws._materialize_from_data = core_overrides._materialize_from_data or function() end
    ws.has_pending_deletions = core_overrides.has_pending_deletions or function() return false end
    ws.record_task_result = core_overrides.record_task_result or function() end
    ws.delete_cached_configs = core_overrides.delete_cached_configs or function() end
    ws.reset_cached_configs = core_overrides.reset_cached_configs or function() end
    ws._mark_cache_unknown = core_overrides._mark_cache_unknown or function() end
    ws._validate_build_dir = core_overrides._validate_build_dir or function() return true end
    ws._delete_build_dirs_async = core_overrides._delete_build_dirs_async or function(_, _, cb) cb({}) end
    ws._run_deletion = core_overrides._run_deletion or function(_, _, _, on_done) if on_done then on_done() end end
    ws._sync_build_dir_refs = core_overrides._sync_build_dir_refs or function() end
    ws.get_build_dir_refs = core_overrides.get_build_dir_refs or function() return {} end
    ws.acquire_build_dir_lock = core_overrides.acquire_build_dir_lock or function(_, _, _, fn) fn(); return true end
    ws.release_build_dir_lock = core_overrides.release_build_dir_lock or function() end
    ws.has_queued_operations = core_overrides.has_queued_operations or function() return false end
    ws.is_build_dir_locked = core_overrides.is_build_dir_locked or function() return false, nil end
    ws._save_config = core_overrides._save_config or function() return true end
    ws._serialize_user = core_overrides._serialize_user or function(self_ws)
        local data = { _meta = { version = 1 } }
        if self_ws._active_profile_key then
            data.active_profile = self_ws._active_profile_key
        end
        local targets = {}
        for _, profile in pairs(self_ws._profiles) do
            if profile._default_target_descriptor then
                targets[profile.key] = profile._default_target_descriptor
            end
        end
        if next(targets) then data.default_target = targets end
        return data
    end
    ws._save_user = core_overrides._save_user or function(self_ws)
        self_ws._core._deps.user.save(self_ws.root, self_ws:_serialize_user())
    end

    -- If cache overrides were provided, pre-create ConfigUnits from configurations.
    -- This replaces the old pattern of storing cache data on ws.cache.
    local cache_data = overrides.cache
    if cache_data and cache_data.configurations then
        for id, entry in pairs(cache_data.configurations) do
            -- Skip if a unit already exists for this id
            local exists = false
            for _, u in pairs(ws._config_units) do
                if u.id == id then exists = true; break end
            end
            if not exists then
                local unit = ConfigUnit.new(ws, id, entry.project_key)
                unit:_apply({ cached = entry })
                ws._config_units[#ws._config_units + 1] = unit
            end
        end
    end

    return ws
end

--- Register a ProfileProject in the workspace registry AND update the
--- Profile's direct lists (_projects_list, _projects_by_key).
--- Use this instead of manually inserting into _profile_projects in tests.
--- Pre-resolves project, configuration, cached, and config_unit references.
--- @param ws table mock workspace
--- @param profile table Profile object
--- @param project_key string
--- @param variant string
--- @return table ProfileProject
function M.register_profile_project(ws, profile, project_key, variant)
    local ProfileProject = require("loomworks.profile").ProfileProject
    -- Pre-resolve references
    local project = M.find_project_in(ws._projects, project_key)
    local configuration = nil
    if project then
        configuration = project:get_configuration(variant)
    end
    local config_unit = nil
    -- Find config unit via first-class fields (cache is nil after remerge)
    for _, unit in pairs(ws._config_units) do
        if unit._init_project_key == project_key
                and unit._variant == variant then
            -- Resolve references if not yet resolved (e.g. pre-created from cache)
            if not unit._project then
                M.refresh_config_unit(ws, unit)
            end
            config_unit = unit
            break
        end
    end
    local pp = ProfileProject.new(ws, project_key, {
        profile = profile,
        project = project,
        configuration = configuration,
        config_unit = config_unit,
    })
    local reg_key = profile.key .. "\0" .. project_key
    ws._profile_projects[#ws._profile_projects + 1] = pp
    -- Update Profile's unsorted list and by_key dict
    profile._projects_list = profile._projects_list or {}
    profile._projects_list[#profile._projects_list + 1] = pp
    profile._projects_by_key = profile._projects_by_key or {}
    profile._projects_by_key[project_key] = pp
    return pp
end

--- Finalize a Profile's project list after all PPs are registered.
--- Sorts _projects_list by dependency order (same as _sync_profile_projects).
--- Call this after all register_profile_project calls for a profile.
--- @param profile table Profile object
function M.finalize_profile(profile)
    local dependency = require("loomworks.dependency")
    profile._projects_list = dependency.toposort(profile._projects_list or {})
end

--- Get or create a Configuration domain object on a project.
--- For tests that need a Configuration object to pass to ensure_config_unit.
--- @param project loomworks.Project
--- @param name string configuration name
--- @return loomworks.Configuration
function M.get_or_create_config(project, name)
    local cfg = project:get_configuration(name)
    if cfg then return cfg end
    local Configuration = require("loomworks.configuration")
    cfg = Configuration.new(project, name, {})
    project._configurations[#project._configurations + 1] = cfg
    return cfg
end

--- Refresh a ConfigUnit's resolved references from the workspace.
--- Mirrors what _sync_config_units does for a single unit.
--- @param ws table mock workspace
--- @param unit table ConfigUnit
function M.refresh_config_unit(ws, unit)
    local project_key = unit._init_project_key
    local project = project_key and M.find_project_in(ws._projects, project_key) or nil
    local tool = nil
    if unit._tool_key then
        local mod = project and project._module
            or ws:find_module("cmake")
        if mod then
            tool = mod:find_tool(unit._tool_key)
        end
    end
    local configuration = nil
    if unit._variant and project then
        configuration = project:get_configuration(unit._variant)
    end
    -- Build cache-shaped table from first-class fields for _apply
    local cached_entry = {
        project_key = project_key,
        config_key = unit._config_key,
        variant = unit._variant,
        state = unit.state_value,
        build_dir = unit.build_dir_value,
        last_configured = unit.last_configured,
        last_built = unit.last_built,
        tool_key = unit._tool_key,
        tool_data = unit._tool_data,
    }
    if unit.cmake_info then cached_entry.cmake = unit.cmake_info end
    unit:_apply({
        cached = cached_entry,
        project = project,
        tool = tool,
        configuration = configuration,
    })
end

--- Get or create a ConfigUnit for a cache entry, with resolved references.
--- Simulates what _sync_config_units does at the deserialization boundary.
--- @param ws table mock workspace
--- @param id string cache dict key (used for ConfigUnit identity + cache lookup)
--- @param project_key string
--- @return table ConfigUnit
function M.ensure_config_unit_by_id(ws, id, project_key)
    local ConfigUnit = require("loomworks.config_unit")
    -- Check if a unit already exists with this id
    for _, unit in pairs(ws._config_units) do
        if unit.id == id then
            M.refresh_config_unit(ws, unit)
            return unit
        end
    end
    local unit = ConfigUnit.new(ws, id, project_key)
    ws._config_units[#ws._config_units + 1] = unit
    M.refresh_config_unit(ws, unit)
    return unit
end

--- Backward-compatible alias for make_mock_workspace.
--- Tests that used make_mock_core with core_overrides need updating to
--- use the new workspace-centric pattern. This alias helps with the transition.
--- @param overrides? table
--- @return table mock_workspace
function M.make_mock_core(overrides)
    -- Translate old core-style overrides to workspace-style
    if not overrides then
        return M.make_mock_workspace()
    end

    local ws_overrides = {}
    local core_overrides = {}

    for k, v in pairs(overrides) do
        if k == "_deps" then
            core_overrides._deps = v
        elseif k == "remerge" or k == "_save_cache" or k == "create_operation"
            or k == "execute_deletion" or k == "cancel_conflicting_operations"
            or k == "find_running_tasks_for_items" or k == "stop_tasks_then"
            or k == "mark_cached_configs_cleaned" or k == "_materialize_from_data" then
            core_overrides[k] = v
        elseif k == "get_workspace" then
            -- Flatten get_workspace() return value onto the workspace
            local ws_data = v()
            if ws_data then
                for wk, wv in pairs(ws_data) do
                    ws_overrides[wk] = wv
                end
            end
        elseif k == "get_profiles" then
            -- get_profiles was a function returning profiles dict;
            -- now profiles are on ws directly
            -- Only used as function in some tests; store the result
            local result = v()
            if result then ws_overrides._profiles = result end
        else
            -- Pass through to workspace
            ws_overrides[k] = v
        end
    end

    if next(core_overrides) then
        ws_overrides._core = core_overrides
    end

    return M.make_mock_workspace(ws_overrides)
end

--- Build mocked deps for Core.new() that use in-memory file content.
--- @param files? table<string, string> path -> content mapping
--- @param opts? table extra dep overrides
--- @return table deps
function M.make_test_deps(files, opts)
    files = files or {}
    local events_log = {}

    local real_user = require("loomworks.user")
    local real_cache = require("loomworks.cache")
    local real_workspace = require("loomworks.workspace")

    local function file_lookup(path)
        local normalized = path:gsub("\\", "/")
        for k, v in pairs(files) do
            if normalized:match(k:gsub("%-", "%%-"):gsub("%.", "%%.") .. "$") then
                return v
            end
        end
        return nil
    end

    local deps = {
        io = {
            read_file = file_lookup,
            write_json = function() return true end,
            rm_rf = function() return true end,
            rm_rf_async = function(_, cb) cb(true, nil) end,
            ensure_dir = function() return true end,
        },
        read_file_async = function(path, callback) callback(file_lookup(path), nil) end,
        read_files_async = function(paths_list, callback)
            local results = {}
            for _, path in ipairs(paths_list) do results[path] = file_lookup(path) end
            callback(results)
        end,
        workspace = {
            resolve_root = function(path)
                -- Test-friendly: return as-is, no vim path normalization
                return (path or "/test"):gsub("/$", "")
            end,
            paths = real_workspace.paths,
            assemble = real_workspace.assemble,
        },
        user = {
            parse = real_user.parse,
            default = real_user.default,
            filepath = real_user.filepath,
            save = function() return true end,
        },
        cache = {
            parse = real_cache.parse,
            default = real_cache.default,
            filepath = real_cache.filepath,
            compute_hash = real_cache.compute_hash,
            config_cache_key = real_cache.config_cache_key,
            next_available_key = real_cache.next_available_key,
            save = function() return true end,
        },
        detect_tools_async = function(config, cache, callback) callback({}) end,
        modules = {
            get = function() return nil end,
        },
        FileTracker = {
            new = function(tracker_opts)
                return {
                    watch = function() end,
                    unwatch = function() end,
                    stop = function() end,
                    content = function(_, path) return file_lookup(path) end,
                    mark_written = function() end,
                }
            end,
        },
        notify = function() end,
        schedule = function(fn) fn() end,
        clock = function() return 0 end,
        normalize = function(p) return p:gsub("\\", "/") end,
        events = {
            emit = function(event, data)
                events_log[#events_log + 1] = { event = event, data = data }
            end,
            on = function() end,
            off = function() end,
        },
        _events_log = events_log,
    }

    if opts then
        for k, v in pairs(opts) do
            if k == "_events_log" then
                -- skip
            elseif type(v) == "table" and type(deps[k]) == "table" then
                -- Merge table overrides so partial overrides work (e.g. only override cache.save)
                for vk, vv in pairs(v) do
                    deps[k][vk] = vv
                end
            else
                deps[k] = v
            end
        end
    end

    return deps
end

--- Find a Profile by key in a profiles array (test convenience).
--- @param profiles loomworks.Profile[]
--- @param key string
--- @return loomworks.Profile|nil
function M.find_profile(profiles, key)
    for _, p in pairs(profiles) do
        if p.key == key then return p end
    end
end

--- Find a Project by key in a projects array (test convenience).
--- @param projects loomworks.Project[]
--- @param key string
--- @return loomworks.Project|nil
function M.find_project_in(projects, key)
    for _, p in pairs(projects) do
        if p.key == key then return p end
    end
end

--- Find a ConfigUnit by id (cache dict key) in a config_units array.
--- @param config_units loomworks.ConfigUnit[]
--- @param id string
--- @return loomworks.ConfigUnit|nil
function M.find_config_unit_by_id(config_units, id)
    for _, unit in pairs(config_units) do
        if unit.id == id then return unit end
    end
end

--- Find a ConfigurationSet by name in an array (test convenience).
--- @param config_sets loomworks.ConfigurationSet[]
--- @param name string
--- @return loomworks.ConfigurationSet|nil
function M.find_config_set_in(config_sets, name)
    for _, cs in pairs(config_sets) do
        if cs.name == name then return cs end
    end
end

--- Get a config set's variant for a project key (test convenience).
--- @param cs loomworks.ConfigurationSet
--- @param project_key string
--- @return string|nil variant
function M.cs_mapping(cs, project_key)
    if not cs or not cs.mappings then return nil end
    for proj, config in pairs(cs.mappings) do
        if proj.key == project_key then return config.name end
    end
end

return M
