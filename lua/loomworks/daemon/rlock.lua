--- loomworks/daemon/rlock.lua — the runtime lock R, `<root>/.nvim/loomworks.daemon.lock`
--- (spec §19.2).
---
--- It designates the one runtime of a workspace. Same primitive as the
--- build-directory lock (§16.6, loomworks.build_lock): an exclusive create and
--- an mtime heartbeat (about 5 s), the common lock record of §19.5
--- (`{ pid, host, start_time, lock_nonce, kind, operation, started_at }`)
--- plus `mode` (`daemon` | `attached`), `command` (an attached run's) and
--- `host_version`. Dead and hung holders are handled per §19.5
--- (loomworks.lock_record): a dead one is reclaimed at once, a hung one never
--- automatically.
---
--- A daemon acquires R before binding its endpoint and holds it for its
--- lifetime; one whose record was replaced while it was suspended has lost
--- authority and exits (§19.2). R is the outermost lock of the order
--- R → O → B → D → F (§19.3).

local build_lock = require("loomworks.build_lock")
local lock_record = require("loomworks.lock_record")
local paths = require("loomworks.daemon.paths")

local M = {}

--- @param root string
--- @return string
function M.path(root) return paths.lock_path(root) end

--- The lock's record with `age`, `stale` and the classified holder `state`
--- (dead | live | hung | stale | stale_foreign), or nil when free.
--- @param root string
--- @return table|nil
function M.read(root)
    local info = build_lock.read_path(M.path(root))
    if not info then return nil end
    info.state = lock_record.classify(info)
    return info
end

--- Try once to acquire R for a daemon (`mode = "daemon"`). A dead holder's
--- lock is reclaimed (`handle.reclaimed`). Returns the handle, or nil + the
--- classified holder info.
--- @param root string
--- @param opts? { mode?: string, command?: string }
--- @return table|nil handle, table|nil info
function M.try_acquire(root, opts)
    opts = opts or {}
    local extra = {
        mode = opts.mode or "daemon",
        command = opts.command,
        host_version = require("loomworks.daemon.version").identity(),
    }
    return build_lock.try_acquire_path(M.path(root), opts.operation or (extra.mode == "daemon" and "daemon"
        or tostring(opts.command or "attached")), extra)
end

--- Does `handle` still carry the lock (its own record, not replaced)?
--- @param handle table|nil
--- @return boolean
function M.still_ours(handle)
    if not handle or handle.released or handle.lost then return false end
    return lock_record.still_ours(handle.path, handle.record)
end

--- Release a held R (idempotent; never removes a record that replaced ours).
--- @param handle table|nil
function M.release(handle)
    build_lock.release(handle)
end

--- How the holder is named in messages.
--- @param info table
--- @return string
function M.holder_text(info)
    if info.mode == "attached" then
        return "lw " .. tostring(info.command or lock_record.operation_of(info) or "")
    end
    if info.kind == "daemon" or info.mode == "daemon" then return "the workspace daemon" end
    return lock_record.holder_text(info)
end

return M
