-- `lw reset` in the workspace daemon's build service (spec §19.15 "Reset",
-- §19.19 step 5d): an in-process server with the build service attached (the
-- host is the CLI's own workspace load), a real authenticated client, a real
-- workspace of two `shell` projects (`app`, `lib`). Covers `-y` (the task
-- lists, removes, clears the cache; its write-back's `model_change` precedes
-- `done`), the two-request confirmation (`confirm` takes no lock and changes
-- nothing; the confirmed request prints no listing), a plan changed between
-- listing and confirmation (refused before any side effect), nothing to reset
-- (refused, exit 0, standard output), the exclusive locks (operation
-- `reset`) and a held lock (the in-process refusal naming the holder,
-- nothing removed), a removal that never blocks the endpoint and a
-- cancellation that stops it between entries (cache left `unknown`, locks
-- held until it has), and `--all` (one task without a profile, an orphaned
-- directory removed, every profile with one of its units shown `deleting`
-- by an observer).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local build_lock = require("loomworks.build_lock")
local remote_task = require("loomworks.daemon.remote_task")
local reset_plan = require("loomworks.reset_plan")
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

--- A project's persisted cache state for `config` (default Debug); nil when
--- it has no entry or no state.
local function cached_state(root, project, config)
    local t = read(root .. "/.nvim/loomworks.cache.json")
    if not t then return nil end
    local data = vim.json.decode(t)
    for _, c in pairs(data.build_dirs or {}) do
        if c.project_key == project and c.config_key == (config or "Debug") then return c.state end
    end
    return nil
end

--- `app` and `lib` (configure/build run the STEP script), set + profile
--- `dev` (both Debug); with `shared`, lib also has Release and a profile
--- `rel` (lib=Release).
local function workspace(shared)
    local root = vim.fs.normalize(assert(uv.fs_realpath(H.tmp())))
    for _, d in ipairs({ "app", "lib", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
    local step = root .. "/step.lua"
    write(step, H.STEP)
    local nv = (vim.v.progpath:gsub("\\", "/"))
    local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
    write(root .. "/loomworks.json", vim.json.encode({
        projects = {
            app = { path = "app", shell = { build_dir = "${workspace_root}/out/app/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = { build_dir = "${workspace_root}/out/app/Debug" } } } },
            lib = { path = "lib", shell = { build_dir = "${workspace_root}/out/lib/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = { build_dir = "${workspace_root}/out/lib/Debug" },
                    Release = shared and { build_dir = "${workspace_root}/out/lib/Release" } or nil } } },
        },
        configuration_sets = { dev = { app = "Debug", lib = "Debug" }, rel = shared and { lib = "Release" } or nil },
    }))
    local profiles = { dev = { configuration_set = "dev" } }
    if shared then profiles.rel = { configuration_set = "rel" } end
    write(root .. "/.nvim/loomworks.user.json", trust.sign("user", trust.encode({ _meta = { version = 2 },
        profiles = profiles })))
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
    conn:request({ kind = kind, args = args, interactive = false, env = env, command = "lw " .. kind },
        function(r, e) rec.reply = r or { error = e } end)
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
    return rec
end

describe("lw reset in the daemon's build service (§19.15 Reset)", function()
    local root, srv
    local real_rm = lio.rm_rf_async
    local function start(shared)
        root = workspace(shared)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end
    local function dir(p, c) return root .. "/out/" .. p .. "/" .. (c or "Debug") end
    --- Build dev through the daemon, then give both build dirs content.
    local function built(only_app)
        local b = request(srv, "build", { profile = "dev" })
        assert.is_true(b.wait_done())
        assert.equals(0, b.done().exit_code, b.lines())
        b.conn:close()
        for _, p in ipairs({ "app", "lib" }) do
            vim.fn.mkdir(dir(p) .. "/obj", "p")
            write(dir(p) .. "/obj/a.o", "x")
        end
        if only_app then vim.fn.delete(dir("lib"), "rf") end
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

    it("-y: lists, removes every build directory, clears the cache; model_change precedes done", function()
        start()
        built()
        assert.equals("built", cached_state(root, "app"))
        local seen = {}
        local obs = assert(client.session(srv.address, { client = "editor", role = "observer",
            on_message = function(m) seen[#seen + 1] = m end }))
        local r = request(srv, "reset", { profile = "dev", yes = true })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("dev", r.reply.profile_key)
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        local meta = r.start().meta
        assert.equals("reset", meta.kind)
        assert.equals("dev", meta.profile)
        assert.is_nil(meta.scope)
        assert.equals(2, #meta.units)
        local lines = r.lines()
        local a = lines:find("out:Will remove 2 build directories and reset profile 'dev' to unconfigured:", 1, true)
        local b = lines:find("out:RESET OK: profile 'dev'", 1, true)
        assert.truthy(a and b and a < b, lines)
        assert.is_false(exists(dir("app")))
        assert.is_false(exists(dir("lib")))
        assert.is_nil(cached_state(root, "app"))
        assert.is_nil(cached_state(root, "lib"))
        assert.is_nil(build_lock.read(dir("app")))
        -- The write-back's model_change reached the observer before done.
        local mc, dn
        assert.is_true(vim.wait(10000, function()
            for i, m in ipairs(seen) do
                if m.kind == "model_change" and not mc then mc = i end
                if m.kind == "task" and m.phase == "done" then dn = i end
            end
            return dn ~= nil
        end, 10))
        assert.truthy(mc and mc < dn, vim.inspect(seen))
        r.conn:close()
        obs:close()
    end)

    it("confirm takes no lock and changes nothing; the confirmed request runs without a listing", function()
        start()
        built()
        local r = request(srv, "reset", { profile = "dev" })
        assert.is_true(r.wait_reply())
        assert.equals("confirm", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("dev", r.reply.profile_key)
        assert.equals("Will remove 2 build directories and reset profile 'dev' to unconfigured:", r.reply.lines[1])
        assert.equals(3, #r.reply.lines)
        assert.truthy(type(r.reply.plan) == "string" and r.reply.plan:match("^%x+$"), vim.inspect(r.reply))
        assert.is_nil(r.reply.task_id)
        assert.is_nil(build_lock.read(dir("app")))
        assert.is_true(exists(dir("app")))
        assert.equals("built", cached_state(root, "app"))
        assert.equals(0, #r.events)
        local token = r.reply.plan
        r.conn:close()
        local c = request(srv, "reset", { profile = "dev", yes = true, plan = token })
        assert.is_true(c.wait_reply())
        assert.equals("accepted", c.reply.outcome, vim.inspect(c.reply))
        assert.is_true(c.wait_done())
        assert.equals(0, c.done().exit_code, c.lines())
        assert.is_nil(c.lines():find("Will remove", 1, true), c.lines())
        assert.truthy(c.lines():find("out:RESET OK: profile 'dev'", 1, true), c.lines())
        assert.is_false(exists(dir("app")))
        c.conn:close()
    end)

    it("a plan changed between listing and confirmation is refused before any side effect", function()
        start()
        built(true) -- lib's directory is not on disk
        local r = request(srv, "reset", { profile = "dev" })
        assert.is_true(r.wait_reply())
        assert.equals("confirm", r.reply.outcome)
        assert.equals("Will remove 1 build directory and reset profile 'dev' to unconfigured:", r.reply.lines[1])
        r.conn:close()
        -- Meanwhile lib's directory appears: the removal set differs.
        vim.fn.mkdir(dir("lib"), "p")
        write(dir("lib") .. "/keep", "k")
        local c = request(srv, "reset", { profile = "dev", yes = true, plan = r.reply.plan })
        assert.is_true(c.wait_reply())
        assert.equals("refused", c.reply.outcome, vim.inspect(c.reply))
        assert.equals(reset_plan.CHANGED, c.reply.message)
        assert.equals(1, c.reply.exit_code)
        assert.equals("k", read(dir("lib") .. "/keep"))
        assert.is_true(exists(dir("app") .. "/obj/a.o"))
        assert.equals("built", cached_state(root, "app"))
        assert.is_nil(build_lock.read(dir("app")))
        c.conn:close()
    end)

    it("nothing to reset: refused with the in-process line, exit 0, on standard output", function()
        start()
        local r = request(srv, "reset", { profile = "dev", yes = true })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("nothing to reset for profile 'dev' — no build directories to remove.", r.reply.message)
        assert.equals(0, r.reply.exit_code)
        assert.equals("out", r.reply.stream)
        r.conn:close()
        r = request(srv, "reset", { profile = "nope" })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply.outcome)
        assert.equals("no profile matching 'nope'. Run `lw profile list` to list.", r.reply.message)
        r.conn:close()
        -- `--all` with a profile is never sent (cmd_reset refuses it).
        r = request(srv, "reset", { profile = "dev", all = true })
        assert.is_true(r.wait_reply())
        assert.equals("declined", r.reply.outcome)
        r.conn:close()
    end)

    it("holds every build directory's lock (operation reset); a held lock refuses it, nothing removed", function()
        start()
        built()
        -- A slow build holds dev's locks: the reset is refused naming the daemon.
        local pidfile = H.tmp() .. "/pid"
        local b = request(srv, "build", { profile = "dev", force = true, reconfigure = true },
            { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        local slow = vim.wait(30000, function() return read(pidfile .. ".configure") ~= nil end, 20)
        assert.is_true(slow, vim.inspect(b.reply) .. b.lines())
        -- (The same environment: a different one is declined while a build runs.)
        local r = request(srv, "reset", { profile = "dev", yes = true },
            { env = { LW_TEST_SLEEP = "60000", LW_TEST_PIDFILE = pidfile } })
        assert.is_true(r.wait_done(), vim.inspect(r.reply))
        assert.equals(1, r.done().exit_code)
        assert.truthy(r.done().error:find("in use by the workspace daemon (pid " .. srv.pid, 1, true), r.done().error)
        assert.is_true(exists(dir("lib") .. "/obj/a.o"))
        r.conn:close()
        b.conn:close()
        assert.is_true(vim.wait(15000, function() return not srv.busy end, 20))
        assert.is_true(vim.wait(15000, function() return build_lock.read(dir("app")) == nil end, 20))
        -- While a reset removes, its record says `reset`.
        local pending = {}
        lio.rm_rf_async = function(d, cb, o)
            pending[#pending + 1] = { dir = d, done = cb }
            return require("loomworks.future").create(function() end)
        end
        r = request(srv, "reset", { profile = "dev", yes = true })
        assert.is_true(vim.wait(30000, function() return #pending > 0 end, 10), r.lines())
        for _, p in ipairs({ "app", "lib" }) do
            local rec = build_lock.read(dir(p))
            assert.truthy(rec, p)
            assert.equals("reset", rec.operation, vim.inspect(rec))
        end
        lio.rm_rf_async = real_rm
        for _, p in ipairs(pending) do vim.fn.delete(p.dir, "rf"); p.done(true) end
        assert.is_true(vim.wait(30000, function()
            for _, p in ipairs(pending) do if exists(p.dir) then return false end end
            return r.done() ~= nil
        end, 10))
        -- (A second batch may have started once the first settled.)
        assert.is_true(vim.wait(30000, function() return r.done() ~= nil end, 10))
        r.conn:close()
    end)

    it("the removal never blocks the endpoint; cancelling stops it between entries (reset stopped)", function()
        start()
        built()
        local pending = {}
        lio.rm_rf_async = function(d, cb, o)
            pending[#pending + 1] = { dir = d, stop = o and o.stop, done = cb,
                cache_app = cached_state(root, "app"), cache_lib = cached_state(root, "lib") }
            return require("loomworks.future").create(function() end)
        end
        local seen = {}
        local obs = assert(client.session(srv.address, { client = "editor", role = "observer",
            on_message = function(m) seen[#seen + 1] = m end }))
        local r = request(srv, "reset", { profile = "dev", yes = true })
        assert.is_true(vim.wait(30000, function() return #pending > 0 end, 10), r.lines())
        local first = pending[1]
        assert.is_function(first.stop)
        assert.is_false(first.stop())
        -- The deletion: the cache said `unknown` before the removal.
        local target = (first.dir:gsub("\\", "/")):lower():find("/out/app/", 1, true) and "cache_app" or "cache_lib"
        assert.equals("unknown", first[target])
        -- The endpoint answers while the removal runs.
        local pong
        r.conn:request({ kind = "ping" }, function(x) pong = x end)
        assert.is_true(vim.wait(5000, function() return pong ~= nil end, 10))
        assert.equals("ok", pong.kind)
        assert.truthy(build_lock.read(dir("app")))
        -- The client goes (Ctrl-C): the removal is asked to stop; the locks
        -- are held until it has.
        r.conn:close()
        assert.is_true(vim.wait(5000, function() return first.stop() end, 10))
        assert.truthy(build_lock.read(dir("app")))
        assert.truthy(build_lock.read(dir("lib")))
        for _, p in ipairs(pending) do p.done(false, "stopped", true) end
        local done
        assert.is_true(vim.wait(10000, function()
            for _, m in ipairs(seen) do if m.kind == "task" and m.phase == "done" then done = m; return true end end
            return false
        end, 10))
        assert.equals(130, done.exit_code)
        assert.equals("reset stopped: the client that started it disconnected", done.error)
        assert.is_true(vim.wait(5000, function()
            return build_lock.read(dir("app")) == nil and build_lock.read(dir("lib")) == nil
        end, 10))
        assert.is_true(vim.wait(5000, function() return not srv.busy end, 10))
        -- Stopped after a (possibly) partial removal: never reset, the cache
        -- stays `unknown` (spec §4.7).
        for _, p in ipairs(pending) do
            local proj = (p.dir:gsub("\\", "/")):lower():find("/out/app/", 1, true) and "app" or "lib"
            assert.equals("unknown", cached_state(root, proj), proj)
        end
        obs:close()
    end)

    it("--all: one task without a profile; an orphaned directory removed; an observer shows every profile deleting",
        function()
        start(true)
        built()
        -- An orphaned build directory: cached state no unit references.
        local ws = assert(srv.service.ws)
        local orphan = root .. "/out/orphan"
        vim.fn.mkdir(orphan, "p")
        write(orphan .. "/a.o", "x")
        table.insert(ws._build_dirs, require("loomworks.build_dir").new("out/orphan", orphan, {
            state = "built", project_key = "Gone", config_key = "Gone",
            variant = "Gone", type = "shell", build_dir = orphan,
        }))
        assert.equals(1, #ws:get_orphaned_configs())
        local r = request(srv, "reset", { all = true, yes = true })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.is_nil(r.reply.profile_key)
        assert.is_true(r.wait_done())
        assert.equals(0, r.done().exit_code, r.lines())
        local meta = r.start().meta
        assert.equals("reset", meta.kind)
        assert.equals("all", meta.scope)
        assert.equals("--all", meta.name)
        assert.is_nil(meta.profile)
        assert.truthy(r.lines():find("out:Will remove 3 build directories and reset the whole workspace to unconfigured:",
            1, true), r.lines())
        assert.truthy(r.lines():find("out:RESET OK: the whole workspace", 1, true), r.lines())
        assert.is_false(exists(dir("app")))
        assert.is_false(exists(dir("lib")))
        assert.is_false(exists(orphan))
        -- The observer's resolution (§19.16): no profile; the units among the
        -- workspace's; every profile with one of them has it running.
        local t = remote_task.new(ws, 1, meta, 0)
        assert.is_nil(t.profile)
        assert.equals("all", t.scope)
        assert.equals("reset", t.action)
        t:attach_units()
        local keys = {}
        for _, p in ipairs(t.profiles) do keys[#keys + 1] = p.key end
        table.sort(keys)
        assert.same({ "dev", "rel" }, keys)
        for _, u in ipairs(t:config_units()) do
            assert.equals("deleting", u:state())
            assert.equals("deleting", u:deleting_reason())
            assert.is_nil(u:shown_action())
        end
        for _, p in ipairs(ws._profiles) do assert.equals(1, #p:remote_tasks(), p.key) end
        t:finish(0, nil, nil, 1)
        for _, p in ipairs(ws._profiles) do assert.equals(0, #p:remote_tasks(), p.key) end
        assert.equals("reset in 1s", t:outcome())
        r.conn:close()
    end)
end)
