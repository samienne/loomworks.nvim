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

--- The workspace of a launch target's profile.
--- @param target loomworks.LaunchTarget
--- @return loomworks.Workspace|nil
local function target_ws(target)
    return require("loomworks.daemon.editor_ops").scope_workspace({ profile = target._profile })
end

--- `scan` for a launch target's workspace (the session tracker's prompt).
--- @param target loomworks.LaunchTarget
--- @param cb fun(devices: loomworks.DeviceRecord[]|nil, err: string|nil)
--- @return loomworks.daemon.Preparation|nil handle `daemon` mode, the scan sent
function M.scan_for_target(target, cb)
    return M.scan(target_ws(target), cb)
end

--- The serial of the device `profile` chose, from `list` (`daemon` mode:
--- the record whose `profiles` names it) or the model (`in-process`), nil
--- when none.
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param list loomworks.DeviceRecord[]|nil
--- @return string|nil
function M.chosen_in(ws, profile, list)
    if not daemon_ops(ws) then return profile:device_serial() end
    for _, d in ipairs(list or {}) do
        for _, p in ipairs(type(d.profiles) == "table" and d.profiles or {}) do
            if p == profile.key then return d.key end
        end
    end
    return nil
end

--- `cb(serial|nil)` with the device a launch target's profile chose: in
--- `daemon` mode once the registry is read, at once in-process. A registry
--- that cannot be read (refused, or its read failed) is `cb(nil, err)`,
--- `err` notified — never taken for "none chosen".
--- @param target loomworks.LaunchTarget
--- @param cb fun(serial: string|nil, err: string|nil)
function M.chosen_for_target(target, cb)
    local ws = target_ws(target)
    local ops = daemon_ops(ws)
    if not ops then return cb(target._profile:device_serial()) end
    ops.with_devices(ws, function(list, err)
        if not list then return cb(nil, err) end
        cb(M.chosen_in(ws, target._profile, list))
    end)
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

--- Select `device` (a record of `list` / `scan`) for the profile. `cb(ok,
--- err)` once the write ended (a failure reported). In-process the write is
--- synchronous and its result also returned; in `daemon` mode it is
--- `Profiles/1.set_device` (by the record's id) and nothing is returned.
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param device loomworks.DeviceRecord
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean|nil ok, string|nil err
function M.select(ws, profile, device, cb)
    cb = cb or function() end
    local ops = daemon_ops(ws)
    if ops then return ops.set_device(ws, profile, device, cb) end
    local ok, err = written(ws, profile, "save", profile:set_device(device.key))
    cb(ok, err)
    return ok, err
end

--- Clear the profile's device selection (see `select`; `daemon` mode:
--- `Profiles/1.clear_device`).
--- @param ws loomworks.Workspace|nil
--- @param profile loomworks.Profile
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean|nil ok, string|nil err
function M.clear(ws, profile, cb)
    cb = cb or function() end
    local ops = daemon_ops(ws)
    if ops then return ops.set_device(ws, profile, nil, cb) end
    local ok, err = written(ws, profile, "clear", profile:clear_device())
    cb(ok, err)
    return ok, err
end

--- The target's selection: `select` for its profile, in its workspace.
--- @param target loomworks.LaunchTarget
--- @param device loomworks.DeviceRecord
--- @param cb? fun(ok: boolean, err: string|nil)
function M.select_for_target(target, device, cb)
    local ws = target_ws(target)
    -- In-process the session tracker's choice tells no page (as before).
    return M.select(daemon_ops(ws) and ws or nil, target._profile, device, cb)
end

return M
