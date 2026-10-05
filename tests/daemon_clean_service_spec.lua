-- `lw clean` in the workspace daemon's build service (spec §19.15 "Clean",
-- §19.19 step 5c): an in-process server with the build service attached (the
-- host is the CLI's own workspace load), a real authenticated client, a real
-- workspace whose `shell` projects run real processes: `app` has a module
-- clean (`clean_cmd`), `lib` none (a core-performed wipe). Covers the
-- in-process lines, nothing to clean (refused before any lock), a failing
-- step, an unsafe wipe path, the exclusive locks, a wipe that does not block
-- the endpoint and a cancellation that stops it between entries, the deletion
-- safety of the wipe (it IS the in-process build-directory deletion,
-- Workspace:clean_wipe_build_dir: cache `unknown` while the tree goes, a
-- stopped wipe leaves it `unknown`, a dir shared outside the clean is kept);
-- plus the stoppable removal itself (loomworks.io.rm_rf_async `opts.stop`).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_lock = require("loomworks.build_lock")
local trust = require("loomworks.trust")
local lio = require("loomworks.io")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end
local function exists(path) return uv.fs_lstat(path) ~= nil end

--- A project's Debug persisted cache state (nil when it has no entry or no
--- state).
local function cached_state(root, project)
    local t = read(root .. "/.nvim/loomworks.cache.json")
    if not t then return nil end
    local data = vim.json.decode(t)
    for _, c in pairs(data.build_dirs or {}) do
        if c.project_key == project and c.config_key == "Debug" then return c.state end
    end
    return nil
end
local function lib_cached_state(root) return cached_state(root, "lib") end

