--- loomworks/lock_record.lua — the common lock record and holder
--- classification of every loomworks lock (spec §19.5).
---
--- Every lockfile (build directory §16.6, device §18.7, file save §2.7, and
--- the workspace operation lock §19.3) carries the same record:
---
---   { pid, host, start_time, lock_nonce, kind, operation, started_at }
---
--- plus `action` (= operation, read by older versions) and any class-specific
--- fields. `start_time` is the holder's process start time (loomworks.proc; it
--- tells a reused process id apart), `lock_nonce` a random id of this one
--- acquisition (a reclaim removes only the record it observed), `kind` the
--- holder kind (`lw`, `daemon`, `editor`). The file's mtime is the heartbeat.
--- (`nonce` is not used: device-lock records already carry a `nonce` naming
--- their running program, §18.7.)
---
--- A process that finds a lock held classifies the holder (§19.5):
---   dead          same host, no process with that id AND start time → reclaim
---   live          same host alive + fresh heartbeat, or other host + fresh
---   hung          same host alive, heartbeat stale → NOT reclaimed
---   stale         no start time to check (older writer, or no probe on this
---                 host) and heartbeat stale → reclaimed (heartbeat rule)
---   stale_foreign other host, heartbeat stale → reclaimed

local proc = require("loomworks.proc")

local M = {}

local function uv() return vim.uv or vim.loop end

--- The holder kind this process records: `editor` unless the host says
--- otherwise (the CLI sets `lw` at startup).
M.holder_kind = "editor"

--- @param kind "lw"|"daemon"|"editor"
function M.set_holder_kind(kind) M.holder_kind = kind end

--- States in which a lock may be reclaimed without killing anything.
M.RECLAIMABLE = { dead = true, stale = true, stale_foreign = true }

function M.this_pid()
    local u = uv()
    if u.os_getpid then return u.os_getpid() end
    return (vim.fn and vim.fn.getpid and vim.fn.getpid()) or 0
end

function M.this_host()
    local ok, h = pcall(function() return uv().os_gethostname and uv().os_gethostname() end)
    return (ok and type(h) == "string" and h ~= "" and h) or "?"
end

local _seq = 0
--- A fresh random nonce (hex).
--- @return string
function M.new_nonce()
    _seq = _seq + 1
    local u = uv()
    local ok, bytes = pcall(function() return u.random and u.random(8) end)
    local hex
    if ok and type(bytes) == "string" and #bytes == 8 then
        hex = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    else
        hex = string.format("%x%x", math.floor(u.hrtime() % 1e15), math.random(0, 0x7fffffff))
    end
    return hex .. string.format("%x%x", M.this_pid() % 0x10000, _seq)
end

--- A new lock record for this process.
--- @param operation string
--- @param extra? table class-specific fields (never override the common ones)
--- @return table
function M.new(operation, extra)
    local rec = {}
    for k, v in pairs(extra or {}) do rec[k] = v end
    rec.pid = M.this_pid()
    rec.host = M.this_host()
    rec.start_time = proc.self_start_time()
    rec.lock_nonce = M.new_nonce()
    rec.kind = M.holder_kind
    rec.operation = operation
    rec.action = operation
    rec.started_at = os.time()
    return rec
end

--- The operation a record names (`action` in records of older versions).
--- @param info table|nil
--- @return string|nil
function M.operation_of(info)
    if type(info) ~= "table" then return nil end
    local op = info.operation
    if type(op) ~= "string" then op = info.action end
    return type(op) == "string" and op or nil
end

--- How long `read` waits for the record of a fresh, empty lockfile (ms).
M.EMPTY_SETTLE_MS = 250
--- An empty lockfile at most this old (seconds, by its mtime) is waited for.
M.EMPTY_FRESH_S = 2
--- The wait between two reads of an empty lockfile (tests replace it).
--- @param ms integer
function M._settle_sleep(ms) uv().sleep(ms) end

local function read_body(u, path)
    local fd = u.fs_open(path, "r", 256)
    if not fd then return nil end
    local fst = u.fs_fstat(fd)
    local data = u.fs_read(fd, (fst and fst.size and fst.size > 0 and fst.size) or 4096, 0)
    u.fs_close(fd)
    return data
end

