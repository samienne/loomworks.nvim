--- loomworks/init.lua — Public API facade.
--- Creates a singleton Core instance and delegates all calls to it.

local M = {}

M._version = "0.0.1-dev"

local Core = require("loomworks.core")
local events = require("loomworks.events")

--- The singleton core instance. Created at module load time.
--- @type loomworks.Core
local core = Core.new()

--- Auto-load mode. Default: "auto".
--- @type string|false
local auto_load_mode = "auto"

--- Access the underlying core instance (for advanced use / testing).
--- @return loomworks.Core
function M._core()
    return core
end

--- Emit an event. Used by components that bypass Core (e.g. task_tracker).
--- @param event string
--- @param data any
function M._emit(event, data)
    events.emit(event, data)
end

-- ---------------------------------------------------------------------------
-- Setup & workspace
-- ---------------------------------------------------------------------------

--- Initialize loomworks workspace.
--- @param opts? { root?: string, auto_load?: string|false }
function M.setup(opts)
    if opts and opts.auto_load ~= nil then
        auto_load_mode = opts.auto_load
    end

    -- Optional fidget.nvim integration for progress notifications (registers listeners, fast)
    require("loomworks.fidget").setup()

    core:setup(opts)
end

--- Get the current auto-load mode.
--- @return string|false
function M._auto_load_mode()
    return auto_load_mode
end

--- Get the merged active configuration set.
--- @return loomworks.ActiveSet|nil
function M.get_active_configuration_set()
    return core:get_active_configuration_set()
end

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function M.get_workspace()
    return core:get_workspace()
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function M.get_setup_error()
    return core:get_setup_error()
end

--- Register an event listener.
--- @param event string
--- @param fn function
function M.on(event, fn)
    events.on(event, fn)
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

--- Get the active Profile object.
--- @return loomworks.Profile|nil
function M.get_active_profile()
    return core:get_active_profile()
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function M.get_profiles()
    return core:get_profiles()
end

--- Get tool entries for the configuration sets UI.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function M.get_tool_entries()
    return core:get_tool_entries()
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function M.get_projects()
    return core:get_projects()
end

--- Get all ConfigurationSet objects.
--- @return table<string, loomworks.ConfigurationSet>
function M.get_config_sets()
    return core:get_config_sets()
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Re-scan tools from all modules and remerge.
function M.rescan_tools()
    core:rescan_tools()
end

--- Nuke the cache: delete .nvim/build/ and loomworks.cache.json, then reload.
--- Caller must confirm with the user before calling this.
--- @param root string workspace root to nuke
function M.nuke_cache(root)
    core:nuke_cache(root)
end

--- Check if a module type has keyed tools (tools with non-nil tool_key).
--- @param mod_type string
--- @return boolean
function M.module_has_keyed_tools(mod_type)
    return core:module_has_keyed_tools(mod_type)
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function M.get_tools_by_type()
    return core:get_tools_by_type()
end

--- Materialize a single configuration in cache (skeleton entry).
--- @param project_key string
--- @param config_key string
function M.materialize_configuration(project_key, config_key)
    core:get_config_unit(project_key, config_key):materialize()
end

--- Create a pinned profile entry that pins a single config in cache.
--- Returns the pinned Profile object.
--- @param project_key string
--- @param config_key string
--- @return loomworks.Profile|nil
function M.materialize_pinned(project_key, config_key)
    return core:get_config_unit(project_key, config_key):materialize_pinned()
end

-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Check if any tasks are currently running.
--- @return boolean
function M.has_running_tasks()
    return core:has_running_tasks()
end

-- ---------------------------------------------------------------------------
-- Progress tracking
-- ---------------------------------------------------------------------------

--- Get a ConfigUnit for a (project_key, config_key) pair.
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function M.get_config_unit(project_key, config_key)
    return core:get_config_unit(project_key, config_key)
end

--- Get progress for a project+config key.
--- @param project_key string
--- @param config_key string
--- @return loomworks.ProgressUpdate|nil
function M.get_progress(project_key, config_key)
    return core:get_config_unit(project_key, config_key):progress()
end

--- Get elapsed seconds for a project+config key.
--- @param project_key string
--- @param config_key string
--- @return number|nil seconds
function M.get_elapsed(project_key, config_key)
    return core:get_config_unit(project_key, config_key):elapsed()
end

-- ---------------------------------------------------------------------------
-- Task results
-- ---------------------------------------------------------------------------

--- Record a task result and update the cache.
--- @param result loomworks.TaskResult
function M.record_task_result(result)
    core:record_task_result(result)
end

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

--- Check if any items are currently being deleted.
--- @return boolean
function M.has_pending_deletions()
    return core:has_pending_deletions()
end

--- Wait for all pending deletions to finish, then call fn.
--- @param fn function
function M.after_deletions(fn)
    core:after_deletions(fn)
end

--- Execute a deletion plan.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: loomworks.Profile }
--- @param on_done? function
function M.execute_deletion(plan, opts, on_done)
    core:execute_deletion(plan, opts, on_done)
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
function M.find_running_tasks_for_items(items)
    return core:find_running_tasks_for_items(items)
end

--- Find all profiles that reference a specific cached config.
--- @param project_key string
--- @param config_key string
--- @return loomworks.Profile[]
function M.find_referencing_profiles(project_key, config_key)
    return core:get_config_unit(project_key, config_key):referencing_profiles()
end

--- Get orphaned cached configs (configs with state not referenced by any profile).
--- @return loomworks.OrphanedConfig[]
function M.get_orphaned_configs()
    return core:get_orphaned_configs()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return string|nil project_key, loomworks.Project|nil
function M.project_for_buf(bufnr)
    return core:project_for_buf(bufnr)
end

--- Get status info for the buffer's project, suitable for statusline/winbar.
--- @param bufnr? number defaults to current buffer
--- @return loomworks.BufStatus|nil
function M.buf_status(bufnr)
    bufnr = bufnr or 0
    local active_set = core:get_active_configuration_set()
    if not active_set then return nil end

    local project_key, project = core:project_for_buf(bufnr)
    if not project_key then return nil end

    local profile = core:get_active_profile()
    local set_name = profile and profile.configuration_set or nil

    local status
    if project.configuration_key then
        status = core:get_config_unit(project_key, project.configuration_key):state()
    end

    return {
        profile_key = active_set.name,
        set_name = set_name,
        tool_key = project.tool and project.tool.key or nil,
        project = project_key,
        configuration = project.configuration,
        status = status,
    }
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

--- Open the workspace status page.
--- @param win_overrides? table Snacks.win config overrides
function M.open(win_overrides)
    require("loomworks.ui.status").open(win_overrides)
end

function M.toggle()
    require("loomworks.ui.status").toggle()
end

return M
