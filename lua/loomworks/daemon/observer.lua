--- loomworks/daemon/observer.lua — the editor as an OBSERVER of the workspace
--- daemon (spec §19.16, §19.19 step 4).
---
--- In `daemon` runtime mode every workspace the editor loads gets one
--- Observer (owned by the Workspace, `ws._daemon_observer`, stopped by
--- `Workspace:teardown`). It never runs an operation: the editor's own
--- operations stay on the in-process path. It
---
---   * connects ONLY through the `--stdio` relay (loomworks.daemon.
---     client.relay, §19.16 "Through the relay", step 5i PR G1): before each
---     spawn it selects the host binary (loomworks.provision.select; a
---     search-path or explicit lw is first probed with `lw version --json`,
---     loomworks.provision.probe, the `probing` state, step 5h.5) and runs
---     `<binary> daemon run --root <root> --stdio` — the ordinary form (it
---     connects to the workspace's daemon or starts it) on workspace load,
---     on `:LoomworksDaemon connect`, on `retiring` / after its own `retire`,
---     and once per retirement episode after a status 16; a `--no-launch`
---     relay after a drop (so `lw daemon stop` stays meaningful) and after a
---     status 10 / 11 / 14; `--no-launch --retiring <id>` after a status 14
---     that named the retiring daemon; `--no-launch --skip-instance <id>`
---     after an incompatible daemon it does not observe (never together with
---     `--retiring`). It reads none of lw's internal files to
---     connect, launch or follow a daemon (only `_prune`'s in-use check reads
---     the handle, read-only). With no host binary it spawns nothing and
---     stays in-process;
---   * judges `welcome.daemon` (transport range overlapping ours, schemas not
---     newer; the host version may differ) as `client = "editor"`, `role =
---     "observer"`, and pings it every KEEPALIVE_MS (§19.11); a `welcome`
---     without `via` (an older pin's attached `--stdio`) is observed without
---     that check and never retired. An incompatible daemon it does not
---     observe (including one it declines to retire) has its relay closed;
---     the editor stays in-process and follows a successor through one
---     `--no-launch --skip-instance <id>` relay naming that daemon (step 5i
---     PR G2, `_skip`), or — the daemon's start time unknown, so it cannot
---     be named — spawns no relay until an explicit connect;
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
local views = require("loomworks.views")

local M = {}

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- Keepalive interval (spec §19.11: about every 30 s).
M.KEEPALIVE_MS = env_ms("LW_TEST_DAEMON_KEEPALIVE_MS") or 30000
--- How often a busy incompatible daemon is re-checked (spec §19.16
--- "Retiring an incompatible daemon": about every 30 s).
M.RETIRE_CHECK_MS = env_ms("LW_TEST_DAEMON_RETIRE_CHECK_MS") or 30000
--- How often the `binary.channel` check is weighed in the background (spec
--- §19.16 "Channel upgrades"): a weighing runs no process, it only decides
--- whether a check is due (CHANNEL_RETRY_S, the daily INTERVAL_S).
M.CHANNEL_TICK_MS = env_ms("LW_TEST_DAEMON_CHANNEL_TICK_MS") or 60000

--- @class loomworks.daemon.Observer
--- @field ws loomworks.Workspace
--- @field root string
--- @field state "idle"|"no-binary"|"probing"|"downloading"|"connecting"|"connected"|"waiting"|"stopped"
--- @field note string|nil the current Runtime note
--- @field conn loomworks.daemon.Conn|nil
--- @field daemon { pid: integer, start_time: string|nil, lw_version: string|nil, exe: string|nil }|nil the observed daemon (`exe`: the binary its handle names)
--- @field seq integer last model_change seq
--- @field mode "v0"|"interfaces"|nil how the connected daemon is observed: protocol-10 broadcasts, or subscriptions (step 5g.3)
--- @field feature_note string|nil the per-feature note of a missing or refused interface (§19.16 "Interface client")
--- @field _feat table<string, string>|nil per feature, on this connection: "pending", "subscribed", "refused" (retried once), "gave_up" or "missing" (offered at other versions only)
--- @field _why table<string, string>|nil per feature: why it is not subscribed (its note)
--- @field _sub_only boolean|nil the connected daemon delivers to a transport-11 connection only by subscription (its `describe` reports `delivery = "subscription"`, step 5g.3)
--- @field _view_seq integer|nil the last `seq` of the `/views` object seen on this connection (a gap re-fetches the views, step 5j)
--- @field generation any session generation of the observed daemon
--- @field _tasks table<integer, loomworks.RemoteTask> running remote tasks by daemon task id
--- @field _order integer[] task ids in start order
--- @field _relay loomworks.daemon.RelayProc|nil the relay in flight, until its `welcome` or its exit (single flight); after `welcome` the relay is the connection's (`conn.relay`)
--- @field _relay_token table|nil identifies that relay's callback: `{ form, answer, conn }` (one after a stop or a replacement is ignored)
--- @field _want table|nil the relay to spawn once a probe or download in flight ends: `{ form, instance?, answer?, prefix? }`
--- @field _episode { launched: boolean|nil }|nil the open retirement episode (§19.16 "Following a stopped or retiring daemon"): its one ordinary relay after a status 16 is spent once `launched`
--- @field _binary string|nil the host binary the last relay was spawned from (an ordinary relay launches the daemon from it)
--- @field _downloading string|nil the hash of the plugin-managed lw being downloaded (step 5h.3)
--- @field _dl_token table|nil identifies that download's callback (a cancelled one's is ignored)
--- @field _download_failed string|nil the hash whose download failed: not retried until an explicit connect
--- @field _download_note string|nil that failure's note
--- @field _probing string|nil the binary whose pre-launch probe is in flight (step 5h.5)
--- @field _probe_token table|nil identifies that probe's callback (one after a stop or the backstop is ignored)
--- @field _probe_backstop uv.uv_timer_t|nil ends `probing` as unknown if the probe never calls back
--- @field probe_note string|nil the last selection's lasting probe note (a skipped lw on PATH, an incompatible explicit lw), shown on the Runtime line
--- @field selection loomworks.provision.Selection|nil the last host-binary selection (spec §19.16 "Host binary"), made when it launches
--- @field _keepalive userdata|nil the keepalive ping timer
--- @field _retire_timer userdata|nil the busy incompatible daemon's re-check timer
--- @field _channel_timer userdata|nil the `binary.channel` check's weighing timer (unref'd; stopped on stop)
--- @field _channel_undecided boolean|nil the last weighing found the selection undecided (CHANNEL_RETRY_S)
--- @field _retired_note boolean|nil the connection is being closed because the daemon retires
--- @field _retire loomworks.daemon.RetireWait|nil an incompatible daemon weighed for a retirement (step 5h.5): its connection is the observed one (older schemas only) or held, unobserved, while the selected binary is probed or while the daemon is busy
--- @field incompat_note string|nil the observed daemon is incompatible (older schemas): what the editor does about it, on the Runtime line
--- @field retire_check_ms integer how often a busy incompatible daemon is re-checked through `status` (spec §19.16: about every 30 s)
--- @field retired_note string|nil the last retirement this observer made (why), shown on the Runtime line until it observes the successor
--- @field channel_note string|nil the `binary.channel` check's note (step 5h.5: an accepted, rejected or failed check, or why the channel has no effect), shown on the Runtime line
--- @field _channel_token table|nil the channel check (query or download) in flight (single flight; a late callback after a stop is ignored)
--- @field _channel_next integer|nil when (epoch s) the next background channel check is weighed
--- @field _channel_force boolean|nil an explicit connect asked for a channel check that could not run yet (the selection undecided, or a check in flight: it runs right after that one)
--- @field opts table the attach options (test seams, see `attach`)
--- @field keepalive_ms integer keepalive ping interval
--- @field warning string|nil an invalid runtime-mode value that was ignored (shown on the Runtime line)
local Observer = {}
Observer.__index = Observer

