--- loomworks/device_source.lua — where the editor reads devices (daemon.md
--- §19.16 "Devices"; step 5n part A). The status page's device row, the
--- `lw.scan_devices` / `lw.get_devices` facade and the session tracker's
--- device prompt list, scan and choose a profile's device only through this
--- module, never from the workspace model.
---
--- One source per runtime mode (as loomworks/test_source.lua and
--- loomworks/lsp_source.lua):
---   * `daemon` mode (step 5n C2): `Devices/1.list` and its `changed`
---     signal, a scan as a `Devices/1.scan` task, the choice as
---     `Profiles/1.set_device` / `clear_device`. Not wired yet: today both
---     modes use the in-process source.
---   * `in-process` mode (transition, until step 6b): the editor's own model —
---     the workspace's device registry (Workspace:devices / scan_devices) and
---     the profile's selection (Profile:device_serial / set_device /
---     clear_device).
---
--- A device is passed around as the model's Device (`serial`, `display_name`,
--- `is_online()`); callers read nothing else from it.

local M = {}

--- The devices the workspace knows (its registry; never probes).
--- @param ws loomworks.Workspace|nil
--- @return loomworks.Device[]
function M.list(ws)
    return ws and ws:devices() or {}
end

--- Discover the devices of every device-capable module, then call `cb` with
--- the registry.
--- @param ws loomworks.Workspace|nil
--- @param cb? fun(devices: loomworks.Device[])
function M.scan(ws, cb)
    if ws then ws:scan_devices(cb) end
end

--- `scan` for a launch target's workspace (the session tracker's prompt).
--- @param target loomworks.LaunchTarget
--- @param cb fun(devices: loomworks.Device[])
function M.scan_for_target(target, cb)
    return target:scan_devices(cb)
end

--- The serial of the device the profile selected, nil when none.
--- @param profile loomworks.Profile
--- @return string|nil
function M.selected_serial(profile)
    return profile:device_serial()
end

--- Select a device for the profile. With `ws`, the page is told
--- (`active_set_changed`).
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param serial string
function M.select(ws, profile, serial)
    profile:set_device(serial)
    if ws then ws._core._deps.events.emit("active_set_changed", ws._active_set) end
end

--- Clear the profile's device selection (see `select` for `ws`).
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
function M.clear(ws, profile)
    profile:clear_device()
    if ws then ws._core._deps.events.emit("active_set_changed", ws._active_set) end
end

return M
