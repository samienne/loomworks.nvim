--- loomworks/workspace.lua — Pure workspace assembly functions.
--- No singleton state, no I/O. Core owns the workspace instance.

local M = {}

local config_mod = require("loomworks.config")
local user_mod = require("loomworks.user")
local cache_mod = require("loomworks.cache")

--- Resolve and normalize a workspace root path.
--- @param path? string directory path (defaults to cwd)
--- @param normalize? fun(path: string): string path normalizer (injectable)
--- @return string root
function M.resolve_root(path, normalize)
  normalize = normalize or function(p) return vim.fs.normalize(vim.fn.fnamemodify(p, ":p")) end
  local root = normalize(path or vim.fn.getcwd())
  -- Strip trailing slash (normalize may leave one for root dirs)
  return root:gsub("/$", "")
end

--- Return the file paths that a workspace root implies.
--- @param root string absolute workspace root
--- @return { config: string, user: string, cache: string }
function M.paths(root)
  return {
    config = root .. "/loomworks.json",
    user = user_mod.filepath(root),
    cache = cache_mod.filepath(root),
  }
end

--- Assemble a Workspace from raw file contents.
--- Pure function: no file I/O, no side effects.
--- @param root string absolute workspace root
--- @param config_content string|nil raw loomworks.json content
--- @param user_content string|nil raw user.json content
--- @param cache_content string|nil raw cache.json content
--- @return loomworks.Workspace|nil ws, string|nil err
function M.assemble(root, config_content, user_content, cache_content)
  if not config_content then
    return nil, "loomworks.json not found or empty in " .. root
  end

  local config, config_err = config_mod.parse(config_content, root)
  if not config then
    return nil, config_err
  end

  local user_data = user_content and user_mod.parse(user_content) or user_mod.default()
  local cache_data = cache_content and cache_mod.parse(cache_content) or cache_mod.default()

  -- Update cache hash from raw content
  if cache_data._meta then
    cache_data._meta.loomworks_hash = cache_mod.compute_hash(config_content)
  end

  local dir_name = root:match("([^/]+)$") or root

  return {
    root = root,
    name = config.name or dir_name,
    config = config,
    user = user_data,
    cache = cache_data,
  }, nil
end

return M
