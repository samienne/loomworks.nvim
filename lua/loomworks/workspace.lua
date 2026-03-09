local M = {}

local config_mod = require("loomworks.config")
local user_mod = require("loomworks.user")
local cache_mod = require("loomworks.cache")
local modules = require("loomworks.modules")

--- @type { root: string, name: string, config: table, user: table, cache: table }|nil
M._active = nil

--- Normalize a path to absolute with forward slashes.
--- @param path string
--- @return string
function M._normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- Initialize workspace from a directory path.
--- Validates that loomworks.json exists and parses it along with user/cache files.
--- @param path? string Directory path (defaults to cwd)
--- @return boolean success, string|nil error
function M.init(path)
  local root = M._normalize(path or vim.fn.getcwd())

  -- Strip trailing slash (normalize may leave one for root dirs)
  root = root:gsub("/$", "")

  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(root .. "/loomworks.json")
  if not stat then
    return false, "loomworks.json not found in " .. root
  end

  local config, config_err, raw_content = config_mod.load(root)
  if not config then
    return false, config_err
  end

  local user_data = user_mod.load(root)
  local cache_data = cache_mod.load(root)

  -- Update cache hash if we have raw content
  if raw_content and cache_data._meta then
    cache_data._meta.loomworks_hash = cache_mod.compute_hash(raw_content)
  end

  -- Validate each project against its module
  for key, project in pairs(config.projects) do
    local mod = modules.get(project.type)
    if mod and mod.validate then
      local abs_path = root .. "/" .. project.path
      local result = mod.validate(abs_path, project.type_config)
      if not result.valid then
        return false, "project '" .. key .. "': " .. table.concat(result.warnings, "; ")
      end
      for _, warning in ipairs(result.warnings) do
        vim.notify("loomworks: project '" .. key .. "': " .. warning, vim.log.levels.WARN)
      end
    end
  end

  M._active = {
    root = root,
    name = config.name or vim.fn.fnamemodify(root, ":t"),
    config = config,
    user = user_data,
    cache = cache_data,
  }

  return true, nil
end

--- Get the active workspace, or nil if none set.
--- @return table|nil
function M.get()
  return M._active
end

--- Get the active workspace root path, or nil.
--- @return string|nil
function M.root()
  return M._active and M._active.root
end

return M
