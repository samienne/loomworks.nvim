-- The workspace daemon's tasks in the editor's task runner (spec §19.16
-- "Tasks in the task runner"; step 5k part C1b): every daemon task the
-- observer knows is ONE overseer task run by the `loomworks_daemon` strategy
-- — an editor-owned one started by its call, stopped by `Tasks/1.cancel`,
-- restarted by the same call; another client's listed read-only with its
-- origin marker — its output written to a terminal buffer in batches; and
-- when overseer cannot host them, none is listed and the Runtime line says so.
--
-- CI has no overseer: `fake_overseer` mimics the parts of overseer's Task /
-- strategy contract the bridge relies on (strategy.load → `new(conf)`;
-- `start` → strategy:start, RUNNING; `stop` → CANCELED, then strategy:stop;
-- `restart(force)` → stop, reset, start; `on_exit(code)` → SUCCESS/FAILURE
-- while running). The last block runs the same flow against the real
-- overseer when it is installed (lazy.nvim's directory), skipped otherwise.

local observer = require("loomworks.daemon.observer")
local editor_ops = require("loomworks.daemon.editor_ops")
local runner = require("loomworks.daemon.task_runner")
local H = require("tests.daemon_helpers")

local fake_overseer = require("tests.fake_overseer")

describe("daemon tasks in the task runner (§19.16, step 5k C1b)", function()
    local root, core, ws, profile, unit
    local obs, sent, created, notes, saved, orig_notify

    local function fake_observer()
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb, env)
            sent[#sent + 1] = { object = object, iface = iface, v = v, method = method, args = args, cb = cb,
                env = env }
        end
        function conn.close(c) c.closed = true end
        local o = setmetatable({
            ws = ws, root = ws.root, state = "connected", conn = conn, mode = "interfaces",
            _feat = { operations = "available", tasks = "subscribed" }, _why = {},
            _tasks = {}, _order = {}, _owned = {}, seq = 0,
            daemon = { pid = 1 },
            opts = { environ = function() return { PATH = "x" } end },
        }, observer.Observer)
        ws._daemon_observer = o
        ws._operation_router = editor_ops.router
        observer._current = o
        return o
    end

    local function frame(id, phase, extra)
        local msg = { kind = "task", task_id = id, phase = phase }
        for k, v in pairs(extra or {}) do msg[k] = v end
        obs:_on_task(msg)
    end

    local function meta(origin)
        return { name = "build " .. profile.key, kind = "build", profile = profile.key,
            units = { editor_ops.unit_ref(unit) }, origin = origin }
    end

    --- Start the editor's own profile build and its task `id`.
    local function owned_build(id)
        local st = {}
        require("loomworks.overseer").run_profile_action(profile, "build")
            :next(function(v) st.ok = v end, function(e) st.err = e end)
        sent[#sent].cb({ outcome = "accepted", task_id = id }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned[id] ~= nil end, 10))
        frame(id, "start", { meta = meta() })
        return st
    end

    local function buf_text(t)
        local b = t:get_bufnr()
        if not (b and vim.api.nvim_buf_is_valid(b)) then return "" end
        return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    end

    local function install(ov, strategy)
        package.loaded["overseer"] = ov
        package.loaded["overseer.strategy"] = strategy
        package.loaded["overseer.util"] = nil
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
        saved = {
            ov = package.loaded["overseer"], strat = package.loaded["overseer.strategy"],
            util = package.loaded["overseer.util"],
        }
        install(fake_overseer(created))
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)

    after_each(function()
        vim.notify = orig_notify
        package.loaded["overseer"] = saved.ov
        package.loaded["overseer.strategy"] = saved.strat
        package.loaded["overseer.util"] = saved.util
        if obs then
            observer._current = nil
            if ws then ws._daemon_observer, ws._operation_router = nil, nil end
        end
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    it("an owned task is one overseer task: no origin marker, its output in a terminal, exit 0 = SUCCESS", function()
        obs = fake_observer()
        local st = owned_build("t1")
        assert.equals(1, #created)
        local t = created[1]
        assert.equals("build " .. profile.key, t.name)
        assert.equals("RUNNING", t.status)
        assert.equals("t1", t.metadata.loomworks_daemon_task)
        assert.equals(t, runner.overseer_task(obs._tasks["t1"]))
        frame("t1", "line", { stream = "out", text = "==> [build] app\n" })
        frame("t1", "output", { stream = "stdout", text = "compiling main.c\n" })
        assert.is_true(vim.wait(2000, function() return buf_text(t):find("compiling main.c", 1, true) ~= nil end, 10),
            buf_text(t))
        assert.truthy(buf_text(t):find("==> [build] app", 1, true))
        frame("t1", "done", { exit_code = 0 })
        assert.equals("SUCCESS", t.status)
        assert.is_true(vim.wait(2000, function() return buf_text(t):find("[built", 1, true) ~= nil end, 10))
        assert.is_true(vim.wait(2000, function() return st.ok ~= nil end, 10))
    end)

    it("output frames are written in batches, never one terminal write per frame", function()
        obs = fake_observer()
        owned_build("t1")
        local t = created[1]
        assert.is_true(vim.wait(2000, function() return t:get_bufnr() ~= nil end, 10))
        local real = vim.api.nvim_chan_send
        local writes = 0
        vim.api.nvim_chan_send = function(...) writes = writes + 1; return real(...) end
        for i = 1, 200 do frame("t1", "output", { stream = "stdout", text = "line " .. i .. "\n" }) end
        assert.equals(0, writes)
        local ok = vim.wait(2000, function() return buf_text(t):find("line 200", 1, true) ~= nil end, 10)
        vim.api.nvim_chan_send = real
        assert.is_true(ok, buf_text(t))
        assert.is_true(writes <= 2, "writes: " .. writes)
    end)

    it("overseer stop sends Tasks/1.cancel and the task ends CANCELED; the operation fails", function()
        obs = fake_observer()
        local st = owned_build("t1")
        local t = created[1]
        t:stop()
        assert.equals("CANCELED", t.status)
        local c = sent[#sent]
        assert.same({ "/tasks", "loomworks.Tasks", "cancel" }, { c.object, c.iface, c.method })
        assert.same({ task_id = "t1" }, c.args)
        frame("t1", "done", { exit_code = 130, error = "build stopped: cancelled" })
        assert.equals("CANCELED", t.status)
        assert.is_true(vim.wait(2000, function() return st.err ~= nil end, 10))
    end)

    it("the status page's Cancel ends the overseer task CANCELED, not FAILURE", function()
        obs = fake_observer()
        owned_build("t1")
        assert.is_true(editor_ops.cancel(obs._tasks["t1"]))
        frame("t1", "done", { exit_code = 130, error = "build stopped: cancelled" })
        assert.equals("CANCELED", created[1].status)
    end)

    it("restart sends the same call again and the new task continues the same overseer task", function()
        obs = fake_observer()
        owned_build("t1")
        local t = created[1]
        local first = sent[#sent]
        frame("t1", "done", { exit_code = 2, error = "build failed" })
        assert.equals("FAILURE", t.status)
        assert.is_true(t:restart(true))
        assert.equals("RUNNING", t.status)
        assert.is_true(vim.wait(2000, function() return sent[#sent] ~= first end, 10))
        local again = sent[#sent]
        assert.same({ "/build", "loomworks.Build", "build" }, { again.object, again.iface, again.method })
        assert.same(first.args, again.args)
        again.cb({ outcome = "accepted", task_id = "t2" }, nil)
        assert.is_true(vim.wait(2000, function() return obs._owned["t2"] ~= nil end, 10))
        assert.is_true(vim.wait(2000, function() return t.strategy._call_id == "t2" end, 10))
        frame("t2", "start", { meta = meta() })
        assert.equals(1, #created)
        assert.equals(t, runner.overseer_task(obs._tasks["t2"]))
        assert.is_true(obs._tasks["t2"].owned)
        frame("t2", "done", { exit_code = 0 })
        assert.equals("SUCCESS", t.status)
    end)

    it("a restart the daemon declines fails the overseer task with the reason; nothing in-process", function()
        obs = fake_observer()
        owned_build("t1")
        local t = created[1]
        frame("t1", "done", { exit_code = 0 })
        t:restart(true)
        assert.is_true(vim.wait(2000, function() return #sent >= 2 end, 10))
        sent[#sent].cb(nil, { code = "stopping", message = "the daemon is stopping" })
        assert.is_true(vim.wait(2000, function() return t.status == "FAILURE" end, 10))
        assert.is_true(vim.wait(2000, function()
            return buf_text(t):find("not restarted: the daemon is stopping", 1, true) ~= nil
        end, 10), buf_text(t))
        assert.equals(1, #created)
    end)

    it("another client's task is listed read-only with its origin marker; stop and restart only say so", function()
        obs = fake_observer()
        frame("c1", "start", { meta = meta("cli") })
        assert.equals(1, #created)
        local t = created[1]
        assert.equals("[lw] build " .. profile.key, t.name)
        assert.equals("RUNNING", t.status)
        local n = #sent
        assert.is_false(t:stop())
        assert.is_false(t:restart(true))
        assert.equals("RUNNING", t.status)
        assert.equals(n, #sent)
        assert.equals("loomworks: started by lw — cancel it there", notes[#notes].msg)
        frame("c1", "output", { stream = "stdout", text = "from the cli\n" })
        assert.is_true(vim.wait(2000, function() return buf_text(t):find("from the cli", 1, true) ~= nil end, 10))
        frame("c1", "done", { exit_code = 1 })
        assert.equals("FAILURE", t.status)
    end)

    it("a task joined late gets its overseer task too", function()
        obs = fake_observer()
        local task = require("loomworks.daemon.remote_task").adopt(ws, { task_id = "c9", name = "build x",
            kind = "build", origin = "editor", started_at = os.time() }, obs:_clock())
        obs:_add(task)
        assert.equals("[editor] build x", created[1].name)
    end)

    it("teardown ends the overseer tasks CANCELED", function()
        obs = fake_observer()
        owned_build("t1")
        frame("c1", "start", { meta = meta("cli") })
        obs:_end_tasks("the workspace was unloaded", true)
        assert.equals("CANCELED", created[1].status)
        assert.equals("CANCELED", created[2].status)
    end)

    it("the status page's Open overseer opens the task list for a task it hosts", function()
        obs = fake_observer()
        owned_build("t1")
        assert.is_true(runner.open(obs._tasks["t1"]))
        assert.equals(1, created.opened)
    end)

    it("without a task runner that can host them: none listed, one Runtime-line note", function()
        package.loaded["overseer"] = { new_task = function() error("must not be called") end }
        package.loaded["overseer.strategy"] = nil
        package.preload["overseer.strategy.loomworks_daemon"] = nil
        package.loaded["overseer.strategy.loomworks_daemon"] = nil
        obs = fake_observer()
        owned_build("t1")
        frame("c1", "start", { meta = meta("cli") })
        assert.is_nil(runner.overseer_task(obs._tasks["t1"]))
        assert.is_false(runner.open(obs._tasks["t1"]))
        assert.equals(runner.NOTE, obs.runner_note)
        local line = obs:runtime_line()
        local _, count = line:gsub("overseer cannot host", "")
        assert.equals(1, count, line)
        -- The operation itself is unaffected.
        frame("t1", "done", { exit_code = 0 })
        assert.is_nil(obs._owned["t1"])
    end)

    describe("against the installed overseer", function()
        -- Next to plenary (the suite repoints stdpath("data") per spec file).
        local path
        for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
            local d = dir:gsub("\\", "/")
            if d:match("/plenary%.nvim/?$") then
                path = d:gsub("/plenary%.nvim/?$", "") .. "/overseer.nvim"
            end
        end
        local have = path ~= nil and vim.fn.isdirectory(path) == 1
        local it_real = have and it or pending

        it_real("an owned task runs, stops by cancel, restarts; an observed one refuses stop", function()
            package.loaded["overseer"] = nil
            package.loaded["overseer.strategy"] = nil
            package.loaded["overseer.util"] = nil
            package.loaded["overseer.task"] = nil
            vim.opt.rtp:append(path)
            local ov = require("overseer")
            ov.setup({})
            obs = fake_observer()
            owned_build("t1")
            local t
            for _, x in ipairs(ov.list_tasks({ include_ephemeral = true })) do
                if x.metadata and x.metadata.loomworks_daemon_task == "t1" then t = x end
            end
            assert.is_not_nil(t)
            assert.equals("RUNNING", t.status)
            frame("t1", "output", { stream = "stdout", text = "hello\n" })
            assert.is_true(vim.wait(2000, function() return buf_text(t):find("hello", 1, true) ~= nil end, 10))
            t:stop()
            assert.equals("CANCELED", t.status)
            assert.equals("cancel", sent[#sent].method)
            frame("t1", "done", { exit_code = 130 })
            assert.equals("CANCELED", t.status)
            t:restart(true)
            assert.is_true(vim.wait(2000, function() return sent[#sent].method == "build" end, 10))
            sent[#sent].cb({ outcome = "accepted", task_id = "t2" }, nil)
            assert.is_true(vim.wait(2000, function() return t.strategy._call_id == "t2" end, 10))
            frame("t2", "start", { meta = meta() })
            frame("t2", "done", { exit_code = 0 })
            assert.equals("SUCCESS", t.status)
            frame("c1", "start", { meta = meta("cli") })
            local c = runner.overseer_task(obs._tasks["c1"])
            assert.equals("[lw] build " .. profile.key, c.name)
            assert.is_false(c:stop())
            assert.equals("RUNNING", c.status)
            frame("c1", "done", { exit_code = 0 })
            assert.equals("SUCCESS", c.status)
            for _, x in ipairs(ov.list_tasks({ include_ephemeral = true })) do pcall(x.dispose, x, true) end
        end)
    end)
end)
