--- loomworks/daemon/legacy.lua — the runtime files of lw before slots
--- (spec §19.6 "Legacy files", §19.7.1).
---
--- `<root>/.nvim/loomworks.daemon.json`, `.lock` and `.log` (+ `.log.1`) are
--- never read to connect to a daemon. This module only:
---
---   * stops a live daemon of THIS slot that holds the legacy runtime lock
---     (a daemon of another version, §19.9) before this slot's daemon starts
---     (`stop_live`, from loomworks.daemon.server) and from `lw daemon stop`
---     / `kill` / `restart`; `lw daemon status` reports it (`live_daemon`);
---   * removes the legacy lock and handle as a reclaimer would (§19.5:
---     holder dead) — `lw daemon stop`, housekeeping and `lw cleanup`;
---   * lists the legacy logs as leftovers for housekeeping / `lw cleanup`.
---
--- Deletion safety: only these exact names directly in `<root>/.nvim`, which
--- must be a real directory (lstat: no link or junction) whose real path is
--- the root's real path + "/.nvim" (case-folded on Windows); only regular
--- files (lstat, re-checked right before each removal; a link at a legacy
--- name is never followed nor removed); one unlink or the nonce-checked
--- reclaim rename per file, never a tree removal. The lock goes only when its
--- holder is provably gone (lock_record.classify "dead", reclaimed only if it
--- still carries the observed record); the handle only when it names a
--- process of this host that is gone (or is malformed and its heartbeat
--- stale) and no live or hung holder has the legacy lock. Another slot's
--- files (`loomworks.daemon-<S'>.*`) are never named here.

local paths = require("loomworks.daemon.paths")

local M = {}

local function uv() return vim.uv or vim.loop end
local IS_WIN = package.config:sub(1, 1) == "\\"

local function key(p)
    local n = paths.norm_root(p)
    if IS_WIN then n = n:lower() end
    return n
end

local function realkey(p)
    local ok, r = pcall(uv().fs_realpath, p)
    if ok and type(r) == "string" and r ~= "" then return key(r) end
    return nil
end

--- `<root>/.nvim` when it is a real directory (lstat) whose real path is the
--- root's real path + "/.nvim"; nil otherwise.
--- @param root string
--- @return string|nil
function M.nvim_dir(root)
    root = paths.norm_root(root)
    local d = root .. "/.nvim"
    local st = uv().fs_lstat(d)
    if not st or st.type ~= "directory" then return nil end
    local rr, rd = realkey(root), realkey(d)
    if not rr or not rd or rd ~= rr .. "/.nvim" then return nil end
    return d
end

--- The path of legacy file `which` (a key of paths.LEGACY) when it is a
--- regular file (lstat) directly in a verified `<root>/.nvim`; nil otherwise.
--- @param root string
--- @param which "lock"|"handle"|"log"|"log1"
--- @return string|nil path, table|nil lstat
function M.file(root, which)
    local name = paths.LEGACY[which]
    if not name then return nil end
    local d = M.nvim_dir(root)
    if not d then return nil end
    local p = d .. "/" .. name
    local st = uv().fs_lstat(p)
    if st and st.type == "file" then return p, st end
    return nil
end

--- Is anything (of any type) at the legacy name `which`?
local function present(root, which)
    return uv().fs_lstat(paths.norm_root(root) .. "/.nvim/" .. paths.LEGACY[which]) ~= nil
end

--- The legacy runtime lock's record, classified (`state`), with its path;
--- nil when there is none (or it is not a regular file in a verified
--- `.nvim`).
--- @param root string
--- @return string|nil path, table|nil info
function M.read_lock(root)
    local p = M.file(root, "lock")
    if not p then return nil end
    local info = require("loomworks.build_lock").read_path(p)
    if not info then return nil end
    info.state = require("loomworks.lock_record").classify(info)
    return p, info
end

--- The legacy lock when a reclaimer may remove it (holder dead), else nil.
--- @param root string
--- @return string|nil path, table|nil info
function M.lock_reclaimable(root)
    local p, info = M.read_lock(root)
    if p and info and info.state == "dead" then return p, info end
    return nil
end

