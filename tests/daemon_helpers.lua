-- Shared helpers for the daemon specs (spec §19.2, §19.6–§19.11, §19.16): a
-- temp workspace, an isolated environment (data dir = trust key + runtime
-- state, config dir = lw settings), real `lw` processes and cleanup that never
-- leaves a daemon running.
--
-- The `lw` is a real binary given by LOOMWORKS_LW (`make test` provisions the
-- release the plugin pins into .lw-test/, scripts/test_lw.lua): a spec that
-- runs lw fails when it is unset, never skips. Everything these helpers need
-- from the binary side goes through lw's CLI and its JSON output: signing a
-- working copy (`lw trust --yes`), a workspace's daemon (`lw daemon list
-- --json --under <root>`), stopping and killing it (`lw daemon stop`, `lw
-- daemon kill --all --strays --under <root>`). No binary-side module is loaded
-- here.

local uv = vim.uv or vim.loop

local M = {}

M.REPO = (uv.cwd():gsub("\\", "/"))
M.is_win = package.config:sub(1, 1) == "\\"

local function tmp()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end
M.tmp = tmp

--- The lw under test: LOOMWORKS_LW, checked once (`lw version --json`
--- answers only when the binary finds its release bundle). Errors when unset
--- or unusable: these specs need a real lw.
local checked
--- @return string
function M.lw_path()
    local p = os.getenv("LOOMWORKS_LW")
    if p == nil or p == "" then
        error("LOOMWORKS_LW is not set: the daemon specs run a real lw. `make test` sets it "
            .. "(`make lw` provisions the pinned release into .lw-test/); by hand, run "
            .. "`eval \"$(nvim -l scripts/test_lw.lua .lw-test)\"` first.", 0)
    end
    if checked ~= p then
        local r = vim.system({ p, "version", "--json" }, { text = true }):wait()
        if r.code ~= 0 then
            error("LOOMWORKS_LW=" .. p .. " does not run (it finds its release bundle through "
                .. "LOOMWORKS_INSTALL_DIR; see `make lw`): " .. (r.stderr or "") .. (r.stdout or ""), 0)
        end
        checked = p
    end
    return p
end

--- A temp workspace (an empty loomworks.json).
--- @return string root
function M.workspace()
    local root = tmp()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = vim.empty_dict() }))
    f:close()
    vim.fn.mkdir(root .. "/.nvim", "p")
    return root
end

--- An isolated environment: its own data dir (trust key, runtime state) and
--- config dir (lw settings). `extra` adds/overrides variables (false removes).
--- LOOMWORKS_LW and LOOMWORKS_INSTALL_DIR (the release bundle) carry over.
--- @param extra? table<string, string|false>
--- @return table env { vars = dict, data = dir, config = dir }
function M.env(extra)
    local data, cfg = tmp(), tmp()
    local vars = {}
    for k, v in pairs(uv.os_environ()) do vars[k] = v end
    -- Never inherit a runtime selection or CI marker from the test runner.
    for _, k in ipairs({ "LOOMWORKS_RUNTIME", "LOOMWORKS_NO_DAEMON", "CI", "LW_NO_INPUT",
        "LOOMWORKS_LUA", "LW_ROOT", "XDG_RUNTIME_DIR" }) do
        vars[k] = nil
    end
    vars.LOOMWORKS_DATA_DIR = data
    -- Spawned lw never runs the startup housekeeping (spec §16.40).
    vars.LOOMWORKS_NO_HOUSEKEEPING = "1"
    -- The suite runs every spec file at once: give a daemon start, and a
    -- handshake, room on a loaded machine.
    vars.LW_TEST_DAEMON_READY_MS = "60000"
    -- ... and each step of a command's ensure (connect + handshake, ping).
    vars.LW_TEST_DAEMON_STEP_MS = "30000"
    -- ... and a routed operation's own connect + handshake (5 s).
    vars.LW_TEST_DAEMON_CONNECT_MS = "30000"
    if M.is_win then vars.APPDATA = cfg else vars.XDG_CONFIG_HOME = cfg end
    for k, v in pairs(extra or {}) do vars[k] = v or nil end
    return { vars = vars, data = data, config = cfg }
