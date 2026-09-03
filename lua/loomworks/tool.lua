--- loomworks/tool.lua — Tool domain object.
--- Represents a toolchain (e.g., ninja-gcc-12, msvc-17-2022-enterprise).
--- Owned by Module._tools registry.
--- For non-keyed modules (ets, typescript), a single default Tool with nil key
--- is created — it doesn't participate in name generation.

--- @class loomworks.Tool
--- @field key string|nil opaque identifier (for display + cache matching). nil for default tools.
--- @field data table module-specific data (cmake: generator, compiler_path, etc.)
--- @field label string|nil display label (e.g., "Ninja + GCC 12"). nil for default tools.
--- @field languages string[] languages this tool can provide (e.g.
---        {"c", "c++"} for ninja+clang, {"rust"} for rust-nightly).
---        Defaults to the owning module's static `languages` when the
---        tool's source data doesn't override.
--- @field _module loomworks.Module owning module domain object
--- @field mod_type string module type (from _module.id)
--- @field _removed boolean
local Tool = {}
Tool.__index = Tool

--- Default languages list: take `data.languages` when present
--- (modules can override per-tool), else fall back to the module's
--- static list. Defensive about types — only accept arrays of
--- non-empty strings.
--- @param module loomworks.Module
--- @param data table
--- @return string[]
local function resolve_languages(module, data)
    local source = nil
    if type(data) == "table" and type(data.languages) == "table" then
        source = data.languages
    elseif module and type(module.languages) == "table" then
        source = module.languages
    end
    if not source then return {} end
    local out = {}
    local seen = {}
    for _, lang in ipairs(source) do
        if type(lang) == "string" and lang ~= "" and not seen[lang] then
            seen[lang] = true
            out[#out + 1] = lang
        end
    end
    return out
end

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
    self.languages = resolve_languages(module, data)
    self._removed = false
    return self
end

--- Update tool data in place (preserves table identity).
--- @param data table module-specific tool data
--- @param label string|nil display label
function Tool:_update(data, label)
    self.data = data or self.data
    self.label = label or self.label
    self.languages = resolve_languages(self._module, self.data)
end

--- Does this tool provide the given language?
--- String equality on the language identifier — no normalization
--- (so callers and producers must agree on the canonical string).
--- @param lang string
--- @return boolean
function Tool:provides_language(lang)
    for _, l in ipairs(self.languages) do
        if l == lang then return true end
    end
    return false
end

--- The compiler family of this tool (`clang`, `gcc`, `msvc`), or nil when it
--- carries no C/C++ compiler or the family can't be determined. Derived from
--- the opaque `data` (module-specific) via the shared cpp_compilers logic;
--- clang-cl folds to `clang`. Used to select compiler-specific variable
--- `overrides` (core §1.3.1).
--- @return "clang"|"gcc"|"msvc"|nil
function Tool:compiler_family()
    return require("loomworks.cpp_compilers").family_from_tool_data(self.data)
end

--- Check if this is a keyed tool (participates in name generation).
--- Default tools for non-keyed modules return false.
--- @return boolean
function Tool:is_keyed()
    return self.key ~= nil
end

--- Produce a ToolRef table for serialization.
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
