-- The editor's test runs in the workspace daemon (spec §19.15 "Tests",
-- §19.20 `Tests/1`, step 5m part B2): `run_cases`, the `results` signal,
-- `result`, `prepare_debug` and `collect`, beyond the golden transcripts
-- (spec/protocol/transcripts/loomworks/Tests.1.json). Every frame goes
-- through the conformance engine's session (validated against the schemas,
-- signal `seq` gaps checked).
--
-- The fixture is the conformance runner's `tests` fixture (the harness-only
-- teststub module, tests/fixtures/teststub) with the profile `dev` active
-- and its own tests.json: one gtest-like program `fake` with the cases
-- Math.Add (passes), Math.Sub (fails at math.cpp:7) and Str.Len (passes).
-- Discovery is the daemon's (`Tests/1.discover`).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local engine = require("loomworks.proto.conformance")
local trust = require("loomworks.trust")
local test_store = require("loomworks.daemon.test_store")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

require("loomworks.daemon.client").TIMEOUT_MS = 30000

--- The tests of the fixture's project `app` (teststub's tests.json).
local TESTS_JSON = {
    targets = { { name = "fake", cases = { "Math.Add", "Math.Sub", "Str.Len" }, file = "math.cpp", line = 3 } },
    results = { ["Math.Sub"] = "failed" },
    failures = { ["Math.Sub"] = "math.cpp:7" },
}

--- The `tests` fixture with the tests above, signed with `key`.
local function fixture(key)
    local root = runner.fixture("tests", key)
    runner.register_teststub()
    local f = assert(io.open(root .. "/app/tests.json", "wb"))
    f:write(vim.json.encode(TESTS_JSON))
    f:close()
    return root
end

local TESTS = { object = "/tests", iface = "loomworks.Tests", v = 1 }

local function call(req_id, object, iface, method, args, no_env)
    return { kind = "call", req_id = req_id, object = object, iface = iface, v = 1, method = method,
        args = args or vim.empty_dict(), env = (not no_env) and { ["$var"] = "env" } or nil }
end

