--- loomworks/daemon/launch.lua — start a workspace daemon (spec §19.10).
---
--- `<own executable> daemon run --root <root>`:
---   * detached (new process group / session), hidden, and with NO inherited
---     standard handles: on POSIX stdio is /dev/null; on Windows libuv spawns
---     with bInheritHandles=TRUE, so the client's own std handles — a pipe
---     when run as `lw … | tail` — are marked non-inheritable around the
---     spawn (FFI SetHandleInformation) and restored after. Without this the
---     daemon kept the pipe open and `lw build | tail` hung until the daemon
---     exited (2 m 56 s in the 2026-09 spike, DAEMON.md §6);
---   * working directory: the per-user state directory, never the workspace
---     (the daemon must not keep it busy);
---   * environment: the client's, de-duplicated (Windows: case-insensitively,
---     keeping the entry this process resolves), plus `LW_ROOT` and
---     `LOOMWORKS_LUA` = the source this process runs (so the daemon runs the
---     same code, and a v0.1.2 host re-executes it, DAEMON.md §6);
---   * readiness: wait about 10 s for a handle naming a live daemon while
---     watching the child for an early exit. A child that exits because
---     another daemon holds the runtime lock (`server.EXIT_HELD`) is not a
---     failure — the client uses the winner. Any other early exit, or no
---     handle in time, is a launch failure. Never retried in a loop.
---
--- "Own executable": the fused `lw` binary itself; a non-fused luvi run
--- (`luvi <app> -- …`) re-runs luvi with its app; the nvim-hosted fallback
--- re-runs `nvim --headless -u NONE -l <cli.lua>` with its checkout on the
--- runtime path (where modules resolve).

local uv = vim.uv or vim.loop
local paths = require("loomworks.daemon.paths")

local M = {}

--- Readiness wait (§19.10). `LW_TEST_DAEMON_READY_MS` lengthens it for test
--- suites that start daemons on a heavily loaded machine.
M.READY_MS = tonumber(os.getenv("LW_TEST_DAEMON_READY_MS") or "") or 10000

local function is_win() return package.config:sub(1, 1) == "\\" end
local function norm(p) return p and (tostring(p):gsub("\\", "/"):gsub("/+$", "")) or nil end

--- The command prefix that re-runs this `lw`, or nil + reason.
--- @return string[]|nil argv, string|nil err
function M.self_argv()
    if rawget(vim, "_loomworks_shim") then
        local ok, exe = pcall(uv.exepath)
        if not ok or type(exe) ~= "string" then return nil, "cannot find the lw executable" end
        local okb, luvi = pcall(require, "luvi")
        local base = okb and luvi and luvi.bundle and luvi.bundle.base or nil
        local nb, ne = norm(base), norm(exe)
        if is_win() then nb, ne = nb and nb:lower(), ne:lower() end
        if base and nb ~= ne then return { exe, base, "--" } end
        return { exe }
    end
    local root = require("loomworks.daemon.version").lua_root()
    if not root then return nil, "cannot find the lw sources" end
    -- Modules resolve on the runtime path (plugin_loader), which `-u NONE`
    -- leaves without these sources: put their checkout on it, so the daemon
    -- builds with the modules the client has (spec §19.15).
    local repo = root:gsub("/lua$", "")
    return { vim.v.progpath, "--headless", "-u", "NONE",
        "--cmd", "lua vim.opt.rtp:prepend(" .. string.format("%q", repo) .. ")",
        "-l", root .. "/loomworks/cli.lua" }
end

--- The daemon's environment as a "K=V" list. `extra` (the editor's
--- `binary.source`, §19.16) is set last.
--- @param root string
--- @param extra? table<string, string>
--- @return string[]
function M.env(root, extra)
    local env = uv.os_environ()
    local out, by_key = {}, {}
    for k, v in pairs(env) do
        local key = is_win() and k:upper() or k
        local cur = by_key[key]
        if not cur then
            by_key[key] = { k, v }
        elseif is_win() and uv.os_getenv(k) == v and uv.os_getenv(cur[1]) ~= cur[2] then
            -- Two spellings of one variable (Path / PATH): keep the one this
            -- process resolves.
            by_key[key] = { k, v }
        end
    end
    local function set(k, v)
        by_key[is_win() and k:upper() or k] = { k, v }
    end
    set("LW_ROOT", root)
    local src = require("loomworks.daemon.version").lua_root()
    -- The luvi host runs the source it resolved (a release bundle, a pinned
    -- one, a dev checkout): the daemon must run the same one, whatever host
    -- binary re-executes it (an old host resolves its own otherwise).
    if src and rawget(vim, "_loomworks_shim") then set("LOOMWORKS_LUA", src) end
    for k, v in pairs(extra or {}) do set(k, v) end
    for _, kv in pairs(by_key) do out[#out + 1] = kv[1] .. "=" .. kv[2] end
    table.sort(out)
    return out
end

-- Windows: std handles non-inheritable around the spawn ----------------------

local _k
local function k32()
    if _k ~= nil then return _k or nil end
    _k = false
    local ok, ffi = pcall(require, "ffi")
    if not ok or ffi.os ~= "Windows" then return nil end
    pcall(ffi.cdef, "void* GetStdHandle(unsigned long nStdHandle);")
    pcall(ffi.cdef, "int GetHandleInformation(void* h, unsigned long* flags);")
    pcall(ffi.cdef, "int SetHandleInformation(void* h, unsigned long mask, unsigned long flags);")
    _k = ffi
    return ffi
end

local HANDLE_FLAG_INHERIT = 1
local STD = { 0xFFFFFFF6, 0xFFFFFFF5, 0xFFFFFFF4 } -- (DWORD)-10, -11, -12

--- Clear HANDLE_FLAG_INHERIT on this process's std handles; returns the
--- restore function.
--- @return fun()
function M._no_inherit_std()
    local ffi = k32()
    if not ffi then return function() end end
    local saved = {}
    for _, n in ipairs(STD) do
        pcall(function()
            local h = ffi.C.GetStdHandle(n)
            local v = ffi.cast("intptr_t", h)
            if h == nil or v == -1 or v == 0 then return end
            local f = ffi.new("unsigned long[1]")
            if ffi.C.GetHandleInformation(h, f) ~= 0 and (tonumber(f[0]) % 2) == 1 then
                if ffi.C.SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0) ~= 0 then saved[#saved + 1] = h end
            end
        end)
    end
    return function()
        for _, h in ipairs(saved) do
            pcall(function() ffi.C.SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) end)
        end
    end
