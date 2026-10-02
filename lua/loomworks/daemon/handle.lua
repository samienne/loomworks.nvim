--- loomworks/daemon/handle.lua — the daemon handle `<root>/.nvim/loomworks.daemon.json`
--- (spec §19.6).
---
--- Discovery only: the runtime lock (§19.2, loomworks.daemon.rlock) decides
--- who the runtime is, the handshake (§19.8) whether a client may use it. The
--- daemon writes the handle after binding its endpoint:
---
---   { pid, host, os, start_time, endpoint, protocol, lw_version,
---     schemas = { user, cache }, session_generation, started_at,
---     clients, busy, idle_since, lock_nonce }
---
--- (`start_time` and `lock_nonce` tie the handle to the daemon's process and
--- its runtime-lock record.) It refreshes the file's modification time on its
--- heartbeat and rewrites it when `clients` / `busy` change. Liveness is the
--- heartbeat, never a probe of the pid. A malformed handle reads as
--- unreadable, never as a live daemon.
---
--- Removal (deletion safety): only the holder of the runtime lock removes the
--- handle — the daemon on its way out, or a process that reclaimed the lock of
--- a dead daemon (§19.5) — and only this exact regular file.

local paths = require("loomworks.daemon.paths")

local M = {}

local function uv() return vim.uv or vim.loop end

