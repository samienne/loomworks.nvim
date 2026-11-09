--- loomworks/daemon/client/relay.lua — the editor's side of the `--stdio`
--- relay (spec §19.16 "Through the relay", §19.10 "Connections"): the only
--- way the editor reaches a workspace daemon.
---
--- The editor never reads the handle or the machine key to connect: it spawns
--- `<binary> daemon run --root <root> --stdio [--no-launch [--retiring <id> |
--- --skip-instance <id>]]` and speaks the protocol over the relay's standard
--- input and output. The relay runs the socket handshake (and, in its
--- ordinary form, launches the shared daemon) on the editor's behalf and
--- forwards the daemon's `welcome` with `daemon = {…}` and `via = "relay"`
--- added; there is no `challenge` on this side.
---
--- The relay process (normative, §19.16 "The relay process"):
---   * spawned hidden and NOT detached, plain pipes for standard input,
---     output and error, the per-user state directory as working directory,
---     this process's environment with `LW_ROOT` and the selection's
---     (loomworks.daemon.client.settings);
---   * no handshake timeout here: every step of a relay is bounded inside
---     the relay, and the waiting forms wait without a bound by design;
---   * ended by closing its standard input (it exits 0); only when it has not
---     exited KILL_MS later is its own pid killed — a plain kill, NEVER a
---     process-tree kill (on Windows the daemon a relay launched is its child
---     by parent pid: a tree kill would take the shared daemon down). An
---     older pin's attached `--stdio` runtime (a `welcome` without `via`) is
---     ended the same way;
---   * the exit status is reported only for a relay that exits before the
---     editor received `welcome` (and that the editor did not end itself);
---     after `welcome` any exit or EOF is a drop of the connection. The exit
---     and the EOF on standard output arrive in either order: once it exited,
---     its remaining EOFs are waited for EOF_GRACE_MS; once its standard
---     output ended before `welcome`, its exit is waited for EXIT_WAIT_MS,
---     then it is an internal error and the relay is ended;
---   * the KILL_MS timer is unref'd: at editor quit it never fires (on
---     Windows the libuv job object ends the relay; on POSIX a relay that
---     ignores EOF is orphaned — accepted);
---   * standard error is kept: its `lw: …` line is the Runtime line's detail,
---     and a status-14 relay's last line `retiring <id>` (§19.10
---     "Retiring-instance line") names the instance for `--retiring`, passed
---     back to the binary as it came (the editor never interprets an id).
---
--- Libuv callbacks here never call vim.fn; the caller's callbacks are
--- invoked from libuv callbacks and must only schedule.

local uv = vim.uv or vim.loop
local framing = require("loomworks.daemon.client.framing")
local settings = require("loomworks.daemon.client.settings")
local version = require("loomworks.daemon.client.version")

local M = {}

--- Errors a caller distinguishes.
M.ERR_CLOSED = "closed"         -- the daemon closed the connection
M.ERR_TRANSPORT = "transport"   -- no transport was agreed with the daemon: no interface calls

M.KILL_MS = settings.KILL_MS
M.EOF_GRACE_MS = settings.EOF_GRACE_MS
M.EXIT_WAIT_MS = settings.EXIT_WAIT_MS
M.STDERR_LINES = settings.STDERR_LINES

--- The relay forms (§19.16 "Through the relay").
M.FORMS = { ordinary = true, ["no-launch"] = true, retiring = true, skip = true }

--- @class loomworks.daemon.WelcomeRelay  a relay's `welcome.relay` (§19.8 step 4)
--- @field lw_version string the relay's own code identity (§19.9): that of the daemon it would launch

--- @class loomworks.daemon.Conn  the editor's connection to a daemon, over a relay
--- @field pipe table the duplex stream over the relay's standard I/O
--- @field relay loomworks.daemon.RelayProc the relay it runs over
--- @field challenge table the daemon's announced versions (`welcome.daemon`; {} without `via`)
--- @field welcome table the daemon's `welcome` with the relay's additions (§19.8 step 4): `daemon`, `via = "relay"` and `relay` (loomworks.daemon.WelcomeRelay, absent from an older relay)
--- @field transport integer|nil the transport both sides agreed on (§19.9; nil: none agreed)
--- @field closed boolean|nil
--- @field on_close fun(conn: loomworks.daemon.Conn)|nil called once when the connection closes after it was established
local Conn = {}
Conn.__index = Conn