--- A session on a loopback daemon of `root` (hello sent, welcome taken).
local function open(root, key, env_over)
    trust._set_key_path(key)
    local d = runner.loopback_driver(root)
    local env = runner.wire_env(uv.os_environ())
    for k, v in pairs(env_over or {}) do env[k] = v end
    local vars = { lw_version = require("loomworks.daemon.version").identity(), root = root, env = env }
    local s = engine.session(d, { vars = vars })
    -- (The engine raises tables; busted shows only strings.)
    local function guard(fn, ...)
        local ok, r = pcall(fn, ...)
        if not ok then error(type(r) == "table" and (r.conformance or vim.inspect(r)) or r, 2) end
        return r
    end
    local function send(frame) guard(s.send, s, assert(engine.expand(frame, s.vars))) end
    send(engine.hello({}, vars))
    s.vars.welcome = guard(s.expect, s, { kind = "welcome" })
    local h = { d = d, s = s, send = send, srv = d.server }
    function h.expect(p, ms) return guard(s.expect, s, p, ms or 60000) end
    function h.ok(req_id, result) return h.expect({ kind = "ok", req_id = req_id, result = result }) end
    --- Subscribe to /tests results.
    function h.subscribe(req_id)
        send(call(req_id, "/", "loomworks.Root", "subscribe",
            { object = TESTS.object, iface = TESTS.iface, v = 1, signals = { "results" } }, true))
        h.ok(req_id, { sub_id = { ["$bind"] = "sub" } })
    end
    --- A Build/1 operation of `dev`, to its end.
    function h.op(req_id, method)
        send(call(req_id, "/build", "loomworks.Build", method, { profile = { key = "dev" } }))
        h.ok(req_id, { outcome = "accepted", task_id = { ["$bind"] = "t" .. req_id } })
        h.expect({ kind = "task", task_id = { ["$var"] = "t" .. req_id }, phase = "done", exit_code = 0 }, 120000)
    end
    --- Discover the unit's tests in the daemon (`Tests/1.discover`) and
    --- return the node ids by name (`fake`, `Math`, `Math.Add`, …).
    function h.discover()
        h.discoveries = (h.discoveries or 0) + 1
        local rid, var = 900 + h.discoveries, "disc" .. h.discoveries
        send(call(rid, TESTS.object, TESTS.iface, "discover", vim.empty_dict()))
        h.ok(rid, { outcome = "accepted", task_id = { ["$bind"] = var } })
        h.expect({ kind = "task", task_id = { ["$var"] = var }, phase = "done", exit_code = 0,
            result = { tests = 3, failed = 0 } }, 60000)
        local ws = h.srv.service.ws
        local unit = ws._active_profile:projects()[1]._config_unit
        local idx = test_store.of(h.srv.service):index(ws)
        local ids = {}
        for _, rec in ipairs(idx.list) do
            ids[rec.entry and rec.entry.name or rec.name] = rec.id
        end
        return ids, unit
    end
    --- Every received `results` signal so far (taken out of the queue).
    function h.results()
        while guard(s._pull, s, 0) do end
        local out, keep = {}, {}
        for _, f in ipairs(s.queue) do
            if f.kind == "signal" and f.name == "results" then out[#out + 1] = f else keep[#keep + 1] = f end
        end
        s.queue = keep
        return out
    end
    --- Drop the task frames that arrived (lines, output, progress).
    function h.drain()
        while guard(s._pull, s, 0) do end
        local keep = {}
        for _, f in ipairs(s.queue) do
            if f.kind ~= "task" and f.kind ~= "model_change" and not (f.kind == "signal" and f.name ~= "results") then
                keep[#keep + 1] = f
            end
        end
        s.queue = keep
    end
    --- Lines of a task's frames still queued (its `line` / `output` text).
    function h.text(task_id)
        while guard(s._pull, s, 0) do end
        local t = {}
        for _, f in ipairs(s.queue) do
            if f.kind == "task" and f.task_id == task_id and (f.phase == "line" or f.phase == "output") then
                t[#t + 1] = tostring(f.text)
            end
        end
        return table.concat(t, "")
    end
    function h.close()
        pcall(d.close)
        trust._set_key_path(nil)
    end
    return h
end

--- The statuses `results` signals carried, per id, in order.
local function statuses(frames)
    local by = {}
    for _, f in ipairs(frames) do
        for _, c in ipairs(f.args.cases) do
            by[c.id] = by[c.id] or {}
            table.insert(by[c.id], c.status)
        end
    end
    return by
end

--- The `lw-test-*.xml` files in the workspace's .nvim/tmp.
local function results_files(root)
    local out = {}
    local h = uv.fs_scandir(root .. "/.nvim/tmp")
    while h do
        local name = uv.fs_scandir_next(h)
        if not name then break end
        if name:match("^lw%-test%-") then out[#out + 1] = name end
    end
    return out
end

describe("Tests/1 runs in the daemon (§19.15 Tests, §19.20 Tests/1)", function()
    local h, key, root

    before_each(function()
        key = H.tmp() .. "/trust.key"
        root = fixture(key)
    end)
    after_each(function()
        if h then h.close() end
        h = nil
    end)

    it("run-all builds, runs every case with live results and ends with the cases, counts and last results", function()
        h = open(root, key)
        h.subscribe(1)
        h.op(2, "configure")
        local ids = h.discover()
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", vim.empty_dict()))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" }, profile_key = "dev" })
        h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "start",
            meta = { method = "run_cases", kind = "test", profile = "dev",
                units = { { project = "app", configuration = { ["$type"] = "string" } } } } })
        local done = h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 1,
            result = { exit_code = 1, error = "1 of 3 tests failed",
                counts = { passed = 2, failed = 1, skipped = 0, errored = 0 } } }, 120000)
        local by = {}
        for _, c in ipairs(done.result.cases) do by[c.id] = c end
        assert.equals(3, #done.result.cases)
        assert.equals("passed", by[ids["Math.Add"]].status)
        assert.equals("failed", by[ids["Math.Sub"]].status)
        assert.equals("passed", by[ids["Str.Len"]].status)
        assert.equals(0, by[ids["Math.Sub"]].duration)
        -- The build ran inside the task, before the test step.
        local sig = statuses(h.results())
        -- Live: each case's current status (batched: a later one replaces an
        -- earlier one of the same batch), the step's end resends the
        -- outcome; the suites and the target get theirs at the run's end.
        assert.equals("passed", sig[ids["Math.Add"]][#sig[ids["Math.Add"]]])
        assert.equals("failed", sig[ids["Math.Sub"]][#sig[ids["Math.Sub"]]])
        assert.equals("failed", sig[ids["Math"]][#sig[ids["Math"]]])
        assert.equals("passed", sig[ids["Str"]][#sig[ids["Str"]]])
        assert.equals("failed", sig[ids["fake"]][#sig[ids["fake"]]])
        -- Every signal of the run names its task.
        for _, f in ipairs(h.results()) do assert.equals(h.s.vars.run, f.args.task_id) end
        -- The per-run results file is gone; the fixed path never written.
        assert.same({}, results_files(root))
        assert.is_nil(uv.fs_stat(root .. "/out/Debug/teststub-fake.xml"))
        -- result: the failed case's last result, output and error location.
        h.drain()
        h.send(call(4, TESTS.object, TESTS.iface, "result", { id = ids["Math.Sub"] }))
        local r = h.ok(4, { id = ids["Math.Sub"], status = "failed", duration = 0 }).result
        assert.truthy(r.message:find("math.cpp:7", 1, true), r.message)
        assert.equals(1, #r.errors)
        assert.equals(7, r.errors[1].line)
        assert.truthy(r.errors[1].file:find("math.cpp$"), r.errors[1].file)
        -- A passed case's output is the step's lines between its start and end.
        h.send(call(5, TESTS.object, TESTS.iface, "result", { id = ids["Math.Add"] }))
        local ra = h.ok(5, { id = ids["Math.Add"], status = "passed" }).result
        assert.truthy(ra.output and ra.output:find("output of Math.Add", 1, true), vim.inspect(ra))
        assert.same({}, ra.errors)
        -- The store's view seam: committed statuses are the run's results.
        local store = test_store.of(h.srv.service)
        assert.equals(0, vim.tbl_count(store.live))
    end)

    it("a selection runs one filtered invocation per program; no_build builds nothing", function()
        h = open(root, key)
        h.subscribe(1)
        h.op(2, "configure")
        local ids = h.discover()
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases",
            { select = { { id = ids["Math.Add"] }, { id = ids["Str"] } }, no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        local done = h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 0,
            result = { exit_code = 0, counts = { passed = 2, failed = 0, skipped = 0, errored = 0 } } }, 120000)
        assert.equals(2, #done.result.cases)
        local text = h.text(h.s.vars.run)
        assert.truthy(text:find("==> [test] app: fake (2 selected)", 1, true), text)
        assert.truthy(text:find("TESTS OK: dev (2 passed)", 1, true), text)
        assert.falsy(text:find("building", 1, true), text)
        local sig = statuses(h.results())
        assert.is_nil(sig[ids["Math.Sub"]], "an unselected case was reported")
        assert.equals("passed", sig[ids["Str"]][#sig[ids["Str"]]])
    end)

    it("a stale or non-runnable node is refused before acceptance; a node with no last result answers only its id", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids, unit = h.discover()
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] .. "x" } } }))
        h.ok(2, { outcome = "refused", message = { ["$pattern"] = "^no such test" }, exit_code = 1 })
        h.send(call(3, TESTS.object, TESTS.iface, "result", { id = ids["Math.Add"] }))
        -- (No last result yet: only the id and no errors.)
        h.ok(3, { id = ids["Math.Add"], errors = {}, status = { ["$absent"] = true } })
        -- A node discovery marked not runnable (e.g. a missing saved entry).
        for _, e in ipairs(test_store.of(h.srv.service).records[unit].entries) do
            if e.name == "Str.Len" then e.runnable, e.message = false, "gone" end
        end
        h.send(call(4, TESTS.object, TESTS.iface, "prepare_debug", { select = { id = ids["Str.Len"] } }))
        h.ok(4, { outcome = "refused", message = "test 'Str.Len' cannot be run: gone", exit_code = 1 })
        assert.is_nil(next(test_store.of(h.srv.service).live))
    end)

    it("a cancel kills the running step, ends nonzero and drops the statuses still queued or running", function()
        h = open(root, key, { LW_TEST_RUN_SLEEP = "60000", LW_TEST_RUN_SLEEP_CASE = "Str.Len" })
        h.subscribe(1)
        h.op(2, "configure")
        local ids = h.discover()
        h.send(call(10, "/", "loomworks.Root", "subscribe",
            { object = "/views", iface = "loomworks.view.Tests", v = 1, signals = { "update" } }, true))
        h.ok(10, { sub_id = { ["$bind"] = "vsub" } })
        --- The view `update` signals received so far.
        local function updates()
            while h.s:_pull(0) do end
            local n = 0
            for _, f in ipairs(h.s.queue) do
                if f.kind == "signal" and f.name == "update" then n = n + 1 end
            end
            return n
        end
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", { no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        -- Wait until Str.Len runs.
        local store = test_store.of(h.srv.service)
        local key_len = store:key_of(ids["Str.Len"])
        assert.is_true(vim.wait(60000, function()
            while h.s:_pull(0) do end
            return store.live[key_len] == "running"
        end, 20), "Str.Len never ran")
        -- Per-case progress (Math.Add passed, Str.Len running) travels as
        -- `results` only: the view's `update` waits for the run's end.
        local before = updates()
        require("loomworks.daemon.views").check(h.srv.service)
        assert.equals(before, updates())
        h.send(call(4, "/tasks", "loomworks.Tasks", "cancel", { task_id = { ["$var"] = "run" } }, true))
        h.ok(4, { outcome = "ok" })
        h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 130 }, 60000)
        assert.equals(0, vim.tbl_count(store.live))
        assert.is_true(updates() > before, "the run's end sent no view update")
        -- Math.Add finished before the cancel: its result stays.
        assert.equals("passed", store.results[store:key_of(ids["Math.Add"])].status)
        assert.is_nil(store.results[key_len])
        assert.same({}, results_files(root))
        h.drain()
        h.results()
    end)

    it("prepare_debug ends with the debug spec and a token; collect records the results the program wrote", function()
        h = open(root, key)
        h.subscribe(1)
        h.op(2, "configure")
        local ids = h.discover()
        h.send(call(3, TESTS.object, TESTS.iface, "prepare_debug", { select = { id = ids["Math.Sub"] }, no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "dbg" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "dbg" }, phase = "start",
            meta = { method = "prepare_debug", kind = "debug" } })
        local done = h.expect({ kind = "task", task_id = { ["$var"] = "dbg" }, phase = "done", exit_code = 0,
            result = { exit_code = 0, prepared = { ["$bind"] = "token" },
                debug = { language = "c++", adapters = { { language = "c++" } },
                    env = { GTEST_FILTER = "Math.Sub" } } } }, 120000)
        local debug = done.result.debug
        local out
        for _, a in ipairs(debug.args) do out = a:match("^%-%-gtest_output=xml:(.+)$") or out end
        assert.truthy(out and out:find("/.nvim/tmp/lw-test-", 1, true), vim.inspect(debug.args))
        -- The client's debugger runs the program (here: the test runs it).
        local r = vim.system({ debug.program, unpack(debug.args) },
            { cwd = debug.cwd, env = debug.env }):wait()
        assert.equals(1, r.code, r.stderr)
        assert.is_not_nil(uv.fs_stat(out))
        h.drain()
        h.send(call(4, TESTS.object, TESTS.iface, "collect", { prepared = { ["$var"] = "token" } }))
        local c = h.ok(4, { outcome = "ok" }).result
        assert.same({ { id = ids["Math.Sub"], status = "failed", duration = 0,
            message = c.cases[1].message } }, c.cases)
        assert.is_nil(uv.fs_stat(out), "collect left the results file")
        local sig = h.expect({ kind = "signal", object = "/tests", name = "results" })
        assert.is_nil(sig.args.task_id)
        -- The token is gone: a second collect is refused.
        h.send(call(5, TESTS.object, TESTS.iface, "collect", { prepared = { ["$var"] = "token" } }))
        h.ok(5, { outcome = "refused", exit_code = 1 })
    end)

    it("a task that ends while it takes its build directory frees it: the next run on it still starts", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids = h.discover()
        -- prepare_debug without a build ends inside the queue's grant.
        h.send(call(2, TESTS.object, TESTS.iface, "prepare_debug", { select = { id = ids["fake"] }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "dbg" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "dbg" }, phase = "done", exit_code = 0 }, 120000)
        assert.is_nil(next(test_store.of(h.srv.service).held), "the ended task still holds its build directory")
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", { no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 1 }, 30000)
    end)

    it("run-all first discovers a unit not discovered yet instead of skipping it", function()
        h = open(root, key)
        h.subscribe(1)
        h.op(2, "configure")
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", vim.empty_dict()))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        local done = h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 1,
            result = { exit_code = 1, error = "1 of 3 tests failed",
                counts = { passed = 2, failed = 1, skipped = 0, errored = 0 } } }, 120000)
        assert.equals(3, #done.result.cases)
        local text = h.text(h.s.vars.run)
        assert.truthy(text:find("==> [discover] app/", 1, true), text)
        assert.truthy(text:find("==> [test] app: fake", 1, true), text)
        -- (One step per top-level node: the program once, not a run-all command.)
        local _, steps = text:gsub("==> %[test%]", "")
        assert.equals(1, steps)
        h.drain()
        h.results()
    end)

    it("a stale tree's node runs after the run re-discovers its unit (a build dropped its entries)", function()
        h = open(root, key)
        h.subscribe(1)
        h.op(2, "configure")
        local ids = h.discover()
        h.op(3, "build")
        h.send(call(4, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(4, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        local done = h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 0,
            result = { exit_code = 0, counts = { passed = 1, failed = 0, skipped = 0, errored = 0 } } }, 120000)
        assert.same({ { id = ids["Math.Add"], status = "passed", duration = 0 } },
            vim.tbl_map(function(c) return { id = c.id, status = c.status, duration = c.duration } end,
                done.result.cases))
        local text = h.text(h.s.vars.run)
        assert.truthy(text:find("==> [discover] app/", 1, true), text)
        h.drain()
        h.results()
    end)

    it("a selected node a stale tree's re-discovery no longer has ends the run as a stale reference", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids = h.discover()
        local f = assert(io.open(root .. "/app/tests.json", "wb"))
        f:write(vim.json.encode({ targets = { { name = "fake", cases = { "Math.Add" }, file = "math.cpp", line = 3 } } }))
        f:close()
        h.op(2, "build")
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Str.Len"] } }, no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 1,
            error = { ["$pattern"] = "^no such test" } }, 120000)
        assert.is_nil(next(test_store.of(h.srv.service).live))
        assert.is_nil(next(test_store.of(h.srv.service).held))
    end)

    it("a run waits behind a build directory a task of this daemon holds", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids, unit = h.discover()
        local build_lock = require("loomworks.build_lock")
        local hold = assert(build_lock.acquire(unit:build_dir(), "build"))
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "run" } })
        local waited = vim.wait(30000, function()
            return h.text(h.s.vars.run):find("in use by another task", 1, true) ~= nil
        end, 20)
        vim.wait(300)
        build_lock.release(hold)
        assert.is_true(waited, h.text(h.s.vars.run))
        h.expect({ kind = "task", task_id = { ["$var"] = "run" }, phase = "done", exit_code = 0 }, 60000)
    end)

    it("a second run of the directory waits for the first and then runs", function()
        h = open(root, key, { LW_TEST_RUN_SLEEP = "60000", LW_TEST_RUN_SLEEP_CASE = "Str.Len" })
        h.op(1, "configure")
        local ids = h.discover()
        local store = test_store.of(h.srv.service)
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Str.Len"] } }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "first" } })
        local key_len = store:key_of(ids["Str.Len"])
        assert.is_true(vim.wait(60000, function()
            while h.s:_pull(0) do end
            return store.live[key_len] == "running"
        end, 20), "Str.Len never ran")
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "second" } })
        assert.is_true(vim.wait(30000, function()
            return h.text(h.s.vars.second):find("waiting for another test task", 1, true) ~= nil
        end, 20), h.text(h.s.vars.second))
        h.send(call(4, "/tasks", "loomworks.Tasks", "cancel", { task_id = { ["$var"] = "first" } }, true))
        h.ok(4, { outcome = "ok" })
        h.expect({ kind = "task", task_id = { ["$var"] = "first" }, phase = "done", exit_code = 130 }, 60000)
        h.expect({ kind = "task", task_id = { ["$var"] = "second" }, phase = "done", exit_code = 0,
            result = { counts = { passed = 1 } } }, 60000)
    end)

    it("a throw while the run is accepted ends its task and frees its queue slot and locks", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids, unit = h.discover()
        local store = test_store.of(h.srv.service)
        local build_lock = require("loomworks.build_lock")
        -- Free directories, nothing to discover, no build: everything up to
        -- the step's command runs inside the acceptance's segment.
        unit.test_command_for = function() error("test_command_for exploded") end
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "boom" } })
        local ok, err = pcall(h.expect,
            { kind = "task", task_id = { ["$var"] = "boom" }, phase = "done", exit_code = 1 }, 15000)
        unit.test_command_for = nil
        assert.is_true(ok, "the task never ended: " .. tostring(err))
        assert.is_nil(next(store.held), "the ended task still holds its Tests/1 queue slot")
        assert.is_false(build_lock.held_by_me(unit:build_dir()), "the ended task still holds its build lock")
        -- The directory is usable again: the next run starts and ends.
        h.send(call(3, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(3, { outcome = "accepted", task_id = { ["$bind"] = "next" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "next" }, phase = "done", exit_code = 0 }, 60000)
    end)

    it("a throw after the accepted reply, before the run exists, ends its task and leaves no node queued", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids = h.discover()
        local store = test_store.of(h.srv.service)
        -- The run's first commit (its nodes marked queued) throws: after the
        -- `accepted` reply, before the runner has a run to cancel.
        store.commit = function(self)
            store.commit = nil
            getmetatable(self).__index.commit(self)
            error("commit exploded")
        end
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { select = { { id = ids["Math.Add"] } }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "boom" } })
        local ok, err = pcall(h.expect, { kind = "task", task_id = { ["$var"] = "boom" }, phase = "done",
            exit_code = 1, error = { ["$pattern"] = "commit exploded" } }, 15000)
        store.commit = nil
        assert.is_true(ok, "the task never ended: " .. tostring(err))
        assert.is_nil(next(store.live), "the ended task left its nodes queued")
        for _, c in pairs(store.committed) do assert.are_not.equal("queued", c.status) end
        assert.is_nil(next(store.held))
    end)

    it("run-all runs only the units it covered at acceptance, not one that became runnable since", function()
        h = open(root, key)
        h.op(1, "configure")
        local _, unit = h.discover()
        -- The unit is not runnable when the run decides what it covers (and
        -- runnable for every other caller, so its tree still has nodes).
        local orig = unit.test_availability
        unit.test_availability = function(self)
            local src = debug.getinfo(2, "S").source
            if src:find("test_runs", 1, true) then return "not configured" end
            return orig(self)
        end
        h.send(call(2, TESTS.object, TESTS.iface, "run_cases", { no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "all" } })
        local ok, err = pcall(h.expect, { kind = "task", task_id = { ["$var"] = "all" }, phase = "done" }, 30000)
        unit.test_availability = nil
        assert.is_true(ok, tostring(err))
        local text = h.text(h.s.vars.all)
        assert.is_nil(text:find("Math.Add", 1, true), text)
        assert.is_nil(next(test_store.of(h.srv.service).held))
    end)

    it("a prepared token is dropped with its results file when its connection closes", function()
        h = open(root, key)
        h.op(1, "configure")
        local ids = h.discover()
        h.send(call(2, TESTS.object, TESTS.iface, "prepare_debug", { select = { id = ids["fake"] }, no_build = true }))
        h.ok(2, { outcome = "accepted", task_id = { ["$bind"] = "dbg" } })
        h.expect({ kind = "task", task_id = { ["$var"] = "dbg" }, phase = "done", exit_code = 0 }, 120000)
        local store = test_store.of(h.srv.service)
        local p = select(2, next(store.prepared))
        assert.is_not_nil(p)
        local f = assert(io.open(p.path, "w"))
        f:write("<testsuites/>")
        f:close()
        -- A second connection cannot collect it.
        local conn = select(1, next(h.srv.conns))
        h.srv.service:on_conn_closed({}) -- (another connection: nothing of it)
        assert.is_not_nil(next(store.prepared))
        h.srv.service:on_conn_closed(conn)
        assert.is_nil(next(store.prepared))
        assert.is_nil(uv.fs_stat(p.path))
    end)
