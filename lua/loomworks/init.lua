local M = {}

M._version = "0.0.1-dev"

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local events = require("loomworks.events")
local user_mod = require("loomworks.user")
local cache_mod = require("loomworks.cache")

--- @type table|nil cached merged projection
M._active_set = nil

--- @type table<number, { project_key: string, action: string, configuration_key: string }>
--- Maps overseer task id -> running task info
M._running_tasks = {}

--- @type table<string, boolean>
--- Set of "project_key\0config_key" currently being deleted.
M._deleting = {}

--- @type function[]
--- Callbacks waiting for all pending deletions to finish.
M._delete_waiters = {}

--- Initialize loomworks workspace.
--- @param opts? { root?: string }
function M.setup(opts)
  local root = opts and opts.root or nil
  local ok, err = workspace.init(root)
  if not ok then
    vim.notify("loomworks: " .. err, vim.log.levels.ERROR)
    return
  end

  local ws = workspace.get()
  M._active_set = merge.merge(ws)
  events.emit("workspace_changed", ws)
  events.emit("active_set_changed", M._active_set)

  -- Register overseer template provider
  require("loomworks.overseer").register()

  vim.notify("loomworks: workspace '" .. ws.name .. "' loaded (" .. ws.root .. ")", vim.log.levels.INFO)
end

--- Get the merged active configuration set.
--- @return table|nil
function M.get_active_configuration_set()
  return M._active_set
end

--- Register an event listener.
--- @param event string
--- @param fn function
function M.on(event, fn)
  events.on(event, fn)
end

--- Get the active workspace.
--- @return table|nil
function M.get_workspace()
  return workspace.get()
end

--- Activate a named profile.
--- @param profile_key string
function M.activate_profile(profile_key)
  local ws = workspace.get()
  if not ws then
    vim.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  -- Verify profile exists
  local all_profiles = merge.get_all_profiles(ws.config)
  if not all_profiles[profile_key] then
    vim.notify("loomworks: profile '" .. profile_key .. "' not found", vim.log.levels.ERROR)
    return
  end

  ws.user.active_profile = profile_key
  user_mod.save(ws.root, ws.user)

  M._active_set = merge.merge(ws)
  events.emit("active_set_changed", M._active_set)
end

--- Deactivate a profile if it is currently active.
--- Clears the active_profile in user.json so the profile no longer pins in the UI.
--- @param profile_key string
function M.deactivate_profile(profile_key)
  local ws = workspace.get()
  if not ws then return end

  if ws.user.active_profile == profile_key then
    ws.user.active_profile = nil
    user_mod.save(ws.root, ws.user)

    M._active_set = merge.merge(ws)
    events.emit("active_set_changed", M._active_set)
  end
end

