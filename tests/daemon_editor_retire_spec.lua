-- The editor's retirement of an incompatible idle daemon (spec §19.16
-- "Retiring an incompatible daemon", §19.9 "Editor retirement", step 5h.5):
-- an idle incompatible daemon is retired once and the editor's selected
-- binary launches in its place; a busy one is retired only once it is idle;
-- a daemon with newer schemas, a compatible one (whatever its version), one
-- of the selected binary's own version, and any daemon while the selected
-- binary is not known compatible are never retired; and a daemon of a given
-- lw_version is retired at most once per workspace per editor session.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local version = require("loomworks.daemon.version")
local R = require("loomworks.daemon.editor_retire")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- The re-check tick for the tests against a real (in-process) daemon. It
--- also bounds a `status` reply (an unanswered status at the next tick ends
--- the wait, §19.16), and the daemon shares this test's event loop: a loop
--- stall longer than the tick (seen on Windows CI past 100 ms) reads as a
--- daemon that stopped answering. The fake-daemon tests keep 100 ms.
local REAL_RETIRE_CHECK_MS = 1000

local function older_schemas()
    local s = version.schemas()
    return { user = s.user - 1, cache = s.cache }
end

--- The editor's selection: the plugin-managed lw, whose pin names `v`.
local function managed_selection(v)
    return {
        resolve = function()
            return "/m/lw", "managed", { path = "/m/lw", source = "managed", label = "plugin-managed lw",
                candidates = { { source = "managed", verdict = "chosen", path = "/m/lw" } } }
        end,
        wanted = function() return { version = v, asset = "lw-test", sha256 = string.rep("a", 64) } end,
    }
end

