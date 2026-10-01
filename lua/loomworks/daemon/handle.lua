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
    local st = uv().fs_stat(path)
    if not st then return nil end
    local info, decoded = {}, nil
    if st.type == "file" then
        local fd = uv().fs_open(path, "r", 256)
        if fd then
            local data = uv().fs_read(fd, math.min(st.size or 0, 65536) + 1, 0)
            uv().fs_close(fd)
            local ok, d = pcall(vim.json.decode, data or "")
            if ok and type(d) == "table" then decoded = d end
        end
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

--- Write the handle atomically: staged to `<handle>.tmp-<random>` created
--- exclusively (never through a file or link planted in a shared `.nvim/`),
--- then renamed over the handle.
--- @param root string
--- @param rec table
--- @return boolean|nil ok, string|nil err
function M.write(root, rec)
    local path = paths.handle_path(root)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not uv().fs_stat(dir) then pcall(vim.fn.mkdir, dir, "p") end
    local body = {}
    for k, v in pairs(rec) do
        if k ~= "age" and k ~= "stale" and k ~= "valid" then body[k] = v end
    end
    local data = vim.json.encode(body)
    local tmp, err
    for _ = 1, 3 do
        local cand = path .. ".tmp-" .. M._suffix()
        local ok, werr, code = require("loomworks.io").write_exclusive(cand, data, tonumber("644", 8))
        if ok then tmp = cand; break end
        err = werr
        if code ~= "EEXIST" then break end
    end
    if not tmp then return nil, err end
    local ok_r, rerr = uv().fs_rename(tmp, path)
    if not ok_r then pcall(uv().fs_unlink, tmp); return nil, rerr end
    return true
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
