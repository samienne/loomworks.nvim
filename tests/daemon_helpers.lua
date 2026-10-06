-- Shared helpers for the daemon specs (spec §19.2, §19.6–§19.11): a temp
-- workspace, an isolated environment (data dir = trust key + runtime state,
-- config dir = lw settings), real `lw` processes run through the nvim host
-- (`nvim --headless -u NONE -l lua/loomworks/cli.lua …`), and cleanup that
-- never leaves a daemon running.

local proc = require("loomworks.proc")
local uv = vim.uv or vim.loop

local M = {}

M.REPO = (uv.cwd():gsub("\\", "/"))
M.CLI = M.REPO .. "/lua/loomworks/cli.lua"
M.is_win = package.config:sub(1, 1) == "\\"

local function tmp()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end
M.tmp = tmp

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
    -- ... and each step of a command's ensure (connect + handshake, ping),
    -- whose 1 s budget a healthy daemon can miss there: the command then
    -- runs without it and prints a line the parity tests do not expect.
    vars.LW_TEST_DAEMON_STEP_MS = "30000"
    if M.is_win then vars.APPDATA = cfg else vars.XDG_CONFIG_HOME = cfg end
    for k, v in pairs(extra or {}) do vars[k] = v or nil end
    return { vars = vars, data = data, config = cfg }
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

