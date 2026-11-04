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

--- A saved test target's program (run by nvim -l): `<name> [args…]`. Prints
--- its name, cwd-independent arguments and a stderr line; exits 3 when
--- $LW_TEST_FAIL_SAVED names it.
local SAVED = [[
local name = arg[1]
io.write("saved " .. name .. " ARGS=" .. table.concat(arg, ",", 2) .. string.char(10))
io.stderr:write("saved stderr " .. name .. string.char(10))
if os.getenv("LW_TEST_FAIL_SAVED") == name then os.exit(3) end
]]

--- The toolchain runtime directory `lwtestmod` reports (never created).
local RUNTIME_DIR = H.is_win and "C:/lw-runtime/bin" or "/lw-runtime/bin"

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
    local sep = package.config:sub(1, 1) == "\\" and ";" or ":"
    return { cmd = cmd, junit_out = opts.junit,
        env = { LW_V_RUNNER = "1", PATH = "/lw-runner/bin" .. sep .. (os.getenv("PATH") or "") } }
end
function TU:run_command_all_rebuilds() return false end
function M.create_test_unit(unit) return setmetatable({ _config_unit = unit }, TU) end
-- One executable build target, `tprog` (this nvim), for a target-backed
-- saved test target; its toolchain runtime directory makes the step's
-- environment a full one on Windows (ConfigUnit:run_env, runenv.compose).
function M.parse_targets() return { tprog = { type = "executable", artifact = %q } } end
function M.runtime_path() return { %q } end
return M
]]):format(runner, (vim.v.progpath:gsub("\\", "/")), RUNTIME_DIR)
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
    -- (Painted dim under --color=always: the whole line goes.)
    return (s:gsub("[^\n]*lw: testing through the workspace daemon %(pid %d+%)[^\n]*\n", ""))
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
        -- Keys too: a build dir outside `.nvim/build` is keyed by its path.
        for kk, vv in pairs(v) do
            out[type(kk) == "string" and unroot(kk, root) or kk] = walk(vv, kk)
        end
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
    --- `dev` (app=Debug, lib=Debug), created by lw itself. `saved`: app's
    --- saved test targets (§1.3.4) — launch configurations `chk` and `chk2`
    --- running the SAVED program — as its project-wide `tests` list;
    --- `launch_extra`: fields added to both launch configurations; `sh`: a
    --- third project in `dev`, of the `shell` module, whose saved test target
    --- its module cannot run (a test plan's pre-build note, §16.16).
    local function workspace(saved, launch_extra, sh)
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
        local cfg = {
            projects = { app = project("app"), lib = project("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }
        if sh then
            vim.fn.mkdir(root .. "/sh", "p")
            local p = project("sh")
            p.shell, p.lwtestmod = p.lwtestmod, nil
            p.shell.tests = { "x" }
            cfg.projects.sh, cfg.configuration_sets.dev.sh = p, "Debug"
        end
        write(root .. "/loomworks.json", vim.json.encode(cfg))
        local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        if saved then
            -- Programs are named only by the local config (§17): the launches
            -- and the list go to the user file, signed with this machine's key.
            local prog = root .. "/saved.lua"
            write(prog, SAVED)
            local function launch(name)
                local l = { command = nv, args = { "--headless", "-u", "NONE", "-l", prog, name } }
                for k, v in pairs(launch_extra or {}) do l[k] = vim.deepcopy(v) end
                return l
            end
            local app = project("app")
            -- (`tchk`: target-backed — the build target `tprog` runs SAVED.)
            app.launch = { chk = launch("chk"), chk2 = launch("chk2"),
                tchk = { target = "tprog", args = { "--headless", "-u", "NONE", "-l", prog, "tchk" } } }
            app.lwtestmod.tests = saved
            local upath = root .. "/.nvim/loomworks.user.json"
            trust._set_key_path(env.data .. "/trust.key")
            local status, body = trust.verify("user", read(upath))
            assert.equals("valid", status)
            local user = vim.json.decode(body)
            user.projects = user.projects or {}
            user.projects.app = app
            local signed, serr = trust.sign("user", trust.encode(user))
            trust._set_key_path(nil)
            if not signed then error(serr) end
            write(upath, signed)
        end
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
            -- The plain in-process host (`--no-daemon` runs attached, §19.1).
            local ra = lw(a, args, vim.tbl_extend("force", c[2] or {}, { LOOMWORKS_RUNTIME = "in-process" }))
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
        -- A relative --junit from a subdirectory lands under the CLIENT's
        -- working directory on both paths (the daemon's cwd is the root).
        do
            local args = { "--no-input", "test", "dev", "--junit", "sub-reports/s.xml" }
            local ea = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
            ea.vars.LOOMWORKS_RUNTIME = "in-process"
            local ra = H.lw(args, { env = ea, cwd = a .. "/app" })
            local rb = H.lw(args, { env = env, cwd = b .. "/app" })
            assert.equals(ra.code, rb.code, ra.stderr .. "\n---\n" .. rb.stderr)
            assert.truthy(rb.stderr:find(NOTICE, 1, true), rb.stderr)
            assert.truthy(next(files_of(a .. "/app/sub-reports")), "in-process JUnit not under the client cwd")
            assert.same(files_of(a .. "/app/sub-reports"), files_of(b .. "/app/sub-reports"))
            assert.is_nil(next(files_of(b .. "/sub-reports")), "routed JUnit resolved against the daemon's cwd")
        end
        -- The forms did run: a pass, a failure that still ran the other
        -- runner, the runner arguments and the JUnit files.
        local ok = lw(b, { "--no-input", "test", "dev", "--", "-R", "x" })
        assert.equals(0, ok.code, ok.stderr)
        assert.truthy(ok.stdout:find("==> [test] app: nvim", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("tests of lib FOO=nil ARGS=-R,x", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("TESTS OK: dev (2 steps)", 1, true), ok.stdout)
        local bad = lw(b, { "--no-input", "test", "dev" }, { LW_TEST_FAIL_UNIT = "app" })
        assert.equals(1, bad.code)
        assert.truthy(bad.stdout:find("tests of lib", 1, true), bad.stdout)
        assert.truthy(bad.stderr:find("lw: 1 of 2 test steps failed", 1, true), bad.stderr)
        local reports = files_of(b .. "/reports")
        assert.truthy(next(reports), "no JUnit file written")
    end)

    it("--color=always: each line the same text and role both ways — the same bytes (§19.17)", function()
        local roots3 = { workspace(), workspace(), workspace() }
        local cases = {
            { { "--color=always", "test", "dev" } },
            { { "--color=always", "test", "dev" }, { LW_TEST_FAIL_UNIT = "app" } },
            { { "--color=always", "test", "dev", "--junit", "reports/n.xml" }, { LW_TEST_NO_JUNIT = "1" } },
            { { "--color=always", "test", "dev" }, { LW_TEST_FAIL = "build" } },
        }
        for _, c in ipairs(cases) do
            local args = { "--no-input" }
            vim.list_extend(args, c[1])
            -- In-process, through the daemon and attached (§19.1, §19.17).
            local ra = H.three_way({ roots = roots3, args = args, extra = c[2], lw = lw, norm = norm, env = env,
                keep_daemon = true, state = function(root)
                    return { cache = cache_of(root, env.data .. "/trust.key"), reports = files_of(root .. "/reports") }
                end })
            local what = table.concat(c[1], " ") .. " " .. vim.inspect(c[2] or {})
            assert.truthy(ra.stdout:find("\27[1mbuilding profile: dev\27[0m", 1, true), what .. "\n" .. ra.stdout)
        end
        -- The test phase is painted too: its step headers and the outcome.
        local ok = lw(roots3[2],{ "--no-input", "--color=always", "test", "dev" })
        assert.equals(0, ok.code, ok.stderr)
        assert.truthy(ok.stdout:find("\27[1;36m==>\27[0m\27[1m [test] app: nvim\27[0m", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("\27[32mTESTS OK: dev (2 steps)\27[0m", 1, true), ok.stdout)
    end)

    it("--color=always: the workspace's warnings and the test plan's notes before the run, painted both ways (§19.17)", function()
        local roots3 = { workspace(nil, nil, true), workspace(nil, nil, true), workspace(nil, nil, true) }
        for _, root in ipairs(roots3) do H.load_warnings(root) end
        -- In-process, through the daemon and attached (§19.1, §19.17).
        local ra = H.three_way({ roots = roots3, args = { "--no-input", "--color=always", "test", "dev" }, lw = lw,
            norm = norm, env = env, state = function(root)
                return { cache = cache_of(root, env.data .. "/trust.key"), reports = files_of(root .. "/reports") }
            end })
        -- The reply's notes (API.md §4.1) by role: the load's warnings warn,
        -- the plan's note plain.
        assert.truthy(ra.stderr:find("\27[33mloomworks: project 'ghost': configure_cmd is required\27[0m", 1, true),
            ra.stderr)
        assert.truthy(ra.stderr:find("\nlw: note: sh: saved test targets are not supported by its module", 1, true),
            ra.stderr)
    end)

    it("-v (and --color=always): each runner and program command, env lines against the client's environment, deploy steps — the same bytes both ways (§19.17)", function()
        local tests = { "chk", { "chk2", "--x" } }
        local extra = { env = { LW_V_SAVED = "s" },
            deploy = { ["deployed/saved.lua"] = { project = "app", path = "${workspace_root}/saved.lua" } } }
        local roots3 = { workspace(tests, extra), workspace(tests, extra), workspace(tests, extra) }
        for _, root in ipairs(roots3) do H.add_module_env(root, env.data .. "/trust.key", H.VERBOSE_ENV) end
        local cases = {
            { { "--color=always", "test", "dev", "-v" }, { LW_V_CLIENT = "one" } },
            { { "test", "dev", "--verbose" }, { LW_V_CLIENT = "two" } },
            { { "--color=always", "test", "dev", "-v" }, { LW_V_CLIENT = "three", LW_TEST_FAIL_UNIT = "app" } },
            { { "test", "dev", "-v", "--no-build" }, { LW_V_CLIENT = "four" } },
        }
        for _, c in ipairs(cases) do
            local args = { "--no-input" }
            vim.list_extend(args, c[1])
            c[2].NoDefaultCurrentDirectoryInExePath = false
            c[2].NODEFAULTCURRENTDIRECTORYINEXEPATH = false
            -- In-process, through the daemon and attached (§19.1, §19.17).
            local ra = H.three_way({ roots = roots3, args = args, extra = c[2], lw = lw, norm = norm, env = env,
                keep_daemon = true, state = function(root)
                    -- (The deploy records: keyed by the absolute destination, with its source's mtime.)
                    local cache = cache_of(root, env.data .. "/trust.key")
                    local deployed = cache and vim.tbl_count(cache.deploy_state or {})
                    if cache then cache.deploy_state = nil end
                    return { cache = cache, deployed = deployed }
                end })
            local what = table.concat(c[1], " ") .. " " .. vim.inspect(c[2])
            local out = norm(ra.stdout, roots3[1]):gsub("\27%[[%d;]*m", "")
            -- The runner's command and env line (its PATH addition, over the client's PATH).
            assert.truthy(out:find("    env: LW_V_RUNNER=1 ", 1, true), what .. "\n" .. out)
            assert.truthy(out:find("/lw-runner/bin" .. (H.is_win and ";" or ":") .. "$PATH", 1, true), what .. "\n" .. out)
            assert.is_nil(out:find("LW_V_CLIENT", 1, true), out)
            if c[2].LW_TEST_FAIL_UNIT == nil then
                -- A saved target: its deploy step (none with --no-build), then its program's command and env.
                local deployed = out:find("    copy <ROOT>/saved.lua -> ", 1, true) or out:find("    up to date ", 1, true)
                assert.equals(not vim.tbl_contains(c[1], "--no-build"), deployed ~= nil, what .. "\n" .. out)
                assert.truthy(out:find("    env: LW_V_SAVED=s", 1, true), what .. "\n" .. out)
            end
        end
    end)

    it("-v, a target-backed saved test target (a full environment on Windows): the env line shows nothing the daemon itself added — the same bytes in-process, through the daemon and attached (§19.15 \"Roles and verbose\")", function()
        local roots3 = { workspace({ "tchk" }), workspace({ "tchk" }), workspace({ "tchk" }) }
        for _, form in ipairs({ { "test", "dev", "-v" }, { "--color=always", "test", "dev", "--verbose" } }) do
            local args = { "--no-input" }
            vim.list_extend(args, form)
            -- The client lacks NoDefaultCurrentDirectoryInExePath (a dev-source
            -- or editor-hosted client; the released lw sets it at startup): on
            -- Windows the daemon's environment scope adds it (envscope.with),
            -- and the step's full environment (ConfigUnit:run_env) is read in it.
            local ra = H.three_way({ roots = roots3, args = args, lw = lw, norm = norm, env = env, keep_daemon = true,
                extra = { NoDefaultCurrentDirectoryInExePath = false, NODEFAULTCURRENTDIRECTORYINEXEPATH = false },
                state = function(root) return cache_of(root, env.data .. "/trust.key") end })
            local what = table.concat(form, " ")
            assert.equals(0, ra.code, what .. "\n" .. ra.stdout .. ra.stderr)
            local out = norm(ra.stdout, roots3[1]):gsub("\27%[[%d;]*m", "")
            assert.truthy(out:find("saved tchk", 1, true), what .. "\n" .. out)
            assert.is_nil(out:lower():find("nodefaultcurrentdirectoryinexepath", 1, true), what .. "\n" .. out)
            if H.is_win then
                -- (Its only addition: the toolchain runtime directory.)
                local want = "    env: " .. require("loomworks.term").format_argv({ "PATH=" .. RUNTIME_DIR .. ";$PATH" })
                assert.truthy(out:find(want .. "\n", 1, true), what .. "\n" .. out)
            end
        end
    end)

    it("saved test targets: the daemon runs the whole plan, as in-process (§16.16, §19.15)", function()
        local tests = { "chk", { "chk2", "--x" } }
        local a, b = workspace(tests), workspace(tests)
        local cases = {
            { { "test", "dev" } },
            { { "test", "dev" }, { LW_TEST_FAIL_SAVED = "chk2" } },
            { { "test", "dev" }, { LW_TEST_FAIL_UNIT = "app" } },
            { { "test", "dev", "--junit", "reports/s.xml" } },
            { { "test", "dev", "--junit", "reports/t.xml" }, { LW_TEST_FAIL_SAVED = "chk" } },
            -- A mixed plan refuses arguments after `--` before the build (exit 2).
            { { "test", "dev", "--", "-R", "x" } },
            { { "test", "dev" }, { LW_TEST_FAIL = "build" } },
        }
        for _, c in ipairs(cases) do
            local args = { "--no-input" }
            vim.list_extend(args, c[1])
            local ra = lw(a, { "--no-daemon", unpack(args) }, vim.tbl_extend("force", c[2] or {},
                { LOOMWORKS_RUNTIME = "in-process" }))
            local rb = lw(b, args, c[2])
            local what = table.concat(c[1], " ") .. " " .. vim.inspect(c[2] or {})
            assert.equals(ra.code, rb.code, what .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
            assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), what)
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), what)
            assert.is_true(ra.stderr:find(NOTICE, 1, true) == nil, what)
            local refused = c[1][3] == "--"
            assert.equals(not refused, rb.stderr:find(NOTICE, 1, true) ~= nil, what .. "\n" .. rb.stderr)
            assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), what)
            assert.same(files_of(a .. "/reports"), files_of(b .. "/reports"), what)
        end
        local ok = lw(b, { "--no-input", "test", "dev" })
        assert.equals(0, ok.code, ok.stderr)
        assert.truthy(ok.stderr:find(NOTICE, 1, true), ok.stderr)
        for _, s in ipairs({ "==> [test] app: chk", "saved chk ARGS=", "saved chk2 ARGS=--x",
            "passed  (exit status only — no per-case results)",
            "TESTS OK: dev (4 steps)" }) do
            assert.truthy(ok.stdout:find(s, 1, true), s .. "\n" .. ok.stdout)
        end
        local bad = lw(b, { "--no-input", "test", "dev" }, { LW_TEST_FAIL_SAVED = "chk2" })
        assert.equals(1, bad.code)
        assert.truthy(bad.stdout:find("saved chk2", 1, true), bad.stdout)
        assert.truthy(bad.stderr:find("lw: 1 of 4 test steps failed", 1, true), bad.stderr)
        assert.truthy(next(files_of(b .. "/reports")), "no JUnit file written")

        -- An entry that resolves to nothing fails after the build, before any
        -- step runs — the same message on both paths.
        local c, d = workspace({ "nope" }), workspace({ "nope" })
        local rc = lw(c, { "--no-input", "--no-daemon", "test", "dev" }, { LOOMWORKS_RUNTIME = "in-process" })
        local rd = lw(d, { "--no-input", "test", "dev" })
        assert.equals(1, rc.code, rc.stderr)
        assert.equals(rc.code, rd.code, rd.stderr)
        assert.equals(norm(rc.stdout, c), norm(rd.stdout, d))
        assert.equals(norm(rc.stderr, c), drop_notice(norm(rd.stderr, d)))
        assert.truthy(rd.stderr:find("saved test entry 'nope'", 1, true), rd.stderr)
    end)

    it("--no-build is carried: nothing built, the same refusal and run as in-process (§16.16, §19.15)", function()
        local tests = { "chk" }
        local a, b = workspace(tests), workspace(tests)
        local function both(args, extra, label)
            local full = { "--no-input" }
            vim.list_extend(full, args)
            local ra = lw(a, { "--no-daemon", unpack(full) }, vim.tbl_extend("force", extra or {},
                { LOOMWORKS_RUNTIME = "in-process" }))
            local rb = lw(b, full, extra)
            assert.equals(ra.code, rb.code, label .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
            assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), label)
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), label)
            assert.truthy(rb.stderr:find(NOTICE, 1, true), label .. "\n" .. rb.stderr)  -- routed
            assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), label)
            return rb
        end
        -- Unconfigured: refused before any step, nothing configured or built.
        local r = both({ "test", "dev", "--no-build" }, nil, "unconfigured")
        assert.equals(1, r.code)
        assert.falsy(r.stdout:find("step configure", 1, true), r.stdout)
        assert.falsy(r.stdout:find("==> [test]", 1, true), r.stdout)
        for _, s in ipairs({ "app: not configured on this machine", "lib: not configured on this machine",
            "build first: lw build dev", "or run without --no-build" }) do
            assert.truthy(r.stderr:find(s, 1, true), s .. "\n" .. r.stderr)
        end
        -- (The build dirs' parents, out/app and out/lib, are left empty, by the
        -- in-process run as by the daemon — where a dir's build lockfile is
        -- taken — but no build dir was created.)
        for _, p in ipairs({ "app", "lib" }) do
            assert.is_nil(vim.uv.fs_stat(b .. "/out/" .. p .. "/Debug"), "the daemon configured or built " .. p)
        end
        -- Built once; then a build that would fail never runs under --no-build.
        for _, root in ipairs({ a, b }) do
            local rb = lw(root, { "--no-input", "--no-daemon", "build", "dev" }, { LOOMWORKS_RUNTIME = "in-process" })
            assert.equals(0, rb.code, rb.stderr)
        end
        r = both({ "test", "dev", "--no-build", "--junit", "reports/nb.xml" }, { LW_TEST_FAIL = "build" }, "built")
        assert.equals(0, r.code, r.stderr)
        assert.falsy(r.stdout:find("building profile", 1, true), r.stdout)
        assert.falsy(r.stdout:find("step build", 1, true), r.stdout)
        assert.truthy(r.stdout:find("saved chk ARGS=", 1, true), r.stdout)
        assert.truthy(r.stdout:find("TESTS OK: dev (3 steps)", 1, true), r.stdout)
        assert.same(files_of(a .. "/reports"), files_of(b .. "/reports"))
        assert.truthy(next(files_of(b .. "/reports")), "no JUnit file written")
    end)

    it("--target and in-process mode stay in-process (--target says so in one line); an attached selection uses a live daemon", function()
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
            -- An attached selection (§19.1, §19.2) finds the daemon live and
            -- uses it as a shared client; in-process mode never does.
            local shared = case[1][1] == "--no-daemon" or (case[2] and (case[2].CI or case[2].LOOMWORKS_NO_DAEMON))
            assert.equals(shared and true or false,
                x.stderr:find("testing through the workspace daemon", 1, true) ~= nil, vim.inspect(case))
            local _, fallbacks = x.stderr:gsub("running without it", "")
            assert.equals(case[3] and 1 or 0, fallbacks, x.stderr)
            if case[3] then
                assert.truthy(x.stderr:find("lw: the workspace daemon could not take the test ("
                    .. case[3] .. "); running without it", 1, true), x.stderr)
            end
            if case[1][1] ~= "--target" then
                assert.equals(0, x.code, x.stderr)
                assert.truthy(x.stdout:find("TESTS OK: dev (2 steps)", 1, true), x.stdout)
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

    it("three-way parity: in-process, through a live daemon, attached (§19.1)", function()
        H.three_way({ roots = { workspace(), workspace(), workspace() }, args = { "--no-input", "test", "dev" },
            lw = lw, norm = norm, env = env, state = function(root) return cache_of(root, env.data .. "/trust.key") end })
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
