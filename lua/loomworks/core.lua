--- loomworks/core.lua — All stateful business logic.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.

--- @class loomworks.Core
--- @field _deps table injected dependencies
--- @field _workspace loomworks.Workspace|nil
--- @field _active_set loomworks.ActiveSet|nil
--- @field _config_units table<string, loomworks.ConfigUnit> "project\0config" -> unit
--- @field _delete_waiters function[]
--- @field _generation number incremented on every remerge
--- @field _tracker loomworks.FileTracker|nil
--- @field _operations table<string, loomworks.Operation> profile_key -> active or completed operation
--- @field _tools_by_type table<string, loomworks.DetectedTool[]> tools per module type
--- @field _setup_error { root: string, message: string }|nil set when setup fails
local Core = {}
Core.__index = Core

local Profile = require("loomworks.profile").Profile
local Project = require("loomworks.project")
local ConfigUnit = require("loomworks.config_unit")

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
  self._operations = {}
  self._delete_waiters = {}
  self._generation = 0
  self._tracker = nil
  self._tools_by_type = {}
  self._config_units = {}
  self._profiles = {}
  self._projects = {}
  self._setup_error = nil
  return self
end

--- Get or create a ConfigUnit for a (project_key, config_key) pair.
--- Returns the same instance for the same pair (registry/flyweight pattern).
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function Core:get_config_unit(project_key, config_key)
  local key = project_key .. "\0" .. config_key
  local unit = self._config_units[key]
  if not unit then
    unit = ConfigUnit.new(self, project_key, config_key)
    self._config_units[key] = unit
  end
  return unit
end

-- ---------------------------------------------------------------------------
-- Cache helpers
-- ---------------------------------------------------------------------------

--- Save the cache file with standard error handling.
--- @return boolean ok
function Core:_save_cache()
  if not self._workspace then return false end
  local ok, err = self._deps.cache.save(self._workspace.root, self._workspace.cache)
  if not ok then
    self._deps.notify("loomworks: failed to save cache: " .. (err or "unknown"), vim.log.levels.ERROR)
  end
  return ok
end

--- Ensure a project entry exists in the cache. Returns the cached project table.
--- @param project_key string
--- @return table cached_project
function Core:_ensure_cached_project(project_key)
  local ws = self._workspace
  ws.cache.projects = ws.cache.projects or {}
  if not ws.cache.projects[project_key] then
    local project_config = ws.config.projects[project_key]
    ws.cache.projects[project_key] = {
      type = project_config and project_config.type or "unknown",
      path = project_config and (project_config.path or project_key) or project_key,
      configurations = {},
    }
  end
  local cached_proj = ws.cache.projects[project_key]
  cached_proj.configurations = cached_proj.configurations or {}
  return cached_proj
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
        self:_migrate_set_names()
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
  self._setup_error = nil

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

  -- Refuse to load when cache has incompatible version
  if ws.cache_version_mismatch then
    local msg = "Cache version mismatch (expected v3). Press <C-n> to reset."
    self._setup_error = { root = root, message = msg }
    self._deps.notify("loomworks: " .. msg, vim.log.levels.ERROR)
    return false
  end

  -- Validate projects
  local ok, val_err = self:_validate_projects(ws.config, ws.root)
  if not ok then
    self._deps.notify("loomworks: " .. val_err, vim.log.levels.ERROR)
    return false
  end

  self._workspace = ws
  self._config_units = {}
  self._profiles = {}
  self._projects = {}
  self:_scan_tools()
  self:_migrate_set_names()
  self:_cleanup_orphaned_skeletons()
  self:remerge()
  self._deps.events.emit("workspace_changed", ws)

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

--- Re-merge workspace state, sync object registries, and emit events.
function Core:remerge()
  if not self._workspace then return end
  local active_set, all_profile_defs = self._deps.merge.merge(
    self._workspace, self._tools_by_type)
  self._active_set = active_set
  self._generation = self._generation + 1
  self:_sync_profiles(all_profile_defs)
  self:_sync_projects()
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

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function Core:get_setup_error()
  return self._setup_error