end)

describe("Tests/1 run internals", function()
    local test_runs = require("loomworks.daemon.test_runs")

    it("reads gtest progress lines", function()
        assert.same({ "running", "A.B" }, { test_runs._progress_line("[ RUN      ] A.B") })
        assert.same({ "passed", "A.B", 3 }, { test_runs._progress_line("[       OK ] A.B (3 ms)") })
        assert.same({ "failed", "P/A.B/0", 12 }, { test_runs._progress_line("[  FAILED  ] P/A.B/0 (12 ms)") })
        assert.same({ "skipped", "A.B", 0 }, { test_runs._progress_line("[  SKIPPED ] A.B (0 ms)") })
        -- The failure summary at the end is not a case's end.
        assert.is_nil((test_runs._progress_line("[  FAILED  ] A.B")))
        assert.is_nil((test_runs._progress_line("[==========] 3 tests ran.")))
    end)

    it("keeps an output's end, never splitting a character", function()
        local t, cut = test_runs._tail(string.rep("a", 10) .. "é", 3)
        assert.is_true(cut)
        assert.equals("aé", t)
        assert.equals("abc", (test_runs._tail("abc", 3)))
    end)

    it("removes only a per-run results file directly in <root>/.nvim/tmp (deletion safety)", function()
        local root = H.tmp() .. "/ws"
        local tmp = root .. "/.nvim/tmp"
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(root .. "/.nvim/tmpx", "p")
        vim.fn.mkdir(tmp .. "/sub", "p")
        local function touch(p)
            local f = assert(io.open(p, "w"))
            f:write("x")
            f:close()
            return p
        end
        local refused = {
            touch(root .. "/lw-test-ab12.xml"),            -- outside .nvim/tmp
            touch(root .. "/.nvim/tmpx/lw-test-ab12.xml"), -- a prefix collision
            touch(tmp .. "/sub/lw-test-ab12.xml"),         -- not a direct child
            touch(tmp .. "/lw-test-xyz.xml"),              -- not hex
            touch(tmp .. "/lw-test-ab12.json"),            -- another name
            touch(tmp .. "/other.xml"),
        }
        for _, p in ipairs(refused) do
            assert.is_false(test_store.unlink(root, p), p)
            assert.is_not_nil(uv.fs_stat(p), "removed " .. p)
        end
        assert.is_false(test_store.unlink(root, tmp .. "/sub/../lw-test-ab12.xml"))
        assert.is_false(test_store.unlink(nil, tmp .. "/lw-test-ab12.xml"))
        assert.is_false(test_store.unlink(root, nil))
        local ok = touch(tmp .. "/lw-test-0123abcdef.xml")
        assert.is_true(test_store.unlink(root, ok))
        assert.is_nil(uv.fs_stat(ok))
        -- (Backslashes and the root's spelling with a trailing slash.)
        ok = touch(tmp .. "/lw-test-ff.xml")
        assert.is_true(test_store.unlink(root .. "/", (ok:gsub("/", "\\"))))
        assert.is_nil(uv.fs_stat(ok))
        -- A directory of that name is never removed.
        vim.fn.mkdir(tmp .. "/lw-test-aa.xml", "p")
        assert.is_false(test_store.unlink(root, tmp .. "/lw-test-aa.xml"))
        assert.is_not_nil(uv.fs_stat(tmp .. "/lw-test-aa.xml"))
        -- A `.nvim/tmp` (or `.nvim`) that is a link or junction is refused:
        -- the file lies wherever it points.
        local root2 = H.tmp() .. "/ws2"
        local away = H.tmp() .. "/away"
        vim.fn.mkdir(root2 .. "/.nvim", "p")
        vim.fn.mkdir(away, "p")
        local linked = uv.fs_symlink(away, root2 .. "/.nvim/tmp", { junction = true })
        if linked then
            local f = touch(away .. "/lw-test-abc.xml")
            assert.is_false(test_store.unlink(root2, root2 .. "/.nvim/tmp/lw-test-abc.xml"))
            assert.is_not_nil(uv.fs_stat(f))
            local root3 = H.tmp() .. "/ws3"
            vim.fn.mkdir(root3, "p")
            vim.fn.mkdir(away .. "/tmp", "p")
            if uv.fs_symlink(away, root3 .. "/.nvim", { junction = true }) then
                local g = touch(away .. "/tmp/lw-test-abc.xml")
                assert.is_false(test_store.unlink(root3, root3 .. "/.nvim/tmp/lw-test-abc.xml"))
                assert.is_not_nil(uv.fs_stat(g))
            end
        else
            print("skipped: links/junctions cannot be created here")
        end
    end)

    it("queues Tests/1 tasks of one build directory FIFO and frees a released waiter", function()
        local store = test_store.of({ ids = require("loomworks.daemon.snapshot").registry(1) })
        local order = {}
        local a = store:acquire_dirs({ "/b/x" }, function() order[#order + 1] = "a" end)
        local b = store:acquire_dirs({ "/b/x", "/b/y" }, function() order[#order + 1] = "b" end)
        local c = store:acquire_dirs({ "/b/y" }, function() order[#order + 1] = "c" end)
        local d = store:acquire_dirs({ "/b/z" }, function() order[#order + 1] = "d" end)
        -- c waits behind b (FIFO on /b/y), d takes its own directory.
        assert.same({ "a", "d" }, order)
        store:release(a)
        assert.same({ "a", "d", "b" }, order)
        store:release(c) -- (a waiter released: dropped from the queue)
        store:release(b)
        assert.same({ "a", "d", "b" }, order)
        store:release(d)
        assert.is_nil(next(store.held))
    end)
end)