--- Reclaim the legacy lock `path` if it still carries `info` (the observed
--- dead holder's record) and is still a regular file in a verified `.nvim`.
--- @param root string
--- @param path string
--- @param info table
--- @return boolean removed
function M.reclaim_lock(root, path, info)
    local cur = M.file(root, "lock")
    if not cur or cur ~= path then return false end
    return require("loomworks.lock_record").reclaim(path, info) and true or false
end

--- Does a handle record name a process of this host that is gone?
local function names_dead(rec)
    if not rec.valid then return rec.stale == true end
    local lr = require("loomworks.lock_record")
    if not lr.same_host(rec) then return false end
    if type(rec.pid) ~= "number" or type(rec.start_time) ~= "string" then return false end
    return require("loomworks.proc").alive(rec.pid, rec.start_time) == false
end

--- The legacy handle when a reclaimer may remove it: it names a process of
--- this host that is gone (or is malformed with a stale heartbeat), and no
--- holder other than a dead one has the legacy lock. Else nil.
--- @param root string
--- @return string|nil path, table|nil rec
function M.handle_removable(root)
    local p = M.file(root, "handle")
    if not p then return nil end
    if present(root, "lock") then
        local _, info = M.read_lock(root)
        if not info or info.state ~= "dead" then return nil end
    end
    local rec = require("loomworks.daemon.handle").read_path(p)
    if not rec or not names_dead(rec) then return nil end
    return p, rec
end

--- Remove the legacy handle `path` — re-checked right before: still a
--- regular file in a verified `.nvim`, still naming the same process (or
--- still malformed and stale), still removable.
--- @param root string
--- @param path string
--- @param rec table the record judged removable
--- @return boolean removed
function M.remove_handle(root, path, rec)
    local cur, now = M.handle_removable(root)
    if not cur or cur ~= path then return false end
    if rec.valid ~= now.valid or (rec.valid and (now.pid ~= rec.pid or now.start_time ~= rec.start_time)) then
        return false
    end
    local st = uv().fs_lstat(path)
    if not st or st.type ~= "file" then return false end
    return uv().fs_unlink(path) and true or false
end

--- Remove the legacy lock and handle as a reclaimer would (§19.5): the lock
--- when its holder is dead, then the handle when it names a gone process and
--- no live holder has the lock. Returns the removed paths.
--- @param root string
--- @return string[]
function M.reclaim(root)
    local removed = {}
    local lp, info = M.lock_reclaimable(root)
    if lp and M.reclaim_lock(root, lp, info) then removed[#removed + 1] = lp end
    local hp, rec = M.handle_removable(root)
    if hp and M.remove_handle(root, hp, rec) then removed[#removed + 1] = hp end
    return removed
end

--- May the legacy runtime logs be removed? Only when nothing is at the
--- legacy lock name, or it is a lock whose holder is dead: a live, hung,
--- foreign or unreadable holder (an older lw's daemon writing them) keeps
--- them.
--- @param root string
--- @return boolean
function M.logs_removable(root)
    if not present(root, "lock") then return true end
    local _, info = M.read_lock(root)
    return info ~= nil and info.state == "dead"
end

--- The legacy runtime logs present (`.log`, `.log.1`): regular files in a
--- verified `.nvim`, as `{ path, st }`.
--- @param root string
--- @return { path: string, st: table }[]
function M.logs(root)
    local out = {}
    for _, w in ipairs({ "log", "log1" }) do
        local p, st = M.file(root, w)
        if p then out[#out + 1] = { path = p, st = st } end
    end
    return out
end

--- The legacy runtime lock's record when its holder is a live daemon of
--- this slot (§19.7.1, §19.5 identity rules: a process of this host alive
--- with the record's start time, its slot read from the process itself) — a
--- daemon of an earlier lw; nil otherwise (none, dead, hung, another host's,
--- no or uncheckable start time, an attached run, another slot's). Never
--- raises.
--- @param root string
--- @return table|nil info
function M.live_daemon(root)
    local ok, info = pcall(function()
        local _, info = M.read_lock(root)
        if not info or info.state ~= "live" then return nil end
        if not (info.kind == "daemon" or info.mode == "daemon") then return nil end
        -- classify also calls a record of another host, or one whose start
        -- time is missing or cannot be checked, "live": only a process of
        -- this host proven alive with that start time is this holder.
        if not require("loomworks.lock_record").same_host(info) then return nil end
        if type(info.pid) ~= "number" or type(info.start_time) ~= "string" then return nil end
        if require("loomworks.proc").alive(info.pid, info.start_time) ~= true then return nil end
        if not require("loomworks.daemon.identity").same_slot(info.pid) then
            return nil
        end
        return info
    end)
    return ok and info or nil
end

--- Before this slot's daemon starts, and from `lw daemon stop` / `kill` /
--- `restart` (§19.6 "Legacy files"): a live daemon of
--- this slot (§19.7.1) holding the legacy runtime lock is a daemon of
--- another version (§19.9) — stop it (asked first, then its tree killed and
--- verified gone, loomworks.lock_break; the §19.5 identity rules: `lw …
--- daemon run --root <root>`, known start time, not an ancestor). A holder
--- of another slot, an attached run, a hung, dead or foreign holder, is left
--- alone. Never raises.
--- @param root string
--- @param log? fun(line: string)
--- @return "none"|"stopped"|"failed" outcome, string|nil detail, table|nil info the stopped holder
function M.stop_live(root, log)
    local info
    local ok, outcome, detail = pcall(function()
        info = M.live_daemon(root)
        if not info then return "none" end
        local lines = {}
        local bok, berr = require("loomworks.lock_break").break_holder(info, {
            what = "the runtime lock of an earlier lw (" .. paths.LEGACY.lock .. ")",
            root = paths.norm_root(root),
            remedy = "lw daemon stop with that lw",
        }, { mode = "ask", report = function(line) lines[#lines + 1] = line end, log = function() end })
        if log then for _, l in ipairs(lines) do pcall(log, l) end end
        if not bok then return "failed", berr end
        return "stopped"
    end)
    if not ok then return "failed", tostring(outcome), info end
    if outcome == "failed" and log then pcall(log, "could not stop the daemon of an earlier lw: " .. tostring(detail)) end
    return outcome, detail, info
end

return M
