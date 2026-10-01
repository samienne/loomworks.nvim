-- Daemon build parity (spec §19.12 / §19.13): a build the daemon runs must be
-- behaviorally identical to the in-process `lw build` it replaces. Both go
-- through `loomworks.build_run`; these specs drive the SAME plan through the
-- in-process runner (`cli._run_build_steps`) and the daemon runner
-- (`daemon.runner.run_build`) and compare what each leaves behind — the
-- serialized cache, the configure record, the full-reconfigure reset, the
-- build request, the status lines — plus the daemon-only lifecycle rules:
-- live-workspace re-validation, profile resolution, cancellation on client
-- disconnect, and stopping a build whose workspace was unloaded (§17.4).
-- No toolchain: the plan and the spawn are stubbed (tests/daemon_real_build_spec
-- covers a real cmake + ninja build).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local helpers = require("tests.helpers")
local Core = require("loomworks.core")
local cli = require("loomworks.cli")
local runner = require("loomworks.daemon.runner")
local overseer = require("loomworks.overseer")
local snapshot = require("loomworks.daemon.snapshot")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local protocol = require("loomworks.daemon.protocol")
local build_lock = require("loomworks.build_lock")
local uv = vim.uv or vim.loop

local function strip(s) return (s:gsub("\27%[[%d;]*m", "")) end

