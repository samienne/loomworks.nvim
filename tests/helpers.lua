-- Shared test helpers for loomworks tests.

local M = {}

--- Build a minimal valid loomworks.json content string.
--- Projects field is replaced entirely (not deep-merged) to avoid
--- combining multiple type keys on a single project.
--- @param overrides? table merged into the base config
--- @return string JSON content
function M.make_config_json(overrides)
  local base = {
    projects = {
      App = { cmake = {} },
    },
  }
  if overrides then
    -- Replace projects entirely if provided (deep merge would combine type keys)
    local projects_override = overrides.projects
    if projects_override then
      overrides = vim.tbl_extend("force", overrides, { projects = nil })
      base.projects = projects_override
    end
    base = vim.tbl_deep_extend("force", base, overrides)
  end
  return vim.json.encode(base)
end

--- Build a valid user.json content string.
--- @param overrides? table merged into the base
--- @return string JSON content
function M.make_user_json(overrides)
  local base = { _meta = { version = 1 } }
  if overrides then
    base = vim.tbl_deep_extend("force", base, overrides)
  end
  return vim.json.encode(base)
end

--- Build a valid cache.json content string.
--- @param overrides? table merged into the base
--- @return string JSON content
function M.make_cache_json(overrides)
  local base = {
    _meta = { version = 3, loomworks_hash = "", cached_at = "" },
    projects = {},
  }
  if overrides then
    base = vim.tbl_deep_extend("force", base, overrides)
  end
  return vim.json.encode(base)
end

--- Create a mock Core for testing Profile/Project objects.
--- @param overrides? table
--- @return table mock_core
function M.make_mock_core(overrides)
  local core = {
    _generation = 1,
    get_workspace = function()
      return nil
    end,

    module_has_keyed_tools = function(self, mod_type)
      return mod_type == "cmake"
    end,

    _tools_by_type = {},
    _config_units = {},
    _profiles = {},
    _projects = {},
    _deps = {
      clock = function() return 0 end,
      events = { emit = function() end },
    },
  }

  -- Registry accessors
  core.get_profiles = function(self)
    return self._profiles
  end
  core.get_projects = function(self)
    return self._projects
  end

  -- Add ConfigUnit registry (same logic as Core:get_config_unit)
  local ConfigUnit = require("loomworks.config_unit")
  core.get_config_unit = function(self, project_key, config_key)
    local key = project_key .. "\0" .. config_key
    local unit = self._config_units[key]
    if not unit then
      unit = ConfigUnit.new(self, project_key, config_key)
      self._config_units[key] = unit
    end
    return unit
  end

  if overrides then
    for k, v in pairs(overrides) do
      core[k] = v
    end
  end
  return core
end

--- Build mocked deps for Core.new() that use in-memory file content.
--- @param files? table<string, string> path -> content mapping
--- @param opts? table extra dep overrides
--- @return table deps
function M.make_test_deps(files, opts)
  files = files or {}
  local events_log = {}

  local real_user = require("loomworks.user")
  local real_cache = require("loomworks.cache")
  local real_workspace = require("loomworks.workspace")

  local function file_lookup(path)
    local normalized = path:gsub("\\", "/")
    for k, v in pairs(files) do
      if normalized:match(k:gsub("%-", "%%-"):gsub("%.", "%%.") .. "$") then
        return v
      end
    end
    return nil
  end

  local deps = {
    io = {
      read_file = file_lookup,
      write_json = function() return true end,
      rm_rf = function() return true end,
      rm_rf_async = function(_, cb) cb(true, nil) end,
      ensure_dir = function() return true end,
    },
    read_file_async = function(path, callback) callback(file_lookup(path), nil) end,
    read_files_async = function(paths_list, callback)
      local results = {}
      for _, path in ipairs(paths_list) do results[path] = file_lookup(path) end
      callback(results)
    end,
    workspace = {
      resolve_root = function(path)
        -- Test-friendly: return as-is, no vim path normalization
        return (path or "/test"):gsub("/$", "")
      end,
      paths = real_workspace.paths,
      assemble = real_workspace.assemble,
    },
    user = {
      parse = real_user.parse,
      default = real_user.default,
      filepath = real_user.filepath,
      save = function() return true end,
    },
    cache = {
      parse = real_cache.parse,
      default = real_cache.default,
      filepath = real_cache.filepath,
      compute_hash = real_cache.compute_hash,
      save = function() return true end,
    },
    detect_tools_async = function(config, cache, callback) callback({}) end,
    modules = {
      get = function() return nil end,
    },
    FileTracker = {
      new = function(tracker_opts)
        return {
          watch = function() end,
          unwatch = function() end,
          stop = function() end,
          content = function(_, path) return file_lookup(path) end,
        }
      end,
    },
    notify = function() end,
    schedule = function(fn) fn() end,
    clock = function() return 0 end,
    normalize = function(p) return p:gsub("\\", "/") end,
    events = {
      emit = function(event, data)
        events_log[#events_log + 1] = { event = event, data = data }
      end,
      on = function() end,
      off = function() end,
    },
    _events_log = events_log,
  }

  if opts then
    for k, v in pairs(opts) do
      if k == "_events_log" then
        -- skip
      elseif type(v) == "table" and type(deps[k]) == "table" then
        -- Merge table overrides so partial overrides work (e.g. only override cache.save)
        for vk, vv in pairs(v) do
          deps[k][vk] = vv
        end
      else
        deps[k] = v
      end
    end
  end

  return deps
end

return M
