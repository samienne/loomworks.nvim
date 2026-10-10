-- The workspace runtime's foundations (spec §19.1, §19.2, §19.6, §19.9):
-- runtime-mode resolution, the version identity, the handle file, the runtime
-- lock record, the file-only state that drives the `Runtime` row of
-- `lw status` and `lw daemon status` — which never launch or contact a daemon.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local runtime = require("loomworks.daemon.runtime")
local version = require("loomworks.daemon.version")
local handle = require("loomworks.daemon.handle")
local rlock = require("loomworks.daemon.rlock")
local inspect = require("loomworks.daemon.inspect")
local dpaths = require("loomworks.daemon.paths")
local lock_record = require("loomworks.lock_record")
local H = require("tests.daemon_helpers")
local LH = require("tests.lock_helpers")
local uv = vim.uv or vim.loop

local function env_of(t) return function(n) return t[n] end end

describe("runtime mode (§19.1)", function()
    it("defaults to in-process", function()
        local m, src = runtime.resolve(nil, { getenv = env_of({}) })
        assert.equals("in-process", m)
        assert.equals("default", src)
    end)
    it("takes the setting, LOOMWORKS_RUNTIME wins", function()
        assert.equals("daemon", (runtime.resolve("daemon", { getenv = env_of({}) })))
        local m, src = runtime.resolve("daemon", { getenv = env_of({ LOOMWORKS_RUNTIME = "in-process" }) })
        assert.equals("in-process", m)
        assert.equals("env", src)
    end)
    it("reports and ignores an invalid value at either layer", function()
        local m, _, w = runtime.resolve("auto", { getenv = env_of({ LOOMWORKS_RUNTIME = "fast" }) })
        assert.equals("in-process", m)
        assert.truthy(w:find("LOOMWORKS_RUNTIME=fast", 1, true))
        assert.truthy(w:find("'auto'", 1, true))
        m, _, w = runtime.resolve("daemon", { getenv = env_of({ LOOMWORKS_RUNTIME = "x" }) })
        assert.equals("daemon", m)
        assert.truthy(w)
    end)
    it("the plugin option resolves the same way and is inert", function()
        local lw = require("loomworks")
        local saved, saved_ci = lw._runtime_mode_config, vim.env.CI
        vim.env.CI = nil
        lw._runtime_mode_config = "daemon"
        local mode, source = lw.runtime_mode()
        lw._runtime_mode_config = saved
        vim.env.CI = saved_ci
        assert.equals("daemon", mode)
        assert.equals("setup", source)
    end)
end)

describe("version identity (§19.9)", function()
    it("a source checkout is a dev identity with a fingerprint", function()
        version._set_identity(nil)
        local id = version.identity()
        assert.truthy(id:match("^%d+%.%d+%.%d+.*%+dev%.%x+$"), id)
        assert.is_true(version.is_dev(id))
    end)
    it("matches on protocol, version and schemas (CLI) / protocol and schemas (editor)", function()
        local me = { protocol = version.PROTOCOL, lw_version = version.identity(), schemas = version.schemas() }
        assert.is_true((version.matches(me)))
        local other = vim.deepcopy(me); other.lw_version = "0.0.1"
        local ok, what = version.matches(other)
        assert.is_false(ok); assert.equals("version", what)
        assert.is_true((version.matches(other, { editor = true })))
        other = vim.deepcopy(me); other.protocol = 1
        ok, what = version.matches(other, { editor = true })
        assert.is_false(ok); assert.equals("protocol", what)
        other = vim.deepcopy(me); other.schemas.cache = other.schemas.cache + 1
        assert.equals("schemas", select(2, version.matches(other)))
        assert.is_true(version.peer_schemas_newer(other))
    end)
end)

