--- loomworks/op_lock.lua — the workspace operation lock O (spec §19.3).
---
--- `<root>/.nvim/loomworks.op.lock`, the build-directory lock primitive (O_EXCL
--- create + heartbeat, common record of §19.5) taken by every operation that
--- writes more than one of the three workspace files, or removes a workspace
--- file or a build tree as part of a larger change: publish (incl. per item),
--- import, pull, cache-propagating renames, deletions that remove build
--- directories, reset, nuke, `lw trust --discard`. Fail-fast; a dead holder is
--- reclaimed at once, a hung one only with `--break-locks` (loomworks.lock_break).
---
--- Lock order (§19.3): O is taken before any build-directory (B), device (D)
--- or file-save (F) lock. Re-entrant within a process: an operation that
--- already holds O (the CLI's `lw reset` around the workspace's deletion) can
--- call another that takes it; the lockfile is released with the outermost
--- holder.

local build_lock = require("loomworks.build_lock")

local M = {}

local function pack(...) return { n = select("#", ...), ... } end

--- Held operation locks of this process, by normalized lockfile path:
--- { handle, refs }.
local _held = {}

local function norm(p)
    p = tostring(p):gsub("\\", "/"):gsub("/+$", "")
    if package.config:sub(1, 1) == "\\" then p = p:lower() end
    return p
end

--- The cross-process lock modules a host uses: `deps.locks` when injected
--- (tests with a fake root), `INERT` for a root that does not exist, else this
--- module and loomworks.build_lock.
--- @param deps table|nil
--- @param root? string
--- @return { op: table, build: table }
function M.locks(deps, root)
    if deps and deps.locks then return deps.locks end
    -- A root that does not exist on disk (a test's fake `/root`) gets inert
    -- locks: a lock must never create directories or files there.
    if root and not (vim.uv or vim.loop).fs_stat(root) then return M.INERT end
    return { op = M, build = build_lock }
end

--- Locks that hold nothing (see `locks`).
M.INERT = {
    fake = true,
    op = {
        acquire = function() return { inert = true } end,
        release = function() end,
        reclaimed_line = function() return "" end,
        held = function() return false end,
    },
    build = {
        acquire = function(dir) return { path = tostring(dir) .. ".loomworks-lock", inert = true } end,
        held_by_me = function() return false end,
        release = function() end,
    },
}

--- The operation lock's path for a workspace root.
--- @param root string
--- @return string
function M.path(root)
    return (tostring(root):gsub("\\", "/"):gsub("/+$", "")) .. "/.nvim/loomworks.op.lock"
end

--- The busy-message context of the operation lock.
--- @return table
function M.ctx()
    local lb = require("loomworks.lock_break")
    return { what = "the workspace", command = lb.command, unlock = "--workspace", style = "workspace" }
end

--- Acquire the operation lock of `root` for `operation`. Returns a token, or
--- nil + the refusal message + the holder info. A token whose acquisition
--- reclaimed a dead holder's lock carries that record as `reclaimed`.
--- @param root string
--- @param operation string
--- @return table|nil token, string|nil message, table|nil info
function M.acquire(root, operation)
    local path = M.path(root)
    local key = norm(path)
    local e = _held[key]
    if e and not e.handle.released then
        e.refs = e.refs + 1
        return { key = key, entry = e, nested = true }
    end
    local h, msg, info = require("loomworks.lock_break").acquire(function()
        return build_lock.try_acquire_path(path, operation)
    end, M.ctx())
    if not h then return nil, msg, info end
    e = { handle = h, refs = 1 }
    _held[key] = e
    return { key = key, entry = e, reclaimed = h.reclaimed }
end

--- Release a token from `acquire` (idempotent). The lockfile goes with the
--- outermost holder.
--- @param token table|nil
function M.release(token)
    if not token or token.released then return end
    token.released = true
    local e = token.entry
    e.refs = e.refs - 1
    if e.refs <= 0 then
        build_lock.release(e.handle)
        if _held[token.key] == e then _held[token.key] = nil end
    end
end

--- Release every operation lock this process holds (process exit: a `die`
--- inside a guarded operation ends the process without unwinding).
function M.release_all()
    for key, e in pairs(_held) do
        build_lock.release(e.handle)
        _held[key] = nil
    end
end

--- Does this process hold the operation lock of `root`?
--- @param root string
--- @return boolean
function M.held(root)
    local e = _held[norm(M.path(root))]
    return e ~= nil and not e.handle.released
end

--- The operation lock's info (record + `age`/`stale`), or nil when free.
--- @param root string
--- @return table|nil
function M.read(root)
    return build_lock.read_path(M.path(root))
end

--- The line reporting a reclaimed operation lock.
--- @param rec table the reclaimed record
--- @return string
function M.reclaimed_line(rec)
    local lock_record = require("loomworks.lock_record")
    return string.format("reclaimed the workspace operation lock from %s (pid %s), which had stopped",
        lock_record.holder_text(rec), tostring(rec.pid or "?"))
end

--- Wrap `class[name]` so it runs holding the operation lock of its workspace
--- (`ws_of(self)`). A refused acquisition returns `false, message` (after
--- `ws:_op_lock_refused`) without running the method; the lock is released
--- when the method returns or raises.
--- @param class table
--- @param name string
--- @param operation string
--- @param ws_of fun(self): table|nil
function M.guard(class, name, operation, ws_of)
    local impl = class[name]
    assert(type(impl) == "function", "op_lock.guard: no method " .. name)
    class[name] = function(self, ...)
        local ws = ws_of(self)
        if not ws or not ws.root or not ws._op_lock then return impl(self, ...) end
        local tok, msg = ws:_op_lock(operation)
        if not tok then return false, msg end
        local r = pack(pcall(impl, self, ...))
        ws:_op_unlock(tok)
        if not r[1] then error(r[2], 0) end
        return (table.unpack or unpack)(r, 2, r.n)
    end
end

return M
