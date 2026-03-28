--- loomworks/core.lua — Infrastructure layer.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.
--- Registries and business logic live on the Workspace instance;
--- Core owns I/O, modules, events, file tracking, and setup.
--- Thin delegation wrappers forward to Workspace so that init.lua callers
--- continue to work via core:method().

--- @class loomworks.Core
--- @field _deps table injected dependencies
--- @field _workspace loomworks.Workspace|nil
--- @field _setup_error { root: string, message: string }|nil set when setup fails
--- @field _state "uninitialized"|"initializing"|"initialized"
local Core = {}
Core.__index = Core

local Workspace = require("loomworks.workspace").Workspace

--- Default dependency table. Tests override individual entries.
local DEFAULT_DEPS = {
    workspace = require("loomworks.workspace"),
    merge     = require("loomworks.merge"),
    events    = require("loomworks.events"),
    user      = require("loomworks.user"),
    cache     = require("loomworks.cache"),
    config    = require("loomworks.config"),
    io        = require("loomworks.io"),
    read_file_async = require("loomworks.io").read_file_async,
    read_files_async = require("loomworks.io").read_files_async,
    detect_tools_async = require("loomworks.merge").detect_tools_async,
    modules   = require("loomworks.modules"),
    FileTracker = require("loomworks.file_tracker"),
    notify    = vim.notify,
    now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    clock     = function() return vim.uv.hrtime() / 1e9 end,
    --- Normalize a file path for comparison. On Windows, also lowercases
    --- because the filesystem is case-insensitive.
    normalize = (function()
        local is_win = vim.fn.has("win32") == 1
        if is_win then
            return function(p)
                return vim.fs.normalize(p):lower()
            end
        end
        return vim.fs.normalize
    end)(),
    schedule  = vim.schedule,
    --- Resolve an overseer task by id. Returns nil if overseer not available.
    --- @param task_id number
    --- @return table|nil task
    get_overseer_task = function(task_id)
        local ok, task_list = pcall(require, "overseer.task_list")
        if not ok then return nil end
        return task_list.get(task_id)
    end,
    --- Get the file path for a buffer.
    --- @param bufnr number
    --- @return string
    buf_name = function(bufnr)
        return vim.api.nvim_buf_get_name(bufnr)
    end,
}

--- Create a new Core instance.
--- @param deps? table override individual dependencies for testing
--- @return loomworks.Core
function Core.new(deps)
    local self = setmetatable({}, Core)
    if deps then
        self._deps = setmetatable(deps, { __index = DEFAULT_DEPS })
    else
        self._deps = DEFAULT_DEPS
    end
    self._workspace = nil
    self._setup_error = nil
    self._state = "uninitialized"
    return self
end

-- ===========================================================================
-- Setup & lifecycle (stays on Core)
-- ===========================================================================

--- Force-reload loomworks.json from disk and remerge.
--- Delegates to Workspace.
function Core:reload_config()
    if not self._workspace then return end
    self._workspace:reload_config()
end

--- Get the workspace initialization state.
--- @return "uninitialized"|"initializing"|"initialized"
function Core:state()
    return self._state
end

--- Get the tool detection state.
--- @return "not_scanned"|"scanning"|"scanned"
function Core:tool_state()
    if not self._workspace then return "not_scanned" end
    return self._workspace._tool_state
end

--- Initialize the workspace asynchronously.
--- Reads files in parallel, then processes synchronously via vim.schedule.
--- @param opts? { root?: string }
function Core:setup(opts)
    if self._state == "initializing" then return end

    self._setup_error = nil
    self._state = "initializing"
    self._deps.events.emit("workspace_initializing")

    local ws_mod = self._deps.workspace
    local root = ws_mod.resolve_root(opts and opts.root or nil)
    local paths = ws_mod.paths(root)

    self._deps.read_files_async(
        { paths.config, paths.user, paths.cache },
        function(results)
            self._deps.schedule(function()
                self:_on_files_read(root, paths, results)
            end)
        end
    )
end

