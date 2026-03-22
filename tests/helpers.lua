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
        _meta = { version = 4, loomworks_hash = "", cached_at = "" },
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
            cache = { config_cache_key = function(pk, ck) return pk .. "/" .. ck end },
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
        user = overrides.user or { _meta = { version = 1 } },
        cache = overrides.cache or { configurations = {} },

        -- Registries
        _tools_by_type = overrides._tools_by_type or {},
        _config_units = overrides._config_units or {},
        _config_sets = overrides._config_sets or {},
        _profiles = overrides._profiles or {},
        _projects = overrides._projects or {},
        _profile_projects = overrides._profile_projects or {},
        _operations = overrides._operations or {},
        _tool_state = overrides._tool_state or "not_scanned",
        _tool_waiters = overrides._tool_waiters or {},
        _delete_waiters = overrides._delete_waiters or {},
    }

    -- Add get_config_unit method (same logic as Workspace:get_config_unit)
    local ConfigUnit = require("loomworks.config_unit")
    ws.get_config_unit = function(self, project_key, config_key)
        local key = project_key .. "\0" .. config_key
        local unit = self._config_units[key]
        if not unit then
            unit = ConfigUnit.new(self, project_key, config_key)
            self._config_units[key] = unit
        end
        return unit
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
    ws._save_config = core_overrides._save_config or function() return true end
    ws._save_user = core_overrides._save_user or function(self_ws)
        self_ws._core._deps.user.save(self_ws.root, self_ws.user)
    end

    return ws
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

return M