--- Send a request; `cb(reply|nil, err)` on its reply.
--- @param msg table
--- @param cb fun(reply: table|nil, err: any)
function Conn:request(msg, cb)
    if self.closed then return cb(nil, M.ERR_CLOSED) end
    self._next = (self._next or 0) + 1
    msg.req_id = self._next
    self._pending[msg.req_id] = cb
    pcall(function() self.pipe:write(framing.encode(msg)) end)
end

--- Call an interface method (spec §19.20): sends a `call` frame stamped with
--- the interface version; `cb(result|nil, err)` with the `ok` reply's
--- `result`, or the structured error object (`{ code, message, data? }`) — a
--- closed connection is `{ code = "closed" }`, and a connection with no
--- agreed transport fails at once with `{ code = "transport" }` (client-side,
--- never on the wire).
--- @param object string
--- @param iface string
--- @param v integer
--- @param method string
--- @param args table|nil
--- @param cb fun(result: any, err: table|nil)
--- @param env? table<string, string> the client's environment
-- (Defined with `.call = function(self, …)`: the interface ratchet's scanner
-- reads `:call(` as a call site naming its interface and method; this is the
-- transport every such site goes through, not one of them.)
Conn.call = function(self, object, iface, v, method, args, cb, env)
    if type(self.transport) ~= "number" then
        return cb(nil, { code = M.ERR_TRANSPORT,
            message = string.format("no transport agreed with the daemon; interface calls need %d",
                version.PROTOCOL) })
    end
    local frame = require("loomworks.proto.envelope").call(object, iface, v, method, args, env)
    self:request(frame, function(reply, err)
        if not reply then
            if type(err) ~= "table" then err = { code = tostring(err or M.ERR_CLOSED), message = tostring(err) } end
            return cb(nil, err)
        end
        cb(reply.result, nil)
    end)
end

--- Stop reading from the daemon (test seam: a client blocked writing a
--- paused terminal stops reading its connection the same way).
function Conn:pause_reading()
    if self.closed or not self._reader then return end
    pcall(function() self.pipe:read_stop() end)
end

--- Read again after `pause_reading`.
function Conn:resume_reading()
    if self.closed or not self._reader then return end
    pcall(function() self.pipe:read_start(self._reader) end)
end

--- Close the connection (idempotent).
function Conn:close()
    if self.closed then return end
    self.closed = true
    pcall(function() if not self.pipe:is_closing() then self.pipe:close() end end)
    local p = self._pending
    self._pending = {}
    for _, cb in pairs(p) do pcall(cb, nil, M.ERR_CLOSED) end
    if self.on_close then pcall(self.on_close, self) end
end