end

-- ---------------------------------------------------------------------------
-- Object registries
-- ---------------------------------------------------------------------------

--- Resolve mappings for a profile definition.
--- Set-based profiles derive mappings from configuration_sets (reactive).
--- Pinned profiles use their stored mappings directly.
--- Falls back to cached profile project data when the configuration_set
--- no longer exists in config (orphaned profile).
--- @param data loomworks.ProfileDef
--- @param config_sets table|nil
--- @return table<string, string>|nil mappings
--- @return boolean orphaned true if mappings came from cache fallback
local function resolve_profile_mappings(data, config_sets)
  -- Set-based profiles: derive from config_sets (reactive)
  if data.configuration_set and config_sets and config_sets[data.configuration_set] then
    return config_sets[data.configuration_set], false
  end

  -- Pinned profiles or set-based with stored mappings
  if data.mappings then
    -- If this has a configuration_set that's no longer in config, it's orphaned
    local orphaned = data.configuration_set ~= nil
    return data.mappings, orphaned
  end

  -- Fallback: derive mappings from cached profile projects
  if data._cached_projects then
    local merge = require("loomworks.merge")
    local mappings = {}
    for project_key, proj_ref in pairs(data._cached_projects) do
      if proj_ref.config_key then
        local variant = merge.parse_profile_key(proj_ref.config_key)
        mappings[project_key] = variant
      end
    end
    if next(mappings) then return mappings, data.configuration_set ~= nil end
  end

  return nil, false
end

--- Sync the profiles registry with current merge data.
--- Creates new Profile objects, updates existing ones in place, removes stale ones.
--- @param all_defs table<string, loomworks.ProfileDef> profile definitions from merge
function Core:_sync_profiles(all_defs)
  local ws = self._workspace
  if not ws then return end

  local config_sets = ws.config.configuration_sets

  -- Mark removed profiles
  for key, profile in pairs(self._profiles) do
    if not all_defs[key] then
      profile._removed = true
      self._profiles[key] = nil
    end
  end

  -- Create or update
  for key, data in pairs(all_defs) do
    local mappings, orphaned_set = resolve_profile_mappings(data, config_sets)
    local profile_data = {
      configuration_set = data.configuration_set,
      tool_key = data.tool_key,
      tool_data = data.tool_data,
      tool_label = data.tool_label,
      tool_mod_type = data.tool_mod_type,
      explicit = data.explicit or false,
      mappings = mappings,
      orphaned_set = orphaned_set,
    }

    local existing = self._profiles[key]
    if existing then
      existing:_update(profile_data)
    else
      self._profiles[key] = Profile.new(self, key, profile_data)
    end
  end
end

--- Sync the projects registry with current active set data.
--- Creates new Project objects, updates existing ones in place, removes stale ones.
function Core:_sync_projects()
  if not self._active_set then return end

  local new_data = self._active_set.projects

  -- Mark removed projects
  for key, project in pairs(self._projects) do
    if not new_data[key] then
      project._removed = true
      self._projects[key] = nil
    end
  end

  -- Create or update
  for key, data in pairs(new_data) do
    local existing = self._projects[key]
    if existing then
      existing:_update(data)
    else
      self._projects[key] = Project.new(self, key, data)
    end
  end
end

--- Get a Profile object by key.
--- @param key string profile key
--- @return loomworks.Profile|nil
function Core:get_profile(key)
  return self._profiles[key]
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function Core:get_profiles()
  return self._profiles
end

--- Get tool entries for the configuration sets UI.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function Core:get_tool_entries()
  if not self._workspace then return {} end
  return self._deps.merge.get_tool_entries(
    self._workspace.config, self._workspace.cache, self._tools_by_type)
end