describe("handle file (§19.6)", function()
    local root
    before_each(function() root = H.workspace() end)

    it("round-trips its fields atomically and reports age", function()
        assert.is_true(handle.write(root, { pid = 4242, host = "H", os = "x", endpoint = "e", protocol = 2,
            lw_version = "0.1.43", schemas = { user = 2, cache = 8 }, session_generation = 7,
            started_at = os.time(), clients = 0, busy = false, idle_since = os.time() }))
        local h = handle.read(root)
        assert.is_true(h.valid)
        assert.equals(4242, h.pid)
        assert.equals("e", h.endpoint)
        assert.is_false(h.stale)
        assert.is_nil(uv.fs_stat(dpaths.handle_path(root) .. ".tmp-" .. uv.os_getpid()))
    end)
    it("a malformed handle is unreadable, never live", function()
        local f = assert(io.open(dpaths.handle_path(root), "w")); f:write("{nope"); f:close()
        local h = handle.read(root)
        assert.is_false(h.valid)
        assert.equals("unreadable", inspect.state(root).kind)
        f = assert(io.open(dpaths.handle_path(root), "w")); f:write('{"pid":"x"}'); f:close()
        assert.is_false(handle.read(root).valid)
    end)
    it("removal takes only the named process's regular file", function()
        handle.write(root, { pid = 11, host = "H", endpoint = "e", protocol = 2, start_time = "win:1" })
        assert.is_false(handle.remove(root, { pid = 12 }))
        assert.is_false(handle.remove(root, { pid = 11, start_time = "win:2" }))
        assert.is_true(handle.remove(root, { pid = 11, start_time = "win:1" }))
        assert.is_nil(handle.read(root))
        vim.fn.mkdir(dpaths.handle_path(root), "p") -- a directory in its place
        assert.is_false(handle.remove(root))
        assert.truthy(uv.fs_stat(dpaths.handle_path(root)))
    end)
end)

describe("runtime lock R (§19.2)", function()
    it("carries the common record plus mode and host version, kind daemon", function()
        local root = H.workspace()
        local saved = lock_record.holder_kind
        lock_record.set_holder_kind("daemon")
        local h = assert(rlock.try_acquire(root))
        lock_record.set_holder_kind(saved)
        local info = rlock.read(root)
        for _, k in ipairs({ "pid", "host", "start_time", "lock_nonce", "kind", "operation", "started_at" }) do
            assert.is_not_nil(info[k], k)
        end
        assert.equals("daemon", info.kind)
        assert.equals("daemon", info.mode)
        assert.equals(version.identity(), info.host_version)
        assert.equals("live", info.state)
        assert.is_true(rlock.still_ours(h))
        -- One runtime per workspace: a second acquisition is refused (live).
        local h2, holder = rlock.try_acquire(root)
        assert.is_nil(h2)
        assert.equals("live", holder.state)
        rlock.release(h)
        assert.is_nil(rlock.read(root))
    end)
end)

