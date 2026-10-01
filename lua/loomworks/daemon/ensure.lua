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

--- The launch-failure line (§19.10).
--- @param reason string
--- @return string
function M.launch_failed_line(reason)
    return "lw: could not start the workspace daemon (" .. tostring(reason) .. "); running without it"
end

--- In `runtime-mode daemon`, make sure the workspace daemon runs before a
--- workspace command (spec §19.1, §19.10, §19.19 step 2): connect to a live
--- one (handshake, version reconcile, `ping` — which also restarts its idle
--- clock), or launch one. Nothing is routed yet; the command then runs on the
--- in-process path whatever happened here. Never fails the command: problems
--- are one stderr line.
--- opts:
---   config   lw's settings table
---   flag     `--no-daemon` was given
---   note     fun(line) — stderr
---   log      fun(line) — the runtime log
---   launch   (tests) replaces loomworks.daemon.launch.launch
---   getenv   (tests) replaces os.getenv for the selection
--- Returns what happened: "off" | "used" | "launched" | "restarted" |
--- "bypass" | "newer" | "hung" | "elsewhere" | "failed".
--- @param root string
--- @param opts table
--- @return string
function M.ensure(root, opts)
    local runtime = require("loomworks.daemon.runtime")
    local note = opts.note or function() end
    local log = opts.log or function() end
    local sel = runtime.select((opts.config or {})[runtime.SETTING], { flag = opts.flag, getenv = opts.getenv })
    if sel.warning then note("lw: " .. sel.warning) end
    if not sel.daemon then return "off" end
    local launch = opts.launch or require("loomworks.daemon.launch").launch
    local st = inspect.state(root)
    if st.kind == "starting" then
        vim.wait(require("loomworks.daemon.launch").READY_MS, function()
            st = inspect.state(root)
            return st.kind ~= "starting"
        end, 25)
    end
    if st.kind == "hung" then
        local lb = require("loomworks.lock_break")
        if not lb.requested then
            note(string.format("lw: the workspace daemon (pid %s) is not responding — recover with: "
                .. "lw daemon stop --force", tostring(st.lock.pid)))
            return "hung"
        end
        -- `--break-locks` (§19.5): recover the hung daemon (ask unless =now,
        -- kill, verify, reclaim), then start a fresh one below.
        local rok, rerr = require("loomworks.daemon.command").recover(root, st, lb.requested ~= "now", {
            note = note, ctx = { what = "the workspace runtime", command = lb.command },
        })
        if not rok then
            note("lw: " .. tostring(rerr))
            return "hung"
        end
        st = inspect.state(root)
    end
    if st.kind == "foreign" or st.kind == "attached" or st.kind == "starting" then return "elsewhere" end
    if st.kind == "live" then
        local conn, err = client.session(st.handle.endpoint, { timeout_ms = 3000 })
        if not conn then
            if err == client.ERR_UNTRUSTED then
                note("lw: the workspace daemon's endpoint " .. tostring(st.handle.endpoint)
                    .. " did not authenticate as this machine's daemon — not using it")
                log("refused an untrusted endpoint " .. tostring(st.handle.endpoint))
            else
                note("lw: could not reach the workspace daemon (pid " .. tostring(st.lock.pid) .. ", "
                    .. tostring(err) .. "); running without it")
            end
            return "failed"
        end
        local outcome, detail = M.reconcile(root, conn, { launch = launch })
        if outcome == "match" then
            client.request(conn, { kind = "ping" })
            conn:close()
            return "used"
        end
        if outcome == "restarted" then
            log("replaced a workspace daemon of another version (lw " .. tostring(conn.challenge.lw_version) .. ")")
            return "restarted"
        end
        if outcome == "failed" then
            note(M.launch_failed_line(detail))
            log("could not replace the workspace daemon: " .. tostring(detail))
            return "failed"
        end
        note(detail)
        return outcome
    end
    -- none, stale or unreadable: launch (a dead holder's lock is reclaimed by
    -- the new daemon itself).
    local ok, res = launch(root)
    if ok then
        log("launched the workspace daemon (pid " .. tostring(res and res.handle and res.handle.pid) .. ")")
        return "launched"
    end
    note(M.launch_failed_line(res))
    log("could not start the workspace daemon: " .. tostring(res))
    return "failed"
end

M._inspect = inspect

return M
