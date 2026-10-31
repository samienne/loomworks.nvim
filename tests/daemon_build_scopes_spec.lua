-- The editor's build scopes in the workspace daemon (spec §19.15 "Editor
-- scopes and configure", §19.19 step 5k part B1): `loomworks.Build/1`'s
-- `configure` method, `units` on build / configure / clean, `jobs`, and
-- `{ project, target }` target operands — called over transport 11 against
-- an in-process server with the build service attached (the host is the
-- CLI's own workspace load) and a real workspace whose `shell` projects run
-- real processes: `app` (configure, build, a module clean) and `lib`
-- (configure, build, no clean: a wipe).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_lock = require("loomworks.build_lock")
local trust = require("loomworks.trust")
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

--- A project's Debug persisted cache state.
local function cached_state(root, project)
    local t = read(root .. "/.nvim/loomworks.cache.json")
    if not t then return nil end
    for _, c in pairs(vim.json.decode(t).build_dirs or {}) do
        if c.project_key == project and c.config_key == "Debug" then return c.state end
    end
    return nil
end

--- `app` and `lib` (shell projects running the STEP script), the set and
--- profile `dev` (app=Debug, lib=Debug). `opts.lib_invalid`: lib's build_dir
--- template names a variable a shell template may not use, so the module
--- reports an `error` for its Debug (§8 `info`).
local function workspace(opts)
    opts = opts or {}
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
                configurations = { Debug = vim.empty_dict() } } },
            lib = { path = "lib", shell = { build_dir = opts.lib_invalid
                    and "${workspace_root}/out/${LW_DBS_UNDECLARED}/${variant}"
                    or "${workspace_root}/out/lib/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = vim.empty_dict() } } },
        },
        configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
    }))
    local signed = trust.sign("user", trust.encode({ _meta = { version = 2 },
        profiles = { dev = { configuration_set = "dev" } } }))
    write(root .. "/.nvim/loomworks.user.json", signed)
    return root
end

--- A `loomworks.Build/1` call through an authenticated connection; records
--- the reply (or error) and the task frames.
local function call(srv, method, args, opts)
    opts = opts or {}
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    local env = envscope.capture()
    for k, v in pairs(opts.env or {}) do env[k] = v or nil end
    conn:call(opts.object or "/build", opts.iface or "loomworks.Build", 1, method, args, function(r, e) rec.reply = r; rec.err = e end, env)
    function rec.wait_reply() return vim.wait(60000, function() return rec.reply ~= nil or rec.err ~= nil end, 10) end
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
    --- The lines in this order (each found after the previous one).
    function rec.ordered(list)
        local text, at = rec.lines(), 1
        for _, l in ipairs(list) do
            local i = text:find(l, at, true)
            if not i then return false end
            at = i + #l
        end
        return true
    end
    --- Run to the end; returns the done frame.
    function rec.finish()
        assert.is_true(rec.wait_reply())
        assert.is_nil(rec.err, vim.inspect(rec.err))
        assert.equals("accepted", rec.reply.outcome, vim.inspect(rec.reply))
        assert.is_true(rec.wait_done())
        return rec.done()
    end
    return rec
end

