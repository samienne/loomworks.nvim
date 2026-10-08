--- loomworks/daemon/connect.lua — connect or start: the one way a client
--- process reaches its workspace's daemon (spec §19.10 "Connections",
--- "Connect or start").
---
--- Shared by the CLI's daemon-mode ensure step (loomworks.daemon.ensure) and
--- the `lw daemon run --stdio` relay (step 5i): read the runtime's state from
--- its files (loomworks.daemon.inspect), wait once, bounded, for a daemon
--- still starting, then either open an authenticated connection to the live
--- daemon (the endpoint check of §19.7 and the socket handshake of §19.8,
--- which verifies `server_proof`) or launch the normal detached daemon
--- (loomworks.daemon.launch, §19.10) when none runs.
---
--- Policy stays with the caller: what to print, the version reconcile
--- (§19.9, the CLI's), `--break-locks` recovery of a hung daemon (the CLI's,
--- through `opts.on_hung`), the relay's exit statuses. This module prints
--- nothing.
---
--- It also names a daemon **instance** (§19.5, §19.10 "Skip an instance"):
--- `<pid>:<start_time>`, the handle's `pid` and `start_time` — the process
--- start time of loomworks.proc, which itself carries a method prefix and may
--- contain colons (`linux:<boot id>:<ticks>`), so an id splits at its first
--- colon.

local inspect = require("loomworks.daemon.inspect")
local client = require("loomworks.daemon.client")

local M = {}

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

--- A daemon instance: process id and process start time (§19.5).
--- @class loomworks.daemon.Instance
--- @field pid integer
--- @field start_time string opaque, with its method prefix (`win:`, `linux:`, `mac:`)

local function valid_pid(pid)
    return type(pid) == "number" and pid >= 1 and pid == math.floor(pid)
end

-- A start time as loomworks.proc writes it: `<method>:<rest>`, no whitespace.
local function valid_start(st)
    return type(st) == "string" and st:match("^%a+:%S+$") ~= nil
end

--- The instance id `<pid>:<start_time>` of a daemon (its handle, lock
--- record or `welcome.daemon`; anything with `pid` and `start_time`), or nil
--- when either is missing or malformed — a daemon whose start time is
--- unknown cannot be named.
--- @param pid integer|{ pid: integer, start_time: string }
--- @param start_time? string
--- @return string|nil
function M.instance_id(pid, start_time)
    if type(pid) == "table" then pid, start_time = pid.pid, pid.start_time end
    if not valid_pid(pid) or not valid_start(start_time) then return nil end
    return string.format("%d:%s", pid, start_time)
end

--- Parse an instance id `<pid>:<start_time>` (the value of
--- `--skip-instance`). Returns the instance, or nil when the value is not of
--- that form (a decimal pid, a colon, a start time with its method prefix).
--- @param s string|nil
--- @return loomworks.daemon.Instance|nil
function M.parse_instance(s)
    if type(s) ~= "string" then return nil end
    local p, st = s:match("^(%d+):(.+)$")
    local pid = tonumber(p)
    if not valid_pid(pid) or not valid_start(st) then return nil end
    return { pid = pid, start_time = st }
end

--- Do `a` and `b` (instances, handles, lock records or ids) name the same
--- daemon instance? Both pid and start time must be known and equal: a
--- record without a start time names no instance and matches nothing.
--- @param a string|table|nil
--- @param b string|table|nil
--- @return boolean
function M.same_instance(a, b)
    if type(a) == "string" then a = M.parse_instance(a) end
    if type(b) == "string" then b = M.parse_instance(b) end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local ia, ib = M.instance_id(a), M.instance_id(b)
    return ia ~= nil and ia == ib
end

-- ---------------------------------------------------------------------------
-- Connect or start
-- ---------------------------------------------------------------------------

--- Wait, at most `step_ms` once, for a daemon still starting (lock held,
--- handle not yet published) to leave that state. Returns the state then.
--- @param root string
--- @param st table inspect.state(root)
--- @param step_ms integer
--- @return table st
function M.await_start(root, st, step_ms)
    if st.kind ~= "starting" then return st end
    vim.wait(step_ms, function()
        st = inspect.state(root)
        return st.kind ~= "starting"
    end, 25)
    return st
end

