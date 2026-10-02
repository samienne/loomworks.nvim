--- loomworks/daemon/envscope.lua — run daemon-side work in the REQUESTING
--- client's environment (spec §19.15 "Environment").
---
--- A routed build must behave as if the client process had run it: the same
--- PATH, compiler / SDK / vcvars variables, `${VAR}` expansions — not the
--- environment of whichever client launched the daemon. The client sends its
--- whole environment with the request; the daemon runs every synchronous piece
--- of the operation (live-workspace sync or reload, profile resolution,
--- planning, gates, cache write-back) with its PROCESS environment switched to
--- that one, and restores its own afterwards. Whatever the model reads —
--- `os.getenv`, `vim.fn.environ`, a probe spawned with an inherited
--- environment, a PATH lookup — therefore sees the client's values, without
--- every reader having to thread an environment through. The build steps are
--- spawned with exactly the client's environment plus the step's own
--- variables (`with_overlay`), never the daemon's.
---
--- Only synchronous code runs inside a scope (the daemon serializes its model
--- work, loomworks.daemon.service), so two clients' builds never see each
--- other's environment.
---
--- Windows: the C runtime keeps its own copy of the environment, which
--- `SetEnvironmentVariableW` (what libuv's os_setenv calls) does not update, so
--- LuaJIT's `os.getenv` would keep reading the daemon's values. `install()`
--- (called once by the daemon) makes `os.getenv` read the process environment
--- through libuv instead.

local uv = vim.uv or vim.loop

local M = {}

local WIN = package.config:sub(1, 1) == "\\"

--- Variables a shell changes between two commands of one session; a
--- difference in them alone does not make the daemon reload its workspace
--- (`signature`). They are still applied to the scope and the build steps.
M.VOLATILE = { ["_"] = true, PWD = true, OLDPWD = true, SHLVL = true }

--- The comparison key of a variable name (case-insensitive on Windows).
--- @param k string
--- @return string
local function key(k) return WIN and k:upper() or k end
M._key = key

--- This process's environment as a dict.
--- @return table<string, string>
function M.capture()
    local e = {}
    for k, v in pairs(uv.os_environ()) do e[k] = v end
    return e
end

--- Validate an environment received on the wire: a dict of string → string.
--- Returns it, or nil + why.
--- @param env any
--- @return table|nil env, string|nil err
function M.validate(env)
    if type(env) ~= "table" then return nil, "no environment" end
    local n = 0
    for k, v in pairs(env) do
        if type(k) ~= "string" or type(v) ~= "string" or k == "" or k:find("[=%z]")
            or v:find("%z") then
            return nil, "malformed environment variable"
        end
        n = n + 1
    end
    if n == 0 then return nil, "empty environment" end
    return env
end

--- The canonical text of an environment, without the VOLATILE variables:
--- two environments with the same signature are the same as far as the
--- workspace model is concerned (the daemon reloads its workspace when it
--- changes, loomworks.daemon.service).
--- @param env table<string, string>
--- @return string
function M.signature(env)
    local lines = {}
    for k, v in pairs(env) do
        local kk = key(k)
        if not M.VOLATILE[kk] then lines[#lines + 1] = kk .. "=" .. v end
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

--- Make the process environment exactly `env`.
--- @param env table<string, string>
function M.apply(env)
    local cur = uv.os_environ()
    local want = {}
    for k, v in pairs(env) do want[key(k)] = { k, v } end
    for k in pairs(cur) do
        if not want[key(k)] then pcall(uv.os_unsetenv, k) end
    end
    for _, w in pairs(want) do
        if cur[w[1]] ~= w[2] then pcall(uv.os_setenv, w[1], w[2]) end
    end
end

--- Run `fn` with the process environment switched to `env` (nil: as is),
--- restoring the previous environment afterwards — also when `fn` raises
--- (the error is re-raised).
--- @param env table<string, string>|nil
--- @param fn fun(): any
--- @return any
function M.with(env, fn)
    if not env then return fn() end
    local saved = M.capture()
    M.apply(env)
    local res = { xpcall(fn, debug.traceback) }
    M.apply(saved)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

--- `env` with `overlay` on top (a step's own variables, §8.1); on Windows an
--- overlay name replaces an entry that differs only in case.
--- @param env table<string, string>
--- @param overlay table|nil
--- @return table<string, string>
function M.with_overlay(env, overlay)
    local out = {}
    for k, v in pairs(env) do out[k] = v end
    for k, v in pairs(overlay or {}) do
        if WIN then
            local lk = key(k)
            for ek in pairs(out) do
                if ek ~= k and key(ek) == lk then out[ek] = nil end
            end
        end
        out[k] = tostring(v)
    end
    return out
end

--- Make `os.getenv` read the process environment through libuv (Windows:
--- the C runtime's copy is not updated by `apply`). Idempotent; a no-op
--- elsewhere, where `setenv` already updates what `getenv` reads.
function M.install()
    if M._installed or not WIN then return end
    M._installed = true
    local orig = os.getenv
    os.getenv = function(name) -- luacheck: ignore 122
        local ok, v = pcall(uv.os_getenv, name, 131072)
        if ok then return v or nil end
        return orig(name)
    end
end

return M
