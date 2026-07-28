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

--- Look up a Tool by key. Exact match first, then a coarse-pin
--- fallback: a truncated key matches any registered tool that extends it on a
--- SEGMENT BOUNDARY — either a dotted version (`ninja-clang-19` →
--- `ninja-clang-19.1.5`) or a dashed segment (`msvc-17` →
--- `msvc-17-2022-enterprise`), so a CI matrix can name a toolchain without
--- pinning the patch version or the Visual Studio edition of the runner image.
--- A truncated selector never crosses a boundary (`…-1` never matches `…-18`).
--- Among candidates the highest trailing version wins; ties (e.g. two MSVC
--- editions, which carry no trailing version) break on the lowest key so the
--- choice is deterministic rather than dependent on table order.
--- @param tool_key string|nil tool identifier (nil for default tools)
--- @return loomworks.Tool|nil
function Module:find_tool(tool_key)
    local rk = tool_key or ""
    local exact = self._tools[rk]
    if exact then return exact end
    if rk == "" then return nil end

    local best, best_ver, best_key
    for key, tool in pairs(self._tools) do
        local nxt = key:sub(#rk + 1, #rk + 1)
        if key:sub(1, #rk) == rk and (nxt == "." or nxt == "-") then
            local ver = key:match("(%d[%d%.]*)$") or ""
            if not best
                or version_gt(ver, best_ver)
                or (ver == best_ver and key < best_key) then
                best, best_ver, best_key = tool, ver, key
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
