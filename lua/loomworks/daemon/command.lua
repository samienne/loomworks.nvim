--- loomworks/daemon/command.lua — `lw daemon <sub>` (spec §19.5, §19.11).
---
--- Kept out of cli.lua (which sits at Lua's 200-local limit); cli.lua passes
--- its output helpers in `host`:
---   host.out(line)        stdout line
---   host.note(line)       stderr line
---   host.die(msg, code)   print `lw: <msg>` and exit (never returns)
---   host.finish(code)     run the exit hooks and exit
---   host.on_exit(fn)      register an exit hook (interrupts included)
---   host.config           lw's settings table (runtime-mode, …)
---
--- None of these sub-commands loads the workspace.
---
--- Deletion safety: the handle and (POSIX) the socket are removed only while
--- holding the runtime lock R — by the daemon itself, or here after R was
--- reclaimed from a dead or killed holder — and the handle only when it names
--- that holder (pid + start time). A kill targets only the holder named by
--- R's record, verified by process id AND start time (loomworks.proc), on
--- this host, never an editor holder, never this process or an ancestor
--- (loomworks.lock_break.can_break).

local runtime = require("loomworks.daemon.runtime")
local inspect = require("loomworks.daemon.inspect")
local rlock = require("loomworks.daemon.rlock")
local dhandle = require("loomworks.daemon.handle")
local lock_record = require("loomworks.lock_record")

local M = {}

M.SUBS = { "status", "list", "stop", "restart", "kill", "run" }

--- How long `stop` waits for the daemon to release R (§19.11).
M.STOP_WAIT_MS = 10000
--- Between two `stop` requests that got no answer (`stop` asks again while
--- STOP_WAIT_MS lasts).
M.RETRY_MS = 250
--- How long `stop --force` waits after asking before it kills (§19.5 step 1).
M.ASK_MS = 5000

--- The resolved runtime mode for a settings table, with a description of
--- where it came from. Reports an invalid configured value once.
--- @param host table
--- @return string mode, string source_text
function M.mode(host)
    local cfg = host.config or {}
    local mode, source, warning = runtime.resolve(cfg[runtime.SETTING])
    if warning and host.note then host.note("lw: " .. warning) end
    local src = ({ env = runtime.ENV, setting = "setting " .. runtime.SETTING, default = "default" })[source]
    return mode, src
end

local function age(secs) return lock_record.age_text(math.max(0, tonumber(secs) or 0)) end

--- The value of `--name <v>` in args, if any.
local function opt_value(args, name)
    for i = 3, #args do
        if args[i] == name then return args[i + 1] end
        local v = type(args[i]) == "string" and args[i]:match("^" .. name:gsub("%-", "%%-") .. "=(.*)$")
        if v then return v end
    end
    return nil
end

local function has(args, flag)
    for i = 3, #args do if args[i] == flag then return true end end
    return false
end

--- Send one frozen control request to the daemon a state describes —
--- only when the handle names this workspace's own endpoint
--- (loomworks.daemon.endpoint.check); otherwise nothing is connected to and
--- the error starts with "untrusted".
--- @param st table inspect.state(root)
--- @param kind string
--- @param timeout_ms? integer
--- @return table|nil reply, string|nil err
function M.request(st, kind, timeout_ms)
    local h = st.handle
    if not h or not h.valid then return nil, "no handle" end
    local ok, why = require("loomworks.daemon.endpoint").check(st.root, h.endpoint)
    if not ok then return nil, why end
    return require("loomworks.daemon.client").call(h.endpoint, kind, { timeout_ms = timeout_ms or 2000 })
end

--- Ask a live daemon for its status over the endpoint (frozen `status`).
--- @return table|nil reply, string|nil err
function M.query(st, timeout_ms)
    return M.request(st, "status", timeout_ms)
end

--- `lw daemon status`: the mode, then the daemon as its files describe it,
--- and — for a live daemon on this host — what it answers. Never launches.
--- @param root string|nil
--- @param host table
--- @return integer
function M.status(root, host)
    local out = host.out
    local mode, src = M.mode(host)
    out(string.format("Runtime mode   %s (%s)", mode, src))
    if not root then
        out("Daemon         no loomworks workspace here")
        return 0
    end
    local st = inspect.state(root)
    local own = require("loomworks.daemon.version").identity()
    if st.kind == "none" then
        out("Daemon         not running" .. (mode == runtime.DAEMON and " (starts on the next command)" or ""))
    else
        out("Daemon         " .. inspect.row(st, mode, own))
    end
    local lk, h = st.lock, st.handle
    if lk and st.kind ~= "stale" then
        out(string.format("  holder       pid %s on %s, %s", tostring(lk.pid or "?"), tostring(lk.host or "?"),
            tostring(lk.mode or lk.kind or "?")))
        out("  heartbeat    " .. age(lk.age) .. " ago")
    end
    if h and h.valid and (st.kind == "live" or st.kind == "hung" or st.kind == "foreign") then
        local sch = type(h.schemas) == "table" and h.schemas or {}
        out(string.format("  version      %s (protocol %s, schemas user %s / cache %s)", tostring(h.lw_version or "?"),
            tostring(h.protocol), tostring(sch.user or "?"), tostring(sch.cache or "?")))
        out("  endpoint     " .. tostring(h.endpoint))
        if type(h.started_at) == "number" then out("  started      " .. age(os.time() - h.started_at) .. " ago") end
    end
    if st.kind == "live" then
        local r, err = M.query(st, 5000)
        if r then
            out(string.format("  answers      %d client%s%s", tonumber(r.clients) or 0, r.clients == 1 and "" or "s",
                r.retiring and ", retiring (exits when idle)" or ""))
        elseif tostring(err):match("^untrusted handle") then
            out("  answers      NOT ASKED — " .. tostring(err))
        elseif tostring(err):match("^untrusted") then
            out("  answers      NO — the endpoint did not authenticate as this machine's daemon (untrusted)")
        else
            out("  answers      no (" .. tostring(err) .. ") — lw daemon stop --force recovers a hung daemon")
        end
    end
    -- The runtime log (§19.10), when there is one.
    local logp = require("loomworks.daemon.paths").log_path(root)
    local lst = (vim.uv or vim.loop).fs_lstat(logp)
    if lst and lst.type == "file" then out("Log            " .. logp) end
    return 0
end

--- Remove the handle and socket of a daemon that is gone, holding R
--- (reclaiming it from a dead holder). Returns true when R could be taken.
--- @param root string
--- @param gone? table the gone holder's R record (its handle only is removed)
--- @return boolean
function M.clear_stale(root, gone)
    local h = dhandle.read(root)
    local R = rlock.try_acquire(root, { mode = "attached", command = "daemon stop" })
    if not R then return false end
    local expect = gone and type(gone.pid) == "number" and { pid = gone.pid, start_time = gone.start_time } or nil
    if dhandle.remove(root, expect) and h and h.valid then
        require("loomworks.daemon.endpoint").cleanup(root, h.endpoint)
    end
    rlock.release(R)
    return true
end

--- Wait until R no longer carries the record `info` (released or replaced).
local function wait_released(root, info, ms)
    return vim.wait(ms, function()
        local cur = rlock.read(root)
        return cur == nil or cur.lock_nonce ~= info.lock_nonce
    end, 50)
end

--- The not-responding message (§19.5).
local function not_responding(info)
    return string.format("the workspace daemon (pid %s) is not responding — recover with: lw daemon stop --force",
        tostring(info.pid or "?"))
end

--- Forced recovery of R (§19.5 steps 1–5): `ask` sends `stop` first (stop
--- --force), `kill` skips it. Returns 0 or dies.
function M.force(root, host, st, ask)
    local ok, res, info = M.recover(root, st, ask, {
        note = function(line) host.note(line) end,
        ctx = { what = "the workspace runtime", command = "lw daemon stop" },
    })
    if not ok then host.die(res, 1) end
    if res == "replaced" then
        host.out("stopped the workspace daemon (pid " .. info.pid .. "); another runtime has started since")
        return 0
    end
    host.out(string.format("%s the workspace daemon (pid %d)", res, info.pid))
    return 0
end

--- The forced recovery of R (§19.5 steps 1–5) without exiting: `ask` sends
--- `stop` first and waits about ASK_MS; then the holder's tree is killed and
--- verified gone (loomworks.lock_break), R is reclaimed by nonce with the
--- handle and socket removed under it, and an interrupted commit journal is
--- rolled forward. Every ask and kill is printed (`opts.note`) and recorded
--- in the runtime log. Returns true + "stopped" | "killed" | "replaced"
--- (another runtime started meanwhile) + the holder info, or false + the
--- refusal / error.
--- @param root string
--- @param st table inspect.state(root) with a live / hung same-host holder
--- @param ask boolean
--- @param opts { note: fun(line: string), ctx: table }
--- @return boolean ok, string result_or_err, table info
function M.recover(root, st, ask, opts)
    local lb = require("loomworks.lock_break")
    local proc = require("loomworks.proc")
    local info = st.lock
    local ctx = opts.ctx
    ctx.root = ctx.root or root
    ctx.remedy = ctx.remedy or ("delete " .. require("loomworks.daemon.paths").lock_path(root) .. " by hand")
    local ok, why = lb.can_break(info, ctx)
    if not ok then return false, why, info end
    local report = function(line) opts.note("lw: " .. line); M.record(root, line) end
    local gone = false
    if ask and st.handle and st.handle.valid then
        local r = M.query_stop(st)
        if r then
            report(string.format("asked the workspace daemon (pid %d) to stop", info.pid))
            gone = vim.wait(M.ASK_MS, function() return proc.alive(info.pid, info.start_time) == false end, 50)
        end
    end
    if not gone then
        local bok, berr = lb.break_holder(info, ctx, { mode = "now", report = report, log = function() end })
        if not bok then return false, berr, info end
    end
    -- Step 4: reclaim R (the dead holder's record, nonce-checked), removing
    -- its handle and socket under it.
    if not M.clear_stale(root, info) then
        local now = rlock.read(root)
        if now and now.lock_nonce ~= info.lock_nonce then return true, "replaced", info end
        return false, "stopped the workspace daemon (pid " .. info.pid .. ") but could not reclaim its runtime lock",
            info
    end
    -- Step 5: complete an interrupted multi-file commit (§19.4) if one is left.
    local uv = vim.uv or vim.loop
    if uv.fs_stat(root .. "/" .. require("loomworks.txn").JOURNAL) then
        local tok, msg = require("loomworks.op_lock").acquire(root, "daemon recovery")
        if tok then
            if tok.recovered then opts.note("lw: " .. tok.recovered) end
            require("loomworks.op_lock").release(tok)
        elseif msg then
            opts.note("lw: " .. msg)
        end
    end
    return true, gone and "stopped" or "killed", info
end

--- Record a kill / forced recovery in the runtime log (spec §19.5, §19.10).
--- @param root string
--- @param line string
function M.record(root, line)
    require("loomworks.daemon.rlog").write(root, line)
end

--- Send `stop` (best effort, short timeout). Returns the reply or nil.
function M.query_stop(st, timeout_ms)
    return M.request(st, "stop", timeout_ms or 2000)
end

--- `lw daemon stop [--force]` / `lw daemon kill`.
--- @param root string
--- @param host table
--- @param opts { force?: boolean, kill?: boolean }
--- @return integer
function M.stop(root, host, opts)
    local st = inspect.state(root)
    local lk = st.lock or {}
    if st.kind == "none" then
        host.out("no workspace daemon is running")
        return 0
    end
    if st.kind == "foreign" then
        host.die(string.format("the workspace daemon runs on %s (pid %s) — it cannot be stopped from here; "
            .. "run `lw daemon stop` there", tostring(lk.host), tostring(lk.pid)), 1)
    end
    if st.kind == "attached" then
        host.die(string.format("no daemon: the workspace runtime is %s (pid %s), a command running without "
            .. "a daemon — wait for it to finish", rlock.holder_text(lk), tostring(lk.pid)), 1)
    end
    if st.kind == "stale" or st.kind == "unreadable" then
        local h = st.handle or {}
        if not M.clear_stale(root, (lk.pid and lk) or (h.valid and h) or nil) then
            host.die("could not clear the stale daemon files: another runtime holds the workspace now", 1)
        end
        host.out("cleared a stale daemon handle" .. ((lk.pid or h.pid) and (" (pid " .. tostring(lk.pid or h.pid)
            .. ")") or ""))
        return 0
    end
    -- live, starting or hung, on this host.
    if opts.kill then return M.force(root, host, st, false) end
    if opts.force then return M.force(root, host, st, true) end
    if st.kind == "hung" then host.die(not_responding(lk), 1) end
    if st.kind == "starting" then
        -- A daemon that holds R (its heartbeat fresh) but has not published
        -- its handle yet: on a loaded machine its start, or a handle rewrite
        -- a reader keeps blocking (§19.6), can take seconds. Wait the stop
        -- window for it (a fixed 3 s used to call such a daemon "not
        -- responding"); one that exited meanwhile is handled as what is left.
        vim.wait(M.STOP_WAIT_MS, function() st = inspect.state(root); return st.kind ~= "starting" end, 50)
        if st.kind == "starting" or st.kind == "hung" then host.die(not_responding(lk), 1) end
        if st.kind ~= "live" then
            if opts._again then host.die(not_responding(lk), 1) end
            return M.stop(root, host, vim.tbl_extend("force", opts, { _again = true }))
        end
    end
    -- Ask until R is released, within STOP_WAIT_MS. The request itself may use
    -- what is left of that window: a healthy daemon slowed down by a loaded
    -- machine (CI running every spec at once; an antivirus holding the
    -- handle file it rewrites) could take longer than a fixed 2 s to answer
    -- the handshake, and the client then gave up before `stop` was even sent
    -- — reported as "not responding" although the daemon was fine. A request
    -- that fails early (the pipe busy, a connection reset) is sent again. A
    -- hung daemon is still reported after STOP_WAIT_MS, as before.
    local uv = vim.uv or vim.loop
    uv.update_time()
    local deadline = uv.now() + M.STOP_WAIT_MS
    local sent = false
    while true do
        if not sent then
            uv.update_time()
            local r, err = M.query_stop(st, math.max(M.RETRY_MS, deadline - uv.now()))
            if err and tostring(err):match("^untrusted handle") then host.die(tostring(err), 1) end
            if err and tostring(err):match("^untrusted") then
                host.die("the daemon endpoint " .. tostring(st.handle.endpoint) .. " did not authenticate as "
                    .. "this machine's daemon (untrusted) — not sending it anything; `lw daemon stop --force` "
                    .. "stops the runtime lock's holder", 1)
            end
            sent = r ~= nil
        end
        uv.update_time()
        local left = deadline - uv.now()
        if left <= 0 then break end
        -- Once `stop` was accepted, wait out the rest; otherwise re-check
        -- shortly and ask again.
        if wait_released(root, lk, sent and left or math.min(left, M.RETRY_MS)) then
            host.out("stopped the workspace daemon (pid " .. tostring(lk.pid) .. ")")
            return 0
        end
        uv.update_time()
        if uv.now() >= deadline then break end
    end
    if not wait_released(root, lk, 0) then host.die(not_responding(lk), 1) end
    host.out("stopped the workspace daemon (pid " .. tostring(lk.pid) .. ")")
    return 0
end

--- `lw daemon run [--root <dir>]`: serve in the foreground until stopped.
--- @param root string|nil
--- @param args string[]
--- @param host table
--- @return integer
function M.run_server(root, args, host)
    -- The root exactly as the launching client named it (the per-user names
    -- hash its real path, loomworks.daemon.paths).
    local r = opt_value(args, "--root")
    if r then root = (r:gsub("\\", "/"):gsub("/+$", "")) end
    if not root then host.die("no loomworks.json found (searched up from cwd) — `lw daemon run` needs a workspace") end
    local server_mod = require("loomworks.daemon.server")
    local rt = require("loomworks.daemon.runtime")
    local srv = server_mod.new(root, {
        exit = function(code) host.finish(code) end,
        log = require("loomworks.daemon.rlog").writer(root),
        idle_seconds = rt.idle_seconds(host.config),
    })
    -- Routed operations (§19.15, §19.19 step 3): the build service, with the
    -- host's workspace load (loaded on the first build, then kept live).
    if host.build then require("loomworks.daemon.service").attach(srv, host.build) end
    local ok, err, code = srv:start()
    if not ok then
        if code == server_mod.EXIT_HELD then
            host.note("lw: another runtime holds this workspace: " .. tostring(err))
            host.finish(code)
        end
        host.die("cannot start the workspace daemon: " .. tostring(err), code or 1)
    end
    if host.on_exit then host.on_exit(function() srv:stop("interrupted", 130) end) end
    host.note(string.format("lw: workspace daemon pid %d serving %s on %s", srv.pid, srv.root, srv.address))
    while not srv.stopped do
        vim.wait(3600 * 1000, function() return srv.stopped end, 200)
    end
    return 0
end

--- `lw daemon restart [--force]`: stop (if running), then launch.
--- @param root string
--- @param host table
--- @param args string[]
--- @return integer
function M.restart(root, host, args)
    local st = inspect.state(root)
    if st.kind ~= "none" then M.stop(root, host, { force = has(args, "--force") }) end
    local ok, res = require("loomworks.daemon.launch").launch(root)
    if not ok then
        M.record(root, "lw daemon restart: could not start the workspace daemon: " .. tostring(res))
        host.die("could not start the workspace daemon (" .. tostring(res) .. ")", 1)
    end
    M.record(root, "lw daemon restart: started the workspace daemon (pid " .. tostring(res.handle.pid) .. ")")
    host.out("started the workspace daemon (pid " .. tostring(res.handle.pid) .. ")")
    return 0
end

-- ---------------------------------------------------------------------------
-- Every daemon of this user (spec §19.6.1)
-- ---------------------------------------------------------------------------

--- The `--under <dir>` filter, made absolute against the cwd.
local function under_of(args, host)
    local u = opt_value(args, "--under")
    if not u then
        for i = 3, #args do
            if args[i] == "--under" then host.die("--under needs a directory", 2) end
        end
        return nil
    end
    u = u:gsub("\\", "/")
    if not (u:match("^/") or u:match("^%a:/")) then
        u = ((vim.uv or vim.loop).cwd():gsub("\\", "/")) .. "/" .. u
    end
    return (u:gsub("/+$", ""))
end

local STATE_TEXT = { starting = "starting", hung = "not responding", stray = "stray", unknown_root = "stray" }

--- The STATE column of one entry.
function M.state_text(e)
    if e.state == "live" then
        if e.busy then return "busy" end
        if (e.clients or 0) > 0 then return "active" end
        if e.idle_since then return "idle " .. age(os.time() - e.idle_since) end
        return "idle"
    end
    return STATE_TEXT[e.state] or tostring(e.state)
end

--- The JSON shape of one entry (§19.6.1; absent values are null).
local function json_entry(e)
    local null = vim.NIL
    local function v(x) if x == nil then return null end return x end
    return {
        pid = e.pid, start_time = v(e.start_time), root = v(e.root), state = e.state, reason = v(e.reason),
        uptime_s = v(e.uptime_s), started_at = v(e.started_at), clients = v(e.clients), busy = v(e.busy),
        idle_since = v(e.idle_since), lw_version = v(e.lw_version), protocol = v(e.protocol),
        endpoint = v(e.endpoint),
    }
end

--- The summary line's counts text: "3 daemons (1 idle, 1 stray)".
function M.summary(list)
    local n, idle, stray = require("loomworks.daemon.discover").counts(list)
    local extra = {}
    if idle > 0 then extra[#extra + 1] = idle .. " idle" end
    if stray > 0 then extra[#extra + 1] = stray .. " stray" end
    return n .. (n == 1 and " daemon" or " daemons") .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or "")
end

--- `lw daemon list [--json] [--under <dir>]`. Never launches, connects or
--- signals; writes nothing.
--- @param args string[]
--- @param host table
--- @return integer
function M.list(args, host)
    local list, ms = require("loomworks.daemon.discover").list({ under = under_of(args, host) })
    if has(args, "--json") then
        -- (Built by hand so an empty list is `[]` under every host's encoder.)
        local enc = require("loomworks.io").encode_sorted
        local ds = {}
        for _, e in ipairs(list) do ds[#ds + 1] = enc(json_entry(e)) end
        host.out(string.format('{"daemons":[%s],"scan_ms":%d,"schema":1}', table.concat(ds, ","),
            math.floor(ms + 0.5)))
        return 0
    end
    if #list == 0 then
        host.out("no workspace daemons are running")
        return 0
    end
    local rows = { { "PID", "UPTIME", "STATE", "CLIENTS", "VERSION", "ROOT" } }
    for _, e in ipairs(list) do
        local root = e.root or "(root unknown)"
        if e.reason and (e.state == "stray") then root = root .. "  (" .. e.reason .. ")" end
        rows[#rows + 1] = {
            tostring(e.pid), e.uptime_s and age(e.uptime_s) or "?", M.state_text(e),
            e.clients and tostring(e.clients) or "-", e.lw_version and tostring(e.lw_version) or "-", root,
        }
    end
    local w = {}
    for _, r in ipairs(rows) do
        for i = 1, #r - 1 do w[i] = math.max(w[i] or 0, #r[i]) end
    end
    for _, r in ipairs(rows) do
        local cells = {}
        for i = 1, #r - 1 do cells[i] = r[i] .. string.rep(" ", w[i] - #r[i]) end
        cells[#r] = r[#r]
        host.out(table.concat(cells, "  "))
    end
    host.out(M.summary(list) .. " — stop them with: lw daemon stop --all")
    return 0
end

--- Kill a stray daemon (§19.6.1): only after its command line is read again
--- and is still `lw … daemon run` for that root with the same start time;
--- never this process or an ancestor. If it held its workspace's runtime
--- lock, that lock is reclaimed (§19.5). Returns true or false + reason.
function M.kill_stray(e)
    local proc = require("loomworks.proc")
    local args = proc.cmdline(e.pid, e.start_time)
    if not args or not proc.is_daemon_for(args, e.root) or (e.root == nil and require("loomworks.daemon.discover")
            .root_of(args) ~= nil) then
        return false, "it is no longer the daemon that was listed (not killed)"
    end
    if proc.ancestors()[e.pid] then return false, "it is this process or its ancestor (not killed)" end
    local ok, err = proc.kill_tree(e.pid, e.start_time)
    if not ok then return false, err end
    if e.root then
        M.record(e.root, string.format("lw daemon kill --all --strays: killed the stray daemon (pid %d)", e.pid))
        local lk = rlock.read(e.root)
        if lk and lk.pid == e.pid and lk.start_time == e.start_time then M.clear_stale(e.root, lk) end
    end
    return true
end

--- `lw daemon stop --all [--force]` / `lw daemon kill --all [--strays]`
--- (§19.6.1): the per-workspace stop / kill for every listed daemon that is
--- its workspace's runtime; strays only with `--strays` (kill). Exit 0 when
--- no listed daemon is left running, else 1.
--- @param args string[]
--- @param host table
--- @param opts { force?: boolean, kill?: boolean }
--- @return integer
function M.stop_all(args, host, opts)
    local strays = has(args, "--strays")
    if strays and not opts.kill then host.die("--strays kills: use `lw daemon kill --all --strays`", 2) end
    local list = require("loomworks.daemon.discover").list({ under = under_of(args, host) })
    if #list == 0 then
        host.out("no workspace daemons are running")
        return 0
    end
    local proc = require("loomworks.proc")
    local left = 0
    for _, e in ipairs(list) do
        local label = (e.root or "(root unknown)") .. ": "
        if e.state == "stray" or e.state == "unknown_root" then
            if strays then
                local ok, why = M.kill_stray(e)
                if ok then
                    host.out(label .. "killed the stray daemon (pid " .. e.pid .. ")")
                else
                    host.note("lw: " .. label .. "stray daemon pid " .. e.pid .. ": " .. tostring(why))
                    left = left + 1
                end
            else
                host.note(string.format("lw: %sskipped stray daemon pid %d (%s) — kill it with: "
                    .. "lw daemon kill --all --strays", label, e.pid, tostring(e.reason or "not its workspace's runtime")))
                left = left + 1
            end
        else
            local died
            local sub = {
                out = function(line) host.out(label .. line) end,
                note = function(line) host.note((line:gsub("^lw: ", "lw: " .. label))) end,
                die = function(msg) died = msg; error("lw-daemon-stop-all", 0) end,
                finish = function() error("lw-daemon-stop-all", 0) end,
                config = host.config,
            }
            local ok, err = pcall(M.stop, e.root, sub, { force = opts.force, kill = opts.kill })
            if not ok and err ~= "lw-daemon-stop-all" then died = tostring(err) end
            if died then host.note("lw: " .. label .. died) end
            if proc.alive(e.pid, e.start_time) == true then
                vim.wait(2000, function() return proc.alive(e.pid, e.start_time) ~= true end, 50)
            end
            if proc.alive(e.pid, e.start_time) == true then left = left + 1 end
        end
    end
    return left == 0 and 0 or 1
end

--- Dispatch `lw daemon [<sub>]`.
--- @param sub string|nil
--- @param root string|nil
--- @param args string[]
--- @param host table
--- @return integer
function M.run(sub, root, args, host)
    sub = sub or "status"
    if sub == "status" then return M.status(root, host) end
    if sub == "run" then return M.run_server(root, args, host) end
    if sub == "list" then return M.list(args, host) end
    local known = { stop = true, kill = true, restart = true }
    if not known[sub] then
        host.die("unknown daemon subcommand '" .. tostring(sub) .. "' — use " .. table.concat(M.SUBS, "|")
            .. " (see `lw help daemon`)", 2)
    end
    if has(args, "--all") and sub ~= "restart" then
        return M.stop_all(args, host, { force = has(args, "--force"), kill = sub == "kill" })
    end
    if has(args, "--strays") or opt_value(args, "--under") then
        host.die("--strays and --under go with --all (`lw daemon kill --all --strays`)", 2)
    end
    if not root then host.die("no loomworks.json found (searched up from cwd)") end
    if sub == "restart" then return M.restart(root, host, args) end
    return M.stop(root, host, { force = has(args, "--force"), kill = sub == "kill" })
end

return M