describe("editor_retire (pure decisions, §19.16)", function()
    it("incompatible: no transport overlap, other schemas, no Root/1 on transport 11; newer schemas flagged", function()
        local s = version.schemas()
        assert.is_nil(R.incompatibility({ protocol = version.PROTOCOL, protocol_min = 10, schemas = s }, {}))
        local inc = assert(R.incompatibility({ protocol = 99, protocol_min = 99, schemas = s }, {}))
        assert.truthy(inc.reasons[1]:find("does not overlap", 1, true))
        assert.is_false(inc.newer)
        inc = assert(R.incompatibility({ protocol = version.PROTOCOL, schemas = older_schemas() }, {}))
        assert.is_false(inc.newer)
        inc = assert(R.incompatibility({ protocol = version.PROTOCOL, schemas = { user = s.user + 1, cache = s.cache } }, {}))
        assert.is_true(inc.newer)
        -- Transport 11 with objects but no root: incompatible; a missing
        -- feature interface alone is not.
        local ch = { protocol = version.PROTOCOL, protocol_min = 10, schemas = s }
        inc = assert(R.incompatibility(ch, { transport = 11, welcome = { objects = {} } }))
        assert.truthy(table.concat(inc.reasons, ";"):find("loomworks.Root/1", 1, true))
        assert.is_nil(R.incompatibility(ch, { transport = 11, welcome = { objects = {
            { path = "/", interfaces = { { name = "loomworks.Root", versions = { 1 } } } } } } }))
        -- Transport 10 (observed through broadcasts): no interfaces weighed.
        assert.is_nil(R.incompatibility(ch, { transport = 10, welcome = {} }))
    end)

    it("selected: the managed lw, or a PATH/explicit lw with a compatible verdict and a version", function()
        local sel = managed_selection("1.2.3")
        local _, _, s = sel.resolve()
        assert.same({ ok = true, path = "/m/lw", version = "1.2.3" }, R.selected(s, { wanted = sel.wanted }))
        local function explicit(probe)
            return { path = "/e/lw", source = "LOOMWORKS_LW", candidates = {
                { source = "LOOMWORKS_LW", verdict = "chosen", path = "/e/lw", probe = probe } } }
        end
        assert.is_true(R.selected(explicit({ verdict = "compatible", version = "2.0.0", problems = {}, degraded = {} })).ok)
        assert.is_false(R.selected(explicit({ verdict = "incompatible", problems = { "x" }, degraded = {} })).ok)
        assert.is_false(R.selected(explicit({ verdict = "unknown", problems = { "x" }, degraded = {} })).ok)
        assert.is_false(R.selected(nil).ok)
        local p = explicit(nil); p.probe = "/e/lw"
        assert.equals("/e/lw", R.selected(p).pending)
        assert.equals("3.0.0", R.selected({ download = { version = "3.0.0" }, candidates = {} }).version)
    end)

    it("busy without busy_clients: the editor (an observer) asking is not subtracted twice", function()
        local P = require("loomworks.daemon.protocol")
        -- The editor plus one CLI client, from a daemon before 5g.3.
        local st = { busy = false, clients = 2, observers = 1 }
        assert.is_true(R.busy(st))
        assert.is_true(P.status_busy(st, { asker_observer = true }))
        -- The editor alone is idle.
        assert.is_false(R.busy({ busy = false, clients = 1, observers = 1 }))
        -- The CLI's reconcile (asking as a client) keeps its rule: itself and
        -- the observing editor leave nobody.
        assert.is_false(P.status_busy(st))
        assert.is_true(P.status_busy({ busy = false, clients = 3, observers = 1 }))
        -- busy_clients, when reported, decides.
        assert.is_false(R.busy({ busy = false, busy_clients = 0, clients = 2, observers = 1 }))
    end)

    it("observable: only older schemas (transports overlap, root present)", function()
        local s = version.schemas()
        local older = { user = s.user - 1, cache = s.cache }
        assert.is_true(assert(R.incompatibility({ protocol = version.PROTOCOL, protocol_min = 10, schemas = older },
            { transport = 10, welcome = {} })).observable)
        assert.is_false(assert(R.incompatibility({ protocol = 99, protocol_min = 99, schemas = older }, {})).observable)
        assert.is_false(assert(R.incompatibility({ protocol = version.PROTOCOL, protocol_min = 10, schemas = older },
            { transport = 11, welcome = { objects = {} } })).observable)
        assert.is_false(assert(R.incompatibility({ protocol = version.PROTOCOL,
            schemas = { user = s.user + 1, cache = s.cache } }, {})).observable)
    end)

    it("the guard is per workspace and lw_version; a leading v is the same version", function()
        R.reset()
        R.record("/w/a", "v1.0.0")
        assert.is_true(R.was_retired("/w/a", "1.0.0"))
        assert.is_false(R.was_retired("/w/b", "1.0.0"))
        assert.is_false(R.was_retired("/w/a", "1.0.1"))
        R.reset()
        assert.is_false(R.was_retired("/w/a", "1.0.0"))
    end)
end)