--- Open an authenticated connection to the live daemon `st` (inspect kind
--- "live"): the endpoint check (§19.7), then the socket handshake (§19.8;
--- the server's proof is verified before anything else is sent). Returns
--- the connection, or nil + why:
---   "endpoint"     the handle's endpoint failed the check (detail: why)
---   "untrusted"    the endpoint did not prove this lw's key
---   "unreachable"  no connection or handshake within the bound (detail:
---                  client error)
--- opts: step_ms (the connect + handshake bound), plus any client.session
--- option (`on_message`, `client`).
--- @param root string
--- @param st table
--- @param opts? table
--- @return loomworks.daemon.Conn|nil conn, string|nil why, string|nil detail
function M.open(root, st, opts)
    opts = opts or {}
    local endpoint = st.handle and st.handle.endpoint
    local eok, ewhy = require("loomworks.daemon.endpoint").check(root, endpoint)
    if not eok then return nil, "endpoint", ewhy end
    local sopts = {}
    for k, v in pairs(opts) do if k ~= "step_ms" then sopts[k] = v end end
    sopts.timeout_ms = opts.step_ms
    local conn, err = client.session(endpoint, sopts)
    if conn then return conn end
    if err == client.ERR_UNTRUSTED then return nil, "untrusted" end
    return nil, "unreachable", err
end

--- The result of `connect_or_start`.
--- @class loomworks.daemon.ConnectResult
--- @field outcome string see `connect_or_start`
--- @field st table the runtime state it acted on (inspect.state; after a launch, the launched daemon's)
--- @field conn? loomworks.daemon.Conn when "connected"
--- @field detail? string the reason of "launch_failed", the endpoint check's or client's error of "endpoint" / "unreachable"
--- @field launched? boolean the daemon connected to was launched here
--- @field launch_state? table what the launch returned (its live state), as is

--- Connect to the workspace daemon of `root`, or launch it first when none
--- runs (§19.10 "Connect or start"). Never prints. Outcomes:
---   "connected"      an authenticated connection (`conn`) to the live daemon
---                    (`opts.connect`), or — with `opts.connect_launched` —
---                    to the one launched here (`launched`)
---   "live"           a live daemon, not connected (`opts.connect` false)
---   "launched"       none ran; one was launched, not connected
---   "launch_failed"  none ran; the launch failed (`detail`)
---   "starting"       a daemon still starting after the one bounded wait
---   "hung"           the holder is hung (§19.5), and `opts.on_hung` did not
---                    recover it
---   "elsewhere"      another holder: `st.kind` "foreign" (another host),
---                    "attached" (an attached run, §19.2), or "starting"
---                    (seen only after `on_hung` recovered)
---   "endpoint" | "untrusted" | "unreachable"  as for `open`
--- opts:
---   step_ms           bound of each step (the wait on a starting daemon,
---                     connect + handshake); required
---   launch            fun(root): ok, state|reason (default
---                     loomworks.daemon.launch.launch)
---   connect           open the live daemon (default true)
---   connect_launched  also open a daemon launched here (default false)
---   on_hung           fun(st): table|nil — recover a hung holder and return
---                     the new state, or nil to give up ("hung")
---   session           extra client.session options (`on_message`, …)
--- @param root string
--- @param opts table
--- @return loomworks.daemon.ConnectResult
function M.connect_or_start(root, opts)
    local step = opts.step_ms
    local st = M.await_start(root, inspect.state(root), step)
    if st.kind == "starting" then return { outcome = "starting", st = st } end
    if st.kind == "hung" then
        local nst = opts.on_hung and opts.on_hung(st) or nil
        if not nst then return { outcome = "hung", st = st } end
        st = nst
    end
    if st.kind == "foreign" or st.kind == "attached" or st.kind == "starting" then
        return { outcome = "elsewhere", st = st }
    end
    local function open(s, launched)
        local sopts = vim.tbl_extend("force", {}, opts.session or {}, { step_ms = step })
        local conn, why, detail = M.open(root, s, sopts)
        if not conn then return { outcome = why, st = s, detail = detail, launched = launched } end
        return { outcome = "connected", st = s, conn = conn, launched = launched }
    end
    if st.kind == "live" then
        if opts.connect == false then return { outcome = "live", st = st } end
        return open(st, false)
    end
    -- none, stale or unreadable: launch (a dead holder's lock is reclaimed by
    -- the new daemon itself; a launch another client's daemon won is that
    -- daemon, live).
    local launch = opts.launch or require("loomworks.daemon.launch").launch
    local ok, res = launch(root)
    if not ok then return { outcome = "launch_failed", st = st, detail = tostring(res) } end
    local lst = type(res) == "table" and res or inspect.state(root)
    if opts.connect_launched and lst.kind == "live" then
        local r = open(lst, true)
        r.launch_state = res
        return r
    end
    return { outcome = "launched", st = lst, launched = true, launch_state = res }
end

return M
