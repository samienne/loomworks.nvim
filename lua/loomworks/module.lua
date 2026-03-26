--- loomworks/module.lua — Module domain object.
--- Wraps a stateless module function table (cmake.lua, ets.lua, typescript.lua)
--- and owns the Tool registry for that module type.
--- No _workspace back-reference — pure domain object.

local Tool = require("loomworks.tool")

--- @class loomworks.Module
--- @field id string module type identifier (e.g., "cmake", "ets", "typescript")
--- @field impl table raw module function table from require()
--- @field has_keyed_tools boolean whether tools have unique keys
--- @field _tools table<string, loomworks.Tool> tool_key -> Tool ("" for default)
--- @field _removed boolean
local Module = {}
Module.__index = Module

--- Create a new Module.
--- @param id string module type identifier
--- @param impl table raw module function table
--- @return loomworks.Module
function Module.new(id, impl)
    local self = setmetatable({}, Module)
    self.id = id
    self.impl = impl
    self.has_keyed_tools = impl.has_keyed_tools or false
    self._tools = {}
    self._removed = false
    return self
end

--- Update module data in place (preserves table identity).
--- @param impl table raw module function table
function Module:_update(impl)
    self.impl = impl
    self.has_keyed_tools = impl.has_keyed_tools or false
end

--- Look up a Tool by key.
--- @param tool_key string|nil tool identifier (nil for default tools)
--- @return loomworks.Tool|nil
function Module:find_tool(tool_key)
    return self._tools[tool_key or ""]
end

--- Get or create a Tool in this module's registry.
--- @param tool_key string|nil opaque identifier
--- @param tool_data table module-specific tool data
--- @param tool_label string|nil display label
--- @return loomworks.Tool
function Module:get_or_create_tool(tool_key, tool_data, tool_label)
    local rk = tool_key or ""
    local existing = self._tools[rk]
    if existing then
        existing:_update(tool_data, tool_label)
        return existing
    end
    local tool = Tool.new(self.id, tool_key, tool_data, tool_label)
    self._tools[rk] = tool
    return tool
end

--- Get all Tool objects in this module's registry.
--- @return loomworks.Tool[]
function Module:tools()
    local result = {}
    for _, tool in pairs(self._tools) do
        result[#result + 1] = tool
    end
    return result
end

function Module:__tostring()
    return "Module(" .. self.id .. ")"
end

function Module:__eq(other)
    return self.id == other.id
end

return Module