--- Get a Project object by key (from the active set).
--- @param key string project key
--- @return loomworks.Project|nil
function Core:get_project(key)
  return self._projects[key]
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function Core:get_projects()
  return self._projects
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

  -- Ensure the profile exists — materialize if it can be resolved from config
  if not self._profiles[profile_key] then
    -- Try to resolve and materialize from config_sets + detected tools
    local def = self._deps.merge.resolve_profile_def(
      self._workspace.config, self._tools_by_type, profile_key)
    if not def then
      self._deps.notify("loomworks: profile '" .. profile_key .. "' not found", vim.log.levels.ERROR)
      return
    end
    self:materialize_profile(profile_key)
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

  -- Already cached?
  if ws.cache.profiles and ws.cache.profiles[profile_key] then return end

  -- Resolve from config_sets + detected tools
  local profile_def = self._deps.merge.resolve_profile_def(
    ws.config, self._tools_by_type, profile_key)
  if not profile_def then return end

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
    local cached_proj = self:_ensure_cached_project(project_key)
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

  self:_save_cache()
  self:remerge()
end

--- Migrate cached profile names when configuration_sets are renamed (case change).
--- Matches cached profiles to config sets case-insensitively and updates the cache.
function Core:_migrate_set_names()
  local ws = self._workspace
  if not ws or not ws.cache.profiles or not ws.config.configuration_sets then return end

  -- Build case-insensitive lookup: lowercase -> actual name in config
  local config_sets_lower = {}
  for name in pairs(ws.config.configuration_sets) do
    config_sets_lower[name:lower()] = name
  end

  local renames = {} -- old_key -> { new_key, new_set }
  for profile_key, cached_profile in pairs(ws.cache.profiles) do
    local old_set = cached_profile.configuration_set
    if not old_set then goto continue end -- pinned profiles have no set

    -- Already matches exactly?
    if ws.config.configuration_sets[old_set] then goto continue end

    -- Try case-insensitive match
    local new_set = config_sets_lower[old_set:lower()]
    if new_set then
      local _, tool_key = self._deps.merge.parse_profile_key(profile_key)
      local new_key = self._deps.merge.profile_key(new_set, tool_key)
      renames[profile_key] = { new_key = new_key, new_set = new_set }
    end

    ::continue::
  end

  if not next(renames) then return end

  for old_key, info in pairs(renames) do
    local profile_data = ws.cache.profiles[old_key]
    profile_data.configuration_set = info.new_set
    ws.cache.profiles[info.new_key] = profile_data
    ws.cache.profiles[old_key] = nil

    -- Update active_profile if it was the old key
    if ws.user.active_profile == old_key then
      ws.user.active_profile = info.new_key
      self._deps.user.save(ws.root, ws.user)
    end
  end

  self:_save_cache()
end

--- Build a set of all (project_key, config_key) pairs referenced by profiles.
--- @return table<string, boolean> referenced set keyed by "project_key\0config_key"
function Core:_build_referenced_set()
  local ws = self._workspace
  local referenced = {}
  if ws and ws.cache.profiles then
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
  return referenced
end

--- Clean up unreferenced unconfigured skeletons on init.
--- Configs with no state and no profile reference are silently dropped.
--- Configs with state are left as orphaned (shown in UI).
function Core:_cleanup_orphaned_skeletons()
  local ws = self._workspace
  if not ws or not ws.cache.projects then return end

  local referenced = self:_build_referenced_set()

  local changed = false

  for project_key, cached_proj in pairs(ws.cache.projects) do
    if cached_proj.configurations then
      local to_drop = {}
      for config_key, cached_config in pairs(cached_proj.configurations) do
        if not referenced[project_key .. "\0" .. config_key] then
          local state = cached_config.state
          if not state or state == "unconfigured" then
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

  if ws.cache.projects and not next(ws.cache.projects) then
    ws.cache.projects = nil
  end

  if changed then
    self:_save_cache()
  end
end

