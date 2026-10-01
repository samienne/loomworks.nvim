--- loomworks/txn.lua — crash-consistent multi-file commits (spec §19.4).
---
--- A multi-file operation (one holding the workspace operation lock O,
--- loomworks.op_lock) runs inside a transaction: every write of one of the
--- three workspace files is STAGED to `<file>.txn-<id>` (flushed) instead of
--- replacing the target, and reads of a staged file in this process see the
--- staged bytes. `finish` then commits, holding the F locks of the three files
--- (taken at `begin`, in the order of §19.3):
---
---   1–2. check + stage   (done by the saves themselves, under the F locks)
---   3.   commit point    atomic write of `.nvim/loomworks.txn.json`
---   4.   apply           per entry in file order: target → `.bak` (as an
---                        ordinary save does), staged → target; flush the dir
---   5.   finish          remove the journal, release the locks
---
--- A one-file commit needs no journal (a rename is atomic). A crash leaves the
--- old state (+ stray staged files, removed by the next O holder), or a
--- journal that `recover` rolls forward under O to the new state; a journal
--- whose targets match neither hash, or whose staged file is missing, refuses
--- the workspace (`lw unlock --journal` discards it). Build-tree removal is not
--- journalled (§5.7 crash rule).
---
--- The writes are intercepted in loomworks.io (`write_file_atomic` /
--- `read_file` consult `io._txn_hook`), so every save path — the working
--- copy, the build cache, the published snapshot — takes part unchanged.

local M = {}

local function uv() return vim.uv or vim.loop end

--- The workspace files in commit order (§19.3), relative to the root.
M.FILES = { "loomworks.json", ".nvim/loomworks.user.json", ".nvim/loomworks.cache.json" }
M.JOURNAL = ".nvim/loomworks.txn.json"

--- Test seam: the commit step at which to simulate a crash (`os.exit`), one
--- of "staged", "journal", "apply1", "apply2", "apply3", "finish".
M._crash_at = nil

local function crash_point(step)
    if M._crash_at == step then
        pcall(function() io.stdout:flush() end)
        os.exit(77)
    end
end

local function norm(p)
    p = tostring(p):gsub("\\", "/"):gsub("/+$", "")
    if package.config:sub(1, 1) == "\\" then p = p:lower() end
    return p
end

local function root_of(root) return (tostring(root):gsub("\\", "/"):gsub("/+$", "")) end

local function sha(s) return s and vim.fn.sha256(s) or nil end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Write `bytes` to `path` and flush it to stable storage.
local function write_flushed(path, bytes)
    local fd, err = uv().fs_open(path, "w", 438)
    if not fd then return false, err end
    local _, werr = uv().fs_write(fd, bytes, 0)
    pcall(uv().fs_fsync, fd)
    uv().fs_close(fd)
    if werr then pcall(uv().fs_unlink, path); return false, werr end
    return true
end

--- Rename with the Windows sharing-violation retry of io.write_file_atomic.
local function rename(from, to)
    local last
    for i = 1, 5 do
        local ok, err, code = uv().fs_rename(from, to)
        if ok then return true end
        last = err
        if code ~= "EACCES" and code ~= "EPERM" then break end
        if i < 5 then uv().sleep(50) end
    end
    return false, last
end

--- Flush a directory's entries (POSIX; a no-op where a directory cannot be
--- opened, Windows).
local function flush_dir(dir)
    pcall(function()
        local fd = uv().fs_open(dir, "r", 0)
        if fd then pcall(uv().fs_fsync, fd); uv().fs_close(fd) end
    end)
end

local function abs(root, rel) return root_of(root) .. "/" .. rel end

local function staged_path(target, id) return target .. ".txn-" .. id end

--- The active transaction of this process (one at a time), or nil.
local _active

--- Is a transaction active in this process?
--- @return boolean
function M.active() return _active ~= nil end

