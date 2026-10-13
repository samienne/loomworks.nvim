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

--- Variables that differ between two commands of one shell session, or
--- between two terminals (tabs, panes, SSH sessions, editor terminals) of one
--- user: a difference in them alone does not make the daemon reload its
--- workspace or decline a concurrent build (`signature`). They are still
--- applied to the scope and passed to the build steps unchanged.
---
--- A deny-list, not an allow-list of what the model reads: what a load reads
--- is open-ended (`${VAR}` in any configuration field, module and SDK probes,
--- compiler / vcvars / cache-tool variables, third-party module plugins), and
--- a variable missed by an allow-list would silently build with a model read
--- in another environment — a reload too many only costs time.
M.VOLATILE = {}
for _, k in ipairs({
    -- the shell itself
    "_", "PWD", "OLDPWD", "SHLVL",
    -- terminal emulators / multiplexers (per window, tab or pane)
    "WT_SESSION", "WT_PROFILE_ID", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TERM_PROGRAM_VERSION",
    "WINDOWID", "KONSOLE_DBUS_SESSION", "KONSOLE_DBUS_WINDOW", "KONSOLE_DBUS_SERVICE",
    "ALACRITTY_WINDOW_ID", "ALACRITTY_SOCKET", "KITTY_WINDOW_ID", "KITTY_PID", "KITTY_LISTEN_ON",
    "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "TMUX", "TMUX_PANE", "STY", "WINDOW",
    "ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME", "GNOME_TERMINAL_SCREEN",
    "SECURITYSESSIONID", "NVIM", "NVIM_LISTEN_ADDRESS", "GPG_TTY",
    -- login / SSH sessions
    "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY", "SSH_AUTH_SOCK", "XDG_SESSION_ID", "XDG_VTNR",
}) do M.VOLATILE[WIN and k:upper() or k] = true end

--- Name prefixes of such variables (editor-integrated terminals' IPC
--- handles: VS Code's `VSCODE_GIT_IPC_HANDLE`, `VSCODE_IPC_HOOK_CLI`, …;
--- ConEmu's per-console `ConEmu*`).
M.VOLATILE_PREFIXES = { "VSCODE_", WIN and "CONEMU" or "ConEmu" }

--- The comparison key of a variable name (case-insensitive on Windows).
--- @param k string
--- @return string
local function key(k) return WIN and k:upper() or k end
M._key = key

--- Is `k` one of the Windows environment block's hidden `=`-prefixed
--- entries — cmd.exe's per-drive working directories (`=C:` = `C:\src`) and
--- `=ExitCode`, inherited by every process a cmd.exe (or a `.cmd` / `.bat`
--- shim, or a console started from one) runs? They are not variables (no
--- `getenv` reads them, `SetEnvironmentVariable` is not how they are made),
--- but they are part of the block an in-process build's step inherits.
--- @param k string
--- @return boolean
function M.special(k)
    return WIN and k:sub(1, 1) == "=" and #k > 1 and not k:find("=", 2, true)
end

--- Is the variable (by comparison key) ignored by `signature`?
--- The `=`-prefixed entries change with every `cd` and every command of a
--- cmd.exe session.
--- @param kk string
--- @return boolean
function M.volatile(kk)
    if M.VOLATILE[kk] or M.special(kk) then return true end
    for _, p in ipairs(M.VOLATILE_PREFIXES) do
        if kk:sub(1, #p) == p then return true end
    end
    return false
end

--- Can the entry `k` = `v` travel in a request (`validate` accepts it)?
--- A name is non-empty, without `=` (except a Windows `=`-prefixed entry,
--- `special`) or NUL; a value is without NUL.
--- @param k any
--- @param v any
--- @return boolean
local function valid_entry(k, v)
    if type(k) ~= "string" or type(v) ~= "string" or k == "" or k:find("%z") or v:find("%z") then
        return false
    end
    return not k:find("=", 1, true) or M.special(k)
end

--- This process's environment as a dict — every entry a request can carry
--- (`valid_entry`; the process environment never holds another).
--- @return table<string, string>
function M.capture()
    local e = {}
    for k, v in pairs(uv.os_environ()) do
        if valid_entry(k, v) then e[k] = v end
    end
    return e
end

--- Validate an environment received on the wire: a dict of string → string.
--- Returns it, or nil + why (naming the variable, never its value).
--- @param env any
--- @return table|nil env, string|nil err
function M.validate(env)
    if type(env) ~= "table" then return nil, "no environment" end
    local n = 0
    for k, v in pairs(env) do
        if not valid_entry(k, v) then
            local name = type(k) == "string" and (k:gsub("[%c]", "?")) or tostring(k)
            return nil, "malformed environment variable '" .. name:sub(1, 64) .. "'"
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
        if not M.volatile(kk) then lines[#lines + 1] = kk .. "=" .. v end
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

--- Make the process environment exactly `env` — its variables: the
--- Windows `=`-prefixed entries (`special`) are left as they are on both
--- sides (they are this process's per-drive directories, and nothing the
--- model reads); they reach a build step through `with_overlay`.
--- @param env table<string, string>
function M.apply(env)
    local cur = uv.os_environ()
    local want = {}
    for k, v in pairs(env) do
        if not M.special(k) then want[key(k)] = { k, v } end
    end
    for k in pairs(cur) do
        if not want[key(k)] and not M.special(k) then pcall(uv.os_unsetenv, k) end
    end
    for _, w in pairs(want) do
        if cur[w[1]] ~= w[2] then pcall(uv.os_setenv, w[1], w[2]) end
    end
end

--- Run `fn` with the process environment switched to `env` (nil: as is),
--- restoring the previous environment afterwards — also when `fn` raises
--- (the error is re-raised). On Windows the scope keeps
--- `NoDefaultCurrentDirectoryInExePath=1` (spec §5.10) even when the client's
--- environment lacks it (a client hosted by the editor): a program a probe
--- runs by name is never taken from the current directory.
--- @param env table<string, string>|nil
--- @param fn fun(): any
--- @return any
function M.with(env, fn)
    if not env then return fn() end
    local saved = M.capture()
    if WIN then
        local exe = require("loomworks.exe")
        local has = false
        for k in pairs(env) do
            if key(k) == key(exe.NO_CWD_ENV) then has = true; break end
        end
        if not has then
            local e = {}
            for k, v in pairs(env) do e[k] = v end
            e[exe.NO_CWD_ENV] = "1"
            env = e
        end
    end
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
