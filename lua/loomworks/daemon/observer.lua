--- loomworks/daemon/observer.lua — the editor as an OBSERVER of the workspace
--- daemon (spec §19.16, §19.19 step 4).
---
--- In `daemon` runtime mode every workspace the editor loads gets one
--- Observer (owned by the Workspace, `ws._daemon_observer`, stopped by
--- `Workspace:teardown`). From step 5k it also carries the editor's builds,
--- configures and module cleans as interface calls whose tasks the editor
--- owns (`start_owned`, `cancel_owned`; the routing is
--- loomworks.daemon.editor_ops); everything else stays in-process. It
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

--- The observer last attached, until it stops (`M.current`).
--- @type loomworks.daemon.Observer|nil
M._current = nil

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
--- The Runtime line's note while a lost connection keeps the workspace
--- unloaded (§19.16 "Unloaded on disconnect", spec/ui.md §1.1).
M.LOST_NOTE = "the workspace daemon disconnected — workspace unloaded, waiting for it"

--- @class loomworks.daemon.Observer
--- @field ws loomworks.Workspace
--- @field root string
--- @field state "idle"|"no-binary"|"probing"|"downloading"|"connecting"|"connected"|"waiting"|"stopped"
--- @field note string|nil the current Runtime note
--- @field conn loomworks.daemon.Conn|nil
--- @field daemon { pid: integer, start_time: string|nil, lw_version: string|nil, exe: string|nil }|nil the observed daemon (`exe`: the binary its handle names)
--- @field seq integer last model_change seq
--- @field mode "v0"|"interfaces"|nil how the connected daemon is observed: protocol-10 broadcasts, or subscriptions (step 5g.3)
--- @field runner_note string|nil the task runner cannot host daemon tasks (step 5k C1b, §19.16 "Tasks in the task runner")
--- @field feature_note string|nil the per-feature note of a missing or refused interface (§19.16 "Interface client")
--- @field _feat table<string, string>|nil per feature, on this connection: "pending", "subscribed", "refused" (retried once), "gave_up" or "missing" (offered at other versions only)
--- @field _why table<string, string>|nil per feature: why it is not subscribed (its note)
--- @field _sub_only boolean|nil the connected daemon delivers to a transport-11 connection only by subscription (its `describe` reports `delivery = "subscription"`, step 5g.3)
--- @field _view_seq integer|nil the last `seq` of the `/views` object seen on this connection (a gap re-fetches the views, step 5j)
--- @field generation any session generation of the observed daemon
--- @field _tasks table<integer, loomworks.RemoteTask> running remote tasks by daemon task id
--- @field _order integer[] task ids in start order
--- @field _owned table<any, loomworks.daemon.OwnedCall> the editor's own tasks by daemon task id, from the call's `accepted` until they end (step 5k)
--- @field _degraded table<string, boolean>|nil Build/1, Launch/1 and DebugConfig/1 methods this connection's daemon lacks (or a parameter of): their operations run in-process
--- @field _method_notes string[]|nil the Runtime-line notes of those methods
--- @field _debug_adapters { languages: table[]|nil }|nil `DebugConfig/1.adapters` as last read on this connection (step 5k C2; `languages` nil: that read failed or was declined)
--- @field _debug_fetch fun(records: table[]|nil)[]|nil an `adapters` read in flight: its waiters (with_debug_adapters)
--- @field _debug_again boolean|nil a model change arrived during that read: read again after it
--- @field _lsp_read { state: loomworks.LspConfigState|nil, reason: string|nil }|nil `LspConfig/1.get` as last read on this connection (step 5l C; `state` nil: that read failed or was declined, `reason` says how)
--- @field _lsp_fetch table|nil the `get` in flight: its token (a reply to an older read — before a reconnect, or `/lsp` removed and re-added — is ignored)
--- @field _lsp_again boolean|nil a `changed` arrived during that read: read again after it
--- @field _lsp_get_why string|nil why `LspConfig/1.get` is degraded on this connection (the daemon lacks it): the LSP note's reason
--- @field _lost boolean|nil a connection the editor held was lost: its workspace is unloaded until the daemon reports `loaded` again (§19.16 "Unloaded on disconnect"); kept across connections
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
-- `cancel` for the tasks the editor owns (step 5k, §19.15 "The editor as
-- owner"); `list` is declared with it (§19.16 "Interface client") — the
-- observer still joins late through `status` (§19.11).
M.TASKS = {
    object = "/tasks", iface = "loomworks.Tasks", v = 1, feature = "tasks",
    methods = { "cancel", "list" }, signals = {},
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
-- The editor's operations as calls (step 5k, §19.16 "Editor operations"):
-- builds, configures and module cleans of a profile or of configuration
-- units. Called, never subscribed to (`call_only`): the feature is
-- `available` when the daemon offers it at this version.
M.BUILD = {
    object = "/build", iface = "loomworks.Build", v = 1, feature = "operations",
    methods = { "build", "configure", "clean" }, signals = {}, call_only = true, tasks = true,
}
-- The preparation of the editor's run and debug launches (step 5k C2,
-- §19.16 "Editor operations"): task-streamed like M.BUILD; the editor then
-- starts the returned program itself.
M.LAUNCH = {
    object = "/launch", iface = "loomworks.Launch", v = 1, feature = "launch",
    methods = { "prepare_run", "prepare_debug" }, signals = {}, call_only = true, tasks = true,
}
-- The debug adapters section (step 5k C2, §19.20 `DebugConfig/1`): plain
-- calls, no task; re-read on `Workspace/1` `changed` (it has no signal).
M.DEBUG = {
    object = "/debug", iface = "loomworks.DebugConfig", v = 1, feature = "debug adapters",
    methods = { "adapters", "set_adapter" }, signals = {}, call_only = true,
}
-- What the language servers are configured with (step 5l, §19.16 "LSP
-- configuration", §19.20 `LspConfig/1`): subscribed to for its thin
-- `changed {seq}`; `get` is called with the editor's environment on each
-- `changed`, `Workspace/1` `changed` and (re)connect, and `set_option` writes
-- the status page's options. `callable`: its methods are called while
-- subscribed.
M.LSP = {
    object = "/lsp", iface = "loomworks.LspConfig", v = 1, feature = "lsp configuration",
    methods = { "get", "set_option" }, signals = { "changed" }, callable = true,
}
M.VIEWS = { M.VIEW_HEADER, M.VIEW_PROJECTS }
M.FEATURES = { M.TASKS, M.WORKSPACE, M.VIEW_HEADER, M.VIEW_PROJECTS, M.BUILD, M.LAUNCH, M.DEBUG, M.LSP }

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
---   environ     fun() → table<string, string> (vim.fn.environ: the environment a Build/1 call carries)
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
        _tasks = {}, _order = {}, _owned = {},
        keepalive_ms = opts.keepalive_ms or M.KEEPALIVE_MS,
        retire_check_ms = opts.retire_check_ms or M.RETIRE_CHECK_MS,
        channel_tick_ms = opts.channel_tick_ms or M.CHANNEL_TICK_MS,
    }, Observer)
    ws._daemon_observer = self
    M._current = self
    -- The domain objects' cleans ask it (step 5k; loomworks.daemon.editor_ops).
    ws._operation_router = require("loomworks.daemon.editor_ops").router
    if sel.warning then self.warning = sel.warning end
    self:start(false)
    return self
