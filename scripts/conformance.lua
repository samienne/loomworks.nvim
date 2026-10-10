--- scripts/conformance.lua — the protocol conformance runner (spec §19.20
--- "Schemas and conformance", step 5g.2).
---
--- Replays the golden transcripts under `spec/protocol/transcripts/` against
--- a daemon, one fresh daemon per case, through loomworks.proto.conformance
--- (the engine: matching, frame validation against the schemas). Two
--- transports:
---
---   stdio     spawns `<lw> daemon run --root <root> --stdio --private`
---             (with LOOMWORKS_TEST_PRIVATE_STDIO=1) and speaks over
---             its standard input and output — any binary, the Lua daemon
---             and a rewrite alike (`--lw` names the command; default: this
---             checkout through nvim)
---   loopback  the daemon's server and build service in this process over
---             the in-memory transport (fast; the same frames)
---
--- Usage:
---   nvim -l scripts/conformance.lua [--transport stdio|loopback]
---        [--lw "<command> [args...]"] [--lw-version <v>] [<transcript>...]
--- Exit status 0 when every case passed. As a library (`dofile`, with
--- `_G.LW_CONFORMANCE_LIB = true`): `M.run_file`, `M.run_case`, `M.files`.

local uv = vim.uv or vim.loop

local function script_dir()
    local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
    return src:match("^(.*)/[^/]*$") or "."
end

local M = {}

M.REPO = (vim.fn.fnamemodify(script_dir() .. "/..", ":p"):gsub("\\", "/"):gsub("/$", ""))
if not package.path:find(M.REPO .. "/lua/?.lua", 1, true) then
    package.path = M.REPO .. "/lua/?.lua;" .. M.REPO .. "/lua/?/init.lua;" .. package.path
    pcall(function() vim.opt.rtp:prepend(M.REPO) end)
end

local engine = require("loomworks.proto.conformance")
local documents = require("loomworks.proto.documents")
local protocol = require("loomworks.daemon.protocol")

M.IS_WIN = package.config:sub(1, 1) == "\\"

local function tmp()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

-- ---------------------------------------------------------------------------
-- Transcripts
-- ---------------------------------------------------------------------------

--- Every transcript file, as paths relative to the protocol directory.
--- @return string[]
function M.files()
    local dir = documents.dir()
    local out = {}
    local function walk(rel)
        local h = uv.fs_scandir(dir .. "/" .. rel)
        if not h then return end
        while true do
            local name, typ = uv.fs_scandir_next(h)
            if not name then break end
            if typ == "directory" then walk(rel .. "/" .. name)
            elseif name:sub(-5) == ".json" then out[#out + 1] = rel .. "/" .. name end
        end
    end
    walk("transcripts")
    table.sort(out)
    return out
end

--- A decoded transcript file.
--- @param rel string
--- @return table
function M.load(rel)
    local text = assert(documents.read(rel))
    return assert(documents.decode(text))
end

-- ---------------------------------------------------------------------------
-- Fixtures (loomworks.proto.conformance.FIXTURES)
-- ---------------------------------------------------------------------------

--- The build/configure step of the `shell` fixture (run by nvim -l).
M.STEP = [[
local kind = arg[1]
io.write("step " .. kind .. string.char(10))
io.stdout:flush()
local ms = tonumber(os.getenv("LW_TEST_SLEEP") or "")
if ms then vim.uv.sleep(ms) end
]]

--- Create fixture `name`; `key_path` is the trust key the daemon verifies
--- the working copy with. Returns the root.
--- @param name string
--- @param key_path string
--- @return string
function M.fixture(name, key_path)
    local root = tmp()
    vim.fn.mkdir(root .. "/.nvim", "p")
    if name == nil or name == "empty" then
        write(root .. "/loomworks.json", vim.json.encode({ projects = vim.empty_dict() }))
        return root
    end
    assert(name == "shell", "unknown fixture " .. tostring(name))
    vim.fn.mkdir(root .. "/app", "p")
    write(root .. "/step.lua", M.STEP)
    local nv = (vim.v.progpath:gsub("\\", "/"))
    local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", root .. "/step.lua", kind } end
    local function app()
        return { path = "app", shell = {
            build_dir = "${workspace_root}/out/${variant}",
            configure_cmd = cmd("configure"), build_cmd = cmd("build"),
            configurations = { Debug = vim.empty_dict() },
        } }
    end
    write(root .. "/loomworks.json", vim.json.encode({
        projects = { app = app() },
        configuration_sets = { dev = { app = "Debug" } },
    }))
    local trust = require("loomworks.trust")
    trust._set_key_path(key_path)
    -- A launch configuration `hello` (honored only from the working copy,
    -- spec 17.10): the program Launch/1.prepare_run resolves.
    local user_app = app()
    user_app.launch = { hello = { command = nv, args = { "--version" } } }
    local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } },
        projects = { app = user_app } }
    local signed, serr = trust.sign("user", trust.encode(user))
    trust._set_key_path(nil)
    if not signed then error(serr) end
    write(root .. "/.nvim/loomworks.user.json", signed)
    return root
