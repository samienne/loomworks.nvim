--- loomworks/config_unit.lua — ConfigUnit: atomic unit of configuration state.
--- A ConfigUnit represents a unique (project_key, config_key) combination.
--- It owns the running/deleting state for that combination and provides
--- a single derived state value. Multiple profiles may reference the same
--- ConfigUnit; state changes are visible to all of them.

--- @class loomworks.ConfigUnit
--- @field project_key string
--- @field config_key string
--- @field _core loomworks.Core
--- @field _task_id number|nil current overseer task ID
--- @field _action string|nil "configure" or "build" while a task is running
--- @field _progress loomworks.ProgressUpdate|nil
--- @field _start_time number|nil clock() value when task started
--- @field _deleting boolean
--- @field _listeners function[]
local ConfigUnit = {}
ConfigUnit.__index = ConfigUnit

--- @alias loomworks.ConfigUnitState
--- | "unconfigured"
--- | "configuring"
--- | "configured"
--- | "building"
--- | "built"
--- | "configure_failed"
--- | "build_failed"
--- | "deleting"
--- | "unknown"

--- Create a new ConfigUnit.
--- @param core loomworks.Core
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function ConfigUnit.new(core, project_key, config_key)
  local self = setmetatable({}, ConfigUnit)
  self._core = core
  self.project_key = project_key
  self.config_key = config_key
  self._task_id = nil
  self._action = nil
  self._progress = nil
  self._start_time = nil
  self._deleting = false
  self._queued_action = nil
  self._listeners = {}
  return self
end

function ConfigUnit:__tostring()
  return "ConfigUnit(" .. self.project_key .. ", " .. self.config_key .. ")"
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Get the derived state for this unit.
--- Priority: deleting > running > cached.
--- @return loomworks.ConfigUnitState
function ConfigUnit:state()
  if self._deleting then return "deleting" end
  if self._action then
    return self._action == "configure" and "configuring" or "building"
  end
  local cached = self:cached_state()
  if not cached or not cached.state then return "unconfigured" end
  -- Map cached status names to ConfigUnitState names
  local state = cached.state
  if state == "failed_configure" then return "configure_failed" end
  if state == "failed_build" then return "build_failed" end
  if state == "unknown" then return "unknown" end
  return state
end

--- Check if a task is currently running on this unit.
--- @return boolean
function ConfigUnit:is_running()
  return self._action ~= nil
end

--- Get the running action name, if any.
--- @return string|nil "configure" or "build"
function ConfigUnit:running_action()
  return self._action
end

--- Check if this unit is being deleted/cleaned.
--- @return boolean
function ConfigUnit:is_deleting()
  return self._deleting
end

--- Get cached state from the workspace cache.
--- @return loomworks.CachedConfig|nil
function ConfigUnit:cached_state()
  local ws = self._core:get_workspace()
  if not ws or not ws.cache.projects then return nil end
  local proj = ws.cache.projects[self.project_key]
  if not proj or not proj.configurations then return nil end
  return proj.configurations[self.config_key]
end

--- Get the build directory from cache.
--- @return string|nil
function ConfigUnit:build_dir()
  local cached = self:cached_state()
  return cached and cached.build_dir
end

--- Get the current progress update, if any.
--- @return loomworks.ProgressUpdate|nil
function ConfigUnit:progress()
  return self._progress
end

--- Get elapsed seconds since the running task started.
--- @return number|nil seconds
function ConfigUnit:elapsed()
  if not self._start_time then return nil end
  return self._core._deps.clock() - self._start_time
end

-- ---------------------------------------------------------------------------
-- Config-level actions
-- ---------------------------------------------------------------------------

