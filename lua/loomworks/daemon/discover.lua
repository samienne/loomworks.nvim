--- loomworks/daemon/discover.lua — every workspace daemon of this user on
--- this host, found by a process scan (spec §19.6.1).
---
--- There is no registry: nothing is written outside the workspaces. The scan
--- lists the processes with their executable names (loomworks.proc.processes),
--- keeps the lw-host candidates (`lw`, `lw-*`, `luvi`, `nvim`), reads their
--- command lines and keeps `lw … daemon run` (loomworks.proc.is_daemon_for).
--- Each daemon's workspace is its `--root`; its runtime lock R and handle are
--- read (files only) to classify it:
---
---   live          R and the handle name this process
---   starting      R names it, no handle yet
---   hung          R names it, heartbeat stale
---   stray         R names another holder / none, the handle names another
---                 process, or the root is gone
---   unknown_root  no `--root` on its command line
---
--- Never launches, connects to or signals anything; writes nothing.

local proc = require("loomworks.proc")
local paths = require("loomworks.daemon.paths")

local M = {}

local function uv() return vim.uv or vim.loop end

--- Is `name` (an executable name or path) an lw-host candidate?
--- @param name string
--- @return boolean
function M.candidate(name)
    local b = tostring(name or ""):gsub("\\", "/"):match("[^/]*$") or ""
    b = b:lower():gsub("%.exe$", "")
    return b == "lw" or b:sub(1, 3) == "lw-" or b == "luvi" or b == "nvim"
end

--- The `--root` value of a command line (`--root <dir>` or `--root=<dir>`),
--- normalized like `lw daemon run` does, or nil.
--- @param args string[]
--- @return string|nil
function M.root_of(args)
    for i = 1, #args do
        local a = args[i]
        local v = (a == "--root" and args[i + 1]) or (type(a) == "string" and a:match("^%-%-root=(.+)$"))
        if v and v ~= "" then return (v:gsub("\\", "/"):gsub("/+$", "")) end
    end
    return nil
end

--- Scan the processes for `lw … daemon run`. Returns `{ pid, start_time,
--- args, root? }[]` and the time the scan took (ms).
--- @return table[] found, number ms
function M.scan()
    local t0 = uv().hrtime()
    local me = uv().os_getpid and uv().os_getpid() or -1
    local found = {}
    for _, p in ipairs(proc.processes()) do
        if p.pid ~= me and p.pid > 0 and M.candidate(p.name) then
            local st = proc.start_time(p.pid)
            if type(st) == "string" then
                local args = proc.cmdline(p.pid, st)
                if args and proc.is_daemon_for(args) then
                    -- The root it names (§19.10: launched daemons always do);
                    -- is_daemon_for(args, root) matches its own --root.
                    found[#found + 1] = { pid = p.pid, start_time = st, args = args, root = M.root_of(args) }
                end
            end
        end
    end
    return found, (uv().hrtime() - t0) / 1e6
end

--- Classify one found daemon from its workspace's files (§19.6.1).
--- @param d table from `scan`
--- @return table entry
function M.classify(d)
    local e = { pid = d.pid, start_time = d.start_time, root = d.root, args = d.args }
    local t = proc.start_epoch(d.start_time)
    if t then e.uptime_s = math.max(0, math.floor(os.time() - t)) end
    if not d.root then
        e.state = "unknown_root"
        e.reason = "no --root on its command line"
        return e
    end
    local rst = uv().fs_stat(d.root)
    if not rst or rst.type ~= "directory" then
        e.state, e.reason = "stray", "its workspace root is gone"
        return e
    end
    local lk = require("loomworks.daemon.rlock").read(d.root)
    local h = require("loomworks.daemon.handle").read(d.root)
    local function names_me(rec)
        return rec and rec.pid == d.pid and (rec.start_time == nil or rec.start_time == d.start_time)
    end
    e.lock = lk
    if not names_me(lk) then
        e.state = "stray"
        e.reason = lk and lk.pid and ("the runtime lock names pid " .. tostring(lk.pid)) or "no runtime lock"
        return e
    end
    if h and h.valid and not names_me(h) then
        e.state, e.reason = "stray", "the handle names pid " .. tostring(h.pid)
        return e
    end
    if lk.state == "hung" then
        e.state = "hung"
    elseif h and h.valid then
        e.state = "live"
    else
        e.state = "starting"
    end
    if h and h.valid then
        e.clients = tonumber(h.clients) or 0
        e.busy = h.busy and true or false
        e.idle_since = (e.clients == 0 and not e.busy and type(h.idle_since) == "number") and h.idle_since or nil
        e.started_at = type(h.started_at) == "number" and h.started_at or nil
        e.lw_version = h.lw_version
        e.protocol = h.protocol
        e.endpoint = h.endpoint
        if not e.uptime_s and e.started_at then e.uptime_s = math.max(0, os.time() - e.started_at) end
    end
    return e
end

--- Is `root` under `dir` (separator-bounded; case-insensitive on Windows;
--- both resolved through their real paths when they exist)?
--- @param root string
--- @param dir string
--- @return boolean
function M.under(root, dir)
    local key = paths._hash_key
    local r, d = key(root), key(dir)
    return r == d or r:sub(1, #d + 1) == d .. "/" or (d:sub(-1) == "/" and r:sub(1, #d) == d)
end

--- Every daemon, classified and sorted by root (unknown roots last, then by
--- pid). `opts.under` keeps those whose root lies under that directory.
--- @param opts? { under?: string }
--- @return table[] daemons, number scan_ms
function M.list(opts)
    opts = opts or {}
    local found, ms = M.scan()
    local out = {}
    for _, d in ipairs(found) do
        if not opts.under or (d.root and M.under(d.root, opts.under)) then
            out[#out + 1] = M.classify(d)
        end
    end
    table.sort(out, function(a, b)
        if (a.root ~= nil) ~= (b.root ~= nil) then return a.root ~= nil end
        if a.root and b.root and a.root ~= b.root then return a.root < b.root end
        return a.pid < b.pid
    end)
    return out, ms
end

--- Counts for the summary line: total, idle, stray (stray + unknown root).
--- @param list table[]
--- @return integer n, integer idle, integer stray
function M.counts(list)
    local n, idle, stray = #list, 0, 0
    for _, e in ipairs(list) do
        if e.state == "live" and not e.busy and (e.clients or 0) == 0 then idle = idle + 1 end
        if e.state == "stray" or e.state == "unknown_root" then stray = stray + 1 end
    end
    return n, idle, stray
end

return M
