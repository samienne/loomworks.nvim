-- The CLI's attached runs in `runtime-mode daemon` (spec §19.1 "Loopback
-- during the transition", §19.2, §19.19 step 5e), with real processes: an
-- attached selection (`--no-daemon`, CI) runs the routed operations through
-- the daemon's own server and service inside the lw process — the same exit
-- code, output and cache as in-process, no "through the workspace daemon"
-- line, the runtime lock released afterwards; a second attached run waits
-- `runtime-busy-wait`, then fails "workspace busy"; a live daemon is used as
-- a shared client; a reset's two requests share one attached runtime; an
-- attached `lw run` releases the lock before its program runs.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local DAEMON_WORDS = "through the workspace daemon"
local NV = (vim.v.progpath:gsub("\\", "/"))

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- `s` with every spelling of `root` replaced.
local function unroot(s, root)
    local forms = { root, ((uv.fs_realpath(root) or root):gsub("\\", "/")),
        (root:gsub("/", "\\")), ((uv.fs_realpath(root) or root):gsub("/", "\\")) }
    for _, r in ipairs(forms) do
        if H.is_win then
            local i = s:lower():find(r:lower(), 1, true)
            while i do
                s = s:sub(1, i - 1) .. "<ROOT>" .. s:sub(i + #r)
                i = s:lower():find(r:lower(), 1, true)
            end
        else
            s = s:gsub(vim.pesc(r), "<ROOT>")
        end
    end
    return s
end
local function norm(s, root) return unroot((s:gsub("\r\n", "\n")), root) end

--- The persisted build state, comparable across roots.
local function cache_of(root, key_path)
    local text = read(root .. "/.nvim/loomworks.cache.json")
    if not text then return nil end
    trust._set_key_path(key_path)
    local status, body = trust.verify("cache", text)
    trust._set_key_path(nil)
    assert.equals("valid", status)
    local function walk(v, k)
        if type(k) == "string" and (k:match("_at$") or k:match("^last_") or k:match("mtime")) then return "<time>" end
        if type(v) == "string" then
            if k == "loomworks_hash" then return "<hash>" end
            return unroot(v, root)
        end
        if type(v) ~= "table" then return v end
        local out = {}
        for kk, vv in pairs(v) do out[type(kk) == "string" and unroot(kk, root) or kk] = walk(vv, kk) end
        return out
    end
    return walk(vim.json.decode(body))
end

local function lock_path(root) return root .. "/.nvim/loomworks.daemon.lock" end
local function count(s, pat) local _, n = s:gsub(vim.pesc(pat), ""); return n end

--- The program of `lw run go`: prints whether the runtime lock exists.
local PROG = [[
local root = arg[1]
local held = vim.uv.fs_stat(root .. "/.nvim/loomworks.daemon.lock") ~= nil
io.write("prog LOCK=" .. (held and "held" or "free") .. string.char(10))
]]

describe("lw attached runs in runtime-mode daemon (real processes)", function()
    local env
    local roots = {}
    --- A shell workspace with the profile `dev` and a launch `go` (the
    --- program above), written to the working copy signed with this
    --- environment's key.
    local function workspace()
        local root = H.shell_workspace()
        roots[#roots + 1] = root
        write(root .. "/prog.lua", PROG)
        local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", "dev" },
            { env = { vars = vim.tbl_extend("force", env.vars, { LOOMWORKS_RUNTIME = "in-process" }),
                data = env.data, config = env.config }, cwd = root })
        assert.equals(0, r.code, r.stderr)
        local upath = root .. "/.nvim/loomworks.user.json"
        trust._set_key_path(env.data .. "/trust.key")
        local status, body = trust.verify("user", read(upath))
        assert.equals("valid", status)
        local user = vim.json.decode(body)
        local cfg = vim.json.decode(read(root .. "/loomworks.json"))
        local app = cfg.projects.app
        app.launch = { go = { command = NV, args = { "--headless", "-u", "NONE", "-l", "${workspace_root}/prog.lua",
            "${workspace_root}" } } }
        user.projects = user.projects or {}
        user.projects.app = app
        local signed, serr = trust.sign("user", trust.encode(user))
        trust._set_key_path(nil)
        if not signed then error(serr) end
        write(upath, signed)
        return root
    end
    local function with_vars(extra)
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        for k, v in pairs(extra or {}) do e.vars[k] = v or nil end
        return e
    end
    local function lw(root, args, extra, stdin)
        return H.lw(args, { env = with_vars(extra), cwd = root, stdin = stdin })
    end
    local function rlog(root) return read(root .. "/.nvim/loomworks.daemon.log") or "" end
    before_each(function()
        env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    it("an attached build (--no-daemon, CI): the same exit code, output and cache as in-process; R released", function()
        local a, b, c = workspace(), workspace(), workspace()
        local cases = {
            { { "build", "dev" } },
            { { "build", "dev", "-v" } },
            { { "build", "dev", "--target", "app" } },
            { { "build", "zzz" } },
            { { "build", "dev" }, { LW_TEST_FAIL = "build" } },
            { { "build", "dev", "--break-locks" } },
        }
        for _, k in ipairs(cases) do
            local what = table.concat(k[1], " ")
            local args = { "--no-input", unpack(k[1]) }
            local ra = lw(a, args, vim.tbl_extend("force", k[2] or {}, { LOOMWORKS_RUNTIME = "in-process" }))
            local rb = lw(b, { "--no-daemon", unpack(args) }, k[2])
            local rc = lw(c, args, vim.tbl_extend("force", k[2] or {}, { CI = "true" }))
            for _, x in ipairs({ { rb, b }, { rc, c } }) do
                local r, root = x[1], x[2]
                assert.equals(ra.code, r.code, what .. "\n" .. r.stderr)
                assert.equals(norm(ra.stdout, a), norm(r.stdout, root), what)
                assert.equals(norm(ra.stderr, a), norm(r.stderr, root), what)
                assert.is_nil(r.stderr:find(DAEMON_WORDS, 1, true), what)
                assert.is_nil(r.stderr:find("running without it", 1, true), what)
                assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(root, env.data .. "/trust.key"), what)
                -- R released, and no daemon was launched.
                assert.is_nil(uv.fs_stat(lock_path(root)), what)
                assert.is_nil(uv.fs_stat(root .. "/.nvim/loomworks.daemon.json"), what)
            end
        end
        -- Ran attached (the daemon's code in the lw process), not in-process.
        assert.truthy(rlog(b):find("attached run of build", 1, true), rlog(b))
        assert.truthy(rlog(c):find("attached run of build", 1, true), rlog(c))
        assert.equals("", rlog(a))
    end)

    it("a second attached run waits runtime-busy-wait, then fails 'workspace busy' (exit 1)", function()
        local root = workspace()
        H.settings(env, { ["runtime-busy-wait"] = "300ms" })
        local first = H.lw_start({ "--no-input", "--no-daemon", "build", "dev" },
            { env = with_vars({ LW_TEST_SLEEP = "4000", LW_TEST_SLEEP_STEP = "build" }), cwd = root })
        H.track(first.pid, first.start)
        local held = vim.wait(60000, function() return (first.stdout()):find("step build", 1, true) ~= nil end, 20)
        assert.is_true(held, first.stderr())
        assert.truthy(uv.fs_stat(lock_path(root)))
        local t0 = uv.now()
        local r = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(1, r.code, r.stderr)
        assert.truthy(r.stderr:find("lw: workspace busy: lw build (pid " .. first.pid, 1, true), r.stderr)
        assert.truthy(r.stderr:find("is running here without a daemon — retry when it finishes", 1, true), r.stderr)
        assert.truthy(uv.now() - t0 >= 300)
        assert.is_true(first.wait(60000))
        assert.equals(0, first.code, first.stderr())
        assert.is_nil(uv.fs_stat(lock_path(root)))
        -- The next one runs.
        local n = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(0, n.code, n.stderr)
    end)

    it("a live daemon holding R: the attached selection connects to it as a shared client", function()
        local root = workspace()
        local s = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, s.code, s.stderr)
        assert.truthy(s.stderr:find("lw: building " .. DAEMON_WORDS, 1, true), s.stderr)
        local r = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find("lw: building " .. DAEMON_WORDS, 1, true), r.stderr)
        assert.is_nil(rlog(root):find("attached run of", 1, true))
        H.stop_daemon(root, env)
    end)

    it("an attached reset: the two-request confirmation in ONE attached runtime", function()
        local a, b = workspace(), workspace()
        for _, root in ipairs({ a, b }) do
            local r = lw(root, { "--no-input", "--no-daemon", "build", "dev" }, { LOOMWORKS_RUNTIME = "in-process" })
            assert.equals(0, r.code, r.stderr)
        end
        local ra = lw(a, { "reset", "dev" }, { LOOMWORKS_RUNTIME = "in-process", LW_TEST_INTERACTIVE = "1" }, "y\n")
        local rb = lw(b, { "--no-daemon", "reset", "dev" }, { LW_TEST_INTERACTIVE = "1" }, "y\n")
        assert.equals(0, ra.code, ra.stderr)
        assert.equals(ra.code, rb.code, rb.stderr)
        assert.equals(norm(ra.stdout, a), norm(rb.stdout, b))
        assert.equals(norm(ra.stderr, a), norm(rb.stderr, b))
        assert.is_nil(rb.stderr:find(DAEMON_WORDS, 1, true))
        assert.is_nil(uv.fs_stat(b .. "/out/Debug"))
        assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"))
        assert.equals(1, count(rlog(b), "attached run of reset"), rlog(b))
        assert.is_nil(uv.fs_stat(lock_path(b)))
    end)

    it("an attached lw run releases R before the program runs", function()
        local a, b = workspace(), workspace()
        local ra = lw(a, { "--no-input", "run", "dev", "go" }, { LOOMWORKS_RUNTIME = "in-process" })
        local rb = lw(b, { "--no-input", "--no-daemon", "run", "dev", "go" })
        assert.equals(0, ra.code, ra.stderr)
        assert.equals(0, rb.code, rb.stderr)
        assert.truthy(rb.stdout:find("prog LOCK=free", 1, true), rb.stdout .. rb.stderr)
        assert.equals(norm(ra.stdout, a), norm(rb.stdout, b))
        assert.equals(norm(ra.stderr, a), norm(rb.stderr, b))
        assert.is_nil(rb.stderr:find(DAEMON_WORDS, 1, true))
        assert.truthy(rlog(b):find("attached run of run", 1, true), rlog(b))
        assert.is_nil(uv.fs_stat(lock_path(b)))
    end)

    it("an attached selection meets a live daemon with the version handshake (§19.2, §19.9)", function()
        local cli = require("loomworks.cli")
        local server_mod = require("loomworks.daemon.server")
        local inspect = require("loomworks.daemon.inspect")
        local root = H.tmp()
        local saved = { state = inspect.state, trusted = cli._daemon_workspace_trusted, delegate = cli._delegate }
        inspect.state = function() return { kind = "live", handle = {}, lock = { pid = 1 } } end
        cli._daemon_workspace_trusted = function() return true end
        local delegated
        cli._delegate = function(_, _, _, ensured) delegated = ensured; return 0 end
        local ok, err = pcall(function()
            local function held() return nil, "held", server_mod.EXIT_HELD end
            local function attached(meet, start)
                return cli._delegate_attached("build", root, { "build", "dev" }, { start = start or held, meet = meet })
            end
            -- The same version: a shared client of it.
            assert.equals(0, attached(function() return "used" end))
            assert.equals("used", delegated)
            -- A busy daemon of another version (bypass), a newer one, one not
            -- reachable: its line printed, the command runs without it.
            for _, m in ipairs({ "bypass", "newer", "failed" }) do
                delegated = nil
                assert.is_nil(attached(function() return m end), m)
                assert.is_nil(delegated, m)
            end
            -- An idle daemon of another version, stopped (nothing launched):
            -- the attached start is retried at once, without the busy wait.
            local starts, met = 0, 0
            local t0 = uv.now()
            assert.is_nil(attached(function() met = met + 1; return "stopped" end, function()
                starts = starts + 1
                if starts == 1 then return held() end
                return nil, "gone", 2
            end))
            assert.equals(2, starts)
            assert.equals(1, met)
            assert.is_true(uv.now() - t0 < 1000)
        end)
        inspect.state, cli._daemon_workspace_trusted, cli._delegate = saved.state, saved.trusted, saved.delegate
        assert(ok, err)
    end)

    it("a shared selection finding an attached runtime waits runtime-busy-wait, then 'workspace busy' (§19.2)", function()
        local root = workspace()
        H.settings(env, { ["runtime-busy-wait"] = "300ms" })
        local first = H.lw_start({ "--no-input", "--no-daemon", "build", "dev" },
            { env = with_vars({ LW_TEST_SLEEP = "4000", LW_TEST_SLEEP_STEP = "build" }), cwd = root })
        H.track(first.pid, first.start)
        local held = vim.wait(60000, function() return (first.stdout()):find("step build", 1, true) ~= nil end, 20)
        assert.is_true(held, first.stderr())
        local t0 = uv.now()
        local r = lw(root, { "--no-input", "build", "dev" })
        assert.equals(1, r.code, r.stderr)
        assert.truthy(r.stderr:find("lw: workspace busy: lw build (pid " .. first.pid, 1, true), r.stderr)
        assert.truthy(r.stderr:find("is running here without a daemon", 1, true), r.stderr)
        assert.is_nil(r.stderr:find("running without it", 1, true), r.stderr)
        assert.truthy(uv.now() - t0 >= 300)
        assert.is_true(first.wait(60000))
        assert.equals(0, first.code, first.stderr())
        -- Free again: the shared selection launches the daemon as usual.
        local n = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, n.code, n.stderr)
        assert.truthy(n.stderr:find("lw: building " .. DAEMON_WORDS, 1, true), n.stderr)
        H.stop_daemon(root, env)
    end)

    it("an attached run whose runtime lock is taken over: its step killed, exit 1 (§19.2)", function()
        local root = workspace()
        local pidfile = H.tmp() .. "/pid"
        local first = H.lw_start({ "--no-input", "--no-daemon", "build", "dev" },
            { env = with_vars({ LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "build", LW_TEST_PIDFILE = pidfile }),
                cwd = root })
        H.track(first.pid, first.start)
        local ok = vim.wait(60000, function() return read(pidfile .. ".build") ~= nil end, 20)
        assert.is_true(ok, first.stderr())
        local spid = tonumber(read(pidfile .. ".build"))
        local sst = require("loomworks.proc").start_time(spid)
        H.track(spid, sst)
        assert.is_true(H.alive(spid, sst))
        -- Reclaimed by someone else (its record gone).
        assert.is_true(os.remove(lock_path(root)) ~= nil)
        assert.is_true(first.wait(30000), first.stderr())
        assert.equals(1, first.code, first.stderr())
        assert.truthy(first.stderr():find("lw: the workspace runtime lock was taken over during the build — stopped",
            1, true), first.stderr())
        assert.is_true(vim.wait(10000, function() return not H.alive(spid, sst) end, 50), "step still running")
    end)

    -- The workspace files' modification times (cache, working copy).
    local function mtimes(root)
        local t = {}
        for _, f in ipairs({ "loomworks.cache.json", "loomworks.user.json" }) do
            local st = uv.fs_stat(root .. "/.nvim/" .. f)
            t[f] = st and (st.mtime.sec .. "." .. st.mtime.nsec) or "absent"
        end
        return t
    end

    -- Every path under `dir`, sorted.
    local function tree(dir)
        local t = {}
        for name in vim.fs.dir(dir, { depth = 20 }) do t[#t + 1] = name end
        table.sort(t)
        return t
    end

    it("an attached reset whose runtime lock is replaced at the prompt deletes nothing, exit 1 (§19.2)", function()
        local root = workspace()
        local b = lw(root, { "--no-input", "--no-daemon", "build", "dev" }, { LOOMWORKS_RUNTIME = "in-process" })
        assert.equals(0, b.code, b.stderr)
        local p = H.lw_start({ "--no-daemon", "reset", "dev" },
            { env = with_vars({ LW_TEST_INTERACTIVE = "1" }), cwd = root, stdin = true })
        H.track(p.pid, p.start)
        local asked = vim.wait(60000, function() return (p.stdout()):find("[y/N]", 1, true) ~= nil end, 20)
        assert.is_true(asked, p.stdout() .. p.stderr())
        -- (The reset would remove the build directory, .nvim/build/app/Debug,
        -- and the cache's entries: the tree and the cache's mtime show it.)
        local built = tree(root)
        assert.truthy(vim.tbl_contains(built, ".nvim/build/app/Debug"), table.concat(built, ", "))
        local before = mtimes(root)
        -- Another runtime's record replaces ours while the prompt waits.
        local rec = vim.json.decode(read(lock_path(root)))
        rec.lock_nonce = "replaced-by-another-runtime"
        write(lock_path(root), vim.json.encode(rec))
        p.write("y\n")
        p.close_stdin()
        assert.is_true(p.wait(30000), p.stderr())
        assert.equals(1, p.code, p.stderr())
        assert.truthy(p.stderr():find("lw: the workspace runtime lock was taken over during the reset — stopped",
            1, true), p.stderr())
        assert.same(built, tree(root))
        assert.same(before, mtimes(root))
        os.remove(lock_path(root))
    end)

    it("an attached build whose lock is taken over writes no workspace file afterwards (§19.2)", function()
        local root = workspace()
        local pidfile = H.tmp() .. "/pid"
        local first = H.lw_start({ "--no-input", "--no-daemon", "build", "dev" },
            { env = with_vars({ LW_TEST_SLEEP = "60000", LW_TEST_SLEEP_STEP = "build", LW_TEST_PIDFILE = pidfile }),
                cwd = root })
        H.track(first.pid, first.start)
        assert.is_true(vim.wait(60000, function() return read(pidfile .. ".build") ~= nil end, 20), first.stderr())
        local spid = tonumber(read(pidfile .. ".build"))
        H.track(spid, require("loomworks.proc").start_time(spid))
        -- (Past any write the step's start made.)
        vim.wait(300, function() return false end, 20)
        local before = mtimes(root)
        assert.is_true(os.remove(lock_path(root)) ~= nil)
        assert.is_true(first.wait(30000), first.stderr())
        assert.equals(1, first.code, first.stderr())
        assert.same(before, mtimes(root))
    end)

    it("none is left running", function()
        assert.equals(0, H.leftovers)
    end)
end)
