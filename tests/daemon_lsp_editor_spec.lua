-- The editor side of `loomworks.LspConfig/1` (step 5l part C; daemon.md
-- §19.16 "LSP configuration", §19.20 `LspConfig/1`; integrations.md §9.2,
-- §9.7, §9.8): the observer's per-connection read of the state, the LSP
-- source's two sources and the hold, the re-evaluation in loomworks.lsp,
-- `set_option` routing and the owned-database generation owner (D6).
--
-- Most cases drive a real loaded (shell) workspace with a fake connected
-- observer whose connection answers `get` / `set_option` as the test says;
-- one case runs the observer against an in-process server.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local source = require("loomworks.lsp_source")
local lsp = require("loomworks.lsp")
local events = require("loomworks.events")
local H = require("tests.daemon_helpers")

local LSP_FEATURE = observer.LSP.feature

describe("the editor's LspConfig/1 client (§19.16 LSP configuration)", function()
    local root, core, ws
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        source._reset_changes()
        lsp._reset_gate()
        lsp._reset_withheld()
    end)
    after_each(function()
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        if ws then ws._daemon_observer, ws._lsp_db_owner = nil, nil end
        lsp._reset_gate()
        lsp._gate_timeout_ms = nil
        pcall(function() core:shutdown() end)
    end)

    --- A connected observer of `ws` over a fake connection: `answer(method,
    --- args)` returns the reply (`result, err`) or nothing — then the test
    --- answers through `calls[i].cb` itself.
    local function fake_obs(answer)
        local calls = {}
        local conn = { closed = false }
        function conn:call(object, iface, v, method, args, cb, env)
            local c = { object = object, iface = iface, v = v, method = method, args = args, cb = cb, env = env }
            calls[#calls + 1] = c
            if answer then
                local r, e = answer(method, args)
                if r ~= nil or e ~= nil then cb(r, e) end
            end
        end
        function conn:close() self.closed = true end
        local obs = setmetatable({
            ws = ws, root = ws.root, state = "connected", mode = "interfaces", conn = conn,
            daemon = { pid = 1 }, seq = 0, _tasks = {}, _order = {}, _owned = {},
            _feat = { [LSP_FEATURE] = "subscribed" }, _why = {},
            opts = { environ = function() return { PATH = "/x" } end, resolve = function() return "lw" end,
                relay = function() return { close = function() end } end },
        }, observer.Observer)
        ws._daemon_observer = obs
        ws._lsp_db_owner = function() return obs:lsp_db_owner() end
        return obs, calls
    end

    --- A daemon state (`get`'s answer): one clangd-like entry of server
    --- `server` for the `app` project.
    local function dstate(o)
        o = o or {}
        local entry = vim.tbl_extend("force", {
            server = o.server or "clangd", root_dir = root .. "/app", db_state = "ready",
            db_dir = root .. "/out/Debug", db_rev = 0,
        }, o.entry or {})
        return {
            state = o.state or "loaded",
            ready = o.ready ~= false,
            projects = o.projects or { { project = "app", id = "p1", path = "app", entries = { entry } } },
            options = o.options or { clangd = ws:get_lsp_options("clangd") },
        }
    end

    local function wait_phase(phase)
        assert.is_true(vim.wait(3000, function() return (source.phase()) == phase end, 10),
            "phase " .. tostring((source.phase())) .. ", want " .. phase)
    end

    describe("reads and the source", function()
        it("in use: the daemon's state, read with the editor's environment", function()
            local obs, calls = fake_obs(function(m) if m == "get" then return dstate() end end)
            assert.is_nil(obs._lsp_read)
            obs:_fetch_lsp()
            wait_phase("loaded")
            assert.equals("/lsp", calls[1].object)
            assert.equals("loomworks.LspConfig", calls[1].iface)
            assert.equals("get", calls[1].method)
            assert.same({ PATH = "/x" }, calls[1].env)
            assert.is_true(source.in_use())
            assert.equals("p1", source.projects()[1].id)
            assert.equals("p1", source.state().projects[1].id)
            assert.is_true(source.loaded())
            assert.is_true(source.loaded_and_ready())
            assert.is_false(source.holding())
            assert.same(ws:get_lsp_options("clangd"), source.options("clangd"))
            -- D6: the daemon generates; the model does not.
            assert.equals("daemon", obs:lsp_db_owner())
            assert.is_false(ws:generates_lsp_databases())
        end)

        it("the buffer's project is lw.buf_project's record (§19.13), in use too", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate() end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/src/main.cpp")
            assert.equals("app", source.project_for_buf(buf).project)
            assert.equals("p1", source.project_for_buf(buf).id)
            -- Separator-bounded: a sibling directory sharing the prefix is not in it.
            local other = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(other, root .. "/appendix/x.cpp")
            assert.is_nil(source.project_for_buf(other))
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.api.nvim_buf_delete(other, { force = true })
        end)

        it("holds while connecting and while unloaded; the timeout goes in-process until loaded", function()
            local obs, calls = fake_obs()
            -- No connection yet: hold.
            obs.state = "connecting"
            assert.equals("connecting", (source.phase()))
            assert.is_true(source.holding())
            assert.is_false(source.loaded_and_ready())
            assert.is_true(source.pending())
            assert.equals("pending", obs:lsp_db_owner())
            -- The first read in flight: still holding.
            obs.state = "connected"
            obs:_fetch_lsp()
            assert.equals("connecting", (source.phase()))
            calls[1].cb(dstate({ state = "unloaded", ready = false, projects = {}, options = {} }))
            wait_phase("unloaded")
            assert.is_true(source.holding())
            assert.is_false(source.in_use())
            -- The §9.7 safety timeout: the in-process state from now on.
            source.hold_timed_out()
            assert.equals("inproc", (source.phase()))
            assert.is_false(source.holding())
            assert.equals("editor", obs:lsp_db_owner())
            assert.equals(require("loomworks").lsp_ready() == true, source.loaded_and_ready())
            -- Another `unloaded` read keeps it in-process; `loaded` ends it.
            obs:_on_message({ kind = "signal", object = "/lsp", iface = "loomworks.LspConfig", v = 1,
                name = "changed", args = { seq = 1 } })
            assert.equals(2, #calls)
            calls[2].cb(dstate({ state = "unloaded", ready = false, projects = {}, options = {} }))
            vim.wait(50)
            assert.equals("inproc", (source.phase()))
            obs:_on_message({ kind = "signal", object = "/lsp", iface = "loomworks.LspConfig", v = 1,
                name = "changed", args = { seq = 2 } })
            calls[3].cb(dstate())
            wait_phase("loaded")
            assert.is_true(source.in_use())
        end)

        it("loaded but not ready holds; the timeout resolves against the daemon's state", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate({ ready = false }) end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            assert.is_true(source.holding())
            assert.is_false(source.loaded_and_ready())
            source.hold_timed_out()
            assert.equals("loaded", (source.phase()))
            assert.is_true(source.in_use())
        end)

        it("a declined or failed read, or a refused/error state, is in-process until the next change", function()
            local reply = { nil, { code = "internal", message = "boom" } }
            local obs, calls = fake_obs(function(m) if m == "get" then return reply[1], reply[2] end end)
            obs:_fetch_lsp()
            wait_phase("declined")
            assert.is_false(source.in_use())
            assert.is_false(source.holding())
            assert.equals("editor", obs:lsp_db_owner())
            assert.is_nil(obs._degraded) -- not a missing method
            -- A `Workspace/1` `changed` reads again.
            reply = { dstate({ state = "refused", ready = false, projects = {}, options = {} }) }
            obs:_model_change(1, obs.generation)
            assert.is_true(vim.wait(3000, function() return #calls == 2 end, 10))
            wait_phase("declined")
            reply = { dstate() }
            obs:_model_change(2, obs.generation)
            wait_phase("loaded")
        end)

        it("a daemon without the method, or without the interface, is not carried", function()
            local obs = fake_obs(function(m) if m == "get" then return nil, { code = "unknown_method", message = "get" } end end)
            obs:_fetch_lsp()
            wait_phase("none")
            assert.is_true(obs._degraded.get)
            assert.is_false(obs:can_call("get"))
            -- Offered at another version only.
            obs._degraded = nil
            obs._lsp_read = nil
            obs._feat[LSP_FEATURE] = "missing"
            obs._why[LSP_FEATURE] = "lsp configuration: daemon offers loomworks.LspConfig/2, editor needs /1"
            assert.equals("none", (source.phase()))
            assert.is_false(obs:can_call("set_option"))
            -- The describe not answered yet (nothing settled): connecting.
            obs._feat[LSP_FEATURE], obs._why[LSP_FEATURE] = nil, nil
            assert.equals("connecting", (source.phase()))
        end)

        it("a lost connection is in-process at once, until a read after the reconnect answers loaded", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate() end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            local seen = 0
            on("daemon_lsp_config", function() seen = seen + 1 end)
            obs:_on_closed(obs.conn)
            assert.equals("inproc", (source.phase()))
            assert.is_false(source.in_use())
            assert.is_nil(obs._lsp_read)
            assert.is_true(seen >= 1)
            obs:stop()
        end)
    end)

    describe("re-evaluation in loomworks.lsp (§9.8)", function()
        local hits
        before_each(function()
            hits = { active = 0, options = {}, db = {} }
            lsp.register("fakesrv", {
                on_active_set_changed = function() hits.active = hits.active + 1 end,
                on_lsp_options_changed = function(p) hits.options[#hits.options + 1] = p end,
                on_owned_database_changed = function(dir) hits.db[#hits.db + 1] = dir end,
            })
        end)
        after_each(function() lsp.register("fakesrv", {}) end)

        it("a switch, changed entries, options and a raised db_rev each reach the integrations", function()
            local st = dstate({ server = "fakesrv", options = { clangd = ws:get_lsp_options("clangd"), fakesrv = { a = 1 } } })
            local obs = fake_obs(function(m) if m == "get" then return vim.deepcopy(st) end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            -- The switch to the daemon's state: an active-set change, and its
            -- options applied as an option change.
            assert.is_true(vim.wait(2000, function() return hits.active == 1 end, 10))
            assert.is_true(vim.wait(2000, function() return #hits.options == 1 end, 10))
            assert.same({ server = "fakesrv", key = "a", value = 1 }, hits.options[1])
            -- A database the daemon wrote (db_rev raised): the completion signal.
            st.projects[1].entries[1].db_rev = 1
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return #hits.db == 1 end, 10))
            assert.equals(root .. "/app", hits.db[1])
            assert.equals(1, hits.active)
            -- An option the daemon reports changed.
            st.options.fakesrv.a = 2
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return #hits.options == 2 end, 10))
            assert.same({ server = "fakesrv", key = "a", value = 2 }, hits.options[2])
            -- Changed entries.
            st.projects[1].entries[1].db_state = "unconfigured"
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return hits.active == 2 end, 10))
            -- An unchanged read changes nothing.
            obs:_fetch_lsp()
            vim.wait(100)
            assert.equals(2, hits.active)
            assert.equals(2, #hits.options)
            assert.equals(1, #hits.db)
        end)

        it("the hold is released on the daemon's ready, not on the model's lsp_ready", function()
            local obs, calls = fake_obs()
            obs:_fetch_lsp()
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
            local resolved = 0
            lsp.gated_root_dir(buf, function() end, function() resolved = resolved + 1 end)
            assert.equals(1, lsp._gate_queue_len())
            -- The model's own readiness does not release a hold for the daemon.
            events.emit("lsp_ready")
            assert.equals(1, lsp._gate_queue_len())
            -- Loaded, not ready: still held.
            calls[1].cb(dstate({ ready = false }))
            wait_phase("loaded")
            assert.equals(1, lsp._gate_queue_len())
            obs:_fetch_lsp()
            calls[2].cb(dstate())
            assert.is_true(vim.wait(2000, function() return resolved == 1 end, 10))
            assert.equals(0, lsp._gate_queue_len())
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("the safety timeout resolves a hold still connecting against the in-process state", function()
            local obs = fake_obs()
            obs.state = "connecting"
            lsp._gate_timeout_ms = 30
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
            local resolved = 0
            lsp.gated_root_dir(buf, function() end, function() resolved = resolved + 1 end)
            assert.equals(1, lsp._gate_queue_len())
            assert.is_true(vim.wait(2000, function() return resolved == 1 end, 10))
            assert.equals("inproc", (source.phase()))
            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)

    describe("options (D11)", function()
        local notes, saved_notify
        before_each(function()
            notes = {}
            saved_notify = vim.notify
            vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        end)
        after_each(function() vim.notify = saved_notify end)

        it("set_option goes through the daemon while carried, applied from the read back", function()
            local obs, calls = fake_obs(function(m)
                if m == "get" then return dstate() end
                if m == "set_option" then return { outcome = "ok" } end
            end)
            local wrote = false
            local orig = ws.set_lsp_option
            ws.set_lsp_option = function() wrote = true; return true end
            local done
            assert.is_true(require("loomworks").set_lsp_option("clangd", "clang_tidy", false,
                function(ok, err) done = { ok, err } end))
            assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
            ws.set_lsp_option = orig
            assert.same({ true }, done)
            assert.is_false(wrote)
            assert.equals("set_option", calls[1].method)
            assert.same({ server = "clangd", key = "clang_tidy", value = false }, calls[1].args)
            assert.is_true(vim.wait(2000, function() return #calls >= 2 and calls[2].method == "get" end, 10))
            assert.is_true(vim.wait(2000, function() return source.in_use() end, 10))
            assert.same({}, notes)
            local _ = obs
        end)

        it("invalid_args and a refused write are shown, nothing written in-process, not degraded", function()
            local reply
            local obs = fake_obs(function(m) if m == "set_option" then return reply[1], reply[2] end end)
            local ops = require("loomworks.daemon.editor_ops")
            local wrote = false
            local orig = ws.set_lsp_option
            ws.set_lsp_option = function() wrote = true; return true end
            reply = { nil, { code = "invalid_args", message = "set_option: unknown key nope" } }
            local done
            ops.set_lsp_option(ws, "clangd", "nope", 1, function(ok, err) done = { ok, err } end)
            assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
            assert.same({ false, "set_option: unknown key nope" }, done)
            assert.is_nil(obs._degraded)
            assert.is_true(obs:can_call("set_option"))
            assert.truthy(notes[1].msg:find("LSP option not saved: set_option: unknown key nope", 1, true))
            assert.equals(vim.log.levels.ERROR, notes[1].level)
            reply = { { outcome = "refused", message = "user.json changed on disk" } }
            done = nil
            ops.set_lsp_option(ws, "clangd", "clang_tidy", true, function(ok, err) done = { ok, err } end)
            assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
            assert.same({ false, "user.json changed on disk" }, done)
            assert.truthy(notes[2].msg:find("user.json changed on disk", 1, true))
            -- Declined: written in-process instead.
            reply = { { outcome = "declined", reason = "stopping" } }
            done = nil
            ops.set_lsp_option(ws, "clangd", "clang_tidy", true, function(ok, err) done = { ok, err } end)
            assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
            ws.set_lsp_option = orig
            assert.same({ true }, done)
            assert.is_true(wrote)
        end)

        it("not carried: written in-process", function()
            local obs = fake_obs()
            obs._feat[LSP_FEATURE] = "missing"
            obs._why[LSP_FEATURE] = "x"
            local args
            local orig = ws.set_lsp_option
            ws.set_lsp_option = function(_, s, k, v) args = { s, k, v }; return true end
            local ok = require("loomworks").set_lsp_option("clangd", "clang_tidy", true)
            ws.set_lsp_option = orig
            assert.is_true(ok)
            assert.same({ "clangd", "clang_tidy", true }, args)
        end)
    end)

    describe("owned databases (D6)", function()
        --- A unit whose module owns a database, recording each generation.
        local function unit_with_db(rec)
            return {
                _project = { _module = { impl = { refresh_lsp_database = function(_, done)
                    rec[#rec + 1] = true
                    if done then done(false) end
                end } } },
                build_dir = function() return root .. "/out/Debug" end,
                variant = function() return "Debug" end,
            }
        end

        it("the model generates nothing while the daemon's state is in use or awaited, and catches up after", function()
            local rec = {}
            local obs, calls = fake_obs()
            obs:_fetch_lsp()
            -- Awaited (the first read in flight): skipped.
            ws:_refresh_lsp_database_for(unit_with_db(rec))
            assert.same({}, rec)
            assert.is_true(ws._lsp_db_skipped)
            -- In use: skipped.
            calls[1].cb(dstate())
            wait_phase("loaded")
            ws:_refresh_lsp_database_for(unit_with_db(rec))
            assert.same({}, rec)
            -- A fallback: the model owns it again and runs the startup pass,
            -- reporting its own readiness once that settles.
            local pass = 0
            local orig = ws._refresh_lsp_databases_async
            ws._refresh_lsp_databases_async = function(_, mark) pass = pass + 1; mark() end
            ws._lsp_ready = false
            local ready = 0
            on("lsp_ready", function() ready = ready + 1 end)
            obs:_on_closed(obs.conn)
            ws._refresh_lsp_databases_async = orig
            assert.equals(1, pass)
            assert.is_true(ws._lsp_ready)
            assert.equals(1, ready)
            assert.is_nil(ws._lsp_db_skipped)
            -- In-process now: it generates.
            ws:_refresh_lsp_database_for(unit_with_db(rec))
            assert.equals(1, #rec)
            obs:stop()
        end)

        it("in-process mode (no observer) always generates", function()
            assert.is_nil(ws._lsp_db_owner)
            assert.is_true(ws:generates_lsp_databases())
            assert.is_nil(ws._lsp_db_skipped)
        end)
    end)
end)

describe("the observer subscribes to /lsp and reads it (in-process server)", function()
    local server_mod = require("loomworks.daemon.server")
    local client = require("loomworks.daemon.client")
    local FR = require("tests.daemon_fake_relay")
    client.TIMEOUT_MS = 30000
    local root, core, ws, srv, obs
    local STATE

    local function daemon_mode(name)
        if name == "LOOMWORKS_RUNTIME" then return "daemon" end
        if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
        return os.getenv(name)
    end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        source._reset_changes()
        STATE = { state = "loaded", ready = true, options = {},
            projects = { { project = "app", id = "p1", path = "app", entries = {
                { server = "clangd", root_dir = root .. "/app", db_state = "unconfigured", db_rev = 0 } } } } }
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
        local reg = srv:registry()
        assert(reg:mount("/workspace", "core", "loomworks.Workspace", 1, { methods = {
            header = function() return { root = srv.root, state = "loaded" } end,
        } }))
        assert(reg:mount("/lsp", "core", "loomworks.LspConfig", 1, { methods = {
            get = function() return vim.deepcopy(STATE) end,
            set_option = function() return { outcome = "ok" } end,
        } }))
    end)
    after_each(function()
        if obs then obs:stop() end
        obs = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() core:shutdown() end)
    end)

    it("reads the state once discovered, again on `changed`, and goes in-process when the daemon goes", function()
        local fr = FR.new({})
        obs = observer.attach(ws, { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(10000, function() return source.in_use() end, 10), obs:runtime_line())
        assert.equals("unconfigured", source.projects()[1].entries[1].db_state)
        STATE.projects[1].entries[1].db_state = "ready"
        srv:registry():emit("/lsp", "loomworks.LspConfig", 1, "changed", { seq = 1 })
        assert.is_true(vim.wait(5000, function()
            return source.in_use() and source.projects()[1].entries[1].db_state == "ready"
        end, 10))
        srv:stop("test end", 0)
        assert.is_true(vim.wait(5000, function() return (source.phase()) == "inproc" end, 10))
        assert.is_false(source.in_use())
    end)
end)
