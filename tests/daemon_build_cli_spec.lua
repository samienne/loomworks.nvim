-- `lw build` routed through the workspace daemon, with real processes (spec
-- §19.15, §19.17, §19.19 step 3): the parity of every build form against the
-- in-process path (same output, exit codes and persisted cache), the
-- delegation notice and when it is absent (every case that stays
-- in-process), the requesting client's environment, an interrupted client,
-- a daemon stopped mid-build, the build locks against an in-process build,
-- and a working copy the machine refuses. No process is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local proc = require("loomworks.proc")
local trust = require("loomworks.trust")
local build_lock = require("loomworks.build_lock")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local NOTICE = "lw: building through the workspace daemon (pid "

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

--- `s` with every spelling of `root` replaced: as the test names it and as
--- lw stores it (its real path: a runner's temp dir can be an 8.3 short
--- path; case-insensitive on Windows).
local function unroot(s, root)
    local forms = { root, ((uv.fs_realpath(root) or root):gsub("\\", "/")) }
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

--- The workspace's persisted build state, comparable across two roots:
--- verified, decoded, the root replaced, timestamps and the config hash masked.
local function cache_of(root, key_path)
    local text = read(root .. "/.nvim/loomworks.cache.json")
    if not text then return nil end
    trust._set_key_path(key_path)
    local status, body = trust.verify("cache", text)
    trust._set_key_path(nil)
    assert.equals("valid", status)
    local t = vim.json.decode(body)
    local function walk(v, k)
        if type(v) == "string" then
            if type(k) == "string" and (k:match("_at$") or k:match("^last_")) then return "<time>" end
            -- A hash of loomworks.json, whose step commands name the root.
            if k == "loomworks_hash" then return "<hash>" end
            v = unroot(v, root)
            return v
        end
        if type(v) ~= "table" then return v end
        local out = {}
        for kk, vv in pairs(v) do out[kk] = walk(vv, kk) end
        return out
    end
    return walk(t)
end

local function norm(s, root) return unroot((s:gsub("\r\n", "\n")), root) end

local function drop_notice(s)
    return (s:gsub("lw: building through the workspace daemon %(pid %d+%)\n", ""))
end

