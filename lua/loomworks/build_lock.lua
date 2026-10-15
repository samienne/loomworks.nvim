--- loomworks/build_lock.lua — cross-process advisory lock for build directories.
---
--- Serializes configure/build/clean across separate processes (editor + CLI,
--- or two CLIs) that share a build directory — advisory, host-provided
--- exclusion. The primitive is an O_EXCL lockfile
--- (`uv.fs_open(path, "wx")`): an atomic create-if-absent that works across
--- processes, unlike a `building=true` flag in a JSON file (a read-check-write
--- of a shared file is a TOCTOU race — two processes can both see "free").
---
--- The lockfile holds the common lock record (loomworks.lock_record, spec
--- §19.5) and the holder heartbeats its mtime on a timer. A would-be acquirer
--- that finds the lock held classifies the holder: a dead one (same host, no
--- process with that id and start time) is reclaimed at once, as is a stale
--- one on another host or one whose start time cannot be checked; a live one
--- refuses (fail-fast); a hung one (same host, alive, heartbeat stale) is NOT
--- reclaimed — `--break-locks` recovers it (loomworks.lock_break). The
--- path-level API is shared with the device lock (§18.7) and the workspace
--- operation lock (§19.3).

local uv = vim.uv or vim.loop
local lock_record = require("loomworks.lock_record")

local M = {}

--- Heartbeat cadence and the staleness window (a few missed beats). A build
--- that is genuinely running keeps its mtime fresh, so only a crashed/hung
--- holder ever crosses the threshold.
M.HEARTBEAT_MS = 5000
M.STALE_SECONDS = 20

local function lock_path(build_dir) return build_dir .. ".loomworks-lock" end
M.lock_path = lock_path

--- Locks this process holds, by normalized lockfile path (for the phase
--- update `set_operation`).
local _held = {}

local function held_key(path)
    local p = path:gsub("\\", "/")
    if package.config:sub(1, 1) == "\\" then p = p:lower() end
    return p
end

--- Read the lock info of a lockfile path (the record plus computed
--- `age`/`stale`), or nil when unlocked. Path-level API shared with the
--- device lock (spec §18.7).
--- @param path string lockfile path
--- @return table|nil
function M.read_path(path)
    return lock_record.read(path, M.STALE_SECONDS)
end

--- Read the lock info for a build dir (with computed `age`/`stale`), or nil
--- when unlocked.
--- @param build_dir string
--- @return table|nil
function M.read(build_dir)
    return M.read_path(lock_path(build_dir))
end

--- Write a fresh lock file exclusively. Returns the written record on
--- success, else nil + the fs error (e.g. "EEXIST").
--- @return table|nil record, string|nil err
local function create_locked(path, action, extra)
    local fd, err = uv.fs_open(path, "wx", tonumber("644", 8))
    if not fd then return nil, err end
    local rec = lock_record.new(action, extra)
    local body = vim.json.encode(rec)
    uv.fs_write(fd, body)
    uv.fs_close(fd)
    return rec
end

--- Try once to take the lockfile at `path` (path-level API shared with the
--- device lock, spec §18.7, and the operation lock, §19.3). A holder that is
--- dead, or stale where it cannot be checked (spec §19.5), is reclaimed — only
--- if its record is still the one judged (nonce); the handle then carries
--- that holder's record as `handle.reclaimed` (with `state`), from which the
--- caller recovers the interrupted operation's state (§19.5 step 5) and the
--- device lock reads a leftover program (§18.7).
--- Returns a handle, or `(nil, info)` with the holder's lock info, classified
--- (`info.state` = "live" | "hung" | …).
--- @param path string
--- @param action string the operation recorded in the lockfile
--- @param extra? table extra fields recorded in the lockfile
--- @return table|nil handle, table|nil holder_info
function M.try_acquire_path(path, action, extra)
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent then pcall(vim.fn.mkdir, parent, "p") end

    local rec = create_locked(path, action, extra)
    local info, reclaimed
    local tries = 0
    while not rec and tries < 3 do
        tries = tries + 1
        info = M.read_path(path)
        if not info then
            -- Released between our create and read: try again.
            rec = create_locked(path, action, extra)
        else
            info.state = lock_record.classify(info)
            if not lock_record.RECLAIMABLE[info.state] then break end
            -- Atomic, nonce-checked reclaim: only the process whose rename
            -- wins, of the record it judged, removes it; a racing reclaimer
            -- then re-hits the fresh lock.
            if lock_record.reclaim(path, info) then
                rec = create_locked(path, action, extra)
                if rec then reclaimed = info end
            end
        end
    end
    if not rec then return nil, info or {} end

    local handle = { path = path, record = rec, reclaimed = reclaimed }
    local timer = uv.new_timer()
    timer:start(M.HEARTBEAT_MS, M.HEARTBEAT_MS, function()
        if handle.released then return end
        -- A record that is no longer ours (reclaimed while this process was
        -- suspended, or forced off by `lw unlock --force`) is never touched:
        -- the holder has lost the lock.
        if not lock_record.still_ours(path, rec) then
            handle.lost = true
            pcall(function() timer:stop() end)
            return
        end
        pcall(uv.fs_utime, path, os.time(), os.time())
    end)
    handle.timer = timer
    _held[held_key(path)] = handle
    return handle