--- The interface versions the observer uses (spec §19.16 "Interface client",
--- step 5g.3): each names its object, interface and version (the guard's
--- interface ratchet, tests/split, checks a schema and transcripts exist),
--- and declares the `methods` it calls and the `signals` it handles there
--- (the guard checks every literal method of a `conn:call` here is declared
--- and every declared one is covered by that version's transcripts, step
--- 5j). Keep `signals` in step with `_on_message`.
M.ROOT = {
    object = "/", iface = "loomworks.Root", v = 1,
    methods = { "describe", "subscribe" }, signals = { "retiring", "objects_changed" },
}
M.TASKS = {
    object = "/tasks", iface = "loomworks.Tasks", v = 1, feature = "tasks",
    methods = {}, signals = {},
}
M.WORKSPACE = {
    object = "/workspace", iface = "loomworks.Workspace", v = 1, feature = "model changes",
    methods = {}, signals = { "changed" },
}
-- The editor views (§19.13 "Views", step 5j): `initial`, then each full-state
-- `update`, `get` after a `seq` gap, into the view store (loomworks.views)
-- under the store's name `view`.
M.VIEW_HEADER = {
    object = "/views", iface = "loomworks.view.Header", v = 1, feature = "statusline",
    methods = { "get" }, signals = { "update" }, view = "header",
}
M.VIEW_PROJECTS = {
    object = "/views", iface = "loomworks.view.ProjectsIndex", v = 1, feature = "project index",
    methods = { "get" }, signals = { "update" }, view = "projects",
}
M.VIEWS = { M.VIEW_HEADER, M.VIEW_PROJECTS }
M.FEATURES = { M.TASKS, M.WORKSPACE, M.VIEW_HEADER, M.VIEW_PROJECTS }

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
---   relay       fun(opts, cb) → relay|nil, err (loomworks.daemon.client.relay.connect: spawns the relay)
---   kill_ms     the relay's kill backstop (loomworks.daemon.client.relay.KILL_MS)
---   probe_cached fun(path) → verdict|nil, or false (loomworks.provision.probe.cached; passed to resolve)
---   run_probe   fun(path, opts, cb(verdict)) (loomworks.provision.probe.run)
---   probe_backstop_ms  how long to wait for run_probe's callback before going on as unknown (default probe.TIMEOUT_MS + 2 s)
---   fetch       fun(wanted, opts, cb(path|nil, err)) (loomworks.provision.fetch.ensure)
---   cancel_fetch fun(sha256, why) (loomworks.provision.fetch.cancel)
---   touch       fun(path) (loomworks.provision.managed.touch)
---   prune       fun(opts) (loomworks.provision.cache.prune)
---   inspect     fun(root) → state (loomworks.daemon.inspect.state; only `_prune`'s read-only in-use check)
---   wanted      fun() → loomworks.provision.Wanted|nil (loomworks.provision.managed.wanted: the managed lw's version, for a retirement)
---   data        the editor's data directory (the managed lw, channel.json; default stdpath("data"))
---   pinned_wanted fun() → loomworks.provision.Wanted|nil (loomworks.provision.managed.pinned_wanted)
---   channel_query fun(pinned, channel, opts, cb(res)) (loomworks.provision.channel.run)
---   channel_load / channel_save  replace loomworks.provision.channel.load / save
---   now         fun() → epoch seconds (the channel interval)
---   notify      fun(msg, level) (vim.notify: the one notice of a retirement)
---   keepalive_ms, retire_check_ms
---   channel_tick_ms  replaces CHANNEL_TICK_MS
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
        ws = ws, root = ws.root, opts = opts, state = "idle", seq = 0,
        _tasks = {}, _order = {},
        keepalive_ms = opts.keepalive_ms or M.KEEPALIVE_MS,
        retire_check_ms = opts.retire_check_ms or M.RETIRE_CHECK_MS,
        channel_tick_ms = opts.channel_tick_ms or M.CHANNEL_TICK_MS,
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

--- Adopt the daemon's full state of a view into the store; the status page
--- re-renders (its header reads the store).
--- @param name loomworks.ViewName
--- @param state table
function Observer:_set_view(name, state)
    views.set(self, name, state)
    self:_emit("daemon_view_changed", { view = name })
end

--- Drop this observer's daemon views (all, or `name`) from the store: they
--- are built in-process again, and the status page re-renders the same way
--- as on a set. Every clear (a removed `/views`, a resubscribe, a close, a
--- stop) goes through here.
--- @param name? loomworks.ViewName
function Observer:_clear_views(name)
    if views.clear(self, name) then
        self:_emit("daemon_view_changed", { view = name })
    end
end

--- Set the state and the note; the status page re-renders.
function Observer:_set(state, note)
    if self.state == state and self.note == note then return end
    self.state, self.note = state, note
    self:_emit("daemon_runtime_changed", self)
end

--- Start observing (spec §19.16 "Through the relay"): spawn an ordinary
--- relay — on workspace load, or `explicit` from `:LoomworksDaemon connect`,
--- which also ends a relay that only waits (it launches nothing) and the open
--- retirement episode. Single flight: nothing while connected, while a
--- connection is held to retire an incompatible daemon, or while an
--- ordinary relay is in flight.
--- @param explicit boolean
function Observer:start(explicit)
    if self.state == "stopped" then return end
    if explicit then
        self._download_failed = nil
        self._episode = nil
        -- An explicit connect aborts a download in flight (it may hang) and
        -- starts over.
        if self._downloading then self:_cancel_download("restarted by :LoomworksDaemon connect") end
    end
    -- The binary.channel check runs in the background (step 5h.5): on load
    -- when due, on every explicit connect, and on a low-rate tick for a long
    -- session (the undecided retry, the daily re-check).
    self:_channel_check(explicit)
    self:_start_channel_timer()
    if self.conn or self._retire then return end
    if self._downloading or self._probing then
        if explicit then self._want = { form = "ordinary" } end
        return
    end
    if self._relay then
        if not explicit or (self._relay_token and self._relay_token.form == "ordinary") then return end
        self:_end_relay()
    end
    self:_spawn({ form = "ordinary" })
end

--- The instance id `<pid>:<start_time>` (§19.5, the value `--skip-instance`
--- takes) of a daemon from `welcome.daemon`, or nil when either part is
--- missing or malformed: a daemon whose start time is unknown cannot be
--- named. The same form as the binary's connect.instance_id (not required
--- here: the plugin reaches the binary only through the protocol).
--- @param d table|nil { pid, start_time }
--- @return string|nil
function M.instance_id(d)
    if type(d) ~= "table" then return nil end
    local pid, st = d.pid, d.start_time
    if type(pid) ~= "number" or pid < 1 or pid > 0x7fffffff or pid ~= math.floor(pid) then return nil end
    if type(st) ~= "string" or not st:match("^%a+:%S+$") then return nil end
    return string.format("%d:%s", pid, st)
end

--- The waiting note of a relay form until it forwards `welcome` (§19.16
--- "Waiting notes"). `what` names the binary and its source (ordinary).
--- @param form string
--- @param what? string
--- @return string
function M.form_note(form, what)
    if form == "ordinary" then
        return "connecting to or starting the workspace daemon" .. (what and (" (" .. what .. ")") or "")
    elseif form == "retiring" then
        return "waiting for the retiring daemon to exit"
    elseif form == "skip" then
        -- Follows the incompatible-daemon note (its prefix, `_skip`).
        return "waiting for another workspace daemon, none is launched"
    end
    return "waiting for a workspace daemon, none is launched (:LoomworksDaemon connect starts one)"
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

--- Select the host binary and spawn a relay of `want.form` from it (spec
--- §19.16 "Through the relay"). A search-path or explicit lw with no cached
--- probe verdict is probed first (spec §19.16 "Pre-launch probe", step 5h.5:
--- `_probe`, then here again with `probed` set, so a binary whose verdict
--- could not be cached is used as unknown rather than probed again); a
--- wanted plugin-managed lw is downloaded first. With no host binary no
--- relay is spawned: the editor stays in-process.
--- want: { form, instance? (retiring, skip), answer? (spawned for a status 10/11),
---         prefix? (the note it follows) }
--- @param want table
--- @param probed? boolean called back from `_probe`
function Observer:_spawn(want, probed)
    self._want = want
    local binsel = require("loomworks.provision.select")
    local resolve = self.opts.resolve or binsel.resolve
    local bin, source, sel = resolve(self.root, { getenv = self.opts.getenv, setting = self.opts.binary,
        probe = self.opts.probe_cached, data = self.opts.data })
    if type(sel) ~= "table" then
        sel = { path = bin, source = source, label = binsel.LABELS[source] or source, candidates = {} }
    end
    self.selection = sel
    self.probe_note = sel.probe_note
    if bin and sel.probe and not probed then return self:_probe(sel.probe) end
    if not bin then
        if sel.download then return self:_download(sel) end
        self._want = nil
        return self:_set("no-binary", binsel.none_note(sel))
    end
    self._want = nil
    local token = { form = want.form, answer = want.answer, instance = want.instance }
    local connect = self.opts.relay or require("loomworks.daemon.client").relay.connect
    local r, err = connect({
        argv = { bin }, root = self.root, env = sel.env, form = want.form, instance = want.instance,
        client = "editor", role = "observer", kill_ms = self.opts.kill_ms,
        on_message = function(msg)
            vim.schedule(function()
                -- Only the observed connection's messages count: one held
                -- to retire an incompatible daemon it cannot observe is not
                -- observed through (its task frames would start tasks that
                -- nothing ends).
                if not token.conn or token.conn ~= self.conn then return end
                self:_on_message(msg)
            end)
        end,
        on_close = function(c) vim.schedule(function() self:_on_closed(c) end) end,
    }, function(conn, cerr, info)
        vim.schedule(function() self:_on_relay(token, conn, cerr, info) end)
    end)
    if not r then
        return self:_set("waiting", "could not start the relay to the workspace daemon from " .. bin .. " ("
            .. tostring(err) .. ")")
    end
    self._relay, self._relay_token = r, token
    self._binary = bin
    local note = M.form_note(want.form, sel.label and binsel.describe(sel) or bin)
    if want.prefix then note = want.prefix .. " — " .. note end
    self:_set(want.form == "ordinary" and "connecting" or "waiting", note)
end

--- End the relay in flight (before its `welcome`): close its standard input
--- (client.relay: a plain kill of its own pid only after about 5 s, never a
--- tree kill). Its exit is not mapped.
function Observer:_end_relay()
    local r = self._relay
    self._relay, self._relay_token = nil, nil
    if r then pcall(r.close, r) end
end

--- Probe `path` (`lw version --json`, async and bounded; loomworks.provision.
--- probe), then select again over the now cached verdict and spawn the
--- relay that was wanted (`_want`). The editor keeps working meanwhile; the Runtime note says so.
--- @param path string
function Observer:_probe(path)
    if self._probing then return end
    self._probing = path
    local token = {}
    self._probe_token = token
    self:_set("probing", "checking " .. path .. " (lw version --json) before connecting to the workspace daemon")
    local probe = require("loomworks.provision.probe")
    local run = self.opts.run_probe or probe.run
    -- Belt and braces: the probe is bounded (TIMEOUT_MS), but a callback
    -- that never arrives must not leave the observer `probing` for good.
    -- After the backstop the binary counts as unknown (used; the handshake
    -- decides) and a late callback is ignored (the token is gone).
    local function finish()
        if self._probe_token ~= token then return end -- a stop or the backstop owns the state
        self._probe_token, self._probing = nil, nil
        self:_stop_timer("_probe_backstop")
        if self.state == "stopped" then return end
        -- The verdict may have decided the selection: weigh the channel again.
        self:_channel_recheck()
        if self.conn or self._relay or self._retire then return end
        self:_spawn(self._want or { form = "ordinary" }, true)
    end
    self._probe_backstop = uv.new_timer()
    self._probe_backstop:start(self.opts.probe_backstop_ms or (probe.TIMEOUT_MS + 2000), 0, vim.schedule_wrap(finish))
    run(path, nil, finish)
end

--- Download the plugin-managed lw the selection wants (spec §19.16, step
--- 5h.3), then spawn the relay that was wanted (`_want`). A failure is one note and leaves the editor in-process; it is not
--- retried until `:LoomworksDaemon connect`.
--- @param sel loomworks.provision.Selection
function Observer:_download(sel)
    local want = sel.download
    local what = "the plugin-managed lw v" .. tostring(want.version) .. " (" .. tostring(want.asset) .. ")"
    if self._downloading then return end
    if self._download_failed == want.sha256 then
        return self:_set("no-binary", self._download_note)
    end
    local fetch = require("loomworks.provision.fetch")
    local setting = self.opts.binary or {}
    self._downloading = want.sha256
    local token = {}
    self._dl_token = token
    local fopts = { release_url = setting.release_url, getenv = self.opts.getenv, data = self.opts.data }
    local st = (self.opts.fetch or fetch.ensure)(want, fopts, function(path, err)
        if self._dl_token ~= token then return end -- cancelled: a newer download or a stop owns the state
        self._dl_token = nil
        self._downloading = nil
        if self.state == "stopped" then return end
        if not path then
            self._download_failed = want.sha256
            self._download_note = "could not install " .. what .. ": " .. tostring(err) .. " — running in-process"
            return self:_set("no-binary", self._download_note)
        end
        self:_prune(want)
        -- The selection now reaches the managed lw: weigh the channel again.
        self:_channel_recheck()
        if self.conn or self._relay or self._retire then return end
        self:_spawn(self._want or { form = "ordinary" })
    end)
    local url = type(st) == "table" and st.url or fetch.url(want, fopts)
    if self._downloading then
        self:_set("downloading", "downloading " .. what .. " from " .. tostring(url) .. " — running in-process meanwhile")
    end
end

--- Abort the download in flight (loomworks.provision.fetch.cancel: curl is
--- killed, its partial file removed); its callback is ignored.
--- @param why string
function Observer:_cancel_download(why)
    local sha = self._downloading
    self._downloading, self._dl_token = nil, nil
    if sha then pcall(self.opts.cancel_fetch or require("loomworks.provision.fetch").cancel, sha, why) end
end

--- Remove the plugin-managed binaries other than the wanted ones — `want`,
--- the pin's and, with `binary.channel` set, the accepted channel release's
--- (spec §19.16 "Channel upgrades": both are kept) — never one in use: the
--- binary this observer's relays run from, the observed daemon's, the live
--- daemon's (loomworks.provision.cache, deletion-safety rule 11). Best effort.
--- (The live daemon's handle is read here, read-only, only for this in-use
--- check — never to decide whether, when or to what the editor connects.)
--- @param want loomworks.provision.Wanted
function Observer:_prune(want)
    local list = {}
    local function use(p) if type(p) == "string" and p ~= "" then list[#list + 1] = p end end
    use(self._binary)
    use(self.daemon and self.daemon.exe)
    local ok, st = pcall(self.opts.inspect or require("loomworks.daemon.inspect").state, self.root)
    if ok and type(st) == "table" and type(st.handle) == "table" then use(st.handle.exe) end
    local keep, seen = {}, {}
    local function add(w)
        local sha = type(w) == "table" and w.sha256 or nil
        if type(sha) == "string" and not seen[sha] then seen[sha] = true; keep[#keep + 1] = sha end
    end
    add(want)
    local managed = require("loomworks.provision.managed")
    local pok, pin = pcall(self.opts.pinned_wanted or managed.pinned_wanted)
    if pok then add(pin) end
    local wok, cur = pcall(managed.wanted, { setting = self.opts.binary, data = self.opts.data })
    if wok then add(cur) end
    pcall(self.opts.prune or require("loomworks.provision.cache").prune,
        { keep = keep, in_use = list, data = self.opts.data })
end

--- How long (s) before the observer weighs again a channel check it could
--- not decide (the selection did not reach the managed lw yet, e.g. an lw on
--- PATH still to be probed). Weighing runs no process.
M.CHANNEL_RETRY_S = 60

--- Weigh the channel check every `channel_tick_ms` while the observer
--- lives (idempotent). Unref'd: it never keeps the editor alive.
function Observer:_start_channel_timer()
    if self._channel_timer or self.state == "stopped" then return end
    local t = uv.new_timer()
    self._channel_timer = t
    t:start(self.channel_tick_ms, self.channel_tick_ms, vim.schedule_wrap(function()
        if self._channel_timer ~= t then return end
        pcall(self._channel_check, self, false)
    end))
    pcall(function() t:unref() end)
end

--- Weigh the channel check again now that a probe or a download ended: a
--- selection that was undecided (CHANNEL_RETRY_S) may be decided by it, so
--- that retry's wait is not kept.
function Observer:_channel_recheck()
    if self._channel_undecided then self._channel_next = nil end
    pcall(self._channel_check, self, false)
end

--- Set the channel check's note; the status page re-renders.
--- @param note string|nil
function Observer:_set_channel_note(note)
    if self.channel_note == note then return end
    self.channel_note = note
    self:_emit("daemon_runtime_changed", self)
end

--- The `binary.channel` check (spec §19.16 "Channel upgrades", step 5h.5):
--- in the background, at most once a day (channel.json's last check) and on
--- every explicit connect (one that arrives while a check runs re-runs it
--- once that check ends), when the setting applies and the selection reaches
--- the managed lw. Weighed on start, on a low-rate tick (`_channel_timer`),
--- and after a probe or a download ends. The pinned managed lw is made present first (the same
--- download as a launch's, shared per hash), then it runs `release query`
--- (loomworks.provision.channel.run); a newer release that passes the check is
--- downloaded and only then recorded as accepted. A running daemon is never
--- switched: the next launch uses the new binary. Any failure is one note;
--- the editor keeps the current wanted binary.
--- @param explicit boolean `:LoomworksDaemon connect`
function Observer:_channel_check(explicit)
    if explicit then self._channel_force = true end
    if self.state == "stopped" or self._channel_token then return end
    local chan = require("loomworks.provision.channel")
    local binsel = require("loomworks.provision.select")
    local setting = binsel.check_setting(self.opts.binary)
    if not chan.applies(setting) then
        self._channel_force, self._channel_undecided = nil, nil
        return self:_set_channel_note(nil)
    end
    local now = (self.opts.now or os.time)()
    if not self._channel_force and self._channel_next and now < self._channel_next then return end
    local _, _, sel = (self.opts.resolve or binsel.resolve)(self.root, { getenv = self.opts.getenv,
        setting = self.opts.binary, probe = self.opts.probe_cached, data = self.opts.data })
    if type(sel) ~= "table" or sel.probe or sel.source ~= "managed" then
        -- An lw the user installed or named is selected (the channel has no
        -- effect, said once), or the selection is still undecided.
        self._channel_next = now + M.CHANNEL_RETRY_S
        self._channel_undecided = true
        return self:_set_channel_note(type(sel) == "table" and sel.channel_note or nil)
    end
    self._channel_undecided = nil
    local data = self.opts.data
    local rec = chan.for_channel((self.opts.channel_load or chan.load)({ data = data }), setting.channel)
    if not self._channel_force and not chan.due(rec, setting.channel, now) then
        self._channel_next = (rec.checked or now) + chan.INTERVAL_S
        return self:_set_channel_note(rec.note)
    end
    self._channel_force = nil
    local managed = require("loomworks.provision.managed")
    local pin = (self.opts.pinned_wanted or managed.pinned_wanted)()
    if type(pin) ~= "table" then
        -- No pinned binary for this host: nothing can resolve a channel.
        self._channel_next = now + chan.INTERVAL_S
        return
    end
    local token = {}
    self._channel_token = token
    local fetch = self.opts.fetch or require("loomworks.provision.fetch").ensure
    local fopts = { release_url = setting.release_url, getenv = self.opts.getenv, data = data }
    local function current() return managed.wanted({ setting = setting, data = data }) or pin end
    local function ctx()
        return { channel = setting.channel, current = current(), asset = pin.asset, rejected = rec.rejected,
            pinned_version = pin.version }
    end
    local function save(out)
        -- Every completion ends here (the token already cleared). An
        -- explicit connect that arrived while this check ran set
        -- `_channel_force` again (this check cleared it when it began): it
        -- gets a check of its own, run right after this one.
        local nrec = chan.record(rec, out, (self.opts.now or os.time)())
        pcall(self.opts.channel_save or chan.save, nrec, { data = data })
        self._channel_next = nrec.checked + chan.INTERVAL_S
        self:_set_channel_note(out.note)
        if self._channel_force then
            vim.schedule(function() pcall(self._channel_check, self, false) end)
        end
    end
    -- 1. The pinned managed lw, present and verified.
    fetch(pin, fopts, function(pinned, perr)
        if self._channel_token ~= token or self.state == "stopped" then return end
        if not pinned then
            self._channel_token = nil
            return save(chan.classify({ error = "the pinned lw v" .. tostring(pin.version) .. " could not be installed: "
                .. tostring(perr) }, ctx()))
        end
        -- 2. It resolves the channel.
        local query = self.opts.channel_query or chan.run
        query(pinned, setting.channel, { release_url = setting.release_url, data = data }, function(res)
            if self._channel_token ~= token or self.state == "stopped" then return end
            local c = ctx()
            local out = chan.classify(res, c)
            if out.kind ~= "accepted" then
                self._channel_token = nil
                return save(out)
            end
            -- 3. Accepted: download it (hash from the query), then record it.
            local what = "lw v" .. out.version .. " from " .. setting.channel
            self:_set_channel_note("downloading " .. what .. " — staying on lw v" .. tostring(c.current.version)
                .. " meanwhile")
            fetch(out.wanted, fopts, function(path, err)
                if self._channel_token ~= token or self.state == "stopped" then return end
                self._channel_token = nil
                if not path then
                    return save(chan.classify({ error = "could not install " .. what .. ": " .. tostring(err) }, c))
                end
                local running = self.conn or self._relay or self._retire
                local extra = out.override and ("; " .. out.override) or ""
                out.note = what .. " is installed"
                    .. (running and ": the next daemon launch uses it (the running daemon is not switched)" or "")
                    .. extra
                save(out)
                self:_prune(out.wanted)
                -- Not running a daemon for want of a binary: start over.
                if not running and (self.state == "no-binary" or self.state == "idle") then self:start(false) end
            end)
        end)
    end)
end

--- The pinned `lw` version of the workspace (`lw.pin`, §16.21: the nearest
--- one up from the root, not past a git working tree's top), for the note
--- of a relay flag the pinned release does not support — read only for that
--- note, never to decide anything — or nil. (Its `version = <v>` line only;
--- the plugin does not use the lw side's pin module, boot.pin.)
--- @param root string
--- @return string|nil
function M.pinned_version(root)
    local dir = type(root) == "string" and root:gsub("\\", "/"):gsub("/+$", "") or ""
    while dir ~= "" do
        if uv.fs_stat(dir .. "/lw.pin") then
            local f = io.open(dir .. "/lw.pin", "r")
            if not f then return nil end
            local text = f:read("*a") or ""
            f:close()
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local v = line:match("^%s*version%s*=%s*([%w%.%-%+]+)%s*$")
                if v then return v end
            end
            return nil
        end
        if uv.fs_stat(dir .. "/.git") then return nil end
        local parent = dir:gsub("/[^/]*$", "")
        if parent == dir then break end
        dir = parent
    end
    return nil
end

--- The Runtime note of a relay that exited before `welcome` (§19.16 "Exit
--- before `welcome`"), without its follow-up; the relay's `lw: …` line is
--- the detail (never the status-14 `retiring` line).
--- @param code integer|nil
--- @param form string the relay's form
--- @param root string
--- @return string
function M.exit_note(code, form, root)
    if code == 10 then return "could not start the workspace daemon; the editor runs degraded" end
    if code == 11 then return "the workspace daemon is not responding" end
    if code == 12 then return "the daemon belongs to another loomworks data dir, or is not a loomworks daemon" end
    if code == 13 then return "the workspace daemon runs on another host" end
    if code == 14 then return "a retiring daemon is still busy" end
    if code == 16 then return "the retiring daemon has exited and no other is live" end
    if code == 3 then
        return "the pinned lw predates the shared-daemon relay and another runtime holds this workspace; "
            .. "running in-process — update the pin"
    end
    if code == 2 and form ~= "ordinary" then
        local v = M.pinned_version(root)
        if v then return "the pinned lw " .. v .. " does not support the editor relay flags — update the pin" end
    end
    if code == 2 then return "internal error (usage)" end
    if code == 15 then return "internal error (protocol)" end
    if code == 0 then return "internal error (the relay ended although the editor kept its standard input open)" end
    return "internal error (the relay exited with status " .. tostring(code) .. ")"
end

--- The relay's outcome (client.relay.connect's callback, on the main loop):
--- its `welcome` — judged and observed, or an incompatible daemon weighed
--- for a retirement — or its exit before `welcome` (`_on_relay_exit`).
--- @param token table the relay's token (`_relay_token`)
--- @param conn loomworks.daemon.Conn|nil
--- @param err string|nil
--- @param info loomworks.daemon.RelayExit|nil
function Observer:_on_relay(token, conn, err, info)
    -- Only the relay in flight counts; anything else (stopped meanwhile,
    -- replaced) closes the connection it got.
    if self.state == "stopped" or self._relay_token ~= token or self.conn then
        if conn then conn.on_close = nil; conn:close() end
        return
    end
    self._relay, self._relay_token = nil, nil
    if not conn then return self:_on_relay_exit(token, err, info) end
    token.conn = conn
    -- The retirement episode ends at the next `welcome`.
    self._episode = nil
    local w = conn.welcome or {}
    local via = w.via == "relay"
    local d = via and type(w.daemon) == "table" and w.daemon or {}
    -- `exe`: the executable the daemon's handle names (§19.6; display only).
    local target = { pid = d.pid, start_time = d.start_time,
        exe = type(d.exe) == "string" and d.exe ~= "" and d.exe or nil }
    local ch = conn.challenge or {}
    local inc
    if via then
        -- Judged by the EDITOR's compatibility rule from `welcome.daemon`
        -- (§19.16 "Through the relay"): the relay applies no version policy.
        local version = require("loomworks.daemon.version")
        local ok, what = version.observer_compatible(ch)
        -- Incompatible (§19.16 "Retiring an incompatible daemon", step 5h.5): no
        -- transport overlap, schemas other than ours, or no loomworks.Root/1. A
        -- daemon with newer schemas is only refused. One whose only problem is
        -- older schemas is observed as usual and weighed for a retirement on the
        -- observed connection; any other is weighed on a held connection it is
        -- not observed through. Its relay is closed when the editor does not
        -- observe it, and a successor is followed through a skip relay
        -- (step 5i PR G2, `_skip`).
        if token.form == "skip" and M.instance_id(target) == token.instance then
            -- A skip relay never connects to the daemon it skips (§19.10
            -- "Skip an instance"); one that did is not trusted, and nothing
            -- is spawned again (no loop back to that daemon).
            conn.on_close = nil
            conn:close()
            return self:_set("waiting", "internal error: the relay connected to the daemon it was told to skip "
                .. "(pid " .. tostring(target.pid) .. ") — :LoomworksDaemon connect tries again")
        end
        inc = require("loomworks.daemon.editor_retire").incompatibility(ch, conn)
        if (not ok or inc) and not (inc and inc.observable) then
            if inc and not inc.newer then return self:_weigh_retire(target, conn, ch, inc) end
            conn.on_close = nil
            conn:close()
            return self:_skip(target, M.mismatch_note(ch, what or "schemas", target.exe or self._binary))
        end
    end
    -- (A `welcome` without `via` is an older pin's attached `--stdio`: no
    -- `welcome.daemon` to judge, observed without the check, never retired.)
    if w.retiring then
        -- (A relay waits out a retiring daemon itself; one forwarded anyway
        -- is followed as a `retiring`.)
        conn.on_close = nil
        conn:close()
        return self:_after_retire("the workspace daemon (pid " .. tostring(target.pid) .. ") is retiring")
    end
    self.conn = conn
    self.retired_note = nil
    self.daemon = { pid = target.pid, start_time = target.start_time, lw_version = ch.lw_version, exe = target.exe }
    -- A daemon running a plugin-managed binary marks it used, so no editor
    -- prunes it (loomworks.provision.cache; a no-op for any other binary).
    if target.exe then pcall(self.opts.touch or require("loomworks.provision.managed").touch, target.exe) end
    self.generation = ch.session_generation
    self.seq = tonumber(w.seq) or 0
    self:_start_keepalive()
    self.feature_note = nil
    self.incompat_note = nil
    self:_subscribe(conn, function()
        self:_connected_note()
        -- What the daemon wrote before we connected (and subscribed): catch
        -- up now.
        self:_reload()
        self:_join_late(conn)
        -- Older schemas only: observed, and weighed for a retirement.
        if inc then self:_weigh_retire(target, conn, ch, inc) end
    end)
end

--- A relay exited before `welcome` (§19.16 "Exit before `welcome`"): its
--- status's note, with the relay's `lw: …` line as detail, and its
--- follow-up — one no-launch relay after a 10 / 11 (not in answer to one
--- that was itself such an answer), a retiring (or no-launch) relay after a
--- 14, the episode's one ordinary relay after a 16; otherwise wait: stay
--- in-process with the note until an explicit `:LoomworksDaemon connect`.
--- @param token table
--- @param err string|nil "exit" or "protocol"
--- @param info loomworks.daemon.RelayExit|nil
function Observer:_on_relay_exit(token, err, info)
    info = info or {}
    local code = info.code
    local function with(note) return info.line and (note .. " (" .. info.line .. ")") or note end
    if err ~= "exit" or code == nil then
        return self:_set("waiting", with("internal error: the relay to the workspace daemon failed"))
    end
    local note = M.exit_note(code, token.form, self.root)
    if code == 10 or code == 11 then
        if token.answer then return self:_set("waiting", with(note)) end
        return self:_spawn({ form = "no-launch", answer = true, prefix = with(note) })
    elseif code == 14 then
        -- A status 14 starts a retirement episode when none is open; the
        -- wait goes on in a relay that never launches (§19.16 "Status 14").
        self._episode = self._episode or {}
        if info.retiring then
            return self:_spawn({ form = "retiring", instance = info.retiring, prefix = with(note) })
        end
        return self:_spawn({ form = "no-launch", prefix = with(note) })
    elseif code == 16 then
        -- At most one ordinary relay per retirement episode (§19.16 "Status 16").
        local ep = self._episode
        if ep and not ep.launched then
            ep.launched = true
            return self:_spawn({ form = "ordinary", prefix = note })
        end
        return self:_set("waiting", with(note) .. " — :LoomworksDaemon connect starts one")
    end
    return self:_set("waiting", with(note))
end

--- The observed daemon retires (its `retiring`, or the editor's own
--- `retire` succeeded): spawn one ordinary relay — its own wait
--- (`RELAY_RETIRE_WAIT`) covers the retiring daemon and it launches the
--- successor — and open a retirement episode (§19.16 "Retiring").
--- @param prefix string the note it follows
function Observer:_after_retire(prefix)
    self._episode = { launched = false }
    if self._relay then self:_end_relay() end
    return self:_spawn({ form = "ordinary", prefix = prefix })
end

--- Follow past an incompatible daemon the editor does not observe (spec
--- §19.16 "Skipping an incompatible daemon", step 5i PR G2): its relay is
--- already closed; the editor stays in-process and spawns one `--no-launch
--- --skip-instance <pid>:<start_time>` relay naming it from
--- `welcome.daemon`, which never connects to it, launches nothing and
--- connects to a successor once one is live (judged afresh). A daemon whose
--- start time is unknown cannot be named (§19.5): no relay is spawned, and
--- the editor stays in-process for the session until an explicit
--- `:LoomworksDaemon connect`. Nothing is retried on a timer.
--- @param target table the daemon { pid, start_time, exe } (`welcome.daemon`)
--- @param note string the incompatible-daemon note
function Observer:_skip(target, note)
    -- Already observing a daemon (a successor connected meanwhile): a late
    -- outcome of an earlier wait (a retire reply after its connection
    -- closed) spawns nothing and leaves the state as it is.
    if self.state == "stopped" or self.conn then return end
    if self._relay then self:_end_relay() end
    local id = M.instance_id(target)
    if not id then
        return self:_set("waiting", note .. " (its start time is unknown, so no relay can skip it; "
            .. ":LoomworksDaemon connect tries again)")
    end
    return self:_spawn({ form = "skip", instance = id, prefix = note })
end

--- @class loomworks.daemon.RetireWait  an incompatible daemon being weighed for a retirement (step 5h.5)
--- @field conn loomworks.daemon.Conn the connection to it: the observed one (`observed`), or held and not observed through
--- @field observed boolean|nil only its schemas are older: it is observed meanwhile (spec §19.16 "Connect")
--- @field target table the daemon { pid, start_time, exe }
--- @field ch table its challenge
--- @field inc loomworks.daemon.Incompatibility why it is incompatible
--- @field probed boolean|nil the selected binary was probed for this weighing (never twice)
--- @field version string|nil the selected binary's lw_version (once weighed eligible)
--- @field asking boolean|nil a `status` is in flight (still unanswered at the next re-check tick, it ends the wait)
--- @field retiring boolean|nil `retire` was sent (at most once)
--- @field settled boolean|nil the `retire` outcome was handled (its reply, or no reply within a re-check tick)

--- Weigh an incompatible daemon for a retirement (spec §19.16 "Retiring an
--- incompatible daemon", §19.9 "Editor retirement", step 5h.5). The editor
--- sends `retire` (never `stop`) only when the daemon is idle, its schemas
--- are not newer (the caller refused those), the binary the editor selected
--- passed the interface check, that binary's `lw_version` differs from the
--- daemon's, and no daemon of that `lw_version` was retired for this
--- workspace in this editor session. A daemon whose only problem is older
--- schemas is observed meanwhile, and for the whole session when the editor
--- declines to retire it (a note on the Runtime line); any other is noted
--- and not observed — its connection is held while the selected binary is
--- probed and while the daemon is busy, then closed. A busy daemon is
--- re-checked through `status` every `retire_check_ms`; nothing else
--- connects meanwhile.
--- @param target table
--- @param conn loomworks.daemon.Conn
--- @param ch table
--- @param inc loomworks.daemon.Incompatibility
--- @param probed? boolean
function Observer:_weigh_retire(target, conn, ch, inc, probed)
    local R = require("loomworks.daemon.editor_retire")
    local binary = target.exe or self._binary
    local wait = self._retire
    if not wait then
        wait = { conn = conn, target = target, ch = ch, inc = inc, observed = self.conn == conn or nil }
        self._retire = wait
        if not wait.observed then
            -- The daemon goes away (stops, exits, drops us) or its relay
            -- ends: forget it, and follow a successor through a skip relay
            -- naming it, which launches nothing (step 5i PR G2, `_skip`).
            -- (The observed connection's close is `_on_closed`.)
            conn.on_close = function(c)
                vim.schedule(function()
                    if self._retire and self._retire.conn == c then
                        self:_drop_retire()
                        if self.state ~= "stopped" then
                            self:_skip(target, R.note(ch, inc, binary, "its connection closed — not observing it; "
                                .. "running in-process"))
                        end
                    end
                end)
            end
        end
    end
    wait.probed = wait.probed or probed
    -- Declined: an observed daemon stays observed (the note says why it is
    -- not retired); a held one is closed, noted, and skipped (`_skip`).
    local function decline(why, advice)
        if wait.observed then
            self._retire = nil
            self:_stop_timer("_retire_timer")
            return self:_note_incompatible(wait, "observing it without retiring it (" .. why .. "); " .. advice)
        end
        self:_drop_retire()
        return self:_skip(target, R.note(ch, inc, binary, "not observing it (" .. why .. "); " .. advice
            .. " — running in-process"))
    end
    -- The editor retires a daemon only over a relay connection
    -- (`welcome.via = "relay"`, §19.16 "Through the relay"); a `welcome`
    -- without `via` (an older pin's attached `--stdio`) is never weighed —
    -- this only guards that rule.
    if not (type(conn.welcome) == "table" and conn.welcome.via == "relay") then
        return decline("not connected through the relay", "update the pin or the plugin")
    end
    -- The selection: the same as a launch would make (over cached verdicts).
    local binsel = require("loomworks.provision.select")
    local resolve = self.opts.resolve or binsel.resolve
    local _, _, sel = resolve(self.root, { getenv = self.opts.getenv, setting = self.opts.binary,
        probe = self.opts.probe_cached, data = self.opts.data })
    local b = R.selected(sel, { wanted = self.opts.wanted, setting = self.opts.binary })
    if b.pending and not wait.probed then
        -- A PATH or explicit lw with no verdict yet: probe it first
        -- (bounded, asynchronous), then weigh again over the cached verdict.
        wait.probed = true
        local what = "checking " .. b.pending .. " (lw version --json) before retiring an incompatible "
            .. "workspace daemon"
        if wait.observed then
            self:_note_incompatible(wait, what)
        else
            self:_set("probing", what)
        end
        local probe = require("loomworks.provision.probe")
        local run = self.opts.run_probe or probe.run
        local done = false
        local t = uv.new_timer()
        local function again()
            if done then return end
            done = true
            pcall(function() t:stop(); if not t:is_closing() then t:close() end end)
            if self.state == "stopped" or self._retire ~= wait or wait.conn.closed then return end
            self:_weigh_retire(target, conn, ch, inc, true)
        end
        t:start(self.opts.probe_backstop_ms or (probe.TIMEOUT_MS + 2000), 0, vim.schedule_wrap(again))
        run(b.pending, {}, function() vim.schedule(again) end)
        return
    end
    if not b.ok then
        return decline("the selected lw cannot replace it: " .. tostring(b.why or "not probed"),
            "update the plugin, or pin or install a matching lw")
    end
    if R.same_version(b.version, ch.lw_version) then
        return decline("the selected lw is the same version", "update the plugin, or pin or install a matching lw")
    end
    if R.retire_failed(self.root, ch.lw_version) then
        -- Tried once this session and it failed (an error reply, or none):
        -- never tried again.
        return decline("retiring a daemon of lw v" .. tostring(ch.lw_version) .. " failed earlier this session",
            "stop it (lw daemon stop) or update the plugin, or pin or install a matching lw")
    end
    if R.was_retired(self.root, ch.lw_version) then
        return decline("the daemon runs lw v" .. tostring(ch.lw_version)
            .. " again after it was retired, likely a repository pin", "update the pin or the plugin")
    end
    if conn.welcome and conn.welcome.retiring then
        -- Already retiring (another client asked): follow it to its
        -- successor through an ordinary relay (§19.16 "Retiring").
        self:_drop_retire()
        return self:_after_retire(R.note(ch, inc, binary, "it is retiring"))
    end
    wait.version = b.version
    self:_check_retire()
end

--- Note an observed incompatible daemon (older schemas) on the connected
--- Runtime line: why it is incompatible and `tail`, what the editor does.
--- @param wait loomworks.daemon.RetireWait
--- @param tail string
function Observer:_note_incompatible(wait, tail)
    if self.conn ~= wait.conn then return end
    self.incompat_note = require("loomworks.daemon.editor_retire").note(wait.ch, wait.inc, nil, tail)
    self:_connected_note()
end

--- Ask the incompatible daemon's `status`: retire it when idle, else note
--- it and ask again in `retire_check_ms` (spec §19.16: "incompatible daemon
--- is busy; retiring when idle"). A `status` still unanswered at the next
--- tick ends the wait (`_retire_unanswered`): no second one is sent.
function Observer:_check_retire()
    local wait = self._retire
    if not wait or wait.retiring or self.state == "stopped" then return end
    local R = require("loomworks.daemon.editor_retire")
    local binary = wait.target.exe or self._binary
    if wait.asking then return self:_retire_unanswered(wait, "status") end
    -- Asked again in `retire_check_ms`; a status unanswered by then ends the
    -- wait (the tick lands on the `asking` check above).
    self:_stop_timer("_retire_timer")
    local t = uv.new_timer()
    self._retire_timer = t
    t:start(self.retire_check_ms, 0, vim.schedule_wrap(function()
        if self._retire_timer ~= t then return end
        self:_stop_timer("_retire_timer")
        if self._retire == wait then self:_check_retire() end
    end))
    wait.asking = true
    wait.conn:request({ kind = "status" }, function(st)
        vim.schedule(function()
            wait.asking = nil
            if self._retire ~= wait or wait.retiring or self.state == "stopped" then return end
            if type(st) == "table" and st.retiring then
                self:_drop_retire()
                if wait.observed then
                    -- Closed as the "Retiring" path of `_on_closed`.
                    self._retired_note = true
                    return wait.conn:close()
                end
                return self:_after_retire(R.note(wait.ch, wait.inc, binary, "it is retiring"))
            end
            if R.busy(st) then
                local tail = "incompatible daemon is busy; retiring when idle"
                if wait.observed then return self:_note_incompatible(wait, tail) end
                return self:_set("waiting", R.note(wait.ch, wait.inc, binary, tail))
            end
            self:_retire_now()
        end)
    end)
end

--- The incompatible daemon left its `status` unanswered for a whole
--- re-check tick (spec §19.16): stop waiting to retire it — neither retired
--- nor relaunched. A held connection is closed; an observed one stays
--- observed (its keepalive notices a daemon that is gone).
--- @param wait loomworks.daemon.RetireWait
--- @param what string the unanswered request
function Observer:_retire_unanswered(wait, what)
    local tail = "it stopped answering (no reply to " .. what .. " within " .. tostring(self.retire_check_ms)
        .. " ms)"
    if wait.observed then
        self._retire = nil
        self:_stop_timer("_retire_timer")
        return self:_note_incompatible(wait, "observing it without retiring it (" .. tail .. ")")
    end
    self:_drop_retire()
    return self:_skip(wait.target, require("loomworks.daemon.editor_retire").note(wait.ch, wait.inc,
        wait.target.exe or self._binary, "not observing it (" .. tail .. ") — running in-process"))
end

--- Retire the idle incompatible daemon: record the guard, send `retire`
--- (once), then — when the daemon accepted it or closed the connection —
--- disconnect and relaunch once when it has exited (the "Retiring" path,
--- §19.16), with one notice. An error reply, or no reply within
--- `retire_check_ms`, is a failure: noted on the Runtime line, no relaunch;
--- an observed daemon stays observed, a held one is closed. The guard stays
--- recorded either way, as failed (no loop; a later connection to that
--- version says retiring it failed).
function Observer:_retire_now()
    local wait = self._retire
    if not wait or wait.retiring then return end
    wait.retiring = true
    self:_stop_timer("_retire_timer")
    local R = require("loomworks.daemon.editor_retire")
    local ch, target = wait.ch, wait.target
    local binary = target.exe or self._binary
    R.record(self.root, ch.lw_version)
    local msg = string.format("retired the workspace daemon (lw v%s, pid %s), incompatible with this plugin (%s); "
        .. "starting lw v%s", tostring(ch.lw_version), tostring(target.pid), table.concat(wait.inc.reasons, "; "),
        tostring(wait.version))
    local closed_err = require("loomworks.daemon.client").ERR_CLOSED
    -- Not retired: no relaunch, no notice.
    local function failed(why)
        R.record_failed(self.root, ch.lw_version)
        local tail = "retiring it failed (" .. why .. ")"
        if wait.observed and self.conn == wait.conn then
            return self:_note_incompatible(wait, "observing it; " .. tail)
        end
        if not wait.conn.closed then
            wait.conn.on_close = nil
            pcall(wait.conn.close, wait.conn)
        end
        return self:_skip(target, R.note(ch, wait.inc, binary, "not observing it; " .. tail
            .. " — running in-process"))
    end
    -- No reply within a re-check tick: a failure (a late reply is ignored).
    local t = uv.new_timer()
    self._retire_timer = t
    t:start(self.retire_check_ms, 0, vim.schedule_wrap(function()
        if self._retire_timer ~= t then return end
        self:_stop_timer("_retire_timer")
        if self._retire ~= wait or wait.settled then return end
        wait.settled = true
        self._retire = nil
        if self.state == "stopped" then return end
        failed("no reply to retire within " .. tostring(self.retire_check_ms) .. " ms")
    end))
    wait.conn:request({ kind = "retire" }, function(reply, err)
        vim.schedule(function()
            if wait.settled then return end
            wait.settled = true
            if self._retire == wait then
                self._retire = nil
                self:_stop_timer("_retire_timer")
            end
            if self.state == "stopped" then return end
            if reply == nil and err ~= nil and err ~= closed_err then
                -- Refused: not retired.
                return failed(tostring(err))
            end
            -- Retired (it accepted, or closed the connection on its way out).
            self.retired_note = msg
            pcall(self.opts.notify or vim.notify, "loomworks: " .. msg, vim.log.levels.INFO)
            if wait.observed then
                -- Its close (ours here, or the daemon's) is the "Retiring"
                -- path of `_on_closed`, which also ends its tasks.
                if self.conn == wait.conn then
                    self._retired_note = true
                    wait.conn:close()
                elseif self.conn == nil and not self._relay then
                    -- Already closed, without the daemon's `retiring`.
                    self:_after_retire("the workspace daemon is retiring")
                end
                return
            end
            if not wait.conn.closed then
                wait.conn.on_close = nil
                pcall(wait.conn.close, wait.conn)
            end
            self:_after_retire("the workspace daemon is retiring")
        end)
    end)
end

--- Forget the incompatible daemon being weighed: stop its re-check and
--- close a held connection (an observed one stays: it is `self.conn`, closed
--- only through the usual paths).
function Observer:_drop_retire()
    local wait = self._retire
    self._retire = nil
    self:_stop_timer("_retire_timer")
    if wait and not wait.observed and wait.conn and not wait.conn.closed then
        wait.conn.on_close = nil
        pcall(wait.conn.close, wait.conn)
    end
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
    if self.incompat_note then note = note .. " — " .. self.incompat_note end
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
--- (loomworks.Tasks/1), `/workspace` (loomworks.Workspace/1) and the views
--- on `/views` (loomworks.view.Header/1, loomworks.view.ProjectsIndex/1,
--- step 5j) when it offers them — it sends such a connection only what it subscribed to; a
--- missing or refused one is a per-feature note, never a failed connection.
--- Any other daemon is observed through the protocol-10 broadcasts (`mode`
--- "v0").
--- @param conn loomworks.daemon.Conn
--- @param done fun()
function Observer:_subscribe(conn, done)
    self._feat, self._why, self._sub_only = {}, {}, nil
    self._view_seq = nil
    self:_clear_views()
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
                { object = want.object, iface = want.iface, v = want.v }, function(result, err)
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
                            if want.view then self:_view_subscribed(want, result) end
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
            if want.object == p then
                self._feat[want.feature] = nil
                if want.view then self:_clear_views(want.view) end
            end
        end
    end
    self:_describe(conn, function(objects, delivery)
        if self.state == "stopped" or self.conn ~= conn or not self._feat then return end
        if objects then self:_set_delivery(delivery) end
        objects = objects or {}
        self:_ensure_subscriptions(conn, objects, function() self:_connected_note() end)
    end)
end

--- A view subscription succeeded (§19.13 "Views"): its `seq` baseline and
--- its `initial` full state go to the view store.
--- @param want table M.VIEW_HEADER or M.VIEW_PROJECTS
--- @param result table|nil the subscribe result `{ sub_id, seq, initial? }`
function Observer:_view_subscribed(want, result)
    if type(result) ~= "table" then return end
    local seq = tonumber(result.seq)
    -- Both views share the `/views` object's `seq` (counted per object and
    -- connection, §19.12): the baseline is the highest one seen.
    if seq and seq > (self._view_seq or 0) then self._view_seq = seq end
    if type(result.initial) == "table" then
        self:_set_view(want.view, result.initial)
    end
end

--- A view's `update` (§19.13 "Views"): the full state replaces the store's
--- table. A `seq` gap means a lost signal: every subscribed view is fetched
--- again with `get`.
--- @param want table M.VIEW_HEADER or M.VIEW_PROJECTS
--- @param msg table the signal frame
function Observer:_view_update(want, msg)
    local st = self._feat and self._feat[want.feature]
    if st ~= "subscribed" and st ~= "pending" then return end
    local seq = tonumber(msg.seq)
    local gap = seq ~= nil and self._view_seq ~= nil and seq > self._view_seq + 1
    if seq and seq > (self._view_seq or 0) then self._view_seq = seq end
    if type(msg.args) == "table" then
        self:_set_view(want.view, msg.args)
    end
    if gap then self:_refetch_views() end
end

--- Fetch every subscribed view again (`get`, its full state) after a gap.
function Observer:_refetch_views()
    local conn = self.conn
    if not conn or type(conn.call) ~= "function" then return end
    for _, want in ipairs(M.VIEWS) do
        if self._feat and self._feat[want.feature] == "subscribed" then
            conn:call(want.object, want.iface, want.v, "get", {}, function(state, err)
                vim.schedule(function()
                    if self.state == "stopped" or self.conn ~= conn or err or type(state) ~= "table" then return end
                    self:_set_view(want.view, state)
                end)
            end)
        end
    end
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
--- this observer, or its relay ended). After a retirement: one ordinary
--- relay, which waits the retiring daemon out and launches its successor;
--- after any other drop: one no-launch relay, which connects when a daemon
--- appears and never launches one, so `lw daemon stop` stays meaningful
--- (§19.16 "Following a stopped or retiring daemon").
function Observer:_on_closed(c)
    if c ~= self.conn then return end
    local d = self.daemon
    self.conn = nil
    self.daemon = nil
    self.mode = nil
    self.feature_note = nil
    self.incompat_note = nil
    self._feat, self._why, self._sub_only = nil, nil, nil
    self._view_seq = nil
    self:_clear_views()
    self:_stop_timer("_keepalive")
    -- An observed incompatible daemon weighed for a retirement: forget it
    -- (a retirement in flight still reports through its reply).
    if self._retire and self._retire.conn == c then self:_drop_retire() end
    self:_end_tasks("the workspace daemon disconnected")
    if self.state == "stopped" then return end
    if self._retired_note then
        self._retired_note = nil
        return self:_after_retire("the workspace daemon (pid " .. tostring(d and d.pid) .. ") is retiring")
    end
    if self._relay then return end
    self:_spawn({ form = "no-launch", prefix = "the workspace daemon disconnected" })
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
        elseif msg.name == "update" then
            for _, want in ipairs(M.VIEWS) do
                if msg.object == want.object and msg.iface == want.iface and msg.v == want.v then
                    return self:_view_update(want, msg)
                end
            end
        end
        return
    end
    if msg.kind == "model_change" then
        return self:_model_change(msg.seq, msg.session_generation)
    elseif msg.kind == "retiring" then
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
    -- The pre-launch probe's lasting note (step 5h.5: a skipped lw on PATH,
    -- an incompatible explicit one); a no-binary note already names it.
    if self.probe_note and self.state ~= "no-binary" then t = t .. " — " .. self.probe_note end
    -- The binary.channel check's note (step 5h.5).
    if self.channel_note then t = t .. " — " .. self.channel_note end
    if self.retired_note and self.state ~= "connected" then t = t .. " (" .. self.retired_note .. ")" end
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

--- Stop observing (workspace teardown): timers stop, the connection closes
--- and a relay still waiting is ended — both by closing the relay's standard
--- input, never a process-tree kill (client.relay) — and remote tasks are
--- cleared. The daemon keeps running (§19.11).
function Observer:stop()
    if self.state == "stopped" then return end
    self.state = "stopped"
    self._probe_token, self._probing = nil, nil
    self:_stop_timer("_probe_backstop")
    if self._downloading then self:_cancel_download("the workspace was unloaded") end
    self:_stop_timer("_keepalive")
    self:_stop_timer("_channel_timer")
    self:_end_relay()
    self._want = nil
    self:_drop_retire()
    local c = self.conn
    self.conn = nil
    if c then c.on_close = nil; c:close() end
    self._view_seq = nil
    self:_clear_views()
    self:_end_tasks("the workspace was unloaded", true)
    if self.ws and self.ws._daemon_observer == self then self.ws._daemon_observer = nil end
end

M.Observer = Observer
return M
