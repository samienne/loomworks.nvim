-- The workspace daemon's test discovery and tests view (spec §19.13 "The
-- tests view", §19.15 "Tests", §19.20 `Tests/1.discover`; step 5m part B1),
-- over the loopback transport on the conformance runner's `tests` fixture
-- (the harness-only teststub module): what a transcript cannot show — a
-- build directory held by another process, waiting behind a task of the
-- daemon, the stale marking by a run's end and by another process's change,
-- the last results and node lookup.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local uv = vim.uv or vim.loop
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")
local trust = require("loomworks.trust")
local build_lock = require("loomworks.build_lock")
local test_discover = require("loomworks.daemon.test_discover")
local tests_view = require("loomworks.daemon.tests_view")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

--- A loopback daemon on a fresh `tests` fixture, handshaken.
local function session()
    local key = (vim.fn.tempname():gsub("\\", "/")) .. "/trust.key"
    vim.fn.mkdir(vim.fn.fnamemodify(key, ":h"), "p")
    trust._set_key_path(key)
    local root = runner.fixture("tests", key)
    trust._set_key_path(key)
    runner.register_teststub()
    local d = runner.loopback_driver(root)
    local s = { d = d, root = root, env = runner.wire_env(uv.os_environ()), inbox = {}, req = 0 }
    function s.send(f) assert(d.send(f)) end
    --- Next frame satisfying `pred` (others kept for later).
    function s.wait(pred, ms)
        local deadline = uv.now() + (ms or 30000)
        while true do
            for i, f in ipairs(s.inbox) do
                if pred(f) then table.remove(s.inbox, i); return f end
            end
            local left = deadline - uv.now()
            assert(left > 0, "timed out waiting for a frame")
            local f = d.recv(math.min(left, 50))
            if f then s.inbox[#s.inbox + 1] = f end
        end
    end
    function s.call(object, iface, method, args, env)
        s.req = s.req + 1
        local id = s.req
        s.send({ kind = "call", req_id = id, object = object, iface = iface, v = 1, method = method,
            args = args or vim.empty_dict(), env = env })
        local f = s.wait(function(m) return m.req_id == id end)
        assert.equals("ok", f.kind, vim.inspect(f))
        return f.result
    end
    --- Start a discovery; returns its task id.
    function s.discover(args)
        local r = s.call("/tests", "loomworks.Tests", "discover", args, s.env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        return r.task_id
    end
    --- The lines and the done frame of a task.
    function s.done(task_id, ms)
        local lines = {}
        while true do
            local f = s.wait(function(m)
                return m.kind == "task" and m.task_id == task_id and (m.phase == "line" or m.phase == "done")
            end, ms)
            if f.phase == "done" then return f, lines end
            lines[#lines + 1] = f.stream .. ": " .. f.text
        end
    end
    function s.build()
        local r = s.call("/build", "loomworks.Build", "build", { profile = { key = "dev" } }, s.env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 120000)
        assert.equals(0, f.exit_code)
    end
    function s.view() return s.call("/views", "loomworks.view.Tests", "get") end
    function s.service() return d.server.service end
    function s.unit()
        local ws = s.service().ws
        return ws._active_profile:projects()[1]._config_unit
    end
    s.send({ kind = "hello", protocol = 11, client = "editor", lw_version = require("loomworks.daemon.version").identity() })
    s.wait(function(m) return m.kind == "welcome" end)
    function s.close()
        pcall(d.close)
        trust._set_key_path(nil)
    end
    return s
end

describe("Tests/1.discover in the workspace daemon (§19.15 Tests)", function()
    local s
    after_each(function()
        L.cleanup()
        if s then s.close(); s = nil end
    end)

    it("counts the entries no other entry is the parent of", function()
        assert.equals(0, test_discover.count_tests(nil))
        assert.equals(3, test_discover.count_tests({
            { id = "t1" }, { id = "a", parent = "t1" }, { id = "b", parent = "t1" }, { id = "t2" },
        }))
    end)

    it("a unit whose build directory another process holds is that unit's error; the task still ends 0", function()
        s = session()
        s.build()
        local bd = s.unit():build_dir()
        L.hold(build_lock.lock_path(bd), "build")
        local f, lines = s.done(s.discover())
        assert.equals(0, f.exit_code)
        assert.same({ exit_code = 0, tests = 0, failed = 1 }, f.result)
        assert.equals("out: ==> [discover] app/Debug", lines[1])
        assert.truthy(lines[2]:find("^err: app/Debug: "), vim.inspect(lines))
        assert.truthy(lines[3]:find("DISCOVER OK: dev (0 tests, 1 failed)", 1, true), lines[3])
        local v = s.view()
        assert.equals("error", v.units[1].state)
        assert.is_string(v.units[1].message)
        -- An errored unit is not stale for its failure; the next discovery
        -- probes it again (no force needed).
        assert.is_false(v.stale)
        L.cleanup()
        f = s.done(s.discover())
        assert.same({ exit_code = 0, tests = 3, failed = 0 }, f.result)
        assert.equals("ok", s.view().units[1].state)
    end)

    it("behind a task of this daemon holding the directory, the discovery waits for it; a cancel ends the wait", function()
        s = session()
        s.build()
        local bd = s.unit():build_dir()
        local h = assert(build_lock.acquire(bd, "build"))
        local task = s.discover()
        local note = s.wait(function(m) return m.kind == "task" and m.task_id == task and m.phase == "line" end)
        assert.equals("note", note.stream)
        assert.truthy(note.text:find("^waiting for "), note.text)
        vim.wait(300)
        build_lock.release(h)
        local f, lines = s.done(task)
        assert.same({ exit_code = 0, tests = 3, failed = 0 }, f.result)
        assert.equals("out: ==> [discover] app/Debug", lines[1])

        h = assert(build_lock.acquire(bd, "build"))
        task = s.discover({ force = true })
        s.wait(function(m) return m.kind == "task" and m.task_id == task and m.phase == "line" end)
        assert.equals("ok", s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = task }).outcome)
        f = s.done(task)
        assert.equals(130, f.exit_code)
        assert.equals("discover stopped: cancelled by the client that started it", f.error)
        build_lock.release(h)
        -- The cancelled discovery leaves the view stale, the tree kept.
        local v = s.view()
        assert.is_true(v.stale)
        assert.equals("ok", v.units[1].state)
        assert.equals(7, #v.units[1].nodes)
    end)

    it("marks the view stale when a run covering its unit ends or another process changed the unit", function()
        s = session()
        s.build()
        s.done(s.discover())
        assert.is_false(s.view().stale)
        -- A run that ended (even one that changed nothing in the cache).
        local svc = s.service()
        tests_view.on_run_done(svc, { op = "clean", ctx = { units = { s.unit() } } })
        assert.is_true(s.view().stale)
        s.done(s.discover())
        assert.is_false(s.view().stale)
        -- A launch preparation without a build marks nothing.
        tests_view.on_run_done(svc, { op = "run", ctx = { units = { s.unit() }, args = { no_build = true } } })
        assert.is_false(s.view().stale)
        -- Another process's build, read through the cache.
        s.unit().last_built = tostring(s.unit().last_built) .. "+1"
        assert.is_true(s.view().stale)
        s.done(s.discover())
        assert.is_false(s.view().stale)
    end)

    it("serves a node's last result in the view and resolves view ids to nodes", function()
        s = session()
        s.build()
        s.done(s.discover())
        local svc = s.service()
        local nodes = s.view().units[1].nodes
        local add, math_suite = nodes[3], nodes[2]
        assert.equals("Add", add.name)
        local hit = assert(tests_view.find_node(svc, add.id))
        assert.equals(s.unit(), hit.unit)
        assert.equals("Math.Add", hit.entry.name)
        local suite = assert(tests_view.find_node(svc, math_suite.id))
        assert.is_nil(suite.entry)
        assert.equals("suite", suite.node.kind)
        assert.is_nil(tests_view.find_node(svc, "nope"))
        tests_view.set_result(svc, hit.unit, hit.key, { status = "failed", duration = 12.4, message = "boom" })
        local n = s.view().units[1].nodes[3]
        assert.same({ "failed", 12, "boom" }, { n.status, n.duration, n.message })
        -- A re-discovery keeps the node's id and its last result.
        s.done(s.discover({ force = true }))
        n = s.view().units[1].nodes[3]
        assert.equals(add.id, n.id)
        assert.equals("failed", n.status)
    end)
end)
