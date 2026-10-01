--- loomworks/daemon/runtime.lua — the runtime mode (spec §19.1).
---
--- During the transition (spec §19.19 steps 1–5) the host setting
--- `runtime-mode` takes:
---   * `in-process` (the default) — no daemon is launched or used; every
---     operation runs on the in-process path (§1–§18 as written);
---   * `daemon` — every workspace command ensures the workspace daemon is
---     running (launching it if absent) and routes the operations that have
---     moved (none yet: step 2 only keeps it running); everything else still
---     runs on the in-process path.
--- `LOOMWORKS_RUNTIME` overrides the setting. An invalid value at either
--- layer is reported and ignored (falls through to the next source).
---
--- This module only RESOLVES; it never launches or connects.

local M = {}

M.IN_PROCESS = "in-process"
M.DAEMON = "daemon"

--- The transition default (spec §19.1).
M.DEFAULT = M.IN_PROCESS

M.MODES = { M.IN_PROCESS, M.DAEMON }

M.ENV = "LOOMWORKS_RUNTIME"

--- The host setting key.
M.SETTING = "runtime-mode"

local VALID = { [M.IN_PROCESS] = true, [M.DAEMON] = true }

--- @param mode any
--- @return boolean
function M.is_valid(mode)
    return type(mode) == "string" and VALID[mode] == true
end

--- Resolve the effective mode: `LOOMWORKS_RUNTIME` > configured value >
--- default. Returns the mode, the source it came from ("env", "setting",
--- "default") and a warning for an invalid value that was ignored.
--- @param configured string|nil the configured mode (host setting / plugin option)
--- @param opts? { getenv?: fun(name:string):string|nil, what?: string }
--- @return string mode, string source, string|nil warning
function M.resolve(configured, opts)
    local getenv = (opts and opts.getenv) or os.getenv
    local what = (opts and opts.what) or M.SETTING
    local warning
    local env = getenv(M.ENV)
    if env ~= nil and env ~= "" then
        if M.is_valid(env) then return env, "env", nil end
        warning = string.format("%s=%s is not one of in-process|daemon; ignoring it", M.ENV, tostring(env))
    end
    if configured ~= nil and configured ~= "" then
        if M.is_valid(configured) then return configured, "setting", warning end
        local w = string.format("%s '%s' is not one of in-process|daemon; ignoring it", what, tostring(configured))
        warning = warning and (warning .. "; " .. w) or w
    end
    return M.DEFAULT, "default", warning
end

--- The idle-timeout setting (spec §19.11) and its default (1 hour).
M.IDLE_SETTING = "daemon-idle-timeout"
M.IDLE_DEFAULT = 3600

--- Parse a duration: seconds (`3600`) or `<n>s|m|h` (`90s`, `30m`, `1h`).
--- @param v any
--- @return integer|nil seconds
function M.parse_duration(v)
    if type(v) == "number" then return (v > 0 and v == math.floor(v)) and v or nil end
    if type(v) ~= "string" then return nil end
    local n, unit = v:match("^%s*(%d+)%s*([smh]?)%s*$")
    n = tonumber(n)
    if not n or n <= 0 then return nil end
    return n * (({ s = 1, m = 60, h = 3600 })[unit] or 1)
end

--- The daemon's idle timeout in seconds from a settings table (an invalid
--- value falls back to the default).
--- @param cfg table|nil
--- @return integer
function M.idle_seconds(cfg)
    return M.parse_duration(cfg and cfg[M.IDLE_SETTING]) or M.IDLE_DEFAULT
end

local function truthy(v) return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false" end

--- Does this command use the workspace daemon (spec §19.1)? During the
--- transition: only in `daemon` mode, and not when attached is selected —
--- in this precedence: the `--no-daemon` flag; `LOOMWORKS_NO_DAEMON` (`1`
--- attached, `0` shared even in CI); `CI`. Attached means, for now, the
--- in-process path with no daemon launched (§19.1 "During the transition").
--- @param configured string|nil the runtime-mode setting
--- @param opts? { flag?: boolean, getenv?: fun(name:string):string|nil }
--- @return { daemon: boolean, mode: string, reason?: string, warning?: string }
function M.select(configured, opts)
    opts = opts or {}
    local getenv = opts.getenv or os.getenv
    local mode, _, warning = M.resolve(configured, opts)
    if mode ~= M.DAEMON then return { daemon = false, mode = mode, reason = "runtime-mode " .. mode, warning = warning } end
    if opts.flag then return { daemon = false, mode = mode, reason = "--no-daemon", warning = warning } end
    local nd = getenv("LOOMWORKS_NO_DAEMON")
    if nd == "1" then return { daemon = false, mode = mode, reason = "LOOMWORKS_NO_DAEMON=1", warning = warning } end
    if nd == "0" then return { daemon = true, mode = mode, warning = warning } end
    if nd ~= nil and nd ~= "" then
        local w = "LOOMWORKS_NO_DAEMON=" .. nd .. " is not 1 or 0; ignoring it"
        warning = warning and (warning .. "; " .. w) or w
    end
    if truthy(getenv("CI")) then return { daemon = false, mode = mode, reason = "CI", warning = warning } end
    return { daemon = true, mode = mode, warning = warning }
end

return M