--- Activate a named configuration set (legacy convenience wrapper).
--- If cmake projects exist and a kit is active, preserves the kit.
--- @param name string
function M.activate_set(name)
  local ws = workspace.get()
  if not ws then
    vim.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  if not ws.config.configuration_sets or not ws.config.configuration_sets[name] then
    vim.notify("loomworks: configuration set '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  -- Try to preserve the current kit when switching sets
  local current_kit_id = M._active_set and M._active_set.kit_id or nil
  local new_profile_key
  if current_kit_id then
    new_profile_key = merge.profile_key(name, current_kit_id)
  else
    new_profile_key = name
  end

  M.activate_profile(new_profile_key)
end

--- Register a running task for live status display.
--- @param info table { task_id, project_key, action, configuration_key }
function M.register_running_task(info)
  M._running_tasks[info.task_id] = {
    project_key = info.project_key,
    action = info.action,
    configuration_key = info.configuration_key,
  }

  -- Start spinner if status UI is open
  local status_ok, status = pcall(require, "loomworks.ui.status")
  if status_ok then
    status.start_spinner()
  end
end

--- Unregister a running task.
--- @param task_id number
function M.unregister_running_task(task_id)
  M._running_tasks[task_id] = nil

  -- Stop spinner if no more running tasks
  if not next(M._running_tasks) then
    local status_ok, status = pcall(require, "loomworks.ui.status")
    if status_ok then
      status.stop_spinner()
    end
  end
end

--- Get running task info for a project + configuration key.
--- @param project_key string
--- @param config_key string
--- @return string|nil action ("configure" or "build") if running
function M.get_running_action(project_key, config_key)
  for _, info in pairs(M._running_tasks) do
    if info.project_key == project_key and info.configuration_key == config_key then
      return info.action
    end
  end
  return nil
end

--- Check if any task is running for a given project.
--- @param project_key string
--- @return string|nil action
function M.get_project_running_action(project_key)
  for _, info in pairs(M._running_tasks) do
    if info.project_key == project_key then
      return info.action
    end
  end
  return nil
end

--- Record a task result and update the cache.
--- Called by the overseer component when a loomworks task completes.
--- @param result table { project_key, action, configuration_key, build_dir?, cmake?, success }
function M.record_task_result(result)
  local ws = workspace.get()
  if not ws then return end

  local project_key = result.project_key
  local config_key = result.configuration_key
  local action = result.action
  local success = result.success
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Ensure cache structure exists
  ws.cache.projects = ws.cache.projects or {}
  if not ws.cache.projects[project_key] then
    -- Look up project type from config
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
    -- Parse variant and kit_id from config key
    local variant, kit_id = merge.parse_profile_key(config_key)
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

  -- Store build_dir and cmake metadata
  if result.build_dir then
    cached_config.build_dir = result.build_dir
  end
  if result.cmake then
    cached_config.cmake = cached_config.cmake or {}
    for k, v in pairs(result.cmake) do
      cached_config.cmake[k] = v
    end
  end

  -- Save cache to disk
  local ok, err = cache_mod.save(ws.root, ws.cache)
  if not ok then
    vim.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  -- Re-merge and emit events
  M._active_set = merge.merge(ws)
  events.emit("active_set_changed", M._active_set)

  -- Refresh status UI if open
  local status_ok, status = pcall(require, "loomworks.ui.status")
  if status_ok then
    status.refresh()
  end
end

--- Find running task IDs that match a list of project+config items.
--- @param items table[] list of { project_key: string, config_key: string }
--- @return table<number, table> task_id -> running task info
function M.find_running_tasks_for_items(items)
  local matches = {}
  for task_id, info in pairs(M._running_tasks) do
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
function M.stop_tasks_then(task_ids, on_done)
  if #task_ids == 0 then
    on_done()
    return
  end

  local ok, task_list = pcall(require, "overseer.task_list")
  if not ok then
    on_done()
    return
  end

  local remaining = #task_ids
  local function check_done()
    remaining = remaining - 1
    if remaining == 0 then
      vim.schedule(on_done)
    end
  end

  for _, task_id in ipairs(task_ids) do
    local task = task_list.get(task_id)
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

--- Check if a project+config is currently being deleted.
--- @param project_key string
--- @param config_key string
--- @return boolean
function M.is_deleting(project_key, config_key)
  return M._deleting[project_key .. "\0" .. config_key] == true
end

--- Check if any items are currently being deleted.
--- @return boolean
function M.has_pending_deletions()
  return next(M._deleting) ~= nil
end

--- Wait for all pending deletions to finish, then call fn.
--- If nothing is pending, calls fn immediately.
--- @param fn function
function M.after_deletions(fn)
  if not next(M._deleting) then
    fn()
    return
  end
  M._delete_waiters[#M._delete_waiters + 1] = fn
end

--- Mark items as deleting, stop any running tasks, then clean cache + build dirs.
--- Returns immediately — deletion happens asynchronously.
--- @param items table[] list of { project_key: string, config_key: string }
--- @param on_done? function called when deletion is complete
function M.delete_async(items, on_done)
  -- Mark items as deleting
  for _, item in ipairs(items) do
    M._deleting[item.project_key .. "\0" .. item.config_key] = true
  end

  -- Start spinner for deleting state
  local status_ok, status_ui = pcall(require, "loomworks.ui.status")
  if status_ok then
    status_ui.start_spinner()
    status_ui.refresh()
  end

  -- Find and stop running tasks for these items
  local running = M.find_running_tasks_for_items(items)
  local task_ids = {}
  for task_id in pairs(running) do
    task_ids[#task_ids + 1] = task_id
  end

  M.stop_tasks_then(task_ids, function()
    -- Now safe to delete
    M.delete_cached_configs(items)

    -- Unmark deleting state
    for _, item in ipairs(items) do
      M._deleting[item.project_key .. "\0" .. item.config_key] = nil
    end

    -- Notify waiters if no more pending deletions
    if not next(M._deleting) then
      local waiters = M._delete_waiters
      M._delete_waiters = {}
      for _, fn in ipairs(waiters) do
        fn()
      end
    end

    -- Refresh UI
    if status_ok then
      status_ui.refresh()
    end

    if on_done then on_done() end
  end)
end

--- Delete cached configurations and their build directories.
--- @param items table[] list of { project_key: string, config_key: string }
function M.delete_cached_configs(items)
  local ws = workspace.get()
  if not ws then return end

  local uv = vim.uv or vim.loop

  --- Recursively remove a directory tree.
  --- @param dir string
  --- @return boolean ok, string|nil err
  local function rm_rf(dir)
    local stat = uv.fs_stat(dir)
    if not stat then return true, nil end
    if stat.type ~= "directory" then
      local ok, err = uv.fs_unlink(dir)
      if not ok then return false, "unlink " .. dir .. ": " .. (err or "unknown") end
      return true, nil
    end

    local handle = uv.fs_scandir(dir)
    if not handle then return true, nil end

    local errors = {}
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      local full = dir .. "/" .. name
      if ftype == "directory" then
        local ok, err = rm_rf(full)
        if not ok then errors[#errors + 1] = err end
      else
        local ok, err = uv.fs_unlink(full)
        if not ok then errors[#errors + 1] = "unlink " .. full .. ": " .. (err or "unknown") end
      end
    end

    local ok, err = uv.fs_rmdir(dir)
    if not ok then errors[#errors + 1] = "rmdir " .. dir .. ": " .. (err or "unknown") end

    if #errors > 0 then
      return false, table.concat(errors, "; ")
    end
    return true, nil
  end

  -- Safety: only allow deleting directories under the workspace's .nvim/build/
  local safe_prefix = vim.fs.normalize(ws.root .. "/.nvim/build")

  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      local cached_config = cached_proj.configurations[item.config_key]
      -- Delete build directory from disk
      if cached_config and cached_config.build_dir then
        local build_dir = vim.fs.normalize(cached_config.build_dir)
        if build_dir:sub(1, #safe_prefix) == safe_prefix then
          if uv.fs_stat(build_dir) then
            local ok, err = rm_rf(build_dir)
            if not ok then
              vim.notify("loomworks: failed to remove " .. build_dir .. ": " .. err, vim.log.levels.WARN)
            end
          end
        else
          vim.notify("loomworks: refusing to delete build dir outside .nvim/build/: " .. build_dir, vim.log.levels.ERROR)
        end
      end
      -- Remove from cache
      cached_proj.configurations[item.config_key] = nil
      -- Clean up empty project entry
      if not next(cached_proj.configurations) then
        ws.cache.projects[item.project_key] = nil
      end
    end
  end

  -- Save cache
  local ok, err = cache_mod.save(ws.root, ws.cache)
  if not ok then
    vim.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  -- Re-merge and emit events
  M._active_set = merge.merge(ws)
  events.emit("active_set_changed", M._active_set)

  -- Refresh status UI
  local status_ok, status = pcall(require, "loomworks.ui.status")
  if status_ok then
    status.refresh()
  end
end

--- Collect all config items for a profile, with shared-config analysis.
--- @param profile_key string
--- @return table[] items { project_key, config_key, build_dir?, shared_by? }
function M.collect_profile_delete_items(profile_key)
  local ws = workspace.get()
  if not ws then return {} end

  local all_profiles = merge.get_all_profiles(ws.config)
  local profile = all_profiles[profile_key]
  if not profile then return {} end

  local config_sets = ws.config.configuration_sets
  if not profile.configuration_set or not config_sets then return {} end

  local mappings = config_sets[profile.configuration_set]
  if not mappings then return {} end

  -- Build a lookup of which other profiles reference each config key
  local config_key_profiles = {} -- config_key -> list of profile keys that use it
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
  return items
end

--- Collect a single config item for deletion.
--- Lists affected profiles as warnings (not blockers).
--- @param project_key string
--- @param config_key string
--- @return table[] items { project_key, config_key, build_dir?, affected_profiles? }
function M.collect_config_delete_items(project_key, config_key)
  local ws = workspace.get()
  if not ws then return {} end

  local all_profiles = merge.get_all_profiles(ws.config)
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

  return {
    {
      project_key = project_key,
      config_key = config_key,
      build_dir = build_dir,
      -- Single-config deletes are never blocked by sharing — user explicitly chose this.
      -- affected_profiles is informational only.
      affected_profiles = #affected > 0 and affected or nil,
    },
  }
end

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return string|nil project_key, table|nil project_data
function M.project_for_buf(bufnr)
  local ws = workspace.get()
  if not ws then return nil, nil end

  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  if buf_path == "" then return nil, nil end
  buf_path = vim.fs.normalize(buf_path)

  local best_key, best_data, best_len = nil, nil, 0
  for key, project in pairs(ws.config.projects) do
    local project_abs = vim.fs.normalize(ws.root .. "/" .. project.path)
    if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
      best_key = key
      best_data = M._active_set and M._active_set.projects[key] or nil
      best_len = #project_abs
    end
  end

  return best_key, best_data
end

return M
