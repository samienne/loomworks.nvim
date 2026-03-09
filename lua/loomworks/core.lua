--- loomworks/core.lua — All stateful business logic.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.

local Core = {}
Core.__index = Core

--- Default dependency table. Tests override individual entries.
local DEFAULT_DEPS = {
  workspace = require("loomworks.workspace"),
  merge     = require("loomworks.merge"),
  events    = require("loomworks.events"),
  user      = require("loomworks.user"),
  cache     = require("loomworks.cache"),
  io        = require("loomworks.io"),
  notify    = vim.notify,
  now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
  normalize = vim.fs.normalize,
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
--- @return table core instance
function Core.new(deps)
  local self = setmetatable({}, Core)
  if deps then
    self._deps = setmetatable(deps, { __index = DEFAULT_DEPS })
  else
    self._deps = DEFAULT_DEPS
  end
  self._active_set = nil
  self._running_tasks = {}
  self._deleting = {}
  self._delete_waiters = {}
  return self
end

-- ---------------------------------------------------------------------------
-- Workspace & merge
-- ---------------------------------------------------------------------------

--- Initialize the workspace and compute the initial merge.
--- @param opts? { root?: string }
--- @return boolean ok
function Core:setup(opts)
  local root = opts and opts.root or nil
  local ok, err = self._deps.workspace.init(root)
  if not ok then
    self._deps.notify("loomworks: " .. err, vim.log.levels.ERROR)
    return false
  end

  local ws = self._deps.workspace.get()
  self._active_set = self._deps.merge.merge(ws)
  self._deps.events.emit("workspace_changed", ws)
  self._deps.events.emit("active_set_changed", self._active_set)

  self._deps.notify("loomworks: workspace '" .. ws.name .. "' loaded (" .. ws.root .. ")", vim.log.levels.INFO)
  return true
end

--- Re-merge workspace state and emit events.
function Core:remerge()
  local ws = self._deps.workspace.get()
  if not ws then return end
  self._active_set = self._deps.merge.merge(ws)
  self._deps.events.emit("active_set_changed", self._active_set)
end

--- Get the merged active configuration set.
--- @return table|nil
function Core:get_active_configuration_set()
  return self._active_set
end

--- Get the active workspace.
--- @return table|nil
function Core:get_workspace()
  return self._deps.workspace.get()
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Activate a named profile.
--- @param profile_key string
function Core:activate_profile(profile_key)
  local ws = self._deps.workspace.get()
  if not ws then
    self._deps.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  if not all_profiles[profile_key] then
    self._deps.notify("loomworks: profile '" .. profile_key .. "' not found", vim.log.levels.ERROR)
    return
  end

  ws.user.active_profile = profile_key
  self._deps.user.save(ws.root, ws.user)

  self:remerge()
end

--- Deactivate a profile if it is currently active.
--- @param profile_key string
function Core:deactivate_profile(profile_key)
  local ws = self._deps.workspace.get()
  if not ws then return end

  if ws.user.active_profile == profile_key then
    ws.user.active_profile = nil
    self._deps.user.save(ws.root, ws.user)
    self:remerge()
  end
end

--- Activate a named configuration set (legacy convenience wrapper).
--- @param name string
function Core:activate_set(name)
  local ws = self._deps.workspace.get()
  if not ws then
    self._deps.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  if not ws.config.configuration_sets or not ws.config.configuration_sets[name] then
    self._deps.notify("loomworks: configuration set '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local current_kit_id = self._active_set and self._active_set.kit_id or nil
  local new_profile_key
  if current_kit_id then
    new_profile_key = self._deps.merge.profile_key(name, current_kit_id)
  else
    new_profile_key = name
  end

  self:activate_profile(new_profile_key)
end

-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Register a running task for live status display.
--- @param info table { task_id, project_key, action, configuration_key }
function Core:register_running_task(info)
  self._running_tasks[info.task_id] = {
    project_key = info.project_key,
    action = info.action,
    configuration_key = info.configuration_key,
  }
  self._deps.events.emit("task_started", info)
end

--- Unregister a running task.
--- @param task_id number
function Core:unregister_running_task(task_id)
  self._running_tasks[task_id] = nil
  local has_running = next(self._running_tasks) ~= nil
  self._deps.events.emit("task_stopped", { task_id = task_id, has_running = has_running })
end

--- Get running task info for a project + configuration key.
--- @param project_key string
--- @param config_key string
--- @return string|nil action ("configure" or "build") if running
function Core:get_running_action(project_key, config_key)
  for _, info in pairs(self._running_tasks) do
    if info.project_key == project_key and info.configuration_key == config_key then
      return info.action
    end
  end
  return nil
end

--- Check if any task is running for a given project.
--- @param project_key string
--- @return string|nil action
function Core:get_project_running_action(project_key)
  for _, info in pairs(self._running_tasks) do
    if info.project_key == project_key then
      return info.action
    end
  end
  return nil
end

--- Check if any tasks are currently running.
--- @return boolean
function Core:has_running_tasks()
  return next(self._running_tasks) ~= nil
end

--- Find running task IDs that match a list of project+config items.
--- @param items table[] list of { project_key: string, config_key: string }
--- @return table<number, table> task_id -> running task info
function Core:find_running_tasks_for_items(items)
  local matches = {}
  for task_id, info in pairs(self._running_tasks) do
    for _, item in ipairs(items) do
      if info.project_key == item.project_key and info.configuration_key == item.config_key then
        matches[task_id] = info
        break
      end
    end
  end
  return matches
end

--- Stop running overseer tasks and call on_done when all have stopped.
--- @param task_ids number[] overseer task IDs to stop
--- @param on_done function called when all tasks have stopped
function Core:stop_tasks_then(task_ids, on_done)
  if #task_ids == 0 then
    on_done()
    return
  end

  local remaining = #task_ids
  local schedule = self._deps.schedule
  local function check_done()
    remaining = remaining - 1
    if remaining == 0 then
      schedule(on_done)
    end
  end

  for _, task_id in ipairs(task_ids) do
    local task = self._deps.get_overseer_task(task_id)
    if task and not task:is_complete() then
      task:subscribe("on_complete", function()
        check_done()
      end)
      task:stop()
    else
      check_done()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Task result recording
-- ---------------------------------------------------------------------------

--- Record a task result and update the cache.
--- @param result table { project_key, action, configuration_key, build_dir?, cmake?, success }
function Core:record_task_result(result)
  local ws = self._deps.workspace.get()
  if not ws then return end

  local project_key = result.project_key
  local config_key = result.configuration_key
  local action = result.action
  local success = result.success
  local now = self._deps.now()

  -- Ensure cache structure exists
  ws.cache.projects = ws.cache.projects or {}
  if not ws.cache.projects[project_key] then
    local project_config = ws.config.projects[project_key]
    ws.cache.projects[project_key] = {
      type = project_config and project_config.type or "unknown",
      path = project_config and project_config.path or project_key,
      configurations = {},
    }
  end

  local cached_proj = ws.cache.projects[project_key]
  cached_proj.configurations = cached_proj.configurations or {}

  if not cached_proj.configurations[config_key] then
    local variant, kit_id = self._deps.merge.parse_profile_key(config_key)
    cached_proj.configurations[config_key] = {
      variant = variant,
      kit_id = kit_id,
    }
  end

  local cached_config = cached_proj.configurations[config_key]

  if action == "configure" then
    if success then
      cached_config.state = "configured"
      cached_config.last_configured = now
    else
      cached_config.state = "failed_configure"
    end
  elseif action == "build" then
    if success then
      cached_config.state = "built"
      cached_config.last_built = now
    else
      cached_config.state = "failed_build"
    end
  end

  if result.build_dir then
    cached_config.build_dir = result.build_dir
  end
  if result.cmake then
    cached_config.cmake = cached_config.cmake or {}
    for k, v in pairs(result.cmake) do
      cached_config.cmake[k] = v
    end
  end

  local ok, err = self._deps.cache.save(ws.root, ws.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  self:remerge()
  self._deps.events.emit("task_result", result)
end

-- ---------------------------------------------------------------------------
-- Deletion: query & status
-- ---------------------------------------------------------------------------

--- Check if a project+config is currently being deleted.
--- @param project_key string
--- @param config_key string
--- @return boolean
function Core:is_deleting(project_key, config_key)
  return self._deleting[project_key .. "\0" .. config_key] == true
end

--- Check if any items are currently being deleted.
--- @return boolean
function Core:has_pending_deletions()
  return next(self._deleting) ~= nil
end

--- Wait for all pending deletions to finish, then call fn.
--- If nothing is pending, calls fn immediately.
--- @param fn function
function Core:after_deletions(fn)
  if not next(self._deleting) then
    fn()
    return
  end
  self._delete_waiters[#self._delete_waiters + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Deletion: plan
-- ---------------------------------------------------------------------------

--- Collect all config items for a profile, with shared-config analysis.
--- @param profile_key string
--- @return table plan { items, profile_key, defined_in_config }
function Core:plan_profile_deletion(profile_key)
  local ws = self._deps.workspace.get()
  local empty = { items = {}, profile_key = profile_key, defined_in_config = false }
  if not ws then return empty end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  local profile = all_profiles[profile_key]
  if not profile then return empty end

  local config_sets = ws.config.configuration_sets
  if not profile.configuration_set or not config_sets then return empty end

  local mappings = config_sets[profile.configuration_set]
  if not mappings then return empty end

  -- Build a lookup of which other profiles reference each config key
  local config_key_profiles = {}
  for pkey, prof in pairs(all_profiles) do
    if pkey ~= profile_key and prof.configuration_set and config_sets[prof.configuration_set] then
      local other_mappings = config_sets[prof.configuration_set]
      for proj_name, variant in pairs(other_mappings) do
        local ck = prof.kit_id and (variant .. ":" .. prof.kit_id) or variant
        local lookup = proj_name .. "\0" .. ck
        config_key_profiles[lookup] = config_key_profiles[lookup] or {}
        config_key_profiles[lookup][#config_key_profiles[lookup] + 1] = pkey
      end
    end
  end

  local items = {}
  for proj_name, variant in pairs(mappings) do
    local config_key = profile.kit_id and (variant .. ":" .. profile.kit_id) or variant
    local lookup = proj_name .. "\0" .. config_key

    local build_dir = nil
    if ws.cache.projects and ws.cache.projects[proj_name] then
      local cached = ws.cache.projects[proj_name].configurations
      if cached and cached[config_key] then
        build_dir = cached[config_key].build_dir
      end
    end

    items[#items + 1] = {
      project_key = proj_name,
      config_key = config_key,
      build_dir = build_dir,
      shared_by = config_key_profiles[lookup],
    }
  end

  table.sort(items, function(a, b) return a.project_key < b.project_key end)

  local defined_in_config = ws.config.profiles and ws.config.profiles[profile_key] or false

  return {
    items = items,
    profile_key = profile_key,
    defined_in_config = defined_in_config and true or false,
  }
end

--- Collect a single config item for deletion.
--- @param project_key string
--- @param config_key string
--- @return table plan { items, project_key, config_key, defined_in_config }
function Core:plan_config_deletion(project_key, config_key)
  local ws = self._deps.workspace.get()
  if not ws then
    return { items = {}, project_key = project_key, config_key = config_key, defined_in_config = false }
  end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  local config_sets = ws.config.configuration_sets

  -- Find all profiles that reference this config key (informational warning)
  local affected = {}
  if config_sets then
    for pkey, prof in pairs(all_profiles) do
      if prof.configuration_set and config_sets[prof.configuration_set] then
        local other_mappings = config_sets[prof.configuration_set]
        for proj_name, variant in pairs(other_mappings) do
          local ck = prof.kit_id and (variant .. ":" .. prof.kit_id) or variant
          if proj_name == project_key and ck == config_key then
            affected[#affected + 1] = pkey
          end
        end
      end
    end
  end

  local build_dir = nil
  if ws.cache.projects and ws.cache.projects[project_key] then
    local cached = ws.cache.projects[project_key].configurations
    if cached and cached[config_key] then
      build_dir = cached[config_key].build_dir
    end
  end

  local defined_in_config = ws.config.projects[project_key] ~= nil

  return {
    items = {
      {
        project_key = project_key,
        config_key = config_key,
        build_dir = build_dir,
        affected_profiles = #affected > 0 and affected or nil,
      },
    },
    project_key = project_key,
    config_key = config_key,
    defined_in_config = defined_in_config,
  }
end

-- ---------------------------------------------------------------------------
-- Deletion: execute
-- ---------------------------------------------------------------------------

--- Delete cached configurations and their build directories (synchronous part).
--- @param items table[] list of { project_key: string, config_key: string }
function Core:delete_cached_configs(items)
  local ws = self._deps.workspace.get()
  if not ws then return end

  local normalize = self._deps.normalize
  local io_mod = self._deps.io

  -- Safety: only allow deleting directories under the workspace's .nvim/build/
  local safe_prefix = normalize(ws.root .. "/.nvim/build")

  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      local cached_config = cached_proj.configurations[item.config_key]
      if cached_config and cached_config.build_dir then
        local build_dir = normalize(cached_config.build_dir)
        if build_dir:sub(1, #safe_prefix) == safe_prefix then
          local ok, err = io_mod.rm_rf(build_dir)
          if not ok then
            self._deps.notify("loomworks: failed to remove " .. build_dir .. ": " .. err, vim.log.levels.WARN)
          end
        else
          self._deps.notify("loomworks: refusing to delete build dir outside .nvim/build/: " .. build_dir, vim.log.levels.ERROR)
        end
      end
      cached_proj.configurations[item.config_key] = nil
      if not next(cached_proj.configurations) then
        ws.cache.projects[item.project_key] = nil
      end
    end
  end

  local ok, err = self._deps.cache.save(ws.root, ws.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  self:remerge()
end

--- Execute a deletion plan asynchronously.
--- Marks items as deleting, stops running tasks, cleans cache + build dirs.
--- @param plan table from plan_profile_deletion or plan_config_deletion
--- @param opts? { deactivate_profile?: string }
--- @param on_done? function called when deletion is complete
function Core:execute_deletion(plan, opts, on_done)
  opts = opts or {}

  -- Filter to only non-shared items (shared items have shared_by set)
  local to_delete = {}
  for _, item in ipairs(plan.items) do
    if not item.shared_by or #item.shared_by == 0 then
      to_delete[#to_delete + 1] = item
    end
  end

  if #to_delete == 0 then
    if on_done then on_done() end
    return
  end

  -- Deactivate profile if requested
  if opts.deactivate_profile then
    self:deactivate_profile(opts.deactivate_profile)
  end

  -- Mark items as deleting
  for _, item in ipairs(to_delete) do
    self._deleting[item.project_key .. "\0" .. item.config_key] = true
  end

  self._deps.events.emit("deletion_started", to_delete)

  -- Find and stop running tasks for these items
  local running = self:find_running_tasks_for_items(to_delete)
  local task_ids = {}
  for task_id in pairs(running) do
    task_ids[#task_ids + 1] = task_id
  end

  self:stop_tasks_then(task_ids, function()
    -- Now safe to delete
    self:delete_cached_configs(to_delete)

    -- Unmark deleting state
    for _, item in ipairs(to_delete) do
      self._deleting[item.project_key .. "\0" .. item.config_key] = nil
    end

    -- Notify waiters if no more pending deletions
    if not next(self._deleting) then
      local waiters = self._delete_waiters
      self._delete_waiters = {}
      for _, fn in ipairs(waiters) do
        fn()
      end
    end

    self._deps.events.emit("deletion_completed", to_delete)

    if on_done then on_done() end
  end)
end

--- Convenience: delete a profile without UI confirmation.
--- @param profile_key string
--- @param on_done? function
function Core:delete_profile(profile_key, on_done)
  local plan = self:plan_profile_deletion(profile_key)
  if #plan.items == 0 then
    if on_done then on_done() end
    return
  end
  self:execute_deletion(plan, { deactivate_profile = profile_key }, on_done)
end

--- Convenience: delete a single config without UI confirmation.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function Core:delete_config(project_key, config_key, on_done)
  local plan = self:plan_config_deletion(project_key, config_key)
  if #plan.items == 0 then
    if on_done then on_done() end
    return
  end
  self:execute_deletion(plan, nil, on_done)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return string|nil project_key, table|nil project_data
function Core:project_for_buf(bufnr)
  local ws = self._deps.workspace.get()
  if not ws then return nil, nil end

  local buf_path = self._deps.buf_name(bufnr)
  if buf_path == "" then return nil, nil end
  buf_path = self._deps.normalize(buf_path)

  local best_key, best_data, best_len = nil, nil, 0
  for key, project in pairs(ws.config.projects) do
    local project_abs = self._deps.normalize(ws.root .. "/" .. project.path)
    if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
      best_key = key
      best_data = self._active_set and self._active_set.projects[key] or nil
      best_len = #project_abs
    end
  end

  return best_key, best_data
end

--- Check if a profile has any configured entries in cache.
--- @param profile_key string
--- @return boolean
function Core:is_profile_configured(profile_key)
  local ws = self._deps.workspace.get()
  if not ws then return false end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  local profile = all_profiles[profile_key]
  if not profile then return false end
  if not ws.cache.projects then return false end

  local config_sets = ws.config.configuration_sets
  local valid_variants = {}
  if profile.configuration_set and config_sets then
    local mappings = config_sets[profile.configuration_set]
    if mappings then
      for _, variant in pairs(mappings) do
        valid_variants[variant] = true
      end
    end
  end

  for _, cached_proj in pairs(ws.cache.projects) do
    if cached_proj.configurations then
      for config_key, _ in pairs(cached_proj.configurations) do
        local variant, kit_id = self._deps.merge.parse_profile_key(config_key)
        if kit_id == profile.kit_id and valid_variants[variant] then
          return true
        end
        if not profile.kit_id and not kit_id and valid_variants[variant] then
          return true
        end
      end
    end
  end
  return false
end

--- Compute aggregate status for a profile from its constituent project states.
--- @param profile_key string
--- @return string label, string hl_group
function Core:resolve_profile_status(profile_key)
  local ws = self._deps.workspace.get()
  if not ws then return "unconfigured", "Comment" end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  local profile = all_profiles[profile_key]
  if not profile then return "unconfigured", "Comment" end

  local config_sets = ws.config.configuration_sets
  if not profile.configuration_set or not config_sets then
    return "unconfigured", "Comment"
  end

  local mappings = config_sets[profile.configuration_set]
  if not mappings then return "unconfigured", "Comment" end

  local STATUS_HL = {
    unconfigured     = "Comment",
    configured       = "DiagnosticInfo",
    built            = "DiagnosticOk",
    failed_configure = "DiagnosticError",
    failed_build     = "DiagnosticError",
  }

  local total = 0
  local counts = {
    unconfigured = 0,
    configured = 0,
    built = 0,
    failed_configure = 0,
    failed_build = 0,
    configuring = 0,
    building = 0,
    deleting = 0,
  }

  for pname, variant in pairs(mappings) do
    total = total + 1
    local config_key = profile.kit_id and (variant .. ":" .. profile.kit_id) or variant

    if self:is_deleting(pname, config_key) then
      counts.deleting = counts.deleting + 1
    else
      local running_action = self:get_running_action(pname, config_key)
      if running_action then
        local state = running_action == "configure" and "configuring" or "building"
        counts[state] = counts[state] + 1
      else
        local state = "unconfigured"
        if ws.cache.projects and ws.cache.projects[pname] and ws.cache.projects[pname].configurations then
          local cached = ws.cache.projects[pname].configurations[config_key]
          if cached and cached.state then
            state = cached.state
          end
        end
        counts[state] = (counts[state] or 0) + 1
      end
    end
  end

  if total == 0 then return "empty", "Comment" end

  if counts.deleting > 0 then
    return "deleting " .. counts.deleting .. "/" .. total, "DiagnosticError"
  end

  local running = counts.configuring + counts.building
  local failed = counts.failed_configure + counts.failed_build

  if running > 0 then
    local parts = {}
    if counts.configuring > 0 then parts[#parts + 1] = "configuring " .. counts.configuring end
    if counts.building > 0 then parts[#parts + 1] = "building " .. counts.building end
    if failed > 0 then parts[#parts + 1] = failed .. " failed" end
    return table.concat(parts, ", "), "DiagnosticWarn"
  end

  if counts.built == total then return "built", STATUS_HL.built end
  if counts.configured == total then return "configured", STATUS_HL.configured end
  if counts.unconfigured == total then return "unconfigured", STATUS_HL.unconfigured end

  if failed > 0 then
    local parts = {}
    if counts.failed_configure > 0 then
      parts[#parts + 1] = counts.failed_configure .. " failed configure"
    end
    if counts.failed_build > 0 then
      parts[#parts + 1] = counts.failed_build .. " failed build"
    end
    local ok_count = counts.built + counts.configured
    if ok_count > 0 then
      parts[#parts + 1] = ok_count .. "/" .. total .. " ok"
    end
    return table.concat(parts, ", "), "DiagnosticError"
  end

  local parts = {}
  if counts.built > 0 then parts[#parts + 1] = counts.built .. " built" end
  if counts.configured > 0 then parts[#parts + 1] = counts.configured .. " configured" end
  if counts.unconfigured > 0 then parts[#parts + 1] = counts.unconfigured .. " unconfigured" end
  return table.concat(parts, ", "), "DiagnosticInfo"
end

--- Check if a profile has any running tasks.
--- @param profile_key string
--- @return boolean
function Core:is_profile_running(profile_key)
  local ws = self._deps.workspace.get()
  if not ws then return false end

  local all_profiles = self._deps.merge.get_all_profiles(ws.config)
  local profile = all_profiles[profile_key]
  if not profile then return false end

  local config_sets = ws.config.configuration_sets
  local set_mappings = profile.configuration_set
      and config_sets and config_sets[profile.configuration_set]
  if not set_mappings then return false end

  local profile_variants = {}
  for _, variant in pairs(set_mappings) do
    profile_variants[variant] = true
  end

  for _, info in pairs(self._running_tasks) do
    local task_variant, task_kit = self._deps.merge.parse_profile_key(info.configuration_key)
    if profile_variants[task_variant] and task_kit == profile.kit_id then
      return true
    end
  end
  return false
end

--- Resolve the cached state for a configuration within a project.
--- @param proj table project data from merge
--- @param cname string configuration name
--- @return table|nil cached_state
function Core:resolve_cached_config(proj, cname)
  if not proj.cached_configurations then return nil end
  if proj.kit_id then
    local cached = proj.cached_configurations[cname .. ":" .. proj.kit_id]
    if cached then return cached end
  end
  return proj.cached_configurations[cname]
end

return Core
