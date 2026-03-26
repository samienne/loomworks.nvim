--- loomworks/tool.lua — Tool domain object.
--- Represents a toolchain (e.g., ninja-gcc-12, msvc-17-2022-enterprise).
--- Owned by Module._tools registry.
--- For non-keyed modules (ets, typescript), a single default Tool with nil key
--- is created — it doesn't participate in name generation.

--- @class loomworks.Tool
--- @field key string|nil opaque identifier (for display + cache matching). nil for default tools.
--- @field data table module-specific data (cmake: generator, compiler_path, etc.)
--- @field label string|nil display label (e.g., "Ninja + GCC 12"). nil for default tools.
--- @field _module loomworks.Module owning module domain object
--- @field mod_type string module type (computed from _module.id, backward compat)
--- @field _removed boolean
local Tool = {}
Tool.__index = Tool

--- Create a new Tool.
--- @param module loomworks.Module owning module domain object
--- @param key string|nil opaque identifier
--- @param data table module-specific tool data
--- @param label string|nil display label
--- @return loomworks.Tool
function Tool.new(module, key, data, label)
    local self = setmetatable({}, Tool)
    self._module = module
    self.mod_type = module.id
    self.key = key
    self.data = data or {}
    self.label = label
    self._removed = false
    return self
end

--- Update tool data in place (preserves table identity).
--- @param data table module-specific tool data
--- @param label string|nil display label
function Tool:_update(data, label)
    self.data = data or self.data
    self.label = label or self.label
end

--- Check if this is a keyed tool (participates in name generation).
--- Default tools for non-keyed modules return false.
--- @return boolean
function Tool:is_keyed()
    return self.key ~= nil
end

--- Produce a ToolRef table for serialization/legacy compatibility.
--- @return loomworks.ToolRef
function Tool:to_ref()
    return {
        key = self.key,
        data = self.data,
        label = self.label,
        mod_type = self._module.id,
    }
end

function Tool:__tostring()
    if self.key then
        return "Tool(" .. self._module.id .. ":" .. self.key .. ")"
    end
    return "Tool(" .. self._module.id .. ":default)"
end

function Tool:__eq(other)
    return self._module == other._module and self.key == other.key
end

return Tool