--- Process read file results and complete initialization.
--- @param root string
--- @param paths table
--- @param results table<string, string|nil>
function Core:_on_files_read(root, paths, results)
    local ws_mod = self._deps.workspace

    local function fail(msg, setup_error)
        self._deps.notify("loomworks: " .. msg, vim.log.levels.ERROR)
        self._setup_error = setup_error
        self._state = "uninitialized"
        self._deps.events.emit("workspace_changed", nil)
    end

    local config_content = results[paths.config]
    if not config_content then
        fail("loomworks.json not found in " .. root)
        return
    end
    local user_content = results[paths.user]
    local cache_content = results[paths.cache]

    -- Assemble workspace data from raw content
    local data, err = ws_mod.assemble(root, config_content, user_content, cache_content)
    if not data then
        fail(err)
        return
    end

    -- Refuse to load when cache has incompatible version
    if data.cache_version_mismatch then
        fail("Cache version mismatch. Press <C-n> to reset.",
            { root = root, message = "Cache version mismatch. Press <C-n> to reset." })
        return
    end

    -- Refuse to load when cache is internally inconsistent
    if data.cache_inconsistent then
        fail("Cache is internally inconsistent. Press <C-n> to reset.",
            { root = root, message = "Cache is internally inconsistent. Press <C-n> to reset." })
        return
    end

    -- Refuse to load when user.json has incompatible version
    if data.user_version_mismatch then
        fail("user.json version mismatch. Press U to delete user preferences and reload.",
            { root = root, message = "user.json version mismatch. Press U to delete user preferences and reload.",
              user_version_mismatch = true })
        return
    end

    -- Validate projects
    local ok, val_err = self:_validate_projects(data.config, data.root)
    if not ok then
        fail(val_err)
        return
    end

    -- Create Workspace instance with registries
    self._workspace = Workspace.new(self, data)

    self._workspace:_cleanup_orphaned_skeletons(data.cache)
    self._workspace:remerge(data.config, data.cache)
    self._state = "initialized"
    self._deps.events.emit("workspace_changed", self._workspace)

    -- Start file tracking (owned by Workspace)
    self._workspace:_start_tracking(paths)

    self._deps.notify("loomworks: workspace '" .. self._workspace.name .. "' loaded (" .. self._workspace.root .. ")", vim.log.levels.INFO)

    -- Start async tool detection
    self._workspace:_scan_tools_async()
end

-- ===========================================================================
-- Validation (stays on Core)
-- ===========================================================================

--- Validate all projects against their modules.
--- @param config loomworks.Config
--- @param root string
--- @return boolean ok, string|nil err
function Core:_validate_projects(config, root)
    local modules_mod = self._deps.modules
    for key, project in pairs(config.projects) do
        local mod = modules_mod.get(project.type)
        if mod and mod.validate then
            local abs_path = root .. "/" .. project.path
            local result = mod.validate(abs_path, project.type_config)
            -- Log warnings but don't block loading — missing directories are
            -- normal when projects come from another branch or were removed
            for _, warning in ipairs(result.warnings or {}) do
                self._deps.notify("loomworks: project '" .. key .. "': " .. warning, vim.log.levels.WARN)
            end
        end
    end
    return true, nil
end

-- ===========================================================================
-- Safety & nuke (stays on Core)
-- ===========================================================================

