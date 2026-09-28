--- loomworks/remote/device_lock.lua — one remote operation at a time per
--- device per host (spec §18.7).
---
--- An exclusive per-serial lockfile `<dir>/<serial>.lock` in a per-user state
--- directory, shared by the editor, the CLI and every workspace on the host.
--- Same atomic-create + heartbeat mechanism as build-directory locks
--- (loomworks.build_lock); unlike those it WAITS by default (queueing for a
--- shared device is normal), printing the holder once; `wait = false` fails
--- fast. The wait has no deadline; a stale lock (heartbeat lapsed) is
--- reclaimed. `LOOMWORKS_DEVICE_LOCK_DIR` relocates the directory.

local build_lock = require("loomworks.build_lock")

local M = {}

--- Poll cadence while waiting for a held device lock.
M.POLL_MS = 500

--- The lock directory.
--- @return string
function M.dir()
    local o = os.getenv("LOOMWORKS_DEVICE_LOCK_DIR")
    if o and o ~= "" then return (o:gsub("\\", "/"):gsub("/+$", "")) end
    return require("loomworks.trust").data_dir() .. "/device-locks"
end

--- Lockfile path for a serial. Characters that cannot appear in a file name
--- (and path separators) are replaced, so any serial maps inside the directory.
--- @param serial string
--- @return string
function M.path(serial)
    local name = tostring(serial):gsub("[^%w%._%-]", "_")
    if name == "" or name == "." or name == ".." then name = "_" .. name end
    return M.dir() .. "/" .. name .. ".lock"
end

--- Lock info for a serial (pid, host, action, workspace, age, stale) or nil.
--- @param serial string
--- @return table|nil
function M.read(serial)
    return build_lock.read_path(M.path(serial))
end

local function holder(info, serial)
    info = info or {}
    return string.format("device %s is in use by pid %s%s (%s%s), %ss",
        tostring(serial), tostring(info.pid or "?"),
        (info.host and info.host ~= "?") and (" on " .. info.host) or "",
        tostring(info.action or "?"),
        info.workspace and (", workspace " .. tostring(info.workspace)) or "",
        tostring(info.age or "?"))
end
M.holder = holder

--- Acquire the device lock.
--- opts:
---   wait       boolean (default true) — false fails fast naming the holder
---   action     string recorded in the lockfile ("run", "test", "clean")
---   workspace  string recorded in the lockfile
---   on_wait    fun(msg: string) called ONCE when the lock is held by another
---   poll_ms    number override of the poll cadence
--- @param serial string
--- @param opts? table
--- @return table|nil handle, string|nil err
function M.acquire(serial, opts)
    opts = opts or {}
    local path = M.path(serial)
    local extra = { serial = serial, workspace = opts.workspace }
    local announced = false
    while true do
        local h, info = build_lock.try_acquire_path(path, opts.action or "run", extra)
        if h then
            h.serial = serial
            return h
        end
        local msg = holder(info, serial)
        if opts.wait == false then
            return nil, msg .. " — retry later, or `lw unlock --device " .. tostring(serial) .. "`"
        end
        if not announced then
            announced = true
            if opts.on_wait then opts.on_wait(msg .. " — waiting for it") end
        end
        vim.wait(opts.poll_ms or M.POLL_MS)
    end
end

--- Release a held device lock.
--- @param handle table|nil
function M.release(handle)
    build_lock.release(handle)
end

--- Force-remove a device lock (`lw unlock --device <serial>`).
--- @param serial string
--- @return boolean removed
function M.force(serial)
    return build_lock.force_path(M.path(serial))
end

return M
