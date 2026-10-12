-- The editor's run and debug launches through the daemon's preparation
-- (spec §19.16 "Editor operations", §19.15 "Run" / "Debug" / "Build scope of
-- a launch"; step 5k part C2), and the debug adapters section on
-- `DebugConfig/1` (§19.20): against an observer whose connection is a
-- recording fake (no daemon). A non-device launch is a
-- `Launch/1.prepare_run` / `prepare_debug` the editor owns; its `done`
-- starts the program here (task runner / nvim-dap); declined or degraded →
-- the in-process chain; refused, failed, or the connection lost after
-- `accepted` → no program, never re-run in-process. A preparation's
-- task-runner restart is not sent again.

local observer = require("loomworks.daemon.observer")
local editor_ops = require("loomworks.daemon.editor_ops")
local H = require("tests.daemon_helpers")

describe("editor launches through the daemon's preparation (§19.16, step 5k C2)", function()
    local root, core, ws, profile
    local obs, sent, created, notes, launched, dap_runs, titles
    local saved = {}

    local function fake_observer(feat)
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb, env)
            sent[#sent + 1] = { object = object, iface = iface, v = v, method = method, args = args, cb = cb,
                env = env }
        end
        function conn.close(c) c.closed = true end
        local o = setmetatable({
            ws = ws, root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = feat or { operations = "available", launch = "available", ["debug adapters"] = "available",
                tasks = "subscribed" },
            _why = {}, _tasks = {}, _order = {}, _owned = {}, seq = 0,
            daemon = { pid = 1 },
            opts = { environ = function() return { PATH = "x" } end },
        }, observer.Observer)
        ws._daemon_observer = o
        ws._operation_router = editor_ops.router
        observer._current = o
        return o
    end

    local function lt(name)
        return require("loomworks.launch_target").new(ws, profile, { project = "app", launch = name })
    end

    local function accept(i, id)
        sent[i].cb({ outcome = "accepted", task_id = id }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned[id] ~= nil end, 10))
    end
    local function start_frame(id, kind)
        obs:_on_task({ kind = "task", task_id = id, phase = "start",
            meta = { name = kind .. " app", kind = kind, profile = profile.key, origin = "editor" } })
    end
    local function done_frame(id, code, result, err)
        obs:_on_task({ kind = "task", task_id = id, phase = "done", exit_code = code, error = err, result = result })
    end

    local function stub(mod, key, fn)
        saved[#saved + 1] = { mod, key, mod[key] }
        mod[key] = fn
    end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        profile = ws:get_profiles()[1]
        -- The project's launch configurations (as loaded from the files).
        ws._projects[1].launch = {
            run = { command = "tool", args = { "-v" } },
            multi = { command = "node", args = { "x.js" }, debug = { "typescript", "c++" } },
        }
        sent, created, notes, launched, dap_runs, titles = {}, {}, {}, {}, {}, {}
        saved = {}
        stub(package.loaded, "overseer", {
            new_task = function(spec)
                created[#created + 1] = spec
                return { id = 1000 + #created, subscribe = function() end, start = function() end,
                    stop = function() end, is_complete = function() return false end,
                    dispose = function() end }
            end,
        })
        stub(package.loaded, "overseer.task_list", { get = function() return nil end })
        stub(require("loomworks.overseer"), "launch_run_task", function(spec)
            launched[#launched + 1] = spec
            return 77
        end)
        local dbg = require("loomworks.debug")
        stub(dbg, "available", function() return true end)
        stub(dbg, "adapter_installed", function(a) return a == "codelldb" or a == "pwa-node" end)
        stub(dbg, "run", function(spec, cb)
            dap_runs[#dap_runs + 1] = { spec = spec, cb = cb }
            return true
        end)
        local fidget = require("loomworks.fidget")
        local function handle() return { report = function() end, finish = function() end, cancel = function() end } end
        stub(fidget, "start_action", function(title)
            titles[#titles + 1] = title
            return handle()
        end)
        stub(vim, "notify", function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end)
    end)

    after_each(function()
        pcall(function() require("loomworks.session_tracker").stop() end)
        for i = #saved, 1, -1 do
            local s = saved[i]
            s[1][s[2]] = s[3]
        end
        if obs then
            observer._current = nil
            if ws then ws._daemon_observer, ws._operation_router = nil, nil end
        end
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    --- The in-process chain ran: it builds the launch's unit first — an
    --- in-process build task, or (daemon mode) that build routed on its own
    --- as a C1 Build/1.build call; never a preparation.
    local function in_process_chain()
        return vim.wait(5000, function()
            if #created > 0 then return true end
            for _, c in ipairs(sent) do if c.method == "build" then return true end end
            return false
        end, 10)
    end

    local function noted(text)
        for _, n in ipairs(notes) do
            if n.msg:find(text, 1, true) then return true end
        end
        return false
    end

    it("in-process mode: nothing is sent, the in-process chain builds first", function()
        assert.is_nil(observer.current())
        require("loomworks.session_tracker").start(lt("run"), "launch")
        assert.is_true(in_process_chain())
        assert.same({}, sent)
        assert.equals(1, #created)
        -- No `(in-process)` marker outside daemon mode.
        assert.equals("Launching app: run", titles[1])
    end)

    it("a launch is a Launch/1.prepare_run the editor owns; its `launch` runs here", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        assert.equals(1, #sent)
        local c = sent[1]
        assert.same({ "/launch", "loomworks.Launch", 1, "prepare_run" }, { c.object, c.iface, c.v, c.method })
        assert.same({ interactive = false, build_scope = "target", profile = { key = profile.key },
            project = { key = "app" }, target = "run", kind = "launch" }, c.args)
        assert.same({ PATH = "x" }, c.env)
        -- The preparation's own task is its progress (no editor entry yet).
        assert.same({}, titles)
        accept(1, "r1")
        start_frame("r1", "run")
        assert.is_true(obs._tasks["r1"].owned)
        done_frame("r1", 0, { exit_code = 0, launch = { name = "app: run", cmd = "/bin/tool", args = { "-v" },
            cwd = "/w/app", env = { FOO = "1" } } })
        assert.is_true(vim.wait(2000, function() return #launched == 1 end, 10))
        assert.same({ name = "app: run", cmd = "/bin/tool", args = { "-v" }, cwd = "/w/app", env = { FOO = "1" } },
            launched[1])
        assert.same({ "Launching app: run" }, titles)
        -- Nothing built in-process.
        assert.equals(0, #created)
    end)

    it("a module target sends its target id, kind and descriptor working_dir", function()
        local target = require("loomworks.launch_target").new(ws, profile,
            { project = "app", target = "app", working_dir = "${workspace_root}/data" })
        local a = editor_ops.launch_args(target)
        assert.equals("app", a.target)
        assert.equals("target", a.kind)
        assert.equals("${workspace_root}/data", a.cwd)
        assert.equals("target", a.build_scope)
    end)

    it("a debug is a Launch/1.prepare_debug; its `debug` goes to nvim-dap", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "debug")
        assert.equals(1, #sent)
        assert.same({ "/launch", "prepare_debug" }, { sent[1].object, sent[1].method })
        accept(1, "d1")
        start_frame("d1", "debug")
        done_frame("d1", 0, { exit_code = 0, debug = { name = "app: run", program = "/bin/tool", args = { "-v" },
            cwd = "/w/app", env = vim.empty_dict(), language = "c++",
            adapters = { { language = "c++", adapter = "codelldb" } } } })
        assert.is_true(vim.wait(2000, function() return #dap_runs == 1 end, 10))
        local r = dap_runs[1].spec
        assert.same({ "codelldb", "/bin/tool", "/w/app", "app: run" }, { r.adapter, r.program, r.cwd, r.name })
        assert.same({ "-v" }, r.args)
        assert.is_nil(r.env)
        assert.is_nil(dap_runs[1].cb)
        assert.equals(0, #created)
        assert.same({}, launched)
    end)

    it("a multi-adapter debug launches the first adapter and attaches the rest to its pid", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("multi"), "debug")
        accept(1, "d2")
        done_frame("d2", 0, { exit_code = 0, debug = { name = "app: multi", program = "node", args = { "x.js" },
            cwd = "/w/app", env = { NODE_ENV = "dev" }, language = "typescript",
            adapters = { { language = "typescript", adapter = "pwa-node" }, { language = "c++", adapter = "codelldb" } } } })
        assert.is_true(vim.wait(2000, function() return #dap_runs == 1 end, 10))
        assert.equals("pwa-node", dap_runs[1].spec.adapter)
        assert.same({ NODE_ENV = "dev" }, dap_runs[1].spec.env)
        dap_runs[1].cb.on_pid(4242)
        assert.equals(2, #dap_runs)
        assert.same({ "codelldb", "attach", 4242 },
            { dap_runs[2].spec.adapter, dap_runs[2].spec.request, dap_runs[2].spec.attach_pid })
    end)

    it("a debug whose adapter is not installed stops with the hint before any call", function()
        obs = fake_observer()
        require("loomworks.debug").adapter_installed = function() return false end
        require("loomworks.session_tracker").start(lt("run"), "debug")
        assert.same({}, sent)
        assert.is_true(noted("not configured. Install via :Mason"))
        vim.wait(100)
        assert.equals(0, #created)
    end)

    it("declined: the in-process chain, the reason as one notification, `(in-process)` title", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        sent[1].cb({ outcome = "declined", reason = "another environment" }, nil)
        assert.is_true(in_process_chain())
        assert.is_true(noted("declined the launch (another environment)"))
        assert.equals("Launching app: run (in-process)", titles[1])
    end)

    it("a daemon without prepare_run: in-process, one Runtime-line note, not called again", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        sent[1].cb(nil, { code = "unknown_method", message = "no prepare_run" })
        assert.is_true(in_process_chain())
        assert.is_false(obs:can_call("prepare_run"))
        assert.is_true(obs:can_call("prepare_debug"))
        assert.is_true(obs:can_call("build"))
        assert.truthy((obs.note or ""):find("launch: daemon offers no loomworks.Launch/1.prepare_run", 1, true))
        assert.is_false(editor_ops.can_prepare("launch", lt("run")))
    end)

    it("no Launch/1 offered: not routed (in-process), builds still are", function()
        obs = fake_observer({ operations = "available", tasks = "subscribed" })
        assert.is_false(editor_ops.can_prepare("launch", lt("run")))
        assert.is_true(obs:can_call("build"))
        require("loomworks.session_tracker").start(lt("run"), "launch")
        assert.is_true(in_process_chain())
        assert.equals("build", sent[1].method)
    end)

    it("the connection lost after `accepted`: no program, never re-run in-process", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        accept(1, "r9")
        start_frame("r9", "run")
        obs:_end_tasks("the workspace daemon disconnected")
        assert.is_true(vim.wait(2000, function() return noted("the workspace daemon disconnected") end, 10))
        vim.wait(100)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("a failed preparation: its error, no program", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        accept(1, "r2")
        start_frame("r2", "run")
        done_frame("r2", 1, { exit_code = 1, error = "build failed" }, "build failed")
        assert.is_true(vim.wait(2000, function() return noted("build failed") end, 10))
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("refused: its message once, no program", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        sent[1].cb({ outcome = "refused", message = "workspace not trusted", exit_code = 1 }, nil)
        assert.is_true(vim.wait(2000, function() return noted("workspace not trusted") end, 10))
        vim.wait(100)
        local n = 0
        for _, x in ipairs(notes) do if x.msg:find("workspace not trusted", 1, true) then n = n + 1 end end
        assert.equals(1, n)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("a `device` result (foreign artifact) never runs here", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(lt("run"), "launch")
        accept(1, "r3")
        done_frame("r3", 0, { exit_code = 0, device = true })
        vim.wait(200)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("a preparation's task-runner restart is not sent again (it would start no program)", function()
        obs = fake_observer()
        local why
        editor_ops.rerun(obs, { method = "prepare_run", args = {} }, {
            runner = {}, accepted = function() error("must not be sent") end,
            failed = function(w) why = w end,
        })
        assert.same({}, sent)
        assert.equals("a launch is not restarted here — start it again from the editor", why)
    end)
end)

describe("debug adapters section on DebugConfig/1 (§19.20, step 5k C2)", function()
    local root, core, ws, obs, sent, emitted

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        sent, emitted = {}, {}
    end)

    after_each(function()
        observer._current = nil
        if ws then ws._daemon_observer = nil end
        pcall(function() core:shutdown() end)
    end)

    local function connect(feat)
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb)
            sent[#sent + 1] = { object = object, iface = iface, method = method, args = args, cb = cb }
        end
        obs = setmetatable({
            ws = ws, root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = feat or { ["debug adapters"] = "available" }, _why = {}, _tasks = {}, _order = {},
            _owned = {}, seq = 0, generation = 1, daemon = { pid = 1 },
            opts = { environ = function() return {} end },
        }, observer.Observer)
        function obs:_emit(e) emitted[#emitted + 1] = e end
        ws._daemon_observer = obs
        observer._current = obs
    end

    local REC = { language = "c++", adapter = "cppdbg", default = "codelldb", known = { "codelldb", "cppdbg" },
        overridden = true }

    it("in-process: the working copy's mapping; a change writes user.json", function()
        local recs = editor_ops.debug_adapters(ws)
        assert.same(require("loomworks.debug_config").adapter_records(ws), recs)
        local ok
        editor_ops.set_debug_adapter(ws, "c++", "cppdbg", function(r) ok = r end)
        assert.is_true(ok)
        assert.equals("cppdbg", require("loomworks.debug_config").resolve_adapter(ws, "c++"))
        assert.same({}, sent)
    end)

    it("carried: read from `adapters` (in-process until the first read), re-read on `changed`", function()
        connect()
        -- The first read is in flight: the in-process mapping meanwhile.
        assert.same(require("loomworks.debug_config").adapter_records(ws), editor_ops.debug_adapters(ws))
        assert.equals(1, #sent)
        assert.same({ "/debug", "loomworks.DebugConfig", "adapters" }, { sent[1].object, sent[1].iface, sent[1].method })
        editor_ops.debug_adapters(ws)
        assert.equals(1, #sent) -- single flight
        sent[1].cb({ languages = { REC } }, nil)
        assert.is_true(vim.wait(2000, function() return #emitted > 0 end, 10))
        assert.equals("daemon_debug_adapters", emitted[1])
        assert.same({ REC }, editor_ops.debug_adapters(ws))
        -- Workspace/1 `changed`: read again.
        obs:_on_message({ kind = "signal", object = "/workspace", iface = "loomworks.Workspace", name = "changed",
            args = { seq = 5, session_generation = 1 } })
        assert.equals(2, #sent)
        assert.equals("adapters", sent[2].method)
    end)

    it("carried: a change is `set_adapter` (no adapter: back to the default); refused is notified", function()
        connect()
        local orig = vim.notify
        local notes = {}
        vim.notify = function(m) notes[#notes + 1] = m end
        local res
        editor_ops.set_debug_adapter(ws, "c++", nil, function(ok, err) res = { ok, err } end)
        assert.same({ "set_adapter", { language = "c++" } }, { sent[1].method, sent[1].args })
        sent[1].cb({ outcome = "refused", message = "stale working copy", exit_code = 1 }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        vim.notify = orig
        assert.same({ false, "stale working copy" }, res)
        assert.truthy(notes[1]:find("stale working copy", 1, true))
        res = nil
        editor_ops.set_debug_adapter(ws, "c++", "cppdbg", function(ok) res = ok end)
        sent[2].cb({ outcome = "ok" }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        assert.is_true(res)
        -- Read again at once (and on the `changed` that follows).
        assert.equals("adapters", sent[3].method)
    end)

    it("a daemon without DebugConfig/1.set_adapter: in-process, noted", function()
        connect()
        local res
        editor_ops.set_debug_adapter(ws, "c++", "cppdbg", function(ok) res = ok end)
        sent[1].cb(nil, { code = "unknown_method", message = "no set_adapter" })
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        assert.is_true(res)
        assert.equals("cppdbg", require("loomworks.debug_config").resolve_adapter(ws, "c++"))
        assert.is_false(obs:can_call("set_adapter"))
        assert.truthy((obs.note or ""):find("debug adapters: daemon offers no loomworks.DebugConfig/1.set_adapter", 1, true))
    end)
end)
