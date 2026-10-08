--- loomworks/daemon/relay.lua — `lw daemon run --root <root> --stdio`: the
--- standard-I/O relay to the workspace's shared daemon (spec §19.10
--- "Connections", §19.8 "Relay handshake", step 5i).
---
--- The relay is a **connection**, never a daemon: it takes no lock, writes no
--- handle and registers nothing. Its client (the editor, a test) sees the
--- private-pipe handshake — `hello` first, then `welcome`, no `challenge` —
--- while the relay runs the socket handshake on its behalf:
---
---   1. read the client's `hello` from standard input first (status 15 when
---      anything else comes first, or nothing within HELLO_MS);
---   2. connect or start (loomworks.daemon.connect): launch the normal
---      detached daemon when none runs, wait (no bound, while standard input
---      is open) while an attached run holds the runtime lock, check the
---      handle's `key_id` and endpoint, then authenticate with the client's
---      versions (the server's proof is verified before anything is sent);
---   3. forward the daemon's `welcome` with `daemon = {…}` and `via = "relay"`
---      added — or, on a `welcome` that says `retiring`, close that
---      connection, wait (RETIRE_WAIT_MS) for the retiring daemon to release
---      the runtime lock and start over (step 2);
---   4. copy bytes both ways unchanged, with bounded buffering
---      (HIGH_WATER per direction), until either side closes.
---
--- `--no-launch` never launches: it waits for a live daemon (POLL_MS
--- cadence), waits out a retiring one and exits 16 when it is gone with no
--- other live; `--skip-instance <pid>:<start_time>` (with `--no-launch`)
--- additionally treats that one daemon instance as not present.
---
--- Before `welcome` is forwarded a failure writes nothing to standard output
--- and one `lw: …` line to standard error (`M.EXIT`, §19.10 "Relay exit
--- status"). Nothing secret — the machine key, nonces, proofs — is ever
--- printed or logged; the client's `hello` is not echoed anywhere.
---
--- `--private` (tests only, gated by LOOMWORKS_TEST_PRIVATE_STDIO=1) is the
--- attached standard-I/O runtime of loomworks.daemon.stdio instead.

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local connect = require("loomworks.daemon.connect")

local M = {}

--- Exit statuses (spec §19.10 "Relay exit status"). Status 3 ("another
--- daemon won") is never a relay's.
M.EXIT = {
    ok = 0,
    usage = 2,
    launch_failed = 10,
    not_responding = 11,
    untrusted = 12,
    foreign = 13,
    retire_timeout = 14,
    no_hello = 15,
    retired = 16,
}

--- How long the relay waits for the client's `hello` (§19.8 step 1).
M.HELLO_MS = 5000
--- What the relay buffers per direction before it stops reading the other
--- side; it resumes below half (§19.10 "Relay buffering").
M.HIGH_WATER = 4 * 1024 * 1024
--- How long an ordinary relay waits for a retiring daemon to release the
--- runtime lock (`RELAY_RETIRE_WAIT`, §19.8 step 5). The test hook shortens it.
M.RETIRE_WAIT_MS = tonumber(os.getenv("LW_TEST_RELAY_RETIRE_MS") or "") or 60000
--- The cadence at which a waiting relay re-reads the runtime lock and the
--- handle (`--no-launch`, an attached run's lock; §19.10 "No launch").
M.POLL_MS = tonumber(os.getenv("LW_TEST_RELAY_POLL_MS") or "") or 2000
--- How long the relay waits, at exit, for queued bytes to be written.
M.FLUSH_MS = 5000
--- The environment variable that admits `--private` (§19.10 "Tests").
M.PRIVATE_ENV = "LOOMWORKS_TEST_PRIVATE_STDIO"

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

--- The parsed `lw daemon run` options of the standard-I/O forms.
--- @class loomworks.daemon.RelayArgs
--- @field stdio boolean
--- @field private boolean
--- @field no_launch boolean
--- @field skip? loomworks.daemon.Instance the `--skip-instance` daemon
--- @field root? string the `--root` value, as given (separators normalized)

--- Parse and validate the options of `lw daemon run` that concern the
--- standard-I/O forms (`args[1]` = "daemon", `args[2]` = "run"). Returns the
--- options, or nil + the usage text (status 2) — the rules of §19.10 "Relay
--- exit status".
--- @param args string[]
--- @param getenv? fun(name: string): string|nil
--- @return loomworks.daemon.RelayArgs|nil, string|nil
function M.parse(args, getenv)
    getenv = getenv or os.getenv
    local o = { stdio = false, private = false, no_launch = false }
    local skips = {}
    local i = 3
    while i <= #args do
        local a = args[i]
        if a == "--" then break end
        if a == "--stdio" then o.stdio = true
        elseif a == "--private" then o.private = true
        elseif a == "--no-launch" then o.no_launch = true
        elseif a == "--root" then o.root = args[i + 1]; i = i + 1
        elseif a == "--skip-instance" then skips[#skips + 1] = args[i + 1] or ""; i = i + 1
        elseif type(a) == "string" and a:sub(1, 7) == "--root=" then o.root = a:sub(8)
        elseif type(a) == "string" and a:sub(1, 16) == "--skip-instance=" then skips[#skips + 1] = a:sub(17)
        end
        i = i + 1
    end
    if o.root then o.root = o.root:gsub("\\", "/"):gsub("/+$", "") end
    if o.private and getenv(M.PRIVATE_ENV) ~= "1" then return nil, "--private is for tests only" end
    if o.private and not o.stdio then return nil, "--private needs --stdio" end
    if o.no_launch and not o.stdio then return nil, "--no-launch needs --stdio" end
    if o.no_launch and o.private then return nil, "--no-launch cannot be combined with --private" end
    if #skips > 0 then
        if not o.no_launch then return nil, "--skip-instance needs --no-launch" end
        if #skips > 1 then return nil, "--skip-instance names at most one daemon instance" end
        o.skip = connect.parse_instance(skips[1])
        if not o.skip then return nil, "--skip-instance takes <pid>:<start_time>" end
    end
    if o.stdio and (not o.root or o.root == "") then return nil, "--stdio needs --root <dir>" end
    return o
end

-- ---------------------------------------------------------------------------
-- Flow control
-- ---------------------------------------------------------------------------

--- One direction of the relay: writes chunks to `dst` and pauses the source
--- (`pause()`) while `dst`'s write queue holds more than `high` bytes,
--- resuming it (`resume()`) once the queue drained below half.
--- @class loomworks.daemon.RelayFlow
--- @field paused boolean
--- @field push fun(chunk: string)

--- @param dst table a libuv stream (write, get_write_queue_size)
--- @param high integer
--- @param pause fun()
--- @param resume fun()
--- @param on_error? fun(err: string) a failed write (the other side went away)
--- @return loomworks.daemon.RelayFlow
function M.flow(dst, high, pause, resume, on_error)
    local f = { paused = false }
    local function drained()
        if f.paused and dst:get_write_queue_size() < high / 2 then
            f.paused = false
            resume()
        end
    end
    function f.push(chunk)
        local ok = pcall(function()
            dst:write(chunk, function(err)
                if err and on_error then on_error(tostring(err)) end
                drained()
            end)
        end)
        if not ok then
            if on_error then on_error("write failed") end
            return
        end
        if not f.paused and dst:get_write_queue_size() > high then
            f.paused = true
            pause()
        end
    end
    return f
end

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

-- Is a lock record held (live or hung)?
local function held(lk)
    return type(lk) == "table" and (lk.state == "live" or lk.state == "hung")
end

-- The same daemon, by instance id; with an unknown start time on either
-- side, by pid (only for following a retiring daemon the relay itself saw —
-- `--skip-instance` always needs both, connect.same_instance).
local function same_daemon(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if connect.same_instance(a, b) then return true end
    return a.pid ~= nil and a.pid == b.pid and (a.start_time == nil or b.start_time == nil)
end

--- Does the daemon instance `inst` hold the runtime lock of state `st`, or
--- is it the live handle's daemon? (`exact`: by instance id only.)
--- @param st table inspect.state
--- @param inst table
--- @param exact? boolean
--- @return boolean
function M.present(st, inst, exact)
    local same = exact and connect.same_instance or same_daemon
    if held(st.lock) and same(st.lock, inst) then return true end
    return st.kind == "live" and st.handle ~= nil and same(st.handle, inst)
end

-- ---------------------------------------------------------------------------
-- The relay
-- ---------------------------------------------------------------------------

--- @class loomworks.daemon.Relay
--- @field root string
--- @field opts table
--- @field inp table standard input (a libuv stream)
--- @field out table standard output (a libuv stream)
--- @field hello? table the client's `hello`
--- @field bad_hello? boolean the first frame was not a `hello`
--- @field eof boolean the client closed standard input
--- @field pending string[] client bytes read after `hello`, before `welcome`
--- @field pending_n integer their size
--- @field dbuf string[] daemon bytes that arrived before the relay forwarded `welcome`
--- @field conn? loomworks.daemon.Conn
--- @field st? table the state the relay connected through
--- @field daemon_closed boolean
local Relay = {}
Relay.__index = Relay

--- A relay over the streams `inp` / `out`.
--- opts:
---   no_launch, skip     as parsed (M.parse)
---   note                fun(line): one standard-error line
---   step_ms             each connect step's bound (ensure.step_ms(true))
---   launch              (tests) the launcher, as for connect.connect_or_start
---   inspect             (tests) the state reader (loomworks.daemon.inspect.state)
--- @param root string
--- @param inp table
--- @param out table
--- @param opts table
--- @return loomworks.daemon.Relay
function M.new(root, inp, out, opts)
    return setmetatable({ root = root, opts = opts, inp = inp, out = out, eof = false, pending = {},
        pending_n = 0, dbuf = {}, daemon_closed = false, decoder = protocol.new_decoder(protocol.PREAUTH_MAX) }, Relay)
end

function Relay:_state()
    return (self.opts.inspect or require("loomworks.daemon.inspect").state)(self.root)
end

function Relay:_note(line) if self.opts.note then self.opts.note("lw: " .. line) end end

--- Fail before `welcome`: one line to standard error, the status.
function Relay:_fail(code, line)
    self:_note(line)
    return code
end

-- Standard input. Before `hello`: decode the first frame. After it: keep
-- the bytes (forwarded after `welcome`), stopping to read past HIGH_WATER.
-- Once relaying: `self.up` takes them.
function Relay:_on_stdin(err, chunk)
    if err or not chunk then
        self.eof = true
        return
    end
    if self.up then return self.up.push(chunk) end
    if not self.hello then
        if self.bad_hello then return end
        local msgs, derr = self.decoder:push(chunk, function() return true end)
        if not msgs then
            self.bad_hello = true
            self.bad_hello_why = derr
            return
        end
        if #msgs == 0 then return end
        if msgs[1].kind ~= protocol.KIND.hello then
            self.bad_hello = true
            return
        end
        self.hello = msgs[1]
        chunk = self.decoder._buf
        self.decoder._buf = ""
        if chunk == "" then return end
    end
    self.pending[#self.pending + 1] = chunk
    self.pending_n = self.pending_n + #chunk
    if self.pending_n > M.HIGH_WATER and not self.stdin_paused then
        self.stdin_paused = true
        pcall(function() self.inp:read_stop() end)
    end
end

function Relay:_read_stdin()
    self.inp:read_start(function(err, chunk) self:_on_stdin(err, chunk) end)
end

-- Daemon bytes after `welcome` (the connection's raw mode).
function Relay:_on_daemon(chunk)
    if self.down then return self.down.push(chunk) end
    self.dbuf[#self.dbuf + 1] = chunk
end

--- Wait up to `ms` or until the client closes standard input. True when it did.
function Relay:_sleep(ms)
    vim.wait(ms, function() return self.eof end, 20)
    return self.eof
end

-- Close the current daemon connection (a retiring one), forwarding nothing.
function Relay:_drop()
    if self.conn then
        self.conn.on_close = nil
        self.conn:close()
    end
    self.conn, self.dbuf, self.daemon_closed = nil, {}, false
end

--- The client's versions, forwarded in the socket `hello` (§19.8 step 2).
function Relay:_hello_fields()
    local h = self.hello
    return { protocol = h.protocol, protocol_min = h.protocol_min, lw_version = h.lw_version,
        schemas = h.schemas, client = h.client, role = h.role }
end

local function pid_text(st)
    local p = (st.handle and st.handle.pid) or (st.lock and st.lock.pid)
    return tostring(p or "?")
end

--- Connect to the live daemon `st`: the handle's key, the endpoint check,
--- the handshake. Returns nil when connected (`self.conn`), or a status.
function Relay:_open(st)
    local command = require("loomworks.daemon.command")
    if command.other_key(st.handle) then
        return self:_fail(M.EXIT.untrusted, string.format("the workspace daemon (pid %s) %s", pid_text(st),
            command.OTHER_KEY_TEXT))
    end
    local conn, why, detail = connect.open(self.root, st, {
        step_ms = self.opts.step_ms,
        hello = self:_hello_fields(),
        raw = function(chunk) self:_on_daemon(chunk) end,
        on_close = function() self.daemon_closed = true end,
    })
    if conn then
        self.conn, self.st = conn, st
        return nil
    end
    if why == "endpoint" then
        return self:_fail(M.EXIT.untrusted, "the workspace daemon's endpoint is not this workspace's: "
            .. tostring(detail))
    elseif why == "untrusted" then
        return self:_fail(M.EXIT.untrusted, command.unauthenticated_text(st.handle))
    end
    return self:_fail(M.EXIT.not_responding, string.format("the workspace daemon (pid %s) is not responding (%s)",
        pid_text(st), tostring(detail or why)))
end

--- The daemon instance of a state's handle (or lock).
local function instance_of(st)
    local h = st.handle or {}
    local lk = st.lock or {}
    return { pid = h.pid or lk.pid, start_time = h.start_time or lk.start_time }
end

--- Connect or start (an ordinary relay). Returns nil once connected to a
--- daemon that is not retiring, or the exit status.
function Relay:_connect_or_start()
    while true do
        if self.eof then return M.EXIT.ok end
        local r = connect.connect_or_start(self.root, { step_ms = self.opts.step_ms, connect = false,
            launch = self.opts.launch })
        local o, st = r.outcome, r.st
        if o == "starting" then
            return self:_fail(M.EXIT.not_responding, string.format(
                "the workspace daemon (pid %s) is still starting", pid_text(st)))
        elseif o == "hung" then
            return self:_fail(M.EXIT.not_responding, string.format(
                "the workspace daemon (pid %s) is not responding — recover with: lw daemon stop --force", pid_text(st)))
        elseif o == "elsewhere" and st.kind == "foreign" then
            return self:_fail(M.EXIT.foreign, string.format("the workspace daemon runs on another host (%s, pid %s)",
                tostring(st.lock and st.lock.host or "?"), pid_text(st)))
        elseif o == "elsewhere" then
            -- An attached run holds the runtime lock: wait for it to end,
            -- with no bound while the client is there (§19.10).
            if self:_sleep(M.POLL_MS) then return M.EXIT.ok end
        elseif o == "launch_failed" then
            -- An attached run that took the lock meanwhile is waited on too.
            if self:_state().kind ~= "attached" then
                return self:_fail(M.EXIT.launch_failed, "could not start the workspace daemon ("
                    .. tostring(r.detail) .. ")")
            end
        elseif st.kind ~= "live" then
            -- Not expected (a launch reports a live daemon): read again.
            if self:_sleep(M.POLL_MS) then return M.EXIT.ok end
        else
            local code = self:_open(st)
            if code then return code end
            if not self.conn.welcome.retiring then return nil end
            -- A retiring daemon (§19.8 step 5): wait for it to go, then
            -- launch its successor (or connect to one another client started).
            local inst = instance_of(st)
            self:_drop()
            local gone = vim.wait(M.RETIRE_WAIT_MS, function()
                return self.eof or not M.present(self:_state(), inst)
            end, 100)
            if self.eof then return M.EXIT.ok end
            if not gone then
                return self:_fail(M.EXIT.retire_timeout, string.format(
                    "the retiring workspace daemon (pid %s) still holds the workspace after %d s",
                    tostring(inst.pid), math.floor(M.RETIRE_WAIT_MS / 1000)))
            end
        end
    end
end

--- Wait for a live daemon (`--no-launch`, §19.10 "No launch", "Skip an
--- instance"). Returns nil once connected, or the exit status.
function Relay:_wait_for_daemon()
    local skip = self.opts.skip
    local retiring -- the retiring daemon this relay connected to
    while true do
        if self.eof then return M.EXIT.ok end
        local st = self:_state()
        local skipped = skip ~= nil and M.present(st, skip, true)
        if st.kind == "foreign" then
            return self:_fail(M.EXIT.foreign, string.format("the workspace daemon runs on another host (%s, pid %s)",
                tostring(st.lock and st.lock.host or "?"), pid_text(st)))
        elseif st.kind == "hung" and not skipped then
            return self:_fail(M.EXIT.not_responding, string.format(
                "the workspace daemon (pid %s) is not responding — recover with: lw daemon stop --force", pid_text(st)))
        elseif st.kind == "live" and not skipped and not (retiring and M.present(st, retiring)) then
            local code = self:_open(st)
            if code then return code end
            if not self.conn.welcome.retiring then return nil end
            retiring = instance_of(st)
            self:_drop()
        elseif retiring and not M.present(st, retiring) and st.kind ~= "live" and st.kind ~= "starting" then
            return self:_fail(M.EXIT.retired, string.format(
                "the retiring workspace daemon (pid %s) has exited and no other daemon is live", tostring(retiring.pid)))
        end
        if self:_sleep(M.POLL_MS) then return M.EXIT.ok end
    end
end

--- The `welcome` the client gets: the daemon's, with `daemon` and `via`
--- added (§19.8 step 4) — spliced into its raw payload, so every field the
--- daemon sent reaches the client byte for byte.
--- @param payload string the daemon's `welcome` payload
--- @param challenge table the verified challenge
--- @param h table|nil the handle connected through
--- @return string frame
function M.welcome_frame(payload, challenge, h)
    h = h or {}
    local daemon = { protocol = challenge.protocol, protocol_min = challenge.protocol_min,
        lw_version = challenge.lw_version, schemas = challenge.schemas,
        session_generation = challenge.session_generation, pid = h.pid,
        start_time = type(h.start_time) == "string" and h.start_time or nil,
        exe = type(h.exe) == "string" and h.exe or nil }
    local extra = '"daemon":' .. vim.json.encode(daemon) .. ',"via":"relay"'
    local body = payload:gsub("%s+$", "")
    local head = body:sub(1, -2):gsub("%s+$", "")
    local joined
    if head:sub(-1) == "{" then joined = head .. extra .. "}" else joined = head .. "," .. extra .. "}" end
    return tostring(#joined) .. "\n" .. joined
end

--- Relay frames both ways until either side closes. Returns 0.
function Relay:_relay()
    local conn = self.conn
    local function client_gone() self.eof = true end
    self.down = M.flow(self.out, M.HIGH_WATER,
        function() conn:pause_reading() end, function() conn:resume_reading() end, client_gone)
    self.up = M.flow(conn.pipe, M.HIGH_WATER,
        function() pcall(function() self.inp:read_stop() end) end,
        function() self:_read_stdin() end,
        function() self.daemon_closed = true end)
    self.down.push(M.welcome_frame(conn.welcome_payload or vim.json.encode(conn.welcome), conn.challenge, self.st.handle))
    for _, c in ipairs(self.dbuf) do self.down.push(c) end
    self.dbuf = {}
    -- Client bytes read before `welcome` (§19.8: the client may pipeline).
    self.up.paused = self.stdin_paused == true
    local pend = self.pending
    self.pending, self.pending_n = {}, 0
    for _, c in ipairs(pend) do self.up.push(c) end
    if self.up.paused and conn.pipe:get_write_queue_size() < M.HIGH_WATER / 2 then
        self.up.paused = false
        self:_read_stdin()
    end
    while not (self.eof or self.daemon_closed) do
        vim.wait(3600 * 1000, function() return self.eof or self.daemon_closed end, 20)
    end
    if self.eof and not self.daemon_closed then
        -- The client's last frames reach the daemon before the connection closes.
        vim.wait(M.FLUSH_MS, function()
            return self.daemon_closed or conn.pipe:get_write_queue_size() == 0
        end, 10)
    end
    return M.EXIT.ok
end

--- Close everything the relay opened (idempotent); the client's last
--- frames are flushed first (bounded).
function Relay:close()
    if self.closed then return end
    self.closed = true
    if self.conn then
        self.conn.on_close = nil
        self.conn:close()
    end
    pcall(function() self.inp:read_stop() end)
    pcall(function() if not self.inp:is_closing() then self.inp:close() end end)
    vim.wait(M.FLUSH_MS, function()
        local ok, n = pcall(function() return self.out:get_write_queue_size() end)
        return not ok or n == 0
    end, 10)
    pcall(function() if not self.out:is_closing() then self.out:close() end end)
end

--- Run the relay to its end. Returns the exit status.
--- @return integer
function Relay:run()
    self:_read_stdin()
    vim.wait(M.HELLO_MS, function() return self.hello ~= nil or self.bad_hello or self.eof end, 10)
    if not self.hello then
        if self.bad_hello then
            return self:_fail(M.EXIT.no_hello, "the client did not send hello first"
                .. (self.bad_hello_why and (" (" .. self.bad_hello_why .. ")") or ""))
        end
        if self.eof then
            return self:_fail(M.EXIT.no_hello, "the client closed standard input before sending hello")
        end
        return self:_fail(M.EXIT.no_hello, string.format("no hello from the client within %d s",
            math.floor(M.HELLO_MS / 1000)))
    end
    local code
    if self.opts.no_launch then code = self:_wait_for_daemon() else code = self:_connect_or_start() end
    if code then return code end
    return self:_relay()
end

M.Relay = Relay

--- `lw daemon run --root <root> --stdio [--no-launch [--skip-instance <id>]]`
--- on this process's standard input and output. Returns the exit status.
--- @param root string
--- @param o loomworks.daemon.RelayArgs
--- @param host table the CLI host (note, on_exit)
--- @return integer
function M.serve(root, o, host)
    local inp, out = uv.new_pipe(false), uv.new_pipe(false)
    local oki = pcall(inp.open, inp, 0)
    local oko = pcall(out.open, out, 1)
    if not (oki and oko) then
        pcall(function() inp:close() end)
        pcall(function() out:close() end)
        host.note("lw: --stdio needs standard input and output")
        return 1
    end
    local r = M.new(root, inp, out, {
        no_launch = o.no_launch, skip = o.skip, note = host.note,
        step_ms = require("loomworks.daemon.ensure").step_ms(true),
    })
    if host.on_exit then host.on_exit(function() r:close() end) end
    local ok, code = pcall(r.run, r)
    r:close()
    if not ok then
        host.note("lw: the relay failed: " .. tostring(code))
        return 1
    end
    return code
end

return M
