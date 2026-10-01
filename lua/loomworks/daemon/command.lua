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

M.SUBS = { "status", "stop", "restart", "kill", "run" }

--- How long `stop` waits for the daemon to release R (§19.11).
M.STOP_WAIT_MS = 10000
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

--- Ask a live daemon for its status over the endpoint (frozen `status`).
--- @return table|nil reply, string|nil err
function M.query(st, timeout_ms)
    local h = st.handle
    if not h or not h.valid then return nil, "no handle" end
    return require("loomworks.daemon.client").call(h.endpoint, "status", { timeout_ms = timeout_ms or 2000 })
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
        local r, err = M.query(st)
        if r then
            out(string.format("  answers      %d client%s%s", tonumber(r.clients) or 0, r.clients == 1 and "" or "s",
                r.retiring and ", retiring (exits when idle)" or ""))
        elseif tostring(err):match("^untrusted") then
            out("  answers      NO — the endpoint did not authenticate as this machine's daemon (untrusted)")
        else
            out("  answers      no (" .. tostring(err) .. ") — lw daemon stop --force recovers a hung daemon")
        end
    end
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
    local lb = require("loomworks.lock_break")
    local proc = require("loomworks.proc")
    local info = st.lock
    local ctx = { what = "the workspace runtime", command = "lw daemon stop", unlock = nil }
    local ok, why = lb.can_break(info, ctx)
    if not ok then host.die(why, 1) end
    local report = function(line) host.note("lw: " .. line); M.record(root, line) end
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
        if not bok then host.die(berr, 1) end
    end
    -- Step 4: reclaim R (the dead holder's record, nonce-checked), removing
    -- its handle and socket under it.
    if not M.clear_stale(root, info) then
        local now = rlock.read(root)
        if now and now.lock_nonce ~= info.lock_nonce then
            host.out("stopped the workspace daemon (pid " .. info.pid .. "); another runtime has started since")
            return 0
        end
        host.die("stopped the workspace daemon (pid " .. info.pid .. ") but could not reclaim its runtime lock", 1)
    end
    -- Step 5: complete an interrupted multi-file commit (§19.4) if one is left.
    local uv = vim.uv or vim.loop
    if uv.fs_stat(root .. "/" .. require("loomworks.txn").JOURNAL) then
        local tok, msg = require("loomworks.op_lock").acquire(root, "daemon recovery")
        if tok then
            if tok.recovered then host.note("lw: " .. tok.recovered) end
            require("loomworks.op_lock").release(tok)
        elseif msg then
            host.note("lw: " .. msg)
        end
    end
    host.out(string.format("%s the workspace daemon (pid %d)", gone and "stopped" or "killed", info.pid))
    return 0
end

--- Record a kill / forced recovery (spec §19.5: printed on stderr and
--- recorded — in the workspace log until the runtime log exists).
--- @param root string
--- @param line string
function M.record(root, line)
    pcall(function()
        local lg = require("loomworks.log").new({ path = root .. "/.nvim/loomworks.log" })
        lg:info("%s", line)
    end)
end

--- Send `stop` (best effort, short timeout). Returns the reply or nil.
function M.query_stop(st)
    local h = st.handle
    if not h or not h.valid then return nil end
    return require("loomworks.daemon.client").call(h.endpoint, "stop", { timeout_ms = 2000 })
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
        vim.wait(3000, function() st = inspect.state(root); return st.kind ~= "starting" end, 50)
        if st.kind ~= "live" then host.die(not_responding(lk), 1) end
    end
    local _, err = M.query_stop(st)
    if err and tostring(err):match("^untrusted") then
        host.die("the daemon endpoint " .. tostring(st.handle.endpoint) .. " did not authenticate as this "
            .. "machine's daemon (untrusted) — not sending it anything; `lw daemon stop --force` stops the "
            .. "runtime lock's holder", 1)
    end
    if not wait_released(root, lk, M.STOP_WAIT_MS) then host.die(not_responding(lk), 1) end
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
    local srv = server_mod.new(root, {
        exit = function(code) host.finish(code) end,
        log = host.log,
    })
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
    if not ok then host.die("could not start the workspace daemon (" .. tostring(res) .. ")", 1) end
    host.out("started the workspace daemon (pid " .. tostring(res.handle.pid) .. ")")
    return 0
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
    local known = { stop = true, kill = true, restart = true }
    if not known[sub] then
        host.die("unknown daemon subcommand '" .. tostring(sub) .. "' — use " .. table.concat(M.SUBS, "|")
            .. " (see `lw help daemon`)", 2)
    end
    if not root then host.die("no loomworks.json found (searched up from cwd)") end
    if sub == "restart" then return M.restart(root, host, args) end
    return M.stop(root, host, { force = has(args, "--force"), kill = sub == "kill" })
end

return M
