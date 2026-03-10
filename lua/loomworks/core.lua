--- loomworks/core.lua — All stateful business logic.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.

--- @class loomworks.Core
--- @field _deps table injected dependencies
--- @field _workspace loomworks.Workspace|nil
--- @field _active_set loomworks.ActiveSet|nil
--- @field _running_tasks table<number, loomworks.RunningTaskInfo>
--- @field _task_progress table<number, loomworks.ProgressUpdate> task_id -> latest progress
--- @field _task_start_times table<number, number> task_id -> os.clock() at start
--- @field _deleting table<string, boolean> "project\0config" -> true
--- @field _delete_waiters function[]
--- @field _generation number incremented on every remerge
--- @field _tracker loomworks.FileTracker|nil
--- @field _operations table<string, loomworks.Operation> profile_key -> active or completed operation
--- @field _detected_tools loomworks.CachedTool[] tools from last scan
--- @field _tool_modules table<string, boolean> module types that provide tools
local Core = {}
Core.__index = Core

local Profile = require("loomworks.profile").Profile
local Project = require("loomworks.project")

--- Default dependency table. Tests override individual entries.
local DEFAULT_DEPS = {
  workspace = require("loomworks.workspace"),
  merge     = require("loomworks.merge"),
  events    = require("loomworks.events"),
  user      = require("loomworks.user"),
  cache     = require("loomworks.cache"),
  config    = require("loomworks.config"),
  io        = require("loomworks.io"),
  modules   = require("loomworks.modules"),
  FileTracker = require("loomworks.file_tracker"),
  notify    = vim.notify,
  now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
  clock     = function() return vim.uv.hrtime() / 1e9 end,
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
--- @return loomworks.Core
function Core.new(deps)
  local self = setmetatable({}, Core)
  if deps then
    self._deps = setmetatable(deps, { __index = DEFAULT_DEPS })
  else
    self._deps = DEFAULT_DEPS
  end
  self._workspace = nil
  self._active_set = nil
  self._running_tasks = {}
  self._task_progress = {}
  self._task_start_times = {}
  self._operations = {}
  self._deleting = {}
  self._delete_waiters = {}
  self._generation = 0
  self._tracker = nil
  self._detected_tools = {}
  self._tool_modules = {}
  return self
end

-- ---------------------------------------------------------------------------
-- Workspace & merge
-- ---------------------------------------------------------------------------

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
      if not result.valid then
        return false, "project '" .. key .. "': " .. table.concat(result.warnings, "; ")
      end
      for _, warning in ipairs(result.warnings) do
        self._deps.notify("loomworks: project '" .. key .. "': " .. warning, vim.log.levels.WARN)
      end
    end
  end
  return true, nil
end

--- Scan tools from all modules present in the workspace.
--- Results are stored on the Core instance for use by merge and UI.
function Core:_scan_tools()
  if not self._workspace then return end
  self._detected_tools, self._tool_modules = self._deps.merge.detect_tools(
    self._workspace.config, self._workspace.cache)
end

--- Re-scan tools and remerge. Used for manual rescan from UI.
function Core:rescan_tools()
  self:_scan_tools()
  self:remerge()
end

--- Check if a module type provides tools (has detected tools).
--- @param mod_type string
--- @return boolean
function Core:module_has_tools(mod_type)
  return self._tool_modules[mod_type] or false
end

--- Get the list of currently detected tools.
--- @return loomworks.CachedTool[]
function Core:get_detected_tools()
  return self._detected_tools
end

--- Handle a tracked file change.
--- @param path string absolute file path that changed
--- @param content string|nil new raw content
function Core:_on_file_changed(path, content)
  if not self._workspace then return end

  local paths = self._deps.workspace.paths(self._workspace.root)

  if path == paths.config then
    -- loomworks.json changed: full reassemble
    local ws, err = self._deps.workspace.assemble(
      self._workspace.root,
      content,
      self._tracker:content(paths.user),
      self._tracker:content(paths.cache)
    )
    if ws then
      local ok, val_err = self:_validate_projects(ws.config, ws.root)
      if ok then
        self._workspace = ws
        self:_scan_tools()
        self:remerge()
        self._deps.notify("loomworks: config reloaded", vim.log.levels.INFO)
      else
        self._deps.notify("loomworks: config reload failed: " .. val_err, vim.log.levels.WARN)
      end
    else
      self._deps.notify("loomworks: config reload failed: " .. (err or "unknown"), vim.log.levels.WARN)
    end

  elseif path == paths.user then
    -- user.json changed: update user data and remerge
    local user_data = content and self._deps.user.parse(content) or self._deps.user.default()
    self._workspace.user = user_data
    self:remerge()

  elseif path == paths.cache then
    -- cache.json changed: update cache data and remerge
    local cache_data = content and self._deps.cache.parse(content) or self._deps.cache.default()
    self._workspace.cache = cache_data
    self:remerge()
  end
end

--- Initialize the workspace and compute the initial merge.
--- @param opts? { root?: string }
--- @return boolean ok
function Core:setup(opts)
  local ws_mod = self._deps.workspace
  local root = ws_mod.resolve_root(opts and opts.root or nil)
  local paths = ws_mod.paths(root)

  -- Read initial file contents via io
  local config_content = self._deps.io.read_file(paths.config)
  if not config_content then
    self._deps.notify("loomworks: loomworks.json not found in " .. root, vim.log.levels.ERROR)
    return false
  end
  local user_content = self._deps.io.read_file(paths.user)
  local cache_content = self._deps.io.read_file(paths.cache)

  -- Assemble workspace from raw content
  local ws, err = ws_mod.assemble(root, config_content, user_content, cache_content)
  if not ws then
    self._deps.notify("loomworks: " .. err, vim.log.levels.ERROR)
    return false
  end

  -- Validate projects
  local ok, val_err = self:_validate_projects(ws.config, ws.root)
  if not ok then
    self._deps.notify("loomworks: " .. val_err, vim.log.levels.ERROR)
    return false
  end

  self._workspace = ws
  self:_scan_tools()
  self._active_set = self._deps.merge.merge(ws, self._detected_tools, self._tool_modules)
  self._generation = self._generation + 1
  self._deps.events.emit("workspace_changed", ws)
  self._deps.events.emit("active_set_changed", self._active_set)

  -- Start file tracking
  if self._tracker then
    self._tracker:stop()
  end
  self._tracker = self._deps.FileTracker.new({
    callback = function(path, content)
      self:_on_file_changed(path, content)
    end,
    schedule = self._deps.schedule,
    read_file = self._deps.io.read_file,
  })
  self._tracker:watch(paths.config)
  self._tracker:watch(paths.user)
  self._tracker:watch(paths.cache)

  self._deps.notify("loomworks: workspace '" .. ws.name .. "' loaded (" .. ws.root .. ")", vim.log.levels.INFO)
  return true
end

--- Re-merge workspace state and emit events.
function Core:remerge()
  if not self._workspace then return end
  self._active_set = self._deps.merge.merge(
    self._workspace, self._detected_tools, self._tool_modules)
  self._generation = self._generation + 1
  self._deps.events.emit("active_set_changed", self._active_set)
end

--- Get the merged active configuration set.
--- @return loomworks.ActiveSet|nil
function Core:get_active_configuration_set()
  return self._active_set
end

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function Core:get_workspace()
  return self._workspace
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

--- Resolve a tool by kit_id from the Core's detected tools list.
--- @param core loomworks.Core
--- @param kit_id string|nil
--- @return loomworks.CachedTool|nil
local function resolve_tool(core, kit_id)
  if not kit_id then return nil end
  for _, tool in ipairs(core._detected_tools) do
    if tool.id == kit_id then
      return tool
    end
  end
  -- Check cache as fallback (tool may no longer be detected)
  local ws = core._workspace
  if ws and ws.cache and ws.cache.profiles then
    for _, profile in pairs(ws.cache.profiles) do
      if profile.tool and profile.tool.id == kit_id then
        return profile.tool
      end
    end
  end
  return nil
end

--- Get a Profile object by key.
--- @param key string profile key
--- @return loomworks.Profile|nil
function Core:get_profile(key)
  if not self._workspace then return nil end

  local ws = self._workspace
  local all_profiles = self._deps.merge.get_all_profiles(ws.config, ws.cache, self._detected_tools)
  local data = all_profiles[key]
  if not data then return nil end

  local config_sets = ws.config.configuration_sets
  local mappings = data.configuration_set and config_sets
      and config_sets[data.configuration_set] or nil

  return Profile.new(self, key, {
    configuration_set = data.configuration_set,
    kit_id = data.kit_id,
    kit = resolve_tool(self, data.kit_id),
    explicit = data.explicit or false,
    auto_generated = data.auto_generated or false,
    materialized = data.materialized or false,
    mappings = mappings,
  })
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function Core:get_profiles()
  if not self._workspace then return {} end

  local ws = self._workspace
  local all_profiles = self._deps.merge.get_all_profiles(ws.config, ws.cache, self._detected_tools)
  local config_sets = ws.config.configuration_sets
  local result = {}

  for key, data in pairs(all_profiles) do
    local mappings = data.configuration_set and config_sets
        and config_sets[data.configuration_set] or nil

    result[key] = Profile.new(self, key, {
      configuration_set = data.configuration_set,
      kit_id = data.kit_id,
      kit = resolve_tool(self, data.kit_id),
      explicit = data.explicit or false,
      auto_generated = data.auto_generated or false,
      materialized = data.materialized or false,
      mappings = mappings,
    })
  end

  return result
end

--- Get a Project object by key (from the active set).
--- @param key string project key
--- @return loomworks.Project|nil
function Core:get_project(key)
  if not self._active_set or not self._active_set.projects[key] then return nil end
  return Project.new(self, key, self._active_set.projects[key])
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function Core:get_projects()
  if not self._active_set then return {} end
  local result = {}
  for key, data in pairs(self._active_set.projects) do
    result[key] = Project.new(self, key, data)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Activate a named profile.
--- @param profile_key string
function Core:activate_profile(profile_key)
  if not self._workspace then
    self._deps.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  local all_profiles = self._deps.merge.get_all_profiles(self._workspace.config, self._workspace.cache)
  if not all_profiles[profile_key] then
    self._deps.notify("loomworks: profile '" .. profile_key .. "' not found", vim.log.levels.ERROR)
    return
  end

  self._workspace.user.active_profile = profile_key
  self._deps.user.save(self._workspace.root, self._workspace.user)

  self:remerge()
end

--- Deactivate a profile if it is currently active.
--- @param profile_key string
function Core:deactivate_profile(profile_key)
  if not self._workspace then return end

  if self._workspace.user.active_profile == profile_key then
    self._workspace.user.active_profile = nil
    self._deps.user.save(self._workspace.root, self._workspace.user)
    self:remerge()
  end
end

--- Activate a named configuration set (legacy convenience wrapper).
--- @param name string
function Core:activate_set(name)
  if not self._workspace then
    self._deps.notify("loomworks: no workspace loaded", vim.log.levels.ERROR)
    return
  end

  if not self._workspace.config.configuration_sets or not self._workspace.config.configuration_sets[name] then
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
-- Profile materialization
-- ---------------------------------------------------------------------------

--- Materialize a profile: write it to cache with full tool and project
--- references BEFORE any build/configure tasks start.
--- Creates skeleton configuration entries in cache.projects.
--- No-op if the profile is already materialized.
--- @param profile_key string
function Core:materialize_profile(profile_key)
  if not self._workspace then return end

  local ws = self._workspace
  local all_profiles = self._deps.merge.get_all_profiles(ws.config, ws.cache, self._detected_tools)
  local profile_def = all_profiles[profile_key]
  if not profile_def then return end

  -- Check if already materialized by tool property comparison
  local profile_tool = resolve_tool(self, profile_def.kit_id)
  local existing = self._deps.merge.find_cached_profile(
    ws.cache, profile_def.configuration_set, profile_tool)
  if existing then return end

  -- Build project mappings from configuration set
  local set_name = profile_def.configuration_set
  local set_mappings = set_name and ws.config.configuration_sets
      and ws.config.configuration_sets[set_name] or {}

  local profile_projects = {}
  for project_key, variant in pairs(set_mappings) do
    local project_config = ws.config.projects[project_key]
    if not project_config then goto continue end

    local has_tools = self._tool_modules[project_config.type] or false
    local config_key
    if profile_def.kit_id and has_tools then
      config_key = variant .. ":" .. profile_def.kit_id
    else
      config_key = variant
    end

    profile_projects[project_key] = { config_key = config_key }

    -- Ensure skeleton config entry exists in cache.projects
    ws.cache.projects = ws.cache.projects or {}
    if not ws.cache.projects[project_key] then
      ws.cache.projects[project_key] = {
        type = project_config.type,
        path = project_config.path or project_key,
        configurations = {},
      }
    end
    local cached_proj = ws.cache.projects[project_key]
    cached_proj.configurations = cached_proj.configurations or {}
    if not cached_proj.configurations[config_key] then
      cached_proj.configurations[config_key] = {
        variant = variant,
        kit_id = profile_def.kit_id,
        tool = has_tools and profile_tool or nil,
      }
    end

    ::continue::
  end

  -- Write profile to cache
  ws.cache.profiles = ws.cache.profiles or {}
  ws.cache.profiles[profile_key] = {
    configuration_set = set_name,
    tool = profile_tool,
    projects = profile_projects,
  }

  local ok, err = self._deps.cache.save(ws.root, ws.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  self:remerge()
end

--- Materialize a single configuration: ensure cache has a skeleton entry.
--- Lighter than materializing a full profile — used for configuration-level
--- build/configure actions.
--- @param project_key string
--- @param config_key string cache key (variant or variant:kit_id)
function Core:materialize_configuration(project_key, config_key)
  if not self._workspace then return end

  local ws = self._workspace
  local project_config = ws.config.projects[project_key]
  if not project_config then return end

  -- Parse config_key for variant and kit_id
  local variant, kit_id = self._deps.merge.parse_profile_key(config_key)
  local has_tools = self._tool_modules[project_config.type] or false
  local tool = has_tools and resolve_tool(self, kit_id) or nil

  -- Ensure cache structure exists
  ws.cache.projects = ws.cache.projects or {}
  if not ws.cache.projects[project_key] then
    ws.cache.projects[project_key] = {
      type = project_config.type,
      path = project_config.path or project_key,
      configurations = {},
    }
  end

  local cached_proj = ws.cache.projects[project_key]
  cached_proj.configurations = cached_proj.configurations or {}
  if not cached_proj.configurations[config_key] then
    cached_proj.configurations[config_key] = {
      variant = variant,
      kit_id = kit_id,
      tool = tool,
    }

    local ok, err = self._deps.cache.save(ws.root, ws.cache)
    if not ok then
      self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end

    self:remerge()
  end
end

-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Register a running task for live status display.
--- @param info { task_id: number, project_key: string, action: string, configuration_key: string, profile_key?: string }
function Core:register_running_task(info)
  self._running_tasks[info.task_id] = {
    project_key = info.project_key,
    action = info.action,
    configuration_key = info.configuration_key,
    profile_key = info.profile_key,
  }
  self._task_start_times[info.task_id] = self._deps.clock()
  self._deps.events.emit("task_started", info)
end

--- Unregister a running task.
--- @param task_id number
function Core:unregister_running_task(task_id)
  self._running_tasks[task_id] = nil
  self._task_progress[task_id] = nil
  self._task_start_times[task_id] = nil
  local has_running = next(self._running_tasks) ~= nil
  self._deps.events.emit("task_stopped", { task_id = task_id, has_running = has_running })
end

--- Get running task info for a project + configuration key (global, any profile).
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

--- Get running task info scoped to a specific profile.
--- Only matches tasks that were launched under this profile_key.
--- @param profile_key string
--- @param project_key string
--- @param config_key string
--- @return string|nil action ("configure" or "build") if running
function Core:get_running_action_for_profile(profile_key, project_key, config_key)
  for _, info in pairs(self._running_tasks) do
    if info.profile_key == profile_key
        and info.project_key == project_key
        and info.configuration_key == config_key then
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

--- Update progress for a running task.
--- @param task_id number
--- @param progress loomworks.ProgressUpdate
function Core:update_task_progress(task_id, progress)
  if not self._running_tasks[task_id] then return end
  self._task_progress[task_id] = progress
  local info = self._running_tasks[task_id]
  self._deps.events.emit("task_progress", {
    task_id = task_id,
    project_key = info.project_key,
    action = info.action,
    configuration_key = info.configuration_key,
    progress = progress,
  })
end

--- Get progress for a running task.
--- @param task_id number
--- @return loomworks.ProgressUpdate|nil
function Core:get_task_progress(task_id)
  return self._task_progress[task_id]
end

--- Get progress for a project+config key (finds the matching running task).
--- @param project_key string
--- @param config_key string
--- @return loomworks.ProgressUpdate|nil
function Core:get_progress(project_key, config_key)
  for task_id, info in pairs(self._running_tasks) do
    if info.project_key == project_key and info.configuration_key == config_key then
      return self._task_progress[task_id]
    end
  end
  return nil
end

--- Get elapsed seconds for a running task.
--- @param task_id number
--- @return number|nil seconds
function Core:get_task_elapsed(task_id)
  local start = self._task_start_times[task_id]
  if not start then return nil end
  return self._deps.clock() - start
end

--- Get elapsed seconds for a project+config key (finds the matching running task).
--- @param project_key string
--- @param config_key string
--- @return number|nil seconds
function Core:get_elapsed(project_key, config_key)
  for task_id, info in pairs(self._running_tasks) do
    if info.project_key == project_key and info.configuration_key == config_key then
      return self:get_task_elapsed(task_id)
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Operations (profile-level action tracking)
-- ---------------------------------------------------------------------------

--- Start tracking a profile-level operation.
--- Replaces any previous operation result for this profile.
--- @param profile_key string
--- @param action string "configure", "build", or "configure+build"
function Core:start_operation(profile_key, action)
  self._operations[profile_key] = {
    action = action,
    started_at = self._deps.clock(),
  }
  self._deps.events.emit("operation_started", { profile_key = profile_key, action = action })
end

--- Finish a profile-level operation and store a result message.
--- @param profile_key string
--- @param success boolean
function Core:finish_operation(profile_key, success)
  local op = self._operations[profile_key]
  if not op or not op.started_at then return end

  local elapsed = self._deps.clock() - op.started_at
  local verb
  if op.action == "configure" then
    verb = success and "configured" or "configure failed"
  elseif op.action == "build" then
    verb = success and "built" or "build failed"
  else
    verb = success and "built" or "failed"
  end

  self._operations[profile_key] = {
    message = verb .. " in " .. self:_format_duration(elapsed),
    success = success,
  }

  self._deps.events.emit("operation_finished", {
    profile_key = profile_key,
    success = success,
    message = self._operations[profile_key].message,
  })
end

--- Get the current operation state for a profile.
--- @param profile_key string
--- @return loomworks.Operation|nil
function Core:get_operation(profile_key)
  return self._operations[profile_key]
end

--- Get elapsed seconds for a running operation.
--- @param profile_key string
--- @return number|nil seconds
function Core:get_operation_elapsed(profile_key)
  local op = self._operations[profile_key]
  if not op or not op.started_at then return nil end
  return self._deps.clock() - op.started_at
end

--- Format a duration in seconds to a compact string.
--- @param seconds number
--- @return string
function Core:_format_duration(seconds)
  local s = math.floor(seconds)
  if s < 60 then
    return s .. "s"
  end
  local m = math.floor(s / 60)
  s = s % 60
  if m < 60 then
    return m .. "m" .. string.format("%02d", s) .. "s"
  end
  local h = math.floor(m / 60)
  m = m % 60
  return h .. "h" .. string.format("%02d", m) .. "m"
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
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
--- @param result loomworks.TaskResult
function Core:record_task_result(result)
  if not self._workspace then return end

  local ws = self._workspace
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
  if result.tool then
    cached_config.tool = result.tool
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
-- Deletion: plan (config-level)
-- ---------------------------------------------------------------------------

--- Plan a single config deletion.
--- @param project_key string
--- @param config_key string
--- @return loomworks.DeletionPlan
function Core:plan_config_deletion(project_key, config_key)
  if not self._workspace then
    return { items = {}, project_key = project_key, config_key = config_key, defined_in_config = false }
  end

  local ws = self._workspace
  local all_profiles = self:get_profiles()
  local config_sets = ws.config.configuration_sets

  -- Find all profiles that reference this config key (informational warning)
  local affected = {}
  if config_sets then
    for _, profile in pairs(all_profiles) do
      local pp = profile:project(project_key)
      if pp and pp.config_key == config_key then
        affected[#affected + 1] = profile.key
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
--- @param items loomworks.DeletionItem[]
function Core:delete_cached_configs(items)
  if not self._workspace then return end

  local ws = self._workspace
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
--- @param plan loomworks.DeletionPlan
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

    -- Remove profile from cache if this is a profile deletion
    if plan.profile_key and self._workspace then
      local ws = self._workspace
      if ws.cache.profiles and ws.cache.profiles[plan.profile_key] then
        ws.cache.profiles[plan.profile_key] = nil
        if not next(ws.cache.profiles) then
          ws.cache.profiles = nil
        end
        self._deps.cache.save(ws.root, ws.cache)
      end
    end

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
  local profile = self:get_profile(profile_key)
  if not profile then
    if on_done then on_done() end
    return
  end
  profile:delete(on_done)
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
--- @return string|nil project_key, loomworks.Project|nil
function Core:project_for_buf(bufnr)
  if not self._workspace then return nil, nil end

  local buf_path = self._deps.buf_name(bufnr)
  if buf_path == "" then return nil, nil end
  buf_path = self._deps.normalize(buf_path)

  local best_key, best_len = nil, 0
  for key, project in pairs(self._workspace.config.projects) do
    local project_abs = self._deps.normalize(self._workspace.root .. "/" .. project.path)
    if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
      best_key = key
      best_len = #project_abs
    end
  end

  if best_key then
    return best_key, self:get_project(best_key)
  end
  return nil, nil
end

--- Stop file tracking and clean up.
function Core:shutdown()
  if self._tracker then
    self._tracker:stop()
    self._tracker = nil
  end
end

return Core
