-- The editor's operations as daemon calls (spec §19.16 "Editor operations",
-- §19.15 "The editor as owner"; step 5k part C1): the routing decision of
-- the overseer entry points in both runtime modes, against an observer
-- whose connection is a recording fake (no daemon): what is sent, and what
-- each outcome does — accepted (one owned task, ended by its `done`),
-- declined (in-process, one notification), a method the daemon lacks
-- (in-process, a Runtime-line note), refused (fails, nothing in-process),
-- the connection lost after `accepted` (fails, never re-run in-process) —
-- plus cancellation (`Tasks/1.cancel`) and a clean's pre-emption of the
-- editor's own build.

local observer = require("loomworks.daemon.observer")
local editor_ops = require("loomworks.daemon.editor_ops")
local H = require("tests.daemon_helpers")

describe("editor operations as daemon calls (§19.16, step 5k C1)", function()
    local root, core, ws, profile, unit
    local obs, sent, created, notes, orig_overseer, orig_notify

    --- A connected observer of `ws` over a fake connection recording each
    --- call (`sent`); `feat` overrides its features.
    local function fake_observer(feat)
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb, env)
            sent[#sent + 1] = { object = object, iface = iface, v = v, method = method, args = args, cb = cb,
                env = env }
        end
        function conn.close(c) c.closed = true end
        local o = setmetatable({
            ws = ws, root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = feat or { operations = "available", tasks = "subscribed" }, _why = {},
            _tasks = {}, _order = {}, _owned = {}, seq = 0,
            daemon = { pid = 1 },
            opts = { environ = function() return { PATH = "x" } end },
        }, observer.Observer)
        ws._daemon_observer = o
        ws._operation_router = editor_ops.router
        observer._current = o
        return o
    end

    --- The task frames of task `id` for `meta`, then the `done`.
    local function start_frame(id, meta)
        obs:_on_task({ kind = "task", task_id = id, phase = "start", meta = meta })
    end
    local function done_frame(id, code, err)
        obs:_on_task({ kind = "task", task_id = id, phase = "done", exit_code = code, error = err })
    end

    --- Settle a future into a table.
    local function watch(f)
        local st = {}
        f:next(function(v) st.ok = v end, function(e) st.err = e end)
        return st
    end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        profile = ws:get_profiles()[1]
        unit = profile:projects()[1]._config_unit
        sent, created, notes = {}, {}, {}
        orig_overseer = package.loaded["overseer"]
        package.loaded["overseer"] = {
            new_task = function(spec)
                created[#created + 1] = spec
                return { id = 1000 + #created, subscribe = function() end, start = function() end,
                    stop = function() end, is_complete = function() return false end,
                    dispose = function() end }
            end,
        }
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)

    after_each(function()
        vim.notify = orig_notify
        package.loaded["overseer"] = orig_overseer
        if obs then
            observer._current = nil
            if ws then ws._daemon_observer, ws._operation_router = nil, nil end
        end
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    it("in-process mode: nothing is routed, the entry points run in-process as before", function()
        assert.is_nil(observer.current())
        assert.is_nil(editor_ops.carrier("build"))
        assert.is_false(editor_ops.daemon_mode())
        local f = require("loomworks.overseer").run_profile_action(profile, "build")
        assert.is_nil(f.routed)
        assert.is_true(vim.wait(5000, function() return #created > 0 end, 10))
        assert.same({}, sent)
    end)

    it("a profile build is a Build/1.build the editor owns; its `done` ends the operation", function()
        obs = fake_observer()
        assert.is_true(editor_ops.daemon_mode())
        local f = require("loomworks.overseer").run_profile_action(profile, "build", { parallel_jobs = 1 })
        assert.is_true(f.routed)
        local st = watch(f)
        assert.equals(1, #sent)
        local c = sent[1]
        assert.same({ "/build", "loomworks.Build", 1, "build" }, { c.object, c.iface, c.v, c.method })
        assert.same({ key = profile.key }, c.args.profile)
        assert.equals(1, c.args.jobs)
        assert.is_false(c.args.interactive)
        assert.same({ PATH = "x" }, c.env)
        -- Accepted, then its task's frames.
        c.cb({ outcome = "accepted", task_id = "t1", profile_key = profile.key }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["t1"] ~= nil end, 10))
        start_frame("t1", { name = "build " .. profile.key, kind = "build", profile = profile.key, origin = "editor",
            units = { editor_ops.unit_ref(unit) } })
        local task = obs._tasks["t1"]
        assert.is_true(task.owned)
        assert.is_nil(task:origin_label())
        assert.equals("building", unit:state())
        assert.equals(1, #obs:owned_tasks())
        assert.is_true(obs:owns_tasks())
        -- Nothing ran in-process.
        assert.equals(0, #created)
        done_frame("t1", 0)
        assert.is_true(vim.wait(2000, function() return st.ok ~= nil or st.err ~= nil end, 10))
        assert.is_true(st.ok)
        assert.is_false(obs:owns_tasks())
    end)

    it("a unit configure / build / -j1 build sends `units`; a failed task rejects with its error", function()
        obs = fake_observer()
        local ov = require("loomworks.overseer")
        ov.run_configuration_action(unit, "configure")
        ov.run_configuration_action(unit, "build", nil, { parallel_jobs = 1 })
        assert.equals(2, #sent)
        assert.equals("configure", sent[1].method)
        assert.same({ editor_ops.unit_ref(unit) }, sent[1].args.units)
        assert.is_nil(sent[1].args.profile)
        assert.equals("build", sent[2].method)
        assert.equals(1, sent[2].args.jobs)
        local okc
        local f = ov.run_configuration_action(unit, "build", function(ok) okc = ok end)
        local st = watch(f)
        sent[3].cb({ outcome = "accepted", task_id = "t3" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["t3"] ~= nil end, 10))
        start_frame("t3", { name = "build", kind = "build", units = { editor_ops.unit_ref(unit) } })
        -- A units task (no profile) resolves its units among the workspace's.
        assert.equals(unit, obs._tasks["t3"]:config_units()[1])
        done_frame("t3", 2, "build failed")
        assert.is_true(vim.wait(2000, function() return st.err ~= nil end, 10))
        assert.equals("build failed", st.err)
        assert.is_true(vim.wait(2000, function() return okc ~= nil end, 10))
        assert.is_false(okc)
        assert.equals(0, #created)
    end)

    it("a module target's build names its project-qualified target", function()
        obs = fake_observer()
        local td = { name = "t", builder = function() return { cmd = { "x" } } end,
            loomworks = { action = "build", target_id = "app" } }
        local f = require("loomworks.overseer").launch_single_task(td, unit)
        assert.is_true(f.routed)
        assert.equals(1, #sent)
        assert.same({ { project = unit._project.key, target = "app" } }, sent[1].args.targets)
        assert.same({ editor_ops.unit_ref(unit) }, sent[1].args.units)
    end)

    it("declined: in-process, with the reason as one notification", function()
        obs = fake_observer()
        local f = require("loomworks.overseer").run_profile_action(profile, "build")
        sent[1].cb({ outcome = "declined", reason = "another environment" }, nil)
        assert.is_true(vim.wait(5000, function() return #created > 0 end, 10))
        local hit
        for _, n in ipairs(notes) do
            if n.msg:find("declined the build (another environment)", 1, true) then hit = true end
        end
        assert.is_true(hit)
        assert.is_true(f.routed)
    end)

    it("a method the daemon lacks: in-process, one Runtime-line note, not called again", function()
        obs = fake_observer()
        require("loomworks.overseer").run_profile_action(profile, "configure")
        sent[1].cb(nil, { code = "unknown_method", message = "no configure" })
        assert.is_true(vim.wait(5000, function() return #created > 0 end, 10))
        assert.is_false(obs:can_call("configure"))
        assert.is_true(obs:can_call("build"))
        assert.truthy((obs.note or ""):find("operations: daemon offers no loomworks.Build/1.configure", 1, true))
        for _, n in ipairs(notes) do assert.is_nil(n.msg:find("configure", 1, true)) end
        -- The next configure runs in-process at once.
        local before = #sent
        assert.is_nil(require("loomworks.overseer").run_profile_action(profile, "configure").routed)
        assert.equals(before, #sent)
    end)

    it("refused: the operation fails with the refusal's message; nothing in-process", function()
        obs = fake_observer()
        local st = watch(require("loomworks.overseer").run_profile_action(profile, "build"))
        sent[1].cb({ outcome = "refused", message = "workspace not trusted", exit_code = 1 }, nil)
        assert.is_true(vim.wait(2000, function() return st.err ~= nil end, 10))
        assert.equals("workspace not trusted", st.err)
        vim.wait(100)
        assert.equals(0, #created)
    end)

    it("the connection lost after `accepted`: fails, never re-run in-process", function()
        obs = fake_observer()
        local st = watch(require("loomworks.overseer").run_profile_action(profile, "build"))
        sent[1].cb({ outcome = "accepted", task_id = "t9" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["t9"] ~= nil end, 10))
        start_frame("t9", { name = "build", kind = "build", profile = profile.key })
        obs:_end_tasks("the workspace daemon disconnected")
        assert.is_true(vim.wait(2000, function() return st.err ~= nil end, 10))
        assert.equals("the workspace daemon disconnected", st.err)
        vim.wait(100)
        assert.equals(0, #created)
    end)

    it("an internal error fails the operation and is not re-run", function()
        obs = fake_observer()
        local st = watch(require("loomworks.overseer").run_profile_action(profile, "build"))
        sent[1].cb(nil, { code = "internal", message = "boom" })
        assert.is_true(vim.wait(2000, function() return st.err ~= nil end, 10))
        assert.equals("boom", st.err)
        assert.equals(0, #created)
    end)

    it("not carried (no Tasks/1, so no cancel): in-process, nothing sent", function()
        obs = fake_observer({ operations = "available" })
        assert.is_nil(editor_ops.carrier("build"))
        assert.is_nil(require("loomworks.overseer").run_profile_action(profile, "build").routed)
        assert.same({}, sent)
        assert.is_true(vim.wait(5000, function() return #created > 0 end, 10))
    end)

    it("cancel sends Tasks/1.cancel for an owned task only, and waits for its end", function()
        obs = fake_observer()
        require("loomworks.overseer").run_profile_action(profile, "build")
        sent[1].cb({ outcome = "accepted", task_id = "t5" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["t5"] ~= nil end, 10))
        start_frame("t5", { name = "build", kind = "build", profile = profile.key,
            units = { editor_ops.unit_ref(unit) } })
        local task = obs._tasks["t5"]
        -- Another client's task is never cancelled from the editor.
        start_frame("t6", { name = "build", kind = "build", profile = profile.key, origin = "cli" })
        assert.is_false(editor_ops.cancel(obs._tasks["t6"]))
        local ended
        obs:cancel_owned(obs._tasks["t6"], function(ok, why) ended = { ok, why } end)
        assert.same({ false, "started by lw — cancel it there" }, ended)
        assert.equals(1, editor_ops.cancel_for_profile(profile))
        local c = sent[#sent]
        assert.same({ "/tasks", "loomworks.Tasks", "cancel" }, { c.object, c.iface, c.method })
        assert.same({ task_id = "t5" }, c.args)
        local waited
        obs:cancel_owned(task, function(ok) waited = ok end)
        assert.is_nil(waited)
        done_frame("t5", 130, "build stopped: cancelled")
        assert.is_true(waited)
    end)

    it("a clean cancels the editor's own build on its units first, then is a Build/1.clean", function()
        obs = fake_observer()
        require("loomworks.overseer").run_profile_action(profile, "build")
        sent[1].cb({ outcome = "accepted", task_id = "b1" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["b1"] ~= nil end, 10))
        start_frame("b1", { name = "build", kind = "build", profile = profile.key,
            units = { editor_ops.unit_ref(unit) } })
        -- Something to clean: the unit has a build directory recorded.
        local ov = require("loomworks.overseer")
        local orig = ov.plan_profile_clean
        ov.plan_profile_clean = function() return { { kind = "clean" } } end
        local st = watch(profile:clean())
        ov.plan_profile_clean = orig
        assert.equals(2, #sent)
        assert.equals("cancel", sent[2].method)
        -- The clean waits for the build's end.
        done_frame("b1", 130, "build stopped")
        assert.is_true(vim.wait(2000, function() return #sent == 3 end, 10))
        assert.equals("clean", sent[3].method)
        assert.same({ key = profile.key }, sent[3].args.profile)
        sent[3].cb({ outcome = "accepted", task_id = "c1" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["c1"] ~= nil end, 10))
        start_frame("c1", { name = "clean", kind = "clean", profile = profile.key,
            units = { editor_ops.unit_ref(unit) } })
        assert.equals("deleting", unit:state())
        assert.equals("cleaning", unit:deleting_reason())
        done_frame("c1", 0)
        assert.is_true(vim.wait(2000, function() return st.ok ~= nil end, 10))
        assert.equals(0, #created)
    end)

    it("a clean with nothing to clean resolves at once, as in-process", function()
        obs = fake_observer()
        local ov = require("loomworks.overseer")
        local orig = ov.plan_units_clean
        ov.plan_units_clean = function() return nil end
        local st = watch(unit:clean())
        ov.plan_units_clean = orig
        assert.is_true(vim.wait(2000, function() return st.ok ~= nil end, 10))
        assert.same({}, sent)
    end)

    it("the action's own progress entry is not shown for a routed operation", function()
        local fidget = require("loomworks.fidget")
        local made = {}
        local orig = fidget.start_action
        fidget.start_action = function(title) made[#made + 1] = title; return { title = title } end
        local ok, err = pcall(function()
            -- In-process mode: unchanged.
            fidget.start_op_action("Building p", "build")
            obs = fake_observer()
            assert.is_nil(fidget.start_op_action("Building p", "build"))
            -- Daemon mode, not carried: the title says so.
            obs._feat.operations = nil
            fidget.start_op_action("Building p", "build")
        end)
        fidget.start_action = orig
        assert.is_true(ok, tostring(err))
        assert.same({ "Building p", "Building p (in-process)" }, made)
    end)
end)
