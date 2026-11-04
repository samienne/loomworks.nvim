--- loomworks/daemon/ensure.lua — a client meets the workspace daemon: the
--- version handshake (spec §19.9).
---
--- After authenticating, a CLI client applies its version policy (`policy`,
--- step 5g.3): an agreed transport, and over transport 11 the daemon's
--- `describe().binary.lw_version` and schemas equal to its own (before 11:
--- protocol, host version and schemas of the challenge,
--- loomworks.daemon.version.matches). On a mismatch:
---   * idle daemon (no running task, no other connection that owns a task or
---     has a command in flight — observers and subscribers never count,
---     §19.9 "Busy") — the client stops it
---     (`stop`, frozen) and launches its own binary in its place;
---   * busy daemon — the client sends `retire` (frozen): the daemon keeps
---     serving its clients and exits once idle; this command runs as a
---     version-bypass run (during the transition: the in-process path) and
---     prints one line;
---   * a daemon whose schemas are newer than the client's is never stopped
---     by it: the client says to update and does not use it.
--- A client never stops a busy daemon and never drives one it does not match.
---
--- Finding, launching and connecting to the daemon is
--- loomworks.daemon.connect's (§19.10 "Connect or start", shared with the
--- `--stdio` relay); this module adds the CLI's policy: its bounds, its one
--- line per outcome, `--break-locks` recovery and the version reconcile.

local inspect = require("loomworks.daemon.inspect")
local rlock = require("loomworks.daemon.rlock")
local version = require("loomworks.daemon.version")
local client = require("loomworks.daemon.client")
local connect = require("loomworks.daemon.connect")

local M = {}

--- The latency budget of the ensure path (§19.10 keeps read-only commands
--- fast): each step with a daemon (connect + handshake, `status`, `ping`)
--- waits at most this long, and a daemon still starting is waited for at
--- most this long, once per command. `LW_TEST_DAEMON_STEP_MS` lengthens it
--- for test suites that run real `lw` processes on a heavily loaded machine
--- (as `LW_TEST_DAEMON_READY_MS` does the launch's readiness wait).
M.STEP_MS = tonumber(os.getenv("LW_TEST_DAEMON_STEP_MS") or "") or 1000

--- The longer bound of a command the daemon would run (§19.10: a routed
--- `lw build`): under machine load a healthy daemon can miss the 1 s, and the
--- build would then run in-process exactly when the daemon helps most. A hung
--- daemon (stale heartbeat) is still reported at once — this only gives a
--- live-but-slow one longer. Never shorter than STEP_MS (so the test hook
--- lengthens it too).
M.ROUTED_STEP_MS = 5000

--- The step bound of an ensure (`routed`: the command would be routed).
--- @param routed? boolean
--- @return integer
function M.step_ms(routed)
    if routed then return math.max(M.ROUTED_STEP_MS, M.STEP_MS) end
    return M.STEP_MS
end

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

--- The CLI's version policy against an authenticated connection (spec §19.9
--- "From protocol 11", step 5g.3): with no agreed transport a mismatch; over
--- transport 11 or later the daemon's `describe().binary.lw_version`
--- (§19.20) and the challenge's schemas must equal ours
--- (version.cli_policy_matches); over transport 10 (a daemon before protocol
--- 11) — or when `describe` gets no answer — the challenge's versions as
--- before (version.matches). Returns match, the daemon's version.
--- @param conn loomworks.daemon.Conn
--- @param step? integer
--- @return boolean match, string|nil daemon_version
function M.policy(conn, step)
    local info = conn.challenge or {}
    local t = conn.transport
    if type(t) ~= "number" then return false, info.lw_version end
    if t >= 11 and type(conn.call) == "function" then
        local d = client.call_sync(conn, "/", "loomworks.Root", 1, "describe", {}, { timeout_ms = step })
        local lw = type(d) == "table" and type(d.binary) == "table" and d.binary.lw_version or nil
        if type(lw) == "string" then
            return (version.cli_policy_matches(t, lw, info.schemas)), lw
        end
    end
    return (version.matches(info)), info.lw_version
end

