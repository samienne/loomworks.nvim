--- loomworks/device_source.lua — where the editor reads devices (daemon.md
--- §19.16 "Devices"; step 5n parts A and C2). The status page's device row,
--- the `lw.scan_devices` / `lw.get_devices` facade and the session tracker's
--- device prompt list, scan and choose a profile's device only through this
--- module, never from the workspace model.
---
--- One source per runtime mode (as loomworks/test_source.lua and
--- loomworks/lsp_source.lua):
---   * `daemon` mode (step 5n C2): **only** the workspace daemon —
---     `Devices/1.list` as the observer last read it (re-read on its
---     `changed` signal), a scan as a `Devices/1.scan` task the editor owns
---     carrying its environment, the choice as `Profiles/1.set_device` /
---     `clear_device` (loomworks.daemon.editor_ops). Nothing is listed,
---     probed or written in the editor's model; while the daemon cannot carry
---     these, they are refused (§19.16 "Availability"), never run in-process.
---   * `in-process` mode (transition, until step 6b): the editor's own model —
---     the workspace's device registry (Workspace:devices / scan_devices) and
---     the profile's selection (Profile:device_serial / set_device /
---     clear_device).
---
--- A device is passed around as a loomworks.DeviceRecord — the shape of
--- `Devices/1.list` (`key` the serial, `label`, `state`, `id` in `daemon`
--- mode); the in-process source builds it from its model's Device.

local M = {}

--- The daemon side of `ws` in `daemon` mode (its operations then never run
--- in-process), or nil in the `in-process` mode.
--- @param ws loomworks.Workspace|nil
--- @return table|nil editor_ops
local function daemon_ops(ws)
    local ops = require("loomworks.daemon.editor_ops")
    if ops.daemon_of(ws) then return ops end
    return nil
end

--- The in-process model's Device as a record.
--- @param d loomworks.Device
--- @return loomworks.DeviceRecord
local function record(d)
    return { key = d.serial, label = d.display_name or d.serial, state = d.state, provider = d.provider }
end

--- @param devices loomworks.Device[]|nil
--- @return loomworks.DeviceRecord[]
local function records(devices)
    local out = {}
    for i, d in ipairs(devices or {}) do out[i] = record(d) end
    return out
end

--- The devices the workspace knows (its registry; never probes). In
--- `daemon` mode the daemon's registry as last read — empty while not
--- carried or not read yet (a read is started then).
--- @param ws loomworks.Workspace|nil
--- @return loomworks.DeviceRecord[]
function M.list(ws)
    local ops = daemon_ops(ws)
    if ops then return ops.devices(ws) or {} end
    return records(ws and ws:devices() or {})
end

--- Discover the devices of every device-capable module, then call
--- `cb(list)` with the registry. In `daemon` mode a `Devices/1.scan` task,
--- whose handle is returned (a stop cancels it; `cb` is then not called);
--- refused (not carried) or failed — its task, or the registry's read after
--- it: notified, then `cb(nil, err)`.
--- @param ws loomworks.Workspace|nil
--- @param cb? fun(devices: loomworks.DeviceRecord[]|nil, err: string|nil)
--- @return loomworks.daemon.Preparation|nil handle `daemon` mode, the scan sent
function M.scan(ws, cb)
    cb = cb or function() end
    local ops = daemon_ops(ws)
    if ops then
        local _, handle = ops.scan_devices(ws, {
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
    if ws then ws:scan_devices(function(devices) cb(records(devices)) end) end
end

--- The choice's write ended: on success, in-process with `ws`, the page is
--- told (`active_set_changed`; in `daemon` mode the view's update tells it);
--- a failed write is reported as an error.
--- @return boolean ok, string|nil err
local function written(ws, profile, what, ok, err)
    if ok then
        if ws then ws._core._deps.events.emit("active_set_changed", ws._active_set) end
        return true
    end
    vim.notify("loomworks: could not " .. what .. " the device of profile '" .. tostring(profile.key)
        .. "': " .. tostring(err), vim.log.levels.ERROR)
    return false, err
end

--- Select `device` (a record of `list` / `scan`) for the profile, in the
--- `in-process` mode (in `daemon` mode the choice is `Profiles/1.set_device`
--- by ids, ui/model_calls). `cb(ok, err)` once the write ended (a failure
--- reported); its result is also returned.
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param device loomworks.DeviceRecord
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean|nil ok, string|nil err
function M.select(ws, profile, device, cb)
    cb = cb or function() end
    local ok, err = written(ws, profile, "save", profile:set_device(device.key))
    cb(ok, err)
    return ok, err
end

--- Clear the profile's device selection (see `select`; in `daemon` mode
--- `Profiles/1.clear_device`, ui/model_calls).
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean|nil ok, string|nil err
function M.clear(ws, profile, cb)
    cb = cb or function() end
    local ok, err = written(ws, profile, "clear", profile:clear_device())
    cb(ok, err)
    return ok, err
end

return M