--- The frame reader of a relay connection: it expects `welcome` first, then
--- hands replies to their pending callbacks and broadcasts to
--- `opts.on_message`. `finish(conn|nil, err, detail)` ends the handshake.
--- @param conn loomworks.daemon.Conn
--- @param opts table
--- @param finish fun(c: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
--- @param is_done fun(): boolean has the handshake ended?
--- @return fun(rerr: string|nil, chunk: string|nil)
local function frame_reader(conn, opts, finish, is_done)
    local decoder = framing.new_decoder(framing.MAX_FRAME)
    local state = "welcome"
    return function(rerr, chunk)
        if rerr or not chunk then
            if not is_done() then return finish(nil, M.ERR_CLOSED) end
            return conn:close()
        end
        local msgs, derr = decoder:push(chunk)
        if not msgs then
            if not is_done() then return finish(nil, M.ERR_CLOSED, derr) end
            return conn:close()
        end
        for _, msg in ipairs(msgs) do
            if state == "welcome" then
                if msg.kind ~= framing.KIND.welcome then return finish(nil, M.ERR_CLOSED) end
                conn.welcome = msg
                conn.on_close = opts.on_close
                state = "ready"
                finish(conn)
            else
                local p = msg.req_id and conn._pending[msg.req_id]
                if p then
                    conn._pending[msg.req_id] = nil
                    if msg.kind == framing.KIND.error then
                        -- An interface call's error is a structured object
                        -- (§19.20); a v0 request's a string.
                        p(nil, type(msg.error) == "table" and msg.error or tostring(msg.error))
                    else
                        p(msg)
                    end
                elseif opts.on_message then
                    pcall(opts.on_message, msg)
                end
            end
        end
    end
end

--- A fresh nonce (64 hex digits) for `hello`, or nil without a random source.
--- @return string|nil
local function nonce()
    local ok, bytes = pcall(uv.random, 32)
    if not ok or type(bytes) ~= "string" or #bytes ~= 32 then return nil end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- The `daemon run` arguments of a relay form (after the executable prefix).
--- @param root string
--- @param form "ordinary"|"no-launch"|"retiring"|"skip"
--- @param instance? string the binary's instance id (retiring, skip), as it named it
--- @return string[]
function M.args(root, form, instance)
    local a = { "daemon", "run", "--root", root, "--stdio" }
    if form == "no-launch" or form == "retiring" or form == "skip" then a[#a + 1] = "--no-launch" end
    if form == "retiring" then
        a[#a + 1] = "--retiring"; a[#a + 1] = instance
    elseif form == "skip" then
        a[#a + 1] = "--skip-instance"; a[#a + 1] = instance
    end
    return a
end

--- The retiring instance a status-14 relay named: the word after
--- `retiring ` on its LAST non-empty standard-error line (§19.10
--- "Retiring-instance line"), passed back to `--retiring` as it came; nil
--- when that line is not one (a relay of an older pin).
--- @param lines string[]
--- @return string|nil instance id
function M.retiring_instance(lines)
    for i = #lines, 1, -1 do
        if lines[i] ~= "" then return lines[i]:match("^retiring (%S+)$") end
    end
    return nil
end

--- The detail line of a relay's standard error: its last `lw: …` line, else
--- its last non-empty line that is not the retiring-instance line.
--- @param lines string[]
--- @return string|nil
function M.detail_line(lines)
    local fallback
    for i = #lines, 1, -1 do
        local l = lines[i]
        if l:sub(1, 4) == "lw: " then return l end
        if not fallback and l ~= "" and not l:match("^retiring ") then fallback = l end
    end
    return fallback
end

--- @class loomworks.daemon.RelayProc  one relay process (the editor's)
--- @field form string
--- @field pid integer|nil
--- @field code integer|nil its exit status, once it exited
--- @field lines string[] its standard-error lines (the last STDERR_LINES)
--- @field eof boolean|nil its standard output reached EOF
--- @field welcomed boolean|nil the editor received `welcome` through it
--- @field ended boolean|nil the editor ended it (closed its standard input): its exit is not mapped
--- @field done boolean|nil the outcome was reported (welcome, or the exit before it)
--- @field conn loomworks.daemon.Conn|nil the connection over it
--- @field kill_ms integer|nil replaces KILL_MS
--- @field _kill_timer uv.uv_timer_t|nil the KILL_MS backstop (unref'd), once ended
--- @field _exit_wait uv.uv_timer_t|nil the EXIT_WAIT_MS bound (unref'd), once standard output ended before `welcome`
local Relay = {}
Relay.__index = Relay

--- @class loomworks.daemon.RelayExit  a relay that exited before `welcome`
--- @field code integer|nil the exit status (nil: unknown — it was ended after a protocol error)
--- @field line string|nil the detail line (M.detail_line)
--- @field retiring string|nil the instance a status-14 relay named (M.retiring_instance)
--- @field form string the relay's form

local function close_handle(h)
    if h then pcall(function() if not h:is_closing() then h:close() end end) end
end

--- A process's exit status from libuv's (code, signal): `128 + signal` when
--- a signal ended it, else the code.
local function exit_status(code, signal)
    code = tonumber(code) or 0
    signal = tonumber(signal) or 0
    if signal ~= 0 and (code == 0 or code == 128 + signal) then return 128 + signal end
    return code
end

--- End the relay (idempotent): close its standard input; when it has not
--- exited KILL_MS later, kill its own process (never its tree).
function Relay:close()
    if self.ended then return end
    self.ended = true
    if self.stdin then
        local s = self.stdin
        -- EOF after what was queued; a shutdown that cannot be queued (the
        -- pipe already closing or broken) closes it outright.
        local ok, res = pcall(function() return s:shutdown(function() close_handle(s) end) end)
        if not ok or not res then close_handle(s) end
    end
    if self.code ~= nil then return end
    local t = uv.new_timer()
    self._kill_timer = t
    -- A timer counts from the loop's cached time, which is stale by however
    -- long this (main-thread) caller ran since the loop last polled.
    pcall(uv.update_time)
    t:start(self.kill_ms or M.KILL_MS, 0, function()
        close_handle(t)
        if self.code == nil and self.proc and not self.proc:is_closing() then
            -- A plain kill of the relay's own pid: on Windows TerminateProcess
            -- of that one process; its children (the shared daemon) live on.
            pcall(function() self.proc:kill("sigkill") end)
        end
    end)
    pcall(function() t:unref() end)
end

--- The duplex stream a Conn writes and reads: writes go to the relay's
--- standard input, reads come from its standard output; closing it ends
--- the relay.
local function duplex(r)
    local s = {}
    function s.write(_, data, cb)
        if r.ended or not r.stdin then return end
        return r.stdin:write(data, cb)
    end
    function s.read_start(_, cb) r.reader = cb end
    function s.read_stop() r.reader = nil end
    function s.is_closing() return r.ended == true end
    function s.close() r:close() end
    return s
end

--- Spawn a relay and speak the protocol through it. Returns the relay, or
--- nil + why when it could not be spawned (nothing to end then).
---
--- opts:
---   argv        the executable prefix (the selected host binary, e.g. `{ bin }`)
---   root        the workspace root
---   env         extra environment (the selection's, `binary.source`)
---   unset       inherited variables to remove (the managed lw's:
---               loomworks.provision.select.child_unset)
---   form        "ordinary"|"no-launch"|"retiring"|"skip"
---   instance    the instance id of a retiring / skip relay
---   client, role  the `hello`'s
---   on_message  fun(msg) broadcasts after `welcome` (from a libuv callback)
---   on_close    fun(conn) once the established connection closes (either side)
---   kill_ms     replaces KILL_MS
---   exit_wait_ms replaces EXIT_WAIT_MS
---   eof_grace_ms replaces EOF_GRACE_MS
---
--- `cb(conn|nil, err, exit)` is called at most once, from a libuv callback:
--- with the connection once `welcome` arrived (`conn.relay` is the relay,
--- `conn.challenge` = `welcome.daemon`, or {} for a `welcome` without `via`);
--- or nil + "exit" + loomworks.daemon.RelayExit when the relay exited before
--- `welcome`; or nil + "protocol" + RelayExit (no `code`) when it sent
--- something else first, or when its standard output ended and it had not
--- exited EXIT_WAIT_MS later (the relay is ended). Never for a relay the editor ended itself.
--- @param opts table
--- @param cb fun(conn: loomworks.daemon.Conn|nil, err: string|nil, exit: loomworks.daemon.RelayExit|nil)
--- @return loomworks.daemon.RelayProc|nil, string|nil
function M.connect(opts, cb)
    local argv = vim.list_extend({}, opts.argv or {})
    local exe = table.remove(argv, 1)
    if not exe then return nil, "no host binary" end
    for _, a in ipairs(M.args(opts.root, opts.form, opts.instance)) do argv[#argv + 1] = a end
    local cwd = settings.state_dir()
    pcall(vim.fn.mkdir, cwd, "p")
    if not uv.fs_stat(cwd) then return nil, "cannot create " .. cwd end
    -- Built here, on the main loop.
    local hello = framing.encode({ kind = framing.KIND.hello, protocol = version.PROTOCOL,
        protocol_min = version.PROTOCOL_MIN, lw_version = version.identity(),
        client = opts.client or "editor", role = opts.role, nonce = nonce() or string.rep("0", 64) })
    local env = settings.env(opts.root, opts.env, opts.unset)

    local r = setmetatable({ form = opts.form, lines = {}, kill_ms = opts.kill_ms }, Relay)
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    r.stdin = stdin
    local out_eof, err_eof, partial = false, false, ""
    local reported = false
    local conn = setmetatable({ _pending = {}, relay = r }, Conn)
    conn.pipe = duplex(r)
    r.conn = conn

    local function report(c, err, info)
        if reported then return end
        reported = true
        r.done = true
        if r.ended and not c then return end -- ended by the editor: not mapped
        cb(c, err, info)
    end
    local function exit_info()
        return { code = r.code, line = M.detail_line(r.lines), retiring = M.retiring_instance(r.lines), form = r.form }
    end
    -- Before `welcome`: report the exit once the status is known and the
    -- output has ended (in either order; the remaining EOFs only briefly,
    -- EOF_GRACE_MS; the exit after the EOF on standard output, EXIT_WAIT_MS).
    local grace
    local function settle()
        if reported or r.welcomed then return end
        if r.code == nil then
            if out_eof and not r._exit_wait then
                local t = uv.new_timer()
                r._exit_wait = t
                local ms = opts.exit_wait_ms or M.EXIT_WAIT_MS
                t:start(ms, 0, function()
                    close_handle(t)
                    if reported or r.welcomed or r.code ~= nil then return end
                    local info = exit_info()
                    info.code = nil
                    info.line = string.format("the relay closed its standard output but had not exited %g s later",
                        ms / 1000)
                    report(nil, "protocol", info)
                    r:close()
                end)
                pcall(function() t:unref() end)
            end
            return
        end
        if out_eof and err_eof then return report(nil, "exit", exit_info()) end
        if not grace then
            grace = uv.new_timer()
            grace:start(opts.eof_grace_ms or M.EOF_GRACE_MS, 0, function()
                close_handle(grace)
                if not reported and not r.welcomed then report(nil, "exit", exit_info()) end
            end)
        end
    end

    -- The handshake: `welcome` first (no challenge on a relay).
    local function finish(c, err, detail)
        if c then
            r.welcomed = true
            local w = c.welcome or {}
            if w.via == "relay" and type(w.daemon) == "table" then
                c.challenge = w.daemon
                c.transport = version.agreed(w.daemon, opts)
            else
                -- An older pin's attached runtime (§19.10 "Compatibility"): no
                -- `daemon` to judge and no transport agreed, so no interface
                -- calls (every pre-0.2.0 transport is incompatible with 1).
                c.challenge = {}
                c.transport = nil
            end
            return report(c)
        end
        if out_eof then return settle() end -- the relay is exiting: wait for its status
        -- Something other than `welcome` first: end it, not mapped by status.
        local info = exit_info()
        info.code = nil
        info.line = "the relay sent no welcome first (" .. tostring(detail or err) .. ")"
        report(nil, "protocol", info)
        r:close()
    end
    local reader = frame_reader(conn, opts, finish, function() return r.welcomed == true end)
    r.reader = reader

    local okp, proc, pid = pcall(uv.spawn, exe, {
        args = argv, env = env, cwd = cwd,
        stdio = { stdin, stdout, stderr },
        hide = true,
        detached = false,
    }, function(code, signal)
        r.code = exit_status(code, signal)
        if r._kill_timer then close_handle(r._kill_timer) end
        if r._exit_wait then close_handle(r._exit_wait) end
        close_handle(r.proc)
        if r.welcomed then
            -- After `welcome` any exit is a drop.
            if not conn.closed then conn:close() end
            return
        end
        settle()
    end)
    if not okp or not proc then
        close_handle(stdin); close_handle(stdout); close_handle(stderr)
        return nil, "cannot start " .. tostring(exe) .. ": " .. tostring(okp and pid or proc)
    end
    r.proc, r.pid = proc, pid

    stdout:read_start(function(rerr, chunk)
        if chunk then
            if r.reader then r.reader(nil, chunk) end
            return
        end
        out_eof = true
        r.eof = true
        close_handle(stdout)
        -- EOF (or a read error): before `welcome` the handshake ends and the
        -- status is awaited; after it, the connection drops.
        if r.reader then r.reader(rerr, nil) elseif r.welcomed and not conn.closed then conn:close() end
        if not r.welcomed then settle() end
    end)
    stderr:read_start(function(_, chunk)
        if chunk then
            partial = partial .. chunk
            while true do
                local nl = partial:find("\n", 1, true)
                if not nl then break end
                r.lines[#r.lines + 1] = (partial:sub(1, nl - 1):gsub("\r$", ""))
                partial = partial:sub(nl + 1)
                if #r.lines > M.STDERR_LINES then table.remove(r.lines, 1) end
            end
            return
        end
        if partial ~= "" then r.lines[#r.lines + 1] = (partial:gsub("\r$", "")); partial = "" end
        err_eof = true
        close_handle(stderr)
        settle()
    end)
    pcall(function() stdin:write(hello) end)
    return r
end

return M
