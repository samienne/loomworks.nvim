local M = {}

--- @type table<string, table>
local registry = {}

--- Register a module handler for a project type.
--- @param id string
--- @param mod table
function M.register(id, mod)
  registry[id] = mod
end

--- Get the module handler for a project type, or nil.
--- @param id string
--- @return table|nil
function M.get(id)
  if not registry[id] then
    -- Try to load it
    local ok, mod = pcall(require, "loomworks.modules." .. id)
    if ok and type(mod) == "table" and mod.id then
      registry[id] = mod
    end
  end
  return registry[id]
end

--- Get all registered module IDs.
--- @return string[]
function M.list()
  -- Ensure built-in modules are loaded
  for _, id in ipairs({ "cmake", "ets", "typescript" }) do
    M.get(id)
  end
  local ids = {}
  for id in pairs(registry) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

return M
