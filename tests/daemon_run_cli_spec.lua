-- `lw run` prepared by the workspace daemon, the program executed by the
-- client, with real processes (spec §19.15 "Run", §19.17, §19.19 step 5):
-- the parity of every form against the in-process path (same output, exit
-- code, deploy records and persisted cache), the delegation notice, the forms
-- that stay in-process (a device option; a target found to run on a device,
-- continued in-process after the daemon's build), and the program's
-- independence from the daemon: it runs after the task ended and every lock
-- was released (a build proceeds meanwhile), two run at once, and a stopped
-- daemon does not stop them. No process is left running.
--
-- The workspace's project uses a test-only module, `lwrunmod` (the `shell`
-- module plus executable build targets), found on the runtime path of the
-- spawned `lw` and of its daemon through $XDG_CONFIG_HOME/nvim. Every program
-- is this nvim running `prog.lua`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local build_lock = require("loomworks.build_lock")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local NOTICE = "lw: preparing the run through the workspace daemon (pid "
local NV = (vim.v.progpath:gsub("\\", "/"))

--- A wrapper (`--prefix`): prints its arguments, exits 0.
local WRAP = [[io.write("wrapped " .. table.concat(arg, ",") .. string.char(10))]]

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- The program (run by nvim -l): prints its arguments, LW_RUN_FOO,
--- LW_RUN_BAZ and its working directory; writes its pid to $LW_RUN_PIDFILE;
--- waits for the file $LW_RUN_WAIT to exist; exits $LW_RUN_EXIT.
local PROG = [[
local pf = os.getenv("LW_RUN_PIDFILE")
if pf then local f = io.open(pf, "w"); f:write(tostring(vim.uv.os_getpid())); f:close() end
io.write("prog ARGS=" .. table.concat(arg, ",") .. " FOO=" .. tostring(os.getenv("LW_RUN_FOO"))
    .. " BAZ=" .. tostring(os.getenv("LW_RUN_BAZ")) .. " CWD=" .. (vim.uv.cwd():gsub("\\", "/"))
    .. string.char(10))
io.stderr:write("prog stderr" .. string.char(10))
local w = os.getenv("LW_RUN_WAIT")
if w then while not vim.uv.fs_stat(w) do vim.uv.sleep(50) end end
os.exit(tonumber(os.getenv("LW_RUN_EXIT") or "0"))
]]

--- The test-only module: the shell module plus two executable targets —
--- `prog` (this nvim) and `armprog`, a file in the build directory whose
--- header names another platform (written on each parse) — and a library.
local function module_source()
    local foreign = H.is_win and "\127ELF\2\1\1" .. string.rep("\0", 64)
        or (jit and jit.os == "OSX") and "\127ELF\2\1\1" .. string.rep("\0", 64)
        or "\254\237\250\207" .. string.rep("\0", 64)
    return ([[
local shell = require("loomworks.modules.shell")
local M = {}
for k, v in pairs(shell) do M[k] = v end
M.id = "lwrunmod"
function M.parse_targets(ctx)
    local f = io.open(ctx.build_dir .. "/armprog", "wb")
    if f then f:write(%q); f:close() end
    return {
        prog = { type = "executable", artifact = %q },
        armprog = { type = "executable", artifact = "armprog" },
        lib = { type = "static_library" },
    }
end
return M
]]):format(foreign, NV)
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

local function drop_notice(s)
    return (s:gsub("lw: preparing the run through the workspace daemon %(pid %d+%)\n", ""))
end

--- The persisted build and deploy state, comparable across two roots.
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

