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
    -- The suite runs every spec file at once: give a daemon start, and a
    -- handshake, room on a loaded machine.
    vars.LW_TEST_DAEMON_READY_MS = "60000"
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
    local obuf, ebuf, code = {}, {}, nil
    -- Modules resolve on the runtime path (plugin_loader): `-u NONE` needs
    -- the checkout on it to build anything.
    local argv = { "--headless", "-u", "NONE", "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", M.REPO) .. ")",
        "-l", M.CLI }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local t0 = uv.hrtime()
    local h, pid = uv.spawn(vim.v.progpath, {
        args = argv, cwd = opts.cwd, env = env_list(opts.env.vars),
        stdio = { nil, out, err },
    }, function(c) code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
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
--- { pid, start, stdout(), stderr(), code (nil while running), kill(signal) }.
--- @param args string[]
--- @param opts { env: table, cwd?: string }
function M.lw_start(args, opts)
    local out, err = uv.new_pipe(false), uv.new_pipe(false)
    local obuf, ebuf = {}, {}
    local argv = { "--headless", "-u", "NONE", "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", M.REPO) .. ")",
        "-l", M.CLI }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = {}
    local h, pid = uv.spawn(vim.v.progpath, {
        args = argv, cwd = opts.cwd, env = env_list(opts.env.vars), stdio = { nil, out, err },
    }, function(c) r.code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
    out:read_start(function(_, d) if d then obuf[#obuf + 1] = d end end)
    err:read_start(function(_, d) if d then ebuf[#ebuf + 1] = d end end)
    r.pid, r.start = pid, proc.start_time(pid)
    function r.stdout() return table.concat(obuf) end
    function r.stderr() return table.concat(ebuf) end
    function r.kill(sig) pcall(uv.process_kill, h, sig or "sigkill") end
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
--- exits 3 when $LW_TEST_FAIL names its kind.
M.STEP = [[
local kind = arg[1]
local pf = os.getenv("LW_TEST_PIDFILE")
if pf then local f = io.open(pf .. "." .. kind, "w"); f:write(tostring(vim.uv.os_getpid())); f:close() end
io.write("step " .. kind .. " FOO=" .. tostring(os.getenv("LW_TEST_FOO")) .. " ONLY="
    .. tostring(os.getenv("LW_TEST_ONLY")) .. " ARGS=" .. table.concat(arg, ",", 2) .. string.char(10))
io.stderr:write("stderr of " .. kind .. string.char(10))
local ms = tonumber(os.getenv("LW_TEST_SLEEP") or "")
if ms then vim.uv.sleep(ms) end
if os.getenv("LW_TEST_FAIL") == kind then os.exit(3) end
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

return M