end

--- An environment on this editor's own data dir (minimal_init's): the trust
--- key the editor and the lw it starts share.
--- @param extra? table<string, string|false>
--- @return table env
function M.editor_env(extra)
    return M.env(vim.tbl_extend("force", { LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR }, extra or {}))
end

--- The env as the `uv.spawn` list.
local function env_list(vars)
    local l = {}
    for k, v in pairs(vars) do l[#l + 1] = k .. "=" .. v end
    return l
end
M.env_list = env_list

--- Write lw settings into an env's config dir.
--- @param env table from M.env
--- @param settings table
function M.settings(env, settings)
    local dir = env.config .. "/loomworks"
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(dir .. "/config.json", "w"))
    f:write(vim.json.encode(settings))
    f:close()
end

--- Started lw processes (`lw_start`), killed by `cleanup` if still running.
local clients = {}

--- Run `lw <args>` to completion as a real process. Returns
--- { code, stdout, stderr, ms, pid }.
--- @param args string[]
--- @param opts { env: table, cwd?: string, timeout?: integer, stdin?: string }
function M.lw(args, opts)
    local out, err = uv.new_pipe(false), uv.new_pipe(false)
    -- `opts.stdin`: text the process reads on its standard input (then EOF).
    local inp = opts.stdin and uv.new_pipe(false) or nil
    local obuf, ebuf, code = {}, {}, nil
    local t0 = uv.hrtime()
    local h, pid = uv.spawn(M.lw_path(), {
        args = args, cwd = opts.cwd, env = env_list(opts.env.vars),
        stdio = { inp, out, err },
    }, function(c) code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
    if inp then inp:write(opts.stdin, function() pcall(function() inp:close() end) end) end
    local eof = 0
    out:read_start(function(_, d) if d then obuf[#obuf + 1] = d else eof = eof + 1 end end)
    err:read_start(function(_, d) if d then ebuf[#ebuf + 1] = d else eof = eof + 1 end end)
    local done = vim.wait(opts.timeout or 120000, function() return code ~= nil and eof >= 2 end, 10)
    pcall(function() out:read_stop(); out:close(); err:read_stop(); err:close() end)
    pcall(function() h:close() end)
    if not done then
        pcall(uv.kill, pid, "sigkill")
        error("lw " .. table.concat(args, " ") .. " timed out: " .. table.concat(ebuf))
    end
    return { code = code, stdout = table.concat(obuf), stderr = table.concat(ebuf),
        ms = (uv.hrtime() - t0) / 1e6, pid = pid }
end

--- Start `lw <args>` without waiting (a build to interrupt). Returns
--- { pid, stdout(), stderr(), code (nil while running), kill(signal), wait(ms) };
--- with `opts.stdin`, also `write(text)` / `close_stdin()` (its standard
--- input is a pipe: e.g. a prompt's answer). `cleanup` kills it if it still
--- runs.
--- @param args string[]
--- @param opts { env: table, cwd?: string, stdin?: boolean }
function M.lw_start(args, opts)
    local out, err = uv.new_pipe(false), uv.new_pipe(false)
    local inp = opts.stdin and uv.new_pipe(false) or nil
    local obuf, ebuf = {}, {}
    local r = {}
    local h, pid = uv.spawn(M.lw_path(), {
        args = args, cwd = opts.cwd, env = env_list(opts.env.vars), stdio = { inp, out, err },
    }, function(c) r.code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
    out:read_start(function(_, d) if d then obuf[#obuf + 1] = d end end)
    err:read_start(function(_, d) if d then ebuf[#ebuf + 1] = d end end)
    r.pid = pid
    function r.stdout() return table.concat(obuf) end
    function r.stderr() return table.concat(ebuf) end
    function r.kill(sig) pcall(uv.process_kill, h, sig or "sigkill") end
    function r.write(text) if inp then inp:write(text) end end
    function r.close_stdin() if inp then pcall(function() inp:close() end) end end
    function r.wait(ms)
        local ok = vim.wait(ms or 60000, function() return r.code ~= nil end, 10)
        if ok then pcall(function() out:close(); err:close(); h:close() end) end
        return ok
    end
    clients[#clients + 1] = r
    return r
end

--- Sign `root`'s working copy for the trust key of `env` (`lw trust --yes`:
--- what a user does to accept a working copy written by hand).
--- @param root string
--- @param env? table from M.env (default: this editor's data dir)
function M.trust(root, env)
    local r = M.lw({ "--no-input", "trust", "--yes" }, { env = env or M.editor_env(), cwd = root })
    if r.code ~= 0 then error("lw trust --yes in " .. root .. ": " .. r.stderr .. r.stdout) end
end

--- The text of a working copy `user` (a table, without `_sig`) signed by lw
--- for the trust key of `env`: `lw trust --yes` in a scratch copy of the
--- workspace (a signature does not bind the directory, `lw help trust`), so
--- a live daemon never sees the unsigned file.
--- @param root string the workspace (its loomworks.json is copied)
--- @param user table
--- @param env? table from M.env (default: this editor's data dir)
--- @return string
function M.signed_user(root, user, env)
    local scratch = tmp()
    vim.fn.mkdir(scratch .. "/.nvim", "p")
    local src = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = src:read("*a"); src:close()
    local f = assert(io.open(scratch .. "/loomworks.json", "wb")); f:write(cfg); f:close()
    f = assert(io.open(scratch .. "/.nvim/loomworks.user.json", "wb")); f:write(vim.json.encode(user)); f:close()
    M.trust(scratch, env)
    f = assert(io.open(scratch .. "/.nvim/loomworks.user.json", "rb"))
    local signed = f:read("*a"); f:close()
    return signed
end

--- The step script of `shell_workspace` (run by nvim -l): prints
--- `step <kind> FOO=<LW_TEST_FOO> ONLY=<LW_TEST_ONLY>` on stdout and a line
--- on stderr; writes its pid to $LW_TEST_PIDFILE.<kind> (atomically); waits until the file $LW_TEST_GATE exists; sleeps $LW_TEST_SLEEP ms;
--- exits 3 when $LW_TEST_FAIL names its kind; kills itself with a signal
--- when $LW_TEST_KILL is `<kind>:<signal>` (e.g. `build:sigkill` — on
--- Windows libuv emulates it with TerminateProcess, exit code 1).
M.STEP = [[
local kind = arg[1]
local pf = os.getenv("LW_TEST_PIDFILE")
-- Written aside and renamed into place: a reader polling for the file never
-- sees it created but still empty (a loaded machine widens that window).
if pf then
    local f = io.open(pf .. "." .. kind .. ".tmp", "w"); f:write(tostring(vim.uv.os_getpid())); f:close()
    vim.uv.fs_rename(pf .. "." .. kind .. ".tmp", pf .. "." .. kind)
end
-- Raw bytes first / last on a step's stdout, given as `<kind>:<hex>`
-- (LW_TEST_STDOUT_HEAD / LW_TEST_STDOUT_TAIL): a UTF-8 sequence cut at a
-- process's end (PROTOCOL.md §14.2).
local function raw(var)
    local v = os.getenv(var)
    if not v or v:sub(1, #kind + 1) ~= kind .. ":" then return "" end
    return (v:sub(#kind + 2):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end
io.write(raw("LW_TEST_STDOUT_HEAD"))
io.write("step " .. kind .. " FOO=" .. tostring(os.getenv("LW_TEST_FOO")) .. " ONLY="
    .. tostring(os.getenv("LW_TEST_ONLY")) .. " ARGS=" .. table.concat(arg, ",", 2) .. string.char(10))
io.stderr:write("stderr of " .. kind .. string.char(10))
io.write(raw("LW_TEST_STDOUT_TAIL"))
-- Raw bytes on the build step's stderr, given as hex (LW_TEST_STDERR=ff41):
-- output that is not valid UTF-8 (PROTOCOL.md §14.2 `data`).
local hex = os.getenv("LW_TEST_STDERR")
if hex and kind == "build" then
    io.stderr:write((hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)))
    io.stderr:flush()
end
-- A ninja-style `[N/M]` progress line from the build step (LW_TEST_PROGRESS=N/M).
local prog = os.getenv("LW_TEST_PROGRESS")
if prog and kind == "build" then io.write("[" .. prog .. "] Building CXX object src/x.cpp.o" .. string.char(10)) end
io.stdout:flush()
-- Held until the file $LW_TEST_GATE exists (at most 120 s): a test releases
-- the step once it has observed what must happen while the task runs.
local gate = os.getenv("LW_TEST_GATE")
if gate then
    local t0 = vim.uv.hrtime()
    while not vim.uv.fs_stat(gate) and (vim.uv.hrtime() - t0) < 120e9 do vim.uv.sleep(20) end
end
local ms = tonumber(os.getenv("LW_TEST_SLEEP") or "")
local only = os.getenv("LW_TEST_SLEEP_STEP") -- (sleep in this step only)
if ms and (not only or only == kind) then vim.uv.sleep(ms) end
if os.getenv("LW_TEST_FAIL") == kind then os.exit(3) end
local ks = os.getenv("LW_TEST_KILL")
if ks and ks:sub(1, #kind + 1) == kind .. ":" then
    io.stdout:flush(); io.stderr:flush()
    vim.uv.kill(vim.uv.os_getpid(), ks:sub(#kind + 2))
    vim.uv.sleep(10000)
end
]]

--- A workspace with one `shell` project `app` (configure + build both run
--- the STEP script through this nvim) and a configuration set `dev`
--- (app=Debug). `opts.profile`: also write a working copy with the profile
--- `dev`, signed by lw (`M.trust`) for the trust key of `opts.env` (default:
--- this editor's data dir); `opts.launch`: with it, the project's launch
--- configurations in that working copy; `opts.tests`: app's saved
--- test-target list there.
--- @param opts? { profile?: boolean, launch?: table, tests?: table, env?: table }
--- @return string root
function M.shell_workspace(opts)
    local root = tmp()
    vim.fn.mkdir(root .. "/app", "p")
    vim.fn.mkdir(root .. "/.nvim", "p")
    local step = root .. "/step.lua"
    local f = io.open(step, "w"); f:write(M.STEP); f:close()
    local nv = (vim.v.progpath:gsub("\\", "/"))
    local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
    local cfg = {
        projects = { app = { path = "app", shell = {
            build_dir = "${workspace_root}/out/${variant}",
            configure_cmd = cmd("configure"), build_cmd = cmd("build"),
            configurations = { Debug = vim.empty_dict() },
        } } },
        configuration_sets = { dev = { app = "Debug" } },
    }
    f = io.open(root .. "/loomworks.json", "w"); f:write(vim.json.encode(cfg)); f:close()
    if opts and opts.profile then
        local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } } }
        -- Launch programs are honored only from the working copy (§17.10).
        -- `tests`: app's saved test targets (§1.3.4), with the launches.
        if opts.launch or opts.tests then
            local app = vim.deepcopy(cfg.projects.app)
            app.launch = opts.launch
            app.shell.tests = opts.tests
            user.projects = { app = app }
        end
        f = io.open(root .. "/.nvim/loomworks.user.json", "wb")
        f:write(vim.json.encode(user)); f:close()
        M.trust(root, opts.env)
    end
    return root
end

--- Make loading `root` raise warnings before any task starts (API.md §4.1
--- reply notes): a project without a configure command (in no configuration
--- set, so nothing builds it) and, unless `opts.signed_cache`, a build cache an
--- earlier lw left unsigned (which a read-only command leaves as it is).
--- @param root string
--- @param opts? { signed_cache?: boolean }
function M.load_warnings(root, opts)
    local f = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = vim.json.decode(f:read("*a")); f:close()
    local ghost = vim.deepcopy(cfg.projects.app)
    ghost.path, ghost.launch = "ghost", nil
    for _, v in pairs(ghost) do
        if type(v) == "table" then v.configure_cmd = nil end
    end
    vim.fn.mkdir(root .. "/ghost", "p")
    cfg.projects.ghost = ghost
    f = assert(io.open(root .. "/loomworks.json", "wb")); f:write(vim.json.encode(cfg)); f:close()
    if opts and opts.signed_cache then return end
    f = assert(io.open(root .. "/.nvim/loomworks.cache.json", "wb"))
    f:write('{ "_meta": { "version": 8 }, "build_dirs": {} }'); f:close()
end

--- `lw daemon list --json [--under <root>]`: the daemons' entries (pid,
--- start_time, state, relays, ...).
--- @param root? string only the daemons of workspaces under it
--- @param env? table from M.env (default: this editor's data dir)
--- @return table[]
local function list(root, env)
    local args = { "daemon", "list", "--json" }
    if root then vim.list_extend(args, { "--under", root }) end
    local r = M.lw(args, { env = env or M.editor_env(), cwd = root })
    if r.code ~= 0 then error("lw daemon list --json: " .. r.stderr) end
    return vim.json.decode(r.stdout).daemons or {}
end

--- The daemons of `root` (`lw daemon list --json --under <root>` entries).
--- @param root string
--- @param env? table
--- @return table[]
function M.daemons(root, env) return list(root, env) end

--- The daemon of `root` (its `lw daemon list --json` entry), or nil.
--- @param root string
--- @param env? table
--- @return table|nil
function M.daemon(root, env) return list(root, env)[1] end

--- Is the daemon (pid + start time) still running? `root`: list only that
--- workspace's daemons (default: every daemon on the machine).
--- @param pid integer
--- @param start string
--- @param root? string
--- @return boolean
function M.alive(pid, start, root)
    for _, d in ipairs(list(root)) do
        if d.pid == pid and d.start_time == start then return true end
    end
    return false
end

--- Workspaces whose daemons `cleanup` kills: { root, env }.
local tracked = {}

--- Remember `root` for `cleanup` and return its daemon's entry (if any).
--- @param root string
--- @param env? table from M.env: the data dir its daemon belongs to (default: this editor's)
--- @return table|nil the `lw daemon list --json` entry
function M.track_root(root, env)
    env = env or M.editor_env()
    local seen = false
    for _, t in ipairs(tracked) do if t.root == root then seen = true end end
    if not seen then tracked[#tracked + 1] = { root = root, env = env } end
    return M.daemon(root, env)
end

--- `lw daemon stop` in `root`, then wait until the stopped daemon is gone
--- from `lw daemon list`. stop returns once the runtime lock is released, a
--- moment before the process is gone — on a loaded machine a while: a test
--- that ends (or lists processes) right there would find it still running.
--- @param root string
--- @param env table from M.env
--- @return table result of M.lw
function M.stop_daemon(root, env)
    local d = M.track_root(root, env)
    local r = M.lw({ "daemon", "stop" }, { env = env, cwd = root })
    if r.code == 0 and d then
        vim.wait(30000, function() return not M.alive(d.pid, d.start_time, root) end, 100)
    end
    return r
end

--- Processes found alive by `cleanup` over a whole spec file (asserted by a
--- final test, so a failing test's leftovers do not mask its own failure).
M.leftovers = 0

--- Daemons still running after `cleanup` tried to kill them: a real leak
--- (asserted zero by each spec's final test).
M.survivors = 0

--- Kill every started lw still running and every tracked workspace's daemon
--- (`lw daemon kill --all --strays --under <root>`, retried once), whatever the
--- test's outcome — after_each runs it, so a failed assertion never leaves a
--- daemon running. Returns the number found alive (also added to
--- `M.leftovers`: a test that passed should have stopped its daemon itself).
function M.cleanup()
    local n = 0
    for _, c in ipairs(clients) do
        if c.code == nil then
            n = n + 1
            c.kill("sigkill")
            c.wait(5000)
        end
    end
    clients = {}
    for _, t in ipairs(tracked) do
        if #list(t.root, t.env) > 0 then
            n = n + 1
            for _ = 1, 2 do
                M.lw({ "daemon", "kill", "--all", "--strays", "--under", t.root }, { env = t.env, cwd = t.root })
                if vim.wait(5000, function() return #list(t.root, t.env) == 0 end, 100) then break end
            end
            if #list(t.root, t.env) > 0 then M.survivors = M.survivors + 1 end
        end
    end
    tracked = {}
    M.leftovers = M.leftovers + n
    return n
end

--- The `relay` of `observer.attach` that spawns real relays of the lw under
--- test (`lw daemon run --stdio`): the editor's daemon is a real one.
--- @return function
function M.real_relay()
    local relay_client = require("loomworks.daemon.client.relay")
    return function(ro, cb)
        ro.argv = { M.lw_path() }
        return relay_client.connect(ro, cb)
    end
end

--- A protocol session to `root`'s daemon as another client (`client`,
--- default "cli": not the editor, so it never makes the daemon load),
--- through a real relay that starts the daemon when none runs. Uses the
--- plugin's own relay client; `cleanup` cannot see it, so close it.
--- @param root string
--- @param client? string
--- @return table conn (loomworks.daemon.Conn)
function M.session(root, client)
    local relay_client = require("loomworks.daemon.client.relay")
    local conn, err, info
    local r, serr = relay_client.connect({ argv = { M.lw_path() }, root = root, form = "ordinary",
        client = client or "cli" }, function(c, e, x) conn, err, info = c, e, x end)
    assert(r, serr)
    assert(vim.wait(60000, function() return conn ~= nil or err ~= nil end, 20), "no welcome from " .. root)
    assert(conn, tostring(err) .. " " .. vim.inspect(info))
    return conn
end

--- One interface call on a `M.session`, waited for: its result, or nil + err.
--- `env`: the caller's environment the call carries (a command that runs or
--- writes needs one, as the editor's carry `vim.fn.environ()`).
--- @return any result, table|nil err
function M.call(conn, object, iface, v, method, args, env, ms)
    local done, res, err = false, nil, nil
    conn:call(object, iface, v, method, args or {}, function(r, e) done, res, err = true, r, e end, env)
    assert(vim.wait(ms or 60000, function() return done end, 20), "no reply to " .. method)
    return res, err
end

--- Install the harness-only module `tests/fixtures/<name>` (teststub,
--- devstub) as an acquired module of this editor's data dir
--- (`<data>/modules/<name>`, where `lw module install` puts one), so the
--- daemon the editor's relay starts can build its projects. Its scripts run
--- through this nvim ($LW_TEST_NVIM, which spawned lw inherits).
--- @param name string
function M.install_stub_module(name)
    vim.env.LW_TEST_NVIM = vim.v.progpath
    local src = M.REPO .. "/tests/fixtures/" .. name
    local dst = vim.env.LOOMWORKS_DATA_DIR .. "/modules/" .. name
    if uv.fs_stat(dst) then return end
    for rel, typ in vim.fs.dir(src, { depth = 10 }) do
        if typ == "file" then
            local to = dst .. "/" .. rel
            vim.fn.mkdir(vim.fn.fnamemodify(to, ":h"), "p")
            assert(uv.fs_copyfile(src .. "/" .. rel, to))
        end
    end
end

--- A stub `loomworks.Workspace/1` handler table: `methods` (its `header`)
--- plus every command method (step 5o part B1) answering `refused`, so a
--- test registry mounts the interface (a method without a handler is not
--- mounted).
--- @param methods table
--- @return table methods
function M.workspace_stub(methods)
    for _, m in ipairs({ "publish", "publish_one", "revert_one", "revert_to_baseline", "set_intent",
        "set_description", "trust_accept", "delete_user_prefs" }) do
        methods[m] = methods[m] or function() return { outcome = "refused", message = "stub", exit_code = 1 } end
    end
    return methods
end

return M
