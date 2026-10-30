-- The build of a launch target through the daemon (spec §19.16 "Editor
-- operations", §19.15 "Build of a launch target" / "Steps of a task"; step
-- 5t part C): against an observer whose connection is a recording fake (no
-- daemon). A non-device launch target's build is ONE `Launch/1.build` the
-- editor owns — no dependency build, deploy or fallback in the editor; the
-- artifact-conflict question is asked before the call (and before a
-- preparation's), its Yes sent as `force`; the task's progress entry, its
-- status row and its task-runner row follow the current step from
-- `TaskInfo.steps` / `start.meta.steps` and the `Tasks/1.step` signal (a seq
-- gap re-reads `Tasks/1.list`). A device target's build is the same call
-- (step 5n C2, §19.16 "Devices"), addressed by its profile alone.

local observer = require("loomworks.daemon.observer")
local editor_ops = require("loomworks.daemon.editor_ops")
local H = require("tests.daemon_helpers")

-- TODO(A1b): the daemon-mode cases below drive the routing from model
-- objects (Profile, ConfigUnit, LaunchTarget), which the `daemon`-mode editor
-- no longer holds (step 6b-alpha A1a: it loads no workspace). They are
-- pending until the facade acts by calls and view-row ids (A1b), which
-- restores them on that path.
describe("a launch target's build through the daemon (§19.16, step 5t C)", function()
    local root, core, ws, profile
    local obs, sent, created, notes, selects, events
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
        require("loomworks.daemon.observer")._current = o
        observer._current = o
        return o
    end

    local function lt(name)
        return require("loomworks.launch_target").new(ws, profile, { project = "app", launch = name })
    end

    local function stub(mod, key, fn)
        saved[#saved + 1] = { mod, key, mod[key] }
        mod[key] = fn
    end

    local function accept(i, id)
        sent[i].cb({ outcome = "accepted", task_id = id }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned[id] ~= nil end, 10))
    end

    local STEPS = {
        { id = "s1", kind = "build", label = "dependency lib", project = "lib", state = "pending" },
        { id = "s2", kind = "deploy", label = "deploy (pre_build)", project = "app", phase = "pre_build",
            state = "pending" },
        { id = "s3", kind = "build", label = "app: run", project = "app", configuration = "Debug",
            state = "pending" },
    }

    local function start_frame(id, steps)
        obs:_on_task({ kind = "task", task_id = id, phase = "start",
            meta = { name = profile.key, kind = "build", profile = profile.key, steps = steps } })
    end
    local function done_frame(id, code, err)
        obs:_on_task({ kind = "task", task_id = id, phase = "done", exit_code = code, error = err,
            result = { exit_code = code } })
    end
    local function step_signal(id, seq, index, state, err)
        obs:_on_message({ kind = "signal", object = "/tasks", iface = "loomworks.Tasks", v = 1, name = "step",
            seq = seq, args = { task_id = id, seq = seq, index = index, state = state, error = err } })
    end

    local function noted(text)
        for _, n in ipairs(notes) do
            if n.msg:find(text, 1, true) then return true end
        end
        return false
    end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        profile = ws:get_profiles()[1]
        ws._projects[1]:_sync_launches({ run = { command = "tool", args = { "-v" } } })
        sent, created, notes, selects, events = {}, {}, {}, {}, {}
        saved = {}
        stub(package.loaded, "overseer", {
            new_task = function(spec)
                local t = { id = 1000 + #created, name = spec.name, subscribe = function() end,
                    start = function() end, stop = function() end, is_complete = function() return false end,
                    is_disposed = function() return false end, dispose = function() end }
                created[#created + 1] = t
                return t
            end,
        })
        stub(package.loaded, "overseer.task_list", { get = function() return nil end, touch = function() end })
        stub(require("loomworks.overseer"), "launch_run_task", function() return 77 end)
        stub(vim, "notify", function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end)
        stub(vim.ui, "select", function(items, opts, cb)
            selects[#selects + 1] = { items = items, prompt = opts and opts.prompt, cb = cb }
        end)
        local lw = require("loomworks")
        for _, ev in ipairs({ "daemon_task_started", "daemon_task_step", "daemon_task_stopped" }) do
            lw.on(ev, function(data) events[#events + 1] = { name = ev, task = data.task } end)
        end
    end)

    after_each(function()
        pcall(function() require("loomworks.session_tracker").stop() end)
        for i = #saved, 1, -1 do
            local s = saved[i]
            s[1][s[2]] = s[3]
        end
        if obs then
            observer._current = nil
            require("loomworks.daemon.observer")._selection = nil
        end
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    pending("a non-device target's build is one Launch/1.build the editor owns; nothing runs here", function()
        obs = fake_observer()
        local t = lt("run")
        local deployed = 0
        t._deploy_phase = function()
            deployed = deployed + 1
            return require("loomworks.future").resolved(true)
        end
        local ok
        t:build():next(function() ok = true end):catch(function(e) ok = e end)
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        local c = sent[1]
        assert.same({ "/launch", "loomworks.Launch", 1, "build" }, { c.object, c.iface, c.v, c.method })
        assert.same({ interactive = false, profile = { key = profile.key }, project = { key = "app" },
            target = "run", kind = "launch" }, c.args)
        assert.same({ PATH = "x" }, c.env)
        accept(1, "b1")
        start_frame("b1", vim.deepcopy(STEPS))
        assert.is_true(obs._tasks["b1"].owned)
        done_frame("b1", 0)
        assert.is_true(vim.wait(2000, function() return ok ~= nil end, 10))
        assert.is_true(ok)
        -- No dependency build, deploy or Build/1 call in the editor.
        assert.equals(1, #sent)
        assert.equals(0, deployed)
    end)

    pending("a failed build rejects with the task's failure line", function()
        obs = fake_observer()
        local err
        lt("run"):build():catch(function(e) err = e end)
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        accept(1, "b2")
        start_frame("b2", vim.deepcopy(STEPS))
        done_frame("b2", 1, "deploy failed: no such file")
        assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
        assert.equals("deploy failed: no such file", err)
    end)

    pending("refused by the daemon (no steps): its message once, rejected", function()
        obs = fake_observer()
        local err
        lt("run"):build():catch(function(e) err = e end)
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        sent[1].cb({ outcome = "refused", message = "workspace not trusted" }, nil)
        assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
        assert.is_true(noted("workspace not trusted"))
    end)

    pending("a daemon without Launch/1.build: refused with the method's note, nothing in the editor", function()
        obs = fake_observer()
        local err
        lt("run"):build():catch(function(e) err = e end)
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        sent[1].cb(nil, { code = "unknown_method", message = "no method build" })
        assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
        assert.is_false(obs:can_call("launch_build"))
        assert.is_true(noted("Launch/1.build"))
        -- Still refused, never sent again nor run in the editor.
        local err2
        lt("run"):build():catch(function(e) err2 = e end)
        assert.is_true(vim.wait(2000, function() return err2 ~= nil end, 10))
        assert.equals(1, #sent)
        assert.equals(0, #created)
    end)

    pending("no Launch/1 offered: refused, nothing built", function()
        obs = fake_observer({ operations = "available", tasks = "subscribed" })
        local err
        lt("run"):build():catch(function(e) err = e end)
        assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
        assert.matches("^build: ", err)
        assert.same({}, sent)
        assert.equals(0, #created)
    end)

    pending("a device target's build is one Launch/1.build too, addressed by its profile alone", function()
        obs = fake_observer()
        local t = require("loomworks.launch_target").new(ws, profile, { project = "app", device_target = "app" })
        t:build()
        assert.is_true(vim.wait(2000, function() return #sent >= 1 end, 10))
        assert.equals(1, #sent)
        assert.same({ "/launch", "build" }, { sent[1].object, sent[1].method })
        assert.is_nil(sent[1].args.target)
        assert.same({ key = profile.key }, sent[1].args.profile)
        assert.equals(0, #created)
    end)

    describe("the artifact-conflict question", function()
        local block = { profile = "other", path = "/w/out/app" }
        before_each(function()
            stub(ws, "artifact_conflict_block", function(_, unit, force)
                if force then return nil end
                return unit and block or nil
            end)
        end)

        pending("is asked before the build's call; Yes sends force = true", function()
            obs = fake_observer()
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
            assert.same({}, sent)
            assert.matches("owned by built profile 'other'", selects[1].prompt)
            selects[1].cb("Yes")
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            assert.equals("build", sent[1].method)
            assert.is_true(sent[1].args.force)
        end)

        pending("No: nothing is sent, the build is cancelled", function()
            obs = fake_observer()
            local err
            lt("run"):build():catch(function(e) err = e end)
            assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
            selects[1].cb("No")
            assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
            assert.matches("would overwrite profile 'other'", err)
            assert.same({}, sent)
        end)

        pending("is asked before a launch's preparation; Yes sends force = true on prepare_run", function()
            obs = fake_observer()
            require("loomworks.session_tracker").start(lt("run"), "launch")
            assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
            assert.same({}, sent)
            selects[1].cb("Yes")
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            assert.equals("prepare_run", sent[1].method)
            assert.is_true(sent[1].args.force)
            assert.equals("target", sent[1].args.build_scope)
        end)

        pending("No before a preparation: nothing is sent, no program", function()
            obs = fake_observer()
            require("loomworks.session_tracker").start(lt("run"), "launch")
            assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
            selects[1].cb("No")
            vim.wait(100)
            assert.same({}, sent)
            assert.is_false(require("loomworks.session_tracker").is_running())
        end)
    end)

    describe("steps", function()
        pending("the task follows its current step: progress entry, status row, task-runner row", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "b3")
            start_frame("b3", vim.deepcopy(STEPS))
            local task = obs._tasks["b3"]
            -- (No overseer strategy runs here: bind a task-runner row as
            -- the strategy's start does.)
            local row = { name = "?" }
            task._runner = { task = row }
            assert.equals(3, #task.steps)
            assert.is_nil(task:step_text())
            step_signal("b3", 1, 1, "running")
            assert.equals("running", task.steps[1].state)
            assert.equals("dependency lib (1/3)", task:step_text())
            assert.equals("daemon_task_step", events[#events].name)
            -- The task-runner row names the step.
            assert.equals(profile.key .. " — dependency lib (1/3)", row.name)
            step_signal("b3", 2, 1, "ok")
            step_signal("b3", 3, 2, "running")
            assert.equals("deploy (pre_build) (2/3)", task:step_text())
            assert.equals(profile.key .. " — deploy (pre_build) (2/3)", row.name)
            -- The status row follows it too (one row for the task).
            local lines = {}
            local tree = {
                leaf = function() end, blank = function() end,
                item = function(_, label)
                    if type(label) == "table" then
                        local t = {}
                        for _, c in ipairs(label) do t[#t + 1] = c[1] end
                        label = table.concat(t)
                    end
                    if label:find("▸", 1, true) and not label:find("Reset", 1, true) then
                        lines[#lines + 1] = label
                    end
                end,
            }
            require("loomworks.ui.sections.tasks")(tree, { lw = {
                get_active_tasks = function() return {} end,
                get_daemon_tasks = function() return { task } end,
                get_build_dir_locks_info = function() return {} end,
            } })
            assert.equals(1, #lines)
            assert.matches("— build: deploy %(pre_build%) %(2/3%)", lines[1])
            -- No list re-read without a gap.
            assert.equals(1, #sent)
        end)

        pending("a failed step carries its failure line; the later step skipped", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "b4")
            start_frame("b4", vim.deepcopy(STEPS))
            step_signal("b4", 1, 2, "failed", "deploy failed: x")
            step_signal("b4", 2, 3, "skipped")
            local task = obs._tasks["b4"]
            assert.same({ "failed", "skipped" }, { task.steps[2].state, task.steps[3].state })
            assert.equals("deploy failed: x", task.steps[2].error)
            assert.is_nil(task:step_text())
        end)

        pending("a seq gap re-reads Tasks/1.list and adopts its step states", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "b5")
            start_frame("b5", vim.deepcopy(STEPS))
            -- seq 1 and 2 lost.
            step_signal("b5", 3, 2, "running")
            assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
            assert.same({ "/tasks", "loomworks.Tasks", "list" }, { sent[2].object, sent[2].iface, sent[2].method })
            local listed = vim.deepcopy(STEPS)
            listed[1].state, listed[2].state = "ok", "running"
            sent[2].cb({ tasks = { { task_id = "b5", kind = "build", steps = listed } } }, nil)
            local task = obs._tasks["b5"]
            assert.is_true(vim.wait(2000, function() return task.steps[1].state == "ok" end, 10))
            assert.equals("deploy (pre_build) (2/3)", task:step_text())
        end)

        pending("started / ended signals count toward the seq (no gap, no re-read)", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "b6")
            start_frame("b6", vim.deepcopy(STEPS))
            obs:_on_message({ kind = "signal", object = "/tasks", iface = "loomworks.Tasks", v = 1, name = "started",
                seq = 1, args = { task = { task_id = "b6" } } })
            step_signal("b6", 2, 1, "running")
            vim.wait(50)
            assert.equals(1, #sent)
        end)

        pending("an unknown step state shows neutrally (no current step)", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "b7")
            start_frame("b7", vim.deepcopy(STEPS))
            step_signal("b7", 1, 1, "warming")
            assert.equals("warming", obs._tasks["b7"].steps[1].state)
            assert.is_nil(obs._tasks["b7"]:step_text())
        end)

        it("a late-joined task's steps are read once through Tasks/1.list (status carries none)", function()
            obs = fake_observer()
            obs._tasks_seq = 0
            local status_cb
            function obs.conn.request(_, req, cb)
                if req.kind == "status" then status_cb = cb end
            end
            obs:_join_late(obs.conn)
            assert.is_function(status_cb)
            status_cb({ tasks = { { task_id = "j1", name = profile.key, kind = "build", profile = profile.key,
                origin = "cli" } } })
            assert.is_true(vim.wait(2000, function() return obs._tasks["j1"] ~= nil end, 10))
            local task = obs._tasks["j1"]
            assert.is_nil(task.steps)
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            assert.same({ "/tasks", "loomworks.Tasks", "list" }, { sent[1].object, sent[1].iface, sent[1].method })
            local listed = vim.deepcopy(STEPS)
            listed[1].state = "running"
            sent[1].cb({ tasks = { { task_id = "j1", kind = "build", steps = listed } } }, nil)
            assert.is_true(vim.wait(2000, function() return task.steps ~= nil end, 10))
            assert.equals("dependency lib (1/3)", task:step_text())
            -- Later step deltas move it.
            step_signal("j1", 1, 1, "ok")
            step_signal("j1", 2, 2, "running")
            assert.equals("deploy (pre_build) (2/3)", task:step_text())
            assert.equals(1, #sent)
        end)

        pending("signals before the /tasks subscribe reply are held: past the baseline applied, at or below ignored",
            function()
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "e1")
            start_frame("e1", vim.deepcopy(STEPS))
            local task = obs._tasks["e1"]
            -- A (re)subscription pending: its baseline not known yet.
            obs._feat.tasks = "pending"
            obs._tasks_seq = nil
            step_signal("e1", 4, 1, "running")
            step_signal("e1", 6, 2, "running")
            assert.same({ "pending", "pending" }, { task.steps[1].state, task.steps[2].state })
            assert.is_nil(obs._tasks_seq)
            obs._feat.tasks = "subscribed"
            obs:_tasks_subscribed({ seq = 5 })
            -- seq 4 is in the state the baseline was taken at; seq 6 follows it.
            assert.same({ "pending", "running" }, { task.steps[1].state, task.steps[2].state })
            assert.equals(6, obs._tasks_seq)
            vim.wait(50)
            assert.equals(1, #sent)
        end)

        pending("the progress entry drops the step text once no step runs", function()
            local creates, reports = {}, {}
            local saved_fp, saved_fid = package.loaded["fidget.progress"], package.loaded["loomworks.fidget"]
            package.loaded["fidget.progress"] = { handle = { create = function(o)
                creates[#creates + 1] = o.message
                return { report = function(_, r) reports[#reports + 1] = r end,
                    finish = function() end, cancel = function() end }
            end } }
            package.loaded["loomworks.fidget"] = nil
            require("loomworks.fidget").setup()
            package.loaded["fidget.progress"], package.loaded["loomworks.fidget"] = saved_fp, saved_fid
            obs = fake_observer()
            obs._tasks_seq = 0
            lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "f1")
            start_frame("f1", vim.deepcopy(STEPS))
            assert.equals("Building", creates[#creates])
            step_signal("f1", 1, 1, "running")
            assert.equals("dependency lib (1/3)", reports[#reports].message)
            step_signal("f1", 2, 1, "ok")
            assert.equals("Building", reports[#reports].message)
        end)
    end)

    describe("cancel", function()
        pending("cancelling the build's Future cancels the daemon task (Tasks/1.cancel)", function()
            obs = fake_observer()
            local f = lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            accept(1, "c1")
            f:cancel()
            assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
            assert.same({ "/tasks", "loomworks.Tasks", "cancel" }, { sent[2].object, sent[2].iface, sent[2].method })
            assert.same({ task_id = "c1" }, sent[2].args)
            assert.is_true(obs._owned["c1"].cancelling)
        end)

        pending("a build cancelled before its reply is cancelled once accepted", function()
            obs = fake_observer()
            local f = lt("run"):build()
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            f:cancel()
            vim.wait(50)
            assert.equals(1, #sent)
            sent[1].cb({ outcome = "accepted", task_id = "c2" }, nil)
            assert.is_true(vim.wait(2000, function() return #sent == 2 end, 10))
            assert.equals("cancel", sent[2].method)
            assert.same({ task_id = "c2" }, sent[2].args)
        end)
    end)

    describe("the daemon is the single authority (thin shim)", function()
        pending("an invalid target is not pre-checked in the editor: one Launch/1.build, the daemon's failure", function()
            obs = fake_observer()
            local t = lt("run")
            t.is_valid = function() return false, { "stale mapping" } end
            t.abstract_error = function() return "abstract" end
            local err
            t:build():catch(function(e) err = e end)
            assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
            assert.equals("build", sent[1].method)
            accept(1, "v1")
            done_frame("v1", 1, "target 'app:run' is not buildable: stale mapping")
            assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
            assert.equals("target 'app:run' is not buildable: stale mapping", err)
        end)

        it("in-process: an invalid target is still refused before anything runs", function()
            local t = lt("run")
            t.is_valid = function() return false, { "stale mapping" } end
            local err
            t:build():catch(function(e) err = e end)
            assert.is_true(vim.wait(2000, function() return err ~= nil end, 10))
            assert.matches("not buildable: stale mapping", err)
            assert.equals(0, #created)
        end)
    end)
end)