--- Reconcile versions with an authenticated connection `conn` to the daemon
--- of `root` (live state `st`). Closes `conn`. Returns one of:
---   "match"      versions match (the caller may keep using the daemon)
---   "restarted"  the idle daemon was stopped and `launch()` started ours
---   "bypass"     the busy daemon was asked to retire; run without it
---   "newer"      the daemon's schemas are newer; run without it
---   "stopped"    (`opts.no_launch`) the idle daemon was stopped; nothing
---                was launched in its place
---   "failed"     replacing the idle daemon failed (reason in second value)
--- `opts.launch(root)` → ok, state|reason (default loomworks.daemon.launch).
--- `opts.no_launch`: an attached selection (§19.1) stops an idle mismatched
--- daemon but launches none — it then runs attached itself.
--- @param root string
--- @param conn loomworks.daemon.Conn
--- @param opts? { launch?: fun(root: string): boolean, any, no_launch?: boolean, step_ms?: integer }
--- @return string outcome, string|nil detail
function M.reconcile(root, conn, opts)
    opts = opts or {}
    local step = opts.step_ms
    local info = conn.challenge or {}
    local match, daemon_version = M.policy(conn, step)
    if match then return "match" end
    if version.peer_schemas_newer(info) then
        conn:close()
        return "newer", M.newer_line(info)
    end
    local st = client.request(conn, { kind = "status" }, step)
    -- Busy (§19.9 "Busy"): protocol.status_busy, the rule the editor's
    -- retirement shares.
    if require("loomworks.daemon.protocol").status_busy(st) then
        -- `retire` is in the frozen control subset (§19.8): sent whatever
        -- the transports, so also to a busy daemon whose range does not
        -- overlap ours.
        client.request(conn, { kind = "retire" }, step)
        conn:close()
        return "bypass", M.bypass_line(daemon_version)
    end
    local lk = rlock.read(root)
    client.request(conn, { kind = "stop" }, step)
    conn:close()
    local released = vim.wait(M.STOP_WAIT_MS, function()
        local cur = rlock.read(root)
        return cur == nil or (lk ~= nil and cur.lock_nonce ~= lk.lock_nonce)
    end, 25)
    if not released then return "failed", "the old daemon did not stop" end
    if opts.no_launch then return "stopped" end
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

--- The one line (and log line) of a connection `connect.open` could not
--- make (`why`, `detail` as it returns them) to the live daemon `st`.
--- @param st table
--- @param why string "endpoint" | "untrusted" | "unreachable"
--- @param detail string|nil
--- @param note fun(line: string)
--- @param log fun(line: string)
local function open_failed(st, why, detail, note, log)
    if why == "endpoint" then
        note("lw: " .. tostring(detail))
        log(tostring(detail))
    elseif why == "untrusted" then
        note("lw: the workspace daemon's endpoint " .. tostring(st.handle.endpoint)
            .. " did not authenticate as this machine's daemon — not using it")
        log("refused an untrusted endpoint " .. tostring(st.handle.endpoint))
    else
        note("lw: could not reach the workspace daemon (pid " .. tostring(st.lock.pid) .. ", "
            .. tostring(detail) .. "); running without it")
    end
end

--- After an authenticated connection `conn` to the live daemon: the version
--- reconcile, `ping`, and the outcome's line (as `meet` returns them).
--- @param root string
--- @param conn loomworks.daemon.Conn
--- @param opts table as for `meet` (note, log, launch, no_launch; step_ms resolved)
--- @return string
local function meet_conn(root, conn, opts)
    local note = opts.note or function() end
    local log = opts.log or function() end
    local step = opts.step_ms
    local outcome, detail = M.reconcile(root, conn, { launch = opts.launch, step_ms = step, no_launch = opts.no_launch })
    if outcome == "match" then
        client.request(conn, { kind = "ping" }, step)
        conn:close()
        return "used"
    end
    if outcome == "stopped" then
        log("stopped a workspace daemon of another version (lw " .. tostring(conn.challenge.lw_version)
            .. ") for an attached run")
        return "stopped"
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