end

--- Merge `fields` into a HELD lock's record and rewrite its lockfile (a
--- `vim.NIL` value removes the field). A released handle is a no-op: the
--- lockfile may belong to another process by now. Best-effort — a failed
--- write leaves the previous record.
--- @param handle table|nil
--- @param fields table
function M.update_record(handle, fields)
    if not handle or handle.released or not handle.record then return end
    for k, v in pairs(fields or {}) do
        if v == vim.NIL then handle.record[k] = nil else handle.record[k] = v end
    end
    local body = vim.json.encode(handle.record)
    -- "r+" (never "w"): a lockfile that vanished (forced off by `lw unlock`)
    -- is not recreated behind another process's back.
    local fd = uv.fs_open(handle.path, "r+", tonumber("644", 8))
    if not fd then return end
    pcall(uv.fs_ftruncate, fd, 0)
    pcall(uv.fs_write, fd, body, 0)
    uv.fs_close(fd)
end

--- Acquire the lock for `build_dir`. Fail-fast: returns a handle on
--- success, or `(nil, reason, info)` if a live or hung process holds it
--- (`info.state`, spec §19.5). A dead holder's lock is reclaimed
--- automatically (`handle.reclaimed`).
--- @param build_dir string
--- @param action "build"|"configure"|"clean"|string
--- @param ctx? table busy-message context (lock_record.busy_message)
--- @return table|nil handle, string|nil reason, table|nil info
function M.acquire(build_dir, action, ctx)
    local h, info = M.try_acquire_path(lock_path(build_dir), action)
    if not h then
        ctx = ctx or { what = "build directory " .. build_dir }
        return nil, lock_record.busy_message(info, ctx), info
    end
    h.build_dir = build_dir
    return h
end

--- Record the step a held build-directory lock is in (spec §19.5: a holder
--- rewrites the operation when it moves from configure to build, so recovery
--- knows which step was interrupted). No-op unless this process holds the
--- lock of `build_dir`.
--- @param build_dir string|nil
--- @param operation string
function M.set_operation(build_dir, operation)
    if not build_dir then return end
    local h = _held[held_key(lock_path(build_dir))]
    if not h or h.released or (h.record and h.record.operation == operation) then return end
    M.update_record(h, { operation = operation, action = operation })
end

--- Release a held lock.
--- @param handle table|nil
function M.release(handle)
    -- Idempotent: a second release (an exit hook after an explicit release)
    -- must never unlink a lockfile another process has since created — nor
    -- one that replaced ours (reclaimed while we were suspended, §19.5).
    if not handle or handle.released then return end
    handle.released = true
    if handle.timer then
        pcall(function() handle.timer:stop(); handle.timer:close() end)
    end
    local key = held_key(handle.path)
    if _held[key] == handle then _held[key] = nil end
    if lock_record.still_ours(handle.path, handle.record) then
        pcall(uv.fs_unlink, handle.path)
    end
end

--- Force-remove the lock for a build dir (`lw unlock --force`). Removes the
--- record without stopping its holder.
--- @param build_dir string
--- @return boolean removed true if a lock file was present
function M.force(build_dir)
    return M.force_path(lock_path(build_dir))
end

--- Force-remove a lockfile by path: exactly that file, only when it is a
--- regular file (never a link or a directory).
--- @param path string
--- @return boolean removed
function M.force_path(path)
    local st = uv.fs_lstat(path)
    if not st or st.type ~= "file" then return false end
    return uv.fs_unlink(path) and true or false
end

--- Remove the lockfile at `path` if its holder is reclaimable (dead, or stale
--- where it cannot be checked, spec §19.5) and its record is still the one
--- judged. Returns the removed record, or nil + the classified info of a
--- holder that is not reclaimable (nil, nil: no lock).
--- @param path string
--- @return table|nil removed, table|nil info
function M.reclaim_path(path)
    local info = M.read_path(path)
    if not info then return nil, nil end
    info.state = lock_record.classify(info)
    if not lock_record.RECLAIMABLE[info.state] then return nil, info end
    if lock_record.reclaim(path, info) then return info end
    return nil, M.read_path(path)
end

return M