--- Validate that a path is a child of root/.nvim/ before deletion.
--- Uses absolute normalized paths to prevent directory traversal.
--- @param path string path to validate
--- @param root string workspace root
--- @return boolean safe
function Core:_safe_nvim_path(path, root)
    local normalize = self._deps.normalize
    local norm_path = normalize(path)
    local nvim_prefix = normalize(root .. "/.nvim")
    -- Ensure path starts with root/.nvim/ (trailing slash prevents partial matches)
    return norm_path == nvim_prefix or norm_path:sub(1, #nvim_prefix + 1) == nvim_prefix .. "/"
end

--- Nuke the cache: delete .nvim/build/ and loomworks.cache.json, then reload.
--- Caller must confirm with the user before calling this.
--- @param root string workspace root to nuke
function Core:nuke_cache(root)
    -- Safety: root must be absolute (Unix /... or Windows C:/...)
    local norm_root = self._deps.normalize(root)
    if not norm_root:match("^/") and not norm_root:match("^%a:/") then
        self._deps.notify("loomworks: nuke_cache requires an absolute path, got: " .. root, vim.log.levels.ERROR)
        return
    end

    -- Safety: loomworks.json must exist at root (confirms this is a real workspace)
    local config_path = norm_root .. "/loomworks.json"
    if not self._deps.io.read_file(config_path) then
        self._deps.notify("loomworks: no loomworks.json found at " .. norm_root .. ", aborting nuke", vim.log.levels.ERROR)
        return
    end

    -- Build absolute paths
    local build_dir = norm_root .. "/.nvim/build"
    local cache_path = self._deps.cache.filepath(norm_root)
    local cache_bak = cache_path .. ".bak"

    -- Safety: verify all paths are under root/.nvim/
    local paths_to_delete = { build_dir, cache_path, cache_bak }
    for _, p in ipairs(paths_to_delete) do
        if not self:_safe_nvim_path(p, norm_root) then
            self._deps.notify("loomworks: refusing to delete path outside .nvim/: " .. p, vim.log.levels.ERROR)
            return
        end
    end

    -- Delete build directory
    local ok, err = self._deps.io.rm_rf(build_dir)
    if not ok then
        self._deps.notify("loomworks: failed to delete build dir: " .. err, vim.log.levels.ERROR)
    end

    -- Delete cache file and backup
    self._deps.io.rm_rf(cache_path)
    self._deps.io.rm_rf(cache_bak)

    -- Re-setup from scratch
    self:setup({ root = norm_root })
end

--- Delete user.json and reload the workspace.
--- Called when user.json has a version mismatch and user confirms deletion.
--- @param root string
function Core:delete_user_prefs(root)
    local norm_root = self._deps.normalize(root)

    local user_path = self._deps.user.filepath(norm_root)
    if not self:_safe_nvim_path(user_path, norm_root) then
        self._deps.notify("loomworks: refusing to delete path outside .nvim/: " .. user_path, vim.log.levels.ERROR)
        return
    end

    local ok, err = self._deps.io.rm_rf(user_path)
    if not ok then
        self._deps.notify("loomworks: failed to delete user.json: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
    end

    self._deps.notify("loomworks: user preferences deleted, reloading", vim.log.levels.INFO)
    self._setup_error = nil
    self:setup({ root = norm_root })
end

-- ===========================================================================
-- Queries (stays on Core)
-- ===========================================================================

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function Core:get_workspace()
    return self._workspace
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function Core:get_setup_error()
    return self._setup_error
end

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return loomworks.Project|nil
function Core:project_for_buf(bufnr)
    if not self._workspace then return nil end

    local buf_path = self._deps.buf_name(bufnr)
    if buf_path == "" then return nil end
    buf_path = self._deps.normalize(buf_path)

    local best_project, best_len = nil, 0
    for _, project in pairs(self._workspace._projects) do
        local project_path = project.path or project.key
        local project_abs = self._deps.normalize(self._workspace.root .. "/" .. project_path)
        if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
            best_project = project
            best_len = #project_abs
        end
    end

    return best_project
end

--- Stop file tracking and clean up.
function Core:shutdown()
    if self._workspace then
        self._workspace:_stop_tracking()
    end
end

-- ===========================================================================
-- Thin delegation wrappers (forward to Workspace)
-- ===========================================================================
-- These keep the init.lua -> core:method() calling convention working
-- without requiring changes to init.lua or any external callers.

--- @see loomworks.Workspace.remerge
function Core:remerge()
    if not self._workspace then return end
    self._workspace:remerge()
end

--- @see loomworks.Workspace._save_cache
function Core:_save_cache()
    if not self._workspace then return false end
    return self._workspace:_save_cache()
end

--- @see loomworks.Workspace.get_active_configuration_set
function Core:get_active_configuration_set()
    if not self._workspace then return nil end
    return self._workspace:get_active_configuration_set()
end

--- @see loomworks.Workspace.get_active_profile
function Core:get_active_profile()
    if not self._workspace then return nil end
    return self._workspace:get_active_profile()
end

--- @see loomworks.Workspace.get_profiles
function Core:get_profiles()
    if not self._workspace then return {} end
    return self._workspace:get_profiles()
end

--- @see loomworks.Workspace.get_projects
function Core:get_projects()
    if not self._workspace then return {} end
    return self._workspace:get_projects()
end

--- @see loomworks.Workspace.get_config_sets
function Core:get_config_sets()
    if not self._workspace then return {} end
    return self._workspace:get_config_sets()
end

--- @see loomworks.Workspace.get_tool_entries
function Core:get_tool_entries()
    if not self._workspace then return {} end
    return self._workspace:get_tool_entries()
end

--- @see loomworks.Workspace.get_tools_by_type
function Core:get_tools_by_type()
    if not self._workspace then return {} end
    return self._workspace:get_tools_by_type()
end

--- @see loomworks.Workspace.get_orphaned_configs
function Core:get_orphaned_configs()
    if not self._workspace then return {} end
    return self._workspace:get_orphaned_configs()
end

--- @see loomworks.Workspace.create_operation
function Core:create_operation(profile, action, units, target_states)
    if not self._workspace then return nil end
    return self._workspace:create_operation(profile, action, units, target_states)
end

--- @see loomworks.Workspace.get_operations
function Core:get_operations()
    if not self._workspace then return {} end
    return self._workspace:get_operations()
end

--- @see loomworks.Workspace.cancel_conflicting_operations
function Core:cancel_conflicting_operations(units)
    if not self._workspace then return end
    self._workspace:cancel_conflicting_operations(units)
end

--- @see loomworks.Workspace.has_pending_deletions
function Core:has_pending_deletions()
    if not self._workspace then return false end
    return self._workspace:has_pending_deletions()
end

--- @see loomworks.Workspace.after_deletions
function Core:after_deletions(fn)
    if not self._workspace then fn(); return end
    self._workspace:after_deletions(fn)
end

--- @see loomworks.Workspace.has_running_tasks
function Core:has_running_tasks()
    if not self._workspace then return false end
    return self._workspace:has_running_tasks()
end

--- @see loomworks.Workspace.find_running_tasks_for_items
function Core:find_running_tasks_for_items(items)
    if not self._workspace then return {} end
    return self._workspace:find_running_tasks_for_items(items)
end

--- @see loomworks.Workspace.stop_tasks_then
function Core:stop_tasks_then(task_ids, on_done)
    if not self._workspace then on_done(); return end
    self._workspace:stop_tasks_then(task_ids, on_done)
end

--- @see loomworks.Workspace.record_task_result
function Core:record_task_result(result)
    if not self._workspace then return end
    self._workspace:record_task_result(result)
end

--- @see loomworks.Workspace._validate_build_dir
function Core:_validate_build_dir(build_dir, safe_prefix)
    if not self._workspace then return false end
    return self._workspace:_validate_build_dir(build_dir, safe_prefix)
end

--- @see loomworks.Workspace._delete_build_dirs_async
function Core:_delete_build_dirs_async(dirs, callback)
    if not self._workspace then callback({}); return end
    self._workspace:_delete_build_dirs_async(dirs, callback)
end

--- @see loomworks.Workspace.delete_cached_configs
function Core:delete_cached_configs(items)
    if not self._workspace then return end
    self._workspace:delete_cached_configs(items)
end

--- @see loomworks.Workspace.reset_cached_configs
function Core:reset_cached_configs(items)
    if not self._workspace then return end
    self._workspace:reset_cached_configs(items)
end

--- @see loomworks.Workspace.mark_cached_configs_cleaned
function Core:mark_cached_configs_cleaned(items)
    if not self._workspace then return end
    self._workspace:mark_cached_configs_cleaned(items)
end

--- @see loomworks.Workspace._mark_cache_unknown
function Core:_mark_cache_unknown(items)
    if not self._workspace then return end
    self._workspace:_mark_cache_unknown(items)
end

--- @see loomworks.Workspace._run_deletion
function Core:_run_deletion(items, work_fn, on_done, reason)
    if not self._workspace then if on_done then on_done() end; return end
    self._workspace:_run_deletion(items, work_fn, on_done, reason)
end

--- @see loomworks.Workspace.execute_deletion
function Core:execute_deletion(plan, opts, on_done)
    if not self._workspace then if on_done then on_done() end; return end
    self._workspace:execute_deletion(plan, opts, on_done)
end

--- @see loomworks.Workspace._materialize_from_data
function Core:_materialize_from_data(config_set, tool_entry)
    if not self._workspace then return end
    self._workspace:_materialize_from_data(config_set, tool_entry)
end

--- @see loomworks.Workspace._scan_tools
function Core:_scan_tools()
    if not self._workspace then return end
    self._workspace:_scan_tools()
end

--- @see loomworks.Workspace._scan_tools_async
function Core:_scan_tools_async()
    if not self._workspace then return end
    self._workspace:_scan_tools_async()
end

--- @see loomworks.Workspace._scan_targets_async
function Core:_scan_targets_async()
    if not self._workspace then return end
    self._workspace:_scan_targets_async()
end

--- @see loomworks.Workspace._add_launch_config_targets
function Core:_add_launch_config_targets()
    if not self._workspace then return end
    self._workspace:_add_launch_config_targets()
end

--- @see loomworks.Workspace.rescan_tools
function Core:rescan_tools()
    if not self._workspace then return end
    self._workspace:rescan_tools()
end

--- @see loomworks.Workspace._build_referenced_set
function Core:_build_referenced_set()
    if not self._workspace then return {} end
    return self._workspace:_build_referenced_set()
end

--- @see loomworks.Workspace._cleanup_orphaned_skeletons
function Core:_cleanup_orphaned_skeletons(raw_cache)
    if not self._workspace then return end
    self._workspace:_cleanup_orphaned_skeletons(raw_cache)
end

return Core