--- Find all profiles that reference this (project_key, config_key) pair.
--- @return loomworks.Profile[]
function ConfigUnit:referencing_profiles()
  local result = {}
  for _, profile in pairs(self._core._profiles) do
    for _, pp in ipairs(profile:projects()) do
      if pp.project_key == self.project_key and pp.config_key == self.config_key then
        result[#result + 1] = profile
        break
      end
    end
  end
  table.sort(result, function(a, b) return a.key < b.key end)
  return result
end

--- Materialize a skeleton cache entry for this configuration.
--- Used for configuration-level build/configure actions.
function ConfigUnit:materialize()
  local core = self._core
  if not core._workspace then return end

  -- Wait for tool detection to complete before materializing
  if core._tool_state == "scanning" then
    core._tool_waiters[#core._tool_waiters + 1] = function()
      self:materialize()
    end
    return
  end

  local ws = core._workspace
  local project_config = ws.config.projects[self.project_key]
  if not project_config then return end

  -- Parse config_key for variant and tool_key
  local variant, tool_key = core._deps.merge.parse_profile_key(self.config_key)

  -- Resolve tool_data from detected tools
  local dt = tool_key
      and core._deps.merge.resolve_detected_tool(core._tools_by_type, tool_key)
      or nil

  -- Ensure cache structure exists
  local cached_proj = core:_ensure_cached_project(self.project_key)
  if not cached_proj.configurations[self.config_key] then
    cached_proj.configurations[self.config_key] = {
      variant = variant,
      tool_key = tool_key,
      tool_data = dt and dt.tool_data or nil,
    }

    core:_save_cache()
    core:remerge()
  end
end

--- Materialize a pinned profile for this configuration.
--- Creates the config skeleton and a pinned profile entry in cache.
--- @return loomworks.Profile|nil
function ConfigUnit:materialize_pinned()
  local core = self._core
  if not core._workspace then return nil end

  -- Wait for tool detection to complete before materializing
  if core._tool_state == "scanning" then
    core._tool_waiters[#core._tool_waiters + 1] = function()
      self:materialize_pinned()
    end
    return nil
  end

  local ws = core._workspace
  local project_config = ws.config.projects[self.project_key]
  if not project_config then return nil end

  local ak = core._deps.merge.pinned_key(self.project_key, self.config_key)

  -- Ensure config skeleton exists
  self:materialize()

  -- Check if pinned profile already exists
  ws.cache.profiles = ws.cache.profiles or {}
  if ws.cache.profiles[ak] then return core._profiles[ak] end

  -- Parse config_key for variant and tool_key
  local variant, tool_key = core._deps.merge.parse_profile_key(self.config_key)

  -- Resolve tool data
  local tool_data, tool_label, tool_mod_type = nil, nil, nil
  if tool_key then
    local det, mt = core._deps.merge.resolve_detected_tool(
      core._tools_by_type, tool_key)
    if det then
      tool_data = det.tool_data
      tool_label = det.tool_label
      tool_mod_type = mt
    end
  end

  ws.cache.profiles[ak] = {
    mappings = { [self.project_key] = variant },
    tool_key = tool_key,
    tool_data = tool_data,
    tool_label = tool_label,
    tool_mod_type = tool_mod_type,
    projects = {
      [self.project_key] = { config_key = self.config_key },
    },
  }

  core:_save_cache()
  core:remerge()
  return core._profiles[ak]
end

--- Plan a deletion for this config.
--- If any profile references it, disposition = "reset" (clear state, keep
--- skeleton). Otherwise "clean" (remove entirely).
--- @return loomworks.DeletionPlan
function ConfigUnit:plan_deletion()
  local core = self._core
  if not core:get_workspace() then
    return { items = {}, project_key = self.project_key, config_key = self.config_key, defined_in_config = false }
  end

  local ws = core:get_workspace()
  local has_ref = #self:referencing_profiles() > 0

  local items = { {
    project_key = self.project_key,
    config_key = self.config_key,
    build_dir = self:build_dir(),
    disposition = has_ref and "reset" or "clean",
  } }

  local defined_in_config = ws.config.projects[self.project_key] ~= nil

  return {
    items = items,
    project_key = self.project_key,
    config_key = self.config_key,
    defined_in_config = defined_in_config,
  }
end

--- Delete this config (plan + execute, no UI confirmation).
--- @param on_done? function
function ConfigUnit:delete(on_done)
  local plan = self:plan_deletion()
  self._core:execute_deletion(plan, nil, on_done)
end

--- Clean this config: delete build dir and reset to unconfigured.
--- @param on_done? function
function ConfigUnit:clean(on_done)
  if not self._core:get_workspace() then
    if on_done then on_done() end
    return
  end

  local items = { {
    project_key = self.project_key,
    config_key = self.config_key,
    build_dir = self:build_dir(),
  } }
  self._core:_run_deletion(items, function(effective_items)
    self._core:reset_cached_configs(effective_items)
  end, on_done)
end

--- Get build options by delegating to the module.
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function ConfigUnit:options()
  local bd = self:build_dir()
  if not bd then return nil end

  local ws = self._core:get_workspace()
  if not ws then return nil end
  local proj_cfg = ws.config.projects[self.project_key]
  if not proj_cfg then return nil end

  local mod = self._core._deps.modules.get(proj_cfg.type)
  if not mod or not mod.get_options then return nil end

  return mod.get_options(bd, proj_cfg.type_config)
end

-- ---------------------------------------------------------------------------
-- Task tracking (called by task_tracker component and Core)
-- ---------------------------------------------------------------------------

--- Register a running task on this unit.
--- @param task_id number overseer task ID
--- @param action string "configure" or "build"
function ConfigUnit:register_task(task_id, action)
  self._task_id = task_id
  self._action = action
  self._progress = nil
  self._start_time = self._core._deps.clock()
  self:_notify()
end

--- Unregister the running task.
--- @param task_id number overseer task ID (must match current)
function ConfigUnit:unregister_task(task_id)
  if self._task_id ~= task_id then return end
  self._task_id = nil
  self._action = nil
  self._progress = nil
  self._start_time = nil
  self:_notify()
end

--- Update progress for the running task.
--- @param task_id number
--- @param progress loomworks.ProgressUpdate
function ConfigUnit:update_progress(task_id, progress)
  if self._task_id ~= task_id then return end
  self._progress = progress
  self:_notify()
end

--- Mark this unit as deleting/cleaning (or clear the flag).
--- @param flag boolean
function ConfigUnit:mark_deleting(flag)
  self._deleting = flag
  if not flag then
    self._queued_action = nil
  end
  self:_notify()
end

--- Queue an action to run after the current deletion completes.
--- Only valid while the unit is deleting. Replaces any previously queued action.
--- @param action string "configure" or "build"
function ConfigUnit:queue_action(action)
  if not self._deleting then return end
  self._queued_action = action
  self:_notify()
end

--- Get the queued action, if any.
--- @return string|nil "configure" or "build"
function ConfigUnit:queued_action()
  return self._queued_action
end

--- Pop the queued action (retrieve and clear).
--- @return string|nil "configure" or "build"
function ConfigUnit:pop_queued_action()
  local action = self._queued_action
  self._queued_action = nil
  return action
end

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

--- Subscribe to state changes on this unit.
--- The callback receives the unit as its argument.
--- @param fn fun(unit: loomworks.ConfigUnit)
function ConfigUnit:on_state_change(fn)
  self._listeners[#self._listeners + 1] = fn
end

--- Fire all listeners.
function ConfigUnit:_notify()
  for _, fn in ipairs(self._listeners) do
    fn(self)
  end
end

return ConfigUnit
