-- Shared helpers for the lock specs (spec §19.3–§19.5): a real lock-holding
-- helper process (tests/fixtures/lock_holder.lua), cleanup that never leaves
-- one running, CLI output capture, and a small typescript workspace.

local proc = require("loomworks.proc")
local uv = vim.uv or vim.loop

local M = {}

M.REPO = (uv.cwd():gsub("\\", "/"))
-- The helper runs from a copy named `…/loomworks/cli.lua`: --break-locks only
-- ever kills a holder whose command line is an lw host (spec §19.5,
-- lock_break.verify_identity), and the nvim-hosted lw runs exactly that.
M.HELPER = (function()
    local dir = (vim.fn.tempname():gsub("\\", "/")) .. "/loomworks"
    vim.fn.mkdir(dir, "p")
    local src = assert(io.open(M.REPO .. "/tests/fixtures/lock_holder.lua", "rb")):read("*a")
    local f = assert(io.open(dir .. "/cli.lua", "wb")); f:write(src); f:close()
    return dir .. "/cli.lua"
end)()

local spawned = {}

--- Start a helper holding `lockfile`; returns { pid, start, child, child_start }.
--- @param lockfile string
--- @param op? string operation recorded (default "build")
--- @param kind? string holder kind (default "lw")
--- @param with_child? boolean the helper also starts a child process
function M.hold(lockfile, op, kind, with_child)
    local out = uv.new_pipe(false)
    local buf = ""
    local handle, pid = uv.spawn(vim.v.progpath, {
        args = { "--headless", "--clean", "-l", M.HELPER, M.REPO, lockfile, op or "build",
            kind or "lw", with_child and "1" or "0", "60000" },
        stdio = { nil, out, nil },
        env = { "LW_TEST_HEARTBEAT_MS=300" },
    }, function() end)
    assert(handle, "could not spawn the helper: " .. tostring(pid))
    out:read_start(function(_, data) if data then buf = buf .. data end end)
    assert(vim.wait(20000, function() return buf:find("\n") ~= nil end, 20),
        "helper never reported: " .. buf)
    local child = tonumber(buf:match("LOCKED (%d+)"))
    assert(child, "helper did not lock: " .. buf)
    local h = { pid = pid, start = proc.start_time(pid), child = child ~= 0 and child or nil }
    if h.child then h.child_start = proc.start_time(h.child) end
    spawned[#spawned + 1] = h
    pcall(function() out:read_stop(); out:close() end)
    return h
end

--- Kill every helper (and its child) still running.
function M.cleanup()
    for _, h in ipairs(spawned) do
        pcall(proc._resume, h.pid)
        if type(h.start) == "string" and proc.alive(h.pid, h.start) then
            proc.kill_tree(h.pid, h.start)
        end
        if h.child and type(h.child_start) == "string" and proc.alive(h.child, h.child_start) then
            proc.kill_tree(h.child, h.child_start)
        end
    end
    spawned = {}
end

--- Push a lockfile's heartbeat `secs` into the past.
function M.age(path, secs)
    local t = os.time() - secs
    uv.fs_utime(path, t, t)
end

--- Run `fn` with stdout/stderr captured and os.exit turned into an error.
function M.capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, err = pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    if not ok and not (type(err) == "table" and err.__exit) then error(err) end
    return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

function M.tmpdir()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end

--- A workspace with a typescript project App, configuration Debug, set Dev
--- and the active profile Dev, whose unit has a "built" build directory.
--- Returns root, the build directory.
function M.make_ws()
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local cli = require("loomworks.cli")
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root .. "/App", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
    M.capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    M.capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
    M.capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
    local ws = assert(cli._load_workspace(root, false))
    local unit = ws._profiles[1]:projects()[1]._config_unit
    local dir = root .. "/.nvim/build/App/Debug"
    vim.fn.mkdir(dir, "p")
    unit.build_dir_value = dir
    unit.state_value = "built"
    ws:_sync_build_dir_refs()
    ws:_save_cache()
    return root, dir
end

function M.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

return M