--- Read a lockfile: its decoded record (an undecodable or legacy non-JSON body
--- reads as `{}`) plus `age` (seconds since the heartbeat) and `stale`.
--- nil when there is no lockfile.
---
--- A lockfile is created with its record in place (`create`: a hard link of
--- a written temp) and rewritten by a rename (`replace`), so it is normally
--- never empty. Where hard links are not supported it is created empty (the
--- exclusive create) and its record written right after, and a lock written
--- by an older version may be too: a reader between the two sees an empty
--- body, which names no host and would be judged another host's live lock. A
--- fresh empty body (EMPTY_FRESH_S) is read again for up to EMPTY_SETTLE_MS;
--- one still empty then (its writer died in between) reads as `{}`.
--- @param path string
--- @param stale_seconds number heartbeat window
--- @return table|nil
function M.read(path, stale_seconds)
    local u = uv()
    local st = u.fs_stat(path)
    if not st then return nil end
    local data = read_body(u, path)
    if data == "" and os.time() - ((st.mtime and st.mtime.sec) or 0) <= M.EMPTY_FRESH_S then
        local deadline = u.hrtime() + M.EMPTY_SETTLE_MS * 1e6
        while data == "" and u.hrtime() < deadline do
            M._settle_sleep(5)
            st = u.fs_stat(path)
            if not st then return nil end -- released meanwhile
            data = read_body(u, path)
        end
    end
    local info = {}
    local ok, decoded = pcall(vim.json.decode, data or "")
    if ok and type(decoded) == "table" then info = decoded end
    local mtime = (st.mtime and st.mtime.sec) or 0
    info.age = os.time() - mtime
    info.stale = info.age > stale_seconds
    return info
end

--- Classify a lock's holder (see the module header).
--- @param info table from `read`
--- @return "dead"|"live"|"hung"|"stale"|"stale_foreign"
function M.classify(info)
    if type(info.host) ~= "string" or info.host ~= M.this_host() then
        return info.stale and "stale_foreign" or "live"
    end
    local st = info.start_time
    if type(st) == "string" and type(info.pid) == "number" then
        local alive = proc.alive(info.pid, st)
        if alive == false then return "dead" end
        if alive == true then return info.stale and "hung" or "live" end
    end
    return info.stale and "stale" or "live"
end

--- The identity a reclaim compares: the nonce, else (older records) the
--- holder fields.
local function identity(info)
    if type(info) ~= "table" then return "?" end
    if type(info.lock_nonce) == "string" then return "n:" .. info.lock_nonce end
    return "p:" .. tostring(info.pid) .. ":" .. tostring(info.started_at) .. ":" .. tostring(info.host)
end
M._identity = identity

--- Does the lockfile still carry this record (same nonce)?
--- @param path string
--- @param rec table
--- @return boolean
function M.still_ours(path, rec)
    local info = M.read(path, math.huge)
    return info ~= nil and type(rec) == "table" and rec.lock_nonce ~= nil
        and info.lock_nonce == rec.lock_nonce
end

--- Atomically remove the lockfile at `path` if it still carries the record
--- `observed` (spec §19.5: reclaiming is a rename of the record, done only if
--- it still carries the observed nonce). A record that changed in between is
--- put back when its name is still free. Returns true when the observed
--- record was removed.
--- @param path string
--- @param observed table
--- @return boolean
function M.reclaim(path, observed)
    local u = uv()
    -- Re-check right before the rename: a record replaced since it was judged
    -- is never moved at all, so the restore below (which can lose a record
    -- written in the rename window) is reached only by a replacement that
    -- lands between this read and the rename.
    local cur = M.read(path, math.huge)
    if not cur or identity(cur) ~= identity(observed) then return false end
    local tmp = path .. ".reclaim." .. M.new_nonce()
    if not u.fs_rename(path, tmp) then return false end
    local got = M.read(tmp, math.huge) or {}
    if identity(got) == identity(observed) then
        pcall(u.fs_unlink, tmp)
        return true
    end
    -- Not the record we judged: restore it if nobody took the name meanwhile
    -- (a hard link is an atomic create-if-absent), else drop our moved copy.
    if not u.fs_link(tmp, path) then
        if not u.fs_stat(path) then u.fs_rename(tmp, path) end
    end
    pcall(u.fs_unlink, tmp)
    return false
end

-- ---------------------------------------------------------------------------
-- Writing a lock file
-- ---------------------------------------------------------------------------