--- Staleness window of the heartbeat (the runtime lock's, §16.6).
M.STALE_SECONDS = 20

--- Is a decoded handle well-formed?
--- @param rec any
--- @return boolean
function M.valid(rec)
    return type(rec) == "table"
        and type(rec.pid) == "number" and rec.pid > 0
        and type(rec.host) == "string" and rec.host ~= ""
        and type(rec.endpoint) == "string" and rec.endpoint ~= ""
        and type(rec.protocol) == "number"
end

--- Read the handle of `root`: nil when absent; otherwise the record plus
--- `age` (seconds since the heartbeat), `stale`, and `valid` (false for a
--- malformed file, whose fields are then not to be trusted).
--- @param root string
--- @return table|nil
function M.read(root)
    local path = paths.handle_path(root)
    -- Windows: one open, as short as it can be (while a reader holds the
    -- file open, the daemon's rename over it fails — `write` retries).
    -- POSIX: never opened unless it is a regular file (a FIFO planted in a
    -- shared `.nvim/` would block the open).
    local info, decoded, st = {}, nil, nil
    if package.config:sub(1, 1) ~= "\\" then
        st = uv().fs_stat(path)
        if not st then return nil end
    end
    local fd = (not st or st.type == "file") and uv().fs_open(path, "r", 256) or nil
    if fd then
        st = uv().fs_fstat(fd)
        local data = st and st.type == "file" and uv().fs_read(fd, math.min(st.size or 0, 65536) + 1, 0)
        uv().fs_close(fd)
        if data then
            local ok, d = pcall(vim.json.decode, data)
            if ok and type(d) == "table" then decoded = d end
        end
    end
    if not st then
        st = uv().fs_stat(path)
        if not st then return nil end
    end
    if decoded and M.valid(decoded) then
        info = decoded
        info.valid = true
    else
        info.valid = false
    end
    local mtime = (st.mtime and st.mtime.sec) or 0
    info.age = os.time() - mtime
    info.stale = info.age > M.STALE_SECONDS
    return info
end

--- The random suffix of a staged handle (a test seam).
--- @return string
function M._suffix()
    local ok, b = pcall(uv().random, 8)
    if ok and type(b) == "string" and #b == 8 then
        return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
    return string.format("%x%x", uv().hrtime() % 0x7fffffff, math.random(0, 0x7fffffff))
end

--- The rename retry of `write` (Windows): its time budget (ms) and the
--- sleeps between attempts (ms; the last value repeats). A reader holds the
--- handle open for well under a millisecond, but on a loaded machine (every
--- client polling it, an indexer, an antivirus scan) the rename can keep
--- failing for longer than the 0.2 s this used to allow; a caller that must
--- not block that long (the daemon's loop) passes a smaller `budget_ms` and
--- retries later itself (loomworks.daemon.server).
M.RENAME_BUDGET_MS = 2000
M.RENAME_DELAYS_MS = { 2, 5, 10, 20, 40, 80, 160, 250 }

--- Is a failed rename worth retrying (a reader holding the handle open)?
--- @param code string|nil the libuv error name
--- @return boolean
function M.transient(code)
    return code == "EPERM" or code == "EACCES" or code == "EBUSY"
end

--- The bytes `write` publishes for `rec` (the computed `age`, `stale`,
--- `valid` left out).
--- @param rec table
--- @return string
function M.encode(rec)
    local body = {}
    for k, v in pairs(rec) do
        if k ~= "age" and k ~= "stale" and k ~= "valid" then body[k] = v end
    end
    return vim.json.encode(body)
end

--- Write the handle atomically: staged to `<handle>.tmp-<random>` created
--- exclusively (never through a file or link planted in a shared `.nvim/`),
--- then renamed over the handle. On Windows the rename fails (EPERM/EACCES)
--- while another process has the handle open — a client reading it, an
--- indexer or a scanner: libuv opens files with FILE_SHARE_DELETE, but
--- replacing a file that is open still fails (only the SOURCE of a rename
--- may be open) — so it is retried with backoff for at most `budget_ms`
--- (default `RENAME_BUDGET_MS`). A rename that still fails removes the staged
--- file (that exact name, a regular file this call created) and leaves the
--- previous handle as it was: never a partial one.
--- @param root string
--- @param rec table
--- @param opts? { budget_ms?: integer }
--- @return boolean|nil ok, string|nil err, string|nil code the libuv error name
function M.write(root, rec, opts)
    local path = paths.handle_path(root)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not uv().fs_stat(dir) then pcall(vim.fn.mkdir, dir, "p") end
    local data = M.encode(rec)
    local tmp, err, ecode
    for _ = 1, 3 do
        local cand = path .. ".tmp-" .. M._suffix()
        local ok, werr, code = require("loomworks.io").write_exclusive(cand, data, tonumber("644", 8))
        if ok then tmp = cand; break end
        err, ecode = werr, code
        if code ~= "EEXIST" then break end
    end
    if not tmp then return nil, err, ecode end
    local budget = (opts and opts.budget_ms) or M.RENAME_BUDGET_MS
    local t0 = uv().hrtime()
    local rerr, rcode
    local i = 0
    while true do
        i = i + 1
        local ok_r, e, code = uv().fs_rename(tmp, path)
        if ok_r then return true end
        rerr, rcode = e, code
        if not M.transient(code) then break end
        local delay = M.RENAME_DELAYS_MS[math.min(i, #M.RENAME_DELAYS_MS)]
        if (uv().hrtime() - t0) / 1e6 + delay > budget then break end
        uv().sleep(delay)
    end
    local lst = uv().fs_lstat(tmp)
    if lst and lst.type == "file" then pcall(uv().fs_unlink, tmp) end
    return nil, rerr, rcode
end

--- Refresh the handle's modification time (the heartbeat). Returns false
--- when the handle is absent (the daemon then rewrites it, §19.6).
--- @param root string
--- @return boolean
function M.touch(root)
    local path = paths.handle_path(root)
    if not uv().fs_stat(path) then return false end
    local t = os.time()
    return uv().fs_utime(path, t, t) and true or false
end

--- Remove the handle — exactly that regular file (never a link or a
--- directory). With `expect`, only when the handle names that process
--- (`pid` and `start_time`), so a reclaimer never removes a successor's
--- handle. The caller holds the runtime lock.
--- @param root string
--- @param expect? { pid: integer, start_time?: string }
--- @return boolean removed
function M.remove(root, expect)
    local path = paths.handle_path(root)
    local st = uv().fs_lstat(path)
    if not st or st.type ~= "file" then return false end
    if expect then
        local cur = M.read(root)
        if cur and cur.valid and (cur.pid ~= expect.pid
                or (expect.start_time ~= nil and cur.start_time ~= expect.start_time)) then
            return false
        end
    end
    return uv().fs_unlink(path) and true or false
end

return M
