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
--- @field _tools_by_type table<string, loomworks.DetectedTool[]> tools per module type
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
  self._tools_by_type = {}
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
  self._tools_by_type = self._deps.merge.detect_tools(
    self._workspace.config, self._workspace.cache)
end

--- Re-scan tools and remerge. Used for manual rescan from UI.
function Core:rescan_tools()
  self:_scan_tools()
  self:remerge()
end

--- Check if a module type has keyed tools (tools with non-nil tool_key).
--- @param mod_type string
--- @return boolean
function Core:module_has_keyed_tools(mod_type)
  return self._deps.merge.module_has_keyed_tools(self._tools_by_type, mod_type)
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function Core:get_tools_by_type()
  return self._tools_by_type
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
  self:_adopt_orphaned_configs()
  self._active_set = self._deps.merge.merge(ws, self._tools_by_type)
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
    self._workspace, self._tools_by_type)
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

--- Resolve mappings for a profile definition.
--- Ad-hoc profiles derive mappings from their single project+config_key.
--- Full profiles derive mappings from configuration_sets.
--- @param data loomworks.ProfileDef
--- @param config_sets table|nil
--- @return table<string, string>|nil
local function resolve_profile_mappings(data, config_sets)
  if data.ad_hoc then
    if data.project_key and data.config_key then
      local variant = require("loomworks.merge").parse_profile_key(data.config_key)
      return { [data.project_key] = variant }
    end
    return nil
  end
  return data.configuration_set and config_sets
      and config_sets[data.configuration_set] or nil
end

