-- The batch `lw test` routed through the workspace daemon, with real
-- processes (spec §19.15, §19.17, §19.19 step 5): the parity of every form
-- against the in-process path (same output, exit code, JUnit files and
-- persisted cache), the delegation notice and the cases that stay in-process
-- (`--target` with its one line, the explicit opt-outs), and an interrupted
-- client. No process is left running.
--
-- The workspace's projects use a test-only module, `lwtestmod` (the `shell`
-- module plus a native batch test runner), found on the runtime path of the
-- spawned `lw` and of its daemon through $XDG_CONFIG_HOME/nvim.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local build_lock = require("loomworks.build_lock")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local NOTICE = "lw: testing through the workspace daemon (pid "

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- The test runner of `lwtestmod` (run by nvim -l): `<junit path or ""> <unit>
--- [args…]`. Prints the unit, the arguments and LW_TEST_FOO, a line on
--- stderr, writes a JUnit file when asked (unless $LW_TEST_NO_JUNIT), and
--- exits 4 when $LW_TEST_FAIL_UNIT names its unit. Sleeps $LW_TEST_SLEEP ms
--- (writing its pid to $LW_TEST_PIDFILE.test first).
local RUNNER = [[
local junit, unit = arg[1], arg[2]
local pf = os.getenv("LW_TEST_PIDFILE")
if pf then local f = io.open(pf .. ".test", "w"); f:write(tostring(vim.uv.os_getpid())); f:close() end
io.write("tests of " .. unit .. " FOO=" .. tostring(os.getenv("LW_TEST_FOO"))
    .. " ARGS=" .. table.concat(arg, ",", 3) .. string.char(10))
io.stderr:write("runner stderr " .. unit .. string.char(10))
local ms = tonumber(os.getenv("LW_TEST_SLEEP_TEST") or "")
if ms then vim.uv.sleep(ms) end
local fail = os.getenv("LW_TEST_FAIL_UNIT") == unit
if junit ~= "" and not os.getenv("LW_TEST_NO_JUNIT") then
    local f = io.open(junit, "w")
    f:write("<testsuite name='" .. unit .. "' failures='" .. (fail and 1 or 0) .. "'/>")
    f:close()
end
if fail then os.exit(4) end
]]

--- The test-only module: the shell module plus a native batch runner.
local function module_source(runner)
    return ([[
local shell = require("loomworks.modules.shell")
local M = {}
for k, v in pairs(shell) do M[k] = v end
M.id = "lwtestmod"
local TU = {}
TU.__index = TU
function TU:run_command_all(opts)
    opts = opts or {}
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l", %q, opts.junit or "",
        self._config_unit._project.key }
    vim.list_extend(cmd, opts.extra_args or {})
    return { cmd = cmd, junit_out = opts.junit }
end
function TU:run_command_all_rebuilds() return false end
function M.create_test_unit(unit) return setmetatable({ _config_unit = unit }, TU) end
return M
]]):format(runner)
end

--- `s` with every spelling of `root` replaced (see daemon_build_cli_spec).
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

local function norm(s, root) return unroot((s:gsub("\r\n", "\n")), root) end

local function drop_notice(s)
    return (s:gsub("lw: testing through the workspace daemon %(pid %d+%)\n", ""))
end

--- The persisted build state, comparable across two roots.
local function cache_of(root, key_path)
    local text = read(root .. "/.nvim/loomworks.cache.json")
    if not text then return nil end
    trust._set_key_path(key_path)
    local status, body = trust.verify("cache", text)
    trust._set_key_path(nil)
    assert.equals("valid", status)
    local function walk(v, k)
        if type(v) == "string" then
            if type(k) == "string" and (k:match("_at$") or k:match("^last_")) then return "<time>" end
            if k == "loomworks_hash" then return "<hash>" end
            return unroot(v, root)
        end
        if type(v) ~= "table" then return v end
        local out = {}
        for kk, vv in pairs(v) do out[kk] = walk(vv, kk) end
        return out
    end
    return walk(vim.json.decode(body))
