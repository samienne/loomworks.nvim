-- The editor side of `loomworks.LspConfig/1` (step 5l part C; daemon.md
-- §19.16 "LSP configuration", "Unloaded on disconnect", §19.13, §19.20
-- `LspConfig/1`; integrations.md §9.2, §9.7, §9.8): in `daemon` mode the
-- language servers are configured ONLY from the daemon's state — the
-- observer's per-connection read, waiting (held, no timeout) and
-- unavailable (withheld) with no in-process fallback, the re-evaluation in
-- loomworks.lsp, a lost connection stopping the controlled clients,
-- `set_option` only through the daemon, no editor-side database
-- generation, the views never built from the model and launches refused
-- while the workspace is unloaded.
--
-- Most cases drive a real loaded (shell) workspace with a fake connected
-- observer whose connection answers `get` / `set_option` as the test says;
-- one case runs the observer against an in-process server.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local source = require("loomworks.lsp_source")
local lsp = require("loomworks.lsp")
local views = require("loomworks.views")
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
        local obs = require("loomworks.daemon.observer")._current
        if obs then views.clear(obs) end
        require("loomworks.daemon.observer")._current, require("loomworks.daemon.observer")._selection = nil, nil
        views.daemon_root(nil)
        lsp._reset_gate()
        lsp._reset_withheld()
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
            root = ws.root, state = "connected", mode = "interfaces", conn = conn,
            daemon = { pid = 1 }, seq = 0, _tasks = {}, _order = {}, _owned = {},
            _feat = { [LSP_FEATURE] = "subscribed" }, _why = {},
            opts = { environ = function() return { PATH = "/x" } end, resolve = function() return "lw" end,
                relay = function() return { close = function() end } end },
        }, observer.Observer)
        -- Never spawn a relay from a test: a lost connection only records.
        function obs:_spawn() end
        require("loomworks.daemon.observer")._current = obs
        require("loomworks.daemon.observer")._selection = { mode = "daemon", source = "default", daemon = true }
        -- (What attach does: no view is built in-process, step 6b-alpha.)
        views.daemon_root(ws.root)
        return obs, calls
    end

    --- A daemon state (`get`'s answer): one entry of server `server` for the
    --- `app` project.
    local function dstate(o)
        o = o or {}
        local entry = vim.tbl_extend("force", {
            server = o.server or "clangd", root_dir = ws.root .. "/app", db_state = "ready",
            db_dir = ws.root .. "/out/Debug", db_rev = 0,
        }, o.entry or {})
        return {
            state = o.state or "loaded",
            ready = o.ready ~= false,
            projects = o.projects or { { project = "app", id = "p1", path = "app", entries = { entry } } },
            options = o.options or { clangd = { clang_tidy = true } },
        }
    end

    --- The daemon's project index (as its ProjectsIndex/1 view would hold it:
    --- the daemon's root is a real path, like the editor model's).
    local function daemon_index(obs)
        views.set(obs, "projects", { projects = {
            { key = "app", id = "p1", label = "app", type = "shell", path = "app", abs_path = ws.root .. "/app" },
        } })
    end

    local function wait_phase(phase)
        assert.is_true(vim.wait(3000, function() return (source.daemon_phase()) == phase end, 10),
            "phase " .. tostring((source.daemon_phase())) .. ", want " .. phase)
    end

    local function signal(obs, seq)
        obs:_on_message({ kind = "signal", object = "/lsp", iface = "loomworks.LspConfig", v = 1,
            name = "changed", args = { seq = seq } })
    end

    describe("reads and the source", function()
        it("in use: the daemon's state only, read with the editor's environment", function()
            local obs, calls = fake_obs(function(m) if m == "get" then return dstate() end end)
            assert.equals("daemon", source.mode())
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
            assert.is_false(source.waiting())
            assert.same({ clang_tidy = true }, source.options("clangd"))
        end)

        it("the buffer's project is lw.buf_project's record (§19.13), by key only", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate() end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            -- No daemon project index yet: no buffer maps (never the model's).
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/src/main.cpp")
            assert.is_nil(source.project_for_buf(buf))
            daemon_index(obs)
            assert.equals("app", source.project_for_buf(buf).project)
            assert.equals("p1", source.project_for_buf(buf).id)
            -- Separator-bounded: a sibling directory sharing the prefix is not in it.
            local other = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(other, root .. "/appendix/x.cpp")
            assert.is_nil(source.project_for_buf(other))
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.api.nvim_buf_delete(other, { force = true })
        end)

        it("a buffer spelled through a link maps by its physical identity (Windows 8.3, junctions)", function()
            local real = ws.root .. "/real"
            vim.fn.mkdir(real .. "/src", "p")
            local link = H.tmp() .. "/via"
            assert(vim.uv.fs_symlink(real, link, { dir = true, junction = true }))
            local index = { projects = { { key = "app", abs_path = vim.uv.fs_realpath(real) } } }
            assert.equals("app", views.match(index, link .. "/src/x.cpp").key)
            assert.is_true(views.under(ws.root, link .. "/src/x.cpp"))
            assert.is_false(views.under(ws.root .. "/rea", link .. "/src/x.cpp"))
            assert.is_nil(views.match(index, H.tmp() .. "/elsewhere/x.cpp"))
        end)

        it("a linked spelling inside an outer project maps to the inner project it really lies in", function()
            -- Projects `ws` and `ws/longdirname`; the buffer is spelled through
            -- a link inside `ws` that resolves into `longdirname` (as a Windows
            -- 8.3 `LONGDI~1` does): its spelling matches the outer project,
            -- its physical identity the inner one — the inner one wins.
            local inner = ws.root .. "/longdirname"
            vim.fn.mkdir(inner, "p")
            local link = ws.root .. "/via"
            assert(vim.uv.fs_symlink(inner, link, { dir = true, junction = true }))
            local index = { projects = {
                { key = "outer", abs_path = vim.uv.fs_realpath(ws.root) },
                { key = "inner", abs_path = vim.uv.fs_realpath(inner) },
            } }
            assert.equals("inner", views.match(index, link .. "/x.c").key)
            assert.equals("outer", views.match(index, ws.root .. "/other/x.c").key)
            -- A real 8.3 short name, where the volume generates them.
            if vim.fn.has("win32") == 1 then
                local out = vim.fn.system({ "cmd", "/c", "for %I in (\"" .. inner:gsub("/", "\\") .. "\") do @echo %~sI" })
                local short = vim.trim(out or ""):gsub("\\", "/")
                if vim.v.shell_error == 0 and short:find("~", 1, true) then
                    assert.equals("inner", views.match(index, short .. "/x.c").key)
                end
            end
        end)

        it("a project root spelled through a link matches a buffer opened by its real path", function()
            local real = ws.root .. "/realroot"
            vim.fn.mkdir(real .. "/src", "p")
            local link = H.tmp() .. "/rootlink"
            assert(vim.uv.fs_symlink(real, link, { dir = true, junction = true }))
            local index = { projects = { { key = "app", abs_path = link } } }
            local file = vim.uv.fs_realpath(real) .. "/src/x.cpp"
            assert.equals("app", views.match(index, file).key)
            assert.is_true(views.under(link, file))
            assert.is_false(views.under(H.tmp() .. "/rootlin", file))
            assert.is_nil(views.match(index, ws.root .. "/elsewhere/x.cpp"))
        end)

        it("a link inside a project pointing outside it maps by its spelling", function()
            -- ws/vendor -> <tmp>/outside: the buffer's physical path is under
            -- no project, its spelling is under `ws`.
            local outside = H.tmp() .. "/outside"
            vim.fn.mkdir(outside, "p")
            local link = ws.root .. "/vendor"
            assert(vim.uv.fs_symlink(outside, link, { dir = true, junction = true }))
            local index = { projects = { { key = "app", abs_path = ws.root } } }
            assert.equals("app", views.match(index, link .. "/lib/x.c").key)
            assert.is_true(views.under(ws.root, link .. "/lib/x.c"))
            -- The outside folder spelled as itself is not in the project.
            assert.is_nil(views.match(index, outside .. "/lib/x.c"))
            assert.is_false(views.under(ws.root, outside .. "/lib/x.c"))
            -- Still separator-bounded on the spelling.
            assert.is_false(views.under(ws.root .. "/vend", link .. "/lib/x.c"))
        end)

        it("a junction nested in a project into a shorter physical path maps to the junction's project", function()
            -- A at C:/src/ws; B at C:/src/ws/ext, a junction to D:/e. The
            -- buffer C:/src/ws/ext/f.c is physically D:/e/f.c: under B's
            -- physical root (shorter than A's) and under A only by spelling.
            -- Physical containment wins, so both spellings map to B.
            local saved = views._fs_realpath
            local owner = {}
            views._fs_realpath = function(p)
                p = p:gsub("\\", "/")
                local rest = p:match("^[Cc]:/src/ws/ext(.*)$")
                if rest and (rest == "" or rest:sub(1, 1) == "/") then return "D:\\e" .. rest end
                if p:match("^[Cc]:/src/ws$") or p:match("^[Cc]:/src/ws/") then return p end
                if p:match("^[Dd]:/e$") or p:match("^[Dd]:/e/") then return p end
                return nil
            end
            local ok, err = pcall(function()
                local index = { projects = {
                    { key = "a", abs_path = "C:/src/ws" },
                    { key = "b", abs_path = "C:/src/ws/ext" },
                } }
                views.set(owner, "projects", index) -- forget cached identities
                assert.equals("b", views.match(index, "C:/src/ws/ext/f.c").key)
                assert.equals("b", views.match(index, "D:/e/f.c").key)
                assert.equals("a", views.match(index, "C:/src/ws/f.c").key)
            end)
            views._fs_realpath = saved
            views.clear(owner)
            assert(ok, err)
        end)

        it("an unreachable UNC path never resolves above its share", function()
            local saved = views._fs_realpath
            -- Nothing on the share resolves; `/` would resolve to the drive root.
            views._fs_realpath = function(p)
                if p == "/" then return "C:\\" end
                if p:sub(1, 2) == "//" then return nil end
                return saved(p)
            end
            local ok, err = pcall(function()
                local file = "//srvunc/share/x/y.c"
                assert.is_false(views.under("C:/srvunc/share/x", file))
                assert.is_nil(views.match({ projects = { { key = "c", abs_path = "C:/srvunc/share" } } }, file))
                -- Its own spelling still matches a root on the share.
                assert.is_true(views.under("//srvunc/share/x", file))
            end)
            views._fs_realpath = saved
            assert(ok, err)
        end)

        it("a retargeted link is re-resolved once the ProjectsIndex view changes", function()
            local a, b = ws.root .. "/pa", ws.root .. "/pb"
            vim.fn.mkdir(a, "p"); vim.fn.mkdir(b, "p")
            local link = H.tmp() .. "/retarget"
            assert(vim.uv.fs_symlink(a, link, { dir = true, junction = true }))
            local index = { projects = {
                { key = "a", abs_path = vim.uv.fs_realpath(a) },
                { key = "b", abs_path = vim.uv.fs_realpath(b) },
            } }
            assert.equals("a", views.match(index, link .. "/x.c").key)
            assert(vim.uv.fs_unlink(link) or vim.uv.fs_rmdir(link))
            assert(vim.uv.fs_symlink(b, link, { dir = true, junction = true }))
            -- Cached until the index view changes.
            assert.equals("a", views.match(index, link .. "/x.c").key)
            local owner = {}
            views.set(owner, "projects", index)
            assert.equals("b", views.match(index, link .. "/x.c").key)
            views.clear(owner)
        end)

        it("waits while connecting and while unloaded, with no in-process state", function()
            local obs, calls = fake_obs()
            -- No connection yet: waiting.
            obs.state = "connecting"
            local phase, d = source.daemon_phase()
            assert.equals("waiting", phase)
            assert.equals("connecting", d.why)
            assert.is_true(source.waiting())
            assert.is_false(source.loaded())
            assert.is_false(source.loaded_and_ready())
            assert.is_true(source.pending())
            assert.same({}, source.projects())
            assert.equals("unloaded", source.state().state)
            assert.is_nil(source.options("clangd"))
            -- The first read in flight: still waiting.
            obs.state = "connected"
            obs:_fetch_lsp()
            assert.equals("waiting", (source.daemon_phase()))
            calls[1].cb(dstate({ state = "unloaded", ready = false, projects = {}, options = {} }))
            assert.is_true(vim.wait(2000, function() return obs._lsp_read ~= nil end, 10))
            phase, d = source.daemon_phase()
            assert.equals("waiting", phase)
            assert.equals("unloaded", d.why)
            assert.same({}, source.projects())
            local note, warn = obs:lsp_note()
            assert.equals("lsp configuration: waiting for the workspace daemon — language servers held", note)
            assert.is_false(warn)
            signal(obs, 1)
            calls[2].cb(dstate())
            wait_phase("loaded")
            assert.is_true(source.in_use())
            assert.is_nil((obs:lsp_note()))
        end)

        it("loaded but not ready is pending", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate({ ready = false }) end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            assert.is_false(source.waiting())
            assert.is_true(source.pending())
            assert.is_false(source.loaded_and_ready())
        end)

        it("a declined or failed read, or a refused/error state, is unavailable until the next change", function()
            local reply = { nil, { code = "internal", message = "boom" } }
            local obs, calls = fake_obs(function(m) if m == "get" then return reply[1], reply[2] end end)
            obs:_fetch_lsp()
            wait_phase("unavailable")
            local _, d = source.daemon_phase()
            assert.equals("daemon", d.kind)
            assert.truthy(d.note:find("LspConfig/1.get failed: boom", 1, true))
            assert.is_false(source.in_use())
            assert.same({}, source.projects())
            assert.is_nil(obs._degraded) -- not a missing method
            local note, warn = obs:lsp_note()
            assert.truthy(note:find("— language servers withheld", 1, true))
            assert.is_true(warn)
            -- A `Workspace/1` `changed` reads again.
            reply = { { outcome = "declined", reason = "stopping" } }
            obs:_model_change(1, obs.generation)
            assert.is_true(vim.wait(3000, function()
                return #calls == 2 and select(2, source.daemon_phase()).note == "LspConfig/1.get declined (stopping)"
            end, 10))
            reply = { dstate({ state = "refused", ready = false, projects = {}, options = {} }) }
            obs:_model_change(2, obs.generation)
            assert.is_true(vim.wait(3000, function()
                return #calls == 3 and select(2, source.daemon_phase()).kind == "error"
            end, 10))
            reply = { dstate() }
            obs:_model_change(3, obs.generation)
            wait_phase("loaded")
        end)

        it("not carried: no binary, protocol 10, a missing method or another version is unavailable", function()
            local obs = fake_obs(function(m) if m == "get" then return nil, { code = "unknown_method", message = "get" } end end)
            obs:_fetch_lsp()
            wait_phase("unavailable")
            assert.is_true(obs._degraded.get)
            assert.is_false(obs:can_call("get"))
            assert.truthy(select(2, source.daemon_phase()).note:find("LspConfig/1.get", 1, true))
            -- Never noted as running in-process.
            assert.is_nil(obs._method_notes)
            -- Offered at another version only.
            obs._degraded = nil
            obs._lsp_read = nil
            obs._feat[LSP_FEATURE] = "missing"
            obs._why[LSP_FEATURE] = "lsp configuration: daemon offers loomworks.LspConfig/2, editor needs /1"
            local phase, d = source.daemon_phase()
            assert.equals("unavailable", phase)
            assert.equals("daemon offers loomworks.LspConfig/2, editor needs /1", d.note)
            assert.is_false(obs:can_call("set_option"))
            -- The describe not answered yet (nothing settled): waiting.
            obs._feat[LSP_FEATURE], obs._why[LSP_FEATURE] = nil, nil
            assert.equals("waiting", (source.daemon_phase()))
            -- Protocol 10.
            obs.mode = "v0"
            assert.equals("unavailable", (source.daemon_phase()))
            -- No host binary.
            obs.mode, obs.state = "interfaces", "no-binary"
            phase, d = source.daemon_phase()
            assert.equals("unavailable", phase)
            assert.equals("no lw host binary", d.note)
        end)

        it("a lost connection unloads the workspace until the daemon reports loaded", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate() end end)
            require("loomworks.daemon.observer")._selection = { mode = "daemon", source = "env", daemon = true }
            obs:_fetch_lsp()
            wait_phase("loaded")
            local seen = 0
            on("daemon_lsp_config", function() seen = seen + 1 end)
            obs:_on_closed(obs.conn)
            local phase, d = source.daemon_phase()
            assert.equals("waiting", phase)
            assert.equals("disconnected", d.why)
            assert.is_false(source.in_use())
            assert.is_nil(obs._lsp_read)
            assert.is_true(seen >= 1)
            local text, warn = observer.runtime_line(ws)
            assert.truthy(text:find(observer.LOST_NOTE, 1, true), text)
            assert.truthy(text:find("language servers stopped, held", 1, true), text)
            assert.is_true(warn)
            -- Reconnected, the daemon not loaded yet: still unloaded.
            local conn2 = { closed = false }
            local n = 0
            function conn2:call(_, _, _, method, _, cb)
                n = n + 1
                if method == "get" then cb(n == 1 and dstate({ state = "unloaded", ready = false, projects = {} }) or dstate()) end
            end
            obs.conn, obs.state, obs.mode = conn2, "connected", "interfaces"
            obs._feat, obs._why = { [LSP_FEATURE] = "subscribed" }, {}
            obs:_fetch_lsp()
            assert.equals("disconnected", select(2, source.daemon_phase()).why)
            assert.is_true((obs:workspace_unloaded()))
            text = observer.runtime_line(ws)
            assert.truthy(text:find(observer.LOST_NOTE, 1, true), text)
            obs:_fetch_lsp()
            wait_phase("loaded")
            assert.is_nil(obs._lost)
            assert.is_false((obs:workspace_unloaded()))
            assert.is_nil(observer.runtime_line(ws):find(observer.LOST_NOTE, 1, true))
        end)

        it("ignores a get reply from before /lsp was removed and re-added", function()
            local obs, calls = fake_obs()
            obs:_fetch_lsp()
            assert.equals(1, #calls)
            obs:_on_objects_changed({ removed = { "/lsp" } })
            assert.is_nil(obs._lsp_fetch)
            -- Re-added and subscribed again: a new read.
            obs._feat[LSP_FEATURE] = "subscribed"
            obs:_fetch_lsp()
            local second = calls[#calls]
            assert.equals("get", second.method)
            -- The old reply arrives late: ignored.
            calls[1].cb(dstate({ entry = { db_state = "unconfigured" } }))
            assert.is_nil(obs._lsp_read)
            assert.is_not_nil(obs._lsp_fetch)
            second.cb(dstate())
            wait_phase("loaded")
            assert.equals("ready", source.projects()[1].entries[1].db_state)
        end)
    end)

    describe("re-evaluation in loomworks.lsp (§9.7, §9.8)", function()
        local hits
        before_each(function()
            hits = { active = 0, options = {}, db = {} }
            lsp.register("fakesrv", {
                on_active_set_changed = function() hits.active = hits.active + 1 end,
                on_lsp_options_changed = function(p) hits.options[#hits.options + 1] = p end,
                on_owned_database_changed = function(dir) hits.db[#hits.db + 1] = dir end,
                withhold_reason = function(entry)
                    if entry.db_state == "unconfigured" then return "unconfigured" end
                    return nil
                end,
            })
        end)
        after_each(function() lsp.register("fakesrv", {}) end)

        local function held_buf(name)
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, name or (root .. "/app/main.cpp"))
            local started = {}
            lsp.managed_root_dir("fakesrv", buf, function(dir) started[#started + 1] = dir end)
            return buf, started
        end

        it("a switch, changed entries, options and a raised db_rev each reach the integrations", function()
            local st = dstate({ server = "fakesrv", options = { fakesrv = { a = 1 } } })
            local obs = fake_obs(function(m) if m == "get" then return vim.deepcopy(st) end end)
            obs:_fetch_lsp()
            wait_phase("loaded")
            -- The switch to the daemon's state: an active-set change; no
            -- option change on the first state in use.
            assert.is_true(vim.wait(2000, function() return hits.active == 1 end, 10))
            vim.wait(50)
            assert.equals(0, #hits.options)
            -- A database the daemon wrote (db_rev raised): the completion signal.
            st.projects[1].entries[1].db_rev = 1
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return #hits.db == 1 end, 10))
            assert.equals(ws.root .. "/app", hits.db[1])
            assert.equals(1, hits.active)
            -- An option the daemon reports changed.
            st.options.fakesrv.a = 2
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return #hits.options == 1 end, 10))
            assert.same({ server = "fakesrv", key = "a", value = 2 }, hits.options[1])
            -- Changed entries.
            st.projects[1].entries[1].db_state = "unconfigured"
            obs:_fetch_lsp()
            assert.is_true(vim.wait(2000, function() return hits.active == 2 end, 10))
            -- An unchanged read changes nothing.
            obs:_fetch_lsp()
            vim.wait(100)
            assert.equals(2, hits.active)
            assert.equals(1, #hits.options)
            assert.equals(1, #hits.db)
        end)

        it("the model's own events re-evaluate nothing in daemon mode", function()
            fake_obs()
            events.emit("active_set_changed")
            events.emit("lsp_options_changed", { server = "fakesrv", key = "a", value = 3 })
            vim.wait(50)
            assert.equals(0, hits.active)
            assert.equals(0, #hits.options)
        end)

        it("the hold is released on the daemon's ready, not on the model's lsp_ready", function()
            local obs, calls = fake_obs()
            daemon_index(obs)
            obs:_fetch_lsp()
            local buf, started = held_buf()
            assert.equals(1, lsp._gate_queue_len())
            assert.equals("held", lsp.buf_state(buf))
            -- The model's own readiness does not release a hold for the daemon.
            events.emit("lsp_ready")
            assert.equals(1, lsp._gate_queue_len())
            -- Loaded, not ready: still held.
            calls[1].cb(dstate({ server = "fakesrv", ready = false }))
            wait_phase("loaded")
            assert.equals(1, lsp._gate_queue_len())
            obs:_fetch_lsp()
            calls[2].cb(dstate({ server = "fakesrv" }))
            assert.is_true(vim.wait(2000, function() return #started == 1 end, 10))
            assert.equals(0, lsp._gate_queue_len())
            assert.equals("ok", lsp.buf_state(buf))
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("waiting for the daemon holds with no timeout and never resolves in-process", function()
            local obs = fake_obs()
            obs.state = "connecting"
            lsp._gate_timeout_ms = 30
            local buf, started = held_buf()
            assert.equals(1, lsp._gate_queue_len())
            vim.wait(200)
            assert.equals(1, lsp._gate_queue_len())
            assert.equals("held", lsp.buf_state(buf))
            assert.equals(0, #started)
            assert.equals("waiting", (source.daemon_phase()))
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("the safety timeout of a loaded-but-not-ready hold resolves against the daemon's state", function()
            local obs = fake_obs(function(m)
                if m == "get" then return dstate({ server = "fakesrv", ready = false, entry = { db_state = "unconfigured" } }) end
            end)
            daemon_index(obs)
            lsp._gate_timeout_ms = 30
            obs:_fetch_lsp()
            wait_phase("loaded")
            local buf, started = held_buf()
            assert.equals(1, lsp._gate_queue_len())
            assert.is_true(vim.wait(2000, function() return lsp._gate_queue_len() == 0 end, 10))
            assert.equals("withheld_unconfigured", lsp.buf_state(buf))
            assert.equals(0, #started)
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("unavailable withholds: withheld_daemon, or withheld_error for a failed load", function()
            local obs = fake_obs()
            obs.state = "no-binary"
            local buf, started = held_buf()
            assert.equals(0, lsp._gate_queue_len())
            assert.equals("withheld_daemon", lsp.buf_state(buf))
            assert.equals(0, #started)
            -- A buffer outside the root takes the stock path.
            local out = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(out, H.tmp() .. "/x.cpp")
            local fell = 0
            lsp.managed_root_dir("fakesrv", out, function() end, function() fell = fell + 1 end)
            assert.equals("none", lsp.buf_state(out))
            assert.equals(1, fell)
            -- The daemon's load failed.
            obs.state = "connected"
            obs._lsp_read = { state = dstate({ state = "error", ready = false, projects = {} }) }
            lsp._reevaluate_now()
            assert.equals("withheld_error", lsp.buf_state(buf))
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.api.nvim_buf_delete(out, { force = true })
        end)

        it("a lost connection stops the controlled clients (managed stop) and holds their buffers", function()
            local obs = fake_obs(function(m) if m == "get" then return dstate({ server = "fakesrv" }) end end)
            daemon_index(obs)
            obs:_fetch_lsp()
            wait_phase("loaded")
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
            local stopped = 0
            local client = { id = 4242, root_dir = ws.root .. "/app", attached_buffers = { [buf] = true } }
            function client:stop() stopped = stopped + 1 end
            local orig_get, orig_mark, orig_retrigger = vim.lsp.get_clients, lsp.mark_managed_stop, lsp._retrigger_attach
            local managed, retriggered = {}, {}
            vim.lsp.get_clients = function(f)
                if f and f.name == "fakesrv" and stopped == 0 then return { client } end
                return {}
            end
            lsp.mark_managed_stop = function(id) managed[#managed + 1] = id end
            lsp._retrigger_attach = function(b, servers) retriggered[#retriggered + 1] = { b, servers } end
            local ok, err = pcall(function()
                obs:_on_closed(obs.conn)
                assert.is_true(vim.wait(2000, function() return stopped == 1 end, 10))
                assert.same({ 4242 }, managed)
                assert.equals("held", lsp.buf_state(buf))
                -- The daemon reports loaded again after a reconnect: started.
                local conn2 = { closed = false }
                function conn2:call(_, _, _, method, _, cb)
                    if method == "get" then cb(dstate({ server = "fakesrv" })) end
                end
                obs.conn, obs.state, obs.mode = conn2, "connected", "interfaces"
                obs._feat, obs._why = { [LSP_FEATURE] = "subscribed" }, {}
                obs:_fetch_lsp()
                assert.is_true(vim.wait(2000, function() return #retriggered == 1 end, 10))
                assert.equals(buf, retriggered[1][1])
            end)
            vim.lsp.get_clients, lsp.mark_managed_stop, lsp._retrigger_attach = orig_get, orig_mark, orig_retrigger
            vim.api.nvim_buf_delete(buf, { force = true })
            assert(ok, err)
        end)

        -- §19.16 "Running clients": waiting while connected, or an
        -- unavailable configuration, starts no client and stops none; the
        -- buffers of a running client keep status `ok`.
        local function running_client_case(make_not_loaded)
            local obs = fake_obs(function(m) if m == "get" then return dstate({ server = "fakesrv" }) end end)
            daemon_index(obs)
            obs:_fetch_lsp()
            wait_phase("loaded")
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
            lsp.managed_root_dir("fakesrv", buf, function() end)
            assert.equals("ok", lsp.buf_state(buf))
            local stopped, detached = 0, 0
            local client = { id = 4343, root_dir = ws.root .. "/app", attached_buffers = { [buf] = true } }
            function client:stop() stopped = stopped + 1 end
            local orig_get, orig_mark, orig_detach = vim.lsp.get_clients, lsp.mark_managed_stop, vim.lsp.buf_detach_client
            local managed = {}
            vim.lsp.get_clients = function(f)
                if f and f.name == "fakesrv" then return { client } end
                return {}
            end
            lsp.mark_managed_stop = function(id) managed[#managed + 1] = id end
            vim.lsp.buf_detach_client = function() detached = detached + 1 end
            local ok, err = pcall(function()
                make_not_loaded(obs)
                lsp._reevaluate_now()
                assert.equals(0, stopped)
                assert.equals(0, detached)
                assert.same({}, managed)
                assert.equals("ok", lsp.buf_state(buf))
                -- A new buffer with no running client is still held/withheld.
                local other = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(other, root .. "/app/other.cpp")
                local started = 0
                lsp.managed_root_dir("fakesrv", other, function() started = started + 1 end)
                assert.equals(0, started)
                assert.is_true(vim.tbl_contains({ "held", "withheld_daemon", "withheld_error" }, lsp.buf_state(other)))
                vim.api.nvim_buf_delete(other, { force = true })
            end)
            vim.lsp.get_clients, lsp.mark_managed_stop, vim.lsp.buf_detach_client = orig_get, orig_mark, orig_detach
            vim.api.nvim_buf_delete(buf, { force = true })
            assert(ok, err)
        end

        it("an unavailable configuration stops no running client; its buffers stay ok", function()
            running_client_case(function(obs)
                obs._lsp_read = { state = nil }
                wait_phase("unavailable")
            end)
        end)

        it("a failed (error) reload stops no running client", function()
            running_client_case(function(obs)
                obs._lsp_read = { state = dstate({ state = "error", ready = false, projects = {} }) }
                wait_phase("unavailable")
            end)
        end)

        it("waiting while connected (daemon reports unloaded) stops no running client", function()
            running_client_case(function(obs)
                obs._lsp_read = { state = dstate({ state = "unloaded", ready = false, projects = {} }) }
                wait_phase("waiting")
            end)
        end)
    end)

    describe("options", function()
        local notes, saved_notify, wrote, orig_set
        before_each(function()
            notes = {}
            saved_notify = vim.notify
            vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
            wrote = false
            orig_set = ws.set_lsp_option
            ws.set_lsp_option = function() wrote = true; return true end
        end)
        after_each(function()
            vim.notify = saved_notify
            ws.set_lsp_option = orig_set
        end)

        it("set_option goes through the daemon, applied from the read back", function()
            local _, calls = fake_obs(function(m)
                if m == "get" then return dstate() end
                if m == "set_option" then return { outcome = "ok" } end
            end)
            local done
            assert.is_true(require("loomworks").set_lsp_option("clangd", "clang_tidy", false,
                function(ok, err) done = { ok, err } end))
            assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
            assert.same({ true }, done)
            assert.is_false(wrote)
            assert.equals("set_option", calls[1].method)
            assert.same({ server = "clangd", key = "clang_tidy", value = false }, calls[1].args)
            assert.is_true(vim.wait(2000, function() return #calls >= 2 and calls[2].method == "get" end, 10))
            assert.same({}, notes)
        end)

        it("every other outcome is an error naming what happened, nothing written", function()
            local reply
            local obs = fake_obs(function(m) if m == "set_option" then return reply[1], reply[2] end end)
            local ops = require("loomworks.daemon.editor_ops")
            local function try(r)
                reply = r
                local done
                ops.set_lsp_option(nil, "clangd", "clang_tidy", true, function(ok, err) done = { ok, err } end)
                assert.is_true(vim.wait(2000, function() return done ~= nil end, 10))
                assert.is_false(done[1])
                assert.equals(vim.log.levels.ERROR, notes[#notes].level)
                return done[2]
            end
            assert.equals("invalid: set_option: unknown key nope",
                try({ nil, { code = "invalid_args", message = "set_option: unknown key nope" } }))
            assert.is_nil(obs._degraded)
            assert.is_true(obs:can_call("set_option"))
            assert.equals("the workspace daemon refused it: user.json changed on disk",
                try({ { outcome = "refused", message = "user.json changed on disk" } }))
            assert.equals("the workspace daemon declined it (stopping)",
                try({ { outcome = "declined", reason = "stopping" } }))
            local err = try({ nil, { code = "internal", message = "no answer" } })
            assert.equals("the call to the workspace daemon failed: no answer", err)
            assert.is_nil(err:find("refused", 1, true))
            assert.is_false(wrote)
        end)

        it("not carried: an error, nothing written", function()
            local obs = fake_obs()
            obs._feat[LSP_FEATURE] = "missing"
            obs._why[LSP_FEATURE] = "x"
            local done
            local ok, err = require("loomworks").set_lsp_option("clangd", "clang_tidy", true,
                function(o, e) done = { o, e } end)
            assert.is_false(ok)
            assert.truthy(err:find("does not carry the LSP configuration", 1, true))
            assert.same({ false, err }, done)
            assert.is_false(wrote)
        end)
    end)

    describe("owned databases", function()
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

        it("in-process mode (no observer) generates", function()
            local rec = {}
            assert.is_true(ws:generates_lsp_databases())
            ws:_refresh_lsp_database_for(unit_with_db(rec))
            assert.equals(1, #rec)
        end)
    end)

    describe("views and launches while unloaded (§19.13, §19.16)", function()
        it("the views are never built from the model in daemon mode", function()
            assert.equals("loaded", views.header().state)
            assert.equals(1, #views.projects_index().projects)
            local obs = fake_obs()
            assert.equals("unloaded", views.header().state)
            assert.is_nil(views.projects_index())
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
            assert.is_nil(require("loomworks").buf_project(buf))
            assert.is_nil(require("loomworks").buf_status(buf))
            views.set(obs, "header", { root = ws.root, state = "loaded", name = "x" })
            daemon_index(obs)
            assert.equals("app", require("loomworks").buf_project(buf).key)
            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        -- TODO(A1b): launch targets come from `Launch/1.targets` (no model in
        -- `daemon` mode, step 6b-alpha); restore on the facade's launch.
        pending("a run or debug launch is refused while the workspace is unloaded", function()
            local tracker = require("loomworks.session_tracker")
            local target = { _profile = { _workspace = ws } }
            assert.is_nil(tracker.launch_refusal(target)) -- in-process mode
            local obs = fake_obs()
            -- Only a daemon reporting `unloaded` or a lost connection
            -- unloads the workspace: no host binary, or a first connection
            -- still being made, refuses nothing.
            obs.state = "no-binary"
            assert.is_nil(tracker.launch_refusal(target))
            obs.state = "connecting"
            assert.is_nil(tracker.launch_refusal(target))
            obs.state = "connected"
            views.set(obs, "header", { root = ws.root, state = "unloaded" })
            assert.truthy(tracker.launch_refusal(target):find("has not loaded the workspace", 1, true))
            views.set(obs, "header", { root = ws.root, state = "loaded" })
            assert.is_nil(tracker.launch_refusal(target))
            obs:_on_closed(obs.conn)
            assert.truthy(tracker.launch_refusal(target):find(observer.LOST_NOTE, 1, true))
            -- Waiting for the reconnect: still unloaded.
            obs.state = "connecting"
            assert.truthy(tracker.launch_refusal(target):find(observer.LOST_NOTE, 1, true))
        end)

        pending("a run or debug launch is not offered while the workspace is unloaded (no target picker)", function()
            local lw = require("loomworks")
            local profile = ws:get_profiles()[1]
            assert.truthy(profile)
            local orig_pick, orig_default, orig_notify = lw._pick_target, profile.default_target, vim.notify
            local orig_active = lw.get_active_profile
            lw.get_active_profile = function() return profile end
            local picked, notes = 0, {}
            lw._pick_target = function() picked = picked + 1 end
            profile.default_target = function() return nil end
            vim.notify = function(m) notes[#notes + 1] = m end
            local ok, err = pcall(function()
                local obs = fake_obs()
                obs:_on_closed(obs.conn)
                lw.launch_target()
                assert.equals(0, picked)
                assert.truthy(notes[#notes]:find(observer.LOST_NOTE, 1, true), notes[#notes])
                -- Loaded again: offered.
                obs._lost = nil
                obs.state, obs.mode = "connected", "interfaces"
                views.set(obs, "header", { root = ws.root, state = "loaded" })
                lw.launch_target()
                assert.equals(1, picked)
            end)
            lw._pick_target, profile.default_target, vim.notify = orig_pick, orig_default, orig_notify
            lw.get_active_profile = orig_active
            assert(ok, err)
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
        assert(reg:mount("/workspace", "core", "loomworks.Workspace", 1, { methods = H.workspace_stub({
            header = function() return { root = srv.root, state = "loaded" } end,
        }) }))
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

    it("reads the state once discovered, again on `changed`, and waits when the daemon goes", function()
        local fr = FR.new({})
        obs = observer.attach(ws.root, { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(10000, function() return source.in_use() end, 10), obs:runtime_line())
        assert.equals("unconfigured", source.projects()[1].entries[1].db_state)
        STATE.projects[1].entries[1].db_state = "ready"
        srv:registry():emit("/lsp", "loomworks.LspConfig", 1, "changed", { seq = 1 })
        assert.is_true(vim.wait(5000, function()
            return source.in_use() and source.projects()[1].entries[1].db_state == "ready"
        end, 10))
        srv:stop("test end", 0)
        assert.is_true(vim.wait(5000, function()
            local phase, d = source.daemon_phase()
            return phase == "waiting" and d.why == "disconnected"
        end, 10))
        assert.is_false(source.in_use())
        assert.same({}, source.projects())
    end)
end)