--- Get a Profile object by key.
--- @param key string profile key
--- @return loomworks.Profile|nil
function Core:get_profile(key)
  if not self._workspace then return nil end

  local ws = self._workspace
  local all_profiles = self._deps.merge.get_all_profiles(
    ws.config, ws.cache, self._tools_by_type)
  local data = all_profiles[key]
  if not data then return nil end

  local mappings = resolve_profile_mappings(data, ws.config.configuration_sets)

  return Profile.new(self, key, {
    configuration_set = data.configuration_set,
    ad_hoc = data.ad_hoc or false,
    project_key = data.project_key,
    config_key = data.config_key,
    tool_key = data.tool_key,
    tool_data = data.tool_data,
    tool_label = data.tool_label,
    tool_mod_type = data.tool_mod_type,
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
  local all_profiles = self._deps.merge.get_all_profiles(
    ws.config, ws.cache, self._tools_by_type)
  local config_sets = ws.config.configuration_sets
  local result = {}

  for key, data in pairs(all_profiles) do
    local mappings = resolve_profile_mappings(data, config_sets)

    result[key] = Profile.new(self, key, {
      configuration_set = data.configuration_set,
      ad_hoc = data.ad_hoc or false,
      project_key = data.project_key,
      config_key = data.config_key,
      tool_key = data.tool_key,
      tool_data = data.tool_data,
      tool_label = data.tool_label,
      tool_mod_type = data.tool_mod_type,
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

  local all_profiles = self._deps.merge.get_all_profiles(
    self._workspace.config, self._workspace.cache, self._tools_by_type)
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

  local current_kit_id = self._active_set and self._active_set.tool_key or nil
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
  local all_profiles = self._deps.merge.get_all_profiles(
    ws.config, ws.cache, self._tools_by_type)
  local profile_def = all_profiles[profile_key]
  if not profile_def then return end

  -- Check if already materialized by tool_data comparison
  local existing = self._deps.merge.find_cached_profile(
    ws.cache, profile_def.configuration_set, profile_def.tool_data)
  if existing then return end

  -- Build project mappings from configuration set
  local set_name = profile_def.configuration_set
  local set_mappings = set_name and ws.config.configuration_sets
      and ws.config.configuration_sets[set_name] or {}

  local profile_projects = {}
  for project_key, variant in pairs(set_mappings) do
    local project_config = ws.config.projects[project_key]
    if not project_config then goto continue end

    local config_key = self._deps.merge.build_config_key(
      self._tools_by_type, project_config.type, variant, profile_def.tool_key)

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
      local has_keyed = self._deps.merge.module_has_keyed_tools(
        self._tools_by_type, project_config.type)
      cached_proj.configurations[config_key] = {
        variant = variant,
        tool_key = profile_def.tool_key,
        tool_data = has_keyed and profile_def.tool_data or nil,
      }
    end

    ::continue::
  end

  -- Write profile to cache
  ws.cache.profiles = ws.cache.profiles or {}
  ws.cache.profiles[profile_key] = {
    configuration_set = set_name,
    tool_key = profile_def.tool_key,
    tool_data = profile_def.tool_data,
    tool_label = profile_def.tool_label,
    tool_mod_type = profile_def.tool_mod_type,
    projects = profile_projects,
  }

  local ok, err = self._deps.cache.save(ws.root, ws.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  self:remerge()
end

--- Adopt orphaned cached configs on init.
--- Configs in configured/built/failed state with no profile reference
--- get an ad-hoc profile created. Unconfigured skeletons are silently dropped.
function Core:_adopt_orphaned_configs()
  local ws = self._workspace
  if not ws or not ws.cache.projects then return end

  -- Build a set of all (project_key, config_key) pairs referenced by profiles
  local referenced = {}
  if ws.cache.profiles then
    for _, profile in pairs(ws.cache.profiles) do
      if profile.projects then
        for pkey, pdata in pairs(profile.projects) do
          if pdata.config_key then
            referenced[pkey .. "\0" .. pdata.config_key] = true
          end
        end
      end
    end
  end

  local changed = false
  ws.cache.profiles = ws.cache.profiles or {}

  for project_key, cached_proj in pairs(ws.cache.projects) do
    if cached_proj.configurations then
      local to_drop = {}
      for config_key, cached_config in pairs(cached_proj.configurations) do
        if not referenced[project_key .. "\0" .. config_key] then
          local state = cached_config.state
          if state and state ~= "unconfigured" then
            -- Adopt: create ad-hoc profile
            local adhoc_key = "adhoc:" .. project_key .. ":" .. config_key
            local variant, tool_key = self._deps.merge.parse_profile_key(config_key)

            -- Resolve tool info from detected tools
            local tool_data, tool_label, tool_mod_type = nil, nil, nil
            if tool_key then
              for mod_type, tools in pairs(self._tools_by_type) do
                for _, dt in ipairs(tools) do
                  if dt.tool_key == tool_key then
                    tool_data = dt.tool_data
                    tool_label = dt.tool_label
                    tool_mod_type = mod_type
                    break
                  end
                end
                if tool_data then break end
              end
            end

            ws.cache.profiles[adhoc_key] = {
              ad_hoc = true,
              project_key = project_key,
              config_key = config_key,
              tool_key = tool_key,
              tool_data = tool_data or cached_config.tool_data,
              tool_label = tool_label,
              tool_mod_type = tool_mod_type,
              projects = {
                [project_key] = { config_key = config_key },
              },
            }
            changed = true
          else
            -- Drop: unconfigured skeleton
            to_drop[#to_drop + 1] = config_key
            changed = true
          end
        end
      end
      for _, config_key in ipairs(to_drop) do
        cached_proj.configurations[config_key] = nil
      end
      if not next(cached_proj.configurations) then
        ws.cache.projects[project_key] = nil
      end
    end
  end

  if not next(ws.cache.projects) then
    ws.cache.projects = nil
  end
  if ws.cache.profiles and not next(ws.cache.profiles) then
    ws.cache.profiles = nil
  end

  if changed then
    local ok, err = self._deps.cache.save(ws.root, ws.cache)
    if not ok then
      self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end
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

  -- Parse config_key for variant and tool_key
  local variant, tool_key = self._deps.merge.parse_profile_key(config_key)

  -- Resolve tool_data from detected tools
  local tool_data = nil
  if tool_key then
    for _, tools in pairs(self._tools_by_type) do
      for _, dt in ipairs(tools) do
        if dt.tool_key == tool_key then
          tool_data = dt.tool_data
          break
        end
      end
      if tool_data then break end
    end
  end

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
      tool_key = tool_key,
      tool_data = tool_data,
    }

    local ok, err = self._deps.cache.save(ws.root, ws.cache)
    if not ok then
      self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
    end

    self:remerge()
  end
end

--- Materialize an ad-hoc profile: a lightweight single-config pin.
--- Creates the config skeleton and an ad-hoc profile entry in cache.
--- Returns the ad-hoc profile key.
--- @param project_key string
--- @param config_key string
--- @return string|nil adhoc_key
function Core:materialize_adhoc(project_key, config_key)
  if not self._workspace then return nil end

  local ws = self._workspace
  local project_config = ws.config.projects[project_key]
  if not project_config then return nil end

  local adhoc_key = "adhoc:" .. project_key .. ":" .. config_key

  -- Ensure config skeleton exists
  self:materialize_configuration(project_key, config_key)

  -- Check if ad-hoc profile already exists
  ws.cache.profiles = ws.cache.profiles or {}
  if ws.cache.profiles[adhoc_key] then return adhoc_key end

  -- Parse config_key for variant and tool_key
  local variant, tool_key = self._deps.merge.parse_profile_key(config_key)

  -- Resolve tool data
  local tool_data, tool_label, tool_mod_type = nil, nil, nil
  if tool_key then
    for mod_type, tools in pairs(self._tools_by_type) do
      for _, dt in ipairs(tools) do
        if dt.tool_key == tool_key then
          tool_data = dt.tool_data
          tool_label = dt.tool_label
          tool_mod_type = mod_type
          break
        end
      end
      if tool_data then break end
    end
  end

  ws.cache.profiles[adhoc_key] = {
    ad_hoc = true,
    project_key = project_key,
    config_key = config_key,
    tool_key = tool_key,
    tool_data = tool_data,
    tool_label = tool_label,
    tool_mod_type = tool_mod_type,
    projects = {
      [project_key] = { config_key = config_key },
    },
  }

  local ok, err = self._deps.cache.save(ws.root, ws.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  self:remerge()
  return adhoc_key
end

--- Find all profile keys that reference a specific cached config.
--- @param project_key string
--- @param config_key string
--- @return string[] profile_keys
function Core:find_referencing_profiles(project_key, config_key)
  local profiles = self:get_profiles()
  local result = {}
  for pkey, profile in pairs(profiles) do
    -- Only materialized profiles hold actual cache references.
    if profile.materialized then
      for _, pp in ipairs(profile:projects()) do
        if pp.project_key == project_key and pp.config_key == config_key then
          result[#result + 1] = pkey
          break
        end
      end
    end
  end
  table.sort(result)
  return result
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
    local variant, tool_key = self._deps.merge.parse_profile_key(config_key)
    cached_proj.configurations[config_key] = {
      variant = variant,
      tool_key = tool_key,
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
  if result.tool_data then
    cached_config.tool_data = result.tool_data
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

--- Plan a single config deletion from the Projects section.
--- Removes ad-hoc profiles referencing this config; if no full profiles
--- still reference it, the config itself is included for deletion.
--- @param project_key string
--- @param config_key string
--- @return loomworks.DeletionPlan
function Core:plan_config_deletion(project_key, config_key)
  if not self._workspace then
    return { items = {}, project_key = project_key, config_key = config_key, defined_in_config = false }
  end

  local ws = self._workspace
  local refs = self:find_referencing_profiles(project_key, config_key)

  -- Separate ad-hoc and full profile references
  local adhoc_keys = {}
  local has_full_ref = false
  local all_profiles = self:get_profiles()
  for _, pkey in ipairs(refs) do
    local profile = all_profiles[pkey]
    if profile and profile.ad_hoc then
      adhoc_keys[#adhoc_keys + 1] = pkey
    else
      has_full_ref = true
    end
  end

  -- Build the item with appropriate disposition
  local build_dir = nil
  if ws.cache.projects and ws.cache.projects[project_key] then
    local cached = ws.cache.projects[project_key].configurations
    if cached and cached[config_key] then
      build_dir = cached[config_key].build_dir
    end
  end

  local items = {}
  items[#items + 1] = {
    project_key = project_key,
    config_key = config_key,
    build_dir = build_dir,
    disposition = has_full_ref and "keep" or "clean",
  }

  local defined_in_config = ws.config.projects[project_key] ~= nil

  return {
    items = items,
    adhoc_profiles = #adhoc_keys > 0 and adhoc_keys or nil,
    project_key = project_key,
    config_key = config_key,
    defined_in_config = defined_in_config,
  }
end

-- ---------------------------------------------------------------------------
-- Deletion: execute
-- ---------------------------------------------------------------------------

--- Delete build directory for a cached config if it's under .nvim/build/.
--- @param cached_config loomworks.CachedConfig
--- @param safe_prefix string
function Core:_delete_build_dir(cached_config, safe_prefix)
  if not cached_config or not cached_config.build_dir then return end
  local build_dir = self._deps.normalize(cached_config.build_dir)
  if build_dir:sub(1, #safe_prefix) == safe_prefix then
    local ok, err = self._deps.io.rm_rf(build_dir)
    if not ok then
      self._deps.notify("loomworks: failed to remove " .. build_dir .. ": " .. err, vim.log.levels.WARN)
    end
  else
    self._deps.notify("loomworks: refusing to delete build dir outside .nvim/build/: " .. build_dir, vim.log.levels.ERROR)
  end
end

--- Delete cached configurations and their build directories (synchronous part).
--- Removes cache entries entirely.
--- @param items loomworks.DeletionItem[]
function Core:delete_cached_configs(items)
  if not self._workspace then return end

  local ws = self._workspace
  local safe_prefix = self._deps.normalize(ws.root .. "/.nvim/build")

  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      self:_delete_build_dir(cached_proj.configurations[item.config_key], safe_prefix)
      cached_proj.configurations[item.config_key] = nil
      if not next(cached_proj.configurations) then
        ws.cache.projects[item.project_key] = nil
      end
    end
  end
end

--- Execute a deletion plan asynchronously.
--- Items with disposition "clean" have their cache entries removed.
--- Items with disposition "keep" are left untouched (referenced by another profile).
--- Also removes the profile entry from cache if plan.profile_key is set.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: string }
--- @param on_done? function called when deletion is complete
function Core:execute_deletion(plan, opts, on_done)
  opts = opts or {}
  local items = plan.items

  -- Deactivate profile if requested
  if opts.deactivate_profile then
    self:deactivate_profile(opts.deactivate_profile)
  end

  -- Remove profile entry from cache (before async work)
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

  -- Only "clean" items need actual work; "keep" items are left untouched
  local clean_items = {}
  for _, item in ipairs(items) do
    if item.disposition == "clean" then
      clean_items[#clean_items + 1] = item
    end
  end

  if #clean_items == 0 then
    self:remerge()
    if on_done then on_done() end
    return
  end

  -- Mark clean items as deleting
  for _, item in ipairs(clean_items) do
    self._deleting[item.project_key .. "\0" .. item.config_key] = true
  end

  self._deps.events.emit("deletion_started", clean_items)

  -- Find and stop running tasks for clean items
  local running = self:find_running_tasks_for_items(clean_items)
  local task_ids = {}
  for task_id in pairs(running) do
    task_ids[#task_ids + 1] = task_id
  end

  self:stop_tasks_then(task_ids, function()
    self:delete_cached_configs(clean_items)

    -- Save cache once after all mutations
    if self._workspace then
      self._deps.cache.save(self._workspace.root, self._workspace.cache)
    end
    self:remerge()

    -- Unmark deleting state
    for _, item in ipairs(clean_items) do
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

    self._deps.events.emit("deletion_completed", clean_items)

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
--- Removes ad-hoc profiles referencing it, then cleans/resets the config.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function Core:delete_config(project_key, config_key, on_done)
  local plan = self:plan_config_deletion(project_key, config_key)

  -- Remove ad-hoc profiles referencing this config
  if plan.adhoc_profiles and self._workspace then
    local ws = self._workspace
    ws.cache.profiles = ws.cache.profiles or {}
    for _, pkey in ipairs(plan.adhoc_profiles) do
      ws.cache.profiles[pkey] = nil
    end
    if not next(ws.cache.profiles) then
      ws.cache.profiles = nil
    end
    self._deps.cache.save(ws.root, ws.cache)
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