--- Hard-link error codes that mean "no hard links on this file system" (FAT,
--- some network shares, a sandbox that forbids them): EPERM (Linux vfat,
--- SMB), EACCES, ENOTSUP/ENOSYS, EISDIR (Windows ERROR_INVALID_FUNCTION on
--- FAT), EXDEV, EMLINK, EINVAL. `create` falls back to the plain exclusive
--- create only when a probe link to a fresh name fails too (EPERM is also
--- Windows' answer for a "delete pending" lock file name). EEXIST is never
--- among them: it means the lock is held.
M.LINK_UNSUPPORTED = {
    EPERM = true, EACCES = true, ENOTSUP = true, ENOSYS = true,
    EISDIR = true, EXDEV = true, EMLINK = true, EINVAL = true,
}

--- Rename retries of `replace` (Windows: a reader holding the lock file open
--- can make a rename over it fail with EACCES/EPERM for a moment).
M.REPLACE_RETRIES = 40
M.REPLACE_RETRY_MS = 5

--- File-system seams (tests inject failures).
function M._link(from, to) return uv().fs_link(from, to) end
function M._rename(from, to) return uv().fs_rename(from, to) end

--- The temporary name a record is written under before it gets the lock
--- file's name: `<lockfile>.new.<nonce>` beside it (the nonce carries the pid
--- and a random part). It never ends in a lock file's suffix (`.lock`,
--- `.loomworks-lock`), so no reader, scan or `lw unlock` takes it for a lock.
--- @param path string
--- @return string
function M.temp_name(path) return path .. ".new." .. M.new_nonce() end

--- Write `body` to a fresh temp beside `path` (exclusive create). Returns its
--- name, or nil + error + code; a failed write removes the temp.
local function write_temp(path, body)
    local u = uv()
    local tmp = M.temp_name(path)
    local fd, err, code = u.fs_open(tmp, "wx", 420) -- 0644
    if not fd then return nil, err, code end
    local _, werr, wcode = u.fs_write(fd, body, 0)
    u.fs_close(fd)
    if werr then
        pcall(u.fs_unlink, tmp)
        return nil, werr, wcode
    end
    return tmp
end

--- Create the lock file at `path` holding `rec`, exclusively: never through
--- an existing one. The record is written to a temp first and given the lock
--- file's name by a hard link — an atomic create-if-absent — so the lock
--- file never exists without its record (spec §19.5). Where hard links are
--- not supported (LINK_UNSUPPORTED) it is the exclusive create
--- (O_CREAT|O_EXCL) followed by the write. Returns true, or nil + error +
--- code ("EEXIST": the lock is held).
--- @param path string
--- @param rec table
--- @return boolean|nil ok, string|nil err, string|nil code
function M.create(path, rec)
    local u = uv()
    local body = vim.json.encode(rec)
    local tmp = write_temp(path, body)
    if tmp then
        local ok, lerr, lcode = M._link(tmp, path)
        if ok then
            pcall(u.fs_unlink, tmp)
            return true
        end
        -- One of these codes can also be about the lock file's NAME (Windows:
        -- a lock file just released but still open elsewhere is "delete
        -- pending" — EPERM — until its last handle closes): a second link to
        -- a fresh name tells "no hard links here" from that.
        local unsupported = M.LINK_UNSUPPORTED[lcode] == true
        if unsupported then
            local probe = M.temp_name(path)
            if M._link(tmp, probe) then
                pcall(u.fs_unlink, probe)
                unsupported = false
            end
        end
        pcall(u.fs_unlink, tmp)
        if not unsupported then return nil, lerr, lcode end
    end
    local fd, err, code = u.fs_open(path, "wx", 420)
    if not fd then return nil, err, code end
    u.fs_write(fd, body, 0)
    u.fs_close(fd)
    return true
end

--- Replace the record of a lock file this process holds by `rec` (same
--- nonce): written to a temp and renamed over the lock file, so a reader
--- sees the old record or the new one, never an empty file. That the lock
--- file still carries `rec`'s nonce is checked right before each rename, so
--- a lock file forced off or reclaimed is normally left alone; a narrow
--- window remains between that check and the rename (no wider than with the
--- previous in-place rewrite). Returns true; false + "lost"
--- when the lock is no longer ours; false + the error when no rename
--- succeeded (the temp is removed on every failure).
--- @param path string
--- @param rec table
--- @return boolean ok, string|nil err
function M.replace(path, rec)
    local u = uv()
    local tmp, terr = write_temp(path, vim.json.encode(rec))
    if not tmp then return false, tostring(terr) end
    local err = "rename failed"
    for i = 1, M.REPLACE_RETRIES do
        if not M.still_ours(path, rec) then
            pcall(u.fs_unlink, tmp)
            return false, "lost"
        end
        local ok, rerr, code = M._rename(tmp, path)
        if ok then return true end
        err = tostring(rerr)
        if code ~= "EACCES" and code ~= "EPERM" then break end
        if i < M.REPLACE_RETRIES then u.sleep(M.REPLACE_RETRY_MS) end
    end
    pcall(u.fs_unlink, tmp)
    return false, err
