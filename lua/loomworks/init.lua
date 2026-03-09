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