--- Meet the live workspace daemon `st` (loomworks.daemon.inspect, kind
--- "live"; spec §19.9): the endpoint check, connect + handshake
--- (loomworks.daemon.connect.open), the version reconcile, `ping`. The one
--- path both a shared selection (`ensure`) and an attached selection that
--- finds a live daemon (§19.2; cli._delegate_attached, `no_launch`) take.
--- Returns "used" | "restarted" | "stopped" | "bypass" | "newer" |
--- "failed"; every outcome but "used", "restarted" and "stopped" has
--- printed its one line.
--- opts: note, log, launch, step_ms (as for `ensure`), no_launch (as for
--- `reconcile`).
--- @param root string
--- @param st table
--- @param opts table
--- @return string
function M.meet(root, st, opts)
    local step = opts.step_ms or M.step_ms(true)
    local conn, why, detail = connect.open(root, st, { step_ms = step })
    if not conn then
        open_failed(st, why, detail, opts.note or function() end, opts.log or function() end)
        return "failed"
    end
    return meet_conn(root, conn, vim.tbl_extend("force", {}, opts, { step_ms = step }))
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
---   routed   the command would be routed to the daemon (a `lw build`):
---            each step, and the one wait for a starting daemon, use
---            ROUTED_STEP_MS instead of STEP_MS
---   step_ms  (tests) replaces the step bound
---   foreign_pin  the version the workspace's lw.pin names when this lw is
---            not it (boot.pin.foreign_pin; main.lua sets it for a command
---            the invoked host runs itself, spec §16.23): the workspace daemon
---            is the pinned lw's, so this one neither launches, stops nor
---            retires one — "pinned", and the command runs without it
--- Returns what happened: "off" | "used" | "launched" | "restarted" |
--- "bypass" | "newer" | "hung" | "starting" | "elsewhere" | "pinned" |
--- "failed".
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
    if opts.foreign_pin then
        log("lw.pin names lw " .. tostring(opts.foreign_pin) .. ": the workspace daemon is the pinned lw's;"
            .. " this command runs without it")
        return "pinned"
    end
    local launch = opts.launch or require("loomworks.daemon.launch").launch
    local step = opts.step_ms or M.step_ms(opts.routed)
    -- Connect or start (§19.10, loomworks.daemon.connect): at most one short
    -- wait for a daemon still starting — one stuck starting must not cost
    -- every command the launch's readiness timeout.
    local r = connect.connect_or_start(root, {
        step_ms = step, launch = launch,
        on_hung = function(st)
            local lb = require("loomworks.lock_break")
            if not lb.requested then
                note(string.format("lw: the workspace daemon (pid %s) is not responding — recover with: "
                    .. "lw daemon stop --force", tostring(st.lock.pid)))
                return nil
            end
            -- `--break-locks` (§19.5): recover the hung daemon (ask unless
            -- =now, kill, verify, reclaim), then start a fresh one.
            local rok, rerr = require("loomworks.daemon.command").recover(root, st, lb.requested ~= "now", {
                note = note, ctx = { what = "the workspace runtime", command = lb.command },
            })
            if not rok then
                note("lw: " .. tostring(rerr))
                return nil
            end
            return inspect.state(root)
        end,
    })
    local o = r.outcome
    if o == "starting" then
        note(string.format("lw: the workspace daemon (pid %s) is still starting — running without it",
            tostring(r.st.lock and r.st.lock.pid)))
        return "starting"
    end
    if o == "hung" or o == "elsewhere" then return o end
    if o == "connected" then
        return meet_conn(root, r.conn, { note = note, log = log, launch = launch, step_ms = step })
    end
    if o == "endpoint" or o == "untrusted" or o == "unreachable" then
        open_failed(r.st, o, r.detail, note, log)
        return "failed"
    end
    if o == "launched" then
        local res = r.launch_state
        log("launched the workspace daemon (pid " .. tostring(res and res.handle and res.handle.pid) .. ")")
        return "launched"
    end
    note(M.launch_failed_line(r.detail))
    log("could not start the workspace daemon: " .. tostring(r.detail))
    return "failed"
end

M._inspect = inspect

return M
