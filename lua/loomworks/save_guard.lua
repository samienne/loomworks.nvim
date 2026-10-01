--- loomworks/save_guard.lua — concurrent-writer guard for the `.nvim/` state
--- files (spec §2.7).
---
--- Several processes write the same working copy and build cache: the editor,
--- CLI invocations, a background process, and older loomworks versions. A save
--- must never blindly overwrite a file another process changed since this one
--- last read it. This module holds the host-neutral pieces; the policy (merge
--- the cache, refuse the working copy) lives in `Workspace:_save_cache` /
--- `Workspace:_save_user`.
---
---   * Disk baseline — the EXACT bytes a process last read or wrote. Content,
---     not mtime/size (coarse on some file systems, blind to same-size
---     rewrites) and not a counter stored in the file (an older version
---     rewrites `_meta` without it). The comparison is a plain string compare.
---   * Write lock — `<file>.lock`, an O_EXCL create held only around the
---     re-read + merge + write (milliseconds), carrying the common lock record
---     (§19.5). No heartbeat: a dead holder's lockfile, or one older than
---     `STALE_SECONDS` whose holder cannot be checked, is reclaimed by an
---     atomic, nonce-checked rename (as `build_lock.lua` does). A save that
---     cannot get the lock within `WAIT_MS` proceeds without it (the stale
---     check still applies) rather than lose the change.
---   * Cache merge — per entry of the keyed maps; see `merge_cache`.
---   * Version stamp — `_meta.written_by`; see `version` / `newer_writer`.
---
--- Uses no boot module (the bundle runs under hosts back to v0.1.2).

local M = {}

local function uv() return vim.uv or vim.loop end

--- Lockfile staleness window (seconds; mtime granularity is one second). Far
--- longer than any save, so only a crashed holder ever crosses it.
M.STALE_SECONDS = 5
--- How long a save waits for a live holder before writing without the lock.
M.WAIT_MS = 2000

--- The cache's keyed maps merged per entry (spec §2.7).
M.CACHE_MAPS = { "build_dirs", "deploy_state", "device_sync" }

-- ---------------------------------------------------------------------------
-- Writer version
-- ---------------------------------------------------------------------------

local _version -- nil = not computed yet, false = unknown

--- This loomworks version, as recorded in `_meta.written_by`: the running
--- release (`lua-<ver>` bundle root), else — a development source or the
--- editor plugin — the newest released version in `CHANGELOG.md`, with a
--- `+dev` suffix while an `## Unreleased` entry sits above it. nil when
--- neither is known.
--- @return string|nil
function M.version()
    if _version == nil then
        local ok, v = pcall(function()
            local rn = require("loomworks.release_notice")
            local running = rn.running_version()
            if running then return running end
            local text = rn.read_text()
            if not text then return nil end
            local unreleased = false
            for line in text:gmatch("[^\r\n]+") do
                local head = line:match("^##%s+(.-)%s*$")
                if head then
                    if head:lower():match("^unreleased") then
                        unreleased = true
                    else
                        local rel = head:match("^[vV]?(%d+%.%d+%.%d+[%w%.%-]*)")
                        if rel then return unreleased and (rel .. "+dev") or rel end
                    end
                end
            end
            return nil
        end)
        _version = (ok and type(v) == "string") and v or false
    end
    return _version or nil
end

--- Override the detected version (tests).
--- @param v string|nil
function M._set_version(v) _version = v or false end

local function comparable(v)
    if type(v) ~= "string" then return nil end
    return require("loomworks.release_notes").normalize((v:gsub("%+.*$", "")))
end

--- Is `a` a strictly newer version than `b`? Build metadata (`+dev`) is
--- ignored; an unparsable side is never newer.
--- @param a string|nil
--- @param b string|nil
--- @return boolean
function M.is_newer(a, b)
    local na, nb = comparable(a), comparable(b)
    if not na or not nb then return false end
    return require("loomworks.release_notes").compare(na, nb) > 0
end

--- The `_meta` stamp members every guarded write records.
--- @return table
function M.stamp()
    return { written_by = M.version() }
end

local _warned = {}

--- Reset the warn-once record (tests).
function M._reset_warnings() _warned = {} end

--- The one-time "written by a newer loomworks" warning for a file whose
--- schema this version understands, or nil (not newer, unknown, or already
--- warned in this process for this file and version).
--- @param path string the file (identifies it in the warn-once record)
--- @param label string how the message names the file
--- @param meta table|nil the file's `_meta`
--- @return string|nil
function M.newer_writer_warning(path, label, meta)
    local by = type(meta) == "table" and meta.written_by or nil
    local own = M.version()
    if not M.is_newer(by, own) then return nil end
    local key = tostring(path) .. "\0" .. by
    if _warned[key] then return nil end
    _warned[key] = true
    return label .. " was written by loomworks " .. by .. ", newer than this loomworks "
        .. own .. " — update loomworks"
end

--- The refusal message for a file whose schema is newer than this version's.
--- @param label string how the message names the file
--- @param meta table the file's `_meta`
--- @param own_schema number this version's schema for the file
--- @return string
function M.newer_schema_message(label, meta, own_schema)
    local by = type(meta.written_by) == "string" and meta.written_by or nil
    local own = M.version()
    return label .. " was written by "
        .. (by and ("loomworks " .. by) or "a newer loomworks")
        .. " (schema " .. tostring(meta.version) .. "), newer than this loomworks"
        .. (own and (" " .. own) or "") .. " (schema " .. tostring(own_schema)
        .. ") — update loomworks; the file was left unchanged"
end

