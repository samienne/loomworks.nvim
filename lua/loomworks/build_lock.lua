--- loomworks/build_lock.lua — cross-process advisory lock for build directories.
---
--- Serializes configure/build/clean across separate processes (editor + CLI,
--- or two CLIs) that share a build directory — advisory, host-provided
--- exclusion. The primitive is an O_EXCL lockfile
--- (`uv.fs_open(path, "wx")`): an atomic create-if-absent that works across
--- processes, unlike a `building=true` flag in a JSON file (a read-check-write
--- of a shared file is a TOCTOU race — two processes can both see "free").
---
--- Crash detection: the holder heartbeats the lockfile's mtime on a timer
--- (pid-liveness via `uv.kill(pid, 0)` is unreliable on Windows — it reports
--- dead pids as alive). A would-be acquirer that finds a lock whose mtime has
--- gone stale (no heartbeat within the window) reclaims it. Fail-fast: `acquire`
--- returns `(nil, reason)` when a live process holds the lock.

local uv = vim.uv or vim.loop

local M = {}

--- Heartbeat cadence and the staleness window (a few missed beats). A build
--- that is genuinely running keeps its mtime fresh, so only a crashed/hung
--- holder ever crosses the threshold.
M.HEARTBEAT_MS = 5000
M.STALE_SECONDS = 20

local function lock_path(build_dir) return build_dir .. ".loomworks-lock" end
local function now() return os.time() end

local function this_pid()
    if uv.os_getpid then return uv.os_getpid() end
    return (vim.fn and vim.fn.getpid and vim.fn.getpid()) or 0
end

local function this_host()
    local ok, h = pcall(function() return uv.os_gethostname and uv.os_gethostname() end)
    return (ok and type(h) == "string" and h) or "?"
end

--- Read the lock info for a build dir (with computed `age`/`stale`), or nil when
--- unlocked.
--- @param build_dir string
--- @return table|nil
function M.read(build_dir)
    local path = lock_path(build_dir)
    local st = uv.fs_stat(path)
    if not st then return nil end
    local info = {}
    local fd = uv.fs_open(path, "r", tonumber("400", 8))
    if fd then
        local data = uv.fs_read(fd, (st.size and st.size > 0 and st.size) or 4096, 0)
        uv.fs_close(fd)
        local ok, decoded = pcall(vim.json.decode, data or "")
        if ok and type(decoded) == "table" then info = decoded end
    end
    local mtime = (st.mtime and st.mtime.sec) or 0
    info.age = now() - mtime
    info.stale = info.age > M.STALE_SECONDS
    return info
end

--- Write a fresh lock file exclusively. Returns true on success, else nil + the
--- fs error (e.g. "EEXIST").
--- @return boolean|nil ok, string|nil err
local function create_locked(path, action)
    local fd, err = uv.fs_open(path, "wx", tonumber("644", 8))
    if not fd then return nil, err end
    local body = vim.json.encode({
        pid = this_pid(), host = this_host(), action = action, started_at = now(),
    })
    uv.fs_write(fd, body)
    uv.fs_close(fd)
    return true
end

--- Build the "busy" reason string from lock info.
local function busy_reason(info)
    info = info or {}
    return string.format("build directory is in use by pid %s%s (%s), %ss ago"
        .. " — wait for it to finish, or `lw unlock`",
        tostring(info.pid or "?"),
        (info.host and info.host ~= "?") and (" on " .. info.host) or "",
        tostring(info.action or "?"),
        tostring(info.age or "?"))
end

--- Acquire the lock for `build_dir`. Fail-fast: returns a handle on
--- success, or `(nil, reason)` if a live process holds it. A stale (crashed)
--- holder's lock is reclaimed automatically.
--- @param build_dir string
--- @param action "build"|"configure"|"clean"
--- @return table|nil handle, string|nil reason
function M.acquire(build_dir, action)
    local path = lock_path(build_dir)
    -- The parent may not exist yet (first configure creates the build dir).
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent then pcall(vim.fn.mkdir, parent, "p") end

    local ok = create_locked(path, action)
    if not ok then
        local info = M.read(build_dir)
        if info and info.stale then
            -- Atomic reclaim: only the process whose rename wins removes the
            -- stale lock; a racing reclaimer then re-hits the fresh lock.
            local tmp = path .. ".stale." .. this_pid()
            if uv.fs_rename(path, tmp) then
                pcall(uv.fs_unlink, tmp)
                ok = create_locked(path, action)
            end
        end
        if not ok then return nil, busy_reason(info) end
    end

    local timer = uv.new_timer()
    timer:start(M.HEARTBEAT_MS, M.HEARTBEAT_MS, function()
        pcall(uv.fs_utime, path, now(), now())
    end)
    return { path = path, timer = timer, build_dir = build_dir }
end

--- Release a held lock.
--- @param handle table|nil
function M.release(handle)
    if not handle then return end
    if handle.timer then
        pcall(function() handle.timer:stop(); handle.timer:close() end)
    end
    pcall(uv.fs_unlink, handle.path)
end

--- Force-remove the lock for a build dir (manual recovery / `lw unlock`).
--- @param build_dir string
--- @return boolean removed true if a lock file was present
function M.force(build_dir)
    local path = lock_path(build_dir)
    if not uv.fs_stat(path) then return false end
    pcall(uv.fs_unlink, path)
    return true
end

return M
