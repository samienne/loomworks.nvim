--- loomworks/device_source.lua — where the editor reads devices (daemon.md
--- §19.16 "Devices"). The status page's device row, the `lw.scan_devices` /
--- `lw.get_devices` facade and the session tracker's device prompt list and
--- scan devices only through this module.
---
--- The source is **only** the workspace daemon: `Devices/1.list` as the
--- observer last read it (re-read on its `changed` signal) and a scan as a
--- `Devices/1.scan` task the editor owns, carrying its environment
--- (loomworks.daemon.editor_ops). Choosing a profile's device is
--- `Profiles/1.set_device` / `clear_device` by ids (the status page's calls).
--- Nothing is listed, probed or written in the editor; while the daemon
--- cannot carry these, they are refused (§19.16 "Availability").
---
--- A device is passed around as a loomworks.DeviceRecord — the shape of
--- `Devices/1.list` (`key` the serial, `label`, `state`, `id`).

local M = {}

--- The devices the workspace knows (the daemon's registry as last read;
--- never probes) — empty while not carried or not read yet (a read is
--- started then).
--- @param _ any unused (the editor holds no model)
--- @return loomworks.DeviceRecord[]
function M.list(_)
    return require("loomworks.daemon.editor_ops").devices(nil) or {}
end

--- Discover the devices of every device-capable module (a `Devices/1.scan`
--- task), then call `cb(list)` with the registry. Its handle is returned (a
--- stop cancels it; `cb` is then not called). Refused (not carried) or
--- failed — its task, or the registry's read after it: notified, then
--- `cb(nil, err)`.
--- @param _ any unused (the editor holds no model)
--- @param cb? fun(devices: loomworks.DeviceRecord[]|nil, err: string|nil)
--- @return loomworks.daemon.Preparation|nil handle the scan sent
function M.scan(_, cb)
    cb = cb or function() end
    local _, handle = require("loomworks.daemon.editor_ops").scan_devices(nil, {
        resolve = function(list) cb(list) end,
        reject = function(err, notified)
            if not notified then
                vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
            end
            cb(nil, tostring(err))
        end,
    })
    return handle
end

return M