describe("the observer retires an incompatible idle daemon (step 5h.5)", function()
    local root, core, ws, obs, s

    before_each(function()
        R.reset()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
    end)
    after_each(function()
        if obs then obs:stop() end
        obs = nil
        if s and not s.srv.stopped then s.srv:stop("test end", 0) end
        s = nil
        pcall(function() core:shutdown() end)
        R.reset()
    end)

    -- The observer over a fake relay (tests/daemon_fake_relay): it connects
    -- through `extra.connect` to what `extra.inspect` sees, waits out a
    -- retiring daemon, and an ordinary relay that finds none calls
    -- `extra.launch` (the successor's launch, the relay's own).
    local fr
    local function attach(extra)
        extra = extra or {}
        fr = FR.new({ inspect = extra.inspect, connect = extra.connect, launch = extra.launch })
        local o = { getenv = daemon_mode, keepalive_ms = 100, retire_check_ms = 100,
            resolve = function() return nil end, notify = function() end, relay = fr.relay }
        for k, v in pairs(extra) do
            if k ~= "connect" and k ~= "launch" then o[k] = v end
        end
        return observer.attach(ws, o)
    end

    --- A fake daemon world: `f.daemons` maps an endpoint to the challenge it
    --- presents, `f.st` is what inspect sees, `f.busy` its status; every
    --- request is recorded in `f.sent`. A retired daemon's `welcome` says
    --- `retiring` (the relay waits it out); the relay's launch (`f.spawned`)
    --- makes it `starting` (the test then makes `f.next` live).
    local function fake(extra)
        local f = { sent = {}, spawned = 0, connects = 0, notes = {}, busy = false }
        f.daemons = { old = { protocol = 99, protocol_min = 99, lw_version = "0.0.1", schemas = version.schemas() } }
        f.st = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "old" } }
        f.next = { kind = "live", handle = { pid = 5151, start_time = "n", endpoint = "new" } }
        f.daemons.new = { protocol = version.PROTOCOL, lw_version = "9.9.9", schemas = version.schemas() }
        f.opts = vim.tbl_extend("force", managed_selection("9.9.9"), {
            inspect = function() return f.st end,
            notify = function(m) f.notes[#f.notes + 1] = m end,
            launch = function() f.spawned = f.spawned + 1; f.st = { kind = "starting" } end,
            connect = function(ep, copts, cb)
                local retiring = f.retired and f.retired[ep] or nil
                local conn = { challenge = f.daemons[ep], welcome = { seq = 0, retiring = retiring }, ep = ep }
                if not retiring then
                    f.connects = f.connects + 1
                    f.conn, f.copts = conn, copts
                end
                function conn.close(c)
                    if c.closed then return end
                    c.closed = true
                    if c.on_close then c.on_close(c) end
                end
                function conn.request(c, msg, rcb)
                    f.sent[#f.sent + 1] = c.ep .. ":" .. msg.kind
                    if f.on_request and f.on_request(c, msg, rcb) then return end
                    if msg.kind == "status" then
                        rcb({ busy = f.busy, busy_clients = 0, clients = 1, observers = 1 })
                    elseif msg.kind == "retire" then
                        f.st = { kind = "live", handle = f.st.handle } -- still exiting
                        f.retired = f.retired or {}
                        f.retired[c.ep] = true
                        rcb({ ok = true })
                    else
                        rcb({})
                    end
                end
                conn.on_close = copts.on_close
                cb(conn)
            end })
        for k, v in pairs(extra or {}) do f.opts[k] = v end
        return f
    end

    local function sent(f, what)
        for _, x in ipairs(f.sent) do if x == what then return true end end
        return false
    end

    local function count(f, what)
        local n = 0
        for _, x in ipairs(f.sent) do if x == what then n = n + 1 end end
        return n
    end

    --- A remote task's `start` frame, delivered on the fake's connection.
    local function start_task(f, id)
        local profile = ws:get_profiles()[1]
        local pp = profile:projects()[1]
        f.copts.on_message({ kind = "task", phase = "start", task_id = id, meta = { name = "dev", kind = "build",
            profile = profile.key, origin = "cli",
            units = { { project = pp:project_key(), configuration = pp:config_key() } } } })
    end

    --- The fake's daemon presents older schemas only: observable.
    local function observable(f)
        f.daemons.old = { protocol = version.PROTOCOL, protocol_min = 10, lw_version = "0.0.1",
            schemas = older_schemas() }
        return f
    end

    it("(a) a real idle incompatible daemon is retired once; the selected binary then launches", function()
        s = { exited = nil }
        s.srv = server_mod.new(root, { exit = function(c) s.exited = c end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(s.srv:start())
        local spawned, notes = 0, {}
        local inspect = require("loomworks.daemon.inspect").state
        local opts = vim.tbl_extend("force", managed_selection("9.9.9"), {
            notify = function(m) notes[#notes + 1] = m end,
            -- The daemon presents older schemas (it cannot read the editor's
            -- files) and another lw_version.
            connect = function(ep, copts, cb)
                client.connect(ep, copts, function(c, e)
                    if c then
                        c.challenge = vim.tbl_extend("force", c.challenge,
                            { schemas = older_schemas(), lw_version = "0.0.1" })
                    end
                    cb(c, e)
                end)
            end,
            inspect = function(r)
                if s.exited == nil then return inspect(r) end
                return { kind = "none" }
            end,
            launch = function() spawned = spawned + 1 end,
            retire_check_ms = REAL_RETIRE_CHECK_MS,
        })
        obs = attach(opts)
        assert.is_true(vim.wait(10000, function() return s.exited ~= nil end, 10), obs:runtime_line())
        assert.is_true(s.srv.retiring)
        assert.is_true(vim.wait(5000, function() return spawned == 1 end, 10), obs:runtime_line())
        assert.equals(1, #notes)
        assert.truthy(notes[1]:find("retired the workspace daemon (lw v0.0.1", 1, true), notes[1])
        assert.truthy(notes[1]:find("starting lw v9.9.9", 1, true), notes[1])
        assert.truthy(obs:runtime_line():find("retired the workspace daemon", 1, true), obs:runtime_line())
        assert.is_true(R.was_retired(ws.root, "0.0.1"))
        vim.wait(300)
        assert.equals(1, spawned)
    end)

    it("(b) a real busy incompatible daemon is not retired until it is idle (re-checked)", function()
        s = { exited = nil }
        s.srv = server_mod.new(root, { exit = function(c) s.exited = c end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(s.srv:start())
        local cli = assert(client.session(s.srv.address))
        local busy
        for c in pairs(s.srv.conns) do
            if c.authed and not c.closed and not c.observer then busy = c end
        end
        busy.in_flight = { [999] = true }
        local statuses = 0
        obs = attach(vim.tbl_extend("force", managed_selection("9.9.9"), {
            connect = function(ep, copts, cb)
                client.connect(ep, copts, function(c, e)
                    if c then
                        c.challenge = vim.tbl_extend("force", c.challenge, { schemas = older_schemas(),
                            lw_version = "0.0.1" })
                        local request = c.request
                        c.request = function(cc, msg, rcb)
                            if msg.kind == "status" then statuses = statuses + 1 end
                            return request(cc, msg, rcb)
                        end
                    end
                    cb(c, e)
                end)
            end,
            retire_check_ms = REAL_RETIRE_CHECK_MS,
            launch = function() end }))
        assert.is_true(vim.wait(10000, function()
            return obs:runtime_line():find("incompatible daemon is busy; retiring when idle", 1, true) ~= nil
        end, 10), obs:runtime_line())
        -- Two more re-checks: still busy, never retired.
        local first = statuses
        assert.is_true(vim.wait(10 * REAL_RETIRE_CHECK_MS, function() return statuses >= first + 2 end, 10),
            obs:runtime_line())
        assert.truthy(obs:runtime_line():find("incompatible daemon is busy; retiring when idle", 1, true),
            obs:runtime_line())
        assert.is_false(s.srv.retiring)
        assert.is_false(R.was_retired(root, "0.0.1"))
        busy.in_flight = {}
        assert.is_true(vim.wait(10 * REAL_RETIRE_CHECK_MS, function() return s.srv.retiring end, 10),
            obs:runtime_line())
        cli:close()
        assert.is_true(vim.wait(5000, function() return s.exited ~= nil end, 10))
    end)

    it("(a') an idle incompatible daemon is retired, the successor launched once and observed", function()
        local f = fake()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        assert.is_true(sent(f, "old:status"))
        -- Followed through one ordinary relay, which waits the retired
        -- daemon out (its own wait) and then launches the successor.
        assert.is_true(vim.wait(5000, function() return #fr.spawns == 2 end, 10), obs:runtime_line())
        assert.same({ "ordinary", "ordinary" }, fr.spawns)
        assert.equals("connecting", obs.state)
        assert.equals(0, f.spawned) -- not while the retired daemon is still live
        f.st = { kind = "none" } -- it exited
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        f.st = f.next
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        assert.equals(5151, obs.daemon.pid)
        assert.is_nil(obs.retired_note)
        assert.equals(1, #f.notes)
        assert.equals(1, f.spawned)
    end)

    it("(b') a busy incompatible daemon is a note, re-checked, and retired once idle", function()
        local f = fake()
        f.busy = true
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("incompatible daemon is busy; retiring when idle", 1, true) ~= nil
        end, 10), obs:runtime_line())
        vim.wait(350)
        local checks = 0
        for _, x in ipairs(f.sent) do if x == "old:status" then checks = checks + 1 end end
        assert.is_true(checks >= 2, tostring(checks))
        assert.is_false(sent(f, "old:retire"))
        assert.equals(1, f.connects) -- one held connection, no reconnects
        f.busy = false
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
    end)

    it("(c) a daemon with newer schemas is never retired", function()
        local f = fake()
        local s0 = version.schemas()
        f.daemons.old = { protocol = version.PROTOCOL, lw_version = "99.0.0",
            schemas = { user = s0.user + 1, cache = s0.cache } }
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(300)
        assert.same({}, f.sent)
        assert.equals(0, f.spawned)
        assert.truthy(obs:runtime_line():find("not observing it", 1, true), obs:runtime_line())
    end)

    it("(c') a compatible daemon of another version is observed, never retired", function()
        local f = fake()
        f.daemons.old = { protocol = version.PROTOCOL, lw_version = "0.0.1", schemas = version.schemas() }
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "connected" end, 10), obs:runtime_line())
        vim.wait(200)
        assert.is_false(sent(f, "old:retire"))
    end)

    it("(c'') an incompatible daemon of the selected binary's own version is not retired", function()
        local f = fake()
        f.daemons.old.lw_version = "v9.9.9"
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(200)
        assert.same({}, f.sent)
        assert.truthy(obs:runtime_line():find("same version", 1, true), obs:runtime_line())
    end)

    it("(d) no retirement while the selected binary is incompatible or unknown", function()
        for _, verdict in ipairs({ "incompatible", "unknown" }) do
            local f = fake({ resolve = function()
                return "/e/lw", "LOOMWORKS_LW", { path = "/e/lw", source = "LOOMWORKS_LW", candidates = {
                    { source = "LOOMWORKS_LW", verdict = "chosen", path = "/e/lw",
                        probe = { verdict = verdict, problems = { "x" }, degraded = {}, version = "9.9.9" } } } }
            end })
            obs = attach(f.opts)
            assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
            vim.wait(200)
            assert.same({}, f.sent)
            assert.equals(0, f.spawned)
            assert.truthy(obs:runtime_line():find("cannot replace it", 1, true), obs:runtime_line())
            obs:stop(); obs = nil
        end
    end)

    it("(d') a selected lw not probed yet is probed first; compatible, the daemon is retired", function()
        local cache, probes = {}, 0
        local f = fake({
            probe_cached = function(p) return cache[p] end,
            run_probe = function(p, _, cb)
                probes = probes + 1
                cache[p] = { verdict = "compatible", problems = {}, degraded = {}, version = "9.9.9" }
                cb(cache[p])
            end,
            resolve = function(r, o)
                return require("loomworks.provision.select").resolve(r, vim.tbl_extend("force", o, { win = false,
                    getenv = function(n) return n == "LOOMWORKS_LW" and "/e/lw" or nil end,
                    exists = function() return true end,
                    on_path = function() return nil, "none" end,
                    managed = function() return nil, "none" end }))
            end })
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        assert.equals(1, probes)
    end)

    it("(e) a daemon of a version already retired this session is not retired again (a pin loop)", function()
        local f = fake()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        -- The successor runs the same incompatible version again (a
        -- repository pin redirects the launch to it).
        f.daemons.new = vim.deepcopy(f.daemons.old)
        f.st = f.next
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("again after it was retired", 1, true) ~= nil
        end, 10), obs:runtime_line())
        vim.wait(300)
        assert.is_false(sent(f, "new:retire"))
        assert.is_false(sent(f, "new:status"))
        assert.equals(1, f.spawned)
        assert.equals(1, #f.notes)
        -- A new observer (a workspace reload) in the same session: still once.
        obs:stop(); obs = nil
        local g = fake()
        obs = attach(g.opts)
        assert.is_true(vim.wait(5000, function() return obs.state == "waiting" end, 10), obs:runtime_line())
        vim.wait(200)
        assert.is_false(sent(g, "old:retire"))
    end)

    it("a stop while a busy daemon is held closes the held connection", function()
        local f = fake()
        f.busy = true
        local closed = false
        local connect = f.opts.connect
        f.opts.connect = function(ep, copts, cb)
            connect(ep, copts, function(c)
                local close = c.close
                c.close = function(x) closed = true; close(x) end
                cb(c)
            end)
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs._retire ~= nil and sent(f, "old:status") end, 10))
        obs:stop()
        assert.is_true(closed)
        assert.is_nil(obs._retire)
        assert.is_nil(obs._retire_timer)
        obs = nil
    end)

    it("an older-schema busy daemon is observed while its retirement is pending", function()
        local f = observable(fake())
        f.busy = true
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("incompatible daemon is busy; retiring when idle", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.equals("connected", obs.state)
        assert.equals(f.conn, obs.conn)
        assert.is_not_nil(obs._retire)
        -- Observed: its task frames count, and end when it is retired.
        start_task(f, 1)
        assert.is_true(vim.wait(2000, function() return #obs:tasks() == 1 end, 10))
        f.busy = false
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        assert.is_true(vim.wait(5000, function() return obs.conn == nil and #fr.spawns == 2 end, 10),
            obs:runtime_line())
        assert.equals("connecting", obs.state)
        assert.same({}, obs:tasks())
        assert.is_nil(obs._retire)
        assert.equals(1, #f.notes)
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
    end)

    it("an older-schema daemon the editor declines to retire stays observed", function()
        local f = observable(fake())
        f.daemons.old.lw_version = "9.9.9" -- the selected binary's own version
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("observing it without retiring it", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.equals("connected", obs.state)
        assert.is_nil(obs._retire)
        vim.wait(300)
        assert.is_false(sent(f, "old:retire"))
        assert.equals("connected", obs.state)
        assert.equals(1, f.connects)
    end)

    it("an observed daemon dropping mid-task while its retirement is pending leaves no running task", function()
        local f = observable(fake())
        f.busy = true
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs._retire ~= nil and obs.state == "connected" end, 10))
        start_task(f, 1)
        assert.is_true(vim.wait(2000, function() return #obs:tasks() == 1 end, 10))
        f.conn:close()
        assert.is_true(vim.wait(2000, function() return obs.conn == nil end, 10))
        assert.same({}, obs:tasks())
        assert.is_nil(obs._retire)
        assert.is_nil(obs._retire_timer)
    end)

    it("a held (unobserved) connection's task frames are ignored", function()
        local f = fake()
        f.busy = true
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return obs._retire ~= nil and sent(f, "old:status") end, 10))
        start_task(f, 1)
        vim.wait(200)
        assert.same({}, obs:tasks())
        assert.is_nil(obs.conn)
    end)

    it("no new status while one is unanswered; retire is sent, noticed and relaunched once", function()
        local f = fake()
        f.opts.retire_check_ms = 2000 -- answered within the tick
        local held
        f.on_request = function(_, msg, rcb)
            if msg.kind == "status" and not f.answer then held = rcb; return true end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return held ~= nil end, 10))
        vim.wait(300)
        assert.equals(1, count(f, "old:status"))
        f.answer = true
        local wait = obs._retire
        held({ busy = false, busy_clients = 0, clients = 1, observers = 1 })
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        -- Asked again (a late tick, a second idle reply): nothing more.
        obs._retire = wait
        obs:_retire_now()
        obs:_check_retire()
        obs._retire = nil
        vim.wait(200)
        assert.equals(1, count(f, "old:retire"))
        f.st = { kind = "none" }
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        vim.wait(300)
        assert.equals(1, f.spawned)
        assert.equals(1, #f.notes)
    end)

    it("an error reply to retire is a failure: noted, no notice, no relaunch", function()
        local f = fake()
        f.on_request = function(_, msg, rcb)
            if msg.kind == "retire" then rcb(nil, "retire refused: test"); return true end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("retiring it failed (retire refused: test)", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.is_true(f.conn.closed)
        assert.is_nil(obs._retire)
        f.st = { kind = "none" }
        vim.wait(300)
        assert.equals(0, f.spawned)
        assert.same({}, f.notes)
        assert.equals(1, count(f, "old:retire"))
        -- The guard still applies.
        assert.is_true(R.was_retired(ws.root, "0.0.1"))
    end)

    it("a status unanswered for a whole tick ends the wait on a held connection (no retire, no relaunch)", function()
        local f = fake()
        f.on_request = function(_, msg) return msg.kind == "status" end -- never answered
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("not observing it (it stopped answering (no reply to status", 1, true)
                ~= nil
        end, 10), obs:runtime_line())
        assert.equals("waiting", obs.state)
        assert.is_true(f.conn.closed)
        assert.is_nil(obs._retire)
        assert.is_nil(obs._retire_timer)
        vim.wait(300) -- no loop: not asked again, not reconnected
        assert.equals(1, count(f, "old:status"))
        assert.is_false(sent(f, "old:retire"))
        assert.equals(1, f.connects)
        assert.equals(0, f.spawned)
        assert.same({}, f.notes)
        assert.is_false(R.was_retired(ws.root, "0.0.1"))
    end)

    it("a status unanswered for a whole tick ends the wait on an observed connection, which stays observed", function()
        local f = observable(fake())
        f.on_request = function(_, msg) return msg.kind == "status" end -- never answered
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("observing it without retiring it (it stopped answering", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.equals("connected", obs.state)
        assert.equals(f.conn, obs.conn)
        assert.is_false(f.conn.closed == true)
        assert.is_nil(obs._retire)
        vim.wait(300)
        assert.equals(2, count(f, "old:status")) -- joining late, and the one retire check
        assert.is_false(sent(f, "old:retire"))
        assert.equals(1, f.connects)
        assert.same({}, f.notes)
    end)

    it("no reply to retire within a tick is a failure: noted, closed, no relaunch; a late reply is ignored", function()
        local f = fake()
        local late
        f.on_request = function(_, msg, rcb)
            if msg.kind == "retire" then late = rcb; return true end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("retiring it failed (no reply to retire", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.is_true(f.conn.closed)
        assert.is_nil(obs._retire)
        assert.is_true(R.retire_failed(ws.root, "0.0.1"))
        late({ ok = true })
        f.st = { kind = "none" }
        vim.wait(300)
        assert.equals(0, f.spawned)
        assert.same({}, f.notes)
        assert.equals(1, count(f, "old:retire"))
    end)

    it("after a failed retire, the same version again is declined as failed earlier (not as a pin)", function()
        local f = fake()
        f.on_request = function(_, msg, rcb)
            if msg.kind == "retire" then rcb(nil, "retire refused: test"); return true end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("retiring it failed (retire refused: test)", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.is_true(R.retire_failed(ws.root, "0.0.1"))
        -- A new observer (a workspace reload) meets the same daemon again.
        obs:stop(); obs = nil
        local g = fake()
        obs = attach(g.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("retiring a daemon of lw v0.0.1 failed earlier this session", 1, true)
                ~= nil
        end, 10), obs:runtime_line())
        assert.is_nil(obs:runtime_line():find("likely a repository pin", 1, true))
        vim.wait(200)
        assert.is_false(sent(g, "old:status"))
        assert.is_false(sent(g, "old:retire"))
        assert.equals(0, g.spawned)
    end)

    it("an error reply to retire leaves an observed daemon observed", function()
        local f = observable(fake())
        f.on_request = function(_, msg, rcb)
            if msg.kind == "retire" then rcb(nil, "nope"); return true end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("retiring it failed (nope)", 1, true) ~= nil
        end, 10), obs:runtime_line())
        assert.equals("connected", obs.state)
        assert.is_nil(obs._retire)
        vim.wait(300)
        assert.equals(1, count(f, "old:retire"))
        assert.same({}, f.notes)
    end)

    it("a connection closed before the retire reply counts as retired (relaunched once)", function()
        local f = fake()
        f.on_request = function(c, msg, rcb)
            if msg.kind == "retire" then
                f.st = { kind = "none" }
                c:close()
                rcb(nil, client.ERR_CLOSED)
                return true
            end
        end
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return f.spawned == 1 end, 10), obs:runtime_line())
        assert.equals(1, #f.notes)
        assert.truthy(obs:runtime_line():find("retired the workspace daemon", 1, true), obs:runtime_line())
    end)
end)
