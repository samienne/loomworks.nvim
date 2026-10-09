--- loomworks/daemon/client.lua — connect to a workspace daemon and authenticate
--- (spec §19.8), then send control requests.
---
--- The endpoint comes from the handle (clients never compute it). The client
--- sends `hello`, verifies the daemon's `server_proof` BEFORE sending anything
--- else — a process squatting the endpoint cannot prove knowledge of K, and
--- the client then closes and reports the endpoint as untrusted — answers
--- with its own proof, and waits for `welcome`.
---
--- Transport is a libuv pipe on both hosts, or the in-memory loopback of an
--- attached run (`loopback_connect` / `loopback_session`, §19.1) through the
--- same frame reader. `connect` is asynchronous; the `session` / `call`
--- wrappers pump the event loop with `vim.wait` (the CLI). The editor
--- connects through the `--stdio` relay instead (`M.relay`, below): the same
--- connection class and frame reader over the relay's standard I/O.

local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local auth = require("loomworks.daemon.auth")
local version = require("loomworks.daemon.version")

local M = {}

--- Handshake / request timeout.
M.TIMEOUT_MS = 5000

--- Errors a caller distinguishes.
M.ERR_UNTRUSTED = "untrusted"   -- the server's proof did not verify
M.ERR_CONNECT = "connect"       -- nothing accepted the connection
M.ERR_TIMEOUT = "timeout"       -- no answer in time
M.ERR_CLOSED = "closed"         -- the daemon closed the connection
M.ERR_TRANSPORT = "transport"   -- the negotiated transport has no interface calls (protocol 10)

--- @class loomworks.daemon.Conn
--- @field pipe userdata the libuv pipe, or a loomworks.daemon.LoopbackEnd
--- @field loopback boolean|nil an attached run's in-memory connection (§19.1)
--- @field challenge table the daemon's announced versions (protocol, lw_version, schemas, session_generation)
--- @field welcome table
--- @field transport integer|nil the transport both sides agreed on (§19.9 "From protocol 11"), from the challenge
--- @field closed boolean|nil
--- @field on_close fun(conn: loomworks.daemon.Conn)|nil called once when the connection closes
---   after it was established (either side; runs in a libuv callback)
--- @field welcome_payload string|nil the `welcome` frame's raw JSON payload (raw mode only)
local Conn = {}
Conn.__index = Conn

--- Send a request; `cb(reply|nil, err)` on its reply.
--- @param msg table
--- @param cb fun(reply: table|nil, err: string|nil)
function Conn:request(msg, cb)
    if self.closed then return cb(nil, M.ERR_CLOSED) end
    self._next = (self._next or 0) + 1
    msg.req_id = self._next
    self._pending[msg.req_id] = cb
    pcall(function() self.pipe:write(protocol.encode(msg)) end)
end

--- Call an interface method (spec §19.20): sends a `call` frame stamped with
--- the interface version; `cb(result|nil, err)` with the `ok` reply's
--- `result`, or the structured error object (`{ code, message, data? }`;
--- loomworks.proto.envelope) — a closed connection is `{ code = "closed" }`,
--- and a connection whose negotiated transport is below 11 fails at once with
--- `{ code = "transport" }` (M.ERR_TRANSPORT; client-side, never on the wire).
--- @param object string
--- @param iface string
--- @param v integer
--- @param method string
--- @param args table|nil
--- @param cb fun(result: any, err: loomworks.proto.ErrorObject|nil)
--- @param env? table<string, string> the client's environment
function Conn:call(object, iface, v, method, args, cb, env)
    -- Interface calls are transport 11 (§19.8): a daemon of protocol 10
    -- would only answer "unknown request kind".
    if not (type(self.transport) == "number" and self.transport >= 11) then
        return cb(nil, { code = M.ERR_TRANSPORT,
            message = string.format("the daemon's transport is %s; interface calls need 11",
                tostring(self.transport or "not agreed")) })
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