describe("lw build through the workspace daemon (real processes)", function()
    local env
    local roots = {}
    local function workspace()
        local root = H.shell_workspace()
        roots[#roots + 1] = root
        -- The profile, created by lw itself (a working copy signed with this
        -- environment's machine key).
        local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        return root
    end
    local function lw(root, args, extra)
        local e = env
        if extra then
            e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
            for k, v in pairs(extra) do e.vars[k] = v or nil end
        end
        return H.lw(args, { env = e, cwd = root })
    end
    before_each(function()
        env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    it("every build form: the same output, exit code and persisted cache as in-process (§19.17)", function()
        local a, b = workspace(), workspace()
        local cases = {
            { { "build", "dev" } },
            { { "build", "dev", "-v" } },
            { { "build", "dev", "--", "x1", "x2" } },
            { { "build", "dev", "--reconfigure" } },
            { { "build", "dev", "--force" } },
            { { "build", "dev", "--target", "app" } },
            { { "build", "zzz" } },
            { { "build" } },
            { { "build", "9" } },
            { { "build", "1" } },
            { { "build", "dev" }, { LW_TEST_FAIL = "build" } },
            { { "build", "dev" }, { LW_TEST_KILL = "build:sigkill" } },
            { { "build", "dev" }, { LW_TEST_FOO = "bar" } },
        }
        for _, c in ipairs(cases) do
            local args = { "--no-input" }
            vim.list_extend(args, c[1])
            local ra = lw(a, { "--no-daemon", unpack(args) }, c[2])
            local rb = lw(b, args, c[2])
            local what = table.concat(c[1], " ")
            assert.equals(ra.code, rb.code, what .. "\n" .. rb.stderr)
            assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), what)
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), what)
            -- Routed: exactly when the arguments resolve to a build.
            local routed = rb.stderr:find(NOTICE, 1, true) ~= nil
            assert.is_true(ra.stderr:find(NOTICE, 1, true) == nil, what)
            local refused_early = c[1][2] == "zzz" or c[1][2] == "9" or c[1][2] == nil
            assert.equals(not refused_early, routed, what .. "\n" .. rb.stderr)
            assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), what)
        end
    end)

    it("prints the notice only when the build is routed; every other case runs in-process", function()
        local root = workspace()
        local r = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find(NOTICE, 1, true) == 1, r.stderr)
        assert.truthy(r.stdout:find("BUILD OK: dev", 1, true))
        for _, case in ipairs({
            { { "--no-daemon" } },
            { {}, { LOOMWORKS_NO_DAEMON = "1" } },
            { {}, { CI = "true" } },
            { {}, { LOOMWORKS_RUNTIME = "in-process" } },
            { { "--break-locks" } },
        }) do
            local args = { "--no-input", "build", "dev" }
            vim.list_extend(args, case[1])
            local x = lw(root, args, case[2])
            assert.equals(0, x.code, x.stderr)
            assert.is_nil(x.stderr:find("building through the workspace daemon", 1, true), vim.inspect(case))
            assert.truthy(x.stdout:find("BUILD OK: dev", 1, true))
        end
    end)

    it("the build runs in the client's environment, not the daemon's", function()
        local root = workspace()
        -- The daemon is started from an environment the build must not see.
        local r = lw(root, { "daemon", "restart" }, { LW_TEST_ONLY = "daemon-env", LW_TEST_FOO = false })
        assert.equals(0, r.code, r.stderr)
        H.track_root(root)
        r = lw(root, { "--no-input", "build", "dev" }, { LW_TEST_FOO = "client-env", LW_TEST_ONLY = false })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find(NOTICE, 1, true), r.stderr)
        assert.truthy(r.stdout:find("FOO=client-env ONLY=nil", 1, true), r.stdout)
    end)

    it("a step that a signal kills fails the build on both paths, never recorded as built (§16.7)", function()
        -- POSIX: the conventional 128 + signal and the signal named. Windows
        -- has no such signals: libuv emulates the kill with TerminateProcess
        -- (exit code 1), which fails exactly as before.
        local sigs = H.is_win and { { "sigkill", 1, "(exit 1)" } }
            or { { "sigkill", 137, "(killed by signal 9 (SIGKILL))" }, { "sigterm", 143, "(killed by signal 15 (SIGTERM))" } }
        for _, s in ipairs(sigs) do
            for _, routed in ipairs({ false, true }) do
                local root = workspace()
                local args = { "--no-input", "build", "dev" }
                if not routed then table.insert(args, 2, "--no-daemon") end
                local r = lw(root, args, { LW_TEST_KILL = "build:" .. s[1] })
                local what = s[1] .. (routed and " (daemon)" or " (in-process)")
                if routed then H.track_root(root) end
                assert.equals(s[2], r.code, what .. "\n" .. r.stderr)
                assert.truthy(r.stderr:find("lw: build failed " .. s[3] .. ": app: build Debug", 1, true),
                    what .. "\n" .. r.stderr)
                assert.equals(routed, r.stderr:find(NOTICE, 1, true) ~= nil, what .. "\n" .. r.stderr)
                assert.is_nil(r.stdout:find("BUILD OK", 1, true), what)
                local cache = cache_of(root, env.data .. "/trust.key")
                assert.is_nil(vim.inspect(cache):find('"built"', 1, true), what .. "\n" .. vim.inspect(cache))
            end
        end
    end)

    it("an interrupted client cancels the build: step killed, lock released, next build OK", function()
        local root = workspace()
        local pidfile = H.tmp() .. "/pid"
        local e = vim.deepcopy(env)
        e.vars.LW_TEST_SLEEP, e.vars.LW_TEST_PIDFILE = "60000", pidfile
        local c = H.lw_start({ "--no-input", "build", "dev" }, { env = e, cwd = root })
        local ok = vim.wait(60000, function() return read(pidfile .. ".configure") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        H.track_root(root)
        local spid = tonumber(read(pidfile .. ".configure"))
        local sst = proc.start_time(spid)
        H.track(spid, sst)
        assert.truthy(c.stderr():find(NOTICE, 1, true), c.stderr())
        -- Ctrl-C (SIGINT) on POSIX; on Windows the console interrupt cannot be
        -- sent to one process, so the client is terminated: both drop the
        -- connection, which cancels the build.
        c.kill(H.is_win and "sigkill" or "sigint")
        assert.is_true(c.wait(30000))
        assert.is_true(c.code ~= 0)
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        local bd = root .. "/.nvim/build/app/Debug"
        assert.is_true(vim.wait(10000, function() return build_lock.read(bd) == nil end, 20))
        local r = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("BUILD OK: dev", 1, true))
    end)

    it("a daemon stopped mid-build ends the build nonzero; the client never re-runs it", function()
        local root = workspace()
        local pidfile = H.tmp() .. "/pid"
        local e = vim.deepcopy(env)
        e.vars.LW_TEST_SLEEP, e.vars.LW_TEST_PIDFILE = "60000", pidfile
        local c = H.lw_start({ "--no-input", "build", "dev" }, { env = e, cwd = root })
        local ok = vim.wait(60000, function() return read(pidfile .. ".configure") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        H.track_root(root)
        local spid = tonumber(read(pidfile .. ".configure"))
        local sst = proc.start_time(spid)
        H.track(spid, sst)
        local s = lw(root, { "daemon", "stop" })
        assert.equals(0, s.code, s.stderr)
        assert.is_true(c.wait(30000))
        assert.equals(1, c.code)
        assert.truthy(c.stderr():find("build stopped: the workspace daemon stopped", 1, true)
            or c.stderr():find("lost the connection to the workspace daemon", 1, true), c.stderr())
        assert.is_nil(c.stdout():find("BUILD OK", 1, true))
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        assert.is_nil(build_lock.read(root .. "/.nvim/build/app/Debug"))
    end)

    it("a daemon build and an in-process build of one directory: the second refuses naming the holder", function()
        local root = workspace()
        local pidfile = H.tmp() .. "/pid"
        local e = vim.deepcopy(env)
        e.vars.LW_TEST_SLEEP, e.vars.LW_TEST_PIDFILE = "60000", pidfile
        -- In-process first: the daemon build is refused.
        local c = H.lw_start({ "--no-input", "--no-daemon", "build", "dev" }, { env = e, cwd = root })
        local ok = vim.wait(60000, function() return read(pidfile .. ".configure") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        H.track(c.pid, c.start)
        local r = lw(root, { "--no-input", "build", "dev" })
        H.track_root(root)
        assert.equals(1, r.code, r.stderr)
        assert.truthy(r.stderr:find("is in use by lw ", 1, true) and r.stderr:find("(pid " .. c.pid .. ")", 1, true),
            r.stderr)
        c.kill(); c.wait(10000)
        local spid = tonumber(read(pidfile .. ".configure"))
        local sst = proc.start_time(spid)
        if sst then H.track(spid, sst); proc.kill_tree(spid, sst) end
        os.remove(pidfile .. ".configure")
        vim.wait(10000, function() return build_lock.read(root .. "/.nvim/build/app/Debug") == nil
            or (build_lock.read(root .. "/.nvim/build/app/Debug") or {}).state == "dead" end, 20)
        -- The daemon first: the in-process build is refused.
        c = H.lw_start({ "--no-input", "build", "dev" }, { env = e, cwd = root })
        ok = vim.wait(60000, function() return read(pidfile .. ".configure") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        local d = require("loomworks.daemon.rlock").read(root)
        r = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(1, r.code, r.stderr)
        assert.truthy(r.stderr:find("is in use by the workspace daemon (pid " .. d.pid, 1, true), r.stderr)
        c.kill(); c.wait(10000)
    end)

    it("a working copy this machine refuses is not routed: the same refusal as in-process", function()
        local root = workspace()
        local r = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, r.code, r.stderr)
        local path = root .. "/.nvim/loomworks.user.json"
        local text = read(path)
        local f = io.open(path, "wb"); f:write((text:gsub('"dev"', '"dev" ', 1))); f:close()
        local routed = lw(root, { "--no-input", "build", "dev" })
        local inproc = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(inproc.code, routed.code)
        assert.is_true(routed.code ~= 0)
        assert.equals(norm(inproc.stderr, root), norm(routed.stderr, root))
        assert.truthy(routed.stderr:find("lw trust", 1, true), routed.stderr)
        assert.is_nil(routed.stderr:find("building through the workspace daemon", 1, true))
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