--- Get orphaned cached configs: configs with state not referenced by any profile.
--- @return loomworks.OrphanedConfig[]
function Core:get_orphaned_configs()
  local ws = self._workspace
  if not ws or not ws.cache.projects then return {} end

  local referenced = self:_build_referenced_set()

  local result = {}
  for project_key, cached_proj in pairs(ws.cache.projects) do
    if cached_proj.configurations then
      for config_key, cached_config in pairs(cached_proj.configurations) do
        local state = cached_config.state
        if state and state ~= "unconfigured"
            and not referenced[project_key .. "\0" .. config_key] then
          result[#result + 1] = {
            project_key = project_key,
            config_key = config_key,
            cached = cached_config,
          }
        end
      end
    end
  end

  -- Sort for deterministic UI order
  table.sort(result, function(a, b)
    if a.project_key ~= b.project_key then return a.project_key < b.project_key end
    return a.config_key < b.config_key
  end)

  return result
end

--- Delete an orphaned config: remove cache entry + build directory.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function Core:delete_orphaned_config(project_key, config_key, on_done)
  local items = {
    {
      project_key = project_key,
      config_key = config_key,
      disposition = "clean",
      build_dir = self:_cached_build_dir(project_key, config_key),
    },
  }
  self:_run_deletion(items, function(effective_items)
    self:delete_cached_configs(effective_items)
  end, on_done)
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
  local dt = tool_key
      and self._deps.merge.resolve_detected_tool(self._tools_by_type, tool_key)
      or nil

  -- Ensure cache structure exists
  local cached_proj = self:_ensure_cached_project(project_key)
  if not cached_proj.configurations[config_key] then
    cached_proj.configurations[config_key] = {
      variant = variant,
      tool_key = tool_key,
      tool_data = dt and dt.tool_data or nil,
    }

    self:_save_cache()
    self:remerge()
  end
end

--- Materialize a pinned profile: a lightweight single-config pin.
--- Creates the config skeleton and a pinned profile entry in cache.
--- Returns the pinned profile key.
--- @param project_key string
--- @param config_key string
--- @return string|nil pinned_key
function Core:materialize_pinned(project_key, config_key)
  if not self._workspace then return nil end

  local ws = self._workspace
  local project_config = ws.config.projects[project_key]
  if not project_config then return nil end

  local ak = self._deps.merge.pinned_key(project_key, config_key)

  -- Ensure config skeleton exists
  self:materialize_configuration(project_key, config_key)

  -- Check if pinned profile already exists
  ws.cache.profiles = ws.cache.profiles or {}
  if ws.cache.profiles[ak] then return ak end

  -- Parse config_key for variant and tool_key
  local variant, tool_key = self._deps.merge.parse_profile_key(config_key)

  -- Resolve tool data
  local tool_data, tool_label, tool_mod_type = nil, nil, nil
  if tool_key then
    local det, mt = self._deps.merge.resolve_detected_tool(
      self._tools_by_type, tool_key)
    if det then
      tool_data = det.tool_data
      tool_label = det.tool_label
      tool_mod_type = mt
    end
  end

  ws.cache.profiles[ak] = {
    mappings = { [project_key] = variant },
    tool_key = tool_key,
    tool_data = tool_data,
    tool_label = tool_label,
    tool_mod_type = tool_mod_type,
    projects = {
      [project_key] = { config_key = config_key },
    },
  }

  self:_save_cache()
  self:remerge()
  return ak
end