describe("Runtime row and lw daemon status (§19.6, §19.11)", function()
    local root, saved_env
    before_each(function()
        root = H.workspace()
        saved_env = vim.env.LOOMWORKS_RUNTIME
    end)
    after_each(function()
        vim.env.LOOMWORKS_RUNTIME = saved_env
        LH.cleanup()
    end)

    it("reads in-process / no daemon when no runtime file exists", function()
        local st = inspect.state(root)
        assert.equals("none", st.kind)
        assert.equals("in-process", inspect.row(st, "in-process"))
        assert.equals("no daemon (starts on the next command)", inspect.row(st, "daemon"))
    end)

    it("reads a live daemon from the lock and handle", function()
        local h = LH.hold(dpaths.lock_path(root), "daemon", "daemon")
        handle.write(root, { pid = h.pid, host = lock_record.this_host(), endpoint = "e", protocol = 2,
            lw_version = version.identity(), clients = 2, busy = false })
        local st = inspect.state(root)
        assert.equals("live", st.kind)
        assert.equals("daemon pid " .. h.pid .. ", 2 clients", inspect.row(st, "daemon", version.identity()))
        handle.write(root, { pid = h.pid, host = lock_record.this_host(), endpoint = "e", protocol = 2,
            lw_version = version.identity(), clients = 0, busy = false, idle_since = os.time() - 720 })
        assert.equals("daemon pid " .. h.pid .. ", idle 12m",
            inspect.row(inspect.state(root), "in-process", version.identity()))
        handle.write(root, { pid = h.pid, host = lock_record.this_host(), endpoint = "e", protocol = 2,
            lw_version = "0.1.43", clients = 0 })
        assert.equals("daemon pid " .. h.pid .. ", v0.1.43 (this lw is v0.1.44 — restarts when idle)",
            inspect.row(inspect.state(root), "daemon", "0.1.44"))
    end)

    it("reports a suspended daemon as not responding, a dead one's handle as stale", function()
        local h = LH.hold(dpaths.lock_path(root), "daemon", "daemon")
        handle.write(root, { pid = h.pid, host = lock_record.this_host(), endpoint = "e", protocol = 2 })
        require("loomworks.proc")._suspend(h.pid)
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        assert.equals("hung", inspect.state(root).kind)
        assert.truthy(inspect.row(inspect.state(root), "daemon"):find("not responding", 1, true))
        require("loomworks.proc").kill_tree(h.pid, h.start)
        local st = inspect.state(root)
        assert.equals("stale", st.kind)
        assert.truthy(inspect.row(st, "daemon"):find("stale daemon handle (pid " .. h.pid, 1, true))
        -- The hint names the self-recovery, not only `lw daemon stop`.
        assert.truthy(inspect.row(st, "daemon"):find("the next workspace command recovers it", 1, true))
    end)

    it("names a daemon on another host and an attached run", function()
        local rec = lock_record.new("daemon", { mode = "daemon" })
        rec.host = "OTHERHOST"
        local f = assert(io.open(dpaths.lock_path(root), "w")); f:write(vim.json.encode(rec)); f:close()
        assert.equals("daemon on OTHERHOST (pid " .. rec.pid .. ")", inspect.row(inspect.state(root), "daemon"))
        rec = lock_record.new("build", { mode = "attached", command = "build" })
        f = assert(io.open(dpaths.lock_path(root), "w")); f:write(vim.json.encode(rec)); f:close()
        assert.equals("attached: lw build (pid " .. rec.pid .. ")", inspect.row(inspect.state(root), "daemon"))
    end)

    it("lw status shows the row in daemon mode without starting anything", function()
        local env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
        local r = H.lw({ "status" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("Runtime%s+no daemon %(starts on the next command%)"), r.stdout)
        assert.is_nil(uv.fs_stat(dpaths.lock_path(root)))
        assert.is_nil(uv.fs_stat(dpaths.handle_path(root)))
        assert.is_nil(uv.fs_stat(env.data .. "/daemon"))
        r = H.lw({ "status" }, { env = H.env(), cwd = root })
        assert.truthy(r.stdout:find("Runtime%s+in%-process"), r.stdout)
    end)

    it("lw daemon status reports the mode and the daemon, never starting one", function()
        local env = H.env()
        H.settings(env, { ["runtime-mode"] = "daemon" })
        local r = H.lw({ "daemon", "status" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("Runtime mode   daemon (setting runtime-mode)", 1, true), r.stdout)
        assert.truthy(r.stdout:find("not running (starts on the next command)", 1, true), r.stdout)
        assert.is_nil(uv.fs_stat(dpaths.lock_path(root)))
        r = H.lw({ "daemon" }, { env = H.env(), cwd = H.tmp() })
        assert.equals(0, r.code)
        assert.truthy(r.stdout:find("no loomworks workspace here", 1, true))
        r = H.lw({ "daemon", "frobnicate" }, { env = H.env(), cwd = root })
        assert.equals(2, r.code)
    end)

    it("lw settings validates runtime-mode", function()
        local env = H.env()
        local r = H.lw({ "settings", "set", "runtime-mode", "auto" }, { env = env, cwd = root })
        assert.equals(1, r.code)
        assert.truthy(r.stderr:find("invalid runtime-mode", 1, true))
        r = H.lw({ "settings", "set", "runtime-mode", "daemon" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        r = H.lw({ "settings", "get", "runtime-mode" }, { env = env, cwd = root })
        assert.truthy(r.stdout:find("daemon", 1, true))
    end)

    it("has a help topic", function()
        assert.is_true(cli.has_help_topic("daemon"))
    end)
end)

describe("test isolation", function()
    it("the suite never uses the real per-user data or settings directories", function()
        local base = assert(os.getenv("LOOMWORKS_TEST_STATE_ROOT"), "minimal_init did not isolate the run")
        local data = require("loomworks.trust").data_dir()
        assert.equals(base .. "/data", data)
        assert.equals(1, vim.fn.stridx(dpaths.state_dir(), base) + 1)
        local cfg = H.is_win and os.getenv("APPDATA") or os.getenv("XDG_CONFIG_HOME")
        assert.equals(base .. "/config", cfg)
        -- The machine-level tool cache (spec §16.43) is the run's own too.
        local tc_dir = require("loomworks.tool_cache").dir()
        assert.equals(1, vim.fn.stridx(tc_dir, base .. "/cache/") + 1, tc_dir)
    end)
end)
