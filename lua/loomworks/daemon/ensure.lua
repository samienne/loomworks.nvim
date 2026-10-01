--- loomworks/daemon/ensure.lua — a client meets the workspace daemon: the
--- version handshake (spec §19.9).
---
--- After authenticating, a CLI client compares protocol, host version and
--- schemas (loomworks.daemon.version.matches). On a mismatch:
---   * idle daemon (no other client, no running task) — the client stops it
---     (`stop`, frozen) and launches its own binary in its place;
---   * busy daemon — the client sends `retire` (frozen): the daemon keeps
---     serving its clients and exits once idle; this command runs as a
---     version-bypass run (during the transition: the in-process path) and
---     prints one line;
---   * a daemon whose schemas are newer than the client's is never stopped
---     by it: the client says to update and does not use it.
--- A client never stops a busy daemon and never drives one it does not match.

local inspect = require("loomworks.daemon.inspect")
local rlock = require("loomworks.daemon.rlock")
local version = require("loomworks.daemon.version")
local client = require("loomworks.daemon.client")

local M = {}

--- How long a client waits for a stopped daemon to release R before it
--- gives up on replacing it.
M.STOP_WAIT_MS = 10000

--- The one line of a version-bypass run (§19.9).
--- @param daemon_version string
--- @return string
function M.bypass_line(daemon_version)
    return string.format("lw: the workspace daemon runs lw v%s and is busy — running this command without it; "
        .. "it restarts when idle", tostring(daemon_version))
end

--- The refusal for a daemon with newer schemas (§19.9 → §2.7).
--- @param info table the daemon's challenge
--- @return string
function M.newer_line(info)
    local s, own = info.schemas or {}, version.schemas()
    return string.format("lw: the workspace daemon runs lw v%s, whose file formats (user %s, cache %s) are newer "
        .. "than this lw's (user %d, cache %d) — update lw; not using the daemon",
        tostring(info.lw_version), tostring(s.user), tostring(s.cache), own.user, own.cache)
end

--- Reconcile versions with an authenticated connection `conn` to the daemon
--- of `root` (live state `st`). Closes `conn`. Returns one of:
---   "match"      versions match (the caller may keep using the daemon)
---   "restarted"  the idle daemon was stopped and `launch()` started ours
---   "bypass"     the busy daemon was asked to retire; run without it
---   "newer"      the daemon's schemas are newer; run without it
---   "failed"     replacing the idle daemon failed (reason in second value)
--- `opts.launch(root)` → ok, state|reason (default loomworks.daemon.launch).
--- @param root string
--- @param conn loomworks.daemon.Conn
--- @param opts? { launch?: fun(root: string): boolean, any }
--- @return string outcome, string|nil detail
function M.reconcile(root, conn, opts)
    opts = opts or {}
    local info = conn.challenge or {}
    if version.matches(info) then return "match" end
    if version.peer_schemas_newer(info) then
        conn:close()
        return "newer", M.newer_line(info)
    end
    local st = client.request(conn, { kind = "status" })
    local others = st and ((tonumber(st.clients) or 1) - 1) or 1
    local busy = (st == nil) or st.busy == true or others > 0
    if busy then
        client.request(conn, { kind = "retire" })
        conn:close()
        return "bypass", M.bypass_line(info.lw_version)
    end
    local lk = rlock.read(root)
    client.request(conn, { kind = "stop" })
    conn:close()
    local released = vim.wait(M.STOP_WAIT_MS, function()
        local cur = rlock.read(root)
        return cur == nil or (lk ~= nil and cur.lock_nonce ~= lk.lock_nonce)
    end, 25)
    if not released then return "failed", "the old daemon did not stop" end
    local launch = opts.launch or require("loomworks.daemon.launch").launch
    local ok, res = launch(root)
    if not ok then return "failed", tostring(res) end
    return "restarted"
end

M._inspect = inspect

return M
