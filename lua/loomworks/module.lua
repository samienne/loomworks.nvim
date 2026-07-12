--- loomworks/module.lua — Module domain object.
--- Wraps a stateless module function table (cmake.lua, ets.lua, typescript.lua)
--- and owns the Tool registry for that module type.
--- No _workspace back-reference — pure domain object.

local Tool = require("loomworks.tool")

--- @class loomworks.Module
--- @field id string module type identifier (e.g., "cmake", "typescript")
--- @field impl table raw module function table from require()
--- @field has_keyed_tools boolean whether tools have unique keys
--- @field languages string[] languages supported by this module (e.g. {"c++"})
--- @field _tools table<string, loomworks.Tool> tool_key -> Tool ("" for default)
--- @field _removed boolean
local Module = {}
Module.__index = Module

--- Compare two dotted numeric version strings component-wise.
--- Missing trailing components count as 0 (`19.1` == `19.1.0`).
--- @param a string
--- @param b string
--- @return boolean a_gt_b true when a > b
local function version_gt(a, b)
    local ga, gb = a:gmatch("%d+"), b:gmatch("%d+")
    while true do
        local sa, sb = ga(), gb()
        if sa == nil and sb == nil then return false end
        local na, nb = tonumber(sa) or 0, tonumber(sb) or 0
        if na ~= nb then return na > nb end
    end
end

--- Create a new Module.
--- @param id string module type identifier
--- @param impl table raw module function table
--- @return loomworks.Module
function Module.new(id, impl)
    local self = setmetatable({}, Module)
    self.id = id
    self.impl = impl
    self.has_keyed_tools = impl.has_keyed_tools or false
    self.languages = impl.languages or {}
    self._tools = {}
    self._removed = false
    return self
end

--- Update module data in place (preserves table identity).
--- @param impl table raw module function table
function Module:_update(impl)
    self.impl = impl
    self.has_keyed_tools = impl.has_keyed_tools or false
    self.languages = impl.languages or {}
end

--- Get the primary language for this module (first in languages list).
--- @return string|nil
function Module:primary_language()
    return self.languages[1]
end

--- Look up a Tool by key (spec §1.5.2). Exact match first, then a
--- dotted-version prefix fallback: a coarse pin like `ninja-clang-19`
--- matches any registered tool whose version extends it on a component
--- boundary (`ninja-clang-19.1.5`). Fully-specified keys only exact-match
--- (they never relax). Highest matching version wins.
--- @param tool_key string|nil tool identifier (nil for default tools)
--- @return loomworks.Tool|nil
function Module:find_tool(tool_key)
    local rk = tool_key or ""
    local exact = self._tools[rk]
    if exact then return exact end
    if rk == "" then return nil end

    local prefix = rk .. "."
    local best, best_ver
    for key, tool in pairs(self._tools) do
        if key:sub(1, #prefix) == prefix then
            local ver = key:match("(%d[%d%.]*)$") or ""
            if not best or version_gt(ver, best_ver) then
                best, best_ver = tool, ver
            end
        end
    end
    return best
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
    local tool = Tool.new(self, tool_key, tool_data, tool_label)
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
