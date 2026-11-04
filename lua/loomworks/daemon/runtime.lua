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

--- The CLI's transition default (spec §19.1; the editor's is `daemon`,
--- `editor_select`).
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

--- The idle-timeout setting (spec §19.11 "Idle exit").
M.IDLE_SETTING = "daemon-idle-timeout"
--- The idle grace (spec §19.11 "Warm restarts", step 5r): the default of the
--- idle timeout, defined only here; every other default refers to it.
M.IDLE_GRACE_SECONDS = 45

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
--- or absent value falls back to the idle grace `IDLE_GRACE_SECONDS`).
--- @param cfg table|nil
--- @return integer
function M.idle_seconds(cfg)
    return M.parse_duration(cfg and cfg[M.IDLE_SETTING]) or M.IDLE_GRACE_SECONDS
end

local function truthy(v) return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false" end

--- How long an attached run waits for another attached run that holds the
--- workspace's runtime lock before it fails "workspace busy" (spec §19.2):
--- the setting and its default (5 s).
M.BUSY_WAIT_SETTING = "runtime-busy-wait"
M.BUSY_WAIT_DEFAULT_MS = 5000

--- Parse a busy-wait value: `0` (no wait), `<n>ms`, or a duration of
--- `parse_duration` (`5`, `5s`, `1m`). Returns milliseconds, or nil when invalid.
--- @param v any
--- @return integer|nil
function M.parse_busy_wait(v)
    if v == 0 or v == "0" then return 0 end
    if type(v) == "string" then
        local ms = tonumber(v:match("^%s*(%d+)%s*ms%s*$") or "")
        if ms then return ms end
    end
    local s = M.parse_duration(v)
    return s and s * 1000 or nil
end

--- The busy wait in milliseconds from a settings table (an invalid value
--- falls back to the default).
--- @param cfg table|nil
--- @return integer
function M.busy_wait_ms(cfg)
    return M.parse_busy_wait(cfg and cfg[M.BUSY_WAIT_SETTING]) or M.BUSY_WAIT_DEFAULT_MS
end

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

--- @alias loomworks.daemon.RuntimeSource "setup"|"default"

--- @class loomworks.daemon.EditorSelection
--- @field mode string the effective mode (`in-process` | `daemon`)
--- @field source loomworks.daemon.RuntimeSource the source that decided
--- @field daemon boolean the editor is a client of the workspace daemon
--- @field deprecated boolean|nil the deprecated in-process editor (the Runtime line's note)
--- @field warning string|nil an ignored setup value (the Runtime line's note)

--- The Runtime line's note on the deprecated in-process editor (spec/ui.md §1.1).
M.DEPRECATED_NOTE = "deprecated: the in-process editor will be removed"

--- The editor's runtime mode (spec §19.1, step 5s). `daemon` is the default;
--- of the setup option `runtime.mode` only `"in-process"` changes it — the
--- deprecated in-process editor, until step 6b — and an explicit `"daemon"`
--- is shown as `setup`. The environment (`LOOMWORKS_RUNTIME`,
--- `LOOMWORKS_NO_DAEMON`, `CI`) and lw's `runtime-mode` setting do not apply
--- to the editor. An invalid value is reported in `warning` and ignored.
--- @param opts? { configured?: string }
--- @return loomworks.daemon.EditorSelection
function M.editor_select(opts)
    local configured = opts and opts.configured
    if configured == M.IN_PROCESS then
        return { mode = M.IN_PROCESS, source = "setup", daemon = false, deprecated = true }
    end
    if configured == M.DAEMON then return { mode = M.DAEMON, source = "setup", daemon = true } end
    local sel = { mode = M.DAEMON, source = "default", daemon = true }
    if configured ~= nil and configured ~= "" then
        sel.warning = string.format("runtime.mode '%s' is not one of in-process|daemon; ignoring it",
            tostring(configured))
    end
    return sel
end

return M
