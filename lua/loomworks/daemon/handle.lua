--- loomworks/daemon/handle.lua — the per-workspace daemon handle file.
---
--- `.nvim/loomworks.daemon.json` is the daemon's **discovery** record: it tells
--- a client where the daemon's pipe is, which wire protocol and lw version it
--- speaks, and its session generation (DAEMON.md §4). It is deliberately
--- SEPARATE from the write-authority **lockfile** (`.nvim/loomworks.daemon.lock`,
--- a Phase-1 concern reusing the `build_lock` O_EXCL + heartbeat primitive) —
--- discovery and write-authority are different concerns.
---
--- Liveness is judged by the **mtime-heartbeat** trick, NOT `uv.kill(pid, 0)`
--- (unreliable on Windows — reports dead pids as alive), exactly the lesson
--- `build_lock.lua` already encodes: a live daemon touches the handle file's
--- mtime on a timer, so a handle whose mtime has gone stale marks a dead daemon.
---
--- Phase 0 note: no daemon *server* exists yet, so nothing in mainline WRITES a
--- live handle in normal operation. This module is the reader the client stub
--- uses to detect a stray/leftover daemon, plus the writer a Phase-1 daemon (and
--- the tests' mock daemon) will use.

local uv = vim.uv or vim.loop

local M = {}

--- Staleness window for the mtime heartbeat. A live daemon refreshes the handle
--- mtime well within this; only a crashed/hung one crosses it. Kept in the same
--- ballpark as `build_lock.STALE_SECONDS` for consistency.
M.STALE_SECONDS = 20

local function now() return os.time() end

--- Absolute path of the handle file for a workspace root.
--- @param root string workspace root
--- @return string
function M.path(root)
    return root .. "/.nvim/loomworks.daemon.json"
end

--- Read the handle file, augmenting it with computed `age` (seconds since last
--- mtime heartbeat) and `stale` (age past the window). Returns nil when no
--- handle file is present.
--- @param root string workspace root
--- @return table|nil info
function M.read(root)
    local path = M.path(root)
    local st = uv.fs_stat(path)
    if not st then return nil end
    local info = {}
    local fd = uv.fs_open(path, "r", tonumber("400", 8))
    if fd then
        local data = uv.fs_read(fd, (st.size and st.size > 0 and st.size) or 8192, 0)
        uv.fs_close(fd)
        local ok, decoded = pcall(vim.json.decode, data or "")
        if ok and type(decoded) == "table" then info = decoded end
    end
    local mtime = (st.mtime and st.mtime.sec) or 0
    info.age = now() - mtime
    info.stale = info.age > M.STALE_SECONDS
    return info
end

--- True when the handle names a daemon that appears live (present and not
--- past the heartbeat staleness window).
--- @param info table|nil the result of M.read
--- @return boolean
function M.is_live(info)
    return info ~= nil and info.stale == false
end

--- Serialize the durable fields of a handle record (never the computed
--- age/stale, which are read-time derivations).
--- @param info table
--- @return table
local function durable_fields(info)
    return {
        pid = info.pid,
        pipe = info.pipe,
        protocol_version = info.protocol_version,
        lw_version = info.lw_version,
        session_generation = info.session_generation,
        started_at = info.started_at,
    }
end

--- Write the handle file for a workspace root (creating `.nvim/` if needed).
--- The daemon calls this on startup and refreshes the mtime as its heartbeat.
--- @param root string workspace root
--- @param info table handle record ({ pid, pipe, protocol_version, lw_version, session_generation, started_at })
--- @return boolean|nil ok, string|nil err
function M.write(root, info)
    local dir = root .. "/.nvim"
    pcall(function()
        if vim.fn and vim.fn.mkdir then vim.fn.mkdir(dir, "p") else pcall(uv.fs_mkdir, dir, 493) end
    end)
    local path = M.path(root)
    local body = vim.json.encode(durable_fields(info))
    local fd, err = uv.fs_open(path, "w", tonumber("644", 8))
    if not fd then return nil, err end
    uv.fs_write(fd, body)
    uv.fs_close(fd)
    return true
end

--- Refresh the handle's mtime — the liveness heartbeat a running daemon issues
--- on a timer. No-op (returns false) when the handle is absent.
--- @param root string workspace root
--- @return boolean beat true if the handle existed and was touched
function M.heartbeat(root)
    local path = M.path(root)
    if not uv.fs_stat(path) then return false end
    local t = now()
    pcall(uv.fs_utime, path, t, t)
    return true
end

--- Remove the handle file (daemon shutdown / stale cleanup).
--- @param root string workspace root
--- @return boolean removed true if a handle file was present
function M.remove(root)
    local path = M.path(root)
    if not uv.fs_stat(path) then return false end
    pcall(uv.fs_unlink, path)
    return true
end

return M
