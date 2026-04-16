--- loomworks/sdk.lua — SDK domain object.
---
--- Represents a resolved platform SDK installation (e.g., OpenHarmony, Android).
--- Created by SDK providers. Modules query SDKs for capabilities via query().
--- The core orchestrates SDK↔module communication without knowing the
--- specifics of either side.

--- @class loomworks.SDK
--- @field key string          identity key (e.g., "ohos", "ohos-5.0.1")
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
--- @return string
function SDK:display_name()
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
