--- loomworks/sdk.lua — SDK domain object.
---
--- Represents a resolved platform SDK installation (e.g., Android NDK,
--- vendor cross-toolchain).
--- Created by SDK providers. Modules query SDKs for capabilities via query().
--- The core orchestrates SDK↔module communication without knowing the
--- specifics of either side.

--- @class loomworks.SDK
--- @field key string          identity key (e.g., "android-ndk", "android-ndk-27.2.12479018")
--- @field _type string        provider type id
--- @field _version string|nil detected version
--- @field _path string|nil    resolved installation path
--- @field _resolved boolean   whether path is valid
--- @field _intent string      "shared"|"local" (publish model)
--- @field _provider table     provider that created this SDK
--- @field _workspace loomworks.Workspace|nil
--- @field _removed boolean
local SDK = {}
SDK.__index = SDK

--- Create a new SDK.
--- @param opts { key: string, type: string, version?: string, path?: string, resolved: boolean, provider: table, intent?: string }
--- @return loomworks.SDK
function SDK.new(opts)
    local self = setmetatable({}, SDK)
    self.key = opts.key
    self._type = opts.type
    self._version = opts.version
    self._path = opts.path
    self._resolved = opts.resolved or false
    self._intent = opts.intent or "local"
    self._provider = opts.provider
    self._workspace = nil
    self._removed = false
    return self
end

--- Query this SDK for capabilities relevant to a module.
--- Returns opaque data that only the module understands, or nil
--- if this SDK has nothing to offer for the given module.
--- @param module_id string|nil module identifier, nil for all capabilities
--- @return table|nil opaque capability data
function SDK:query(module_id)
    if not self._resolved or not self._provider.query_capabilities then
        return nil
    end
    return self._provider.query_capabilities(self, module_id)
end

--- Check if this SDK is resolved (installation path exists and is valid).
--- @return boolean
function SDK:is_resolved()
    return self._resolved
end

--- Get the human-readable display name.
---
--- Providers may override per-SDK labelling by implementing
--- `display_name_for(sdk) → string` — useful when the static
--- `display_name` field isn't expressive enough (e.g. the C/C++
--- compiler provider wants to surface the detected family in the
--- label: "Clang 19.0.0 (custom)" rather than the static "C/C++
--- Compiler"). When the override is absent, falls back to the
--- generic `<display_name> <version>` shape.
--- @return string
function SDK:display_name()
    if self._resolved and self._provider.display_name_for then
        local ok, name = pcall(self._provider.display_name_for, self)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    local name = self._provider.display_name or self._type
    if self._version then
        name = name .. " " .. self._version
    end
    if not self._resolved then
        name = name .. " (not found)"
    end
    return name
end

--- Get the SDK type (provider id).
--- @return string
function SDK:sdk_type()
    return self._type
end

--- Get the detected version.
--- @return string|nil
function SDK:sdk_version()
    return self._version
end

--- Get the installation path (nil if unresolved).
--- @return string|nil
function SDK:sdk_path()
    return self._path
end

--- Enumerate the SDK's kits as flat `{ platform, arch }` pairs. A
--- kit is a property of the SDK (what targets it can build for),
--- independent of any module — modules then turn a chosen kit into
--- module-specific tool_data via their own `kits_from_sdk`.
---
--- Resolution order:
---   1. Provider's `kits(sdk)` if present — explicit, opaque-free.
---   2. Fallback: derive from `query("cmake").platforms` for
---      providers that haven't migrated. Lets the abstraction land
---      without churning every provider at once.
--- @return { sdk: loomworks.SDK, platform: string, arch: string }[]
function SDK:kits()
    if not self._resolved then return {} end

    if self._provider.kits then
        local ok, result = pcall(self._provider.kits, self)
        if ok and type(result) == "table" then
            local out = {}
            for _, k in ipairs(result) do
                if k.platform and k.arch then
                    out[#out + 1] = { sdk = self, platform = k.platform, arch = k.arch }
                end
            end
            return out
        end
        return {}
    end

    local caps = self:query("cmake")
    if not caps or not caps.platforms then return {} end
    local out = {}
    for _, platform in ipairs(caps.platforms) do
        for _, arch in ipairs(platform.archs or {}) do
            out[#out + 1] = { sdk = self, platform = platform.name, arch = arch }
        end
    end
    return out
end

--- Human-readable label for a kit pair (platform × arch). Includes
--- the SDK version so different SDK installs are visually distinct
--- in a flat picker.
--- @param platform string
--- @param arch string
--- @return string
function SDK:kit_label(platform, arch)
    local v = self._version
    if v and v ~= "" then
        return platform .. " " .. v .. " " .. arch
    end
    return platform .. " " .. arch
end

--- Serialize for user.json persistence.
--- @return table
function SDK:serialize()
    local data = {}
    if self._path then data.path = self._path end
    if self._version then data.version = self._version end
    return data
end

function SDK:__tostring()
    return "SDK(" .. self.key .. ": " .. self:display_name() .. ")"
end

return SDK