--- A workspace with `app` (configure/build/clean run the STEP script) and
--- `lib` (configure/build, no clean_cmd: a wipe), a set and a profile `dev`.
--- `lib_dir`: lib's build_dir template (default under the root).
--- `shared`: lib also has a Release configuration (its own default
--- directory), used by a second profile `rel` (set `rel`: lib=Release); the
--- test points that unit at lib's Debug directory, as cli_clean_wipe_spec
--- fakes its shared case.
local function workspace(lib_dir, shared)
    -- The root in its canonical (realpath'd) form, as the product resolves a
    -- workspace root (workspace.resolve_root): every build directory the
    -- daemon derives is spelled from it. The temp dir may be reached through
    -- another spelling (CI's TEMP is an 8.3 short name, `RUNNER~1`), and the
    -- paths this spec compares or plants must be the product's spelling.
    local root = vim.fs.normalize(assert(uv.fs_realpath(H.tmp())))
    for _, d in ipairs({ "app", "lib", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
    local step = root .. "/step.lua"
    write(step, H.STEP)
    local nv = (vim.v.progpath:gsub("\\", "/"))
    local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
    write(root .. "/loomworks.json", vim.json.encode({
        projects = {
            app = { path = "app", shell = { build_dir = "${workspace_root}/out/app/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"), clean_cmd = cmd("clean"),
                configurations = { Debug = { build_dir = "${workspace_root}/out/app/Debug" } } } },
            lib = { path = "lib", shell = { build_dir = lib_dir or "${workspace_root}/out/lib/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = { build_dir = lib_dir or "${workspace_root}/out/lib/Debug" },
                    Release = shared and vim.empty_dict() or nil } } },
        },
        configuration_sets = { dev = { app = "Debug", lib = "Debug" }, rel = shared and { lib = "Release" } or nil },
    }))
    local profiles = { dev = { configuration_set = "dev" } }
    if shared then profiles.rel = { configuration_set = "rel" } end
    local signed = trust.sign("user", trust.encode({ _meta = { version = 2 }, profiles = profiles }))
    write(root .. "/.nvim/loomworks.user.json", signed)
    return root
end

--- A routed request through an authenticated connection. Returns a recorder.
local function request(srv, kind, args, opts)
    opts = opts or {}
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    local env = envscope.capture()
    for k, v in pairs(opts.env or {}) do env[k] = v or nil end
    conn:request({ kind = kind, args = args or { profile = "dev" }, interactive = false,
        env = env, command = "lw " .. kind }, function(r, e) rec.reply = r or { error = e } end)
    function rec.wait_reply() return vim.wait(60000, function() return rec.reply ~= nil end, 10) end
    function rec.done()
        for _, m in ipairs(rec.events) do if m.phase == "done" then return m end end
    end
    function rec.start()
        for _, m in ipairs(rec.events) do if m.phase == "start" then return m end end
    end
    function rec.wait_done(ms) return vim.wait(ms or 60000, function() return rec.done() ~= nil end, 10) end
    function rec.lines()
        local t = {}
        for _, m in ipairs(rec.events) do
            if m.phase == "line" then t[#t + 1] = m.stream .. ":" .. tostring(m.text) end
        end
        return table.concat(t, "\n")
    end
    function rec.output()
        local t = {}
        for _, m in ipairs(rec.events) do if m.phase == "output" then t[#t + 1] = tostring(m.text) end end
        return table.concat(t)
    end
    return rec
end

describe("lw clean in the daemon's build service (§19.15 Clean)", function()
    local root, srv
    local real_rm = lio.rm_rf_async
    local lib_outside
    local function start(lib_dir, shared)
        lib_outside = lib_dir ~= nil
        root = workspace(lib_dir, shared)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end
    local function built()
        local b = request(srv, "build")
        assert.is_true(b.wait_done())
        assert.equals(0, b.done().exit_code, b.lines())
        b.conn:close()
        -- (The STEP script creates no build directory; a clean skips a
        -- missing one.)
        vim.fn.mkdir(root .. "/out/app/Debug", "p")
        if not lib_outside then vim.fn.mkdir(root .. "/out/lib/Debug", "p") end
    end
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
    end)
    after_each(function()
        lio.rm_rf_async = real_rm
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("runs each project's clean with the in-process lines: module clean, then the wipe", function()
        start()
        built()
        local libdir = root .. "/out/lib/Debug"
        write(libdir .. "/artifact.o", "x")
        -- Both units start built (persisted), so the states below prove the
        -- clean's transitions.
        assert.equals("built", cached_state(root, "app"))
        assert.equals("built", lib_cached_state(root))
        local r = request(srv, "clean")
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("dev", r.reply.profile_key)
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        assert.equals("clean", r.start().meta.kind)
        local lines = r.lines()
        local a = lines:find("out:cleaning profile: dev", 1, true)
        local b = lines:find("out:==> [clean] app: clean Debug", 1, true)
        local c = lines:find("out:==> [clean] lib: clean Debug", 1, true)
        local d = lines:find("out:CLEAN OK: dev", 1, true)
        assert.truthy(a and b and c and d and a < b and b < c and c < d, lines)
        assert.truthy(r.output():find("step clean", 1, true), r.output())
        -- The wipe removed lib's build directory; app's (module clean) is kept.
        assert.is_false(exists(libdir))
        assert.is_true(exists(root .. "/out/app/Debug"))
        -- The module clean left app configured, persisted (spec §3, §16.18:
        -- `lw status` no longer shows it built); the wipe reset lib.
        assert.equals("configured", cached_state(root, "app"))
        assert.is_nil(lib_cached_state(root))
        assert.is_nil(build_lock.read(libdir))
        r.conn:close()
    end)

    it("nothing to clean: refused with the in-process line, before any lock", function()
        start()
        local r = request(srv, "clean")
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome)
        assert.equals("nothing to clean for profile 'dev' — no configured build directories.", r.reply.message)
        assert.equals(1, r.reply.exit_code)
        assert.is_false(exists(root .. "/out"))
        r.conn:close()
        -- An unknown profile: the in-process resolution refusal.
        r = request(srv, "clean", { profile = "nope" })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome)
        assert.equals("no profile matching 'nope'. Run `lw profile list` to list.", r.reply.message)
        r.conn:close()
    end)

    it("a failing step ends the task with the in-process line and exit code; later steps not run", function()
        start()
        built()
        local libdir = root .. "/out/lib/Debug"
        local r = request(srv, "clean", nil, { env = { LW_TEST_FAIL = "clean" } })
        assert.is_true(r.wait_done())
        assert.equals(3, r.done().exit_code)
        assert.equals("clean failed (exit 3): app: clean Debug", r.done().error)
        assert.is_nil(r.lines():find("lib: clean", 1, true))
        assert.is_true(exists(libdir))
        assert.is_nil(build_lock.read(libdir))
        r.conn:close()
    end)

    it("an unsafe wipe path is refused with the in-process line, nothing removed", function()
        local outside = H.tmp() .. "/outside"
        vim.fn.mkdir(outside, "p")
        write(outside .. "/keep.txt", "keep")
        start((outside:gsub("\\", "/")))
        built()
        local r = request(srv, "clean")
        assert.is_true(r.wait_done())
        assert.equals(1, r.done().exit_code, r.lines())
        assert.truthy(r.done().error:find("^clean refused: unsafe build directory "), r.done().error)
        assert.equals("keep", read(outside .. "/keep.txt"))
        r.conn:close()
    end)

    it("holds every build directory's lock exclusively while it runs (operation clean)", function()
        start()
        built()
        local pidfile = H.tmp() .. "/pid"
        local r = request(srv, "clean", nil, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".clean") ~= nil end, 20), r.lines())
        for _, p in ipairs({ "app", "lib" }) do
            local rec = build_lock.read(root .. "/out/" .. p .. "/Debug")
            assert.truthy(rec, p)
            assert.equals("clean", rec.operation, vim.inspect(rec))
        end
        -- A build of the same profile meanwhile is refused naming the daemon.
        local b = request(srv, "build", nil, { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(b.wait_done())
        assert.equals(1, b.done().exit_code)
        assert.truthy(b.done().error:find("in use by the workspace daemon (pid " .. srv.pid, 1, true), b.done().error)
        b.conn:close()
        r.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        assert.is_nil(build_lock.read(root .. "/out/app/Debug"))
    end)

    it("a wipe never blocks the endpoint; cancelling stops it between entries (clean stopped)", function()
        start()
        built()
        local libdir = root .. "/out/lib/Debug"
        local pending
        lio.rm_rf_async = function(dir, cb, o)
            pending = { dir = dir, stop = o and o.stop, done = cb, cache = lib_cached_state(root) }
            return require("loomworks.future").create(function() end)
        end
        local seen = {}
        local obs = assert(client.session(srv.address, { client = "editor", role = "observer",
            on_message = function(m) seen[#seen + 1] = m end }))
        local r = request(srv, "clean")
        assert.is_true(vim.wait(30000, function() return pending ~= nil end, 10), r.lines())
        assert.equals(libdir:lower(), (pending.dir:gsub("\\", "/")):lower(), vim.inspect(r.events))
        assert.is_function(pending.stop)
        assert.is_false(pending.stop())
        -- The wipe is the deletion: the cache said `unknown` before removal.
        assert.equals("unknown", pending.cache)
        -- The endpoint answers while the wipe runs.
        local pong
        r.conn:request({ kind = "ping" }, function(x) pong = x end)
        assert.is_true(vim.wait(5000, function() return pong ~= nil end, 10))
        assert.equals("ok", pong.kind)
        assert.truthy(build_lock.read(libdir))
        -- The client goes (Ctrl-C): the wipe is asked to stop; the locks are
        -- held until it has.
        r.conn:close()
        assert.is_true(vim.wait(5000, function() return pending.stop() end, 10))
        assert.truthy(build_lock.read(libdir))
        pending.done(false, "stopped", true)
        local done
        assert.is_true(vim.wait(10000, function()
            for _, m in ipairs(seen) do if m.kind == "task" and m.phase == "done" then done = m; return true end end
            return false
        end, 10))
        assert.equals(130, done.exit_code)
        assert.equals("clean stopped: the client that started it disconnected", done.error)
        assert.is_true(vim.wait(5000, function() return build_lock.read(libdir) == nil end, 10))
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 10))
        -- Stopped after a (possibly) partial removal: never reset, the cache
        -- stays `unknown` (crash-safe, spec §4.7).
        assert.equals("unknown", lib_cached_state(root))
        obs:close()
    end)

    it("the wipe marks the cache unknown, then resets it after the removal", function()
        start()
        built()
        local libdir = root .. "/out/lib/Debug"
        assert.equals("built", lib_cached_state(root))
        local seen
        lio.rm_rf_async = function(dir, cb, o)
            seen = lib_cached_state(root)
            return real_rm(dir, cb, o)
        end
        local r = request(srv, "clean")
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        assert.equals("unknown", seen)
        assert.is_false(exists(libdir))
        local after = lib_cached_state(root)
        assert.is_true(after == nil or after == "unconfigured", tostring(after))
        r.conn:close()
    end)

    it("keeps a build directory still used by a configuration outside the clean", function()
        start(nil, true)
        built()
        local libdir = root .. "/out/lib/Debug"
        write(libdir .. "/artifact.o", "x")
        -- Profile rel's lib (Release) uses the same directory and is built
        -- there (as cli_clean_wipe_spec fakes it): a reference OUTSIDE the
        -- clean of dev, in the daemon's live workspace.
        local ws = assert(srv.service.ws)
        local rel
        for _, p in ipairs(ws._profiles) do if p.key == "rel" then rel = p end end
        local unit = assert(assert(rel, "profile rel").projects and rel:projects()[1]._config_unit,
            "rel's lib has a config unit")
        unit.build_dir_value = libdir
        unit.state_value = "built"
        ws:_sync_build_dir_refs()
        local removed = false
        lio.rm_rf_async = function(dir, cb, o)
            if (dir:gsub("\\", "/")):lower() == libdir:lower() then removed = true end
            return real_rm(dir, cb, o)
        end
        local r = request(srv, "clean")
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        assert.truthy(r.lines():find("still used by another configuration", 1, true), r.lines())
        assert.is_false(removed)
        assert.equals("x", read(libdir .. "/artifact.o"))
        r.conn:close()
    end)

    it("the real wipe removes a tree in the daemon process", function()
        start()
        built()
        local libdir = root .. "/out/lib/Debug"
        for i = 1, 50 do
            vim.fn.mkdir(libdir .. "/d" .. i, "p")
            write(libdir .. "/d" .. i .. "/f.o", "x")
        end
        local r = request(srv, "clean")
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        assert.is_false(exists(libdir))
        r.conn:close()
    end)
end)

describe("loomworks.io.rm_rf_async with a stop predicate", function()
    local function tree(n)
        local d = H.tmp() .. "/tree"
        for i = 1, n do
            vim.fn.mkdir(d .. "/d" .. i, "p")
            write(d .. "/d" .. i .. "/f", "x")
        end
        return d
    end

    it("removes a tree asynchronously (returns before it is done)", function()
        local d = tree(20)
        local res
        lio.rm_rf_async(d, function(ok, err, stopped)
            res = { ok = ok, err = err, stopped = stopped }
        end, { stop = function() return false end })
        assert.is_nil(res)
        assert.is_true(vim.wait(10000, function() return res ~= nil end, 10))
        assert.is_true(res.ok, res.err)
        assert.is_nil(res.stopped)
        assert.is_false(exists(d))
    end)

    it("stops between entries: what was removed stays removed, the root is kept", function()
        local d = tree(40)
        local asked, res = 0, nil
        lio.rm_rf_async(d, function(ok, err, stopped) res = { ok = ok, err = err, stopped = stopped } end,
            { stop = function()
                asked = asked + 1
                return asked > 10
            end })
        assert.is_true(vim.wait(10000, function() return res ~= nil end, 10))
        assert.is_true(res.stopped)
        assert.is_false(res.ok)
        assert.is_true(exists(d))
    end)

    it("removes a link, never what it points to", function()
        local target = H.tmp() .. "/target"
        vim.fn.mkdir(target, "p")
        write(target .. "/keep", "keep")
        local d = tree(1)
        local ok = uv.fs_symlink(target, d .. "/link", { junction = true, dir = true })
        if not ok then return end -- (no link support here)
        local res
        lio.rm_rf_async(d, function(o, e) res = { ok = o, err = e } end, { stop = function() return false end })
        assert.is_true(vim.wait(10000, function() return res ~= nil end, 10))
        assert.is_true(res.ok, res.err)
        assert.is_false(exists(d))
        assert.equals("keep", read(target .. "/keep"))
    end)
end)