--- Run `lw <args>` to completion as a real process. Returns
--- { code, stdout, stderr, ms }.
--- @param args string[]
--- @param opts { env: table, cwd?: string, timeout?: integer }
function M.lw(args, opts)
    local out, err = uv.new_pipe(false), uv.new_pipe(false)
    -- `opts.stdin`: text the process reads on its standard input (then EOF).
    local inp = opts.stdin and uv.new_pipe(false) or nil
    local obuf, ebuf, code = {}, {}, nil
    -- Modules resolve on the runtime path (plugin_loader): `-u NONE` needs
    -- the checkout on it to build anything.
    local argv = { "--headless", "-u", "NONE", "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", M.REPO) .. ")",
        "-l", M.CLI }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local t0 = uv.hrtime()
    local h, pid = uv.spawn(vim.v.progpath, {
        args = argv, cwd = opts.cwd, env = env_list(opts.env.vars),
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
--- { pid, start, stdout(), stderr(), code (nil while running), kill(signal) };
--- with `opts.stdin`, also `write(text)` / `close_stdin()` (its standard
--- input is a pipe: e.g. a prompt's answer).
--- @param args string[]
--- @param opts { env: table, cwd?: string, stdin?: boolean }
function M.lw_start(args, opts)
    local out, err = uv.new_pipe(false), uv.new_pipe(false)
    local inp = opts.stdin and uv.new_pipe(false) or nil
    local obuf, ebuf = {}, {}
    local argv = { "--headless", "-u", "NONE", "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", M.REPO) .. ")",
        "-l", M.CLI }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = {}
    local h, pid = uv.spawn(vim.v.progpath, {
        args = argv, cwd = opts.cwd, env = env_list(opts.env.vars), stdio = { inp, out, err },
    }, function(c) r.code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
    out:read_start(function(_, d) if d then obuf[#obuf + 1] = d end end)
    err:read_start(function(_, d) if d then ebuf[#ebuf + 1] = d end end)
    r.pid, r.start = pid, proc.start_time(pid)
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
    return r
end

--- The step script of `shell_workspace` (run by nvim -l): prints
--- `step <kind> FOO=<LW_TEST_FOO> ONLY=<LW_TEST_ONLY>` on stdout and a line
--- on stderr; writes its pid to $LW_TEST_PIDFILE; sleeps $LW_TEST_SLEEP ms;
--- exits 3 when $LW_TEST_FAIL names its kind; kills itself with a signal
--- when $LW_TEST_KILL is `<kind>:<signal>` (e.g. `build:sigkill` — on
--- Windows libuv emulates it with TerminateProcess, exit code 1).
M.STEP = [[
local kind = arg[1]
local pf = os.getenv("LW_TEST_PIDFILE")
if pf then local f = io.open(pf .. "." .. kind, "w"); f:write(tostring(vim.uv.os_getpid())); f:close() end
io.write("step " .. kind .. " FOO=" .. tostring(os.getenv("LW_TEST_FOO")) .. " ONLY="
    .. tostring(os.getenv("LW_TEST_ONLY")) .. " ARGS=" .. table.concat(arg, ",", 2) .. string.char(10))
io.stderr:write("stderr of " .. kind .. string.char(10))
-- A ninja-style `[N/M]` progress line from the build step (LW_TEST_PROGRESS=N/M).
local prog = os.getenv("LW_TEST_PROGRESS")
if prog and kind == "build" then io.write("[" .. prog .. "] Building CXX object src/x.cpp.o" .. string.char(10)) end
io.stdout:flush()
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
--- (app=Debug). `opts.profile`: also write a signed working copy with the
--- profile `dev` (the trust key must already be set, in-process tests).
--- @param opts? { profile?: boolean }
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
        local trust = require("loomworks.trust")
        local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } } }
        -- (No `assert(x)` as a value: under busted it is luassert's, which
        -- returns nothing.)
        local signed, serr = trust.sign("user", trust.encode(user))
        if not signed then error(serr) end
        f = io.open(root .. "/.nvim/loomworks.user.json", "wb")
        f:write(signed); f:close()
    end
    return root
end

--- `lw daemon stop` in `root`, then wait until the stopped daemon's process
--- has exited. stop returns once the runtime lock is released, a moment
--- before the process is gone — on a loaded machine a while: a test that
--- ends (or lists processes) right there would find it still running.
--- @param root string
--- @param env table from M.env
--- @return table result of M.lw
function M.stop_daemon(root, env)
    local lk = require("loomworks.daemon.rlock").read(root)
    if lk and type(lk.pid) == "number" then M.track(lk.pid, lk.start_time) end
    local r = M.lw({ "daemon", "stop" }, { env = env, cwd = root })
    if r.code == 0 and lk and type(lk.start_time) == "string" then
        vim.wait(30000, function() return not M.alive(lk.pid, lk.start_time) end, 50)
    end
    return r
end

--- Daemon processes this spec started or found, killed by `cleanup`.
local tracked = {}

--- Remember a process to be killed at cleanup (pid + start time).
--- @param pid integer
--- @param start? string
function M.track(pid, start)
    if type(pid) ~= "number" then return end
    tracked[#tracked + 1] = { pid = pid, start = start or proc.start_time(pid) }
end

--- Track the daemon a workspace's runtime lock names (if any).
--- @param root string
--- @return table|nil the lock info
function M.track_root(root)
    local info = require("loomworks.daemon.rlock").read(root)
    if info and type(info.pid) == "number" then M.track(info.pid, info.start_time) end
    return info
end

--- Processes found alive by `cleanup` over a whole spec file (asserted by a
--- final test, so a failing test's leftovers do not mask its own failure).
M.leftovers = 0

--- Processes still alive after `cleanup` tried to kill them: a real leak
--- (asserted zero by each spec's final test).
M.survivors = 0

--- Kill every tracked process still alive (identity-checked, the whole tree;
--- retried once), whatever the test's outcome — after_each runs it, so a
--- failed assertion never leaves a daemon running. Returns the number found
--- alive (also added to `M.leftovers`: a test that passed should have stopped
--- its daemon itself; one that failed has already been reported).
function M.cleanup()
    local n = 0
    for _, t in ipairs(tracked) do
        pcall(proc._resume, t.pid)
        if type(t.start) == "string" and proc.alive(t.pid, t.start) then
            n = n + 1
            for _ = 1, 2 do
                pcall(proc.kill_tree, t.pid, t.start)
                if vim.wait(5000, function() return proc.alive(t.pid, t.start) ~= true end, 20) then break end
            end
            if proc.alive(t.pid, t.start) == true then M.survivors = M.survivors + 1 end
        end
    end
    tracked = {}
    M.leftovers = M.leftovers + n
    return n
end

--- Is the process (pid + start time) alive?
function M.alive(pid, start)
    return type(start) == "string" and proc.alive(pid, start) == true
end

--- `s` (stdout or stderr, root already replaced) comparable across the three
--- runtimes: CRLF as LF, the daemon's delegation line dropped, pids and
--- durations masked.
--- @param s string
--- @return string
function M.parity_text(s)
    s = s:gsub("\r\n", "\n")
    s = s:gsub("[^\n]*through the workspace daemon[^\n]*\n", "")
    s = s:gsub("pid %d+", "pid N"):gsub("%d+%.%d+ ?s%f[%W]", "<t>"):gsub("%d+ ?ms%f[%W]", "<t>")
    return s
end

--- Three-way parity (spec §19.1 "Loopback during the transition", §19.17):
--- `o.args` on three workspaces — `o.roots[1]` in-process
--- (LOOMWORKS_RUNTIME=in-process), `[2]` routed through a live daemon (daemon
--- mode: launched by the run itself), `[3]` attached (`--no-daemon` in daemon
--- mode, no daemon running) — with the same exit code, output
--- (`o.norm(s, root)` then `parity_text`) and state (`o.state(root)`). The
--- daemon is stopped afterwards. Returns the in-process result.
--- @param o { roots: string[], args: string[], lw: function, norm: function, state: function, env: table, extra?: table, stdin?: string, routed?: boolean }
--- @return table
function M.three_way(o)
    local function with(t) return vim.tbl_extend("force", o.extra or {}, t) end
    local a, b, c = o.roots[1], o.roots[2], o.roots[3]
    local what = table.concat(o.args, " ")
    local ra = o.lw(a, o.args, with({ LOOMWORKS_RUNTIME = "in-process" }), o.stdin)
    local rb = o.lw(b, o.args, with({ LOOMWORKS_RUNTIME = "daemon" }), o.stdin)
    local rc = o.lw(c, { "--no-daemon", unpack(o.args) }, with({ LOOMWORKS_RUNTIME = "daemon" }), o.stdin)
    if o.routed ~= false then
        assert(rb.stderr:find("through the workspace daemon", 1, true), what .. ": not routed\n" .. rb.stderr)
        local f = io.open(c .. "/.nvim/loomworks.daemon.log", "rb")
        local log = f and f:read("*a") or ""
        if f then f:close() end
        local op
        for _, x in ipairs(o.args) do if x:sub(1, 1) ~= "-" then op = x; break end end
        assert(log:find("attached run of " .. tostring(op), 1, true), what .. ": not attached\n" .. log)
        -- Served by the attached runtime: its service accepted the request as
        -- a task (not merely started, then fell back in-process) ...
        assert(log:find("\n[^\n]*" .. vim.pesc(tostring(op)) .. " [^\n]*%(task [^)]+%) accepted"),
            what .. ": no attached task\n" .. log)
        -- ... and no daemon was involved (§19.1 rule c).
        assert(not rc.stderr:find("through the workspace daemon", 1, true), what .. ": daemon line\n" .. rc.stderr)
    end
    M.stop_daemon(b, o.env)
    local ea = M.parity_text(o.norm(ra.stdout, a))
    local fa = M.parity_text(o.norm(ra.stderr, a))
    for _, x in ipairs({ { rb, b, "daemon" }, { rc, c, "attached" } }) do
        local r, root, how = x[1], x[2], what .. " (" .. x[3] .. ")"
        assert.equals(ra.code, r.code, how .. "\n" .. r.stderr)
        assert.equals(ea, M.parity_text(o.norm(r.stdout, root)), how)
        assert.equals(fa, M.parity_text(o.norm(r.stderr, root)), how)
        assert.same(o.state(a), o.state(root), how)
    end
    assert.is_nil(uv.fs_stat(c .. "/.nvim/loomworks.daemon.lock"), what .. ": R not released")
    return ra
end

return M
