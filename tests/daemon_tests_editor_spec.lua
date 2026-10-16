-- The editor's read path of the daemon's tests (step 5m part C1;
-- daemon.md §19.13 "The tests view", §19.16 "Tests", "Interface client";
-- LOOMTEST.md §3, §4.2, §13.1): in `daemon` mode the test tree, its unit
-- states and last results come ONLY from `loomworks.view.Tests/1`, discovery
-- is a `Tests/1.discover` call the editor owns, and nothing about tests is
-- computed in-process — unloaded, disconnected or unavailable shows a status
-- and refuses. The neotest adapter is not available in daemon mode.
--
-- The cases drive a real loaded (shell) workspace with a fake connected
-- observer whose connection answers as the test says.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local test_source = require("loomworks.test_source")
local adapter_mod = require("loomworks.loomtest_adapter")
local loomtest = require("loomtest")
local views = require("loomworks.views")
local H = require("tests.daemon_helpers")

describe("the editor's tests read path in daemon mode (§19.16 Tests)", function()
    local root, core, ws
    local notes
    local orig_notify

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        notes = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        adapter_mod._reset()
        loomtest.clear()
    end)
    after_each(function()
        vim.notify = orig_notify
        local obs = ws and ws._daemon_observer
        if obs then views.clear(obs) end
        if ws then ws._daemon_observer = nil end
        loomtest.unregister_adapter("loomworks")
        loomtest.clear()
        adapter_mod._reset()
        pcall(function() core:shutdown() end)
    end)

    --- A connected observer of `ws` over a fake connection: `answer(method,
    --- args)` returns the reply (`result, err`) or nothing.
    local function fake_obs(answer, feat)
        local calls = {}
        local conn = { closed = false }
        function conn:call(object, iface, v, method, args, cb, env)
            calls[#calls + 1] = { object = object, iface = iface, v = v, method = method, args = args, cb = cb,
                env = env }
            if answer then
                local r, e = answer(method, args)
                if r ~= nil or e ~= nil then cb(r, e) end
            end
        end
        function conn:close() self.closed = true end
        local obs = setmetatable({
            ws = ws, root = ws.root, state = "connected", mode = "interfaces", conn = conn,
            daemon = { pid = 1 }, seq = 0, _tasks = {}, _order = {}, _owned = {},
            _feat = feat or { [observer.VIEW_TESTS.feature] = "subscribed", [observer.TESTS.feature] = "subscribed",
                [observer.TASKS.feature] = "subscribed" },
            _why = {},
            opts = { environ = function() return { PATH = "/x" } end },
        }, observer.Observer)
        function obs:_spawn() end
        ws._daemon_observer = obs
        return obs, calls
    end

    --- A daemon tests view: two units, one discovered (target → suite → case,
    --- the same case name as unit b's), one not configured.
    local function tview(o)
        o = o or {}
        return {
            state = o.state or "loaded", profile = "dev", profile_id = "pr1",
            stale = o.stale or false, discovering = o.discovering,
            units = o.units or {
                { id = "u1", project = "a", configuration = "Debug", state = "ok", nodes = {
                    { id = "n1", kind = "target", name = "a_test", runnable = true, source = "ctest" },
                    { id = "n2", kind = "suite", parent = "n1", name = "Math", runnable = true },
                    { id = "n3", kind = "test", parent = "n2", name = "Add", runnable = true,
                        file = "/src/a.cpp", line = 3, status = "failed", message = "boom", duration = 4 },
                } },
                { id = "u2", project = "b", configuration = "Debug", state = "not_configured",
                    message = "not configured on this machine", nodes = {} },
            },
        }
    end

    local function ids(nodes)
        local out = {}
        for _, n in ipairs(nodes or {}) do out[#out + 1] = n.id end
        return out
    end

    local function discover_now()
        local got
        local a = loomtest.adapters()[1]
        a.discover_async(function(nodes) got = nodes or {} end)
        return got
    end

    local function discover_calls(calls)
        local out = {}
        for _, c in ipairs(calls) do if c.method == "discover" then out[#out + 1] = c end end
        return out
    end

    describe("observer descriptors and the view store", function()
        it("declares the tests view on /views and Tests/1 on /tests, subscribed for `results`", function()
            assert.equals("/views", observer.VIEW_TESTS.object)
            assert.equals("loomworks.view.Tests", observer.VIEW_TESTS.iface)
            assert.equals("tests", observer.VIEW_TESTS.view)
            assert.is_true(vim.tbl_contains(observer.VIEWS, observer.VIEW_TESTS))
            assert.is_true(vim.tbl_contains(observer.FEATURES, observer.VIEW_TESTS))
            assert.equals("/tests", observer.TESTS.object)
            assert.equals("loomworks.Tests", observer.TESTS.iface)
            assert.same({ "discover", "run_cases", "prepare_debug", "collect", "result" }, observer.TESTS.methods)
            assert.same({ "results" }, observer.TESTS.signals)
            assert.is_true(observer.TESTS.callable and observer.TESTS.tasks)
            assert.is_nil(observer.TESTS.call_only)
            assert.is_true(vim.tbl_contains(observer.FEATURES, observer.TESTS))
            assert.are_not.equal(observer.VIEW_TESTS.feature, observer.TESTS.feature)
        end)

        it("subscribes to view.Tests/1, adopts initial and update, re-gets after a gap, clears on close", function()
            local obs, calls = fake_obs(function(m, args)
                if m == "subscribe" then
                    if args.iface == "loomworks.view.Tests" then return { sub_id = 1, seq = 1, initial = tview() } end
                    return { sub_id = 2, seq = 1 }
                elseif m == "get" then
                    return tview({ stale = true })
                end
            end, {})
            local objects = {
                { path = "/views", interfaces = { { name = "loomworks.view.Tests", versions = { 1 } } } },
                { path = "/tests", interfaces = { { name = "loomworks.Tests", versions = { 1 } } } },
            }
            local done = false
            obs:_ensure_subscriptions(obs.conn, objects, function() done = true end)
            assert.is_true(vim.wait(1000, function() return done end, 10))
            assert.equals("subscribed", obs._feat[observer.VIEW_TESTS.feature])
            assert.equals("subscribed", obs._feat[observer.TESTS.feature])
            assert.equals(1, obs._tests_seq)
            assert.equals("pr1", views.daemon_state(obs, "tests").profile_id)

            obs:_on_message({ kind = "signal", object = "/views", iface = "loomworks.view.Tests", v = 1,
                name = "update", seq = 2, args = tview({ discovering = 9 }) })
            assert.equals(9, views.daemon_state(obs, "tests").discovering)
            -- A gap: one `get` of every subscribed view.
            obs:_on_message({ kind = "signal", object = "/views", iface = "loomworks.view.Tests", v = 1,
                name = "update", seq = 5, args = tview() })
            assert.is_true(vim.wait(1000, function() return views.daemon_state(obs, "tests").stale == true end, 10))
            local got = false
            for _, c in ipairs(calls) do
                if c.method == "get" and c.iface == "loomworks.view.Tests" then got = true end
            end
            assert.is_true(got)

            obs:_on_closed(obs.conn)
            assert.is_nil(views.daemon_state(obs, "tests"))
        end)
    end)

    describe("status (LOOMTEST.md §4.2, §13.1)", function()
        it("is nil with the view in use, `discovering…` while a discovery runs", function()
            local obs = fake_obs()
            views.set(obs, "tests", tview())
            assert.is_nil(obs:tests_status())
            views.set(obs, "tests", tview({ discovering = 3 }))
            local st = obs:tests_status()
            assert.is_false(st.blocked)
            assert.matches("^tests: discovering", st.text)
        end)

        it("is blocked while unloaded, disconnected, without a binary or the interfaces", function()
            local obs = fake_obs()
            -- Subscribed but no table yet: waiting.
            local st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.equals("tests: waiting for the workspace daemon", st.text)

            views.set(obs, "tests", tview({ state = "unloaded", units = {} }))
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.equals("tests: workspace unloaded", st.text)

            views.set(obs, "tests", tview({ state = "error", units = {} }))
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.equals("error", st.level)

            obs._feat[observer.VIEW_TESTS.feature] = nil
            obs._why[observer.VIEW_TESTS.feature] = observer.feature_note(observer.VIEW_TESTS, {})
            views.clear(obs)
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.equals("tests: daemon offers no loomworks.view.Tests, editor needs /1", st.text)

            obs._feat[observer.VIEW_TESTS.feature] = "subscribed"
            obs._feat[observer.TESTS.feature] = nil
            obs._why[observer.TESTS.feature] = observer.feature_note(observer.TESTS, {}) .. " — tests unavailable"
            views.set(obs, "tests", tview())
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.truthy(st.text:find("daemon offers no loomworks.Tests,", 1, true))

            obs._lost = true
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.matches("disconnected", st.text)

            obs._lost = nil
            obs.state = "no-binary"
            st = obs:tests_status()
            assert.is_true(st.blocked)
            assert.equals("tests: no lw host binary", st.text)
        end)

        it("a missing Tests/1 is noted as unavailable, never in-process", function()
            local obs = fake_obs(nil, {})
            local done = false
            obs:_ensure_subscriptions(obs.conn, {}, function() done = true end)
            assert.is_true(vim.wait(1000, function() return done end, 10))
            local why = obs._why[observer.TESTS.feature]
            assert.matches("^tests: daemon offers no loomworks.Tests", why)
            assert.matches("tests unavailable$", why)
            assert.is_nil(why:find("in%-process"))
        end)
    end)

    describe("the test source (no in-process discovery in daemon mode)", function()
        it("reports daemon mode and never discovers from the model", function()
            fake_obs()
            assert.equals("daemon", test_source.mode())
            local spy = 0
            for _, u in ipairs(test_source.units()) do
                u.unit.discover_tests = function() spy = spy + 1 end
                u.unit.discover_tests_async = function() spy = spy + 1 end
            end
            assert.is_nil(test_source.discover({ discover_tests = function() spy = spy + 1 end }))
            local cb_got = "unset"
            test_source.discover_async({ discover_tests_async = function() spy = spy + 1 end },
                function(e) cb_got = e end)
            assert.is_nil(cb_got)
            test_source.warm(true)
            test_source.warm(false)
            assert.equals(0, spy)
        end)

        it("is in-process without an observer", function()
            assert.equals("in-process", test_source.mode())
        end)
    end)

    describe("the loomtest adapter's daemon form (LOOMTEST.md §13.1)", function()
        it("shows the view's tree: unit-scoped ids, given suites, unit placeholders", function()
            local obs = fake_obs()
            views.set(obs, "tests", tview())
            adapter_mod.register()
            local a = loomtest.adapters()[1]
            assert.equals("dev", a.description())
            assert.is_nil(a.status())
            assert.is_function(a.start)
            local nodes = discover_now()
            local byid = {}
            for _, n in ipairs(nodes) do byid[n.id] = n end
            assert.equals("target", byid.n1.type)
            assert.equals("suite", byid.n2.type)
            assert.equals("n1", byid.n2.parent)
            assert.equals("test", byid.n3.type)
            assert.equals("failed", byid.n3.status)
            assert.equals("boom", byid.n3.message)
            assert.equals(4, byid.n3.duration)
            assert.equals("/src/a.cpp", byid.n3.file)
            -- The not-configured unit: one non-runnable node with its message.
            local placeholder
            for _, n in ipairs(nodes) do if not n.parent and n.id ~= "n1" then placeholder = n end end
            assert.is_not_nil(placeholder)
            assert.is_false(placeholder.runnable)
            assert.matches("not configured on this machine", placeholder.name)
        end)

        it("labels no_tests, pending and unknown unit states", function()
            local obs = fake_obs()
            views.set(obs, "tests", tview({ units = {
                { project = "a", configuration = "Debug", state = "no_tests", nodes = {} },
                { project = "b", configuration = "Debug", state = "pending", nodes = {} },
                { project = "c", configuration = "Debug", state = "brand_new", nodes = {} },
            } }))
            adapter_mod.register()
            local nodes = discover_now()
            assert.equals(3, #nodes)
            assert.matches("no tests", nodes[1].name)
            assert.matches("not discovered yet", nodes[2].name)
            for _, n in ipairs(nodes) do
                assert.is_false(n.runnable)
                assert.is_nil(n.status)
            end
        end)

        it("discovers once when the view is stale on the first ask, never while discovering", function()
            local obs, calls = fake_obs(function(m)
                if m == "discover" then return { outcome = "accepted", task_id = 7 } end
            end)
            views.set(obs, "tests", tview({ stale = true }))
            adapter_mod.register()
            discover_now()
            assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
            local c = discover_calls(calls)[1]
            assert.equals("/tests", c.object)
            assert.equals("loomworks.Tests", c.iface)
            assert.same({}, c.args)
            assert.same({ PATH = "/x" }, c.env)
            -- In flight: not again.
            discover_now()
            vim.wait(50)
            assert.equals(1, #discover_calls(calls))
            -- Its end; then a running discovery (another client's) holds it off.
            obs:_on_message({ kind = "task", task_id = 7, phase = "done", exit_code = 0 })
            vim.wait(50)
            views.set(obs, "tests", tview({ stale = true, discovering = 12 }))
            loomtest.refresh()
            vim.wait(50)
            assert.equals(1, #discover_calls(calls))
        end)

        it("refresh discovers with force; nothing in-process", function()
            local obs, calls = fake_obs(function(m)
                if m == "discover" then return { outcome = "accepted", task_id = 8 } end
            end)
            views.set(obs, "tests", tview())
            adapter_mod.register()
            discover_now()
            vim.wait(50)
            assert.equals(0, #discover_calls(calls))
            loomtest.refresh()
            assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
            assert.same({ force = true }, discover_calls(calls)[1].args)
        end)

        it("unloaded: an empty tree, refresh and runs refused with the status line", function()
            local obs, calls = fake_obs()
            views.set(obs, "tests", tview({ state = "unloaded", units = {} }))
            adapter_mod.register()
            local a = loomtest.adapters()[1]
            assert.is_true(a.status().blocked)
            assert.same({}, ids(discover_now()))
            loomtest.refresh()
            loomtest.run_all()
            vim.wait(50)
            assert.equals(0, #discover_calls(calls))
            local refused = 0
            for _, n in ipairs(notes) do
                if n.msg == "tests: workspace unloaded" then refused = refused + 1 end
            end
            assert.equals(2, refused)
        end)

        it("follows the view: an update re-renders the tree", function()
            local obs = fake_obs()
            views.set(obs, "tests", tview())
            adapter_mod.setup()
            adapter_mod.register()
            loomtest.discover()
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3") ~= nil end, 10))
            local v = tview()
            v.units[1].nodes[3].status = "passed"
            obs:_set_view("tests", v)
            assert.is_true(vim.wait(1000, function()
                local n = loomtest.get_node("n3")
                return n ~= nil and n.status == "passed"
            end, 10))
            obs:_on_closed(obs.conn)
            assert.is_true(vim.wait(1000, function() return #loomtest.nodes() == 0 end, 10))
        end)

        it("setup is idempotent: a repeated setup does not stack its listeners", function()
            fake_obs()
            adapter_mod.setup()
            adapter_mod.setup()
            adapter_mod.setup()
            vim.wait(300) -- earlier deferred re-renders drained
            local orig, renders = adapter_mod._render, 0
            adapter_mod._render = function() renders = renders + 1 end
            local ok, err = pcall(function()
                require("loomworks.events").emit("active_set_changed")
                vim.wait(400)
            end)
            adapter_mod._render = orig
            assert(ok, err)
            assert.equals(1, renders)
        end)

        it("a stale view arriving is shown, not discovered, by the re-render alone", function()
            local obs, calls = fake_obs(function(m)
                if m == "discover" then return { outcome = "accepted", task_id = 5 } end
            end)
            adapter_mod.setup()
            adapter_mod.register()
            obs:_set_view("tests", tview({ stale = true }))
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3") ~= nil end, 10))
            vim.wait(50)
            assert.equals(0, #discover_calls(calls))
            -- loomtest's own first ask then discovers it.
            discover_now()
            assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
        end)

        describe("with the explorer open, discovers on the turn to stale only", function()
            local explorer = require("loomtest.explorer")
            local orig_is_open
            before_each(function()
                orig_is_open = explorer.is_open
                explorer.is_open = function() return true end
            end)
            after_each(function() explorer.is_open = orig_is_open end)

            --- An observer whose discover replies `reply` (default: accepted,
            --- task 9), the adapter set up on a fresh (not stale) view.
            local function open_on_fresh_view(reply)
                local obs, calls = fake_obs(function(m)
                    if m == "discover" then return reply or { outcome = "accepted", task_id = 9 } end
                end)
                adapter_mod.setup()
                adapter_mod.register()
                obs:_set_view("tests", tview())
                assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3") ~= nil end, 10))
                return obs, calls
            end

            --- Later view and runtime updates, still stale: each re-renders.
            local function more_updates(obs)
                obs:_set_view("tests", tview({ stale = true }))
                vim.wait(50)
                obs:_emit("daemon_runtime_changed", obs)
                vim.wait(50)
                obs:_set_view("tests", tview({ stale = true }))
                vim.wait(50)
            end

            it("the turn to stale discovers exactly once", function()
                local obs, calls = open_on_fresh_view()
                vim.wait(50)
                assert.equals(0, #discover_calls(calls))
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
                more_updates(obs)
                assert.equals(1, #discover_calls(calls))
                -- It succeeds, the view stays stale: not again until it turns.
                obs:_on_message({ kind = "task", task_id = 9, phase = "done", exit_code = 0 })
                more_updates(obs)
                assert.equals(1, #discover_calls(calls))
                obs:_set_view("tests", tview())
                vim.wait(50)
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 2 end, 10))
            end)

            it("a cancelled discovery is not sent again", function()
                local obs, calls = open_on_fresh_view()
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
                obs:_on_message({ kind = "task", task_id = 9, phase = "done", exit_code = 130,
                    error = "test discovery stopped: cancelled" })
                more_updates(obs)
                discover_now()
                vim.wait(50)
                assert.equals(1, #discover_calls(calls))
            end)

            it("a failed discovery is not retried", function()
                local obs, calls = open_on_fresh_view()
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
                obs:_on_message({ kind = "task", task_id = 9, phase = "done", exit_code = 1 })
                more_updates(obs)
                assert.equals(1, #discover_calls(calls))
            end)

            it("a refused discovery is not repeated on later updates", function()
                local obs, calls = open_on_fresh_view({ outcome = "refused", message = "not now" })
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
                more_updates(obs)
                assert.equals(1, #discover_calls(calls))
                local warned = 0
                for _, n in ipairs(notes) do if n.msg == "loomworks: not now" then warned = warned + 1 end end
                assert.equals(1, warned)
                -- A refresh still forces one.
                loomtest.refresh()
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 2 end, 10))
                assert.same({ force = true }, discover_calls(calls)[2].args)
            end)

            it("a turn to stale during a discovery is looked at when it succeeds", function()
                local obs, calls = open_on_fresh_view()
                obs:_set_view("tests", tview({ stale = true }))
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 1 end, 10))
                obs:_set_view("tests", tview())
                vim.wait(50)
                obs:_set_view("tests", tview({ stale = true }))
                vim.wait(50)
                assert.equals(1, #discover_calls(calls))
                obs:_on_message({ kind = "task", task_id = 9, phase = "done", exit_code = 0 })
                assert.is_true(vim.wait(1000, function() return #discover_calls(calls) == 2 end, 10))
                vim.wait(50)
                assert.equals(2, #discover_calls(calls))
            end)
        end)

    end)

    describe("runs, debug and output through Tests/1 (step 5m C2, §19.16 Tests)", function()
        local dbg = require("loomworks.debug")
        local runner = require("loomtest.runner")
        local orig_installed, orig_run, orig_hint
        local dap_runs, hints

        before_each(function()
            orig_installed, orig_run, orig_hint = dbg.adapter_installed, dbg.run, dbg.adapter_hint
            dap_runs, hints = {}, {}
            dbg.adapter_installed = function(a) return a == "codelldb" end
            dbg.run = function(spec, cb)
                local r = { spec = spec, cb = cb, stopped = 0 }
                dap_runs[#dap_runs + 1] = r
                return true, { stop = function() r.stopped = r.stopped + 1; cb.on_terminated() end }
            end
            dbg.adapter_hint = function(a, l) hints[#hints + 1] = { adapter = a, language = l } end
        end)
        after_each(function()
            dbg.adapter_installed, dbg.run, dbg.adapter_hint = orig_installed, orig_run, orig_hint
        end)

        local function calls_of(calls, method, object)
            local out = {}
            for _, c in ipairs(calls) do
                if c.method == method and (not object or c.object == object) then out[#out + 1] = c end
            end
            return out
        end

        local function errors()
            local out = {}
            for _, n in ipairs(notes) do
                if n.level == vim.log.levels.ERROR then out[#out + 1] = n.msg end
            end
            return out
        end

        --- The adapter set up on a fresh view; the fake answers `answer`.
        local function on_view(answer, view)
            local obs, calls = fake_obs(answer)
            obs._tests_seq = 1
            adapter_mod.setup()
            adapter_mod.register()
            obs:_set_view("tests", view or tview())
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3") ~= nil end, 10))
            return obs, calls
        end

        local function results(obs, seq, task_id, cases)
            obs:_on_message({ kind = "signal", object = "/tests", iface = "loomworks.Tests", v = 1,
                name = "results", args = { seq = seq, task_id = task_id, cases = cases } })
        end

        it("a run is one owned run_cases; its results move the nodes; nothing runs in-process", function()
            local obs, calls = on_view(function(m)
                if m == "run_cases" then return { outcome = "accepted", task_id = 11 } end
            end)
            local spec_asked = 0
            local a = loomtest.adapters()[1]
            local orig = a.run
            a.run = function(...) spec_asked = spec_asked + 1; return orig(...) end
            loomtest.run("n2")
            local rc = calls_of(calls, "run_cases")
            assert.equals(1, #rc)
            assert.equals("/tests", rc[1].object)
            assert.equals("loomworks.Tests", rc[1].iface)
            assert.same({ select = { { id = "n2" } } }, rc[1].args)
            assert.is_table(rc[1].env)
            vim.wait(50)
            results(obs, 2, 11, { { id = "n3", status = "running" } })
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3").status == "running" end, 10))
            -- The held view carries the delta (a re-render shows it).
            assert.equals("running", views.daemon_state(obs, "tests").units[1].nodes[3].status)
            results(obs, 3, 11, { { id = "n3", status = "passed", duration = 5 } })
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3").status == "passed" end, 10))
            obs:_on_message({ kind = "task", task_id = 11, phase = "done", exit_code = 0,
                result = { cases = { { id = "n3", status = "passed", duration = 5 } },
                    counts = { passed = 1, failed = 0, skipped = 0, errored = 0 } } })
            vim.wait(50)
            assert.equals("passed", loomtest.get_node("n3").status)
            assert.same({}, errors())
            assert.equals(0, spec_asked)
        end)

        it("failed tests end the run quietly; a run that ran no tests fails with its error", function()
            local n = 20
            local obs, calls = on_view(function(m)
                if m == "run_cases" then
                    n = n + 1
                    return { outcome = "accepted", task_id = n }
                end
            end)
            loomtest.run("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 21, phase = "done", exit_code = 1,
                error = "1 of 1 tests failed", result = { cases = { { id = "n3", status = "failed", message = "x" } } } })
            vim.wait(50)
            assert.equals("failed", loomtest.get_node("n3").status)
            assert.same({}, errors())
            loomtest.run("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 22, phase = "done", exit_code = 1, error = "build failed" })
            assert.is_true(vim.wait(1000, function() return #errors() == 1 end, 10))
            assert.equals("loomtest: build failed", errors()[1])
            assert.equals(2, #calls_of(calls, "run_cases"))
        end)

        it("a run whose discovery failed reports it, its cases still applied (review of #254)", function()
            local n = 50
            local obs = on_view(function(m)
                if m == "run_cases" then n = n + 1; return { outcome = "accepted", task_id = n } end
            end)
            loomtest.run("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 51, phase = "done", exit_code = 1,
                error = "discovery of b failed", result = { cases = { { id = "n3", status = "passed" } },
                    counts = { passed = 1, failed = 0, skipped = 0, errored = 0 },
                    discovery_error = "discovery of b failed" } })
            assert.is_true(vim.wait(1000, function() return #errors() == 1 end, 10))
            assert.equals("loomtest: discovery of b failed", errors()[1])
            assert.equals("passed", loomtest.get_node("n3").status)
            loomtest.run("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 52, phase = "done", exit_code = 1,
                error = "1 of 1 tests failed; discovery of b failed",
                result = { cases = { { id = "n3", status = "failed" } },
                    discovery_error = "discovery of b failed" } })
            assert.is_true(vim.wait(1000, function() return #errors() == 2 end, 10))
            assert.equals("loomtest: 1 of 1 tests failed; discovery of b failed", errors()[2])
            assert.equals("failed", loomtest.get_node("n3").status)
            -- The field decides, never the message text: failed cases and no
            -- discovery_error end quietly whatever the error says.
            loomtest.run("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 53, phase = "done", exit_code = 1,
                error = "some other wording", result = { cases = { { id = "n3", status = "errored" } },
                    counts = { passed = 0, failed = 0, skipped = 0, errored = 1 } } })
            vim.wait(100)
            assert.equals(2, #errors())
        end)

        it("results before the run's accepted reply feed its own sink (review of #254)", function()
            local saved = package.loaded["fidget.progress"]
            local made = {}
            package.loaded["fidget.progress"] = { handle = { create = function()
                local h = { finish = function() end }
                made[#made + 1] = h
                return h
            end } }
            local ok, e = pcall(function()
                local obs, calls = on_view(function() end)
                loomtest.run("n3")
                assert.equals(1, #made)
                assert.equals("building...", made[1].message)
                results(obs, 2, 61, { { id = "n3", status = "running" } })
                vim.wait(50)
                local rc = calls_of(calls, "run_cases")
                rc[1].cb({ outcome = "accepted", task_id = 61 })
                assert.is_true(vim.wait(1000, function() return made[1].message ~= "building..." end, 10))
                assert.equals("running", loomtest.get_node("n3").status)
                assert.is_true(runner.cancel())
            end)
            package.loaded["fidget.progress"] = saved
            assert(ok, e)
        end)

        it("a results signal at or below the subscription's seq is dropped (review of #254)", function()
            local obs = on_view(function() end)
            obs._feat[observer.TESTS.feature] = "pending"
            obs._tests_seq = nil
            results(obs, 4, 99, { { id = "n3", status = "running" } })
            results(obs, 6, 99, { { id = "n1", status = "passed" } })
            vim.wait(50)
            assert.equals("failed", loomtest.get_node("n3").status)
            obs._feat[observer.TESTS.feature] = "subscribed"
            obs:_tests_subscribed({ seq = 5 })
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n1").status == "passed" end, 10))
            results(obs, 6, 99, { { id = "n3", status = "skipped" } })
            vim.wait(50)
            assert.equals("failed", loomtest.get_node("n3").status)
            assert.equals(6, obs._tests_seq)
        end)

        it("run-all selects nothing, no-build sends no_build; a refusal says why once", function()
            local _, calls = on_view(function(m)
                if m == "run_cases" then return { outcome = "refused", message = "the node is stale" } end
            end)
            loomtest.run_all_no_build()
            local rc = calls_of(calls, "run_cases")
            assert.same({ no_build = true }, rc[1].args)
            assert.is_true(vim.wait(1000, function() return #errors() == 1 end, 10))
            assert.equals("loomtest: the node is stale", errors()[1])
        end)

        it("stopping the run cancels its task", function()
            local _, calls = on_view(function(m)
                if m == "run_cases" then return { outcome = "accepted", task_id = 31 } end
            end)
            loomtest.run("n1")
            vim.wait(50)
            assert.is_true(runner.cancel())
            local c = calls_of(calls, "cancel")
            assert.equals(1, #c)
            assert.same({ task_id = 31 }, c[1].args)
        end)

        it("another client's results move the nodes; a seq gap re-gets the tests view", function()
            local obs, calls = on_view(function(m)
                if m == "get" then return tview({ stale = true }) end
            end)
            results(obs, 2, 99, { { id = "n3", status = "running" } })
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3").status == "running" end, 10))
            assert.equals(0, #calls_of(calls, "get"))
            results(obs, 5, 99, { { id = "n3", status = "passed" } })
            assert.is_true(vim.wait(1000, function() return #calls_of(calls, "get", "/views") == 1 end, 10))
            assert.is_true(vim.wait(1000, function() return views.daemon_state(obs, "tests").stale == true end, 10))
        end)

        it("debug: prepare_debug, the returned spec to the debugger, collect when it ends", function()
            local obs, calls = on_view(function(m)
                if m == "prepare_debug" then return { outcome = "accepted", task_id = 41 } end
                if m == "collect" then return { outcome = "ok", cases = { { id = "n3", status = "passed" } } } end
            end)
            loomtest.debug("n3")
            local pd = calls_of(calls, "prepare_debug")
            assert.equals(1, #pd)
            assert.equals("/tests", pd[1].object)
            assert.same({ select = { id = "n3" } }, pd[1].args)
            assert.is_table(pd[1].env)
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 41, phase = "done", exit_code = 0, result = {
                debug = { program = "/b/a_test", args = { "--gtest_filter=Math.Add" }, cwd = "/b",
                    language = "c++", adapters = { { language = "c++", adapter = "codelldb" } } },
                prepared = "tok" } })
            assert.is_true(vim.wait(1000, function() return #dap_runs == 1 end, 10))
            local s = dap_runs[1].spec
            assert.equals("codelldb", s.adapter)
            assert.equals("/b/a_test", s.program)
            assert.same({ "--gtest_filter=Math.Add" }, s.args)
            assert.equals("/b", s.cwd)
            assert.equals(0, #calls_of(calls, "collect"))
            dap_runs[1].cb.on_terminated()
            local col = calls_of(calls, "collect")
            assert.equals(1, #col)
            assert.same({ prepared = "tok" }, col[1].args)
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3").status == "passed" end, 10))
            assert.same({}, errors())
        end)

        it("debug with an adapter that is not installed: the hint, no session, collect at once", function()
            local obs, calls = on_view(function(m)
                if m == "prepare_debug" then return { outcome = "accepted", task_id = 42 } end
                if m == "collect" then return { outcome = "ok", cases = {} } end
            end)
            loomtest.debug("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 42, phase = "done", exit_code = 0, result = {
                debug = { program = "/b/a_test", args = {}, cwd = "/b", language = "c++",
                    adapters = { { language = "c++", adapter = "gdb" } } }, prepared = "tok2" } })
            assert.is_true(vim.wait(1000, function() return #calls_of(calls, "collect") == 1 end, 10))
            assert.same({ prepared = "tok2" }, calls_of(calls, "collect")[1].args)
            assert.equals(0, #dap_runs)
            assert.same({ { adapter = "gdb", language = "c++" } }, hints)
        end)

        it("stopping a debug cancels its prepare, or after it stops the session, which collects", function()
            local obs, calls = on_view(function(m)
                if m == "prepare_debug" then return { outcome = "accepted", task_id = 43 } end
                if m == "collect" then return { outcome = "ok", cases = { { id = "n3", status = "passed" } } } end
            end)
            loomtest.debug("n3")
            vim.wait(50)
            assert.is_true(runner.cancel())
            assert.same({ task_id = 43 }, calls_of(calls, "cancel")[1].args)
            assert.is_false(runner.cancel())
            loomtest.debug("n3")
            vim.wait(50)
            obs:_on_message({ kind = "task", task_id = 43, phase = "done", exit_code = 0, result = {
                debug = { program = "/b/a_test", args = {}, cwd = "/b", language = "c++",
                    adapters = { { language = "c++", adapter = "codelldb" } } }, prepared = "tok3" } })
            assert.is_true(vim.wait(1000, function() return #dap_runs == 1 end, 10))
            assert.is_true(runner.cancel())
            assert.equals(1, dap_runs[1].stopped)
            assert.is_true(vim.wait(1000, function() return #calls_of(calls, "collect") == 1 end, 10))
            assert.same({ prepared = "tok3" }, calls_of(calls, "collect")[1].args)
            assert.is_true(vim.wait(1000, function() return loomtest.get_node("n3").status == "passed" end, 10))
        end)

        it("the test prepare_debug never collides with Launch/1's", function()
            local obs, calls = fake_obs(function() return { outcome = "accepted", task_id = 1 } end)
            obs._feat[observer.LAUNCH.feature] = "available"
            obs:start_owned("prepare_debug", {}, { on_reply = function() end, on_done = function() end })
            obs:start_owned("prepare_test_debug", {}, { on_reply = function() end, on_done = function() end })
            assert.equals("/launch", calls[1].object)
            assert.equals("/tests", calls[2].object)
            assert.equals("prepare_debug", calls[2].method)
            assert.is_true(obs:can_call("prepare_test_debug"))
            obs:_degrade("prepare_test_debug", { code = "unknown_method" })
            assert.matches("loomworks%.Tests/1%.prepare_debug", obs._method_notes[1])
            assert.matches("tests unavailable$", obs._method_notes[1])
            assert.is_false(obs:can_call("prepare_test_debug"))
            assert.is_true(obs:can_call("prepare_debug"))
        end)

        it("output and error locations are read with result when shown, once", function()
            local file = root .. "/a_test.cpp"
            local view = tview()
            view.units[1].nodes[3].file = file
            local _, calls = on_view(function(m, args)
                if m == "result" then
                    return { id = args.id, status = "failed", message = "boom", output = "the output",
                        errors = { { message = "Expected 2", file = file, line = 4 } } }
                end
            end, view)
            local got
            loomtest.load_result("n3", function(node) got = node end)
            assert.is_true(vim.wait(1000, function() return got ~= nil end, 10))
            assert.same({ id = "n3" }, calls_of(calls, "result")[1].args)
            assert.equals("the output", got._output)
            assert.equals(4, got._errors[1].line)
            loomtest.load_result("n3", function() end)
            assert.equals(1, #calls_of(calls, "result"))
            -- Inline: a failed node's error detail in its file's buffer.
            loomtest.get_node("n3")._result_loaded = nil
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(buf, file)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "", "", "", "" })
            require("loomtest.inline").update_buf(buf)
            assert.is_true(vim.wait(1000, function()
                for _, d in ipairs(vim.diagnostic.get(buf)) do
                    if d.lnum == 3 and d.message == "Expected 2" then return true end
                end
                return false
            end, 10))
            assert.equals(2, #calls_of(calls, "result"))
            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)

    describe("neotest (not available in daemon mode)", function()
        it("finds no root and says so once", function()
            fake_obs()
            local neo = require("loomworks.neotest")
            neo._reset_daemon_notice()
            assert.is_nil(neo.root(ws.root))
            assert.is_nil(neo.root(ws.root))
            assert.is_false(neo.is_test_file(ws.root .. "/a_test.cpp"))
            vim.wait(200)
            local n = 0
            for _, x in ipairs(notes) do
                if x.msg == "loomworks: neotest is not available with the workspace daemon — use the loomtest explorer"
                then n = n + 1 end
            end
            assert.equals(1, n)
        end)
    end)
end)

describe("loomtest adapter status (LOOMTEST.md §4.2)", function()
    local orig_notify, notes
    before_each(function()
        notes = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        loomtest.clear()
    end)
    after_each(function()
        vim.notify = orig_notify
        loomtest.unregister_adapter("fake")
        loomtest.clear()
    end)

    it("a blocked status refuses run, debug and refresh with its text", function()
        local invalidated, ran = 0, 0
        loomtest.register_adapter({
            name = "fake",
            description = function() return "x" end,
            discover_async = function(cb) cb({ { id = "t", name = "t", type = "test", runnable = true } }) end,
            run = function() ran = ran + 1 end,
            run_all = function() ran = ran + 1 end,
            run_suite = function() ran = ran + 1 end,
            invalidate = function() invalidated = invalidated + 1 end,
            get_cursor_test = function() return nil end,
            status = function() return { text = "tests: nope", level = "warn", blocked = true } end,
        })
        loomtest.run("t")
        loomtest.debug("t")
        loomtest.run_all()
        loomtest.refresh()
        assert.equals(0, ran)
        assert.equals(0, invalidated)
        assert.equals(4, #notes)
        for _, n in ipairs(notes) do assert.equals("tests: nope", n.msg) end
        assert.equals("tests: nope", loomtest.blocked())
    end)
end)