--- The frame reader of a connection being established or established (both
--- transports): `state` "hello" expects the daemon's challenge (verified by
--- `on_challenge(msg)` → true to go on), "auth" its welcome; after the
--- welcome, replies go to their pending callbacks and broadcasts to
--- `opts.on_message`. `finish(conn|nil, err, detail)` ends the handshake.
--- With `opts.raw` (the `--stdio` relay, loomworks.daemon.relay) nothing is
--- decoded after the welcome: the bytes that followed it, and every later
--- chunk, go to `opts.raw(chunk)` unchanged, and the welcome's raw payload is
--- kept in `conn.welcome_payload`.
--- @param conn loomworks.daemon.Conn
--- @param opts table
--- @param state "hello"|"auth"
--- @param finish fun(c: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
--- @param is_done fun(): boolean has the handshake ended?
--- @param on_challenge? fun(msg: table): boolean
--- @return fun(rerr: string|nil, chunk: string|nil)
local function frame_reader(conn, opts, state, finish, is_done, on_challenge)
    local decoder = protocol.new_decoder(protocol.MAX_FRAME)
    local stop = opts.raw and function(m) return m.kind == protocol.KIND.welcome end or nil
    return function(rerr, chunk)
        if rerr or not chunk then
            if not is_done() then return finish(nil, M.ERR_CLOSED) end
            return conn:close()
        end
        if state == "raw" then return opts.raw(chunk) end
        local msgs, derr = decoder:push(chunk, stop)
        if not msgs then
            if not is_done() then return finish(nil, M.ERR_CLOSED, derr) end
            return conn:close()
        end
        for _, msg in ipairs(msgs) do
            if state == "hello" then
                if msg.kind ~= protocol.KIND.challenge or not on_challenge or not on_challenge(msg) then
                    -- Close without sending anything else (§19.8).
                    return finish(nil, M.ERR_UNTRUSTED)
                end
                state = "auth"
            elseif state == "auth" then
                if msg.kind ~= protocol.KIND.welcome then return finish(nil, M.ERR_CLOSED) end
                conn.welcome = msg
                conn.on_close = opts.on_close
                state = "ready"
                if opts.raw then
                    state = "raw"
                    conn.welcome_payload = decoder.stop_payload
                    local rest = decoder._buf
                    decoder._buf = ""
                    if rest ~= "" then opts.raw(rest) end
                end
                finish(conn)
            else
                local p = msg.req_id and conn._pending[msg.req_id]
                if p then
                    conn._pending[msg.req_id] = nil
                    if msg.kind == protocol.KIND.error then
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

--- The handshake bookkeeping both transports share: a timeout, and a
--- `finish` that calls `cb` once (closing the conn on failure).
--- @param conn loomworks.daemon.Conn
--- @param opts table
--- @param cb fun(conn: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
--- @return fun(c: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil) finish
--- @return fun(): boolean is_done
local function handshake_guard(conn, opts, cb)
    local done = false
    local timer = uv.new_timer()
    local function finish(c, err, detail)
        if done then return end
        done = true
        pcall(function() timer:stop(); timer:close() end)
        if not c then conn:close() end
        cb(c, err, detail)
    end
    timer:start(opts.timeout_ms or M.TIMEOUT_MS, 0, function() finish(nil, M.ERR_TIMEOUT) end)
    return finish, function() return done end
end

--- The transport agreed with a daemon's challenge (§19.9 "From protocol
--- 11"), within the range this client announced (`opts.protocol`, a test's
--- older client; default ours).
--- @param ch table the challenge
--- @param opts table
--- @return integer|nil
function M._agreed(ch, opts)
    local t = version.negotiate(ch.protocol, ch.protocol_min)
    local max = opts and opts.protocol
    if t and type(max) == "number" and t > max then
        local lo = math.max(type(ch.protocol_min) == "number" and ch.protocol_min or ch.protocol,
            opts.protocol_min or max)
        t = (max >= lo) and max or nil
    end
    return t
end

--- Connect to `endpoint` and authenticate. `cb(conn|nil, err, detail)`.
--- opts: { client = "cli"|"editor", role = "observer"|nil (§19.16), timeout_ms,
---         key (tests: K override), on_message = fun(msg) for broadcasts,
---         on_close = fun(conn) once an established connection closes,
---         protocol / protocol_min = the range to announce (tests: an older
---         client; default ours),
---         hello = the fields to announce in `hello` instead of this lw's
---         (`protocol`, `protocol_min`, `lw_version`, `schemas`, `client`,
---         `role`: the `--stdio` relay forwards its client's, §19.8 "Relay
---         handshake"; the nonce is always this connection's own),
---         raw = fun(chunk) — after `welcome`, hand the connection's bytes
---         over undecoded (see frame_reader) }
--- @param endpoint string
--- @param opts table|nil
--- @param cb fun(conn: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
function M.connect(endpoint, opts, cb)
    opts = opts or {}
    local key, kerr = opts.key, nil
    if not key then key, kerr = auth.key() end
    if not key then return cb(nil, M.ERR_CONNECT, kerr) end
    local nc = auth.nonce()
    if not nc then return cb(nil, M.ERR_CONNECT, "no random source") end
    -- Built before going asynchronous: the editor host forbids vim.fn (the
    -- version fingerprint's sha256) inside libuv callbacks.
    local fh = opts.hello
    local hello = protocol.encode(fh and { kind = protocol.KIND.hello, protocol = fh.protocol,
        protocol_min = fh.protocol_min, lw_version = fh.lw_version, schemas = fh.schemas, client = fh.client,
        role = fh.role, nonce = nc } or { kind = protocol.KIND.hello, protocol = opts.protocol or protocol.VERSION,
        protocol_min = opts.protocol_min or protocol.VERSION_MIN, lw_version = version.identity(),
        schemas = version.schemas(), client = opts.client or "cli", role = opts.role, nonce = nc })
    local pipe = uv.new_pipe(false)
    local conn = setmetatable({ pipe = pipe, _pending = {}, endpoint = endpoint }, Conn)
    local finish, is_done = handshake_guard(conn, opts, cb)
    -- The daemon's proof is verified BEFORE anything else is sent (§19.8).
    local function on_challenge(msg)
        if not auth.valid_nonce(msg.server_nonce)
            or not auth.equal(msg.server_proof, auth.server_proof(key, endpoint, nc, msg.server_nonce)) then
            return false
        end
        conn.challenge = msg
        conn.transport = M._agreed(msg, opts)
        pcall(function()
            pipe:write(protocol.encode({ kind = protocol.KIND.auth,
                client_proof = auth.client_proof(key, endpoint, nc, msg.server_nonce) }))
        end)
        return true
    end
    local ok_c = pcall(function()
        pipe:connect(endpoint, function(cerr)
            if cerr then return finish(nil, M.ERR_CONNECT, tostring(cerr)) end
            conn._reader = frame_reader(conn, opts, "hello", finish, is_done, on_challenge)
            pipe:read_start(conn._reader)
            pcall(function() pipe:write(hello) end)
        end)
    end)
    if not ok_c then finish(nil, M.ERR_CONNECT, "bad endpoint") end
end

--- Connect to an attached runtime in this process over the loopback
--- transport (spec §19.1 "Loopback"): no endpoint and no authentication.
--- The server adopts its end as an authenticated connection and welcomes it
--- over the loopback; `challenge` is synthesized from the server's versions.
--- The conn has the pipe session's shape. `cb(conn|nil, err, detail)`.
--- opts: as for `connect` (client, role, timeout_ms, on_message, on_close).
--- @param server loomworks.daemon.Server a server started with `start_attached`
--- @param opts table|nil
--- @param cb fun(conn: loomworks.daemon.Conn|nil, err: string|nil, detail: string|nil)
function M.loopback_connect(server, opts, cb)
    opts = opts or {}
    local mine, theirs = require("loomworks.daemon.loopback").pair()
    local conn = setmetatable({ pipe = mine, _pending = {}, loopback = true }, Conn)
    conn.challenge = { kind = protocol.KIND.challenge, protocol = protocol.VERSION,
        protocol_min = protocol.VERSION_MIN, lw_version = server.identity, schemas = server.schemas, session_generation = server.generation }
    conn.transport = M._agreed(conn.challenge, opts)
    local finish, is_done = handshake_guard(conn, opts, cb)
    conn._reader = frame_reader(conn, opts, "auth", finish, is_done)
    mine:read_start(conn._reader)
    local ok, err = server:adopt(theirs, { protocol = opts.protocol or protocol.VERSION,
        protocol_min = opts.protocol_min or protocol.VERSION_MIN,
        lw_version = version.identity(),
        schemas = version.schemas(), client = opts.client or "cli", role = opts.role })
    if not ok then
        pcall(function() theirs:close() end)
        finish(nil, M.ERR_CONNECT, err)
    end
end

--- `loopback_connect` synchronously (pumping the event loop): the conn, or
--- nil + error + detail. A drop-in for `session`.
--- @param server loomworks.daemon.Server
--- @param opts? table
--- @return loomworks.daemon.Conn|nil, string|nil, string|nil
function M.loopback_session(server, opts)
    local res
    M.loopback_connect(server, opts, function(c, e, d) res = { c, e, d } end)
    vim.wait((opts and opts.timeout_ms or M.TIMEOUT_MS) + 200, function() return res ~= nil end, 5)
    if not res then return nil, M.ERR_TIMEOUT end
    return res[1], res[2], res[3]
end

--- A `session(endpoint, opts)` function bound to an attached server: the
--- shape of the `opts.session` hook the CLI's routed operations take (the
--- endpoint is ignored).
--- @param server loomworks.daemon.Server
--- @return fun(endpoint: string|nil, opts: table|nil): loomworks.daemon.Conn|nil, string|nil, string|nil
function M.loopback_sessioner(server)
    return function(_, opts) return M.loopback_session(server, opts) end
end

--- Connect synchronously (pumping the event loop). Returns the conn, or nil
--- + error + detail.
--- @param endpoint string
--- @param opts? table as for `connect`
--- @return loomworks.daemon.Conn|nil, string|nil, string|nil
function M.session(endpoint, opts)
    local res
    M.connect(endpoint, opts, function(c, e, d) res = { c, e, d } end)
    -- The connect callback reports a timeout itself; the extra margin only
    -- covers its own scheduling.
    vim.wait((opts and opts.timeout_ms or M.TIMEOUT_MS) + 200, function() return res ~= nil end, 5)
    if not res then return nil, M.ERR_TIMEOUT end
    return res[1], res[2], res[3]
end

--- Send one request on an open conn synchronously. Returns the reply, or nil
--- + error.
--- @param conn loomworks.daemon.Conn
--- @param msg table
--- @param timeout_ms? integer
--- @return table|nil reply, string|nil err
function M.request(conn, msg, timeout_ms)
    local res
    conn:request(msg, function(r, e) res = { r, e } end)
    vim.wait(timeout_ms or M.TIMEOUT_MS, function() return res ~= nil end, 5)
    if not res then return nil, M.ERR_TIMEOUT end
    return res[1], res[2]
end

--- `Conn:call` synchronously (pumping the event loop): the result, or nil +
--- the error object.
--- @param conn loomworks.daemon.Conn
--- @param object string
--- @param iface string
--- @param v integer
--- @param method string
--- @param args? table
--- @param opts? { env?: table<string, string>, timeout_ms?: integer }
--- @return any result, loomworks.proto.ErrorObject|nil err
function M.call_sync(conn, object, iface, v, method, args, opts)
    opts = opts or {}
    local res
    conn:call(object, iface, v, method, args, function(r, e) res = { r, e } end, opts.env)
    vim.wait(opts.timeout_ms or M.TIMEOUT_MS, function() return res ~= nil end, 5)
    if not res then return nil, { code = M.ERR_TIMEOUT, message = "no answer in time" } end
    return res[1], res[2]
end

--- Connect, send one request, close. Returns (reply|nil, err, conn_info) —
--- conn_info is the daemon's challenge (its versions) when the handshake
--- got that far.
--- @param endpoint string
--- @param kind string
--- @param opts? table
--- @return table|nil, string|nil, table|nil
function M.call(endpoint, kind, opts)
    local conn, err, detail = M.session(endpoint, opts)
    if not conn then return nil, err .. (detail and (": " .. detail) or "") end
    local reply, rerr = M.request(conn, { kind = kind }, opts and opts.timeout_ms)
    local info = conn.challenge
    conn:close()
    return reply, rerr, info
end

-- ---------------------------------------------------------------------------
-- The editor's relay client (M.relay)
-- ---------------------------------------------------------------------------

--- `M.relay` — the editor's side of the `--stdio` relay (spec §19.16
--- "Through the relay", §19.10 "Connections").
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
---     the environment a daemon launch would get (launch.env);
---   * no handshake timeout here: every step of a relay is bounded inside
---     the relay, and the waiting forms wait without a bound by design;
---   * ended by closing its standard input (it exits 0); only when it has not
---     exited KILL_MS later is its own pid killed — a plain kill, NEVER a
---     process-tree kill (on Windows the daemon a relay launched is its child
---     by parent pid, loomworks.daemon.discover: a tree kill would take the
---     shared daemon down). An older pin's attached `--stdio` runtime (a
---     `welcome` without `via`) is ended the same way;
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
---     and a status-14 relay's last line `retiring <pid>:<start_time>`
---     (§19.10 "Retiring-instance line") names the instance for `--retiring`.
---
--- Libuv callbacks here never call vim.fn; the caller's callbacks are
--- invoked from libuv callbacks and must only schedule.

local RC = {}

local function relay_env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- How long after closing a relay's standard input the editor waits before
--- it kills the relay's own process id (spec §19.16: about 5 s).
RC.KILL_MS = relay_env_ms("LW_TEST_RELAY_KILL_MS") or 5000
--- How long, once the relay exited, its remaining pipe EOFs are waited for
--- before the outcome is reported anyway (the daemon never holds them).
RC.EOF_GRACE_MS = 1000
--- How long, once a relay's standard output reached EOF before `welcome`, its
--- exit is waited for (spec §19.16 "The relay process": about 5 s). A relay
--- still running then is an internal error (no status: the "protocol" case
--- of the exit-before-`welcome` table) and is ended (Relay:close).
RC.EXIT_WAIT_MS = relay_env_ms("LW_TEST_RELAY_EXIT_WAIT_MS") or 5000
--- How many standard-error lines are kept.
RC.STDERR_LINES = 50

--- The relay forms (§19.16 "Through the relay").
RC.FORMS = { ordinary = true, ["no-launch"] = true, retiring = true, skip = true }

--- The `daemon run` arguments of a relay form (after the executable prefix).
--- @param root string
--- @param form "ordinary"|"no-launch"|"retiring"|"skip"
--- @param instance? string `<pid>:<start_time>` (retiring, skip)
--- @return string[]
function RC.args(root, form, instance)
    local a = { "daemon", "run", "--root", root, "--stdio" }
    if form == "no-launch" or form == "retiring" or form == "skip" then a[#a + 1] = "--no-launch" end
    if form == "retiring" then
        a[#a + 1] = "--retiring"; a[#a + 1] = instance
    elseif form == "skip" then
        a[#a + 1] = "--skip-instance"; a[#a + 1] = instance
    end
    return a
end

--- The retiring instance a status-14 relay named: its LAST standard-error
--- line when that is exactly `retiring <pid>:<start_time>` (§19.10
--- "Retiring-instance line"; both parts in the form `--retiring` takes), or
--- nil (a relay of an older pin, a daemon without a start time).
--- @param lines string[]
--- @return string|nil instance id
function RC.retiring_instance(lines)
    local last
    for i = #lines, 1, -1 do
        if lines[i] ~= "" then last = lines[i]; break end
    end
    local id = last and last:match("^retiring (%S+)$")
    if not id then return nil end
    local connect = require("loomworks.daemon.connect")
    local inst = connect.parse_instance(id)
    return inst and connect.instance_id(inst) or nil
end

--- The detail line of a relay's standard error: its last `lw: …` line, else
--- its last non-empty line that is not the retiring-instance line.
--- @param lines string[]
--- @return string|nil
function RC.detail_line(lines)
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
--- @field eof boolean|nil its standard output reached EOF (it exited: the daemon holds none of its pipes)
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
--- @field line string|nil the detail line (RC.detail_line)
--- @field retiring string|nil the instance a status-14 relay named (RC.retiring_instance)
--- @field form string the relay's form

local function close_handle(h)
    if h then pcall(function() if not h:is_closing() then h:close() end end) end
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
    t:start(self.kill_ms or RC.KILL_MS, 0, function()
        close_handle(t)
        if self.code == nil and self.proc and not self.proc:is_closing() then
            -- A plain kill of the relay's own pid: on Windows TerminateProcess
            -- of that one process; its children (the shared daemon) live on.
            pcall(function() self.proc:kill("sigkill") end)
        end
    end)
    pcall(function() t:unref() end)
end

--- The duplex stream a Conn writes and reads (frame_reader): writes go to
--- the relay's standard input, reads come from its standard output; closing
--- it ends the relay.
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
---   form        "ordinary"|"no-launch"|"retiring"|"skip"
---   instance    the `<pid>:<start_time>` of a retiring / skip relay
---   client, role  the `hello`'s
---   on_message  fun(msg) broadcasts after `welcome` (from a libuv callback)
---   on_close    fun(conn) once the established connection closes (either side)
---   kill_ms     replaces KILL_MS
---   exit_wait_ms replaces EXIT_WAIT_MS
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
function RC.connect(opts, cb)
    local launch = require("loomworks.daemon.launch")
    local paths = require("loomworks.daemon.paths")
    local exit_status = require("loomworks.build_run").exit_status
    local argv = vim.list_extend({}, opts.argv or {})
    local exe = table.remove(argv, 1)
    if not exe then return nil, "no host binary" end
    for _, a in ipairs(RC.args(opts.root, opts.form, opts.instance)) do argv[#argv + 1] = a end
    local cwd = paths.state_dir()
    pcall(vim.fn.mkdir, cwd, "p")
    if not uv.fs_stat(cwd) then return nil, "cannot create " .. cwd end
    -- Built here, on the main loop (the version fingerprint uses vim.fn).
    local nonce = auth.nonce() or string.rep("0", 64)
    local hello = protocol.encode({ kind = protocol.KIND.hello, protocol = protocol.VERSION,
        protocol_min = protocol.VERSION_MIN, lw_version = version.identity(), schemas = version.schemas(),
        client = opts.client or "editor", role = opts.role, nonce = nonce })
    local env = launch.env(opts.root, opts.env)

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
        return { code = r.code, line = RC.detail_line(r.lines), retiring = RC.retiring_instance(r.lines), form = r.form }
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
                local ms = opts.exit_wait_ms or RC.EXIT_WAIT_MS
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
            grace:start(RC.EOF_GRACE_MS, 0, function()
                close_handle(grace)
                if not reported and not r.welcomed then report(nil, "exit", exit_info()) end
            end)
        end
    end

    -- The handshake: frame_reader in state "auth" (no challenge on a relay).
    local function finish(c, err, detail)
        if c then
            r.welcomed = true
            local w = c.welcome or {}
            if w.via == "relay" and type(w.daemon) == "table" then
                c.challenge = w.daemon
                c.transport = M._agreed(w.daemon, opts)
            else
                -- An older pin's attached runtime (§19.10 "Compatibility"): no
                -- `daemon` to judge; interface calls only when it lists objects.
                c.challenge = {}
                c.transport = type(w.objects) == "table" and 11 or 10
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
    local reader = frame_reader(conn, opts, "auth", finish, function() return r.welcomed == true end)
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
                if #r.lines > RC.STDERR_LINES then table.remove(r.lines, 1) end
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

M.relay = RC

return M