local function new_events()
    local L = {}
    return { on = function(e, f) L[e] = L[e] or {}; L[e][#L[e] + 1] = f end, off = function() end,
        emit = function(e, d) for _, f in ipairs(L[e] or {}) do pcall(f, d) end end }
end

--- `set_name` names the configuration set — and so the profile key (a profile
--- without a tool is keyed by its set).
local function files(set_name)
    set_name = set_name or "dev"
    return {
        ["loomworks.json"] = helpers.make_config_json({
            projects = { App = { cmake = { configurations = { Debug = { variant = "Debug" } } } } },
        }),
        ["loomworks.user.json"] = helpers.make_user_json({ active_profile = set_name,
            profiles = { [set_name] = { configuration_set = set_name } },
            configuration_sets = { [set_name] = { App = "Debug" } } }),
        ["loomworks.cache.json"] = helpers.make_cache_json(),
    }
end

--- A loaded in-memory workspace at a real temp root (build-dir locks are real
--- files), with a buildable profile and its ConfigUnit.
--- @param opts? { root?: string, files?: table, deps?: table }
local function fixture(opts)
    opts = opts or {}
    local root = opts.root or (vim.fn.tempname():gsub("\\", "/"))
    local f = opts.files or files()
    local deps = helpers.make_test_deps(f, vim.tbl_extend("force", {
        events = new_events(),
        now = function() return 1000 end,
    }, opts.deps or {}))
    local core = Core.new(deps)
    core:setup({ root = root })
    vim.wait(3000, function() return core._state == "initialized" or core._state == "uninitialized" end, 5)
    local ws = core:get_workspace()
    assert.is_not_nil(ws, "fixture workspace failed to load")
    local profile = ws._profiles[1]
    -- The fake cmake module selects no tool; the gate itself is shared code.
    profile.assert_buildable = function() return true end
    local pp = profile:projects()[1]
    local fx = { root = root, files = f, core = core, ws = ws, profile = profile,
        unit = pp._config_unit, bd = pp:build_dir(), resets = {}, records = 0 }
    vim.fn.mkdir(vim.fn.fnamemodify(fx.bd, ":h"), "p")
    -- Observe the core-performed full-reconfigure reset (§5.1 / §8.1).
    ws._pre_configure_reset = function(_, build_dir, entries)
        fx.resets[#fx.resets + 1] = { build_dir = build_dir, entries = vim.deepcopy(entries) }
        return true
    end
    local orig_record = ws.record_task_result
    ws.record_task_result = function(self, result)
        fx.records = fx.records + 1
        return orig_record(self, result)
    end
    return fx
end

--- A configure (full reconfigure with a reset list + a module record) then a
--- build — the shape a real cmake plan has.
local function standard_plan(fx)
    return function(profile, popts)
        fx.plan_opts = popts
        return {
            { kind = "configure", name = "App/Debug", unit = fx.unit, profile = profile,
              build_dir = fx.bd,
              module_info = { passed_options = { "-DFOO=1" }, generator = "Ninja" },
              pre_configure_reset = { "CMakeCache.txt", "CMakeFiles" },
              configure_reason = "configure record from an older lw", reconfigure = "full",
              reconfigure_detail = "reset CMakeCache.txt + CMakeFiles",
              cmd = { vim.v.progpath, "--version" } },
            { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
              build_dir = fx.bd, applied_build_args = popts and popts.build_args and true or nil,
              cmd = { vim.v.progpath, "--version" } },
        }
    end
end

--- Run the in-process build (cli run_build_steps) with the spawn stubbed.
--- Returns { code (nil = ok), stdout, stderr, spawned }.
local function run_inprocess(fx, opts, spawn_code)
    local res = { spawned = {} }
    local o_spawn, o_write, o_stderr, o_exit = cli._run_spec, io.write, io.stderr, os.exit
    local out_buf, err_buf = {}, {}
    cli._run_spec = function(step)
        res.spawned[#res.spawned + 1] = step
        return spawn_code and spawn_code(step) or 0
    end
    io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    os.exit = function(c) res.code = c or 0; error({ __exit = true }, 0) end
    local ok, err = pcall(cli._run_build_steps, fx.profile, fx.ws, opts or {})
    cli._run_spec, io.write, io.stderr, os.exit = o_spawn, o_write, o_stderr, o_exit
    if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
    res.stdout, res.stderr = strip(table.concat(out_buf)), strip(table.concat(err_buf))
    return res
end

--- A fake task stream recording what the daemon runner reports.
local function fake_stream()
    local s = { out = {}, err = {}, notes = {}, started = false }
    function s.start() s.started = true end
    function s.progress() end
    function s.output(_, _, stream, text)
        local t = stream == "stderr" and s.err or s.out
        t[#t + 1] = text
    end
    function s.notify(_, level, _, msg) s.notes[#s.notes + 1] = { level = level, msg = msg } end
    function s.done(_, _, code) s.code = code end
    return s
end

--- Run the daemon runner with the async spawn stubbed. `spawn_code(argv)`
--- returns the exit code, or false to never exit on its own (until killed).
local function run_daemon(fx, opts, spawn_code, no_wait)
    local res = { spawned = {}, killed = 0 }
    local s = fake_stream()
    runner.spawn_stream = function(argv, sopts, sink)
        res.spawned[#res.spawned + 1] = { cmd = argv, cwd = sopts.cwd, env = sopts.env }
        local code = 0
        if spawn_code then code = spawn_code(argv) end
        local handle = { pid = nil }
        function handle.kill()
            res.killed = res.killed + 1
            vim.schedule(function() sink.done(143) end)
        end
        if code ~= false then vim.schedule(function() sink.done(code) end) end
        return handle
    end
    res.ctl = runner.run_build(fx.ws, fx.profile, s, 1, opts or {}, function(c) res.code = c end)
    res.stream = s
    if not no_wait then
        assert.is_true(vim.wait(5000, function() return res.code ~= nil end, 5), "daemon build never finished")
    end
    res.stdout = function() return strip(table.concat(s.out)) end
    res.errors = function()
        local l = {}
        for _, n in ipairs(s.notes) do if n.level == "error" then l[#l + 1] = n.msg end end
        return table.concat(l, "\n")
    end
    return res
end

describe("daemon build parity with in-process lw build", function()
    local orig_plan, orig_spawn_stream
    before_each(function()
        orig_plan, orig_spawn_stream = overseer.plan_profile_build, runner.spawn_stream
    end)
    after_each(function()
        overseer.plan_profile_build, runner.spawn_stream = orig_plan, orig_spawn_stream
    end)

    it("the same plan leaves an identical cache, configure record and reset both ways", function()
        local root = (vim.fn.tempname():gsub("\\", "/"))
        local a = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(a)
        local ip = run_inprocess(a, {})
        assert.is_nil(ip.code, ip.stderr)
        local ref = snapshot.serialize(a.ws).cache

        local b = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(b)
        local d = run_daemon(b, {})
        assert.equals(0, d.code, d.errors())

        assert.same(ref, snapshot.serialize(b.ws).cache)
        -- The configure record (§5.1) survives — the next build compares against it.
        assert.same({ "-DFOO=1" }, b.unit.module_info.passed_options)
        assert.same(a.unit.module_info, b.unit.module_info)
        assert.equals("built", b.unit.state_value)
        -- The full-reconfigure reset ran before the configure, both ways.
        assert.same(a.resets, b.resets)
        assert.equals(1, #b.resets)
        assert.same({ "CMakeCache.txt", "CMakeFiles" }, b.resets[1].entries)
    end)

    it("prints the same status lines (building / ==> step / why the configure runs)", function()
        local root = (vim.fn.tempname():gsub("\\", "/"))
        local a = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(a)
        local ip = run_inprocess(a, {})
        local b = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(b)
        local d = run_daemon(b, {})
        assert.equals(ip.stdout, d.stdout())
        assert.matches("building profile: dev", d.stdout(), 1, true)
        assert.matches("full reconfigure (reset CMakeCache.txt + CMakeFiles)", d.stdout(), 1, true)
    end)

    it("hands `-- args` to the module (build_args) and never re-appends what it applied", function()
        local fx = fixture()
        overseer.plan_profile_build = standard_plan(fx)
        local d = run_daemon(fx, { extra_args = { "-j", "3" } })
        assert.equals(0, d.code, d.errors())
        assert.same({ "-j", "3" }, fx.plan_opts.build_args)
        -- The module applied them (applied_build_args): the build argv is the module's.
        assert.equals(2, #d.spawned[2].cmd)
    end)

    it("refuses to append `-- args` to a batch-wrapped build the module did not apply them to", function()
        local fx = fixture()
        overseer.plan_profile_build = function(profile)
            return { { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
                build_dir = fx.bd, cmd = { "cmd", "/d", "/c", "C:/x/build.bat" } } }
        end
        local d = run_daemon(fx, { extra_args = { "-j", "3" } })
        assert.equals(1, d.code)
        assert.equals(0, #d.spawned)
        assert.matches("does not accept build args", d.errors(), 1, true)
    end)

    it("a plan error refuses the build (exit 1) instead of reporting success", function()
        local fx = fixture()
        overseer.plan_profile_build = function() return nil, "App/Debug: unsafe vcvarsall path" end
        local d = run_daemon(fx, {})
        assert.equals(1, d.code)
        assert.matches("cannot build: App/Debug: unsafe vcvarsall path", d.errors(), 1, true)
    end)

    it("nothing to build is a refusal (exit 1), as in-process", function()
        local fx = fixture()
        overseer.plan_profile_build = function() return {} end
        local d = run_daemon(fx, {})
        assert.equals(1, d.code)
        assert.matches("nothing to build for profile 'dev'", d.errors(), 1, true)
    end)

    it("spawns the hardened argv (absolute program, Windows no-cwd env), never a bare name", function()
        local fx = fixture()
        local exe = require("loomworks.exe")
        overseer.plan_profile_build = function(profile)
            return { { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
                build_dir = fx.bd, cmd = { vim.fn.fnamemodify(vim.v.progpath, ":t"), "--version" },
                env = { PATH = vim.fn.fnamemodify(vim.v.progpath, ":h") } } }
        end
        local d = run_daemon(fx, {})
        assert.equals(0, d.code, d.errors())
        local argv0 = d.spawned[1].cmd[1]:gsub("\\", "/")
        assert.is_truthy(argv0:match("^/") or argv0:match("^%a:/"), "not absolute: " .. argv0)
        if vim.fn.has("win32") == 1 then
            assert.equals("1", d.spawned[1].env[exe.NO_CWD_ENV])
        end
    end)

    it("an unresolvable program is reported and never spawned (exit 127, recorded failed)", function()
        local fx = fixture()
        overseer.plan_profile_build = function(profile)
            return { { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
                build_dir = fx.bd, cmd = { "definitely-not-a-program-xyz" } } }
        end
        local d = run_daemon(fx, {})
        assert.equals(127, d.code)
        assert.equals(0, #d.spawned)
        assert.equals("failed_build", fx.unit.state_value)
    end)

    it("a failed step exits with the step's code and the in-process failure line", function()
        local root = (vim.fn.tempname():gsub("\\", "/"))
        local a = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(a)
        local ip = run_inprocess(a, {}, function(step) return step.kind == "build" and 2 or 0 end)
        local b = fixture({ root = root })
        overseer.plan_profile_build = standard_plan(b)
        local calls = 0
        local d = run_daemon(b, {}, function() calls = calls + 1; return calls == 2 and 2 or 0 end)
        assert.equals(2, ip.code)
        assert.equals(2, d.code)
        assert.matches("lw: " .. d.errors(), ip.stderr, 1, true)
        assert.same(snapshot.serialize(a.ws).cache, snapshot.serialize(b.ws).cache)
    end)
end)

describe("daemon build lifecycle", function()
    local orig_plan, orig_spawn_stream, server
    before_each(function()
        orig_plan, orig_spawn_stream = overseer.plan_profile_build, runner.spawn_stream
    end)
    after_each(function()
        overseer.plan_profile_build, runner.spawn_stream = orig_plan, orig_spawn_stream
        if server and not server:is_stopped() then server:stop("cleanup") end
        server = nil
    end)

    --- A raw pipe client collecting every message.
    local function connect(addr)
        local c = { pipe = uv.new_pipe(false), messages = {}, decoder = protocol.new_decoder() }
        c.pipe:connect(addr, function(err)
            if err then c.error = err; return end
            c.connected = true
            c.pipe:read_start(function(rerr, chunk)
                if rerr or not chunk then return end
                for _, p in ipairs(c.decoder:push(chunk)) do
                    local m = protocol.decode(p); if m then c.messages[#c.messages + 1] = m end
                end
            end)
        end)
        assert.is_true(vim.wait(2000, function() return c.connected end, 10), "client connect")
        function c.send(m) c.pipe:write(protocol.encode(m)) end
        function c.close() pcall(function() if not c.pipe:is_closing() then c.pipe:close() end end) end
        function c.reply(id)
            for _, m in ipairs(c.messages) do if m.req_id == id then return m end end
        end
        function c.task(phase)
            for _, m in ipairs(c.messages) do
                if m.kind == protocol.KIND.task and m.phase == phase then return m end
            end
        end
        return c
    end

    local function serve(fx, run_build)
        server = server_mod.new(fx.root)
        service.attach(server, { workspace = fx.ws, core = fx.core, run_build = run_build,
            no_change_subscription = true })
        assert.is_true((server:start()))
        return server
    end

    it("resolves the profile with the in-process matcher (unambiguous substring)", function()
        local fx = fixture({ files = files("Debug-fast") })
        local got
        serve(fx, function(srv, _args, task_id, ctx)
            got = ctx.profile.key
            srv.tasks:done(task_id, 0)
        end)
        local c = connect(server.address)
        c.send({ kind = "command", name = "build", args = { profile_key = "fast" }, req_id = 1 })
        assert.is_true(vim.wait(3000, function() return c.reply(1) ~= nil end, 10))
        assert.equals("accepted", c.reply(1).outcome, vim.inspect(c.reply(1)))
        assert.equals("Debug-fast", c.reply(1).profile_key)
        assert.equals("Debug-fast", got)
        c.close()
    end)

    it("an unknown profile is not accepted (the client falls back in-process)", function()
        local fx = fixture()
        local ran = false
        serve(fx, function() ran = true end)
        local c = connect(server.address)
        c.send({ kind = "command", name = "build", args = { profile_key = "nope" }, req_id = 1 })
        assert.is_true(vim.wait(3000, function() return c.reply(1) ~= nil end, 10))
        assert.equals(protocol.KIND.error, c.reply(1).kind)
        assert.matches(service.ERR_PROFILE, c.reply(1).error, 1, true)
        assert.is_false(ran)
        c.close()
    end)

    it("re-reads the workspace files first: a working copy no longer trusted refuses the build", function()
        local f = files()
        local trust_all = helpers.trust_all
        local fx = fixture({ files = f, deps = {
            FileTracker = require("loomworks.file_tracker"),
            -- A real tracker polls from a libuv callback: defer like the editor.
            schedule = vim.schedule,
            trust = {
                verify = function(kind, text)
                    if text and text:find("TAMPERED", 1, true) then return "unsigned", nil end
                    return trust_all.verify(kind, text)
                end,
                sign_file = trust_all.sign_file,
            },
        } })
        local ran = false
        serve(fx, function() ran = true end)
        -- Hand-edited since the daemon loaded it (within one poll interval).
        f["loomworks.user.json"] = f["loomworks.user.json"] .. "\n// TAMPERED"
        local c = connect(server.address)
        c.send({ kind = "command", name = "build", args = { profile_key = "dev" }, req_id = 1 })
        assert.is_true(vim.wait(3000, function() return c.reply(1) ~= nil end, 10))
        assert.equals(protocol.KIND.error, c.reply(1).kind)
        assert.matches(service.ERR_WORKSPACE, c.reply(1).error, 1, true)
        assert.is_false(ran)
        assert.is_nil(fx.core:get_workspace())
        c.close()
    end)

    it("a build whose workspace is unloaded mid-run is stopped and the step not recorded", function()
        local fx = fixture()
        overseer.plan_profile_build = function(profile)
            return { { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
                build_dir = fx.bd, cmd = { vim.v.progpath } } }
        end
        local current = true
        local d = run_daemon(fx, { is_current = function() return current, "the workspace was unloaded" end },
            function() return false end, true)
        assert.is_true(vim.wait(3000, function() return #d.spawned == 1 end, 5))
        current = false
        assert.is_true(vim.wait(3000, function() return d.code ~= nil end, 10), "build never stopped")
        assert.equals(1, d.killed)
        assert.equals(1, d.code)
        assert.matches("build stopped: the workspace was unloaded", d.errors(), 1, true)
        assert.equals(0, fx.records)
        -- The build-dir lock is released.
        local h = build_lock.acquire(fx.bd, "build")
        assert.is_not_nil(h); build_lock.release(h)
    end)

    it("the launching client's disconnect cancels its build and releases the build-dir lock", function()
        local fx = fixture()
        overseer.plan_profile_build = function(profile)
            return { { kind = "build", name = "App/Debug", unit = fx.unit, profile = profile,
                build_dir = fx.bd, cmd = { vim.v.progpath } } }
        end
        local killed = 0
        runner.spawn_stream = function(_, _, sink)
            return { kill = function()
                killed = killed + 1
                vim.schedule(function() sink.done(143) end)
            end }
        end
        serve(fx, nil)
        local observer = connect(server.address)
        local c = connect(server.address)
        c.send({ kind = "command", name = "build", args = { profile_key = "dev" }, req_id = 1 })
        assert.is_true(vim.wait(3000, function() return c.task("start") ~= nil end, 10), "build never started")
        assert.is_nil(build_lock.acquire(fx.bd, "build"), "the running build must hold the lock")
        c.close() -- Ctrl-C on `lw build`
        assert.is_true(vim.wait(3000, function() return observer.task("done") ~= nil end, 10),
            "build was not cancelled")
        assert.equals(1, killed)
        assert.equals(130, observer.task("done").exit_code)
        assert.equals(0, fx.records)
        local h = build_lock.acquire(fx.bd, "build")
        assert.is_not_nil(h); build_lock.release(h)
        observer.close()
    end)
end)

describe("cli delegation client", function()
    local function delegate(fake_build)
        local fake_proj = { build = fake_build, close = function() end }
        local o_write, o_stderr = io.write, io.stderr
        local out_buf, err_buf = {}, {}
        io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
        local ok, code = pcall(cli._maybe_delegate_build, "/ws", { "build", "fast" }, {
            mode = "daemon",
            trusted = function() return true end,
            detect = function() return { present = true, live = true, compatible = true } end,
            connect = function(_root, copts, cb) fake_proj.copts = copts; cb(fake_proj, nil) end,
        })
        io.write, io.stderr = o_write, o_stderr
        assert.is_true(ok, tostring(code))
        return code, strip(table.concat(out_buf)), strip(table.concat(err_buf)), fake_proj
    end

    it("prints the daemon's refusal like `die` and exits with the build's code", function()
        local code, _, err = delegate(function(self, _, cbs)
            cbs.on_accept(7, nil, { profile_key = "Debug-fast" })
            self.copts.on_notify({ level = "error", task_id = 7, message = "build failed (exit 2): App/Debug" })
            cbs.on_done(2)
        end)
        assert.equals(2, code)
        assert.matches("lw: build failed (exit 2): App/Debug", err, 1, true)
    end)

    it("reports success with the resolved profile key", function()
        local code, out = delegate(function(_, _, cbs)
            cbs.on_accept(1, nil, { profile_key = "Debug-fast" })
            cbs.on_done(0)
        end)
        assert.equals(0, code)
        assert.matches("BUILD OK: Debug-fast", out, 1, true)
    end)

    it("falls back in-process, silently, when the daemon cannot resolve the profile", function()
        local code, _, err = delegate(function(_, _, cbs)
            cbs.on_accept(nil, service.ERR_PROFILE .. ": no profile matching 'fast'")
        end)
        assert.is_nil(code)
        assert.equals("", err)
    end)

    it("a daemon lost after accepting fails the build (never re-run in-process)", function()
        local code, _, err = delegate(function(_, _, cbs)
            cbs.on_accept(1, nil, { profile_key = "Debug-fast" })
            cbs.on_lost("daemon_lost")
        end)
        assert.equals(1, code)
        assert.matches("lost the connection to the daemon", err, 1, true)
    end)
end)

describe("FileTracker:sync", function()
    it("delivers a change now, once (the next poll sees no change)", function()
        local FileTracker = require("loomworks.file_tracker")
        local content = { ["/x/a.json"] = "1" }
        local seen = {}
        local t = FileTracker.new({
            callback = function(p, c) seen[#seen + 1] = { p, c } end,
            read_file = function(p) return content[p] end,
            schedule = function(fn) fn() end,
        })
        t:watch("/x/a.json")
        t:sync()
        assert.equals(0, #seen)
        content["/x/a.json"] = "2"
        t:sync()
        assert.same({ { "/x/a.json", "2" } }, seen)
        t:sync()
        assert.equals(1, #seen)
        content["/x/a.json"] = nil -- deleted (lw nuke / lw trust --discard)
        t:sync()
        assert.same({ "/x/a.json", nil }, seen[2])
        t:stop()
    end)
end)