describe("lw run through the workspace daemon (real processes)", function()
    local env
    local roots = {}

    --- A workspace with one `lwrunmod` project `app` (Debug), launch
    --- configurations — `go` (target-backed, args, env, a deploy), `prog`
    --- (a command: the same name as a target), `cmd` (a command with a
    --- working_dir), `baddeploy` (a deploy whose source is missing) — and a
    --- profile `dev`, created by lw itself.
    local function workspace()
        local root = H.tmp()
        roots[#roots + 1] = root
        vim.fn.mkdir(root .. "/app", "p")
        vim.fn.mkdir(root .. "/sub", "p")
        vim.fn.mkdir(root .. "/.nvim", "p")
        write(root .. "/step.lua", H.STEP)
        write(root .. "/prog.lua", PROG)
        write(root .. "/wrap.lua", WRAP)
        local function cmd(kind) return { NV, "--headless", "-u", "NONE", "-l", root .. "/step.lua", kind } end
        local function largs(...)
            local a = { "--headless", "-u", "NONE", "-l", "${workspace_root}/prog.lua" }
            vim.list_extend(a, { ... })
            return a
        end
        -- Launch programs are honored only from the working copy (§17.10):
        -- written there below, signed with this environment's key.
        local launch = {
                    go = { target = "prog", args = largs("fromcfg"), env = { LW_RUN_FOO = "cfgfoo" },
                        deploy = { ["deployed/prog.lua"] = { project = "app", path = "${workspace_root}/prog.lua" } } },
                    prog = { command = NV, args = largs("cmdprog") },
                    cmd = { command = NV, args = largs("cmd"), env = { LW_RUN_FOO = "bar" }, working_dir = "sub" },
                    baddeploy = { command = NV, args = largs("bad"),
                        deploy = { ["deployed/x"] = { project = "app", path = "${workspace_root}/missing.txt" } } },
        }
        local app = { path = "app", lwrunmod = {
            build_dir = "${workspace_root}/out/${variant}",
            configure_cmd = cmd("configure"), build_cmd = cmd("build"),
            configurations = { Debug = vim.empty_dict() },
        } }
        write(root .. "/loomworks.json", vim.json.encode({
            projects = { app = app },
            configuration_sets = { dev = { app = "Debug" } },
        }))
        local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        local upath = root .. "/.nvim/loomworks.user.json"
        trust._set_key_path(env.data .. "/trust.key")
        local status, body = trust.verify("user", read(upath))
        assert.equals("valid", status)
        local user = vim.json.decode(body)
        user.projects = user.projects or {}
        app.launch = launch
        user.projects.app = app
        local signed, serr = trust.sign("user", trust.encode(user))
        trust._set_key_path(nil)
        if not signed then error(serr) end
        write(upath, signed)
        return root
    end
    local function with_vars(extra)
        if not extra then return env end
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        for k, v in pairs(extra) do e.vars[k] = v or nil end
        return e
    end
    local function lw(root, args, extra, cwd)
        return H.lw(args, { env = with_vars(extra), cwd = cwd or root })
    end
    before_each(function()
        local nvim_cfg = H.tmp()
        local mods = nvim_cfg .. "/nvim/lua/loomworks/modules"
        vim.fn.mkdir(mods, "p")
        write(mods .. "/lwrunmod.lua", module_source())
        -- Interactive defaults (the sole profile, §16.3) without a terminal:
        -- a bare `lw run` resolves the profile as at a prompt.
        env = H.env({ LOOMWORKS_RUNTIME = "daemon", LW_TEST_INTERACTIVE = "1" })
        env.vars.XDG_CONFIG_HOME = nvim_cfg
        if not H.is_win then env.config = nvim_cfg end
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    it("every form: the same output, exit code, deploy records and cache as in-process (§19.17)", function()
        local a, b = workspace(), workspace()
        local P = { "--headless", "-u", "NONE", "-l", "../prog.lua" }
        local function prog_args(...) local t = vim.deepcopy(P); vim.list_extend(t, { ... }); return t end
        -- { args, extra env, routed?, cwd subdirectory }
        local cases = {
            -- before any build: nothing parsed yet, nothing deployed
            { { "run", "--no-build", "go" }, nil, true },
            { { "run", "--dry-run", "cmd" }, nil, true },
            { { "run", "--dry-run=json", "go" }, nil, true },
            -- a failed build
            { { "run", "go" }, { LW_TEST_FAIL = "build" }, true },
            -- builds; named launch configurations, forwarded arguments
            { { "run", "go" }, nil, true },
            { { "run", "go", "--", "x", "y z" }, { LW_RUN_BAZ = "client" }, true },
            { { "run", "cmd" }, { LW_RUN_EXIT = "7" }, true },
            { { "run", "--launch", "prog" }, nil, true },
            { { "run", "dev", "cmd" }, nil, true },
            -- a named build target (ambiguous by name), its arguments, --cwd
            { { "run", "--target", "prog", "--", unpack(prog_args("t1")) }, nil, true },
            { { "run", "--target", "prog", "--cwd", "sub", "--", "-u", "NONE", "--headless", "-l",
                "../prog.lua" } , nil, true },
            { { "run", "--project", "app", "--target", "prog", "--cwd", "${workspace_root}/app", "--",
                unpack(prog_args("t2")) }, nil, true, "sub" },
            -- a relative --cwd from a subdirectory: the workspace root's, as in-process
            { { "run", "--target", "prog", "--cwd", "sub", "--", unpack(prog_args("t3")) }, nil, true, "app" },
            { { "run", "prog" }, nil, true },
            { { "run", "nosuch" }, nil, true },
            { { "run" }, nil, true },
            -- reports
            { { "run", "--print", "go", "--", "p" }, nil, true },
            { { "run", "--print=json", "go" }, nil, true },
            { { "run", "--dry-run", "--target", "prog" }, nil, true },
            { { "run", "--no-build", "cmd" }, nil, true },
            -- a failed deploy
            { { "run", "baddeploy" }, nil, true },
            -- a wrapper: the program under another program
            { { "run", "--prefix", "'" .. NV .. "' --headless -u NONE -l ../wrap.lua", "cmd" }, nil, true },
            -- refused before anything is prepared
            { { "--no-input", "run", "zzz", "go" }, nil, false },
            { { "--no-input", "run", "go" }, nil, false },
            { { "run", "--print", "--prefix", "x", "go" }, nil, false },
        }
        for _, c in ipairs(cases) do
            local args = {}
            vim.list_extend(args, c[1])
            local ra = lw(a, { "--no-daemon", unpack(args) }, c[2], c[4] and (a .. "/" .. c[4]))
            local rb = lw(b, args, c[2], c[4] and (b .. "/" .. c[4]))
            local what = table.concat(c[1], " ") .. " " .. vim.inspect(c[2] or {})
            assert.equals(ra.code, rb.code, what .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
            if ra.code == 0 and (vim.tbl_contains(c[1], "--print=json") or vim.tbl_contains(c[1], "--dry-run=json")) then
                assert.same(vim.json.decode(norm(ra.stdout, a)), vim.json.decode(norm(rb.stdout, b)), what)
            else
                assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), what)
            end
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), what)
            assert.is_nil(ra.stderr:find(NOTICE, 1, true), what)
            assert.equals(c[3], rb.stderr:find(NOTICE, 1, true) ~= nil, what .. "\n" .. rb.stderr)
            assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), what)
            assert.equals(read(a .. "/deployed/prog.lua"), read(b .. "/deployed/prog.lua"), what)
        end
        -- The default target (§16.17): set, then run with and without arguments.
        for _, root in ipairs({ a, b }) do
            local r = lw(root, { "--no-input", "--no-daemon", "target", "set", "dev", "go", "--launch" })
            assert.equals(0, r.code, r.stderr)
        end
        for _, args in ipairs({ { "run" }, { "run", "--", "d1" }, { "run", "--print" } }) do
            local full = { unpack(args) }
            local ra = lw(a, { "--no-daemon", unpack(full) })
            local rb = lw(b, full)
            local what = table.concat(args, " ")
            assert.equals(ra.code, rb.code, what .. "\n" .. rb.stderr)
            assert.equals(norm(ra.stdout, a), norm(rb.stdout, b), what)
            assert.equals(norm(ra.stderr, a), drop_notice(norm(rb.stderr, b)), what)
            assert.truthy(rb.stderr:find(NOTICE, 1, true), what)
        end
        -- The forms did what they say: the program's output, exit status,
        -- arguments, launch environment over the client's, working directory.
        local r = lw(b, { "run", "go", "--", "x" }, { LW_RUN_BAZ = "client" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("prog ARGS=fromcfg,x FOO=cfgfoo BAZ=client CWD=", 1, true), r.stdout)
        local x = lw(b, { "run", "cmd" }, { LW_RUN_EXIT = "7" })
        assert.equals(7, x.code, x.stderr)
        assert.truthy(norm(x.stdout, b):find("FOO=bar BAZ=nil CWD=<ROOT>/sub", 1, true), x.stdout)
        local p = lw(b, { "run", "--print", "go" })
        assert.equals(0, p.code, p.stderr)
        assert.is_nil(p.stdout:find("building", 1, true), p.stdout)
        assert.is_nil(p.stdout:find("step build", 1, true), p.stdout)
        assert.truthy(read(b .. "/deployed/prog.lua"), "the deploy did not run")
    end)

    it("a device option and a target that runs on a device stay in this process", function()
        local root = workspace()
        local d = lw(root, { "run", "go", "--device", "X" })
        assert.equals(1, d.code)
        assert.is_nil(d.stderr:find(NOTICE, 1, true), d.stderr)
        assert.truthy(d.stderr:find("lw: the workspace daemon could not take the run (device options run the "
            .. "program on a device in this process); running without it", 1, true), d.stderr)
        assert.truthy(d.stderr:find("--device applies only to a build target that runs on a device", 1, true),
            d.stderr)
        -- Found foreign only by probing the built artifact: the daemon built,
        -- the client continues (no second build) and refuses as in-process.
        local ra = lw(root, { "--no-daemon", "run", "armprog" })
        local rb = lw(root, { "run", "armprog" })
        assert.equals(ra.code, rb.code, rb.stderr)
        assert.truthy(rb.stderr:find(NOTICE, 1, true), rb.stderr)
        local line = "lw: the workspace daemon could not take the run (armprog runs on a device in this process); "
            .. "continuing without it\n"
        assert.truthy(norm(rb.stderr, root):find(line, 1, true), rb.stderr)
        local _, builds = rb.stdout:gsub("step build", "")
        assert.equals(1, builds, rb.stdout)
        local ea = norm(ra.stderr, root)
        local eb = drop_notice(norm(rb.stderr, root)):gsub(vim.pesc(line), "")
        assert.equals(ea, eb)
    end)

    it("the program is the client's: locks released, a build proceeds, two at once, survives lw daemon stop",
        function()
        local root = workspace()
        assert.equals(0, lw(root, { "run", "cmd" }).code)
        local dir = H.tmp()
        local starts = {}
        local function cleanup_starts()
            write(dir .. "/go", "")
            for _, s in ipairs(starts) do if not s.wait(30000) then s.kill(); s.wait(5000) end end
        end
        -- The second starts while the first's program runs (that preparation
        -- is over: another environment is then no conflict).
        for i = 1, 2 do
            starts[i] = H.lw_start({ "run", "cmd", "--", "n" .. i }, { env = with_vars({
                LW_RUN_PIDFILE = dir .. "/pid" .. i, LW_RUN_WAIT = dir .. "/go", LW_RUN_EXIT = tostring(4 + i),
            }), cwd = root })
            local ok = vim.wait(60000, function() return read(dir .. "/pid" .. i) ~= nil end, 20)
            if not ok then cleanup_starts() end
            assert.is_true(ok, starts[i].stderr())
        end
        H.track_root(root)
        for _, s in ipairs(starts) do assert.truthy(s.stderr():find(NOTICE, 1, true), s.stderr()) end
        -- No lock is held while the programs run: a build goes through.
        local bd = root .. "/.nvim/build/app/Debug"
        assert.is_nil(build_lock.read(bd))
        local b = lw(root, { "--no-input", "build", "dev" })
        assert.equals(0, b.code, b.stderr)
        assert.truthy(b.stdout:find("BUILD OK: dev", 1, true), b.stdout)
        -- Stopping the daemon does not touch them.
        local st = H.stop_daemon(root, env)
        assert.equals(0, st.code, st.stderr)
        for i = 1, 2 do
            local pid = tonumber(read(dir .. "/pid" .. i))
            assert.is_true(H.alive(pid, require("loomworks.proc").start_time(pid)), "program " .. i)
            assert.is_nil(starts[i].code, starts[i].stderr())
        end
        write(dir .. "/go", "")
        for i, s in ipairs(starts) do
            assert.is_true(s.wait(60000), s.stderr())
            assert.equals(4 + i, s.code, s.stderr())
            assert.truthy(s.stdout():find("prog ARGS=cmd,n" .. i, 1, true), s.stdout())
        end
    end)
