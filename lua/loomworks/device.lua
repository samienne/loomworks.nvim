--- loomworks/device.lua — Device: physical or emulated deployment target.
--- Represents a connected device discovered via a module's list_devices().
--- Runtime-only — not persisted to cache. Profile stores the selected
--- device serial in user.json.

--- @class loomworks.Device
--- @field serial string unique device identifier (e.g., hdc serial)
--- @field display_name string human-readable label (model name or serial)
--- @field provider string module ID that owns this device type (e.g., "harmony")
--- @field state "online"|"offline"
--- @field properties table opaque module-specific data (model, OS version, etc.)
--- @field _removed boolean
local Device = {}
Device.__index = Device

--- Create a new Device.
--- @param data { serial: string, display_name: string, provider: string, state?: string, properties?: table }
--- @return loomworks.Device
function Device.new(data)
    local self = setmetatable({}, Device)
    self.serial = data.serial
    self.display_name = data.display_name or data.serial
    self.provider = data.provider
    self.state = data.state or "online"
    self.properties = data.properties or {}
    self._removed = false
    return self
end

--- Update device in place (identity-preserving).
--- @param data { display_name?: string, state?: string, properties?: table }
function Device:_update(data)
    if data.display_name then self.display_name = data.display_name end
    if data.state then self.state = data.state end
    if data.properties then self.properties = data.properties end
    self._removed = false
end

--- Check if the device is currently online.
--- @return boolean
function Device:is_online()
    return self.state == "online"
end

function Device:__tostring()
    return "Device(" .. self.serial .. ": " .. self.display_name .. ")"
end

return Device