--- Is a file's schema (`_meta.version`) newer than `own_schema`?
--- @param meta table|nil
--- @param own_schema number
--- @return boolean
function M.schema_newer(meta, own_schema)
    return type(meta) == "table" and type(meta.version) == "number"
        and meta.version > own_schema
end

-- ---------------------------------------------------------------------------
-- Write lock
-- ---------------------------------------------------------------------------

--- Files whose save lock a transaction (loomworks.txn, spec §19.4) holds for
--- its whole commit: a save inside it re-enters the lock.
local _txn_held = {}

local function held_key(path)
    local p = tostring(path):gsub("\\", "/")
    if package.config:sub(1, 1) == "\\" then p = p:lower() end
    return p
end

--- Mark `path`'s save lock as held by the active transaction.
--- @param path string
function M._hold(path) _txn_held[held_key(path)] = true end

--- Clear `_hold`.
--- @param path string
function M._unhold(path) _txn_held[held_key(path)] = nil end

--- Take the save lock for `path` (`<path>.lock`). The lockfile holds the
--- common lock record (loomworks.lock_record, spec §19.5); its nonce is the
--- handle's token. Waits up to `opts.wait_ms` (default `WAIT_MS`) for a live
--- holder; a dead holder's lock — or one older than `STALE_SECONDS` whose
--- holder cannot be checked (another host, an older version's token) — is
--- reclaimed; a hung one (alive) is not, so the save then proceeds without the
--- lock. Returns a handle, or nil when the lock is still held after waiting.
--- @param path string the guarded file
--- @param opts? { wait_ms?: number }
--- @return table|nil handle `{ path, token }`
function M.lock(path, opts)
    if _txn_held[held_key(path)] then return { path = path .. ".lock", txn = true, released = false } end
    local u = uv()
    local lock_record = require("loomworks.lock_record")
    local lock_path = path .. ".lock"
    local wait_ms = (opts and opts.wait_ms) or M.WAIT_MS
    local deadline = u.hrtime() + wait_ms * 1e6
    local rec = lock_record.new("save")
    local body = vim.json.encode(rec)
    while true do
        local fd, _, code = u.fs_open(lock_path, "wx", 420) -- 0644, exclusive create
        if fd then
            u.fs_write(fd, body, 0)
            u.fs_close(fd)
            return { path = lock_path, token = rec.lock_nonce, record = rec }
        end
        -- Anything but "exists" (no directory, no permission) cannot be waited
        -- out: save without the lock.
        if code ~= "EEXIST" then return nil end
        local info = lock_record.read(lock_path, M.STALE_SECONDS)
        if info then
            info.state = lock_record.classify(info)
            -- Atomic, nonce-checked reclaim: only the process whose rename
            -- wins removes the record it judged.
            if lock_record.RECLAIMABLE[info.state] then lock_record.reclaim(lock_path, info) end
        end
        -- (no info: the holder just released it — retry at once)
        if u.hrtime() >= deadline then return nil end
        if info then u.sleep(5) end
    end
end

--- Release a lock taken by `lock`. Only a lockfile that still carries this
--- handle's token is removed (a holder whose lock was reclaimed must not
--- remove its successor's). Idempotent.
--- @param handle table|nil
function M.unlock(handle)
    if not handle or handle.released or handle.txn then return end
    handle.released = true
    if require("loomworks.lock_record").still_ours(handle.path, { lock_nonce = handle.token }) then
        pcall(uv().fs_unlink, handle.path)
    end
end

-- ---------------------------------------------------------------------------
-- Cache merge
-- ---------------------------------------------------------------------------

local function encode(v) return require("loomworks.io").encode_sorted(v) end

--- The per-entry serialization of a cache's keyed maps — what "this process
--- changed an entry since its last sync" is measured against.
--- @param cache table serialized cache (`Workspace:_serialize_cache()` shape)
--- @return table<string, table<string, string>>
function M.snapshot_cache(cache)
    local snap = {}
    for _, map in ipairs(M.CACHE_MAPS) do
        local enc = {}
        if type(cache[map]) == "table" then
            for k, v in pairs(cache[map]) do enc[k] = encode(v) end
        end
        snap[map] = enc
    end
    return snap
end

--- Merge this process's cache (`ours`) into the cache on disk (`theirs`) per
--- entry of the keyed maps (spec §2.7): an entry whose serialization differs
--- from `snapshot` (this process changed, added or removed it since its last
--- sync with disk) comes from `ours`; every other entry, and every top-level
--- member this version does not write, comes from `theirs`. `_meta` is ours
--- (this write's stamp). Every keyed map is present in the result (possibly
--- empty) so a reconciliation applies removals too.
--- @param ours table
--- @param theirs table
--- @param snapshot table|nil from `snapshot_cache`; nil = nothing changed here
--- @return table merged
function M.merge_cache(ours, theirs, snapshot)
    local out = {}
    for k, v in pairs(theirs) do out[k] = v end
    out._meta = ours._meta
    for _, map in ipairs(M.CACHE_MAPS) do
        local o = type(ours[map]) == "table" and ours[map] or {}
        local t = type(theirs[map]) == "table" and theirs[map] or {}
        local s = (snapshot and snapshot[map]) or {}
        local res = {}
        for k, v in pairs(t) do res[k] = v end
        local keys = {}
        for k in pairs(o) do keys[k] = true end
        for k in pairs(s) do keys[k] = true end
        for k in pairs(keys) do
            local enc = o[k] ~= nil and encode(o[k]) or nil
            if enc ~= s[k] then res[k] = o[k] end
        end
        out[map] = res
    end
    return out
end

return M