end

--- The files of a directory (name → content), or {} when it does not exist.
local function files_of(dir)
    local out = {}
    local h = uv.fs_scandir(dir)
    while h do
        local name = uv.fs_scandir_next(h)
        if not name then break end
        out[name] = read(dir .. "/" .. name)
    end
    return out
end

describe("lw test through the workspace daemon (real processes)", function()
    local env
    local roots = {}

    --- A workspace with two `lwtestmod` projects (app, lib) and a profile
    --- `dev` (app=Debug, lib=Debug), created by lw itself.
    local function workspace()
        local root = H.tmp()
        roots[#roots + 1] = root
        vim.fn.mkdir(root .. "/app", "p")
        vim.fn.mkdir(root .. "/lib", "p")
        vim.fn.mkdir(root .. "/.nvim", "p")
        local step = root .. "/step.lua"
        write(step, H.STEP)
        local nv = (vim.v.progpath:gsub("\\", "/"))
        local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
        local function project(name)
            return { path = name, lwtestmod = {
                build_dir = "${workspace_root}/out/" .. name .. "/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = vim.empty_dict() },
            } }
        end
        write(root .. "/loomworks.json", vim.json.encode({
            projects = { app = project("app"), lib = project("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }))
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
        local nvim_cfg = H.tmp()
        local mods = nvim_cfg .. "/nvim/lua/loomworks/modules"
        vim.fn.mkdir(mods, "p")
        local runner = nvim_cfg .. "/runner.lua"
        write(runner, RUNNER)
        write(mods .. "/lwtestmod.lua", module_source(runner))
        env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
        -- The module on the runtime path of `nvim -u NONE` (the lw client and
        -- the daemon it launches, which inherits this environment).
        env.vars.XDG_CONFIG_HOME = nvim_cfg
        if not H.is_win then
            -- (POSIX: lw's own settings live there too.)
            env.config = nvim_cfg
        end
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    it("every batch form: the same output, exit code, JUnit and cache as in-process (§19.17)", function()
        local a, b = workspace(), workspace()
        local cases = {
            { { "test", "dev" } },
            { { "test", "dev" }, { LW_TEST_FAIL_UNIT = "app" } },
            { { "test", "dev" }, { LW_TEST_FAIL_UNIT = "lib" } },
            { { "test", "dev", "--", "-R", "only_this" } },
            { { "test", "dev", "--junit", "reports/j.xml" } },
            { { "test", "dev", "--junit", "reports/k.xml" }, { LW_TEST_FAIL_UNIT = "app" } },
            { { "test", "dev", "--junit", "reports/n.xml" }, { LW_TEST_NO_JUNIT = "1" } },
            { { "test", "dev" }, { LW_TEST_FAIL = "build" } },
            { { "test", "dev" }, { LW_TEST_FOO = "bar" } },
            { { "test", "zzz" } },
            { { "test", "9" } },
            { { "test" } },
            { { "test", "1" } },
        }
        for _, c in ipairs(cases) do
            local args = { "--no-input" }
            vim.list_extend(args, c[1])
            local ra = lw(a, { "--no-daemon", unpack(args) }, c[2])
            local rb = lw(b, args, c[2])
            local what = table.concat(c[1], " ") .. " " .. vim.inspect(c[2] or {})
            assert.equals(ra.code, rb.code, what .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
            assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), what)
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), what)
            -- Routed exactly when the arguments resolve to a profile.
            local routed = rb.stderr:find(NOTICE, 1, true) ~= nil
            assert.is_true(ra.stderr:find(NOTICE, 1, true) == nil, what)
            local refused_early = c[1][2] == "zzz" or c[1][2] == "9" or c[1][2] == nil
            assert.equals(not refused_early, routed, what .. "\n" .. rb.stderr)
            assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), what)
            assert.same(files_of(a .. "/reports"), files_of(b .. "/reports"), what)
        end
        -- The forms did run: a pass, a failure that still ran the other
        -- runner, the runner arguments and the JUnit files.
        local ok = lw(b, { "--no-input", "test", "dev", "--", "-R", "x" })
        assert.equals(0, ok.code, ok.stderr)
        assert.truthy(ok.stdout:find("==> [test] app:Debug", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("tests of lib FOO=nil ARGS=-R,x", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("TESTS OK: dev (2 runs)", 1, true), ok.stdout)
        local bad = lw(b, { "--no-input", "test", "dev" }, { LW_TEST_FAIL_UNIT = "app" })
        assert.equals(1, bad.code)
        assert.truthy(bad.stdout:find("tests of lib", 1, true), bad.stdout)
        assert.truthy(bad.stderr:find("lw: 1 of 2 test run(s) failed: app:Debug", 1, true), bad.stderr)
        local reports = files_of(b .. "/reports")
        assert.truthy(next(reports), "no JUnit file written")
    end)

    it("--target and the opt-outs stay in-process; --target says so in one line", function()
        local root = workspace()
        local r = lw(root, { "--no-input", "test", "dev" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find(NOTICE, 1, true) == 1, r.stderr)
        for _, case in ipairs({
            { { "--no-daemon" } },
            { {}, { LOOMWORKS_NO_DAEMON = "1" } },
            { {}, { CI = "true" } },
            { {}, { LOOMWORKS_RUNTIME = "in-process" } },
            { { "--break-locks" }, nil, "--break-locks runs the test in this process" },
            { { "--target", "app" }, nil, "--target runs test executables in this process" },
        }) do
            local args = { "--no-input", "test", "dev" }
            vim.list_extend(args, case[1])
            local x = lw(root, args, case[2])
            assert.is_nil(x.stderr:find("testing through the workspace daemon", 1, true), vim.inspect(case))
            local _, fallbacks = x.stderr:gsub("running without it", "")
            assert.equals(case[3] and 1 or 0, fallbacks, x.stderr)
            if case[3] then
                assert.truthy(x.stderr:find("lw: the workspace daemon could not take the test ("
                    .. case[3] .. "); running without it", 1, true), x.stderr)
            end
            if case[1][1] ~= "--target" then
                assert.equals(0, x.code, x.stderr)
                assert.truthy(x.stdout:find("TESTS OK: dev (2 runs)", 1, true), x.stdout)
            end
        end
    end)

    it("an interrupted client cancels the test run: runner killed, lock released, next run OK", function()
        local root = workspace()
        -- Built first, so the run below goes straight to the runners.
        assert.equals(0, lw(root, { "--no-input", "test", "dev" }).code)
        local pidfile = H.tmp() .. "/pid"
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        e.vars.LW_TEST_SLEEP_TEST = "60000"
        e.vars.LW_TEST_PIDFILE = pidfile
        local c = H.lw_start({ "--no-input", "test", "dev" }, { env = e, cwd = root })
        local ok = vim.wait(60000, function() return read(pidfile .. ".test") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        H.track_root(root)
        local spid = tonumber(read(pidfile .. ".test"))
        local sst = proc.start_time(spid)
        H.track(spid, sst)
        assert.truthy(c.stderr():find(NOTICE, 1, true), c.stderr())
        -- Ctrl-C on POSIX; on Windows the client is terminated: both drop the
        -- connection, which cancels the run (§19.15).
        c.kill(H.is_win and "sigkill" or "sigint")
        assert.is_true(c.wait(30000))
        assert.is_true(c.code ~= 0)
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        for _, p in ipairs({ "app", "lib" }) do
            local bd = root .. "/out/" .. p .. "/Debug"
            assert.is_true(vim.wait(10000, function() return build_lock.read(bd) == nil end, 20), bd)
        end
        local again = lw(root, { "--no-input", "test", "dev" })
        assert.equals(0, again.code, again.stderr)
        assert.truthy(again.stderr:find(NOTICE, 1, true), again.stderr)
        assert.truthy(again.stdout:find("TESTS OK: dev", 1, true), again.stdout)
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
