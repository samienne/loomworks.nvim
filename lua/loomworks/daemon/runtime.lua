--- loomworks/daemon/runtime.lua — the runtime-mode flag (DAEMON.md §7, §8).
---
--- `runtime.mode` selects which backend drives the workspace:
---   * `in-process` — the plugin/CLI IS the workspace (today's behavior). The
---     PERMANENT default and fallback.
---   * `daemon` — drive a long-lived `lw daemon` (Phase 1; no backend on mainline
---     yet, so resolving to it still runs in-process until the daemon lands).
---   * `auto` — use a daemon when one is available, else in-process.
---
--- This module ONLY resolves the *configured* mode; it never launches or
--- connects to anything. On mainline (Phase 0) the resolved mode has no daemon
--- backend behind it, so the effective execution path stays in-process no matter
--- what is configured — nothing here changes runtime behavior. `LOOMWORKS_RUNTIME`
--- overrides configuration for quick A/B (the same env-over-config precedence the
--- other `LOOMWORKS_*` overrides use).

local M = {}

M.IN_PROCESS = "in-process"
M.DAEMON = "daemon"
M.AUTO = "auto"

--- The permanent default and fallback (DAEMON.md §1, §4, §8).
M.DEFAULT = M.IN_PROCESS

M.MODES = { M.IN_PROCESS, M.DAEMON, M.AUTO }

M.ENV = "LOOMWORKS_RUNTIME"

local VALID = { [M.IN_PROCESS] = true, [M.DAEMON] = true, [M.AUTO] = true }

--- Validate a mode string.
--- @param mode any
--- @return boolean
function M.is_valid(mode)
    return type(mode) == "string" and VALID[mode] == true
end

--- Resolve the effective runtime mode.
---
--- Precedence: `LOOMWORKS_RUNTIME` env > configured value > default. An invalid
--- value at either layer is ignored (falling through to the next source) and
--- reported via the second return, so a typo never silently disables the
--- permanent in-process default — it degrades TO it.
---
--- @param configured string|nil the mode from plugin opts / CLI settings
--- @param opts? { getenv?: fun(name:string):string|nil } injectable env reader (tests)
--- @return string mode, string|nil warning
function M.resolve(configured, opts)
    local getenv = (opts and opts.getenv) or os.getenv
    local warning = nil

    local env = getenv(M.ENV)
    if env ~= nil and env ~= "" then
        if M.is_valid(env) then
            return env, nil
        end
        warning = string.format(
            "%s=%q is not one of in-process|daemon|auto; ignoring it",
            M.ENV, tostring(env))
    end

    if configured ~= nil then
        if M.is_valid(configured) then
            return configured, warning
        end
        warning = string.format(
            "runtime.mode=%q is not one of in-process|daemon|auto; using %q",
            tostring(configured), M.DEFAULT)
    end

    return M.DEFAULT, warning
end

return M