describe("Build/1 editor scopes in the daemon's build service (§19.15)", function()
    local root, srv
    local function start(opts)
        root = workspace(opts)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end
    local function built()
        local b = call(srv, "build", { profile = { key = "dev" } })
        assert.equals(0, b.finish().exit_code, b.lines())
        b.conn:close()
    end
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("configure runs every unit's configure, also an already configured one, and no build", function()
        start()
        built()
        assert.equals("built", cached_state(root, "app"))
        local r = call(srv, "configure", { profile = { key = "dev" }, command = "lw build" })
        local done = r.finish()
        assert.equals(0, done.exit_code, r.lines())
        assert.equals("dev", r.reply.profile_key)
        local meta = r.start().meta
        assert.equals("configure", meta.kind)
        assert.equals("configure", meta.method)
        assert.equals("dev", meta.profile)
        assert.equals(2, #meta.units)
        -- The profile and its units by id too (API.md §4.2; step 5o C2d).
        local ids, prof = srv.service.ids, srv.service.ws._profiles[1]
        assert.equals(ids:id(prof), meta.profile_id)
        for i, pp in ipairs(prof:projects()) do
            assert.same({ project = pp:project_key(), configuration = pp:config_key(),
                id = ids:id(pp._config_unit) }, meta.units[i])
        end
        assert.is_true(r.ordered({ "out:configuring profile: dev", "out:==> [configure] app",
            "out:==> [configure] lib", "out:CONFIGURE OK: dev" }), r.lines())
        assert.is_nil(r.lines():find("[build]", 1, true), r.lines())
        assert.truthy(r.output():find("step configure", 1, true), r.output())
        assert.is_nil(r.output():find("step build", 1, true), r.output())
        -- The configure recorded as in-process (Workspace:record_task_result,
        -- the editor's own path): a successful configure keeps a built unit built.
        assert.equals("built", cached_state(root, "app"))
        assert.equals("built", cached_state(root, "lib"))
        assert.same({ exit_code = 0 }, done.result)
        r.conn:close()
    end)

    it("configure takes the build-directory locks with operation configure, and cancels as a build", function()
        start()
        local pidfile = H.tmp() .. "/pid"
        local r = call(srv, "configure", { profile = { key = "dev" } },
            { env = { LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "configure", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.is_true(vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20), r.lines())
        local bd = srv.service.ws._profiles[1]:projects()[1]:build_dir()
        local info = build_lock.read(bd)
        assert.truthy(info)
        assert.equals("configure", info.operation)
        local res, err = client.call_sync(r.conn, "/tasks", "loomworks.Tasks", 1, "cancel",
            { task_id = r.reply.task_id })
        assert.is_nil(err, vim.inspect(err))
        assert.equals("ok", res.outcome)
        assert.is_true(r.wait_done())
        -- (A cancel ends the task as the CLI's interrupted build: 130.)
        assert.equals(130, r.done().exit_code)
        assert.matches("^configure stopped: ", r.done().error)
        assert.is_true(vim.wait(10000, function() return build_lock.read(bd) == nil end, 20))
        r.conn:close()
    end)

    it("builds configuration units named by key: only those, meta.profile absent, lines naming the units", function()
        start()
        local r = call(srv, "build", { units = { { project = "app", configuration = "Debug" } } })
        local done = r.finish()
        assert.equals(0, done.exit_code, r.lines())
        assert.is_nil(r.reply.profile_key)
        local meta = r.start().meta
        assert.equals("build", meta.kind)
        assert.is_nil(meta.profile)
        assert.is_nil(meta.profile_id)
        assert.equals("app/Debug", meta.name)
        assert.equals(1, #meta.units)
        assert.equals("app", meta.units[1].project)
        assert.equals("Debug", meta.units[1].configuration)
        -- (Its id: the unit's, as a view's unit_id names it; step 5o C2d.)
        local app_unit
        for _, u in pairs(srv.service.ws._config_units) do
            if u._project and u._project.key == "app" and u:config_key() == "Debug" then app_unit = u end
        end
        assert.equals(srv.service.ids:id(app_unit), meta.units[1].id)
        assert.is_true(r.ordered({ "out:building app/Debug", "out:==> [configure] app", "out:==> [build] app",
            "out:BUILD OK: app/Debug" }), r.lines())
        assert.is_nil(r.lines():find("lib", 1, true), r.lines())
        assert.equals("built", cached_state(root, "app"))
        assert.is_nil(cached_state(root, "lib"))
        r.conn:close()
    end)

    it("names units by id from the snapshot index; configures and cleans units", function()
        start()
        built()
        local conn = assert(client.session(srv.address, {}))
        local snap = assert(client.call_sync(conn, "/internal", "lw.internal.Snapshot", 1, "get",
            { scope = "config" }, { env = envscope.capture() }))
        local lib_id
        for _, u in ipairs(snap.index.config_units) do
            if u.project == "lib" and u.configuration == "Debug" then lib_id = u.id end
        end
        assert.is_string(lib_id)
        conn:close()
        local r = call(srv, "configure", { units = { { id = lib_id } } })
        assert.equals(0, r.finish().exit_code, r.lines())
        assert.is_true(r.ordered({ "out:configuring lib/Debug", "out:==> [configure] lib",
            "out:CONFIGURE OK: lib/Debug" }), r.lines())
        assert.equals("built", cached_state(root, "lib"))
        r.conn:close()
        -- A units clean: app's module clean only; lib's directory untouched.
        vim.fn.mkdir(root .. "/out/app/Debug", "p")
        vim.fn.mkdir(root .. "/out/lib/Debug", "p")
        r = call(srv, "clean", { units = { { project = "app", configuration = "Debug" } } })
        assert.equals(0, r.finish().exit_code, r.lines())
        assert.equals("clean", r.start().meta.kind)
        assert.is_true(r.ordered({ "out:cleaning app/Debug", "out:==> [clean] app", "out:CLEAN OK: app/Debug" }),
            r.lines())
        assert.is_nil(r.lines():find("lib", 1, true), r.lines())
        assert.equals("configured", cached_state(root, "app"))
        assert.is_true(exists(root .. "/out/lib/Debug"))
        r.conn:close()
    end)

    it("jobs reaches the build step as the editor's parallel-jobs option", function()
        start()
        local r = call(srv, "build", { profile = { key = "dev" }, jobs = 1 })
        assert.equals(0, r.finish().exit_code, r.lines())
        assert.truthy(r.output():find("step build[^\n]*ARGS=[^\n]*%-j1"), r.output())
        assert.is_nil(r.output():find("step configure[^\n]*%-j1"), r.output())
        r.conn:close()
    end)

    it("a { project, target } operand is resolved to that project; one the scope does not build is refused", function()
        start()
        -- A shell project's module takes no targets: the qualified operand
        -- reached app's build step (lib was not selected).
        local r = call(srv, "build", { profile = { key = "dev" }, targets = { { project = "app", target = "x" } } })
        local done = r.finish()
        assert.equals(1, done.exit_code)
        assert.matches("^app[^\n]*: this project's module does not support %-%-target", done.error)
        r.conn:close()
        r = call(srv, "build", { profile = { key = "dev" }, targets = { { project = "nope", target = "x" } } })
        done = r.finish()
        assert.equals(1, done.exit_code)
        assert.equals("target 'x' names project 'nope', which profile 'dev' does not build", done.error)
        r.conn:close()
    end)

    it("units with profile, empty units and a bad jobs are invalid_args; an unknown unit is refused", function()
        start()
        local r = call(srv, "build", { profile = { key = "dev" }, units = { { project = "app", configuration = "Debug" } } })
        assert.is_true(r.wait_reply())
        assert.equals("invalid_args", r.err and r.err.code, vim.inspect(r))
        r.conn:close()
        -- A profile by id is a profile too: one scope.
        r = call(srv, "build", { profile = { id = "1" }, units = { { project = "app", configuration = "Debug" } } })
        assert.is_true(r.wait_reply())
        assert.equals("invalid_args", r.err and r.err.code, vim.inspect(r))
        r.conn:close()
        r = call(srv, "configure", { units = {} })
        assert.is_true(r.wait_reply())
        assert.equals("invalid_args", r.err and r.err.code, vim.inspect(r))
        r.conn:close()
        r = call(srv, "build", { profile = { key = "dev" }, jobs = 0 })
        assert.is_true(r.wait_reply())
        assert.equals("invalid_args", r.err and r.err.code, vim.inspect(r))
        r.conn:close()
        r = call(srv, "clean", { units = { { project = "app", configuration = "Release" } } })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("no configuration unit app/Release (unknown project or configuration)", r.reply.message)
        assert.equals(1, r.reply.exit_code)
        r.conn:close()
        r = call(srv, "build", { units = { { id = "1.1" } } })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome, vim.inspect(r.reply))
        assert.matches("stale reference", r.reply.message)
        r.conn:close()
        -- Nothing to clean for units with no build directory on disk.
        r = call(srv, "clean", { units = { { project = "app", configuration = "Debug" } } })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("nothing to clean for app/Debug — no configured build directories.", r.reply.message)
        -- On stdout (API.md §4.1): an ordinary line, not an error.
        assert.equals("out", r.reply.stream)
        r.conn:close()
    end)

    it("the CLI's protocol-10 build takes none of Build/1's new fields (units, jobs, { project, target })", function()
        start()
        for _, args in ipairs({
            { units = { { project = "app", configuration = "Debug" } } },
            { profile = "dev", jobs = 2 },
            { profile = "dev", targets = { { project = "app", target = "x" } } },
        }) do
            local reply
            local conn = client.session(srv.address, {})
            conn:request({ kind = "build", args = args, interactive = false, env = envscope.capture(),
                command = "lw build" }, function(r, e) reply = r or { error = e } end)
            assert.is_true(vim.wait(60000, function() return reply ~= nil end, 10))
            assert.equals("declined", reply.outcome, vim.inspect({ args, reply }))
            assert.equals("malformed request", reply.reason)
            conn:close()
        end
    end)

    it("verbose only where its API defines it (build, clean, test, prepare_run) and only a boolean", function()
        start()
        for _, req in ipairs({
            { kind = "reset", args = { profile = "dev", verbose = true }, command = "lw reset" },
            { kind = "build", args = { profile = "dev", verbose = "yes" }, command = "lw build" },
            { kind = "clean", args = { profile = "dev", verbose = 1 }, command = "lw clean" },
        }) do
            local reply
            local conn = client.session(srv.address, {})
            req.interactive, req.env = false, envscope.capture()
            conn:request(req, function(r, e) reply = r or { error = e } end)
            assert.is_true(vim.wait(60000, function() return reply ~= nil end, 10))
            assert.equals("declined", reply.outcome, vim.inspect({ req.kind, req.args, reply }))
            assert.equals("malformed request", reply.reason)
            conn:close()
        end
        -- (configure: a Build/1 method only, whose params have no `verbose`.)
        local r = call(srv, "configure", { profile = { key = "dev" }, verbose = false })
        assert.is_true(r.wait_reply())
        assert.is_nil(r.reply, vim.inspect(r.reply))
        assert.equals("invalid_args", (r.err or {}).code, vim.inspect(r.err))
        r.conn:close()
    end)

    -- Core state-lifecycle §5.4 "Invalid ProfileProjects": a profile build runs
    -- every valid ProfileProject; an invalid one (a tool compat error) is not
    -- run and fails the task, with its reason, after the others ran.
    it("a profile build runs the valid projects, then fails naming the refused one (§5.4)", function()
        local ProfileProject = require("loomworks.profile").ProfileProject
        local orig = ProfileProject.tool_compat_error
        ProfileProject.tool_compat_error = function(pp)
            if pp._project and pp._project.key == "lib" then return "lib tool is wrong" end
            return orig(pp)
        end
        local ok, e = pcall(function()
            start()
            local r = call(srv, "build", { profile = { key = "dev" } })
            local done = r.finish()
            assert.equals(1, done.exit_code, r.lines())
            assert.truthy(tostring(done.error):find("lib/Debug not run: lib tool is wrong", 1, true),
                tostring(done.error))
            assert.equals("built", cached_state(root, "app"))
            assert.is_nil(cached_state(root, "lib"))
            assert.is_nil(r.lines():find("[build] lib", 1, true), r.lines())
            r.conn:close()
        end)
        ProfileProject.tool_compat_error = orig
        assert.is_true(ok, tostring(e))
    end)

    --- Run `fn` with `lib`'s ProfileProject carrying a tool compat error (§8.4).
    local function with_lib_refused(fn)
        local ProfileProject = require("loomworks.profile").ProfileProject
        local orig = ProfileProject.tool_compat_error
        ProfileProject.tool_compat_error = function(pp)
            if pp._project and pp._project.key == "lib" then return "lib tool is wrong" end
            return orig(pp)
        end
        local ok, e = pcall(fn)
        ProfileProject.tool_compat_error = orig
        assert.is_true(ok, tostring(e))
    end

    it("a profile test runs the valid projects' tests, then fails naming the refused one (§5.4)", function()
        -- Each unit's native batch runner: the STEP script with `test-<project>`.
        local ConfigUnit = require("loomworks.config_unit")
        local orig_units = ConfigUnit.batch_runner_test_units
        local nv = (vim.v.progpath:gsub("\\", "/"))
        ConfigUnit.batch_runner_test_units = function(unit)
            local name = unit._project and unit._project.key or "?"
            return { { run_command_all = function()
                return { cmd = { nv, "--headless", "-u", "NONE", "-l", root .. "/step.lua", "test-" .. name } }
            end } }
        end
        local ok, e = pcall(with_lib_refused, function()
            start()
            local r = call(srv, "run", { profile = { key = "dev" } },
                { object = "/tests", iface = "loomworks.Tests" })
            local done = r.finish()
            assert.equals(1, done.exit_code, r.lines())
            assert.truthy(tostring(done.error):find("lib/Debug not run: lib tool is wrong", 1, true),
                tostring(done.error))
            assert.truthy(r.output():find("step test-app", 1, true), r.output())
            assert.is_nil(r.output():find("step test-lib", 1, true), r.output())
            r.conn:close()
        end)
        ConfigUnit.batch_runner_test_units = orig_units
        assert.is_true(ok, tostring(e))
    end)

    it("a profile clean cleans the valid projects, then fails naming the refused one (§5.4)", function()
        start()
        built()
        vim.fn.mkdir(root .. "/out/app/Debug", "p")
        vim.fn.mkdir(root .. "/out/lib/Debug", "p")
        with_lib_refused(function()
            local r = call(srv, "clean", { profile = { key = "dev" } })
            local done = r.finish()
            assert.equals(1, done.exit_code, r.lines())
            assert.truthy(tostring(done.error):find("lib/Debug not run: lib tool is wrong", 1, true),
                tostring(done.error))
            assert.truthy(r.lines():find("[clean] app", 1, true), r.lines())
            assert.is_nil(r.lines():find("[clean] lib", 1, true), r.lines())
            assert.equals("configured", cached_state(root, "app"))
            assert.equals("built", cached_state(root, "lib"))
            assert.is_true(exists(root .. "/out/lib/Debug"))
            -- The refusals are the clean's only failure: its task result says
            -- so (an editor's rebuild goes on to build).
            local result = done.result or done
            assert.same({ "lib/Debug not run: lib tool is wrong — change the profile's tool to match the configuration" },
                result.not_run)
            r.conn:close()
        end)
    end)

    it("a profile clean with nothing else to clean is a task failing with the refused one as not_run", function()
        start()
        built()
        with_lib_refused(function()
            local r = call(srv, "clean", { profile = { key = "dev" } })
            r.wait_reply()
            assert.equals("accepted", r.reply and r.reply.outcome, vim.inspect(r.reply or r.err))
            local done = r.finish()
            assert.equals(1, done.exit_code, r.lines())
            assert.truthy(tostring(done.error):find("lib/Debug not run: lib tool is wrong", 1, true),
                tostring(done.error))
            assert.equals(1, #((done.result or done).not_run or {}), vim.inspect(done))
            assert.equals("built", cached_state(root, "lib"))
            r.conn:close()
        end)
    end)
    it("a profile clean refuses a configuration the module reported an error for, cleaning the others (§5.4)", function()
        start({ lib_invalid = true })
        local b = call(srv, "build", { profile = { key = "dev" } })
        assert.equals(1, b.finish().exit_code, b.lines())
        b.conn:close()
        assert.equals("built", cached_state(root, "app"))
        vim.fn.mkdir(root .. "/out/app/Debug", "p")
        local r = call(srv, "clean", { profile = { key = "dev" } })
        local done = r.finish()
        assert.equals(1, done.exit_code, r.lines())
        assert.truthy(tostring(done.error):find("lib/Debug not run", 1, true), tostring(done.error))
        assert.truthy(tostring(done.error):find("LW_DBS_UNDECLARED", 1, true), tostring(done.error))
        assert.truthy(r.lines():find("[clean] app", 1, true), r.lines())
        assert.equals("configured", cached_state(root, "app"))
        assert.equals(1, #((done.result or done).not_run or {}), vim.inspect(done))
        r.conn:close()
    end)
end)
