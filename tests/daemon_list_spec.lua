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
    it("a pin redirect's wrapper is not a daemon: only the pinned lw under it is listed (spec 16.23)", function()
        -- 10 = global lw wrapping 11 (pinned lw), same --root; 20 = an unrelated
        -- daemon whose parent 10 is not (another root); 30's parent id 31 is a
        -- younger process (a reused id on Windows): not its parent.
        local function d(pid, root, t)
            return { pid = pid, root = root, start_time = string.format("win:%d", (11644473600 + t) * 10000000),
                args = { "lw", "daemon", "run", "--root", root } }
        end
        local found = { d(10, "C:/w/a", 100), d(11, "C:/w/a", 101), d(20, "C:/w/b", 102),
            d(31, "C:/w/c", 200), d(30, "C:/w/c", 150) }
        local out = discover.drop_redirect_wrappers(found, { [11] = 10, [20] = 10, [30] = 31 })
        local pids = {}
        for _, e in ipairs(out) do pids[#pids + 1] = e.pid end
        assert.same({ 11, 20, 31, 30 }, pids)
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

describe("relays in the scan (§19.6.1 step 3, step 5i)", function()
    local function st(t) return string.format("win:%d", (11644473600 + t) * 10000000) end
    -- One full command line per lw host, each with `extra` after `--root /w`.
    local function lines(extra)
        local function with(pre)
            local a = vim.list_extend(vim.deepcopy(pre), { "daemon", "run", "--root", "/w" })
            return vim.list_extend(a, extra)
        end
        return {
            with({ "lw" }),
            with({ "C:/bin/lw.exe", "--no-input" }),
            with({ "luvi", "C:/src/loomworks.nvim/lua", "--" }),
            with({ "nvim", "--headless", "-u", "NONE", "-l", "C:/src/loomworks.nvim/lua/loomworks/cli.lua" }),
        }
    end
    local function d(args, pid, t) return { pid = pid or 10, start_time = st(t or 100), args = args, root = "/w" } end

    it("finds the `daemon run` arguments behind any host and its global flags", function()
        assert.same({ "daemon", "run", "--stdio" },
            discover.run_args({ "lw", "--no-input", "daemon", "run", "--stdio" }))
        assert.same({ "daemon", "run" }, discover.run_args({ "luvi", "app", "--", "daemon", "run" }))
        assert.is_nil(discover.run_args({ "lw", "daemon", "status" }))
        assert.is_nil(discover.run_args({ "lw", "run" }))
    end)

    it("the scan's standard-I/O test is the dispatch's (command.relay_form), `--` included", function()
        local cases = {
            { { "--stdio" }, true }, { { "--no-launch", "--stdio" }, true }, { { "--stdio", "--private" }, true },
            { { "--skip-instance=1:win:1" }, true }, { {}, false }, { { "--", "--stdio" }, false },
            { { "--", "--private", "--no-launch", "--skip-instance", "1:win:1" }, false },
            { { "--force" }, false },
        }
        for _, c in ipairs(cases) do
            for _, line in ipairs(lines(c[1])) do
                local ra = assert(discover.run_args(line))
                assert.equals(c[2], discover.stdio_form(ra), table.concat(line, " "))
                assert.equals(command.relay_form(ra), discover.stdio_form(ra), table.concat(line, " "))
            end
        end
    end)

    it("a standard-I/O process is a relay unless R names it by pid and start time", function()
        for _, line in ipairs(lines({ "--stdio" })) do
            local r = d(line)
            assert.is_true(discover.is_relay(r, nil), "no lock")
            assert.is_true(discover.is_relay(r, { pid = 11, start_time = r.start_time }), "another pid")
            assert.is_true(discover.is_relay(r, { pid = 10, start_time = st(99) }), "a reused pid")
            assert.is_true(discover.is_relay(r, { pid = 10 }), "no start time: not provably it")
            -- R names it: the attached --stdio runtime of a release before 5i.
            assert.is_false(discover.is_relay(r, { pid = 10, start_time = r.start_time }))
            -- No root: R cannot name it.
            local nr = vim.deepcopy(r)
            nr.root = nil
            assert.is_true(discover.is_relay(nr, { pid = 10, start_time = r.start_time }))
        end
        -- The gated private runtime takes no R: a connection-like process, never acted on.
        assert.is_true(discover.is_relay(d(lines({ "--stdio", "--private" })[1]), nil))
        -- Not a standard-I/O form: never a relay, whatever R says.
        for _, extra in ipairs({ {}, { "--", "--stdio" }, { "--", "--no-launch" } }) do
            for _, line in ipairs(lines(extra)) do
                assert.is_false(discover.is_relay(d(line), nil), table.concat(line, " "))
                assert.is_false(discover.is_relay(d(line), { pid = 99, start_time = st(1) }), table.concat(line, " "))
            end
        end
    end)

    it("a relay that launched its daemon is not that daemon's redirect wrapper; a relay's wrapper is", function()
        local relay = { "lw", "daemon", "run", "--root", "/w", "--stdio" }
        local daemon = { "lw", "daemon", "run", "--root", "/w" }
        -- 10: a relay that launched daemon 11. 20 wraps relay 21 (pin redirect).
        local found = { d(relay, 10, 100), d(daemon, 11, 101), d(relay, 20, 102), d(relay, 21, 103) }
        local out = discover.drop_redirect_wrappers(found, { [11] = 10, [21] = 20 })
        local pids = {}
        for _, e in ipairs(out) do pids[#pids + 1] = e.pid end
        assert.same({ 10, 11, 21 }, pids)
    end)

    it("relays go on the entry of their root's runtime; none for an unlisted root", function()
        local a, b = H.tmp(), H.tmp()
        local stray = { pid = 1, root = a, state = "stray" }
        local live = { pid = 2, root = a, state = "live" }
        local other = { pid = 3, root = b, state = "stray" }
        local unknown = { pid = 4, state = "unknown_root" }
        discover.attach_relays({ stray, live, other, unknown }, {
            { pid = 9, start_time = "s9", root = a }, { pid = 8, start_time = "s8", root = a .. "/" },
            { pid = 7, start_time = "s7", root = b }, { pid = 6, start_time = "s6", root = H.tmp() },
            { pid = 5, start_time = "s5" },
        })
        assert.same({}, stray.relays)
        assert.same({ { pid = 8, start_time = "s8" }, { pid = 9, start_time = "s9" } }, live.relays)
        assert.same({ { pid = 7, start_time = "s7" } }, other.relays)
        assert.same({}, unknown.relays)
    end)

    it("--json has relays on each daemon entry, always an array; the rows and counts are daemons only", function()
        local orig = discover.list
        discover.list = function()
            return {
                { pid = 2, start_time = "s2", root = "/w/a", state = "live", clients = 1, busy = false,
                    relays = { { pid = 9, start_time = "s9" } } },
                { pid = 3, start_time = "s3", root = "/w/b", state = "live", clients = 0, busy = false, relays = {} },
            }, 1
        end
        local out = {}
        local host = { out = function(l) out[#out + 1] = l end, note = function() end, die = error }
        local ok, err = pcall(command.list, { "daemon", "list", "--json" }, host)
        local ok2, err2 = pcall(command.list, { "daemon", "list" }, host)
        discover.list = orig
        assert.is_true(ok, tostring(err))
        assert.is_true(ok2, tostring(err2))
        local doc = vim.json.decode(out[1])
        assert.same({ { pid = 9, start_time = "s9" } }, doc.daemons[1].relays)
        assert.equals(0, #doc.daemons[2].relays)
        assert.truthy(out[1]:find('"relays":[]', 1, true), out[1])
        assert.equals(5, #out) -- the json; then the header, two rows, the summary
        assert.truthy(out[5]:find("^2 daemons"), out[5])
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
            assert.equals(require("loomworks.daemon.version").PROTOCOL, d.protocol)
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

describe("lw daemon list display (field findings, §19.6.1)", function()
    after_each(function() H.cleanup() end)

    --- Every state the scan can produce, with what each would carry.
    local function sample()
        local now = os.time()
        return {
            { pid = 4242, start_time = "win:1", root = "C:/w/app", state = "live", uptime_s = 7200, clients = 0,
                busy = false, idle_since = now - 720, lw_version = "0.1.43", protocol = 3, endpoint = "e1",
                same_key = true },
            { pid = 4310, start_time = "win:2", root = "C:/w/lib", state = "live", uptime_s = 300, clients = 1,
                busy = false, lw_version = "0.1.42+dev.34399bdb9585dd99", protocol = 3, endpoint = "e2" },
            { pid = 4311, start_time = "win:3", root = "C:/w/busy", state = "live", uptime_s = 30, clients = 1,
                busy = true, lw_version = "0.1.43", protocol = 3, endpoint = "e3" },
            { pid = 4388, start_time = "win:4", root = "C:/w/old", state = "stray", reason = "no runtime lock",
                uptime_s = 60 },
            { pid = 4389, start_time = "win:5", root = "C:/w/new", state = "starting", reason = "no runtime lock yet",
                uptime_s = 1 },
            { pid = 4390, start_time = "win:6", root = "C:/w/hung", state = "hung", uptime_s = 600, clients = 0,
                busy = false, lw_version = "0.1.43" },
            { pid = 4391, start_time = "win:7", state = "unknown_root", reason = "no --root on its command line" },
            { pid = 4392, start_time = "win:8", root = "C:/t/test-ws", state = "live", uptime_s = 5, clients = 0,
                busy = false, idle_since = now - 3, lw_version = "0.1.43", same_key = false },
        }
    end

    local function run_list(list, args)
        local orig = discover.list
        discover.list = function() return list, 12 end
        local out = {}
        local ok, err = pcall(command.list, args, { out = function(l) out[#out + 1] = l end,
            die = function(m) error(m) end })
        discover.list = orig
        assert.is_true(ok, tostring(err))
        return out
    end

    it("the table has exactly the --json entries, every column filled, counts matching the rows", function()
        local list = sample()
        local doc = vim.json.decode(run_list(list, { "lw", "daemon", "list", "--json" })[1])
        local lines = run_list(list, { "lw", "daemon", "list" })
        assert.equals(#doc.daemons + 2, #lines, table.concat(lines, "\n")) -- header + rows + summary
        local rows = command.rows(list)
        assert.equals(#doc.daemons + 1, #rows)
        for i, d in ipairs(doc.daemons) do
            local line = lines[i + 1]
            assert.truthy(line:find("^" .. d.pid .. "%s"), line)
            for c = 1, 6 do
                assert.is_true(type(rows[i + 1][c]) == "string" and rows[i + 1][c] ~= "", "empty column " .. c
                    .. " in: " .. line)
                assert.is_nil(rows[i + 1][c]:find("?", 1, true), line)
            end
        end
        -- Summary: counted from those rows.
        assert.truthy(lines[#lines]:find("^8 daemons %(2 idle, 2 stray, 1 other data dir%)"), lines[#lines])
        -- Unknown values are `-`: the unknown root's uptime, clients and version.
        local unknown = lines[8]
        assert.truthy(unknown:find("^4391%s+%-%s+unknown root%s+%-%s+%-%s+%(root unknown%)"), unknown)
    end)

    it("STATE uses the documented vocabulary (live / starting / hung / stray / unknown root)", function()
        local words = { live = true, starting = true, hung = true, stray = true, ["unknown root"] = true }
        local seen = {}
        for _, e in ipairs(sample()) do
            local t = command.state_text(e)
            local head = t:match("^unknown root") or t:match("^[%a]+")
            assert.is_true(words[head] == true, "not a documented state: " .. t)
            seen[t] = true
        end
        assert.is_true(seen["live"], vim.inspect(seen))          -- live with a client (was "active")
        assert.is_true(seen["live, busy"], vim.inspect(seen))
        assert.is_true(seen["hung"], vim.inspect(seen))          -- (was "not responding")
        assert.is_true(seen["unknown root"], vim.inspect(seen))  -- (was "stray")
        assert.is_true(seen["live, idle 12m"], vim.inspect(seen))
        -- Reasons and the other data dir go after the root; a dev fingerprint is cut.
        local lines = run_list(sample(), { "lw", "daemon", "list" })
        local text = table.concat(lines, "\n")
        assert.truthy(text:find("C:/w/old  (no runtime lock)", 1, true), text)
        assert.truthy(text:find("C:/w/new  (no runtime lock yet)", 1, true), text)
        assert.truthy(text:find("C:/t/test-ws  (other data dir)", 1, true), text)
        assert.truthy(text:find("0.1.42+dev.34399bdb ", 1, true), text)
        assert.is_nil(text:find("34399bdb9585", 1, true), text)
    end)

    it("the PID column is the scanned process, never a pid a lock or handle record names", function()
        local list = sample()
        list[4].reason = "the runtime lock names pid 8"
        local lines = run_list(list, { "lw", "daemon", "list" })
        assert.truthy(lines[5]:find("^4388%s"), lines[5])
        for i = 2, #lines - 1 do assert.is_nil(lines[i]:find("^8%s"), lines[i]) end
    end)

    it("a just-launched daemon without its runtime lock yet is starting, an old one a stray", function()
        local dir = H.tmp()
        local root = ws(dir, "young")
        -- A real young process standing in for a daemon that has not taken R.
        local child = uv.spawn(vim.v.progpath, { args = { "--headless", "-u", "NONE", "--cmd", "sleep 20" } },
            function() end)
        assert.is_truthy(child)
        local pid = child:get_pid()
        local st = proc.start_time(pid)
        H.track(pid, st)
        local d = { pid = pid, start_time = st, root = root, args = { "lw", "daemon", "run", "--root", root } }
        local e = discover.classify(d, false)
        assert.equals("starting", e.state, vim.inspect(e))
        assert.equals("no runtime lock yet", e.reason)
        local grace = discover.STARTING_GRACE_S
        discover.STARTING_GRACE_S = 0
        e = discover.classify(d, false)
        discover.STARTING_GRACE_S = grace
        assert.equals("stray", e.state)
        assert.equals("no runtime lock", e.reason)
        H.cleanup()
        pcall(function() child:close() end)
    end)

    it("a daemon of another data dir: list marks it, stop --all skips it calmly, its own data dir stops it",
        function()
            local env_a, env_b, dir = H.env(), H.env(), parent()
            local a = ws(dir, "alpha")
            local ia = start(a, env_a)
            -- The handle carries the non-secret key id of A's data dir.
            local h = handle.read(a)
            assert.equals("string", type(h.key_id), vim.inspect(h))
            assert.equals(16, #h.key_id)
            -- Listed from env A: same key; from env B: another data dir.
            local da = by_pid(list_json(dir, env_a), ia.pid)
            assert.equals(true, da.same_key)
            local db = by_pid(list_json(dir, env_b), ia.pid)
            assert.equals(false, db.same_key)
            assert.equals("live", db.state)
            local r = H.lw({ "daemon", "list", "--under", dir }, { env = env_b, cwd = H.tmp() })
            assert.truthy(r.stdout:find(a .. "  (other data dir)", 1, true), r.stdout)
            assert.truthy(r.stdout:find("1 daemon (1 idle, 1 other data dir)", 1, true), r.stdout)
            -- stop --all from env B: skipped (exit 0, nothing of B's left), never connected to.
            r = H.lw({ "daemon", "stop", "--all", "--under", dir }, { env = env_b, cwd = H.tmp() })
            assert.equals(0, r.code, r.stdout .. r.stderr)
            assert.truthy(r.stderr:find(a .. ": daemon pid " .. ia.pid .. " belongs to another loomworks data "
                .. "dir (different key) — skipped", 1, true), r.stderr)
            assert.is_nil(r.stderr:find("untrusted", 1, true), r.stderr)
            assert.is_true(H.alive(ia.pid, ia.start_time))
            -- The per-workspace stop from env B says the same, exit 1.
            r = H.lw({ "daemon", "stop" }, { env = env_b, cwd = a })
            assert.equals(1, r.code, r.stdout .. r.stderr)
            assert.truthy(r.stderr:find("belongs to another loomworks data dir (different key)", 1, true), r.stderr)
            assert.is_true(H.alive(ia.pid, ia.start_time))
            r = H.lw({ "daemon", "status" }, { env = env_b, cwd = a })
            assert.truthy(r.stdout:find("NOT ASKED — it belongs to another loomworks data dir", 1, true), r.stdout)
            -- Its own data dir stops it.
            r = H.lw({ "daemon", "stop", "--all", "--under", dir }, { env = env_a, cwd = H.tmp() })
            assert.equals(0, r.code, r.stdout .. r.stderr)
            assert.truthy(r.stdout:find(a .. ": stopped the workspace daemon (pid " .. ia.pid .. ")", 1, true),
                r.stdout)
            assert.is_true(vim.wait(10000, function() return not H.alive(ia.pid, ia.start_time) end, 50))
        end)
end)

describe("relays as real processes (§19.6.1 step 3)", function()
    after_each(function() H.cleanup() end)

    local protocol = require("loomworks.daemon.protocol")
    local version = require("loomworks.daemon.version")
    local function hello()
        return { kind = "hello", protocol = protocol.VERSION, protocol_min = protocol.VERSION_MIN,
            lw_version = version.identity(), schemas = version.schemas(), client = "editor", role = "observer",
            nonce = string.rep("ab", 16) }
    end
    --- A real `lw daemon run --root <root> --stdio [extra…]` that has sent its hello.
    local function relay(root, env, extra)
        local args = { "daemon", "run", "--root", root, "--stdio" }
        vim.list_extend(args, extra or {})
        local p = H.lw_start(args, { env = env, cwd = root, stdin = true })
        H.track(p.pid, p.start)
        p.write(protocol.encode(hello()))
        return p
    end

    it("a relay is listed under its daemon, never as a row; kill_stray refuses it", function()
        local env, dir = H.env(), parent()
        local a = ws(dir, "alpha")
        local ia = start(a, env)
        local p = relay(a, env)
        local first
        assert.is_true(vim.wait(120000, function()
            first = (protocol.new_decoder(protocol.MAX_FRAME):push(p.stdout()) or {})[1]
            return first ~= nil or p.code ~= nil
        end, 20), p.stderr())
        assert.equals("welcome", first and first.kind, p.stderr())
        local doc = list_json(dir, env)
        assert.equals(1, #doc.daemons, vim.inspect(doc))
        assert.is_nil(by_pid(doc, p.pid))
        local da = by_pid(doc, ia.pid)
        assert.equals("live", da.state)
        assert.same({ { pid = p.pid, start_time = p.start } }, da.relays)
        -- Asked to kill it as a stray anyway: refused, it lives.
        local ok, why = command.kill_stray({ pid = p.pid, start_time = p.start, root = a })
        assert.is_false(ok)
        assert.truthy(tostring(why):find("relay", 1, true), why)
        assert.is_true(H.alive(p.pid, p.start))
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, H.stop_daemon(a, env).code)
    end)

    it("a --no-launch relay with no daemon is not listed, and kill --all --strays never touches it", function()
        local env, dir = H.env(), parent()
        local a = ws(dir, "alpha")
        local p = relay(a, env, { "--no-launch" })
        -- Past its hello check (about 5 s): it waits for a daemon.
        vim.wait(7000, function() return p.code ~= nil end, 50)
        assert.is_nil(p.code, p.stderr())
        assert.same({}, list_json(dir, env).daemons)
        local r = H.lw({ "daemon", "kill", "--all", "--strays", "--under", dir }, { env = env, cwd = H.tmp() })
        assert.equals(0, r.code, r.stdout .. r.stderr)
        assert.truthy(r.stdout:find("no workspace daemons are running", 1, true), r.stdout)
        assert.is_true(H.alive(p.pid, p.start))
        assert.is_nil(rlock.read(a), "the relay launched nothing")
        local ok, why = command.kill_stray({ pid = p.pid, start_time = p.start, root = a })
        assert.is_false(ok)
        assert.truthy(tostring(why):find("relay", 1, true), why)
        assert.is_true(H.alive(p.pid, p.start))
        p.close_stdin()
        assert.is_true(p.wait(60000), p.stderr())
        assert.equals(0, p.code, p.stderr())
    end)
end)

describe("daemon processes", function()
    it("none was left running by any test of this file", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a daemon process survived the cleanup")
    end)
end)
