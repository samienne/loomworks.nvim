local M = {}

local io_mod = require("loomworks.io")

local KNOWN_TYPES = { cmake = true, ets = true, typescript = true }
local NON_TYPE_KEYS = { path = true, depends_on = true }

--- Extract project type from the project definition table.
--- Type is implicit from the inner key: {"cmake": {}} -> type = "cmake"
--- @param project_def table raw JSON project definition
--- @return string|nil type, table|nil type_config, string|nil err
function M._extract_type(project_def)
  local found_type, found_config
  for key, val in pairs(project_def) do
    if not NON_TYPE_KEYS[key] then
      if found_type then
        return nil, nil, "multiple type keys: " .. found_type .. ", " .. key
      end
      found_type = key
      found_config = val
    end
  end
  if not found_type then
    return nil, nil, "no type key found"
  end
  return found_type, found_config or {}, nil
end

--- Validate raw decoded JSON and normalize into a config structure.
--- @param raw table raw decoded JSON
--- @param root string workspace root for resolving paths
--- @return loomworks.Config|nil config, string|nil err
function M.validate(raw, root)
  if type(raw.projects) ~= "table" then
    return nil, "missing or invalid 'projects' field"
  end

  local projects = {}
  for key, def in pairs(raw.projects) do
    if type(def) ~= "table" then
      return nil, "project '" .. key .. "' must be a table"
    end

    local ptype, type_config, type_err = M._extract_type(def)
    if not ptype then
      return nil, "project '" .. key .. "': " .. type_err
    end

    if not KNOWN_TYPES[ptype] then
      vim.notify("loomworks: project '" .. key .. "' has unknown type '" .. ptype .. "'", vim.log.levels.WARN)
    end

    local project_path = def.path or key
    local abs_path = root .. "/" .. project_path
    local stat = (vim.uv or vim.loop).fs_stat(abs_path)
    if not stat then
      vim.notify("loomworks: project '" .. key .. "' directory not found: " .. abs_path, vim.log.levels.WARN)
    end

    projects[key] = {
      path = project_path,
      type = ptype,
      type_config = type_config,
      depends_on = def.depends_on,
    }
  end

  -- Validate configuration_sets references
  if raw.configuration_sets then
    if type(raw.configuration_sets) ~= "table" then
      return nil, "'configuration_sets' must be a table"
    end
    for set_name, mappings in pairs(raw.configuration_sets) do
      if type(mappings) == "table" then
        for proj_name, _ in pairs(mappings) do
          if not projects[proj_name] then
            vim.notify(
              "loomworks: configuration_set '" .. set_name .. "' references unknown project '" .. proj_name .. "'",
              vim.log.levels.WARN
            )
          end
        end
      end
    end
  end

  -- Validate profiles
  local profiles = nil
  if raw.profiles then
    if type(raw.profiles) ~= "table" then
      return nil, "'profiles' must be a table"
    end
    profiles = {}
    for profile_name, profile_def in pairs(raw.profiles) do
      if type(profile_def) ~= "table" then
        return nil, "profile '" .. profile_name .. "' must be a table"
      end
      profiles[profile_name] = {
        configuration_set = profile_def.configuration_set,
        kit_id = profile_def.kit_id,
        -- Legacy support: cmake.kit_id
        cmake = profile_def.cmake,
      }
    end
  end

  return {
    name = raw.name,
    projects = projects,
    configuration_sets = raw.configuration_sets,
    profiles = profiles,
  }, nil
end

--- Parse raw JSON content into a validated Config.
--- @param content string raw JSON content
--- @param root string workspace root for resolving paths
--- @return loomworks.Config|nil config, string|nil err
function M.parse(content, root)
  local ok, raw = pcall(vim.json.decode, content)
  if not ok or type(raw) ~= "table" then
    return nil, "failed to decode JSON"
  end
  return M.validate(raw, root)
end

--- Load and validate loomworks.json from a workspace root.
--- @param root string
--- @return loomworks.Config|nil config, string|nil err, string|nil raw_content
function M.load(root)
  local path = root .. "/loomworks.json"

  -- Read raw content for hashing
  local raw_content = io_mod.read_file(path)

  local raw, read_err = io_mod.read_json(path)
  if not raw then
    return nil, "failed to read loomworks.json: " .. (read_err or "unknown"), nil
  end

  local config, val_err = M.validate(raw, root)
  if not config then
    return nil, path .. ": " .. val_err, nil
  end

  return config, nil, raw_content
end

return M
