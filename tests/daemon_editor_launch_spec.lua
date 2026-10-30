-- The editor's run and debug launches through the daemon's preparation
-- (spec §19.16 "Editor operations", §19.15 "Run" / "Debug" / "Build scope of
-- a launch"; step 5k part C2), and the debug adapters section on
-- `DebugConfig/1` (§19.20): against an observer whose connection is a
-- recording fake (no daemon). A non-device launch is a
-- `Launch/1.prepare_run` / `prepare_debug` the editor owns; its `done`
-- starts the program here (task runner / nvim-dap); not carried, declined,
-- degraded, refused, failed, or the connection lost after `accepted` → no
-- program, never run in-process (step 5s). A device target's launch is
-- `Launch/1.build`, then `Devices/1.install` and `launch`, its stop
-- `Devices/1.stop` (step 5n C2). A preparation's task-runner restart is not
-- sent again.

local observer = require("loomworks.daemon.observer")
local views = require("loomworks.views")
local editor_ops = require("loomworks.daemon.editor_ops")
local H = require("tests.daemon_helpers")

-- In `daemon` mode the editor holds no model (step 6b-alpha): a launch
-- target is a LaunchRef (a `Launch/1.targets` record of a profile row of
-- `view.Workspace/1`), addressed by ids (`rt` below).
describe("editor launches through the daemon's preparation (§19.16, step 5k C2)", function()
    local root, core, ws, profile, prow
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
            root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = feat or { operations = "available", launch = "available", ["debug adapters"] = "available",
                tasks = "subscribed" },
            _why = {}, _tasks = {}, _order = {}, _owned = {}, seq = 0,
            daemon = { pid = 1 },
            opts = { environ = function() return { PATH = "x" } end },
        }, observer.Observer)
        -- (The registry's first read on connecting, which the fake skips.)
        if o._feat.devices then o._devices = { list = {} } end
        require("loomworks.daemon.observer")._current = o
        observer._current = o
        -- The daemon's view of the workspace: the active profile's row.
        prow = { id = "p:1", key = profile.key, active = true, units = {} }
        views.set(o, "workspace", { profiles = { prow },
            projects = { { id = "pr:app", key = "app", type = "cmake" } } })
        return o
    end

    local function lt(name)
        return require("loomworks.launch_target").new(ws, profile, { project = "app", launch = name })
    end

    --- A launch target as the daemon-mode editor knows it (LaunchRef): a
    --- `Launch/1.targets` record of the profile row (`kind` default
    --- "launch"; a build target of a `ptype` project, default cmake: its
    --- debug adapter is checked before the call).
    local function rt(name, kind, ptype)
        return require("loomworks.daemon.launch_ref").new(prow,
            { kind = kind or "launch", project = { id = "pr:app", key = "app" }, name = name, label = name },
            { id = "pr:app", key = "app", type = ptype or "cmake" })
    end

    --- The project's declaration (`Projects/1.declaration`), which names the
    --- debug language of a target: the module's languages and the launch
    --- configurations' `debug` fields.
    local DECL = { outcome = "ok", module = { languages = { "c", "c++" } },
        launches = { { id = "l:multi", key = "multi", fields = { debug = { "typescript", "c++" } } } } }
    local function answer_declaration(i)
        assert.same({ "/projects", "loomworks.Projects", "declaration" }, { sent[i].object, sent[i].iface, sent[i].method })
        assert.same({ project = { id = "pr:app" } }, sent[i].args)
        sent[i].cb(vim.deepcopy(DECL), nil)
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
        ws._projects[1]:_sync_launches({
            run = { command = "tool", args = { "-v" } },
            multi = { command = "node", args = { "x.js" }, debug = { "typescript", "c++" } },
        })
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
        require("loomworks.device_log")._reset_for_tests()
        for i = #saved, 1, -1 do
            local s = saved[i]
            s[1][s[2]] = s[3]
        end
        if obs then
            views.clear(obs)
            observer._current = nil
            require("loomworks.daemon.observer")._selection = nil
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
        require("loomworks.session_tracker").start(rt("run"), "launch")
        assert.equals(1, #sent)
        local c = sent[1]
        assert.same({ "/launch", "loomworks.Launch", 1, "prepare_run" }, { c.object, c.iface, c.v, c.method })
        assert.same({ interactive = false, build_scope = "target", profile = { id = "p:1" },
            project = { id = "pr:app" }, target = "run", kind = "launch" }, c.args)
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

    it("a module target sends the project's id, its target id and kind", function()
        obs = fake_observer()
        local a = editor_ops.launch_args(rt("app", "target"))
        assert.same({ interactive = false, build_scope = "target", profile = { id = "p:1" },
            project = { id = "pr:app" }, target = "app", kind = "target" }, a)
    end)

    -- The profile's default target is addressed by its profile alone: the
    -- daemon then runs the profile's own default target, its `working_dir`
    -- override included (daemon_run_prepare_spec: "a run naming no target
    -- runs the profile's default target in its working_dir").
    it("the profile's default target is sent by its profile alone (target, project and kind omitted)", function()
        obs = fake_observer()
        local ref = require("loomworks.daemon.launch_ref").new(prow,
            { kind = "target", project = { id = "pr:app", key = "app" }, name = "app", label = "app", default = true },
            { id = "pr:app", key = "app", type = "cmake" })
        assert.same({ interactive = false, build_scope = "target", profile = { id = "p:1" } },
            editor_ops.launch_args(ref))
        assert.same({ interactive = false, profile = { id = "p:1" } }, editor_ops.target_build_args(ref))
        require("loomworks.session_tracker").start(ref, "launch")
        assert.equals(1, #sent)
        assert.same({ "/launch", "prepare_run" }, { sent[1].object, sent[1].method })
        assert.same({ interactive = false, build_scope = "target", profile = { id = "p:1" } }, sent[1].args)
    end)

    it("a debug is a Launch/1.prepare_debug; its `debug` goes to nvim-dap", function()
        obs = fake_observer()
        obs._debug_adapters = { languages = {
            { language = "c++", adapter = "codelldb" }, { language = "typescript", adapter = "pwa-node" } } }
        require("loomworks.session_tracker").start(rt("run"), "debug")
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
        obs._debug_adapters = { languages = {
            { language = "c++", adapter = "codelldb" }, { language = "typescript", adapter = "pwa-node" } } }
        require("loomworks.session_tracker").start(rt("multi"), "debug")
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
        obs._debug_adapters = { languages = { { language = "c", adapter = "codelldb" },
            { language = "c++", adapter = "codelldb" }, { language = "typescript", adapter = "pwa-node" } } }
        obs._feat.projects = "available"
        require("loomworks.debug").adapter_installed = function() return false end
        -- A build target: its module's primary language (c), from the
        -- project's declaration.
        require("loomworks.session_tracker").start(rt("app", "target"), "debug")
        assert.equals(1, #sent)
        answer_declaration(1)
        assert.is_true(vim.wait(2000, function() return noted("not configured. Install via :Mason") end, 10))
        assert.equals(1, #sent)
        vim.wait(100)
        assert.equals(0, #created)
    end)

    --- How many notifications contain `text`.
    local function count(text)
        local n = 0
        for _, x in ipairs(notes) do if x.msg:find(text, 1, true) then n = n + 1 end end
        return n
    end

    it("declined: the reason as one notification line, no program, nothing in-process", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(rt("run"), "launch")
        sent[1].cb({ outcome = "declined", reason = "another environment" }, nil)
        assert.is_true(vim.wait(2000, function() return noted("declined the launch (another environment)") end, 10))
        vim.wait(100)
        assert.equals(1, count("declined the launch"))
        assert.equals(1, #sent)
        assert.same({}, launched)
        assert.equals(0, #created)
        assert.same({}, titles)
    end)

    it("a daemon without prepare_run: refused with its Runtime-line note, not called again", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(rt("run"), "launch")
        sent[1].cb(nil, { code = "unknown_method", message = "no prepare_run" })
        local note = "launch: daemon offers no loomworks.Launch/1.prepare_run (no prepare_run)"
        assert.is_true(vim.wait(2000, function() return noted("launch: " .. note) end, 10))
        assert.is_false(obs:can_call("prepare_run"))
        assert.is_true(obs:can_call("prepare_debug"))
        assert.is_true(obs:can_call("build"))
        assert.truthy((obs.note or ""):find(note, 1, true))
        -- The next launch is refused at once.
        require("loomworks.session_tracker").start(rt("run"), "launch")
        vim.wait(100)
        assert.equals(2, count("launch: " .. note))
        assert.equals(1, #sent)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("no Launch/1 offered: refused with the feature's note, nothing built or run", function()
        obs = fake_observer({ operations = "available", tasks = "subscribed" })
        obs._why = { launch = "launch: daemon offers no loomworks.Launch" }
        assert.is_true(obs:can_call("build"))
        require("loomworks.session_tracker").start(rt("run"), "launch")
        vim.wait(100)
        assert.equals(1, count("loomworks: launch: launch: daemon offers no loomworks.Launch"))
        assert.same({}, sent)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("no connection: a launch is refused with the observer's note", function()
        obs = fake_observer()
        obs.state, obs.note = "no-binary", "no lw host binary (…) — running degraded"
        require("loomworks.session_tracker").start(rt("run"), "launch")
        require("loomworks.session_tracker").start(rt("run"), "debug")
        vim.wait(100)
        assert.equals(1, count("loomworks: launch: no lw host binary (…) — running degraded"))
        assert.equals(1, count("loomworks: debug launch: no lw host binary (…) — running degraded"))
        assert.same({}, sent)
        assert.same({}, launched)
        assert.same({}, dap_runs)
        assert.equals(0, #created)
    end)

    -- Step 5n C2 (§19.16 "Devices"): a device target's launch is the
    -- daemon's — Launch/1.build, then Devices/1.install and launch, each a
    -- task the editor owns, addressed by the profile alone; its stop is
    -- Devices/1.stop of the launch task. Nothing runs in the editor.
    it("a device target's launch is Launch/1.build, Devices/1.install and launch; stop is Devices/1.stop", function()
        obs = fake_observer({ operations = "available", launch = "available", tasks = "subscribed",
            devices = "subscribed", profiles = "available" })
        -- The profile's device: its view row's `device` (no registry read).
        prow.device = { id = "d-1", key = "SER1", label = "Phone", state = "online" }
        local t = rt("app", "device")
        local st = require("loomworks.session_tracker")
        st.start(t, "launch")
        assert.equals(1, #sent)
        assert.same({ "/launch", "build" }, { sent[1].object, sent[1].method })
        assert.is_nil(sent[1].args.target)
        assert.same({ id = "p:1" }, sent[1].args.profile)
        accept(1, "b1")
        done_frame("b1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        assert.same({ "/devices", "loomworks.Devices", "install" }, { sent[2].object, sent[2].iface, sent[2].method })
        assert.same({ profile = { id = "p:1" } }, sent[2].args)
        assert.same({ PATH = "x" }, sent[2].env)
        accept(2, "i1")
        done_frame("i1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        assert.same({ "/devices", "launch" }, { sent[3].object, sent[3].method })
        assert.same({ profile = { id = "p:1" } }, sent[3].args)
        accept(3, "l1")
        start_frame("l1", "launch")
        done_frame("l1", 0, { exit_code = 0, pid = 42, bundle = "com.x" })
        assert.is_true(vim.wait(2000, function() return st.is_running() end, 10))
        assert.equals("l1", st.active_run().device_task)
        -- Its device log: Launch/1.device_log of the launch task (step 5n
        -- C3), never streamed here.
        assert.equals(4, #sent)
        assert.same({ "/launch", "loomworks.Launch", "device_log" }, { sent[4].object, sent[4].iface, sent[4].method })
        assert.same({ task = "l1" }, sent[4].args)
        assert.same({ PATH = "x" }, sent[4].env)
        assert.equals(0, #created)
        assert.same({}, launched)
        st.stop()
        assert.equals(5, #sent)
        assert.same({ "/devices", "stop" }, { sent[5].object, sent[5].method })
        assert.same({ task = "l1" }, sent[5].args)
        sent[5].cb({ outcome = "ok" }, nil)
        assert.is_false(st.is_running())
    end)

    it("a device target without a chosen device: a Devices/1.scan task, then Profiles/1.set_device", function()
        obs = fake_observer({ operations = "available", launch = "available", tasks = "subscribed",
            devices = "subscribed", profiles = "available" })
        local selects = {}
        stub(vim.ui, "select", function(items, opts, cb) selects[#selects + 1] = { items = items, cb = cb } end)
        local t = rt("app", "device")
        require("loomworks.session_tracker").start(t, "launch")
        accept(1, "b2")
        done_frame("b2", 0, { exit_code = 0 })
        -- None chosen (the profile row names no device): a scan the editor
        -- owns, carrying its environment.
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        assert.same({ "/devices", "scan" }, { sent[2].object, sent[2].method })
        assert.same({ PATH = "x" }, sent[2].env)
        accept(2, "s1")
        done_frame("s1", 0, { exit_code = 0, devices = 2 })
        -- Then the registry read.
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        assert.equals("list", sent[3].method)
        sent[3].cb({ devices = { { id = "d-1", key = "SER1", label = "Phone", state = "online" },
            { id = "d-2", key = "SER2", label = "SER2", state = "offline" } } }, nil)
        assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
        assert.equals(1, #selects[1].items)
        selects[1].cb(selects[1].items[1])
        assert.is_true(vim.wait(2000, function() return #sent == 4 end, 10))
        assert.same({ "/profiles", "loomworks.Profiles", "set_device" },
            { sent[4].object, sent[4].iface, sent[4].method })
        assert.same({ profile = { id = "p:1" }, device = { id = "d-1" } }, sent[4].args)
        sent[4].cb({ outcome = "ok" }, nil)
        assert.is_true(vim.wait(2000, function() return #sent == 5 end, 10))
        assert.equals("install", sent[5].method)
        -- Nothing of it in the editor's model.
        assert.is_nil(profile:device_serial())
    end)

    it("a device target's launch the daemon cannot carry (no Devices/1) is refused before anything runs", function()
        obs = fake_observer()
        local t = rt("app", "device")
        require("loomworks.session_tracker").start(t, "launch")
        vim.wait(100)
        assert.same({}, sent)
        assert.is_true(noted("loomworks: launch: "))
        assert.same({}, titles)
    end)

    -- Step 5n C2 review fixes: the device run's chain, stop and disconnect.
    local DEVICE_FEAT = { operations = "available", launch = "available", tasks = "subscribed",
        devices = "subscribed", profiles = "available" }
    local function device_target() return rt("app", "device") end
    local function errors()
        local out = {}
        for _, n in ipairs(notes) do
            if n.level == vim.log.levels.ERROR then out[#out + 1] = n.msg end
        end
        return out
    end
    local function sent_method(method)
        for _, c in ipairs(sent) do if c.method == method then return c end end
        return nil
    end
    local SER1 = { id = "d-1", key = "SER1", label = "Phone", state = "online" }
    --- Start a device target's launch and run its build; `chosen`: the
    --- profile's row names its device (SER1; nil: none).
    local function device_built(chosen)
        if chosen then prow.device = { id = SER1.id, key = SER1.key, label = SER1.label, state = "online" } end
        local st = require("loomworks.session_tracker")
        local t = device_target()
        st.start(t, "launch")
        accept(1, "b1")
        done_frame("b1", 0, { exit_code = 0 })
        return st, t
    end
    --- A device run launched (its launch task `l1`).
    local function device_launched()
        local st, t = device_built(true)
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        accept(2, "i1")
        done_frame("i1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        accept(3, "l1")
        start_frame("l1", "launch")
        done_frame("l1", 0, { exit_code = 0, pid = 42 })
        assert.is_true(vim.wait(2000, function() return st.is_running() end, 10))
        return st, t
    end

    it("a device run is forgotten when its connection closes: no question, its stop sends nothing", function()
        obs = fake_observer(DEVICE_FEAT)
        local st = device_launched()
        -- The daemon forgot the launch with the connection (API.md §15).
        obs.conn:close()
        assert.is_false(st.is_running())
        assert.is_nil(st.active_run())
        st.stop()
        -- (Its device log's call, sent at the launch, is the fifth.)
        assert.equals(4, #sent)
        assert.equals("device_log", sent[4].method)
        assert.same({}, errors())
    end)

    it("a device run's stop the connection's close overtakes ends without an error", function()
        obs = fake_observer(DEVICE_FEAT)
        local st = device_launched()
        st.stop()
        assert.equals(5, #sent)
        assert.equals("stop", sent[5].method)
        obs.conn:close()
        sent[5].cb(nil, { code = "closed", message = "not connected" })
        vim.wait(100)
        assert.same({}, errors())
        assert.is_false(st.is_running())
    end)

    -- Step 5n C3 (API.md §9.5): the device run's log is a
    -- Launch/1.device_log task the editor owns; its records arrive as the
    -- `/launch` `log` signal of a Root subscription naming that task.
    local function view_lines() return require("loomworks.device_log")._lines_for_tests() end
    local function has_line(text)
        for _, l in ipairs(view_lines()) do
            if l:find(text, 1, true) then return true end
        end
        return false
    end
    local function log_signal(args)
        obs:_on_message({ kind = "signal", object = "/launch", iface = "loomworks.Launch", name = "log", args = args })
    end
    --- A device run launched, its device log accepted (task `g1`) and
    --- subscribed (`s1`).
    local function device_log_streaming()
        local st, t = device_launched()
        assert.equals("device_log", sent[4].method)
        accept(4, "g1")
        assert.is_true(vim.wait(2000, function() return #sent == 5 end, 10))
        assert.same({ "/", "loomworks.Root", "subscribe" }, { sent[5].object, sent[5].iface, sent[5].method })
        assert.same({ object = "/launch", iface = "loomworks.Launch", v = 1, signals = { "log" },
            args = { task = "g1" } }, sent[5].args)
        sent[5].cb({ sub_id = "s1", seq = 0 }, nil)
        assert.is_true(vim.wait(2000, function() return obs._log_subs.g1.sub_id == "s1" end, 10))
        return st, t
    end
    local function sent_call(object, method)
        for i, c in ipairs(sent) do
            if c.object == object and c.method == method then return c, i end
        end
        return nil
    end

    it("a device run's log streams the subscription's records into the view", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        device_log_streaming()
        assert.is_true(dl.is_running())
        assert.is_true(has_line("streamed by the workspace daemon"))
        log_signal({ task = "g1", records = {
            { ts = "10-19 12:00:00.001", level = "info", tag = "T", pid = 42, message = "hi",
                fields = { proc = "com.x" } },
            { level = "info", message = "raw" } } })
        assert.is_true(has_line("hi"))
        assert.is_true(has_line("[UNPARSED] raw"))
        -- Another task's records are not this view's.
        log_signal({ task = "other", records = { { level = "info", message = "not mine" } } })
        assert.is_false(has_line("not mine"))
        assert.same({}, errors())
    end)

    it("a device log's `start` meta level sets the new view's level filter", function()
        obs = fake_observer(DEVICE_FEAT)
        device_log_streaming()
        obs:_on_task({ kind = "task", task_id = "g1", phase = "start",
            meta = { kind = "device_log", name = "log", level = "warn" } })
        log_signal({ task = "g1", records = {
            { ts = "10-19 12:00:00.001", level = "info", tag = "T", pid = 1, message = "lowinfo" },
            { ts = "10-19 12:00:00.002", level = "warn", tag = "T", pid = 1, message = "highwarn" } } })
        assert.is_true(has_line("highwarn"))
        assert.is_false(has_line("lowinfo"))
    end)

    it("records the daemon dropped are a gap line in the view", function()
        obs = fake_observer(DEVICE_FEAT)
        device_log_streaming()
        log_signal({ task = "g1", dropped = 3, records = { { level = "info", message = "after" } } })
        assert.is_true(has_line("… 3 records dropped"))
        assert.is_true(has_line("after"))
    end)

    it("closing the view cancels the device log and drops its subscription; reopening starts a new one", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        local st = device_log_streaming()
        dl.hide()
        local unsub = sent_call("/", "unsubscribe")
        assert.is_not_nil(unsub)
        assert.same({ sub_id = "s1" }, unsub.args)
        local cancel = sent_call("/tasks", "cancel")
        assert.is_not_nil(cancel)
        assert.same({ task_id = "g1" }, cancel.args)
        assert.is_false(dl.is_running())
        assert.is_true(st.is_running())
        -- Nothing more reaches the view from it.
        log_signal({ task = "g1", records = { { level = "info", message = "late" } } })
        assert.is_false(has_line("late"))
        -- Reopened while the run is active: a new device_log of the launch.
        local n = #sent
        dl.toggle()
        assert.is_true(vim.wait(2000, function() return #sent == n + 1 end, 10))
        assert.equals("device_log", sent[n + 1].method)
        assert.same({ task = "l1" }, sent[n + 1].args)
        assert.is_true(dl.is_running())
        assert.same({}, errors())
    end)

    it("reopening the view after the run was dropped (its connection gone) only shows it", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        local st = device_log_streaming()
        dl.hide()
        assert.is_false(dl.is_visible())
        -- The run is forgotten with its connection; active_run() drops it.
        obs.conn:close()
        assert.is_nil(st.active_run())
        local n = #sent
        dl.toggle()
        assert.is_true(dl.is_visible())
        vim.wait(100)
        assert.equals(n, #sent)
        assert.is_false(dl.is_running())
    end)

    it("a device log accepted after its connection was replaced subscribes on neither", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        device_launched()
        assert.equals("device_log", sent[4].method)
        -- A reconnect's new connection: the old one's task is not its.
        local fresh = { transport = 11, closed = false }
        local on_fresh = {}
        function fresh.call(_, object, iface, v, method, args, cb)
            on_fresh[#on_fresh + 1] = { object = object, method = method, args = args, cb = cb }
        end
        obs.conn.closed = true
        obs.conn = fresh
        sent[4].cb({ outcome = "accepted", task_id = "g1" }, nil)
        vim.wait(200)
        assert.same({}, on_fresh)
        assert.is_nil(sent_call("/", "subscribe"))
        assert.is_true(obs._log_subs == nil or obs._log_subs.g1 == nil)
        assert.is_false(dl.is_running())
        assert.is_true(has_line("device log stream ended: the workspace daemon disconnected"),
            table.concat(view_lines(), "\n"))
        assert.same({}, errors())
    end)

    it("a refused subscribe ends the view with its message once, no error notification", function()
        obs = fake_observer(DEVICE_FEAT)
        device_launched()
        accept(4, "g1")
        assert.is_true(vim.wait(2000, function() return #sent == 5 end, 10))
        sent[5].cb(nil, { code = "invalid_args", message = "nope" })
        assert.is_true(vim.wait(2000, function()
            return has_line("device log stream ended: could not subscribe to the device log: nope")
        end, 10))
        assert.same({}, errors())
        assert.equals("cancel", sent[6].method)
    end)

    it("a closed connection drops its log subscriptions", function()
        obs = fake_observer(DEVICE_FEAT)
        device_log_streaming()
        obs:_on_closed(obs.conn)
        assert.is_nil(obs._log_subs)
    end)

    it("stopping the run cancels its device log", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        local st = device_log_streaming()
        st.stop()
        local cancel = sent_call("/tasks", "cancel")
        assert.is_not_nil(cancel)
        assert.same({ task_id = "g1" }, cancel.args)
        assert.is_not_nil(sent_call("/", "unsubscribe"))
        assert.is_not_nil(sent_call("/devices", "stop"))
        assert.is_false(dl.is_running())
    end)

    it("the device log's end is the view's last line; the view stays", function()
        obs = fake_observer(DEVICE_FEAT)
        local dl = require("loomworks.device_log")
        device_log_streaming()
        done_frame("g1", 0)
        assert.is_true(vim.wait(2000, function() return has_line("device log stream ended ──") end, 10))
        assert.is_false(dl.is_running())
        assert.is_true(dl.is_visible())
        assert.same({ sub_id = "s1" }, sent_call("/", "unsubscribe").args)
        -- Ended on its own: reopening only shows the view.
        dl.hide()
        local n = #sent
        dl.toggle()
        vim.wait(100)
        assert.equals(n, #sent)
    end)

    it("a failing device log ends with its error in the view", function()
        obs = fake_observer(DEVICE_FEAT)
        device_log_streaming()
        done_frame("g1", 1, nil, "boom")
        assert.is_true(vim.wait(2000, function() return has_line("device log stream ended: boom") end, 10))
    end)

    it("a device target without a device whose choice the daemon cannot carry is refused before the build", function()
        local feat = vim.tbl_extend("force", {}, DEVICE_FEAT)
        feat.profiles = nil
        obs = fake_observer(feat)
        obs._devices = { list = { SER1 } }
        require("loomworks.session_tracker").start(device_target(), "launch")
        vim.wait(100)
        assert.same({}, sent)
        assert.is_true(noted("loomworks: launch: "))
        assert.same({}, titles)
    end)

    it("a device target without a device whose scan is degraded is refused before the build", function()
        obs = fake_observer(DEVICE_FEAT)
        obs._devices = { list = {} }
        obs._degraded = { device_scan = true }
        require("loomworks.session_tracker").start(device_target(), "launch")
        vim.wait(100)
        assert.same({}, sent)
        assert.is_true(noted("loomworks: launch: "))
    end)

    it("a device target with a device needs no scan or choice: not refused without them", function()
        local feat = vim.tbl_extend("force", {}, DEVICE_FEAT)
        feat.profiles = nil
        obs = fake_observer(feat)
        -- The profile row names its device.
        prow.device = vim.tbl_extend("force", {}, SER1)
        require("loomworks.session_tracker").start(device_target(), "launch")
        assert.equals(1, #sent)
        assert.equals("build", sent[1].method)
    end)

    it("a failed list read after a scan is its error, not \"no online devices\"", function()
        obs = fake_observer(DEVICE_FEAT)
        device_built(false)
        -- SER1 not chosen: a scan.
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        assert.equals("scan", sent[2].method)
        accept(2, "s1")
        done_frame("s1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        assert.equals("list", sent[3].method)
        sent[3].cb(nil, { code = "internal", message = "boom" })
        assert.is_true(vim.wait(2000, function() return #errors() > 0 end, 10))
        assert.is_false(noted("no online devices found"))
        assert.truthy(errors()[1]:find("boom", 1, true), errors()[1])
    end)

    it("a stop during a device run's scan cancels the scan task", function()
        obs = fake_observer(DEVICE_FEAT)
        local st = device_built(false)
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        accept(2, "s1")
        st.stop()
        assert.is_true(vim.wait(2000, function() return sent_method("cancel") ~= nil end, 10))
        local cancel = sent_method("cancel")
        assert.same({ task_id = "s1" }, cancel.args)
        done_frame("s1", 1, { exit_code = 1 })
        vim.wait(100)
        assert.same({}, errors())
        assert.is_nil(sent_method("install"))
    end)

    it("a stop while the device picker is open ends the chain", function()
        obs = fake_observer(DEVICE_FEAT)
        local selects = {}
        stub(vim.ui, "select", function(items, _, cb) selects[#selects + 1] = { items = items, cb = cb } end)
        local st = device_built(false)
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        accept(2, "s1")
        done_frame("s1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        sent[3].cb({ devices = { SER1 } }, nil)
        assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
        st.stop()
        selects[1].cb(selects[1].items[1])
        vim.wait(100)
        assert.equals(3, #sent)
        assert.is_false(st.is_running())
        -- Nothing left preparing: a new launch does not ask.
        st.start(device_target(), "launch")
        assert.equals(1, #selects)
    end)

    it("a refused set_device ends the chain with its message; nothing installed", function()
        obs = fake_observer(DEVICE_FEAT)
        local selects = {}
        stub(vim.ui, "select", function(items, _, cb) selects[#selects + 1] = { items = items, cb = cb } end)
        local st = device_built(false)
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        accept(2, "s1")
        done_frame("s1", 0, { exit_code = 0 })
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        sent[3].cb({ devices = { SER1 } }, nil)
        assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
        selects[1].cb(selects[1].items[1])
        assert.is_true(vim.wait(2000, function() return #sent == 4 end, 10))
        assert.equals("set_device", sent[4].method)
        sent[4].cb({ outcome = "refused", message = "unknown device d-1" }, nil)
        assert.is_true(vim.wait(2000, function() return #errors() > 0 end, 10))
        assert.equals("loomworks: device choice: unknown device d-1", errors()[1])
        vim.wait(100)
        assert.equals(4, #sent)
        assert.is_false(st.is_running())
        st.start(device_target(), "launch")
        assert.equals(1, #selects)
    end)

    it("a disconnected editor refuses a device target's launch with the Runtime status", function()
        obs = fake_observer()
        obs.state, obs.note = "waiting", "waiting for the workspace daemon (connecting)"
        local t = rt("run")
        t.requires_device = function() return true end
        require("loomworks.session_tracker").start(t, "launch")
        vim.wait(100)
        assert.equals(1, count("loomworks: launch: waiting for the workspace daemon (connecting)"))
        assert.same({}, sent)
        assert.same({}, launched)
        assert.equals(0, #created)
        assert.same({}, titles)
    end)

    it("the connection lost after `accepted`: no program, never re-run in-process", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(rt("run"), "launch")
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
        require("loomworks.session_tracker").start(rt("run"), "launch")
        accept(1, "r2")
        start_frame("r2", "run")
        done_frame("r2", 1, { exit_code = 1, error = "build failed" }, "build failed")
        assert.is_true(vim.wait(2000, function() return noted("build failed") end, 10))
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("refused: its message once, no program", function()
        obs = fake_observer()
        require("loomworks.session_tracker").start(rt("run"), "launch")
        sent[1].cb({ outcome = "refused", message = "workspace not trusted", exit_code = 1 }, nil)
        assert.is_true(vim.wait(2000, function() return noted("workspace not trusted") end, 10))
        vim.wait(100)
        local n = 0
        for _, x in ipairs(notes) do if x.msg:find("workspace not trusted", 1, true) then n = n + 1 end end
        assert.equals(1, n)
        assert.same({}, launched)
        assert.equals(0, #created)
    end)

    it("a `device` result (foreign artifact) is refused: no program, nothing continues here (§18.11)", function()
        obs = fake_observer()
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        accept(1, "r3")
        done_frame("r3", 0, { exit_code = 0, device = true })
        assert.is_true(vim.wait(2000, function()
            return noted("app: run runs on a device: the editor does not execute foreign targets (spec §18.11); "
                .. "run it with lw run")
        end, 10))
        vim.wait(100)
        assert.same({}, launched)
        assert.equals(0, #created)
        assert.equals(1, #sent)
        assert.is_false(st.is_running())
    end)

    --- The `Tasks/1.cancel` calls sent for task `id`.
    local function cancels(id)
        local n = 0
        for _, c in ipairs(sent) do
            if c.method == "cancel" and c.args and c.args.task_id == id then n = n + 1 end
        end
        return n
    end

    it("a stop while the daemon prepares cancels its task; no program starts", function()
        obs = fake_observer()
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        accept(1, "r5")
        start_frame("r5", "run")
        st.stop()
        assert.is_true(vim.wait(2000, function() return cancels("r5") == 1 end, 10))
        assert.is_false(noted("no running session"))
        -- The daemon finished it anyway: still no program.
        done_frame("r5", 0, { exit_code = 0, launch = { name = "app: run", cmd = "/bin/tool", args = {} } })
        vim.wait(200)
        assert.same({}, launched)
        assert.equals(0, #created)
        -- Nothing is preparing any more.
        st.stop()
        assert.is_true(noted("no running session"))
    end)

    it("a stop before the preparation is accepted cancels it once accepted", function()
        obs = fake_observer()
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        st.stop()
        assert.equals(0, cancels("r6"))
        accept(1, "r6")
        assert.is_true(vim.wait(2000, function() return cancels("r6") == 1 end, 10))
        done_frame("r6", 0, { exit_code = 0, launch = { name = "app: run", cmd = "/bin/tool", args = {} } })
        vim.wait(200)
        assert.same({}, launched)
    end)

    it("a second launch while the daemon prepares asks, then replaces the first", function()
        obs = fake_observer()
        local prompts = {}
        stub(vim.ui, "select", function(_, opts, on_choice)
            prompts[#prompts + 1] = opts.prompt
            on_choice("Yes")
        end)
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        accept(1, "r7")
        st.start(rt("run"), "launch")
        assert.equals(1, #prompts)
        assert.truthy(prompts[1]:find("Preparing 'app: run'", 1, true))
        assert.is_true(vim.wait(2000, function() return cancels("r7") == 1 end, 10))
        local second
        for i, c in ipairs(sent) do if c.method == "prepare_run" and i > 1 then second = i end end
        assert.is_not_nil(second)
        -- The first one's result never starts a program.
        done_frame("r7", 0, { exit_code = 0, launch = { name = "first", cmd = "/bin/first", args = {} } })
        accept(second, "r8")
        done_frame("r8", 0, { exit_code = 0, launch = { name = "second", cmd = "/bin/second", args = {} } })
        assert.is_true(vim.wait(2000, function() return #launched == 1 end, 10))
        vim.wait(100)
        assert.equals(1, #launched)
        assert.equals("/bin/second", launched[1].cmd)
    end)

    it("a second launch while the daemon prepares, answered No: the first goes on", function()
        obs = fake_observer()
        stub(vim.ui, "select", function(_, _, on_choice) on_choice("No") end)
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        accept(1, "r9a")
        st.start(rt("run"), "launch")
        assert.equals(0, cancels("r9a"))
        assert.equals(1, #sent)
        done_frame("r9a", 0, { exit_code = 0, launch = { name = "first", cmd = "/bin/first", args = {} } })
        assert.is_true(vim.wait(2000, function() return #launched == 1 end, 10))
    end)

    it("a failure before `accepted`: noted, no program, nothing left preparing", function()
        obs = fake_observer()
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        sent[1].cb(nil, { code = "closed", message = "closed" })
        assert.is_true(vim.wait(2000, function() return noted("the workspace daemon disconnected") end, 10))
        vim.wait(100)
        assert.same({}, launched)
        assert.equals(0, #created)
        st.stop()
        assert.is_true(noted("no running session"))
    end)

    it("an error starting the prepared program is notified and fails its progress entry", function()
        obs = fake_observer()
        local cancelled = {}
        stub(require("loomworks.fidget"), "start_action", function(title)
            titles[#titles + 1] = title
            return { report = function() end, finish = function() end,
                cancel = function() cancelled[#cancelled + 1] = title end }
        end)
        stub(require("loomworks.overseer"), "launch_run_task", function() error("task runner exploded") end)
        local st = require("loomworks.session_tracker")
        st.start(rt("run"), "launch")
        accept(1, "r10")
        done_frame("r10", 0, { exit_code = 0, launch = { name = "app: run", cmd = "/bin/tool", args = {} } })
        assert.is_true(vim.wait(2000, function() return noted("task runner exploded") end, 10))
        assert.same({ "Launching app: run" }, cancelled)
        assert.is_false(st.is_running())
    end)

    it("a build target's debug checks the adapter the daemon's mapping names for its module's language", function()
        obs = fake_observer()
        obs._feat.projects = "available"
        require("loomworks.session_tracker").start(rt("app", "target"), "debug")
        -- Nothing cached yet: the mapping is read first, then the declaration.
        assert.equals(1, #sent)
        assert.equals("adapters", sent[1].method)
        sent[1].cb({ languages = { { language = "c", adapter = "codelldb" } } }, nil)
        assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
        answer_declaration(2)
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        assert.equals("prepare_debug", sent[3].method)
        assert.is_false(noted("not configured"))
    end)

    it("a debug whose daemon-mapped adapter is not installed stops with the hint", function()
        obs = fake_observer()
        obs._debug_adapters = { languages = { { language = "c", adapter = "gdb" } } }
        obs._feat.projects = "available"
        require("loomworks.session_tracker").start(rt("app", "target"), "debug")
        answer_declaration(1)
        assert.is_true(vim.wait(2000, function() return noted("not configured. Install via :Mason") end, 10))
        assert.equals(1, #sent)
    end)

    it("a launch configuration's debug checks its first `debug` language's adapter (its declaration)", function()
        obs = fake_observer()
        obs._debug_adapters = { languages = { { language = "typescript", adapter = "pwa-node" } } }
        obs._feat.projects = "available"
        require("loomworks.debug").adapter_installed = function() return false end
        require("loomworks.session_tracker").start(rt("multi"), "debug")
        answer_declaration(1)
        assert.is_true(vim.wait(2000, function() return noted("not configured. Install via :Mason") end, 10))
        assert.is_true(noted("pwa-node"))
        assert.equals(1, #sent)
    end)

    it("the project's declaration not carried: no check before the call, the daemon prepares", function()
        obs = fake_observer()
        obs._debug_adapters = { languages = { { language = "c", adapter = "gdb" } } }
        require("loomworks.session_tracker").start(rt("app", "target"), "debug")
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        assert.equals("prepare_debug", sent[1].method)
        assert.is_false(noted("not configured"))
    end)

    it("DebugConfig/1 not carried: no adapter check from the editor's mapping; the daemon prepares", function()
        obs = fake_observer({ operations = "available", launch = "available", tasks = "subscribed" })
        require("loomworks.debug").adapter_installed = function() return false end
        require("loomworks.session_tracker").start(rt("run"), "debug")
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        assert.equals("prepare_debug", sent[1].method)
        assert.is_false(noted("not configured"))
    end)

    it("a language the daemon's records do not name is not resolved from the editor's mapping", function()
        obs = fake_observer()
        obs._debug_adapters = { languages = { { language = "c++", adapter = "codelldb" } } }
        require("loomworks.debug").adapter_installed = function(a) return a == "codelldb" end
        -- `multi` launches typescript first: the daemon's records do not name it.
        require("loomworks.session_tracker").start(rt("multi"), "debug")
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        assert.equals("prepare_debug", sent[1].method)
        assert.is_false(noted("not configured"))
    end)

    it("a failed `adapters` read is remembered: not sent again until `changed`", function()
        obs = fake_observer()
        assert.is_nil(obs:debug_adapters())
        assert.equals(1, #sent)
        sent[1].cb(nil, { code = "internal", message = "boom" })
        assert.is_true(vim.wait(2000, function() return obs._debug_fetch == nil end, 10))
        assert.is_nil(obs:debug_adapters())
        assert.is_nil(obs:debug_adapters())
        assert.equals(1, #sent)
        -- A debug is then sent unchecked (debug.run checks the prepared adapter).
        require("loomworks.session_tracker").start(rt("run"), "debug")
        assert.equals(2, #sent)
        assert.equals("prepare_debug", sent[2].method)
        -- A model change reads it again.
        obs:_refetch_debug_adapters()
        assert.equals(3, #sent)
        assert.equals("adapters", sent[3].method)
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
        require("loomworks.daemon.observer")._current, require("loomworks.daemon.observer")._selection = nil, nil
        pcall(function() core:shutdown() end)
    end)

    local function connect(feat)
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb)
            sent[#sent + 1] = { object = object, iface = iface, method = method, args = args, cb = cb }
        end
        obs = setmetatable({
            root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = feat or { ["debug adapters"] = "available" }, _why = {}, _tasks = {}, _order = {},
            _owned = {}, seq = 0, generation = 1, daemon = { pid = 1 },
            opts = { environ = function() return {} end },
        }, observer.Observer)
        function obs:_emit(e) emitted[#emitted + 1] = e end
        require("loomworks.daemon.observer")._current = obs
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

    it("carried: read from `adapters` (never the in-process mapping), re-read on `changed`", function()
        connect()
        -- The first read is in flight: nothing meanwhile, and why.
        local recs, why = editor_ops.debug_adapters(nil)
        assert.is_nil(recs)
        assert.equals("reading them from the workspace daemon", why)
        assert.equals(1, #sent)
        assert.same({ "/debug", "loomworks.DebugConfig", "adapters" }, { sent[1].object, sent[1].iface, sent[1].method })
        editor_ops.debug_adapters(nil)
        assert.equals(1, #sent) -- single flight
        sent[1].cb({ languages = { REC } }, nil)
        assert.is_true(vim.wait(2000, function() return #emitted > 0 end, 10))
        assert.equals("daemon_debug_adapters", emitted[1])
        assert.same({ REC }, editor_ops.debug_adapters(nil))
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
        editor_ops.set_debug_adapter(nil, "c++", nil, function(ok, err) res = { ok, err } end)
        assert.same({ "set_adapter", { language = "c++" } }, { sent[1].method, sent[1].args })
        sent[1].cb({ outcome = "refused", message = "stale working copy", exit_code = 1 }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        vim.notify = orig
        assert.same({ false, "stale working copy" }, res)
        assert.truthy(notes[1]:find("stale working copy", 1, true))
        res = nil
        editor_ops.set_debug_adapter(nil, "c++", "cppdbg", function(ok) res = ok end)
        sent[2].cb({ outcome = "ok" }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        assert.is_true(res)
        -- Read again at once (and on the `changed` that follows).
        assert.equals("adapters", sent[3].method)
    end)

    it("in-process: the debug languages are every known language, not only the modules'", function()
        local langs
        editor_ops.debug_languages(ws, function(l) langs = l end)
        assert.same(require("loomworks.debug_config").workspace_languages(ws), langs)
        assert.truthy(vim.tbl_contains(langs, "typescript"))
        assert.same({}, sent)
    end)

    it("carried: the debug languages are `known_languages` (never the in-process list)", function()
        connect()
        local res
        editor_ops.debug_languages(nil, function(l, why) res = { l, why } end)
        assert.same({ "/debug", "loomworks.DebugConfig", "known_languages" },
            { sent[1].object, sent[1].iface, sent[1].method })
        sent[1].cb({ outcome = "ok", languages = { "c++", "zig" } }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        assert.same({ "c++", "zig" }, res[1])
        -- Declined: no languages, and why.
        res = nil
        editor_ops.debug_languages(nil, function(l, why) res = { l, why } end)
        sent[2].cb({ outcome = "declined", reason = "the workspace runtime is stopping" }, nil)
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        assert.is_nil(res[1])
        assert.truthy(res[2]:find("declined", 1, true))
    end)

    it("the launch editor's Add debug language offers every known language, not only the records'", function()
        local View = require("loomworks.ui.view")
        local tree
        local orig_new = View.new
        View.new = function(vopts)
            tree = vopts.widget
            return { open = function() end, close = function() end, refresh = function() end }
        end
        local ok, err = pcall(require("loomworks.ui.launch_editor").open, {
            title = "Edit", name = "run", command = "", args = {}, working_dir = "", env = {},
            projects = {}, profiles = {}, debug = { "c++" },
            -- The records: only the workspace modules' languages.
            debug_adapters = function() return { REC } end,
            debug_languages = function(cb) cb({ "c", "c++", "typescript" }) end,
            on_accept = function() end, on_cancel = function() end,
        })
        View.new = orig_new
        assert(ok, err)
        local offered
        local orig_select = vim.ui.select
        vim.ui.select = function(items) offered = items end
        local ok2, err2 = pcall(function()
            local lines = tree:render()
            local row
            for i, l in ipairs(lines) do
                if l:find("Add debug language", 1, true) and tree.line_meta[i] then row = i end
            end
            assert(row, table.concat(lines, "\n"))
            tree.line_meta[row].on_enter()
        end)
        vim.ui.select = orig_select
        assert(ok2, err2)
        assert.same({ "c", "typescript" }, offered)
    end)

    it("the launch editor shows a debug language with no adapter record as resolved at launch", function()
        local View = require("loomworks.ui.view")
        local tree
        local orig_new = View.new
        View.new = function(vopts)
            tree = vopts.widget
            return { open = function() end, close = function() end, refresh = function() end }
        end
        local ok, err = pcall(require("loomworks.ui.launch_editor").open, {
            title = "Edit", name = "run", command = "", args = {}, working_dir = "", env = {},
            projects = {}, profiles = {}, debug = { "c++", "typescript" },
            -- The records cover only the workspace modules' languages: no typescript.
            debug_adapters = function() return { REC } end,
            on_accept = function() end, on_cancel = function() end,
        })
        View.new = orig_new
        assert(ok, err)
        local text = table.concat(tree:render(), "\n")
        assert.truthy(text:find("c++ (primary) → cppdbg", 1, true), text)
        assert.truthy(text:find("typescript (attach)  → (resolved at launch)", 1, true), text)
        assert.is_nil(text:find("→ ?", 1, true), text)
    end)

    it("a daemon without DebugConfig/1.set_adapter: the write fails, noted; nothing in-process", function()
        connect()
        local orig = vim.notify
        local notes = {}
        vim.notify = function(m) notes[#notes + 1] = m end
        local before = require("loomworks.debug_config").resolve_adapter(ws, "c++")
        local res
        editor_ops.set_debug_adapter(nil, "c++", "cppdbg", function(ok, err) res = { ok, err } end)
        sent[1].cb(nil, { code = "unknown_method", message = "no set_adapter" })
        assert.is_true(vim.wait(2000, function() return res ~= nil end, 10))
        local note = "debug adapters: daemon offers no loomworks.DebugConfig/1.set_adapter (no set_adapter)"
        assert.same({ false, note }, res)
        assert.equals(before, require("loomworks.debug_config").resolve_adapter(ws, "c++"))
        assert.is_false(obs:can_call("set_adapter"))
        assert.truthy((obs.note or ""):find(note, 1, true))
        -- The next write fails at once, nothing sent.
        res = nil
        editor_ops.set_debug_adapter(nil, "c++", "cppdbg", function(ok, err) res = { ok, err } end)
        vim.notify = orig
        assert.same({ false, note }, res)
        assert.equals(1, #sent)
        assert.equals(2, #notes)
        assert.truthy(notes[2]:find("debug adapter not saved: " .. note, 1, true))
    end)

    it("a failed or declined `adapters` read re-renders the section with why", function()
        connect()
        assert.is_nil(editor_ops.debug_adapters(nil))
        sent[1].cb(nil, { code = "internal", message = "boom" })
        assert.is_true(vim.wait(2000, function() return #emitted > 0 end, 10))
        assert.equals("daemon_debug_adapters", emitted[1])
        local recs, why = editor_ops.debug_adapters(nil)
        assert.is_nil(recs)
        assert.equals("the workspace daemon did not answer DebugConfig/1.adapters", why)
        obs:_refetch_debug_adapters()
        sent[2].cb({ outcome = "declined", reason = "trust" }, nil)
        assert.is_true(vim.wait(2000, function() return #emitted > 1 end, 10))
        assert.equals("daemon_debug_adapters", emitted[2])
    end)

    it("not carried: the section is unavailable with the observer's note; writes fail", function()
        connect({})
        obs._why = { ["debug adapters"] = "debug adapters: daemon offers no loomworks.DebugConfig" }
        local recs, why = editor_ops.debug_adapters(nil)
        assert.is_nil(recs)
        assert.equals("debug adapters: daemon offers no loomworks.DebugConfig", why)
        local orig = vim.notify
        local notes = {}
        vim.notify = function(m) notes[#notes + 1] = m end
        local res
        editor_ops.set_debug_adapter(nil, "c++", "cppdbg", function(ok, err) res = { ok, err } end)
        -- Declined, too: fails with the reason.
        obs._feat = { ["debug adapters"] = "available" }
        local res2
        editor_ops.set_debug_adapter(nil, "c++", "cppdbg", function(ok, err) res2 = { ok, err } end)
        sent[#sent].cb({ outcome = "declined", reason = "trust" }, nil)
        assert.is_true(vim.wait(2000, function() return res2 ~= nil end, 10))
        vim.notify = orig
        assert.same({ false, "debug adapters: daemon offers no loomworks.DebugConfig" }, res)
        assert.same({ false, "the workspace daemon declined it (trust)" }, res2)
        assert.equals(2, #notes)
        -- The status page's section says so.
        local Tree = require("loomworks.ui.tree")
        local tree = Tree.new(function(t)
            require("loomworks.ui.sections.debug")(t, { lw = { get_workspace = function() return nil end } })
        end)
        obs._feat = {}
        local lines = tree:render()
        assert.truthy(table.concat(lines, "\n"):find(
            "unavailable — debug adapters: daemon offers no loomworks.DebugConfig", 1, true), table.concat(lines, "\n"))
    end)
end)
