--- loomworks/daemon/observer.lua — the editor as an OBSERVER of the workspace
--- daemon (spec §19.16, §19.19 step 4).
---
--- In `daemon` runtime mode every workspace the editor loads gets one
--- Observer (owned by the Workspace, `ws._daemon_observer`, stopped by
--- `Workspace:teardown`). It never runs an operation: the editor's own
--- operations stay on the in-process path. It
---
---   * resolves a host binary (loomworks.provision.select) and launches
---     `<binary> daemon run --root <root>` only when no daemon is live on
---     workspace load or on an explicit `:LoomworksDaemon connect`, and once
---     after the observed daemon retired (a version change) and exited with
---     no successor — never after any other drop (`lw daemon stop` must stop
---     it);
---   * watches the handle (WATCH_MS) and connects to a live daemon whose
---     transport range overlaps ours and whose schemas are not newer (the host
---     version may differ), as `client = "editor"`, `role = "observer"`, and
---     pings it every KEEPALIVE_MS (§19.11);
---   * skips a daemon that is `retiring` (broadcast or in `welcome`) or
---     incompatible, identified by pid + start time;
---   * on a transport-11 daemon (`welcome.objects`, §19.20) re-describes it
---     (`Root.describe`, bounded by DESCRIBE_MS, falling back to
---     `welcome.objects`) and subscribes to `loomworks.Tasks/1` on `/tasks`
---     and `loomworks.Workspace/1` on `/workspace` when offered (§19.16
---     "Interface client", step 5g.3) — one whose describe reports `delivery =
---     "subscription"` sends a transport-11
---     connection only what it subscribed to; a missing interface is one
---     per-feature note, never a failed connection; the root's
---     `objects_changed` subscribes to an interface that appears later and
---     retries a refused subscription once; against a daemon without
---     `welcome.objects` it observes through the protocol-10 broadcasts
---     (`mode` "v0");
---   * on `model_change` (or `Workspace.changed`) applies the workspace files'
---     pending changes at once (the file tracker's `sync`, §19.12);
---   * turns observed `task` streams into RemoteTasks resolved to the
---     workspace's domain objects (loomworks.daemon.remote_task), which put
---     the same runtime running state on units and profile as a local
---     operation and which the status page, fidget and the statusline show
---     like local tasks (never in overseer's task list);
---   * on each connect asks `status` and adopts the tasks already running
---     ("Joining late", protocol 7 `tasks`).
---
--- Every problem is the observer's one current NOTE (the status page's
--- Runtime line) — never a notification, never repeated.
---
--- Libuv callbacks (connection, timers) only schedule: all work runs on the
--- main loop.

local uv = vim.uv or vim.loop
local remote_task = require("loomworks.daemon.remote_task")

local M = {}

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- Keepalive interval (spec §19.11: about every 30 s).
M.KEEPALIVE_MS = env_ms("LW_TEST_DAEMON_KEEPALIVE_MS") or 30000
--- Handle watch interval (spec §19.16: about every 2 s).
M.WATCH_MS = env_ms("LW_TEST_OBSERVER_WATCH_MS") or 2000
--- Handshake timeout.
M.CONNECT_MS = env_ms("LW_TEST_DAEMON_STEP_MS") or 5000

--- @class loomworks.daemon.Observer
--- @field ws loomworks.Workspace
--- @field root string
--- @field state "idle"|"no-binary"|"launching"|"connecting"|"connected"|"waiting"|"stopped"
--- @field note string|nil the current Runtime note
--- @field conn loomworks.daemon.Conn|nil
--- @field daemon { pid: integer, start_time: string|nil, lw_version: string|nil }|nil the observed daemon
--- @field seq integer last model_change seq
--- @field mode "v0"|"interfaces"|nil how the connected daemon is observed: protocol-10 broadcasts, or subscriptions (step 5g.3)
--- @field feature_note string|nil the per-feature note of a missing or refused interface (§19.16 "Interface client")
--- @field _feat table<string, string>|nil per feature, on this connection: "pending", "subscribed", "refused" (retried once), "gave_up" or "missing" (offered at other versions only)
--- @field _why table<string, string>|nil per feature: why it is not subscribed (its note)
--- @field _sub_only boolean|nil the connected daemon delivers to a transport-11 connection only by subscription (its `describe` reports `delivery = "subscription"`, step 5g.3)
--- @field generation any session generation of the observed daemon
--- @field skip table<string, boolean> daemons never connected to again ("pid:start")
--- @field _tasks table<integer, loomworks.RemoteTask> running remote tasks by daemon task id
--- @field _order integer[] task ids in start order
--- @field _child table|nil the daemon this observer launched (until it is live or exited): `{ pid, code }`
--- @field _binary string|nil the host binary it was launched from
--- @field selection loomworks.provision.Selection|nil the last host-binary selection (spec §19.16 "Host binary"), made when it launches
--- @field _connecting table|nil the one connection attempt in flight (single-flight token)
--- @field _watch userdata|nil the handle-watch timer
--- @field _keepalive userdata|nil the keepalive ping timer
--- @field _dropped boolean|nil the last connection dropped (keeps its note while waiting)
--- @field _dropped_id string|nil the daemon that last dropped us: a reconnect to it is quiet
--- @field _retired_note boolean|nil the connection is being closed because the daemon retires
--- @field _relaunch boolean|nil the observed daemon retired: launch one successor once it has exited
--- @field opts table the attach options (test seams, see `attach`)
--- @field watch_ms integer handle-watch interval
--- @field keepalive_ms integer keepalive ping interval
--- @field warning string|nil an invalid runtime-mode value that was ignored (shown on the Runtime line)
local Observer = {}
Observer.__index = Observer

local function daemon_id(pid, start) return tostring(pid) .. ":" .. tostring(start) end

--- The interface versions the observer uses (spec §19.16 "Interface client",
--- step 5g.3): each names its object, interface and version (the guard's
--- interface ratchet, tests/split, checks a schema and transcripts exist).
M.ROOT = { object = "/", iface = "loomworks.Root", v = 1 }
M.TASKS = { object = "/tasks", iface = "loomworks.Tasks", v = 1, feature = "tasks" }
M.WORKSPACE = { object = "/workspace", iface = "loomworks.Workspace", v = 1, feature = "model changes" }
M.FEATURES = { M.TASKS, M.WORKSPACE }

--- How long the connect's `Root.describe` may take before the observer
--- falls back to `welcome.objects` (§19.16 "Interface client").
M.DESCRIBE_MS = 3000

--- The versions of `want.iface` the daemon offers on `want.object`, from
--- `welcome.objects` (§19.20; describe().objects without digests).
--- @param objects table[]|nil
--- @param want table
--- @return integer[]
function M.offered_versions(objects, want)
    for _, o in ipairs(type(objects) == "table" and objects or {}) do
        if type(o) == "table" and o.path == want.object then
            for _, i in ipairs(type(o.interfaces) == "table" and o.interfaces or {}) do
                if type(i) == "table" and i.name == want.iface and type(i.versions) == "table" then
                    return i.versions
                end
            end
        end
    end
    return {}
end

--- The per-feature note of an interface the editor cannot use (§19.16
--- "Interface client"), e.g. `tasks: daemon offers loomworks.Tasks/2, editor
--- needs /1`, or of a refused subscription (`why`).
--- @param want table
--- @param offered integer[]
--- @param why? string
--- @return string
function M.feature_note(want, offered, why)
    if why then
        return string.format("%s: %s/%d refused (%s)", want.feature, want.iface, want.v, tostring(why))
    end
    local theirs
    if #offered == 0 then
        theirs = "daemon offers no " .. want.iface
    else
        local vs = {}
        for i, v in ipairs(offered) do vs[i] = "/" .. tostring(v) end
        theirs = "daemon offers " .. want.iface .. table.concat(vs, ",")
    end
    return string.format("%s: %s, editor needs /%d", want.feature, theirs, want.v)
end

--- Attach an observer to a freshly loaded workspace when the runtime mode
--- selects the daemon (spec §19.1). Returns the observer, or nil (in-process
--- mode: nothing happens).
--- opts (tests inject):
---   configured  the setup option `runtime.mode`
---   getenv      replaces os.getenv for the selection and LOOMWORKS_LW
---   settings_file / read_setting  lw's settings file (loomworks.daemon.runtime.read_setting)
---   binary      the setup option `binary` (loomworks.provision.BinarySetting)
---   resolve     fun(root, opts) → binary|nil, source, selection (loomworks.provision.binsel.resolve)
---   spawn       fun(root, opts) → child|nil, err (loomworks.daemon.launch.spawn)
---   inspect     fun(root) → state (loomworks.daemon.inspect.state)
---   connect     fun(endpoint, opts, cb) (loomworks.daemon.client.connect)
---   check       fun(root, endpoint) → ok, why (loomworks.daemon.endpoint.check)
---   watch_ms, keepalive_ms
--- @param ws loomworks.Workspace
--- @param opts? table
--- @return loomworks.daemon.Observer|nil
function M.attach(ws, opts)
    opts = opts or {}
    if not ws or ws._torn_down then return nil end
    local runtime = require("loomworks.daemon.runtime")
    -- Selected afresh on every load (lw's setting may have changed); kept on
    -- the workspace for the Runtime line, in-process mode included.
    local sel = runtime.editor_select({ configured = opts.configured, getenv = opts.getenv,
        settings_file = opts.settings_file, read_setting = opts.read_setting })
    ws._runtime_selection = sel
    if not sel.daemon then return nil end
    if ws._daemon_observer then return ws._daemon_observer end
    local self = setmetatable({
        ws = ws, root = ws.root, opts = opts, state = "idle", seq = 0, skip = {},
        _tasks = {}, _order = {},
        watch_ms = opts.watch_ms or M.WATCH_MS,
        keepalive_ms = opts.keepalive_ms or M.KEEPALIVE_MS,
    }, Observer)
    ws._daemon_observer = self
    if sel.warning then self.warning = sel.warning end
    self:start(false)
    return self
end

--- The observer of `ws`, if any.
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
function M.of(ws) return ws and ws._daemon_observer or nil end

function Observer:_emit(event, data)
    local core = self.ws and self.ws._core
    local events = core and core._deps and core._deps.events
    if events then pcall(events.emit, event, data) end
end

--- Set the state and the note; the status page re-renders.
function Observer:_set(state, note)
    if self.state == state and self.note == note then return end
    self.state, self.note = state, note
    self:_emit("daemon_runtime_changed", self)
end

function Observer:_inspect()
    return (self.opts.inspect or require("loomworks.daemon.inspect").state)(self.root)
end

--- Start observing: connect to a live daemon, or launch one (spec §19.16:
--- here — on workspace load, or `explicit` from `:LoomworksDaemon connect` —
--- and once after a retirement (`_on_watch`), never after another drop), then
--- keep watching the handle.
--- @param explicit boolean
function Observer:start(explicit)
    if self.state == "stopped" then return end
    if explicit then self.skip = {} end
    self:_start_watch()
    -- Single-flight: one connection, one attempt, one launch at a time.
    if self.conn or self._connecting then return end
    if self._child and self._child.code == nil then return end
    local st = self:_inspect()
    if st.kind == "live" then return self:_connect(st) end
    if st.kind == "none" or st.kind == "stale" or st.kind == "unreadable" then
        return self:_launch()
    end
    self:_set("waiting", M.state_note(st))
end

--- The note for a daemon state the observer does not launch over.
--- @param st table
--- @return string
function M.state_note(st)
    local pid = st.lock and st.lock.pid or (st.handle and st.handle.pid) or "?"
    if st.kind == "starting" then return "the workspace daemon (pid " .. tostring(pid) .. ") is starting" end
    if st.kind == "hung" then
        return "the workspace daemon (pid " .. tostring(pid) .. ") is not responding — lw daemon stop --force"
    end
    if st.kind == "foreign" then
        return "the workspace daemon runs on " .. tostring(st.lock and st.lock.host or "another host")
    end
    if st.kind == "attached" then return "the workspace runtime is held by an lw command (pid " .. tostring(pid) .. ")" end
    return "no workspace daemon — waiting for one"
end

--- The note for a daemon this plugin cannot observe (spec §19.16 "version
--- mismatch"): both sides' protocol (or file formats) and versions, the
--- binary's path when known (the daemon's handle names it; else the binary
--- this observer launched), and the remedy.
--- @param ch table the daemon's challenge { protocol, lw_version, schemas }
--- @param what "protocol"|"schemas" what differs (version.observer_compatible)
--- @param binary string|nil the host binary the daemon was launched from
--- @return string
function M.mismatch_note(ch, what, binary)
    local version = require("loomworks.daemon.version")
    local theirs, ours
    if what == "protocol" then
        theirs = "protocol " .. tostring(ch.protocol)
        ours = "protocol " .. version.PROTOCOL
    else
        local ps, s = type(ch.schemas) == "table" and ch.schemas or {}, version.schemas()
        theirs = string.format("file formats user %s, cache %s", tostring(ps.user), tostring(ps.cache))
        ours = string.format("file formats user %d, cache %d", s.user, s.cache)
    end
    local lw = "lw v" .. tostring(ch.lw_version) .. (binary and (" at " .. binary) or "")
    return string.format("the workspace daemon runs %s (%s), which does not match this plugin (v%s, %s): "
        .. "update the plugin, or pin or install a matching lw — not observing it; running in-process",
        lw, theirs, version.identity(), ours)
end

function Observer:_launch()
    local binsel = require("loomworks.provision.select")
    local resolve = self.opts.resolve or binsel.resolve
    local bin, source, sel = resolve(self.root, { getenv = self.opts.getenv, setting = self.opts.binary })
    if type(sel) ~= "table" then
        sel = { path = bin, source = source, label = binsel.LABELS[source] or source, candidates = {} }
    end
    self.selection = sel
    if not bin then
        return self:_set("no-binary", binsel.none_note(sel))
    end
    local spawn = self.opts.spawn or require("loomworks.daemon.launch").spawn
    local child, err = spawn(self.root, { argv = { bin }, env = sel.env })
    if not child then
        return self:_set("waiting", "could not start the workspace daemon from " .. bin .. " ("
            .. tostring(err) .. ")")
    end
    self._child = child
    self._binary = bin
    self:_set("launching", "starting the workspace daemon (" .. (sel.label and binsel.describe(sel) or bin) .. ")")
end

function Observer:_start_watch()
    if self._watch then return end
    local t = uv.new_timer()
    self._watch = t
    t:start(self.watch_ms, self.watch_ms, vim.schedule_wrap(function()
        if self.state == "stopped" then return end
        local ok, err = pcall(self._on_watch, self)
        if not ok then self:_set("waiting", "internal error: " .. tostring(err)) end
    end))
end

--- One watch tick: a launched daemon that exited early is a note; a live
--- daemon we are not connected to is connected to (unless skipped).
function Observer:_on_watch()
    if self.conn or self._connecting then return end
    local st = self:_inspect()
    local child = self._child
    -- The launched daemon exited without becoming the live one. EXIT_HELD
    -- means some runtime holds R — another daemon (then it is live or
    -- starting and is picked up below) or an attached lw command (noted).
    if child and child.code ~= nil and st.kind ~= "live" and st.kind ~= "starting" then
        self._child = nil
        if child.code == require("loomworks.daemon.server").EXIT_HELD then
            return self:_set("waiting", M.state_note(st))
        end
        return self:_set("waiting", "could not start the workspace daemon (it exited with status "
            .. tostring(child.code) .. ")")
    end
    if st.kind == "live" then
        local h = st.handle or {}
        if self.skip[daemon_id(h.pid, h.start_time)] then return end
        return self:_connect(st)
    end
    -- The daemon retired for a version change and has exited, and nothing
    -- took its place: launch one successor ourselves — once (§19.16).
    if self._relaunch and (st.kind == "none" or st.kind == "stale" or st.kind == "unreadable") then
        self._relaunch = nil
        return self:_launch()
    end
    if self.state ~= "launching" and self.state ~= "no-binary" then
        local note = M.state_note(st)
        if self.state ~= "waiting" or not self._dropped then self:_set("waiting", note) end
    end
end

--- Connect to the live daemon of `st`.
function Observer:_connect(st)
    local h = st.handle or {}
    -- The daemon that just dropped us, still live on disk: `lw daemon stop`
    -- closes its connections before it removes its handle, so a watch tick
    -- in between sees the stopping daemon. Try it again quietly — keep the
    -- "disconnected" note and state while trying, and on failure; only a
    -- connection that succeeds changes what the editor shows.
    local quiet = self._dropped and self._dropped_id == daemon_id(h.pid, h.start_time) or nil
    local check = self.opts.check or require("loomworks.daemon.endpoint").check
    local eok, why = check(self.root, h.endpoint)
    if not eok then
        self.skip[daemon_id(h.pid, h.start_time)] = true
        if quiet then return end
        return self:_set("waiting", tostring(why))
    end
    local connect = self.opts.connect or require("loomworks.daemon.client").connect
    if not quiet then
        self:_set("connecting", "connecting to the workspace daemon (pid " .. tostring(h.pid) .. ")")
    end
    -- `exe`: the executable the daemon's handle names (§19.6; display only).
    local target = { pid = h.pid, start_time = h.start_time, quiet = quiet,
        exe = type(h.exe) == "string" and h.exe ~= "" and h.exe or nil }
    self._connecting = target
    connect(h.endpoint, {
        client = "editor", role = "observer", timeout_ms = M.CONNECT_MS,
        on_message = function(msg) vim.schedule(function() self:_on_message(msg) end) end,
        on_close = function(c) vim.schedule(function() self:_on_closed(c) end) end,
    }, function(conn, err)
        vim.schedule(function() self:_on_connected(target, conn, err) end)
    end)
end

function Observer:_on_connected(target, conn, err)
    -- Only the attempt in flight counts; anything else (stopped meanwhile,
    -- superseded) closes the connection it got.
    if self.state == "stopped" or self._connecting ~= target or self.conn then
        if conn then conn.on_close = nil; conn:close() end
        return
    end
    self._connecting = nil
    if not conn then
        if err == "untrusted" then self.skip[daemon_id(target.pid, target.start_time)] = true end
        if target.quiet then return end
        return self:_set("waiting", "could not reach the workspace daemon (pid " .. tostring(target.pid)
            .. ", " .. tostring(err) .. ")")
    end
    local ch = conn.challenge or {}
    local version = require("loomworks.daemon.version")
    local ok, what = version.observer_compatible(ch)
    if not ok then
        self.skip[daemon_id(target.pid, target.start_time)] = true
        conn.on_close = nil
        conn:close()
        return self:_set("waiting", M.mismatch_note(ch, what, target.exe or self._binary))
    end
    if conn.welcome and conn.welcome.retiring then
        self.skip[daemon_id(target.pid, target.start_time)] = true
        self._relaunch = true
        conn.on_close = nil
        conn:close()
        return self:_set("waiting", "the workspace daemon (pid " .. tostring(target.pid)
            .. ") is retiring — waiting for its successor")
    end
    self.conn = conn
    self._child = nil
    self._dropped = nil
    self._dropped_id = nil
    self._relaunch = nil
    self.daemon = { pid = target.pid, start_time = target.start_time, lw_version = ch.lw_version }
    self.generation = ch.session_generation
    self.seq = tonumber(conn.welcome and conn.welcome.seq) or 0
    self:_start_keepalive()
    self.feature_note = nil
    self:_subscribe(conn, function()
        self:_connected_note()
        -- What the daemon wrote before we connected (and subscribed): catch
        -- up now.
        self:_reload()
        self:_join_late(conn)
    end)
end

--- Set the Runtime note of a connected observer: the daemon it observes,
--- and the per-feature note (`feature_note`) when an interface it needs is
--- missing or refused.
function Observer:_connected_note()
    local d = self.daemon
    if not d then return end
    local notes = {}
    -- A missing interface is noted only when the editor really gets nothing
    -- for it: from a daemon that offers some of them, or (`_sub_only`) one
    -- that delivers to this connection only by subscription. A daemon of
    -- transport 11 that offers none of them (step 5g.1) still sends the
    -- protocol-10 broadcasts, through which the editor observes it.
    local offers_any = false
    for _, want in ipairs(M.FEATURES) do
        if self._feat and self._feat[want.feature] then offers_any = true end
    end
    if self.mode == "interfaces" and (offers_any or self._sub_only) then
        for _, want in ipairs(M.FEATURES) do
            local st = self._feat[want.feature]
            if st ~= "subscribed" and st ~= "pending" and self._why[want.feature] then
                notes[#notes + 1] = self._why[want.feature]
            end
        end
    end
    self.feature_note = #notes > 0 and table.concat(notes, "; ") or nil
    local note = "observing the workspace daemon (pid " .. tostring(d.pid) .. ")"
    if self.feature_note then note = note .. " — " .. self.feature_note end
    self:_set("connected", note)
end

--- `Root.describe` on `conn` (§19.20), bounded by DESCRIBE_MS: `cb(objects,
--- delivery)` on the main loop with its `objects` and `delivery`, or nil
--- when it failed or timed out (the caller then uses `welcome.objects`).
--- Never blocks.
--- @param conn loomworks.daemon.Conn
--- @param cb fun(objects: table[]|nil, delivery: string|nil)
function Observer:_describe(conn, cb)
    local finished = false
    local timer = uv.new_timer()
    local function finish(objects, delivery)
        if finished then return end
        finished = true
        pcall(function() timer:stop(); timer:close() end)
        vim.schedule(function() cb(objects, delivery) end)
    end
    timer:start(self.opts.describe_ms or M.DESCRIBE_MS, 0, function() finish(nil) end)
    conn:call(M.ROOT.object, M.ROOT.iface, M.ROOT.v, "describe", {}, function(result, err)
        if err or type(result) ~= "table" or type(result.objects) ~= "table" then return finish(nil) end
        finish(result.objects, type(result.delivery) == "string" and result.delivery or nil)
    end)
end

--- Adopt the describe's `delivery` (§19.20): "subscription" marks a daemon
--- that sends a transport-11 connection only what it subscribed to, so an
--- interface it lacks is really missing (the note). Absent — an older daemon,
--- or a describe that failed — it also sends the protocol-10 broadcasts.
--- @param delivery string|nil
function Observer:_set_delivery(delivery)
    self._sub_only = delivery == "subscription" or nil
end

--- Subscribe to what the editor shows (§19.16 "Interface client", step
--- 5g.3), then `done()`. A daemon of transport 11 that lists its objects in
--- `welcome` is re-described (`Root.describe`; `welcome.objects` when that
--- fails or times out) and gets a subscription to `/tasks`
--- (loomworks.Tasks/1) and `/workspace` (loomworks.Workspace/1) when it
--- offers them — it sends such a connection only what it subscribed to; a
--- missing or refused one is a per-feature note, never a failed connection.
--- Any other daemon is observed through the protocol-10 broadcasts (`mode`
--- "v0").
--- @param conn loomworks.daemon.Conn
--- @param done fun()
function Observer:_subscribe(conn, done)
    self._feat, self._why, self._sub_only = {}, {}, nil
    local welcome_objects = conn.welcome and conn.welcome.objects
    if not (type(conn.transport) == "number" and conn.transport >= 11) or type(welcome_objects) ~= "table"
        or type(conn.call) ~= "function" then
        self.mode = "v0"
        return done()
    end
    self.mode = "interfaces"
    self:_describe(conn, function(objects, delivery)
        if self.state == "stopped" or self.conn ~= conn then return end
        if objects then self:_set_delivery(delivery) end
        self:_ensure_subscriptions(conn, objects or welcome_objects, done)
    end)
end

--- Subscribe to each feature `objects` offers at the editor's version and
--- not subscribed on `conn` yet (a refused one once more), then `done()`.
--- @param conn loomworks.daemon.Conn
--- @param objects table[]
--- @param done fun()
function Observer:_ensure_subscriptions(conn, objects, done)
    local pending = 1
    local function settle()
        pending = pending - 1
        if pending > 0 then return end
        if self.state == "stopped" or self.conn ~= conn then return end
        done()
    end
    for _, want in ipairs(M.FEATURES) do
        local f = want.feature
        local st = self._feat[f]
        local offered = M.offered_versions(objects, want)
        if st == "subscribed" or st == "pending" then
            -- nothing to do
            local _ = st
        elseif vim.tbl_contains(offered, want.v) and st ~= "gave_up" then
            self._feat[f] = "pending"
            pending = pending + 1
            conn:call(M.ROOT.object, M.ROOT.iface, M.ROOT.v, "subscribe",
                { object = want.object, iface = want.iface, v = want.v }, function(_, err)
                    vim.schedule(function()
                        if self.conn ~= conn or not self._feat then return settle() end
                        if err then
                            -- Refused: retried once, on the next
                            -- `objects_changed` (a reconnect starts afresh).
                            self._feat[f] = st == "refused" and "gave_up" or "refused"
                            self._why[f] = M.feature_note(want, offered,
                                type(err) == "table" and (err.message or err.code) or err)
                        else
                            self._feat[f] = "subscribed"
                            self._why[f] = nil
                        end
                        settle()
                    end)
                end)
        elseif #offered > 0 then
            -- Offered at other versions only.
            if st ~= "refused" and st ~= "gave_up" then
                self._feat[f] = "missing"
                self._why[f] = M.feature_note(want, offered)
            end
        elseif st ~= "refused" and st ~= "gave_up" then
            self._feat[f] = nil
            self._why[f] = M.feature_note(want, offered)
        end
    end
    settle()
end

--- The root's `objects_changed` (§19.20): an interface the editor needs that
--- appears is subscribed to, a refused subscription retried (once), and the
--- feature note updated. A removed object's subscription is gone (the
--- daemon drops it).
--- @param args table
function Observer:_on_objects_changed(args)
    local conn = self.conn
    if not conn or self.mode ~= "interfaces" or not self._feat then return end
    for _, p in ipairs(type(args.removed) == "table" and args.removed or {}) do
        for _, want in ipairs(M.FEATURES) do
            if want.object == p then self._feat[want.feature] = nil end
        end
    end
    self:_describe(conn, function(objects, delivery)
        if self.state == "stopped" or self.conn ~= conn or not self._feat then return end
        if objects then self:_set_delivery(delivery) end
        objects = objects or {}
        self:_ensure_subscriptions(conn, objects, function() self:_connected_note() end)
    end)
end

--- Joining late (spec §19.16): ask `status` and adopt every task in its
--- `tasks` (§19.11) as a remote task, its output starting now. A task whose
--- `start` already arrived on the stream is kept; one that ended before the
--- reply was computed is not in it (the daemon sends the reply before any
--- later `done`).
--- @param conn loomworks.daemon.Conn
function Observer:_join_late(conn)
    if type(conn.request) ~= "function" then return end
    conn:request({ kind = "status" }, function(reply)
        vim.schedule(function()
            if self.state == "stopped" or self.conn ~= conn or type(reply) ~= "table" then return end
            local list = type(reply.tasks) == "table" and reply.tasks or {}
            local clock = self:_clock()
            for _, entry in ipairs(list) do
                local id = type(entry) == "table" and entry.task_id or nil
                if id ~= nil and not self._tasks[id] then
                    local task = remote_task.adopt(self.ws, entry, clock)
                    if task then self:_add(task) end
                end
            end
        end)
    end)
end

--- Track a running remote task and put its running state on the editor's
--- objects.
--- @param task loomworks.RemoteTask
function Observer:_add(task)
    self._tasks[task.id] = task
    self._order[#self._order + 1] = task.id
    table.sort(self._order, function(a, b)
        local ta, tb = self._tasks[a], self._tasks[b]
        if ta.start_time ~= tb.start_time then return ta.start_time < tb.start_time end
        return a < b
    end)
    task:attach_units()
    self:_emit("daemon_task_started", { task = task })
end

function Observer:_start_keepalive()
    self:_stop_timer("_keepalive")
    local t = uv.new_timer()
    self._keepalive = t
    t:start(self.keepalive_ms, self.keepalive_ms, vim.schedule_wrap(function()
        local c = self.conn
        if c and not c.closed then c:request({ kind = "ping" }, function() end) end
    end))
end

function Observer:_stop_timer(field)
    local t = self[field]
    if not t then return end
    self[field] = nil
    pcall(function() t:stop(); if not t:is_closing() then t:close() end end)
end

--- The connection closed (the daemon stopped, crashed, retired, or dropped
--- this observer). Watch for the next live daemon; relaunch only after a
--- retirement (once, when it has exited), never after a stop (§19.16).
function Observer:_on_closed(c)
    if c ~= self.conn then return end
    local d = self.daemon
    self.conn = nil
    self.daemon = nil
    self.mode = nil
    self.feature_note = nil
    self._feat, self._why, self._sub_only = nil, nil, nil
    self:_stop_timer("_keepalive")
    self:_end_tasks("the workspace daemon disconnected")
    if self.state == "stopped" then return end
    self._dropped = true
    self._dropped_id = d and daemon_id(d.pid, d.start_time) or nil
    if self._retired_note then
        self._retired_note = nil
        self._relaunch = true
        return self:_set("waiting", "the workspace daemon is retiring — waiting for its successor")
    end
    self._relaunch = nil
    self:_set("waiting", "the workspace daemon disconnected — waiting for it")
end

--- Apply the workspace files' pending changes now (spec §19.12).
function Observer:_reload()
    local ws = self.ws
    if not ws or ws._torn_down then return end
    local tr = ws._tracker
    if tr and tr.sync then pcall(tr.sync, tr) end
end

function Observer:_clock() return uv.hrtime() / 1e9 end

--- A broadcast or task event from the daemon.
--- @param msg table
function Observer:_on_message(msg)
    if self.state == "stopped" or type(msg) ~= "table" then return end
    if msg.kind == "signal" then
        -- Interface signals (§19.20): the root's `retiring` and
        -- `Workspace.changed`, the interface forms of the protocol-10
        -- broadcasts below. (`Tasks.started` / `ended` follow the task
        -- frames they announce: nothing to do.)
        local args = type(msg.args) == "table" and msg.args or {}
        if msg.object == M.ROOT.object and msg.name == "retiring" then
            return self:_on_message({ kind = "retiring" })
        elseif msg.object == M.ROOT.object and msg.name == "objects_changed" then
            return self:_on_objects_changed(args)
        elseif msg.object == M.WORKSPACE.object and msg.iface == M.WORKSPACE.iface and msg.name == "changed" then
            return self:_model_change(args.seq, args.session_generation)
        end
        return
    end
    if msg.kind == "model_change" then
        return self:_model_change(msg.seq, msg.session_generation)
    elseif msg.kind == "retiring" then
        local d = self.daemon
        if d then self.skip[daemon_id(d.pid, d.start_time)] = true end
        local c = self.conn
        if c then
            self._retired_note = true
            c:close() -- _on_closed (scheduled) records the drop
        end
        return
    elseif msg.kind == "task" then
        return self:_on_task(msg)
    end
end

--- A model change (`model_change`, or `Workspace.changed`, which carries the
--- same `seq` and `session_generation`): apply the files' pending changes,
--- once per `seq` (a daemon of step 5g.2 sends both forms).
--- @param seq any
--- @param generation any
function Observer:_model_change(seq, generation)
    if generation ~= self.generation then
        self.generation = generation
        self.seq = tonumber(seq) or 0
    elseif (tonumber(seq) or 0) <= self.seq then
        return
    else
        self.seq = tonumber(seq) or self.seq
    end
    return self:_reload()
end

--- A task-stream event (spec §19.15).
function Observer:_on_task(msg)
    local id = msg.task_id
    if id == nil then return end
    local task = self._tasks[id]
    if msg.phase == "start" then
        if task then return end
        return self:_add(remote_task.new(self.ws, id, msg.meta, self:_clock()))
    end
    if not task then return end -- started before we connected: not shown
    if msg.phase == "line" or msg.phase == "output" then
        task:append(tostring(msg.text or ""))
    elseif msg.phase == "progress" then
        task.pct = tonumber(msg.pct)
        self:_emit("daemon_task_progress", { task = task })
    elseif msg.phase == "done" then
        -- Its cache write-back's `model_change` came first (§19.16 End): the
        -- editor already reloaded the outcome when the running state clears.
        task:finish(tonumber(msg.exit_code), msg.error, nil, self:_clock())
        self:_forget(id)
        self:_emit("daemon_task_stopped", { task = task })
    end
end

function Observer:_forget(id)
    self._tasks[id] = nil
    for i, v in ipairs(self._order) do
        if v == id then table.remove(self._order, i); break end
    end
end

--- End every running remote task (`reason`). `cleared`: teardown — the
--- tasks are dropped, not ended, so no end result is recorded (§19.16).
--- @param reason string
--- @param cleared? boolean
function Observer:_end_tasks(reason, cleared)
    local ids = vim.list_extend({}, self._order)
    for _, id in ipairs(ids) do
        local task = self._tasks[id]
        if task then
            if cleared then task.cleared = true end
            task:finish(nil, nil, reason, self:_clock())
            self:_forget(id)
            self:_emit("daemon_task_stopped", { task = task })
        end
    end
end

--- The running remote tasks, in start order.
--- @return loomworks.RemoteTask[]
function Observer:tasks()
    local out = {}
    for _, id in ipairs(self._order) do out[#out + 1] = self._tasks[id] end
    return out
end

--- The observer's part of the Runtime line: its state or current note.
--- @return string
function Observer:runtime_line()
    local t = self.note or self.state
    if self.warning then t = t .. " (" .. self.warning .. ")" end
    return t
end

--- The status page's Runtime line (spec/ui.md §1.1, core §19.1, §19.16): the
--- mode, the source that selected it and, in `daemon` mode, the observer's
--- state or note. nil when no mode was selected yet, or when the default
--- picked `in-process` with nothing to report. `warn` is true while a
--- `daemon`-mode observer is not connected (a version mismatch, no host
--- binary, waiting) and for an ignored value or unreadable settings file.
--- @param ws loomworks.Workspace|nil
--- @return string|nil text, boolean warn
function M.runtime_line(ws)
    local sel = ws and ws._runtime_selection
    if not sel then return nil, false end
    local head = sel.mode .. " (" .. sel.source .. ")"
    local obs = M.of(ws)
    if obs then return head .. " — " .. obs:runtime_line(), obs.state ~= "connected" end
    local parts = {}
    if sel.reason then parts[#parts + 1] = sel.reason end
    if sel.warning then parts[#parts + 1] = sel.warning end
    if #parts == 0 then
        if sel.source == "default" and sel.mode ~= "daemon" then return nil, false end
        return head, false
    end
    return head .. " — " .. table.concat(parts, "; "), sel.warning ~= nil
end

--- Stop observing (workspace teardown): timers stop, the connection closes,
--- remote tasks are cleared. The daemon keeps running (§19.11).
function Observer:stop()
    if self.state == "stopped" then return end
    self.state = "stopped"
    self:_stop_timer("_watch")
    self:_stop_timer("_keepalive")
    local c = self.conn
    self.conn = nil
    if c then c.on_close = nil; c:close() end
    self:_end_tasks("the workspace was unloaded", true)
    if self.ws and self.ws._daemon_observer == self then self.ws._daemon_observer = nil end
end

M.Observer = Observer
return M