end

--- "45s", "2m", "3h".
--- @param secs number|nil
--- @return string
function M.age_text(secs)
    secs = tonumber(secs) or 0
    if secs < 120 then return string.format("%ds", secs) end
    if secs < 7200 then return string.format("%dm", math.floor(secs / 60)) end
    return string.format("%dh", math.floor(secs / 3600))
end

--- How a message names the holder: "lw build", "nvim (configure)", …
--- @param info table
--- @return string
function M.holder_text(info)
    local op = M.operation_of(info)
    if info.kind == "editor" then return "nvim" .. (op and (" (" .. op .. ")") or "") end
    if info.kind == "daemon" then return "the workspace daemon" end
    return "lw" .. (op and (" " .. op) or "")
end

--- Is this holder on this host?
--- @param info table
--- @return boolean
function M.same_host(info)
    return type(info.host) == "string" and info.host == M.this_host()
end

--- The refusal message for a held lock (spec §19.3, §19.5).
--- ctx:
---   what     how to name the locked thing ("build/debug", "device SER1")
---   command  the command to retry with `--break-locks` ("lw build")
---   unlock   the `lw unlock --force` argument naming this lock
---   breaking true when `--break-locks` was given (and refused here)
---   style    "workspace" (the operation lock, §19.3: `workspace busy: …`) or
---            "nuke" (a build lock `lw nuke` needs: `a build is running in …`)
---   prefix   prepended to every message ("cannot nuke: ")
--- @param info table classified holder info (`state` set)
--- @param ctx table
--- @return string
function M.busy_message(info, ctx)
    return (ctx.prefix or "") .. M._busy_text(info, ctx)
end

function M._busy_text(info, ctx)
    local what = ctx.what or "the lock"
    local pid = tostring(info.pid or "?")
    local holder = M.holder_text(info)
    local unlock = ctx.unlock and ("lw unlock --force " .. ctx.unlock) or "lw unlock --force"
    local foreign = not M.same_host(info)
    if foreign and ctx.style == "workspace" and not ctx.breaking then
        return string.format("workspace busy: %s (pid %s on %s, %s) — retry when it finishes",
            M.operation_of(info) or "an operation", pid, tostring(info.host or "?"), M.age_text(info.age))
    end
    if foreign then
        local host = (type(info.host) == "string" and info.host ~= "") and info.host or "another host"
        return string.format("%s is in use by %s (pid %s on %s), %s ago — wait for it; it cannot be "
            .. "stopped from here (stop it on %s), or remove the record without stopping it: %s",
            what, holder, pid, host, M.age_text(info.age), host, unlock)
    end
    if info.kind == "editor" and (ctx.breaking or info.state == "hung") then
        return string.format("%s is held by nvim (pid %s) — cancel the task there, or break the lock "
            .. "without killing it: %s", what, pid, unlock)
    end
    if info.state == "hung" then
        return string.format("%s is locked by a hung %s (pid %s, no heartbeat for %s) — recover with: %s",
            what, holder, pid, M.age_text(info.age), (ctx.command or "lw <command>") .. " --break-locks")
    end
    if ctx.style == "workspace" then
        return string.format("workspace busy: %s (pid %s on %s, %s) — retry when it finishes",
            M.operation_of(info) or "an operation", pid, tostring(info.host or "?"), M.age_text(info.age))
    end
    if ctx.style == "nuke" then
        return string.format("a build is running in %s (pid %s) — wait for it, or stop it%s", what, pid,
            ctx.command and (" (" .. ctx.command .. " --break-locks)") or "")
    end
    return string.format("%s is in use by %s (pid %s), %s ago — wait for it to finish, or stop it"
        .. (ctx.command and (" (" .. ctx.command .. " --break-locks)") or ""),
        what, holder, pid, M.age_text(info.age))
end

return M