end

--- Spawn the daemon (no wait). Returns { pid, exited = fun(): integer|nil }
--- or nil + reason.
--- `opts.argv` replaces the own-executable prefix: the editor launches the
--- host binary it resolved (spec §19.16), never its own plugin source;
--- `opts.env` adds variables (the opt-in `binary.source`).
--- @param root string
--- @param opts? { args?: string[], argv?: string[], env?: table<string, string> } extra `daemon run` arguments; the executable prefix; extra environment
--- @return table|nil child, string|nil err
function M.spawn(root, opts)
    local argv, aerr
    if opts and opts.argv then argv = vim.list_extend({}, opts.argv) else argv, aerr = M.self_argv() end
    if not argv then return nil, aerr end
    local exe = table.remove(argv, 1)
    for _, a in ipairs({ "daemon", "run", "--root", root }) do argv[#argv + 1] = a end
    for _, a in ipairs(opts and opts.args or {}) do argv[#argv + 1] = a end
    local cwd = paths.state_dir()
    pcall(vim.fn.mkdir, cwd, "p")
    if not uv.fs_stat(cwd) then return nil, "cannot create " .. cwd end
    local child = { code = nil }
    local env = M.env(root, opts and opts.env)
    local restore = M._no_inherit_std()
    -- Whatever happens in the spawn, the std handles' inherit flags are
    -- restored.
    local okp, h, pid = pcall(uv.spawn, exe, {
        args = argv,
        env = env,
        cwd = cwd,
        stdio = { nil, nil, nil },
        detached = true,
        hide = true,
    }, function(code, signal)
        -- (A daemon a signal ended: 128 + signal, never "status 0".)
        child.code = require("loomworks.build_run").exit_status(code, signal)
        if child.handle and not child.handle:is_closing() then pcall(function() child.handle:close() end) end
    end)
    restore()
    if not okp then return nil, "cannot start " .. tostring(exe) .. ": " .. tostring(h) end
    if not h then return nil, "cannot start " .. tostring(exe) .. ": " .. tostring(pid) end
    child.handle, child.pid = h, pid
    pcall(function() h:unref() end)
    return child
end

--- Launch a daemon for `root` and wait until one is live (§19.10). Returns
--- true + the live state (loomworks.daemon.inspect) or false + reason.
--- @param root string
--- @param opts? { ready_ms?: integer, args?: string[] }
--- @return boolean ok, table|string state_or_reason, table|nil child
function M.launch(root, opts)
    opts = opts or {}
    local inspect = require("loomworks.daemon.inspect")
    local EXIT_HELD = require("loomworks.daemon.server").EXIT_HELD
    local child, err = M.spawn(root, opts)
    if not child then return false, err end
    local st
    local function ready()
        st = inspect.state(root)
        if st.kind == "live" and (child.code == nil or child.code == EXIT_HELD or st.handle.pid ~= child.pid) then
            return true
        end
        return child.code ~= nil and child.code ~= EXIT_HELD
    end
    vim.wait(opts.ready_ms or M.READY_MS, ready, 25)
    if st and st.kind == "live" then return true, st, child end
    if child.code ~= nil and child.code ~= EXIT_HELD then
        return false, "it exited with status " .. tostring(child.code), child
    end
    if child.code == EXIT_HELD then
        return false, "another runtime holds the workspace (" .. tostring(st and st.kind) .. ")", child
    end
    return false, "it did not report ready within " .. math.floor((opts.ready_ms or M.READY_MS) / 1000) .. " s", child
end

return M