end

-- ---------------------------------------------------------------------------
-- Drivers
-- ---------------------------------------------------------------------------

local function now() return uv.hrtime() / 1e6 end

--- A driver over a pipe-like stream (read_start/write/close) carrying the
--- framed protocol.
--- @param read_start fun(cb: fun(err: string|nil, chunk: string|nil))
--- @param write_fn fun(data: string)
--- @return table driver
local function frame_driver(read_start, write_fn)
    local d = { inbox = {}, closed = nil, now = now }
    local decoder = protocol.new_decoder(protocol.MAX_FRAME)
    read_start(function(err, chunk)
        if err or not chunk then
            d.closed = d.closed or (err or "closed")
            return
        end
        local msgs, derr = decoder:push(chunk)
        if not msgs then
            d.closed = "malformed frame: " .. tostring(derr)
            return
        end
        for _, m in ipairs(msgs) do d.inbox[#d.inbox + 1] = m end
    end)
    function d.send(frame)
        if d.closed then return false, d.closed end
        local ok, err = pcall(write_fn, protocol.encode(frame))
        if not ok then return false, err end
        return true
    end
    function d.recv(timeout_ms)
        if #d.inbox == 0 and not d.closed and (timeout_ms or 0) > 0 then
            vim.wait(timeout_ms, function() return #d.inbox > 0 or d.closed ~= nil end, 5)
        elseif #d.inbox == 0 then
            vim.wait(0)
        end
        if #d.inbox > 0 then return table.remove(d.inbox, 1) end
        if d.closed then return nil, d.closed end
        return nil, "timeout"
    end
    return d
end

--- An isolated environment for a spawned daemon: its own data dir (trust
--- key, runtime state) and config dir; no runtime selection inherited.
--- @return { vars: table<string, string>, data: string }
function M.isolated_env()
    local data, cfg = tmp(), tmp()
    local vars = {}
    for k, v in pairs(uv.os_environ()) do vars[k] = v end
    for _, k in ipairs({ "LOOMWORKS_RUNTIME", "LOOMWORKS_NO_DAEMON", "CI", "LW_NO_INPUT", "LOOMWORKS_LUA",
        "LW_ROOT", "XDG_RUNTIME_DIR" }) do
        vars[k] = nil
    end
    vars.LOOMWORKS_DATA_DIR = data
    vars.LOOMWORKS_NO_HOUSEKEEPING = "1"
    if M.IS_WIN then vars.APPDATA = cfg else vars.XDG_CONFIG_HOME = cfg end
    return { vars = vars, data = data }
end

--- The client environment frames carry (`env`): the entries a request can
--- carry (loomworks.daemon.envscope.validate).
local function wire_env(vars)
    local envscope = require("loomworks.daemon.envscope")
    local out = {}
    for k, v in pairs(vars) do
        if envscope.validate({ [k] = v }) then out[k] = v end
    end
    return out
end

--- The default command of the stdio transport: this checkout's `lw`
--- through this nvim.
--- @return string[]
function M.default_lw()
    return { vim.v.progpath, "--headless", "-u", "NONE", "--cmd",
        "lua vim.opt.rtp:prepend(" .. string.format("%q", M.REPO) .. ")", "-l", M.REPO .. "/lua/loomworks/cli.lua" }
end

--- Start a daemon on `root` over standard I/O. Returns the driver (with
--- `close()` ending the daemon) and the variables of the case.
--- @param root string
--- @param ctx { env: table, lw?: string[] }
--- @return table driver
function M.stdio_driver(root, ctx)
    local argv = vim.deepcopy(ctx.lw or M.default_lw())
    -- The private runtime on standard I/O (gated, tests only, §19.10 "Tests"):
    -- without `--private`, `--stdio` is the relay to the shared daemon.
    for _, a in ipairs({ "daemon", "run", "--root", root, "--stdio", "--private" }) do argv[#argv + 1] = a end
    local inp, out, err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local envl = {}
    for k, v in pairs(ctx.env.vars) do envl[#envl + 1] = k .. "=" .. v end
    envl[#envl + 1] = "LOOMWORKS_TEST_PRIVATE_STDIO=1"
    local code
    local exe = table.remove(argv, 1)
    local h, pid = uv.spawn(exe, { args = argv, cwd = root, env = envl, stdio = { inp, out, err }, hide = true },
        function(c) code = c end)
    assert(h, "spawn failed: " .. tostring(pid))
    local ebuf = {}
    err:read_start(function(_, chunk) if chunk then ebuf[#ebuf + 1] = chunk end end)
    local d = frame_driver(function(cb) out:read_start(cb) end, function(data) inp:write(data) end)
    function d.stderr() return table.concat(ebuf) end
    function d.close()
        pcall(function() inp:close() end)
        if not vim.wait(20000, function() return code ~= nil end, 10) then
            pcall(uv.process_kill, h, "sigkill")
            vim.wait(5000, function() return code ~= nil end, 10)
        end
        pcall(function() out:close(); err:close(); h:close() end)
        return code
    end
    return d
end

--- Start a daemon on `root` in this process over the loopback transport.
--- @param root string
--- @return table driver
function M.loopback_driver(root)
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local server_mod = require("loomworks.daemon.server")
    local srv = server_mod.new(root, { tick_ms = 200, log = function() end })
    require("loomworks.daemon.service").attach(srv, require("loomworks.cli")._daemon_build_host())
    assert(srv:start_attached({ command = "conformance" }))
    local a, b = require("loomworks.daemon.loopback").pair()
    assert(srv:adopt_pipe(b))
    local d = frame_driver(function(cb) a:read_start(cb) end, function(data) a:write(data) end)
    d.server = srv
    -- As the stdio daemon does when its client closes standard input.
    function d.close()
        pcall(function() a:close() end)
        vim.wait(50)
        if not srv.stopped then srv:stop("conformance case end", 0) end
        return srv.exit_code
    end
    return d
end

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

--- Run one case. Returns ok, failure text.
--- @param case table
--- @param opts { transport: "stdio"|"loopback", lw?: string[], lw_version?: string, timeout_ms?: integer }
--- @return boolean, string|nil
function M.run_case(case, opts)
    local version = require("loomworks.daemon.version")
    local trust = require("loomworks.trust")
    local d, root, ctx_env
    local ok, a, b = pcall(function()
        if opts.transport == "stdio" then
            ctx_env = M.isolated_env()
            root = M.fixture(case.fixture, ctx_env.data .. "/trust.key")
            d = M.stdio_driver(root, { env = ctx_env, lw = opts.lw })
        else
            local key = tmp() .. "/trust.key"
            trust._set_key_path(key)
            root = M.fixture(case.fixture, key)
            trust._set_key_path(key)
            ctx_env = { vars = uv.os_environ() }
            d = M.loopback_driver(root)
        end
        local vars = { lw_version = opts.lw_version or version.identity(), root = root,
            env = wire_env(ctx_env.vars) }
        return engine.run_case(case, d, { vars = vars, timeout_ms = opts.timeout_ms })
    end)
    local closed, exit_code = false, nil
    if d then closed, exit_code = pcall(d.close) end
    if opts.transport ~= "stdio" then trust._set_key_path(nil) end
    if not ok then return false, "runner error: " .. tostring(a) end
    -- The daemon ends cleanly once its client closed the connection.
    if a and opts.transport == "stdio" and not (closed and exit_code == 0) then
        a, b = false, "end: the daemon exited with " .. tostring(exit_code) .. " after its client closed standard input"
    end
    if not a and d and d.stderr then b = b .. "\n  daemon stderr: " .. d.stderr():gsub("\n", "\n    ") end
    return a, b
end

--- Run every case of a transcript file. Returns the results
--- `{ { name, ok, err } }`.
--- @param rel string
--- @param opts table as for `run_case`
--- @return table[]
function M.run_file(rel, opts)
    local t = M.load(rel)
    local results = {}
    local problems = engine.check_file(t, rel)
    if #problems > 0 then
        return { { name = rel, ok = false, err = table.concat(problems, "; ") } }
    end
    for _, case in ipairs(t.cases) do
        if not opts.only or opts.only == case.name then
            local ok, err = M.run_case(case, opts)
            results[#results + 1] = { name = t.interface .. "/" .. t.version .. ": " .. case.name, ok = ok, err = err }
        end
    end
    return results
end

local function main(argv)
    local opts = { transport = "stdio" }
    local files = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--transport" then i = i + 1; opts.transport = argv[i]
        elseif a == "--lw" then i = i + 1; opts.lw = vim.split(argv[i], " ", { trimempty = true })
        elseif a == "--lw-version" then i = i + 1; opts.lw_version = argv[i]
        elseif a == "--case" then i = i + 1; opts.only = argv[i]
        else files[#files + 1] = a end
        i = i + 1
    end
    if #files == 0 then files = M.files() end
    local failed, total = 0, 0
    for _, rel in ipairs(files) do
        for _, r in ipairs(M.run_file(rel, opts)) do
            total = total + 1
            if r.ok then
                io.stdout:write("ok    " .. r.name .. "\n")
            else
                failed = failed + 1
                io.stdout:write("FAIL  " .. r.name .. "\n  " .. tostring(r.err) .. "\n")
            end
        end
    end
    io.stdout:write(string.format("%d case(s), %d failed (%s)\n", total, failed, opts.transport))
    return failed == 0 and 0 or 1
end

if not rawget(_G, "LW_CONFORMANCE_LIB") then
    local code = main(_G.arg or {})
    os.exit(code)
end

return M
