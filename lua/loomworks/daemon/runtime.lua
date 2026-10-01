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

return M
