--- loomworks/init.lua — Public API facade.
--- Creates a singleton Core instance and delegates all calls to it.

local M = {}

M._version = "0.0.1-dev"

local Core = require("loomworks.core")
local events = require("loomworks.events")

--- The singleton core instance. Created at module load time.
--- @type loomworks.Core
local core = Core.new()

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
--- @param opts? { root?: string }
function M.setup(opts)
  if not core:setup(opts) then return end

  -- Register overseer template provider
  require("loomworks.overseer").register()
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

--- Register an event listener.
--- @param event string
--- @param fn function
function M.on(event, fn)
  events.on(event, fn)
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

--- Get a Profile object by key.
--- @param key string profile key
--- @return loomworks.Profile|nil
function M.get_profile(key)
  return core:get_profile(key)
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function M.get_profiles()
  return core:get_profiles()
end

--- Get a Project object by key (from the active set).
--- @param key string project key
--- @return loomworks.Project|nil
function M.get_project(key)
  return core:get_project(key)
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function M.get_projects()
  return core:get_projects()
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Activate a named profile.
--- @param profile_key string
function M.activate_profile(profile_key)
  core:activate_profile(profile_key)
end

--- Deactivate a profile if it is currently active.
--- @param profile_key string
function M.deactivate_profile(profile_key)
  core:deactivate_profile(profile_key)
end

--- Materialize a profile: write it to cache with full tool and project
--- references before any build/configure tasks start.
--- @param profile_key string
function M.materialize_profile(profile_key)
  core:materialize_profile(profile_key)
end

--- Re-scan tools from all modules and remerge.
function M.rescan_tools()
  core:rescan_tools()
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
  core:materialize_configuration(project_key, config_key)
end

--- Create a lightweight ad-hoc profile entry that pins a single config in cache.
--- Returns the ad-hoc profile key (format: "adhoc:<project_key>:<config_key>").
--- @param project_key string
--- @param config_key string
--- @return string adhoc_profile_key
function M.materialize_adhoc(project_key, config_key)
  return core:materialize_adhoc(project_key, config_key)
end

--- Activate a named configuration set.
--- @param name string
function M.activate_set(name)
  core:activate_set(name)
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

--- Start tracking a profile-level operation.
--- @param profile_key string
--- @param action string
function M.start_operation(profile_key, action)
  core:start_operation(profile_key, action)
end

--- Finish a profile-level operation.
--- @param profile_key string
--- @param success boolean
function M.finish_operation(profile_key, success)
  core:finish_operation(profile_key, success)
end

--- Get the current operation state for a profile.
--- @param profile_key string
--- @return loomworks.Operation|nil
function M.get_operation(profile_key)
  return core:get_operation(profile_key)
end

--- Get elapsed seconds for a running operation.
--- @param profile_key string
--- @return number|nil seconds
function M.get_operation_elapsed(profile_key)
  return core:get_operation_elapsed(profile_key)
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

--- Plan a config deletion (query only, no side effects).
--- @param project_key string
--- @param config_key string
--- @return loomworks.DeletionPlan
function M.plan_config_deletion(project_key, config_key)
  return core:plan_config_deletion(project_key, config_key)
end

--- Execute a deletion plan.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: string }
--- @param on_done? function
function M.execute_deletion(plan, opts, on_done)
  core:execute_deletion(plan, opts, on_done)
end

--- Delete a profile (plan + execute, no UI confirmation).
--- @param profile_key string
--- @param on_done? function
function M.delete_profile(profile_key, on_done)
  core:delete_profile(profile_key, on_done)
end

--- Delete a single config (plan + execute, no UI confirmation).
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function M.delete_config(project_key, config_key, on_done)
  core:delete_config(project_key, config_key, on_done)
end

--- Clean a profile: delete build dirs and reset all configs to unconfigured.
--- Does NOT remove or modify any profile.
--- @param profile_key string
--- @param on_done? function
function M.clean_profile(profile_key, on_done)
  core:clean_profile(profile_key, on_done)
end

--- Clean a single config: delete build dir and reset to unconfigured.
--- Does NOT remove or modify any profile.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function M.clean_config(project_key, config_key, on_done)
  core:clean_config(project_key, config_key, on_done)
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
function M.find_running_tasks_for_items(items)
  return core:find_running_tasks_for_items(items)
end

--- Find all materialized profile keys that reference a specific cached config.
--- @param project_key string
--- @param config_key string
--- @return string[] profile_keys
function M.find_referencing_profiles(project_key, config_key)
  return core:find_referencing_profiles(project_key, config_key)
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

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

--- Open the workspace status page.
function M.open()
  require("loomworks.ui.status").open()
end

return M
