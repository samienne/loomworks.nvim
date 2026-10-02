-- `lw daemon list` and `lw daemon stop --all` / `kill --all [--strays]`
-- (spec §19.6.1): every daemon of this user found by a process scan, no
-- registry. Real daemon processes in temp workspaces, asserted by pid and
-- start time; every command that acts on "all" daemons is narrowed with
-- `--under <this file's temp parent>` so another session's daemons on the
-- machine are never touched. None is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local discover = require("loomworks.daemon.discover")
local command = require("loomworks.daemon.command")
local handle = require("loomworks.daemon.handle")
local rlock = require("loomworks.daemon.rlock")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

--- A parent directory holding this test's workspaces.
local function parent()
    return H.tmp()
end

--- A workspace `<dir>/<name>`.
local function ws(dir, name)
    local root = dir .. "/" .. name
    vim.fn.mkdir(root .. "/.nvim", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write('{"projects":{}}')
    f:close()
    return root
end

--- Start a daemon for `root` (`lw daemon restart`) and track it.
local function start(root, env)
    local r = H.lw({ "daemon", "restart" }, { env = env, cwd = root })
    assert.equals(0, r.code, r.stderr)
    local info = H.track_root(root)
    assert.is_truthy(info and info.pid, "no runtime lock after restart")
    return info
end

local function list_json(dir, env, cwd)
    local r = H.lw({ "daemon", "list", "--json", "--under", dir }, { env = env, cwd = cwd or H.tmp() })
    assert.equals(0, r.code, r.stderr)
    return vim.json.decode(r.stdout), r
end

local function by_pid(doc, pid)
    for _, d in ipairs(doc.daemons) do if d.pid == pid then return d end end
    return nil
end

local function key(p) return require("loomworks.daemon.paths")._hash_key(p) end

describe("discover helpers (§19.6.1)", function()
    it("keeps lw-host executable names only", function()
        for _, n in ipairs({ "lw", "lw.exe", "LW.EXE", "lw-0.1.42-windows-x86_64.exe", "lw-linux-x86_64",
            "/usr/local/bin/lw", "C:\\bin\\luvi.exe", "nvim", "nvim.exe" }) do
            assert.is_true(discover.candidate(n), n)
        end
        for _, n in ipairs({ "lwx", "flw", "bash", "node.exe", "", "svchost.exe" }) do
            assert.is_false(discover.candidate(n), n)
        end
    end)
    it("reads --root in both forms", function()
        assert.equals("C:/w/a", discover.root_of({ "lw", "daemon", "run", "--root", "C:\\w\\a\\" }))
        assert.equals("/w/b", discover.root_of({ "lw", "daemon", "run", "--root=/w/b" }))
        assert.is_nil(discover.root_of({ "lw", "daemon", "run" }))
    end)
    it("--under is separator-bounded", function()
        local d = H.tmp()
        vim.fn.mkdir(d .. "/ab/x", "p")
        vim.fn.mkdir(d .. "/abc", "p")
        assert.is_true(discover.under(d .. "/ab/x", d .. "/ab"))
        assert.is_true(discover.under(d .. "/ab", d .. "/ab"))
        assert.is_false(discover.under(d .. "/abc", d .. "/ab"))
    end)
    it("lists processes with names, this nvim among them", function()
        local me = uv.os_getpid()
        local found
        for _, p in ipairs(proc.processes()) do
            if p.pid == me then found = p end
        end
        assert.is_truthy(found, "own process not listed")
        assert.is_true(discover.candidate(found.name), tostring(found.name))
    end)
    it("turns a start time into the wall clock", function()
        local t = proc.start_epoch(proc.self_start_time())
        assert.is_truthy(t, "no start epoch for " .. tostring(proc.self_start_time()))
        assert.is_true(t <= os.time() + 2 and t > os.time() - 3600 * 24, tostring(t))
    end)
    it("--strays needs kill --all; --under needs --all", function()
        local r = H.lw({ "daemon", "stop", "--all", "--strays" }, { env = H.env(), cwd = H.tmp() })
        assert.is_true(r.code ~= 0)
        r = H.lw({ "daemon", "kill", "--strays" }, { env = H.env(), cwd = H.tmp() })
        assert.equals(2, r.code)
        assert.truthy(r.stderr:find("--all", 1, true), r.stderr)
    end)
    it("an empty list: text and json", function()
        local env, dir = H.env(), parent()
        local r = H.lw({ "daemon", "list", "--under", dir }, { env = env, cwd = H.tmp() })
        assert.equals(0, r.code)
        assert.truthy(r.stdout:find("no workspace daemons are running", 1, true), r.stdout)
        local doc = list_json(dir, env)
        assert.equals(1, doc.schema)
        assert.same({}, doc.daemons)
        assert.equals("number", type(doc.scan_ms))
    end)
    it("the health provider counts daemons", function()
        local sug = require("loomworks.suggestions")
        local seam = vim.env.LOOMWORKS_TEST_NO_DAEMON_SCAN
        assert.same({}, sug.daemon_count_provider()) -- the suite's seam: off
        vim.env.LOOMWORKS_TEST_NO_DAEMON_SCAN = nil
        local orig = discover.list
        discover.list = function()
            return { { state = "live", clients = 0, busy = false }, { state = "live", clients = 1 } }, 1
        end
        local ok, items = pcall(sug.daemon_count_provider)
        discover.list = orig
        assert.is_true(ok, tostring(items))
        assert.equals(1, #items)
        assert.equals("info", items[1].kind)
        assert.equals("2 workspace daemons running (1 idle) — lw daemon list", items[1].title)
        discover.list = function() return {}, 1 end
        items = sug.daemon_count_provider()
        discover.list = orig
        vim.env.LOOMWORKS_TEST_NO_DAEMON_SCAN = seam
        assert.same({}, items)
    end)
end)

describe("lw daemon list with real daemons (§19.6.1)", function()
    after_each(function() H.cleanup() end)

    it("lists two daemons with their roots; json shape; a stopped one disappears", function()
        local env, dir = H.env(), parent()
        local a, b = ws(dir, "alpha"), ws(dir, "beta")
        local ia, ib = start(a, env), start(b, env)
        local r = H.lw({ "daemon", "list", "--under", dir }, { env = env, cwd = H.tmp() })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("PID%s+UPTIME%s+STATE%s+CLIENTS%s+VERSION%s+ROOT"), r.stdout)
        assert.truthy(r.stdout:find(a, 1, true), r.stdout)
        assert.truthy(r.stdout:find(b, 1, true), r.stdout)
        assert.truthy(r.stdout:find("2 daemons (2 idle)", 1, true), r.stdout)
        local doc = list_json(dir, env)
        assert.equals(2, #doc.daemons)
        local da, db = by_pid(doc, ia.pid), by_pid(doc, ib.pid)
        assert.is_truthy(da and db, vim.inspect(doc))
        assert.equals(key(a), key(da.root))
        assert.equals(key(b), key(db.root))
        for _, d in ipairs({ da, db }) do
            assert.equals("live", d.state)
            assert.equals(0, d.clients)
            assert.equals(false, d.busy)
            assert.equals("number", type(d.uptime_s))
            assert.equals("string", type(d.lw_version))
            assert.equals("string", type(d.start_time))
            assert.equals(3, d.protocol)
        end
        assert.equals(da.start_time, ia.start_time)
        assert.is_true(doc.scan_ms < 5000, "scan took " .. doc.scan_ms .. " ms")
        -- Stop alpha: it is gone from the list.
        assert.equals(0, H.stop_daemon(a, env).code)
        doc = list_json(dir, env)
        assert.is_nil(by_pid(doc, ia.pid))
        assert.is_truthy(by_pid(doc, ib.pid))
        assert.equals(0, H.stop_daemon(b, env).code)
        assert.equals(0, #list_json(dir, env).daemons)
    end)

    it("a killed daemon is absent; its leftover files list nothing", function()
        local env, dir = H.env(), parent()
        local a = ws(dir, "alpha")
        local ia = start(a, env)
        assert.is_true(proc.kill_tree(ia.pid, ia.start_time))
        assert.is_truthy(rlock.read(a), "the killed daemon's lock should remain")
        assert.equals(0, #list_json(dir, env).daemons)
    end)

    it("a handle and lock naming a live non-daemon process (reused pid) list nothing", function()
        local env, dir = H.env(), parent()
        local a = ws(dir, "alpha")
        -- A live process that is not a daemon: a sleeping nvim.
        local child = uv.spawn(vim.v.progpath, { args = { "--headless", "-u", "NONE", "--cmd", "sleep 20" } },
            function() end)
        assert.is_truthy(child)
        local pid = child:get_pid()
        local st = proc.start_time(pid)
        H.track(pid, st)
        handle.write(a, { pid = pid, host = require("loomworks.lock_record").this_host(), start_time = st,
            endpoint = "x", protocol = 3 })
        local f = assert(io.open(rlock.path(a), "w"))
        f:write(vim.json.encode({ pid = pid, host = require("loomworks.lock_record").this_host(),
            start_time = st, kind = "daemon", mode = "daemon", lock_nonce = "n" }))
        f:close()
        local doc = list_json(dir, env)
        assert.is_nil(by_pid(doc, pid), vim.inspect(doc))
        assert.equals(0, #doc.daemons)
        H.cleanup()
        pcall(function() child:close() end)
    end)

    it("a daemon whose handle names another process is a stray; stop --all skips it, kill --all --strays kills it",
        function()
            local env, dir = H.env(), parent()
            local a, b = ws(dir, "alpha"), ws(dir, "beta")
            local ia, ib = start(a, env), start(b, env)
            local h = handle.read(b)
            h.pid = 1234
            assert.is_true(handle.write(b, h))
            local doc = list_json(dir, env)
            local db = by_pid(doc, ib.pid)
            assert.equals("stray", db.state)
            assert.equals("the handle names pid 1234", db.reason)
            assert.equals("live", by_pid(doc, ia.pid).state)
            local r = H.lw({ "daemon", "list", "--under", dir }, { env = env, cwd = H.tmp() })
            assert.truthy(r.stdout:find("stray", 1, true), r.stdout)
            assert.truthy(r.stdout:find("(1 idle, 1 stray)", 1, true), r.stdout)
            -- stop --all: alpha stopped, the stray skipped (exit 1).
            r = H.lw({ "daemon", "stop", "--all", "--under", dir }, { env = env, cwd = H.tmp() })
            assert.equals(1, r.code, r.stdout .. r.stderr)
            assert.truthy(r.stdout:find(a .. ": stopped the workspace daemon (pid " .. ia.pid .. ")", 1, true),
                r.stdout)
            assert.truthy(r.stderr:find("skipped stray daemon pid " .. ib.pid, 1, true), r.stderr)
            assert.is_true(vim.wait(10000, function() return not H.alive(ia.pid, ia.start_time) end, 50))
            assert.is_true(H.alive(ib.pid, ib.start_time))
            -- kill --all --strays: killed, its runtime lock reclaimed.
            r = H.lw({ "daemon", "kill", "--all", "--strays", "--under", dir }, { env = env, cwd = H.tmp() })
            assert.equals(0, r.code, r.stdout .. r.stderr)
            assert.truthy(r.stdout:find(b .. ": killed the stray daemon (pid " .. ib.pid .. ")", 1, true), r.stdout)
            assert.is_true(vim.wait(10000, function() return not H.alive(ib.pid, ib.start_time) end, 50))
            assert.is_nil(rlock.read(b))
            assert.equals(0, #list_json(dir, env).daemons)
        end)

    it("stop --all stops both; kill --all kills", function()
        local env, dir = H.env(), parent()
        local a, b = ws(dir, "alpha"), ws(dir, "beta")
        local ia, ib = start(a, env), start(b, env)
        local r = H.lw({ "daemon", "stop", "--all", "--under", dir }, { env = env, cwd = H.tmp() })
        assert.equals(0, r.code, r.stdout .. r.stderr)
        assert.truthy(r.stdout:find(a .. ": stopped the workspace daemon", 1, true), r.stdout)
        assert.truthy(r.stdout:find(b .. ": stopped the workspace daemon", 1, true), r.stdout)
        assert.is_false(H.alive(ia.pid, ia.start_time))
        assert.is_false(H.alive(ib.pid, ib.start_time))
        local ic = start(a, env)
        r = H.lw({ "daemon", "kill", "--all", "--under", dir }, { env = env, cwd = H.tmp() })
        assert.equals(0, r.code, r.stdout .. r.stderr)
        assert.truthy(r.stdout:find(a .. ": killed the workspace daemon (pid " .. ic.pid .. ")", 1, true), r.stdout)
        assert.is_false(H.alive(ic.pid, ic.start_time))
        assert.is_nil(rlock.read(a))
    end)

    it("a daemon run without --root is listed with root unknown, never under --under", function()
        local env, dir = H.env(), parent()
        local a = ws(dir, "alpha")
        local d = H.lw_start({ "daemon", "run" }, { env = env, cwd = a })
        H.track(d.pid, d.start)
        assert.is_true(vim.wait(60000, function() return handle.read(a) ~= nil end, 50), d.stderr())
        -- In-process: the whole machine's list, found by pid (the other
        -- session's daemons are not touched — nothing here acts on them).
        local list = discover.list()
        local e
        for _, x in ipairs(list) do if x.pid == d.pid then e = x end end
        assert.is_truthy(e, "the daemon was not found")
        assert.equals("unknown_root", e.state)
        assert.is_nil(e.root)
        assert.equals(0, #list_json(dir, env).daemons)
        local out = {}
        command.list({ "lw", "daemon", "list" }, { out = function(l) out[#out + 1] = l end })
        assert.truthy(table.concat(out, "\n"):find(d.pid .. ".-%(root unknown%)"), table.concat(out, "\n"))
        -- kill_stray checks it is still that daemon, then kills it.
        assert.is_true(command.kill_stray(e))
        assert.is_true(d.wait(10000))
        assert.is_false(H.alive(d.pid, d.start))
    end)
end)

describe("daemon processes", function()
    it("none was left running by any test of this file", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a daemon process survived the cleanup")
    end)
end)