local function install_hook(t)
    local io_mod = require("loomworks.io")
    io_mod._txn_hook = {
        write = function(path, bytes, opts)
            local e = t.by_norm[norm(path)]
            if not e then return false end
            local ok, err = write_flushed(staged_path(e.target, t.id), bytes)
            if not ok then return true, false, "stage: " .. tostring(err) end
            if not e.staged then
                e.staged = true
                e.sha_old = sha(read(e.target))
                t.order_staged[#t.order_staged + 1] = e
            end
            e.sha_new = sha(bytes)
            e.bytes = bytes
            e.backup = not (opts and opts.backup == false)
            crash_point("staged")
            return true, true, nil
        end,
        read = function(path)
            local e = t.by_norm[norm(path)]
            if e and e.staged then return true, e.bytes end
            return false
        end,
    }
end

local function remove_hook()
    require("loomworks.io")._txn_hook = nil
end

--- Begin a transaction for `operation` on `root` (re-entrant: a nested begin
--- joins the active one). Takes the F locks of the three files in order.
--- @param root string
--- @param operation string
--- @return table txn
function M.begin(root, operation)
    if _active then
        _active.refs = _active.refs + 1
        return _active
    end
    local save_guard = require("loomworks.save_guard")
    local t = {
        root = root_of(root), operation = operation, refs = 1,
        id = require("loomworks.lock_record").new_nonce(),
        by_norm = {}, entries = {}, order_staged = {}, flocks = {},
    }
    for i, rel in ipairs(M.FILES) do
        local target = abs(root, rel)
        local e = { rel = rel, target = target, index = i }
        t.entries[i] = e
        t.by_norm[norm(target)] = e
        -- F locks for the whole commit; the saves inside re-enter them.
        t.flocks[#t.flocks + 1] = save_guard.lock(target)
        save_guard._hold(target)
    end
    _active = t
    install_hook(t)
    return t
end

local function release(t)
    local save_guard = require("loomworks.save_guard")
    remove_hook()
    for _, e in ipairs(t.entries) do save_guard._unhold(e.target) end
    for _, l in ipairs(t.flocks) do save_guard.unlock(l) end
    t.flocks = {}
    if _active == t then _active = nil end
end

--- Abandon the outermost transaction: remove its staged files, write nothing.
--- @param t table|nil
function M.abort(t)
    if not t or t ~= _active then return end
    t.refs = t.refs - 1
    if t.refs > 0 then return end
    for _, e in ipairs(t.order_staged) do pcall(uv().fs_unlink, staged_path(e.target, t.id)) end
    release(t)
end

--- Abandon whatever transaction is active (process exit mid-operation):
--- its staged files are removed and its save locks released; nothing is
--- applied.
function M.abandon()
    local t = _active
    if not t then return end
    t.refs = 1
    M.abort(t)
end

--- The journal record for `t`'s staged entries (in file order).
local function journal_record(t, staged)
    local entries = {}
    for _, e in ipairs(staged) do
        entries[#entries + 1] = { file = e.rel, action = "replace", sha256_new = e.sha_new,
            sha256_old = e.sha_old }
    end
    local lock_record = require("loomworks.lock_record")
    return { id = t.id, operation = t.operation, pid = lock_record.this_pid(),
        host = lock_record.this_host(), written_by = require("loomworks.save_guard").version(),
        entries = entries }
end

--- Apply one staged entry: target → .bak (when the save asked for one),
--- staged → target.
local function apply(e, id)
    if e.backup and uv().fs_stat(e.target) then rename(e.target, e.target .. ".bak") end
    return rename(staged_path(e.target, id), e.target)
end

--- Finish (commit) the outermost transaction. Returns true, or false + err
--- (nothing applied when the journal could not be written).
--- @param t table|nil
--- @return boolean ok, string|nil err
function M.finish(t)
    if not t or t ~= _active then return true end
    t.refs = t.refs - 1
    if t.refs > 0 then return true end
    local staged = {}
    for _, e in ipairs(t.entries) do if e.staged then staged[#staged + 1] = e end end
    -- Fencing: commit only while this process still holds the workspace
    -- operation lock with its own record. A holder whose lock was reclaimed
    -- (suspended past the heartbeat, `lw unlock --force`) has lost authority
    -- and writes nothing.
    if #staged > 0 and not require("loomworks.op_lock").still_held(t.root) then
        for _, e in ipairs(staged) do pcall(uv().fs_unlink, staged_path(e.target, t.id)) end
        release(t)
        return false, "lost the workspace operation lock before committing — nothing was written"
    end
    local ok, err = true, nil
    if #staged == 1 then
        ok, err = apply(staged[1], t.id)
    elseif #staged > 1 then
        local jpath = abs(t.root, M.JOURNAL)
        local tmp = jpath .. ".tmp"
        local jok, jerr = write_flushed(tmp, vim.json.encode(journal_record(t, staged)))
        if jok then jok, jerr = rename(tmp, jpath) end
        if not jok then
            pcall(uv().fs_unlink, tmp)
            for _, e in ipairs(staged) do pcall(uv().fs_unlink, staged_path(e.target, t.id)) end
            release(t)
            return false, "could not write the commit journal: " .. tostring(jerr)
        end
        flush_dir(abs(t.root, ".nvim"))
        crash_point("journal")
        for n, e in ipairs(staged) do
            local aok, aerr = apply(e, t.id)
            if not aok then ok, err = false, "commit: " .. tostring(aerr) end
            crash_point("apply" .. n)
        end
        flush_dir(t.root)
        flush_dir(abs(t.root, ".nvim"))
        crash_point("finish")
        -- A failed apply keeps the journal: the next O holder completes it.
        if ok then pcall(uv().fs_unlink, jpath) end
    end
    release(t)
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Recovery
-- ---------------------------------------------------------------------------

--- Read and validate the journal of `root`. Returns nil (no journal), or the
--- journal table, or false + the reason it is not a valid journal.
--- @param root string
--- @return table|false|nil journal, string|nil why
function M.read_journal(root)
    local jpath = abs(root, M.JOURNAL)
    local st = uv().fs_lstat(jpath)
    if not st then return nil end
    if st.type ~= "file" then return false, "is not a regular file" end
    local ok, j = pcall(vim.json.decode, read(jpath) or "")
    if not ok or type(j) ~= "table" then return false, "is not a journal (not JSON)" end
    if type(j.id) ~= "string" or not j.id:match("^%x+$") or #j.id > 64 then
        return false, "has no valid id"
    end
    if type(j.entries) ~= "table" or #j.entries == 0 then return false, "has no entries" end
    local known = {}
    for _, rel in ipairs(M.FILES) do known[rel] = true end
    local seen = {}
    for _, e in ipairs(j.entries) do
        if type(e) ~= "table" or not known[e.file] or seen[e.file] then
            return false, "names a file that is not a workspace file"
        end
        seen[e.file] = true
        if e.action ~= "replace" and e.action ~= "remove" then return false, "has an unknown action" end
        for _, k in ipairs({ "sha256_new", "sha256_old" }) do
            local v = e[k]
            if v ~= nil and (type(v) ~= "string" or not v:match("^%x+$") or #v ~= 64) then
                return false, "has an invalid hash"
            end
        end
        if e.action == "replace" and not e.sha256_new then return false, "has an entry without its hash" end
    end
    return j
end

--- Stray staged files of the three workspace files (`<file>.txn-<hex>`), and
--- a journal's temp: regular files only, exactly those names, nothing else.
--- @param root string
--- @return string[]
function M.strays(root)
    local out = {}
    local dirs = {}
    for _, rel in ipairs(M.FILES) do
        local target = abs(root, rel)
        local dir, base = target:match("^(.*)/([^/]+)$")
        dirs[dir] = dirs[dir] or {}
        dirs[dir][base] = true
    end
    local jdir, jbase = abs(root, M.JOURNAL):match("^(.*)/([^/]+)$")
    for dir, bases in pairs(dirs) do
        local req = uv().fs_scandir(dir)
        while req do
            local name = uv().fs_scandir_next(req)
            if not name then break end
            local base = name:match("^(.-)%.txn%-%x+$")
            local hit = (base and bases[base]) or (dir == jdir and name == jbase .. ".tmp")
            if hit then
                local p = dir .. "/" .. name
                local st = uv().fs_lstat(p)
                if st and st.type == "file" then out[#out + 1] = p end
            end
        end
    end
    table.sort(out)
    return out
end

--- Roll a journal forward. The caller holds O. Returns
---   "none"                         no journal (stray staged files removed)
---   "recovered", line              completed; line to report once
---   "refused",  message            an entry cannot be completed (left as is)
--- @param root string
--- @return string status, string|nil message
function M.recover_locked(root)
    local j, why = M.read_journal(root)
    if j == nil then
        for _, p in ipairs(M.strays(root)) do pcall(uv().fs_unlink, p) end
        return "none"
    end
    local jrel = M.JOURNAL
    if j == false then
        return "refused", string.format("%s %s — discard it with `lw unlock --journal`", jrel, why)
    end
    -- First pass: decide every entry; touch nothing unless all can complete.
    local plan, bad = {}, {}
    for _, e in ipairs(j.entries) do
        local target = abs(root, e.file)
        local cur = sha(read(target))
        local staged = staged_path(target, j.id)
        local st = uv().fs_lstat(staged)
        local staged_sha = (st and st.type == "file") and sha(read(staged)) or nil
        if e.action == "replace" then
            if cur == e.sha256_new then
                plan[#plan + 1] = { done = true }
            elseif staged_sha == e.sha256_new and (cur == e.sha256_old or cur == nil) then
                -- old content, or absent (moved to .bak mid-apply): complete it
                plan[#plan + 1] = { from = staged, to = target }
            else
                -- changed by a writer that ignores the journal, or no staged copy
                bad[#bad + 1] = e.file
            end
        else -- remove
            if cur == nil then
                plan[#plan + 1] = { done = true }
            elseif cur == e.sha256_old then
                plan[#plan + 1] = { remove = target }
            else
                bad[#bad + 1] = e.file
            end
        end
    end
    if #bad > 0 then
        return "refused", string.format("%s: an interrupted %s cannot be completed — %s changed since "
            .. "(by a writer that ignores the journal) or its staged copy is missing; nothing was "
            .. "changed. Discard the journal with `lw unlock --journal` (the files then stay as they "
            .. "are)", jrel, tostring(j.operation or "operation"),
            table.concat(bad, ", "))
    end
    for _, p in ipairs(plan) do
        if p.from then
            local ok, err = rename(p.from, p.to)
            if not ok then return "refused", jrel .. ": could not complete it: " .. tostring(err) end
        elseif p.remove then
            pcall(uv().fs_unlink, p.remove)
        end
    end
    flush_dir(root_of(root))
    flush_dir(abs(root, ".nvim"))
    pcall(uv().fs_unlink, abs(root, M.JOURNAL))
    for _, p in ipairs(M.strays(root)) do pcall(uv().fs_unlink, p) end
    local files = {}
    for _, e in ipairs(j.entries) do files[#files + 1] = e.file end
    local who = tostring(j.pid or "?")
    local lock_record = require("loomworks.lock_record")
    if type(j.host) == "string" and j.host ~= lock_record.this_host() then who = who .. " on " .. j.host end
    return "recovered", string.format("completed an interrupted %s (pid %s crashed) — %s",
        tostring(j.operation or "operation"), who, table.concat(files, ", "))
end

--- Discard a journal and the stray staged files (`lw unlock --journal`). The
--- caller holds O. Removes exactly the journal (a regular file) and the
--- strays of `strays`. Returns the removed paths.
--- @param root string
--- @return string[]
function M.discard_locked(root)
    local removed = {}
    local jpath = abs(root, M.JOURNAL)
    local st = uv().fs_lstat(jpath)
    if st and st.type == "file" and uv().fs_unlink(jpath) then removed[#removed + 1] = jpath end
    for _, p in ipairs(M.strays(root)) do
        if uv().fs_unlink(p) then removed[#removed + 1] = p end
    end
    return removed
end

return M