end)

describe("the prepare_run request (§19.15 Run)", function()
    it("carries the parsed command line; the wrapper (only whether one is given) and report format stay with the client", function()
        local cli = require("loomworks.cli")
        local req, r = cli._run_request({ "run", "dev", "app", "--project", "p", "--launch", "--cwd", "${x}/d",
            "--print=json", "--", "a", "--device" })
        assert.same({ profile = "dev", target = "app", project = "p", kind = "launch", cwd = "${x}/d",
            extra = { "a", "--device" }, no_build = false, quiet = true }, req)
        assert.equals("json", r.print_mode)
        req = cli._run_request({ "run", "app", "--dry-run", "--target" })
        assert.same({ target = "app", kind = "target", extra = {}, no_build = true, quiet = true }, req)
        req, r = cli._run_request({ "run", "--prefix", "valgrind -q" })
        assert.same({ extra = {}, no_build = false, quiet = false, prefix = true }, req)
        assert.same({ "valgrind", "-q" }, r.prefix_tokens)
        assert.equals("device", (cli._run_request({ "run", "app", "--timeout", "3" })))
        assert.equals("device", (cli._run_request({ "run", "--no-wait" })))
        -- What cmd_run refuses, it reports itself (in-process).
        assert.is_nil((cli._run_request({ "run", "--print", "--prefix", "x" })))
        assert.is_nil((cli._run_request({ "run", "--print=yaml" })))
        assert.is_nil((cli._run_request({ "run", "--prefix" })))
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
