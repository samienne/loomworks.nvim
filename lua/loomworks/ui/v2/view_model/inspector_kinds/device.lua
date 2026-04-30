--- loomworks/ui/v2/view_model/inspector_kinds/device.lua
---
--- Read-only device inspector. Shows serial, display name, provider
--- module, state, properties dict (sorted), and which profiles (if
--- any) currently pin this device.
---
--- ref: { kind = "device", key = serial }

local M = {}

--- @param workspace loomworks.Workspace
--- @param serial string
--- @return loomworks.Device|nil
local function find_device(workspace, serial)
    if not workspace then return nil end
    if workspace.find_device then
        return workspace:find_device(serial)
    end
    for _, d in ipairs(workspace:devices() or {}) do
        if d.serial == serial then return d end
    end
    return nil
end

--- Profiles whose stored device serial matches this one.
--- @param workspace loomworks.Workspace
--- @param serial string
--- @return string[]
local function pinned_by(workspace, serial)
    local out = {}
    for _, p in pairs(workspace._profiles or {}) do
        if p._device_serial and p._device_serial == serial then
            out[#out + 1] = p.key
        end
    end
    table.sort(out)
    return out
end

--- @param props table|nil
--- @return table[]   { key, value }
local function properties_block(props)
    local out = {}
    if type(props) == "table" then
        for k, v in pairs(props) do
            out[#out + 1] = { key = tostring(k), value = tostring(v) }
        end
        table.sort(out, function(a, b) return a.key < b.key end)
    end
    return out
end

--- @param workspace loomworks.Workspace|nil
--- @param ref { kind: "device", key: string }
--- @return table
function M.build(workspace, ref)
    local device = find_device(workspace, ref.key)
    if not device then
        return {
            kind     = "device",
            subject  = ref.key,
            missing  = true,
            hint_bar = {},
        }
    end
    return {
        kind         = "device",
        subject      = device.serial,
        missing      = false,
        display_name = device.display_name,
        provider     = device.provider,
        state        = device.state,
        properties   = properties_block(device.properties),
        pinned_by    = pinned_by(workspace, device.serial),
        hint_bar     = {
            { key = "p",      label = "pin/unpin" },
            { key = "<C-w>w", label = "focus overview" },
        },
    }
end

return M
