--- loomworks/daemon/inspect.lua — the state of a workspace's runtime, read
--- from its files only (spec §19.6): the runtime lock R and the handle. Never
--- launches, connects to or signals anything — the `Runtime` row of
--- `lw status` and the file part of `lw daemon status` are computed here.
---
--- States (`state(root).kind`):
---   none          no runtime lock, no handle
---   live          R held by a live daemon on this host, handle present
---   starting      R held by a live daemon on this host, no handle yet
---   hung          R held by a daemon on this host that stopped heartbeating
---   foreign       R held by a daemon on another host (heartbeat fresh)
---   attached      R held by an attached run (§19.2) or another lw command
---   stale         a handle (or lock) whose daemon is gone: R free, dead or
---                 stale — `lw daemon stop` clears it
---   unreadable    a malformed handle and no live holder

local rlock = require("loomworks.daemon.rlock")
local handle = require("loomworks.daemon.handle")
local lock_record = require("loomworks.lock_record")

local M = {}

--- @param root string
--- @return table state { kind, lock?, handle? }
function M.state(root)
    local lk = rlock.read(root)
    local h = handle.read(root)
    local s = { lock = lk, handle = h }
    if lk and (lk.state == "live" or lk.state == "hung") then
        local is_daemon = lk.mode == "daemon" or (lk.mode == nil and lk.kind == "daemon")
        if not lock_record.same_host(lk) then
            s.kind = "foreign"
        elseif not is_daemon then
            s.kind = "attached"
        elseif lk.state == "hung" then
            s.kind = "hung"
        elseif h and h.valid and h.pid == lk.pid then
            s.kind = "live"
        else
            s.kind = "starting"
        end
        return s
    end
    if not lk and not h then
        s.kind = "none"
    elseif h and not h.valid and not lk then
        s.kind = "unreadable"
    else
        s.kind = "stale"
    end
    return s
end

local function age_text(secs) return lock_record.age_text(math.max(0, tonumber(secs) or 0)) end

--- The `Runtime` row's text (without the label), spec §19.6.
--- @param st table from `state`
--- @param mode string the resolved runtime mode
--- @param own_version? string this lw's identity (loomworks.daemon.version)
--- @return string
function M.row(st, mode, own_version)
    local k = st.kind
    local lk, h = st.lock or {}, st.handle or {}
    if k == "none" then
        if mode == "daemon" then return "no daemon (starts on the next command)" end
        return "in-process"
    end
    local pid = tostring(lk.pid or h.pid or "?")
    if k == "live" then
        local v = h.lw_version
        if own_version and v and v ~= own_version then
            return string.format("daemon pid %s, v%s (this lw is v%s — restarts when idle)", pid, v, own_version)
        end
        local parts = { "daemon pid " .. pid }
        local n = tonumber(h.clients) or 0
        if h.busy then parts[#parts + 1] = "busy" end
        if n > 0 then
            parts[#parts + 1] = n .. (n == 1 and " client" or " clients")
        elseif type(h.idle_since) == "number" then
            parts[#parts + 1] = "idle " .. age_text(os.time() - h.idle_since)
        end
        return table.concat(parts, ", ")
    elseif k == "starting" then
        return "daemon pid " .. pid .. " (starting)"
    elseif k == "hung" then
        return string.format("daemon pid %s is not responding (no heartbeat for %s) — lw daemon stop --force",
            pid, age_text(lk.age))
    elseif k == "foreign" then
        return string.format("daemon on %s (pid %s)", tostring(lk.host or "?"), pid)
    elseif k == "attached" then
        return string.format("attached: %s (pid %s)", rlock.holder_text(lk), pid)
    elseif k == "unreadable" then
        return "unreadable daemon handle — lw daemon stop clears it"
    end
    -- stale
    local age = h.age or lk.age
    return string.format("stale daemon handle (pid %s, %s ago) — lw daemon stop clears it", pid, age_text(age))
end

return M
