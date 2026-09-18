--- loomworks/daemon/lock.lua — the per-workspace daemon WRITE-AUTHORITY lock.
---
--- Exactly one process may write a workspace's files (user/cache/loomworks.json)
--- at a time (DAEMON.md §4). This lock is that single-writer token: the daemon
--- acquires it on startup and holds it for its lifetime, so it is the sole
--- writer; a client only ever enters the file-writing fallback lane after it
--- acquires this lock ITSELF (never on a bare socket error). Two writers can
--- never race.
---
--- It reuses the SAME primitive as `build_lock.lua` — an `O_EXCL` create
--- (atomic across processes) with an mtime heartbeat so a crashed holder's lock
--- goes stale and is reclaimed — but it is a DISTINCT, per-folder lockfile
--- (`.nvim/loomworks.daemon.lock`), not `build_lock`'s per-build-dir naming.
--- The lock (write-authority) and the handle file (discovery, §17.2) are
--- separate concerns.

local uv = vim.uv or vim.loop

local M = {}

--- Heartbeat cadence and staleness window. A live daemon keeps its lock mtime
--- fresh on this timer; only a crashed/hung holder crosses the window.
M.HEARTBEAT_MS = 5000
M.STALE_SECONDS = 20

local function lock_path(root) return root .. "/.nvim/loomworks.daemon.lock" end
local function now() return os.time() end

local function this_pid()
    if uv.os_getpid then return uv.os_getpid() end
    return (vim.fn and vim.fn.getpid and vim.fn.getpid()) or 0
end

local function this_host()
    local ok, h = pcall(function() return uv.os_gethostname and uv.os_gethostname() end)
    return (ok and type(h) == "string" and h) or "?"
end

--- Read the lock record for a root (with computed age/stale), or nil when free.
--- @param root string
--- @return table|nil
function M.read(root)
    local path = lock_path(root)
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

--- Create the lockfile exclusively. Returns true, or nil + fs error (e.g. EEXIST).
--- @return boolean|nil ok, string|nil err
local function create_locked(path, pid, generation)
    local fd, err = uv.fs_open(path, "wx", tonumber("644", 8))
    if not fd then return nil, err end
    uv.fs_write(fd, vim.json.encode({
        pid = pid, host = this_host(), started_at = now(), session_generation = generation,
    }))
    uv.fs_close(fd)
    return true
end

--- Acquire write authority for `root`. Fail-fast: returns a handle on success,
--- or `(nil, reason)` when a LIVE process holds it. A stale (crashed) holder's
--- lock is reclaimed atomically (only the rename winner recreates it).
--- @param root string
--- @param opts? { generation?: integer }
--- @return table|nil handle, string|nil reason
function M.acquire(root, opts)
    opts = opts or {}
    local path = lock_path(root)
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent then pcall(vim.fn.mkdir, parent, "p") end

    local pid = this_pid()
    local ok = create_locked(path, pid, opts.generation)
    if not ok then
        local info = M.read(root)
        if info and info.stale then
            local tmp = path .. ".stale." .. pid
            if uv.fs_rename(path, tmp) then
                pcall(uv.fs_unlink, tmp)
                ok = create_locked(path, pid, opts.generation)
            end
        end
        if not ok then
            info = info or {}
            return nil, string.format(
                "a loomworks daemon (pid %s%s) already owns this workspace, %ss ago",
                tostring(info.pid or "?"),
                (info.host and info.host ~= "?") and (" on " .. info.host) or "",
                tostring(info.age or "?"))
        end
    end

    local timer = uv.new_timer()
    timer:start(M.HEARTBEAT_MS, M.HEARTBEAT_MS, function()
        pcall(uv.fs_utime, path, now(), now())
    end)
    return { path = path, timer = timer, root = root }
end

--- Refresh the lock mtime once (manual heartbeat, e.g. from a test).
--- @param root string
function M.heartbeat(root)
    local path = lock_path(root)
    if not uv.fs_stat(path) then return false end
    local t = now()
    pcall(uv.fs_utime, path, t, t)
    return true
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

--- Force-remove the lock for a root (recovery). Returns true if one was present.
--- @param root string
--- @return boolean removed
function M.force(root)
    local path = lock_path(root)
    if not uv.fs_stat(path) then return false end
    pcall(uv.fs_unlink, path)
    return true
end

return M