--- Find all profile keys that reference a specific cached config.
--- @param project_key string
--- @param config_key string
--- @return string[] profile_keys
function Core:find_referencing_profiles(project_key, config_key)
  local profiles = self:get_profiles()
  local result = {}
  for pkey, profile in pairs(profiles) do
    for _, pp in ipairs(profile:projects()) do
      if pp.project_key == project_key and pp.config_key == config_key then
        result[#result + 1] = pkey
        break
      end
    end
  end
  table.sort(result)
  return result
end

-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Check if any task is running for a given project (any config).
--- @param project_key string
--- @return string|nil action
function Core:get_project_running_action(project_key)
  for _, unit in pairs(self._config_units) do
    if unit.project_key == project_key and unit:is_running() then
      return unit:running_action()
    end
  end
  return nil
end

--- Check if any tasks are currently running.
--- @return boolean
function Core:has_running_tasks()
  for _, unit in pairs(self._config_units) do
    if unit:is_running() then return true end
  end
  return false
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
  for _, item in ipairs(items) do
    local unit = self:get_config_unit(item.project_key, item.config_key)
    if unit._task_id then
      matches[unit._task_id] = {
        project_key = unit.project_key,
        action = unit:running_action(),
        configuration_key = unit.config_key,
      }
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
  local cached_proj = self:_ensure_cached_project(project_key)

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
      -- Don't downgrade from built to configured
      if cached_config.state ~= "built" then
        cached_config.state = "configured"
      end
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

  -- Parse file-api targets after successful configure
  if action == "configure" and success and result.build_dir then
    local proj_type = cached_proj.type
        or (ws.config.projects[project_key] and ws.config.projects[project_key].type)
    if proj_type then
      local mod = self._deps.modules.get(proj_type)
      if mod and mod.parse_file_api then
        local variant = self._deps.merge.parse_profile_key(config_key)
        local targets = mod.parse_file_api(result.build_dir, variant)
        if targets then
          cached_config.cmake = cached_config.cmake or {}
          cached_config.cmake.targets = targets
        end
      end
    end
  end

  self:_save_cache()
  self:remerge()
  self._deps.events.emit("task_result", result)
end

-- ---------------------------------------------------------------------------
-- Deletion: query & status
-- ---------------------------------------------------------------------------

--- Check if any items are currently being deleted.
--- @return boolean
function Core:has_pending_deletions()
  for _, unit in pairs(self._config_units) do
    if unit:is_deleting() then return true end
  end
  return false
end

--- Wait for all pending deletions to finish, then call fn.
--- If nothing is pending, calls fn immediately.
--- @param fn function
function Core:after_deletions(fn)
  if not self:has_pending_deletions() then
    fn()
    return
  end
  self._delete_waiters[#self._delete_waiters + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Deletion: plan (config-level)
-- ---------------------------------------------------------------------------

--- Plan a single config deletion from the Projects section.
--- If any profile references it, disposition = "reset" (clear state, keep
--- skeleton so the profile sees "unconfigured"). Otherwise "clean" (remove).
--- Profiles are never removed — only explicit profile deletion does that.
--- @param project_key string
--- @param config_key string
--- @return loomworks.DeletionPlan
function Core:plan_config_deletion(project_key, config_key)
  if not self._workspace then
    return { items = {}, project_key = project_key, config_key = config_key, defined_in_config = false }
  end

  local ws = self._workspace
  local refs = self:find_referencing_profiles(project_key, config_key)
  local has_ref = #refs > 0

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
    disposition = has_ref and "reset" or "clean",
  }

  local defined_in_config = ws.config.projects[project_key] ~= nil

  return {
    items = items,
    project_key = project_key,
    config_key = config_key,
    defined_in_config = defined_in_config,
  }
end

-- ---------------------------------------------------------------------------
-- Deletion: execute
-- ---------------------------------------------------------------------------

--- Validate a build directory path is safe to delete (under workspace root).
--- Checks that the path is strictly under the workspace root using a
--- directory boundary check (trailing "/") to prevent prefix collisions
--- (e.g., "/root" must not match "/roots/...").
--- @param build_dir string normalized path
--- @param safe_prefix string normalized workspace root
--- @return boolean safe
function Core:_validate_build_dir(build_dir, safe_prefix)
  local is_under = build_dir == safe_prefix
    or build_dir:sub(1, #safe_prefix + 1) == safe_prefix .. "/"
  if not is_under then
    self._deps.notify("loomworks: refusing to delete build dir outside workspace: " .. build_dir, vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Delete multiple build directories asynchronously via subprocesses (parallel).
--- @param dirs string[] list of normalized directory paths
--- @param callback fun(results: {dir: string, ok: boolean, err: string|nil}[])
function Core:_delete_build_dirs_async(dirs, callback)
  if #dirs == 0 then
    callback({})
    return
  end

  local results = {}
  local remaining = #dirs
  for _, dir in ipairs(dirs) do
    self._deps.io.rm_rf_async(dir, function(ok, err)
      results[#results + 1] = { dir = dir, ok = ok, err = err }
      remaining = remaining - 1
      if remaining == 0 then
        callback(results)
      end
    end)
  end
end

--- Remove cache entries entirely (cache-only, no filesystem operations).
--- @param items loomworks.DeletionItem[]
function Core:delete_cached_configs(items)
  if not self._workspace then return end

  local ws = self._workspace
  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      cached_proj.configurations[item.config_key] = nil
      if not next(cached_proj.configurations) then
        ws.cache.projects[item.project_key] = nil
      end
    end
  end
end

--- Reset cached configurations: clear state to unconfigured (cache-only, no filesystem).
--- Keeps the cache entry skeleton (variant, tool_key, tool_data) intact.
--- @param items loomworks.DeletionItem[]
function Core:reset_cached_configs(items)
  if not self._workspace then return end

  local ws = self._workspace
  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      local cached_config = cached_proj.configurations[item.config_key]
      if cached_config then
        cached_config.state = nil
        cached_config.build_dir = nil
        cached_config.last_configured = nil
        cached_config.last_built = nil
        cached_config.cmake = nil
      end
    end
  end
end

--- Set cache state to "unknown" for items that have build directories.
--- @param items loomworks.DeletionItem[]
function Core:_mark_cache_unknown(items)
  if not self._workspace then return end

  local ws = self._workspace
  for _, item in ipairs(items) do
    local cached_proj = ws.cache.projects and ws.cache.projects[item.project_key]
    if cached_proj and cached_proj.configurations then
      local cached_config = cached_proj.configurations[item.config_key]
      if cached_config and cached_config.build_dir then
        cached_config.state = "unknown"
      end
    end
  end
end

--- Common async deletion workflow: mark items as deleting, stop running tasks,
--- delete build dirs via async subprocess, then apply cache mutations.
--- Crash-safe: cache is set to "unknown" before async deletion starts.
--- @param items table[] list of { project_key, config_key, ... }
--- @param work_fn function called after build dirs are successfully deleted (cache mutations)
--- @param on_done? function called when complete
function Core:_run_deletion(items, work_fn, on_done)
  if #items == 0 then
    if on_done then on_done() end
    return
  end

  for _, item in ipairs(items) do
    self:get_config_unit(item.project_key, item.config_key):mark_deleting(true)
  end
  self._deps.events.emit("deletion_started", items)

  local running = self:find_running_tasks_for_items(items)
  local task_ids = {}
  for task_id in pairs(running) do
    task_ids[#task_ids + 1] = task_id
  end

  self:stop_tasks_then(task_ids, function()
    -- Crash-safe: mark cache as "unknown" before starting async deletion
    self:_mark_cache_unknown(items)
    self:_save_cache()

    -- Collect build directories to delete
    local ws = self._workspace
    if not ws then
      if on_done then on_done() end
      return
    end

    local safe_prefix = self._deps.normalize(ws.root)
    local dirs = {}
    for _, item in ipairs(items) do
      if item.build_dir then
        local normalized = self._deps.normalize(item.build_dir)
        if self:_validate_build_dir(normalized, safe_prefix) then
          dirs[#dirs + 1] = normalized
        end
      end
    end

    -- Delete build directories asynchronously
    self:_delete_build_dirs_async(dirs, function(results)
      -- Check for failures
      local errors = {}
      for _, r in ipairs(results) do
        if not r.ok then
          errors[#errors + 1] = r
        end
      end

      if #errors > 0 then
        -- Failure: cache already has "unknown" state, notify user
        for _, e in ipairs(errors) do
          self._deps.notify("loomworks: failed to delete " .. e.dir .. ": " .. (e.err or "unknown"), vim.log.levels.ERROR)
        end

        -- Discard any queued actions on failed items
        for _, item in ipairs(items) do
          local unit = self:get_config_unit(item.project_key, item.config_key)
          unit:mark_deleting(false)
        end

        self:_save_cache()
        self:remerge()

        if not self:has_pending_deletions() then
          local waiters = self._delete_waiters
          self._delete_waiters = {}
          for _, fn in ipairs(waiters) do fn() end
        end

        self._deps.events.emit("deletion_failed", { items = items, errors = errors })
        if on_done then on_done() end
        return
      end

      -- Success: check for queued actions before applying cache mutations
      local queued = {}
      for _, item in ipairs(items) do
        local unit = self:get_config_unit(item.project_key, item.config_key)
        local action = unit:pop_queued_action()
        if action then
          queued[#queued + 1] = { item = item, action = action }
        end
      end

      -- Apply cache mutations for items without queued actions
      if #queued > 0 then
        -- Items with queued actions: reset to unconfigured (keep cache entry)
        local queued_items = {}
        local normal_items = {}
        local queued_set = {}
        for _, q in ipairs(queued) do
          local key = q.item.project_key .. "\0" .. q.item.config_key
          queued_set[key] = true
          queued_items[#queued_items + 1] = q.item
        end
        for _, item in ipairs(items) do
          local key = item.project_key .. "\0" .. item.config_key
          if not queued_set[key] then
            normal_items[#normal_items + 1] = item
          end
        end
        -- Reset queued items to unconfigured
        self:reset_cached_configs(queued_items)
        -- Apply normal work_fn only to non-queued items
        -- For simplicity, run work_fn for all then restore queued ones
        -- Actually, the work_fn operates on all items - we need to exclude queued ones
        -- Split: run work_fn replacement logic manually
        -- The work_fn is either delete_cached_configs or reset_cached_configs
        -- We handle this by not calling work_fn for queued items
        if #normal_items > 0 then
          -- Re-scope work_fn: this is called with the original items, so we need
          -- to apply the mutation to normal items only. The caller passes work_fn
          -- that operates on the full item list. Instead, we apply mutations directly.
          work_fn(normal_items)
        end
      else
        work_fn(items)
      end

      self:_save_cache()
      self:remerge()

      for _, item in ipairs(items) do
        self:get_config_unit(item.project_key, item.config_key):mark_deleting(false)
      end
      if not self:has_pending_deletions() then
        local waiters = self._delete_waiters
        self._delete_waiters = {}
        for _, fn in ipairs(waiters) do fn() end
      end

      self._deps.events.emit("deletion_completed", items)

      -- Execute queued actions after everything is settled
      for _, q in ipairs(queued) do
        self._deps.schedule(function()
          local overseer = require("loomworks.overseer")
          overseer.run_config_action(q.item.project_key, q.item.config_key, q.action)
        end)
      end

      if on_done then on_done() end
    end)
  end)
end

--- Execute a deletion plan asynchronously.
--- Items with disposition "clean" have their cache entries removed.
--- Items with disposition "reset" have their state cleared to unconfigured.
--- Items with disposition "keep" are left untouched (referenced by another profile).
--- Also removes the profile entry from cache if plan.profile_key is set.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: string }
--- @param on_done? function called when deletion is complete
function Core:execute_deletion(plan, opts, on_done)
  opts = opts or {}

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
      self:_save_cache()
    end
  end

  -- Split items by disposition
  local actionable = {}
  local clean_items = {}
  local reset_items = {}
  for _, item in ipairs(plan.items) do
    if item.disposition == "clean" then
      actionable[#actionable + 1] = item
      clean_items[#clean_items + 1] = item
    elseif item.disposition == "reset" then
      actionable[#actionable + 1] = item
      reset_items[#reset_items + 1] = item
    end
  end

  if #actionable == 0 then
    self:remerge()
    if on_done then on_done() end
    return
  end

  self:_run_deletion(actionable, function(effective_items)
    -- Split effective items by their original disposition
    local eff_clean = {}
    local eff_reset = {}
    local clean_set = {}
    for _, item in ipairs(clean_items) do
      clean_set[item.project_key .. "\0" .. item.config_key] = true
    end
    for _, item in ipairs(effective_items) do
      local key = item.project_key .. "\0" .. item.config_key
      if clean_set[key] then
        eff_clean[#eff_clean + 1] = item
      else
        eff_reset[#eff_reset + 1] = item
      end
    end
    if #eff_clean > 0 then
      self:delete_cached_configs(eff_clean)
    end
    if #eff_reset > 0 then
      self:reset_cached_configs(eff_reset)
    end
  end, on_done)
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
--- Cleans/resets the config. Profiles are never removed — they stay and
--- show "unconfigured" state.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function Core:delete_config(project_key, config_key, on_done)
  local plan = self:plan_config_deletion(project_key, config_key)
  self:execute_deletion(plan, nil, on_done)
end

-- ---------------------------------------------------------------------------
-- Clean: reset state without touching profiles
-- ---------------------------------------------------------------------------

--- Look up the build_dir for a cached config.
--- @param project_key string
--- @param config_key string
--- @return string|nil
function Core:_cached_build_dir(project_key, config_key)
  if not self._workspace then return nil end
  local ws = self._workspace
  local proj = ws.cache.projects and ws.cache.projects[project_key]
  if not proj or not proj.configurations then return nil end
  local cfg = proj.configurations[config_key]
  return cfg and cfg.build_dir
end

--- Return build options for a project+config by delegating to the module.
--- @param project_key string
--- @param config_key string
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function Core:get_project_options(project_key, config_key)
  local build_dir = self:_cached_build_dir(project_key, config_key)
  if not build_dir then return nil end

  local ws = self._workspace
  if not ws then return nil end
  local proj_cfg = ws.config.projects[project_key]
  if not proj_cfg then return nil end

  local mod = self._deps.modules.get(proj_cfg.type)
  if not mod or not mod.get_options then return nil end

  return mod.get_options(build_dir, proj_cfg.type_config)
end

--- Clean a profile's configs: delete build dirs and reset to unconfigured.
--- Does NOT remove or modify the profile itself.
--- @param profile_key string
--- @param on_done? function
function Core:clean_profile(profile_key, on_done)
  local profile = self:get_profile(profile_key)
  if not profile then
    if on_done then on_done() end
    return
  end

  local items = {}
  for _, pp in ipairs(profile:projects()) do
    items[#items + 1] = {
      project_key = pp.project_key,
      config_key = pp.config_key,
      build_dir = self:_cached_build_dir(pp.project_key, pp.config_key),
    }
  end

  self:_run_deletion(items, function(effective_items)
    self:reset_cached_configs(effective_items)
  end, on_done)
end

--- Clean a single config: delete build dir and reset to unconfigured.
--- Does NOT remove or modify any profile.
--- @param project_key string
--- @param config_key string
--- @param on_done? function
function Core:clean_config(project_key, config_key, on_done)
  if not self._workspace then
    if on_done then on_done() end
    return
  end

  local items = { {
    project_key = project_key,
    config_key = config_key,
    build_dir = self:_cached_build_dir(project_key, config_key),
  } }
  self:_run_deletion(items, function(effective_items)
    self:reset_cached_configs(effective_items)
  end, on_done)
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
