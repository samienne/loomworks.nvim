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
---
--- Leftover programs (§18.7): while a remote run's program runs, the lockfile
--- also records `{ device_pid, nonce, program, program_started_at }`; a
--- handle that reclaimed a stale lock carries that record as `leftover`.

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

--- The program recorded in a lock record, validated (a corrupted or hostile
--- lockfile must never turn into a signal for an arbitrary pid or a path a
--- runner would quote into a device command unchecked), or nil.
--- @param info table|nil lock record
--- @return { pid: integer, nonce: string, program: string, started_at: integer|nil }|nil
function M.leftover_of(info)
    if type(info) ~= "table" then return nil end
    local pid, nonce, program = info.device_pid, info.nonce, info.program
    if type(pid) ~= "number" or pid < 1 or pid ~= math.floor(pid) then return nil end
    if type(nonce) ~= "string" or not nonce:match("^%w+$") then return nil end
    if type(program) ~= "string" or not program:match("^/") or program:find("[%z\r\n]") then return nil end
    for seg in program:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return nil end
    end
    local started = type(info.program_started_at) == "number" and info.program_started_at or nil
    return { pid = pid, nonce = nonce, program = program, started_at = started }
end

--- Record the running program in a held lock (§18.7).
--- @param handle table|nil
--- @param p { pid: integer, nonce: string, program: string }
function M.set_program(handle, p)
    build_lock.update_record(handle, { device_pid = p.pid, nonce = p.nonce, program = p.program,
        program_started_at = os.time() })
end

--- Clear the running-program record (the program exited or was stopped).
--- @param handle table|nil
function M.clear_program(handle)
    if not handle or not handle.record or handle.record.device_pid == nil then return end
    build_lock.update_record(handle, { device_pid = vim.NIL, nonce = vim.NIL, program = vim.NIL,
        program_started_at = vim.NIL })
end

-- ---------------------------------------------------------------------------
-- Leftover record file (§18.7): `<lock dir>/<serial>.leftover` keeps the
-- program of a run that ended (lock released) without stopping it.
-- ---------------------------------------------------------------------------

--- Path of a serial's leftover file: the lockfile's name with `.leftover`
--- in place of `.lock` (same serial-to-file-name mapping, same directory).
--- @param serial string
--- @return string
function M.leftover_path(serial)
    return (M.path(serial):gsub("%.lock$", ".leftover"))
end

--- Persist a run's program in the leftover file (atomic: temp + rename).
--- Best-effort; returns true on success.
--- @param serial string
--- @param p { pid: integer, nonce: string, program: string, started_at?: integer }
--- @return boolean
function M.save_leftover(serial, p)
    local rec = { device_pid = p.pid, nonce = p.nonce, program = p.program,
        program_started_at = p.started_at or os.time(), serial = serial }
    if not M.leftover_of(rec) then return false end
    local uv = vim.uv or vim.loop
    local path = M.leftover_path(serial)
    pcall(vim.fn.mkdir, M.dir(), "p")
    local tmp = path .. ".tmp." .. tostring(uv.os_getpid())
    local fd = uv.fs_open(tmp, "w", tonumber("644", 8))
    if not fd then return false end
    local ok = pcall(uv.fs_write, fd, vim.json.encode(rec), 0)
    uv.fs_close(fd)
    if not ok or not uv.fs_rename(tmp, path) then
        pcall(uv.fs_unlink, tmp)
        return false
    end
    return true
end

--- Read a serial's leftover file. Returns the validated leftover, or nil and
--- the state: "absent" (no file) or "invalid" (unreadable / not a record).
--- @param serial string
--- @return table|nil leftover, string|nil state
function M.load_leftover(serial)
    local uv = vim.uv or vim.loop
    local path = M.leftover_path(serial)
    local st = uv.fs_lstat(path)
    if not st then return nil, "absent" end
    if st.type ~= "file" then return nil, "invalid" end
    local f = io.open(path, "rb")
    if not f then return nil, "invalid" end
    local data = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, data or "")
    local left = ok and M.leftover_of(decoded) or nil
    if not left then return nil, "invalid" end
    return left
end

--- Remove a serial's leftover file — exactly that file, only when it is a
--- regular file (never a link or directory), nothing else in the directory.
--- @param serial string
--- @return boolean removed
function M.remove_leftover(serial)
    local uv = vim.uv or vim.loop
    local path = M.leftover_path(serial)
    local st = uv.fs_lstat(path)
    if not st or st.type ~= "file" then return false end
    return uv.fs_unlink(path) and true or false
end

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
            h.leftover = M.leftover_of(h.reclaimed)
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