end

--- The observer of `ws`, if any.
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
function M.of(ws) return ws and ws._daemon_observer or nil end

--- The observer of the workspace the editor has loaded (the last attached,
--- until it stops), if any. The editor's operation routing asks the
--- observer of the operation's own workspace (`M.of`) instead
--- (loomworks.daemon.editor_ops, step 5k).
--- @return loomworks.daemon.Observer|nil
function M.current()
    local o = M._current
    if o and o.state ~= "stopped" then return o end
    return nil
end

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
    -- The daemon reports the workspace loaded: a lost connection's unload
    -- ends (§19.16 "Unloaded on disconnect").
    if name == "header" and type(state) == "table" and state.state == "loaded" then self:_daemon_loaded() end
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
    local moved = self.state ~= state
    self.state, self.note = state, note
    self:_emit("daemon_runtime_changed", self)
    -- A new state can move the LSP phase (no binary: unavailable;
    -- connecting or waiting: held).
    if moved then self:_lsp_changed() end
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
            -- `busy_clients` leaves out the asking connection (server
            -- busy_connections(except)), so on the observed connection the
            -- editor's own tasks reach R.busy only through the daemon-wide
            -- `busy` flag; owns_tasks keeps §19.16's "the editor's own
            -- connection included" explicit (D10), whatever the status says.
            if R.busy(st) or self:owns_tasks() then
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
            -- (The LSP configuration's own note says it: lsp_note.)
            if st ~= "subscribed" and st ~= "pending" and st ~= "available" and self._why[want.feature]
                and want ~= M.LSP then
                notes[#notes + 1] = self._why[want.feature]
            end
        end
    end
    -- A method an older daemon lacks (step 5k): its operations run in-process.
    for _, n in ipairs(self._method_notes or {}) do notes[#notes + 1] = n end
    -- The task runner cannot list daemon tasks (step 5k C1b, §19.16).
    if self.runner_note then notes[#notes + 1] = self.runner_note end
    self.feature_note = #notes > 0 and table.concat(notes, "; ") or nil
    local note = "observing the workspace daemon (pid " .. tostring(d.pid) .. ")"
    if self.feature_note then note = note .. " — " .. self.feature_note end
    if self.incompat_note then note = note .. " — " .. self.incompat_note end
    self:_set("connected", note)
    -- The LSP state's first read on this connection, once discovered (§19.16
    -- "LSP configuration"); a feature found missing makes it unavailable.
    if not self._lsp_read and not self._lsp_fetch and self:can_call("get") then
        self:_fetch_lsp()
    end
    self:_lsp_changed()
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
    self._degraded, self._method_notes, self._lsp_get_why = nil, nil, nil
    self._debug_adapters, self._debug_fetch, self._debug_again = nil, nil, nil
    self._lsp_read, self._lsp_fetch, self._lsp_again = nil, nil, nil
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
        elseif want.call_only then
            -- Called, not subscribed to (step 5k): offered at our version
            -- or not; missing, the operations run in-process.
            if vim.tbl_contains(offered, want.v) then
                self._feat[f], self._why[f] = "available", nil
            else
                self._feat[f] = #offered > 0 and "missing" or nil
                self._why[f] = M.feature_note(want, offered) .. " — running them in-process"
            end
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
                if want == M.LSP then
                    self._lsp_read, self._lsp_fetch, self._lsp_again = nil, nil, nil
                    self:_lsp_changed()
                end
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
--- objects; it becomes one task in the editor's task runner (§19.16 "Tasks
--- in the task runner", loomworks.daemon.task_runner). `runner`: the
--- task-runner task of an owned task's restart, which this task continues.
--- @param task loomworks.RemoteTask
--- @param runner? loomworks.daemon.RunnerStrategy
function Observer:_add(task, runner)
    self._tasks[task.id] = task
    self._order[#self._order + 1] = task.id
    table.sort(self._order, function(a, b)
        local ta, tb = self._tasks[a], self._tasks[b]
        if ta.start_time ~= tb.start_time then return ta.start_time < tb.start_time end
        return a < b
    end)
    task:attach_units()
    self:_emit("daemon_task_started", { task = task })
    local ok, err = pcall(require("loomworks.daemon.task_runner").add, self, task, runner)
    if not ok then vim.notify("loomworks: daemon task in the task runner: " .. tostring(err), vim.log.levels.WARN) end
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
    -- The workspace is unloaded until a reconnect's daemon reports it
    -- `loaded` (§19.16 "Unloaded on disconnect"): its remote tasks end
    -- below, the controlled language servers stop (the LSP layer, on the
    -- `lost` change) and their buffers are held.
    self._lost = true
    self._feat, self._why, self._sub_only = nil, nil, nil
    self._degraded, self._method_notes, self._lsp_get_why = nil, nil, nil
    self._debug_adapters, self._debug_fetch, self._debug_again = nil, nil, nil
    self._lsp_read, self._lsp_fetch, self._lsp_again = nil, nil, nil
    self._view_seq = nil
    self:_clear_views()
    self:_lsp_changed()
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
    self:_spawn({ form = "no-launch", prefix = M.LOST_NOTE })
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
        elseif msg.object == M.LSP.object and msg.iface == M.LSP.iface and msg.name == "changed" then
            -- Thin (§19.20): read the state again with the editor's environment.
            return self:_fetch_lsp()
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
    -- The debug adapters section re-reads DebugConfig/1 (no signal of its
    -- own, §19.20) once it has read it on this connection.
    if self._debug_adapters or self._debug_fetch then self:_refetch_debug_adapters() end
    -- The LSP state is read again on every `Workspace/1` `changed` (§19.20).
    if self._lsp_read or self._lsp_fetch then self:_fetch_lsp() end
    return self:_reload()
end

--- A task-stream event (spec §19.15).
function Observer:_on_task(msg)
    local id = msg.task_id
    if id == nil then return end
    local task = self._tasks[id]
    if msg.phase == "start" then
        if task then return end
        task = remote_task.new(self.ws, id, msg.meta, self:_clock())
        -- A task the editor started through a call (step 5k): its own, no
        -- origin marker, cancelled from the editor.
        local owned = self._owned[id]
        if owned then
            task.owned = true
            task.cancelling = owned.cancelling
            owned.task = task
        end
        return self:_add(task, owned and owned.runner)
    end
    if not task then
        -- An owned task that ended before its `start` arrived still ends its
        -- operation; any other one started before we connected: not shown.
        if msg.phase == "done" and self._owned[id] then
            self:_owned_ended(id, nil, nil, { exit_code = tonumber(msg.exit_code), error = msg.error },
                M.done_result(msg))
        end
        return
    end
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
        self:_owned_ended(id, task, nil, nil, M.done_result(msg))
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
            self:_owned_ended(id, task, reason)
        end
    end
    -- Owned tasks whose `start` never arrived end the same way.
    local left = {}
    for oid in pairs(self._owned) do left[#left + 1] = oid end
    for _, oid in ipairs(left) do self:_owned_ended(oid, nil, reason) end
end

-- ---------------------------------------------------------------------------
-- Operations as calls: the tasks the editor owns (step 5k, spec §19.15 "The
-- editor as owner", §19.16 "Editor operations")
-- ---------------------------------------------------------------------------

--- Transport error codes of a call after which nothing ran because the
--- daemon lacks the method or a parameter (§19.16 "Availability": the
--- feature is degraded, a Runtime-line note, the operation in-process).
M.DEGRADED_CODES = { unknown_object = true, unknown_interface = true, unknown_method = true,
    unsupported_version = true, invalid_args = true }
--- Codes after which nothing ran and the daemon declines this request
--- (§19.20 "The CLI's calls"): in-process, the reason as one notification.
M.DECLINED_CODES = { same_build_required = true, stopping = true, retiring = true }

--- The interface table of each method the editor calls (step 5k): the
--- feature that carries it, and whether it runs as a task (`tasks`: it needs
--- Tasks/1, to be cancelled).
local METHOD_IFACE = {
    build = M.BUILD, configure = M.BUILD, clean = M.BUILD,
    prepare_run = M.LAUNCH, prepare_debug = M.LAUNCH,
    adapters = M.DEBUG, set_adapter = M.DEBUG,
    get = M.LSP, set_option = M.LSP,
    cancel = M.TASKS,
}

--- The calls the editor makes (step 5k), each naming its method literally
--- (the guard checks them against the `methods` of M.BUILD, M.LAUNCH,
--- M.DEBUG and M.TASKS): `fn(conn, args, cb, env)`.
local CALLS = {
    build = function(conn, args, cb, env)
        conn:call(M.BUILD.object, M.BUILD.iface, M.BUILD.v, "build", args, cb, env)
    end,
    configure = function(conn, args, cb, env)
        conn:call(M.BUILD.object, M.BUILD.iface, M.BUILD.v, "configure", args, cb, env)
    end,
    clean = function(conn, args, cb, env)
        conn:call(M.BUILD.object, M.BUILD.iface, M.BUILD.v, "clean", args, cb, env)
    end,
    prepare_run = function(conn, args, cb, env)
        conn:call(M.LAUNCH.object, M.LAUNCH.iface, M.LAUNCH.v, "prepare_run", args, cb, env)
    end,
    prepare_debug = function(conn, args, cb, env)
        conn:call(M.LAUNCH.object, M.LAUNCH.iface, M.LAUNCH.v, "prepare_debug", args, cb, env)
    end,
    adapters = function(conn, args, cb, env)
        conn:call(M.DEBUG.object, M.DEBUG.iface, M.DEBUG.v, "adapters", args, cb, env)
    end,
    set_adapter = function(conn, args, cb, env)
        conn:call(M.DEBUG.object, M.DEBUG.iface, M.DEBUG.v, "set_adapter", args, cb, env)
    end,
    get = function(conn, args, cb, env)
        conn:call(M.LSP.object, M.LSP.iface, M.LSP.v, "get", args, cb, env)
    end,
    set_option = function(conn, args, cb, env)
        conn:call(M.LSP.object, M.LSP.iface, M.LSP.v, "set_option", args, cb, env)
    end,
    cancel = function(conn, args, cb, env)
        conn:call(M.TASKS.object, M.TASKS.iface, M.TASKS.v, "cancel", args, cb, env)
    end,
}

--- An interface call of CALLS on the observed connection; every call but
--- Tasks/1.cancel carries the editor process's whole environment at call
--- time (§19.16 "Editor operations"; their schemas' `needs_env`).
--- `cb(result, err)` runs in the connection's callback (libuv): it only
--- schedules.
--- @param name "build"|"configure"|"clean"|"prepare_run"|"prepare_debug"|"adapters"|"set_adapter"|"get"|"set_option"|"cancel"
--- @param args table
--- @param cb fun(result: any, err: table|nil)
function Observer:_icall(name, args, cb)
    local conn = self.conn
    local send = CALLS[name]
    if not send then return cb(nil, { code = "unknown_method", message = tostring(name) }) end
    if not conn or conn.closed or type(conn.call) ~= "function" then
        return cb(nil, { code = "closed", message = "not connected" })
    end
    local env = nil
    if name ~= "cancel" then env = (self.opts.environ or vim.fn.environ)() end
    send(conn, args, cb, env)
end

--- Can the editor carry `method` now (§19.16 "Availability")? Connected
--- through interfaces to a compatible daemon (never one it weighs for a
--- retirement: older schemas are only observed), offering the method's
--- interface (Build/1, Launch/1, DebugConfig/1) at our version, or
--- subscribed to it (LspConfig/1, `callable`) — and, for a method that runs
--- as a task, Tasks/1 (cancel) — and the method not found missing on this
--- connection.
--- @param method string
--- @return boolean
function Observer:can_call(method)
    if self.state ~= "connected" or not self.conn or self.conn.closed then return false end
    if self.mode ~= "interfaces" or not self._feat then return false end
    if self.incompat_note or self._retire then return false end
    local want = METHOD_IFACE[method]
    if not want then return false end
    local st = self._feat[want.feature]
    if want.call_only then
        if st ~= "available" then return false end
    elseif not (want.callable and st == "subscribed") then
        return false
    end
    if want.tasks and self._feat[M.TASKS.feature] ~= "subscribed" then return false end
    return not (self._degraded and self._degraded[method])
end

--- Note a method the daemon lacks (or a parameter of it): its operations
--- run in-process from now on, on this connection (§19.16 "Availability").
--- @param method string
--- @param err table the call's error
function Observer:_degrade(method, err)
    self._degraded = self._degraded or {}
    if self._degraded[method] then return end
    self._degraded[method] = true
    local want = METHOD_IFACE[method] or M.BUILD
    -- The LSP configuration never runs in-process (§19.16 "LSP
    -- configuration"): a missing `get` makes it unavailable (lsp_note says
    -- why), a missing `set_option` makes an option write an error.
    if want == M.LSP then
        if method == "get" then
            self._lsp_get_why = string.format("daemon offers no %s/%d.%s (%s)", want.iface, want.v, method,
                tostring(err and (err.message or err.code) or "?"))
        end
        return self:_lsp_changed()
    end
    self._method_notes = self._method_notes or {}
    self._method_notes[#self._method_notes + 1] = string.format(
        "%s: daemon offers no %s/%d.%s (%s) — running them in-process", want.feature, want.iface,
        want.v, method, tostring(err and (err.message or err.code) or "?"))
    self:_connected_note()
end

--- @class loomworks.daemon.OwnedCall
--- @field method string the Build/1 method
--- @field args table the call's arguments (an overseer restart sends them again, step 5k C1b)
--- @field runner loomworks.daemon.RunnerStrategy|nil the task-runner task of a restart, which its task continues
--- @field cancelling boolean|nil the editor asked to cancel it
--- @field units loomworks.ConfigUnit[]|nil the call's units, before its `start` names them
--- @field task loomworks.RemoteTask|nil once its `start` arrived
--- @field on_done fun(task: loomworks.RemoteTask|nil, reason: string|nil, done: table|nil)
--- @field waiters fun()[] called once it ended (a cancel waiting for it)

--- Start an operation as a call the editor owns (§19.15 "The editor as
--- owner"). `h.on_reply(r)` runs once on the main loop with one of
---   { outcome = "accepted", task_id }  its task runs; `h.on_done(task,
---                                      reason, done)` follows when it ends
---                                      (its `done`, whose task result is
---                                      `done`, or the connection lost:
---                                      `reason`);
---   { outcome = "refused", message }   fails as in-process would;
---   { outcome = "declined", reason }   nothing ran: run it in-process;
---   { outcome = "degraded", reason }   nothing ran (the daemon lacks the
---                                      method or a parameter): noted, run
---                                      it in-process;
---   { outcome = "failed", reason }     it may have started (an internal
---                                      error, the connection lost before
---                                      the reply): never re-run.
--- @param method "build"|"configure"|"clean"|"prepare_run"|"prepare_debug"
--- @param args table the call's arguments (§19.15)
--- `h.units`: the call's configuration units (a clean pre-empts the task by
--- them before its `start` arrives).
--- `h.runner`: the task-runner task an overseer restart continues (step 5k
--- C1b): the task's `start` binds to it instead of a new one.
--- @param h { units?: loomworks.ConfigUnit[], runner?: loomworks.daemon.RunnerStrategy, on_reply: fun(r: table), on_done: fun(task: loomworks.RemoteTask|nil, reason: string|nil, done: table|nil) }
function Observer:start_owned(method, args, h)
    local conn = self.conn
    self:_icall(method, args, function(result, err)
        -- Registered here, in the reply's own callback, so the task's
        -- `start` frame (scheduled after this reply) finds it owned.
        local id = not err and type(result) == "table" and result.outcome == "accepted" and result.task_id or nil
        local registered = false
        if id ~= nil and self.conn == conn then
            self._owned[id] = { method = method, args = args, units = h.units, runner = h.runner,
                on_done = h.on_done, waiters = {} }
            registered = true
        end
        vim.schedule(function()
            if err then
                local code = type(err) == "table" and err.code or err
                local text = type(err) == "table" and (err.message or tostring(err.code)) or tostring(err)
                if M.DEGRADED_CODES[code] then
                    self:_degrade(method, type(err) == "table" and err or { code = code })
                    return h.on_reply({ outcome = "degraded", reason = text })
                elseif M.DECLINED_CODES[code] then
                    return h.on_reply({ outcome = "declined", reason = text })
                end
                if code == "closed" or code == "connect" or code == "timeout" then
                    text = "the workspace daemon disconnected"
                end
                return h.on_reply({ outcome = "failed", reason = text })
            end
            local r = type(result) == "table" and result or {}
            if r.outcome == "accepted" and id ~= nil then
                h.on_reply({ outcome = "accepted", task_id = id })
                if not registered then
                    -- Accepted on a connection already replaced: its task
                    -- ended with that connection, never seen here.
                    return h.on_done(nil, "the workspace daemon disconnected")
                end
                -- The connection dropped before this ran: it ended with it.
                if self.conn ~= conn and self._owned[id] then
                    self:_owned_ended(id, nil, "the workspace daemon disconnected")
                end
                return
            elseif r.outcome == "refused" then
                return h.on_reply({ outcome = "refused", message = tostring(r.message or "refused") })
            elseif r.outcome == "declined" then
                return h.on_reply({ outcome = "declined", reason = tostring(r.reason or "declined") })
            end
            h.on_reply({ outcome = "failed", reason = "unexpected reply from the workspace daemon ("
                .. tostring(r.outcome) .. ")" })
        end)
    end)
end

--- The task result of a `done` frame (§19.15 "Tasks of interface methods":
--- an interface method's task carries it as `result`, a protocol-10 task
--- the same fields on the frame itself): e.g. a preparation's `launch`,
--- `device` or `debug` (Launch/1).
--- @param msg table the `done` frame
--- @return table
function M.done_result(msg)
    return type(msg.result) == "table" and msg.result or msg
end

-- ---------------------------------------------------------------------------
-- The debug adapters section on DebugConfig/1 (step 5k C2, §19.16 "Editor
-- operations", §19.20 `DebugConfig/1`)
-- ---------------------------------------------------------------------------

--- Methods whose `invalid_args` judges the value the client sent, not the
--- daemon's version (§19.20 `LspConfig/1.set_option`: an unknown server or
--- key, or a value its option schema rejects): the call's own error, never a
--- degraded method.
M.VALUE_CHECKED = { set_option = true }

--- A plain interface call (no task) of a method `can_call` carries:
--- `cb(r)` once, on the main loop, with
---   { outcome = "ok", result }        the reply (a `refused` / `declined`
---                                     result as the daemon sent it)
---   { outcome = "invalid", reason }   `invalid_args` of a VALUE_CHECKED method
---   { outcome = "degraded", reason }  the daemon lacks the method (noted)
---   { outcome = "failed", reason }    any other error
--- @param method "adapters"|"set_adapter"|"get"|"set_option"
--- @param args table
--- @param cb fun(r: table)
function Observer:request(method, args, cb)
    self:_icall(method, args, function(result, err)
        vim.schedule(function()
            if err then
                local code = type(err) == "table" and err.code or err
                local text = type(err) == "table" and (err.message or tostring(err.code)) or tostring(err)
                if code == "invalid_args" and M.VALUE_CHECKED[method] then
                    return cb({ outcome = "invalid", reason = text })
                end
                if M.DEGRADED_CODES[code] then
                    self:_degrade(method, type(err) == "table" and err or { code = code })
                    return cb({ outcome = "degraded", reason = text })
                end
                if code == "closed" or code == "connect" or code == "timeout" then
                    text = "the workspace daemon disconnected"
                end
                return cb({ outcome = "failed", reason = text })
            end
            cb({ outcome = "ok", result = result })
        end)
    end)
end

--- The workspace's debug-adapter records as `DebugConfig/1.adapters` last
--- returned them (`{ language, adapter?, default?, known, overridden }[]`),
--- or nil: not carried, not read yet on this connection — a first read is
--- started then, and its records re-render the status page
--- (`daemon_debug_adapters`) — or the last read failed or was declined
--- (remembered until the next `Workspace/1` `changed` or a reconnect, so a
--- render does not send it again).
--- @return table[]|nil
function Observer:debug_adapters()
    if not self:can_call("adapters") then return nil end
    if self._debug_adapters then return self._debug_adapters.languages end
    self:_fetch_debug_adapters()
    return nil
end

--- `cb(records)` on the main loop with the records `debug_adapters` returns
--- once read: the cached read at once, else after the read in flight (or one
--- started now); nil when not carried, or the read failed, was declined or
--- outlived its connection.
--- @param cb fun(records: table[]|nil)
function Observer:with_debug_adapters(cb)
    if not self:can_call("adapters") then return cb(nil) end
    if self._debug_adapters then return cb(self._debug_adapters.languages) end
    self:_fetch_debug_adapters()
    if type(self._debug_fetch) ~= "table" then return cb(nil) end
    table.insert(self._debug_fetch, cb)
end

--- Read `DebugConfig/1.adapters` again (single flight; on connect through
--- `debug_adapters`, and on every `Workspace/1` `changed`, §19.20: it has no
--- signal of its own). `_debug_fetch` is the read in flight's waiters
--- (`with_debug_adapters`); a failed or declined read caches its absence
--- (`languages` nil).
function Observer:_fetch_debug_adapters()
    if self._debug_fetch or not self:can_call("adapters") then return end
    local conn = self.conn
    local waiters = {}
    self._debug_fetch = waiters
    local function flush(records)
        for _, w in ipairs(waiters) do
            local ok, e = pcall(w, records)
            if not ok then vim.notify("loomworks: " .. tostring(e), vim.log.levels.ERROR) end
        end
    end
    self:request("adapters", {}, function(r)
        if self.conn ~= conn then return flush(nil) end
        self._debug_fetch = nil
        local res = r.outcome == "ok" and type(r.result) == "table" and r.result or nil
        local records = res and type(res.languages) == "table" and res.languages or nil
        self._debug_adapters = { languages = records }
        -- A change while this read was in flight: read again; its waiters
        -- wait for that read (this one may predate the change).
        if self._debug_again then
            self._debug_again = nil
            self:_fetch_debug_adapters()
            if type(self._debug_fetch) == "table" then
                for _, w in ipairs(waiters) do table.insert(self._debug_fetch, w) end
                waiters = {}
            end
        end
        if records then self:_emit("daemon_debug_adapters", {}) end
        flush(records)
    end)
end

--- A model change: read the adapters again, after a read in flight.
function Observer:_refetch_debug_adapters()
    if self._debug_fetch then
        self._debug_again = true
        return
    end
    self:_fetch_debug_adapters()
end

-- ---------------------------------------------------------------------------
-- The LSP configuration on LspConfig/1 (step 5l C, §19.16 "LSP
-- configuration", §19.20 `LspConfig/1`)
-- ---------------------------------------------------------------------------

--- Read `LspConfig/1.get` (with the editor's environment, as every call) into
--- the per-connection cache (single flight: a `changed` during a read reads
--- once more after it). Each read carries a token: a reply to an older read
--- (before a reconnect, or `/lsp` removed and re-added on this connection)
--- is ignored. A failed or declined read is cached as absent (`state` nil,
--- with its reason) until the next `changed`, `Workspace/1` `changed` or
--- reconnect, and logged at debug level: the language servers are withheld
--- meanwhile, never configured in-process (§19.16 "LSP configuration").
function Observer:_fetch_lsp()
    if self._lsp_fetch then
        self._lsp_again = true
        return
    end
    if not self:can_call("get") then return end
    local conn = self.conn
    local token = {}
    self._lsp_fetch = token
    self:request("get", {}, function(r)
        if self.conn ~= conn or self.state == "stopped" or self._lsp_fetch ~= token then return end
        self._lsp_fetch = nil
        local res = r.outcome == "ok" and type(r.result) == "table" and r.result or nil
        local st = res and type(res.state) == "string" and type(res.projects) == "table" and res or nil
        local reason = nil
        if not st then
            if r.outcome ~= "ok" then
                reason = "LspConfig/1.get failed: " .. tostring(r.reason or r.outcome)
            elseif res and res.outcome == "declined" then
                reason = "LspConfig/1.get declined" .. (res.reason and (" (" .. tostring(res.reason) .. ")") or "")
            else
                reason = "LspConfig/1.get answered " .. tostring(res and (res.message or res.outcome) or "nothing usable")
            end
            self:_debug("lsp configuration: " .. reason .. " — language servers withheld until the next change")
        end
        self._lsp_read = { state = st, reason = reason }
        if st and st.state == "loaded" then self:_daemon_loaded() end
        if self._lsp_again then
            self._lsp_again = nil
            self:_fetch_lsp()
        end
        self:_lsp_changed()
    end)
end

--- A debug-log line (the editor's log, when it has one).
--- @param msg string
function Observer:_debug(msg)
    local core = self.ws and self.ws._core
    local log = core and core._deps and core._deps.log
    if log and log.debug then pcall(log.debug, log, "daemon: %s", msg) end
end

--- The daemon reports the workspace `loaded` (its header view, or an
--- `LspConfig/1` read): a lost connection's unload ends (§19.16 "Unloaded on
--- disconnect").
function Observer:_daemon_loaded()
    if not self._lost then return end
    self._lost = nil
    self:_emit("daemon_runtime_changed", self)
end

--- Whether the editor's workspace is unloaded in `daemon` mode (§19.13,
--- §19.16 "Unloaded on disconnect"): no connection yet or any more, a lost
--- connection the daemon has not reported `loaded` again since, or the
--- daemon reporting it `unloaded` (its header view, else its LSP state).
--- A run or debug launch is refused then (§19.16 "Editor operations").
--- @return boolean unloaded
--- @return string|nil why the status a refused launch names
function Observer:workspace_unloaded()
    if self.state == "stopped" then return false, nil end
    if self._lost then return true, M.LOST_NOTE end
    if self.state ~= "connected" or self.mode == nil then
        return true, "the editor is not connected to the workspace daemon yet"
    end
    local header = views.daemon_state(self, "header")
    local st = self._lsp_read and self._lsp_read.state
    local state = (type(header) == "table" and header.state) or (type(st) == "table" and st.state) or nil
    if state == "unloaded" then return true, "the workspace daemon has not loaded the workspace yet" end
    return false, nil
end

--- Why the LSP configuration cannot come from this connected daemon (§19.16
--- "LSP configuration" Unavailable), or nil (it can, or it is not settled
--- yet). `kind` "error" for a failed or refused load (§9.8
--- `withheld_error`), else "daemon" (`withheld_daemon`).
--- @return { kind: "error"|"daemon", note: string }|nil
function Observer:_lsp_unavailable()
    if self.mode ~= "interfaces" then
        return { kind = "daemon", note = "the workspace daemon offers no loomworks.LspConfig/1 (protocol 10)" }
    end
    if self.incompat_note or self._retire then
        return { kind = "daemon", note = "the workspace daemon is incompatible" }
    end
    local f = self._feat and self._feat[M.LSP.feature]
    if f == "pending" then return nil end
    if f ~= "subscribed" then
        local why = self._why and self._why[M.LSP.feature]
        -- Not settled yet (no note either): the describe is in flight.
        if f == nil and not why then return nil end
        why = why and (why:gsub("^lsp configuration: ", "")) or "daemon offers no loomworks.LspConfig/1"
        return { kind = "daemon", note = why }
    end
    if self._degraded and self._degraded.get then
        return { kind = "daemon", note = self._lsp_get_why or "daemon offers no loomworks.LspConfig/1.get" }
    end
    local read = self._lsp_read
    if not read then return nil end
    local st = read.state
    if not st then return { kind = "daemon", note = read.reason or "LspConfig/1.get failed" } end
    if st.state == "error" or st.state == "refused" then
        return { kind = "error", note = st.state == "refused" and "the workspace daemon's load of the workspace was refused"
            or "the workspace daemon's load of the workspace failed" }
    end
    return nil
end

--- Where the LSP configuration stands with this observer (§19.16 "LSP
--- configuration"):
---   "loaded"      in use: carried and the last read answered `loaded`;
---                 detail: the daemon's state
---   "waiting"     connecting, the first read not answered, the daemon's
---                 workspace `unloaded`, or unloaded by a lost connection:
---                 buffers held, no timeout; detail `{ why =
---                 "connecting"|"unloaded"|"disconnected" }`
---   "unavailable" no host binary, the interface not carried, a declined or
---                 failed read, a state `error` / `refused`: buffers withheld;
---                 detail `{ kind = "error"|"daemon", note }`
--- @return "loaded"|"waiting"|"unavailable" phase
--- @return table detail
function Observer:lsp_phase()
    if self.state == "no-binary" then
        return "unavailable", { kind = "daemon", note = "no lw host binary" }
    end
    local read = self._lsp_read
    local st = read and read.state
    if st and st.state == "loaded" and self:can_call("get") then return "loaded", st end
    if self.state == "connected" and self.mode ~= nil then
        local u = self:_lsp_unavailable()
        if u then return "unavailable", u end
        if not self._lost and st and st.state == "unloaded" then return "waiting", { why = "unloaded" } end
    end
    return "waiting", { why = self._lost and "disconnected" or "connecting" }
end

--- The Runtime line's note for the LSP configuration (spec/ui.md §1.1), nil
--- while the daemon's state is in use; `warn` for an unavailable one.
--- @return string|nil note
--- @return boolean warn
function Observer:lsp_note()
    local phase, d = self:lsp_phase()
    if phase == "loaded" then return nil, false end
    if phase == "waiting" then
        return "lsp configuration: waiting for the workspace daemon — language servers "
            .. (d.why == "disconnected" and "stopped, held" or "held"), false
    end
    return "lsp configuration: " .. d.note .. " — language servers withheld", true
end

--- The LSP state or where it stands may have changed: the LSP layer re-reads
--- its source (`daemon_lsp_config`).
function Observer:_lsp_changed()
    self:_emit("daemon_lsp_config", {})
end

--- An owned task ended (its `done`, or the connection lost): its operation
--- learns how, and a cancel waiting for it goes on.
--- @param id any the task id
--- @param task loomworks.RemoteTask|nil
--- @param reason string|nil why it ended without `done`
--- @param result? { exit_code: integer|nil, error: string|nil } its `done`, when no task was ever shown
--- @param done? table its `done`'s task result (M.done_result); nil when it ended without `done`
function Observer:_owned_ended(id, task, reason, result, done)
    local o = self._owned[id]
    if not o then return end
    self._owned[id] = nil
    -- An error in the operation's continuation (e.g. starting the program a
    -- preparation returned) is the user's to see, never dropped.
    if o.on_done then
        local ok, e = pcall(o.on_done, task or o.task or result, reason, done)
        if not ok then vim.notify("loomworks: " .. tostring(e), vim.log.levels.ERROR) end
    end
    for _, w in ipairs(o.waiters) do pcall(w) end
end

--- Does the editor own running tasks in the daemon (they keep it busy: it is
--- never retired under them, §19.19 5k C1)?
--- @return boolean
function Observer:owns_tasks()
    return next(self._owned) ~= nil
end

--- The running tasks the editor owns, in start order.
--- @return loomworks.RemoteTask[]
function Observer:owned_tasks()
    local out = {}
    for _, t in ipairs(self:tasks()) do
        if t.owned then out[#out + 1] = t end
    end
    return out
end

--- Cancel a task the editor owns (§19.15 "The editor as owner": always
--- `loomworks.Tasks/1.cancel`, graceful) and call `on_ended(true)` once it
--- has ended — its `done`, or the connection lost. Another client's task is
--- never cancelled: `on_ended(false, why)` at once.
--- @param task loomworks.RemoteTask
--- @param on_ended? fun(ok: boolean, why: string|nil)
function Observer:cancel_owned(task, on_ended)
    on_ended = on_ended or function() end
    if not (task and self._owned[task.id]) then
        local who = task and task.origin_label and task:origin_label()
        return on_ended(false, who and ("started by " .. who .. " — cancel it there") or "not running")
    end
    self:cancel_owned_id(task.id, on_ended)
end

--- The calls the editor owns that have not ended — accepted, their task
--- started (`task`) or not yet (`units`, the call's) — in no set order.
--- @return { id: any, task: loomworks.RemoteTask|nil, units: loomworks.ConfigUnit[]|nil }[]
function Observer:owned_calls()
    local out = {}
    for id, o in pairs(self._owned) do
        out[#out + 1] = { id = id, task = o.task, units = o.units }
    end
    return out
end

--- Cancel the editor's owned call `id` (accepted; its task started or not
--- yet), as `cancel_owned`. Not owned: `on_ended(false, "not running")`.
--- @param id any the daemon task id
--- @param on_ended? fun(ok: boolean, why: string|nil)
function Observer:cancel_owned_id(id, on_ended)
    on_ended = on_ended or function() end
    local o = self._owned[id]
    if not o then return on_ended(false, "not running") end
    local name = o.task and o.task.name or tostring(id)
    -- Its end is a cancellation the editor asked for (its task-runner task
    -- ends CANCELED, loomworks.daemon.task_runner).
    o.cancelling = true
    if o.task then o.task.cancelling = true end
    o.waiters[#o.waiters + 1] = function() on_ended(true) end
    self:_icall("cancel", { task_id = id }, function(_, err)
        if not err then return end
        vim.schedule(function()
            -- Ended meanwhile (`not_found`), or the connection is gone: its
            -- end (or the disconnect) completes the wait.
            local code = type(err) == "table" and err.code or err
            if code == "not_found" or code == "closed" then return end
            vim.notify("loomworks: could not cancel " .. tostring(name) .. ": "
                .. tostring(type(err) == "table" and (err.message or err.code) or err), vim.log.levels.WARN)
        end)
    end)
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
    -- A lost connection keeps the workspace unloaded until the daemon
    -- reports it `loaded` (§19.16 "Unloaded on disconnect"), reconnected too.
    if self._lost and not t:find(M.LOST_NOTE, 1, true) then t = t .. " — " .. M.LOST_NOTE end
    -- Where the language servers stand (§19.16 "LSP configuration").
    local lsp = self:lsp_note()
    if lsp then t = t .. " — " .. lsp end
    return t
end

--- The status page's Runtime line (spec/ui.md §1.1, core §19.1, §19.16): the
--- mode, the source that selected it and, in `daemon` mode, the observer's
--- state or note. nil when no mode was selected yet, or when the default
--- picked `in-process` with nothing to report. `warn` is true while a
--- `daemon`-mode observer is not connected (a version mismatch, no host
--- binary, waiting), while a lost connection keeps the workspace unloaded,
--- while the LSP configuration is unavailable, and for an ignored value or
--- unreadable settings file.
--- @param ws loomworks.Workspace|nil
--- @return string|nil text, boolean warn
function M.runtime_line(ws)
    local sel = ws and ws._runtime_selection
    if not sel then return nil, false end
    local head = sel.mode .. " (" .. sel.source .. ")"
    local obs = M.of(ws)
    if obs then
        local _, lsp_warn = obs:lsp_note()
        return head .. " — " .. obs:runtime_line(), obs.state ~= "connected" or obs._lost == true or lsp_warn
    end
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
    if M._current == self then M._current = nil end
    if self.ws and self.ws._operation_router then self.ws._operation_router = nil end
    self._lsp_read, self._lsp_fetch, self._lsp_again, self._lost = nil, nil, nil, nil
end

M.Observer = Observer
return M
