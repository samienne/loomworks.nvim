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

client.TIMEOUT_MS = 30000
observer.CONNECT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

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

    local function attach(extra)
        local o = { getenv = daemon_mode, watch_ms = 50, keepalive_ms = 100, retire_check_ms = 100,
            resolve = function() return nil end, notify = function() end }
        for k, v in pairs(extra or {}) do o[k] = v end
        return observer.attach(ws, o)
    end

    --- A fake daemon world: `f.daemons` maps an endpoint to the challenge it
    --- presents, `f.st` is what inspect sees, `f.busy` its status; every
    --- request is recorded in `f.sent`. Launching makes `f.next` live.
    local function fake(extra)
        local f = { sent = {}, spawned = 0, connects = 0, notes = {}, busy = false }
        f.daemons = { old = { protocol = 99, protocol_min = 99, lw_version = "0.0.1", schemas = version.schemas() } }
        f.st = { kind = "live", handle = { pid = 4242, start_time = "t", endpoint = "old" } }
        f.next = { kind = "live", handle = { pid = 5151, start_time = "n", endpoint = "new" } }
        f.daemons.new = { protocol = version.PROTOCOL, lw_version = "9.9.9", schemas = version.schemas() }
        f.opts = vim.tbl_extend("force", managed_selection("9.9.9"), {
            inspect = function() return f.st end, check = function() return true end,
            notify = function(m) f.notes[#f.notes + 1] = m end,
            spawn = function() f.spawned = f.spawned + 1; f.st = { kind = "starting" }; f.child = { pid = 99 }
                return f.child end,
            connect = function(ep, copts, cb)
                f.connects = f.connects + 1
                local conn = { challenge = f.daemons[ep], welcome = { seq = 0 }, ep = ep }
                function conn.close(c)
                    if c.closed then return end
                    c.closed = true
                    if c.on_close then c.on_close(c) end
                end
                function conn.request(c, msg, rcb)
                    f.sent[#f.sent + 1] = c.ep .. ":" .. msg.kind
                    if msg.kind == "status" then
                        rcb({ busy = f.busy, busy_clients = 0, clients = 1, observers = 1 })
                    elseif msg.kind == "retire" then
                        f.st = { kind = "live", handle = f.st.handle } -- still exiting
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
            spawn = function() spawned = spawned + 1; return { pid = 99 } end,
        })
        obs = attach(opts)
        assert.is_true(vim.wait(10000, function() return s.exited ~= nil end, 10), obs:runtime_line())
        assert.is_true(s.srv.retiring)
        assert.is_true(vim.wait(5000, function() return spawned == 1 end, 10), obs:runtime_line())
        assert.equals(1, #notes)
        assert.truthy(notes[1]:find("retired the workspace daemon (lw v0.0.1", 1, true), notes[1])
        assert.truthy(notes[1]:find("starting lw v9.9.9", 1, true), notes[1])
        assert.truthy(obs:runtime_line():find("retired the workspace daemon", 1, true), obs:runtime_line())
        assert.is_true(R.was_retired(root, "0.0.1"))
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
        obs = attach(vim.tbl_extend("force", managed_selection("9.9.9"), {
            connect = function(ep, copts, cb)
                client.connect(ep, copts, function(c, e)
                    if c then c.challenge = vim.tbl_extend("force", c.challenge, { schemas = older_schemas(),
                        lw_version = "0.0.1" }) end
                    cb(c, e)
                end)
            end,
            spawn = function() return { pid = 99 } end }))
        assert.is_true(vim.wait(5000, function()
            return obs:runtime_line():find("incompatible daemon is busy; retiring when idle", 1, true) ~= nil
        end, 10), obs:runtime_line())
        vim.wait(400) -- several re-checks: still busy, never retired
        assert.is_false(s.srv.retiring)
        assert.is_false(R.was_retired(root, "0.0.1"))
        busy.in_flight = {}
        assert.is_true(vim.wait(5000, function() return s.srv.retiring end, 10), obs:runtime_line())
        cli:close()
        assert.is_true(vim.wait(5000, function() return s.exited ~= nil end, 10))
    end)

    it("(a') an idle incompatible daemon is retired, the successor launched once and observed", function()
        local f = fake()
        obs = attach(f.opts)
        assert.is_true(vim.wait(5000, function() return sent(f, "old:retire") end, 10), obs:runtime_line())
        assert.is_true(sent(f, "old:status"))
        assert.equals("waiting", obs.state)
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
end)
