--- loomworks/daemon/broker.lua — the runtime broker (DAEMON.md §5.2).
---
--- Decides WHICH `lw` runtime a daemon would be driven from, by the precedence:
---
---   LOOMWORKS_LW → repo pin (.nvim/…) → system `lw` on PATH
---     → nvim-data cached runtime → fetch (CONSENTED) → bundled/dev (in-process)
---
--- This is a plugin-side resolution chain, DISTINCT from the launcher's
--- system-Lua precedence (headless spec §16.11) and the pin-redirect order
--- (§16.23): the launcher chooses what to *execute now*, the broker chooses what
--- daemon runtime to *drive*. An explicit `LOOMWORKS_LW` / dev opt-in stays high;
--- the bundled plugin source is the last-resort fallback.
---
--- Phase-0 scope: this module RESOLVES only — it never installs, never fetches,
--- and never spawns. "Never auto-install" (§5.2) is enforced structurally: the
--- `fetch` rung is not a resolution outcome here (it needs explicit consent, a
--- `:LoomworksProvision`-style action), so an unresolved chain falls straight
--- through to `bundled-dev`, i.e. run in-process from the plugin's own source,
--- exactly as today. Actually launching/driving a resolved runtime is Phase 1
--- (there is no daemon server to drive on mainline).

local M = {}

M.KIND = {
    env_override = "env-override",   -- LOOMWORKS_LW
    pin = "pin",                     -- repo-local lw.pin
    system = "system",               -- `lw` on PATH
    data_cache = "data-cache",       -- provisioned runtime under stdpath("data")
    bundled_dev = "bundled-dev",     -- the plugin's own source (in-process fallback)
}

--- Best-effort PATH lookup for an executable. Injectable; the default handles
--- the Windows `.exe`/`.cmd` extensions.
--- @param exe string
--- @return string|nil path
local function default_which(exe)
    local uv = vim.uv or vim.loop
    local path = (uv.os_getenv and uv.os_getenv("PATH")) or os.getenv("PATH") or ""
    local is_win = package.config:sub(1, 1) == "\\"
    local sep = is_win and ";" or ":"
    local exts = is_win and { ".exe", ".cmd", ".bat", "" } or { "" }
    for dir in (path .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        if dir ~= "" then
            for _, ext in ipairs(exts) do
                local cand = dir .. "/" .. exe .. ext
                local st = uv.fs_stat(cand)
                if st and st.type ~= "directory" then
                    return (cand:gsub("\\", "/"))
                end
            end
        end
    end
    return nil
end

--- Probe a candidate `lw` binary for its wire protocol version by invoking
--- `<path> daemon protocol`, which prints `protocol <N> (min <M>)` (spec §17.3).
--- Returns the parsed `{ version, min }`, or nil + reason when it cannot be run
--- or parsed. Synchronous and time-bounded; injectable via `opts.run`.
--- @param path string the candidate binary
--- @param opts? { run?: fun(argv:string[]):{ code:integer, stdout:string }|nil, timeout_ms?: integer }
--- @return table|nil info, string|nil err
function M.probe(path, opts)
    opts = opts or {}
    local run = opts.run
    if not run then
        run = function(argv)
            local ok, sys = pcall(function()
                return vim.system(argv, { text = true }):wait(opts.timeout_ms or 4000)
            end)
            if not ok or type(sys) ~= "table" then return nil end
            return { code = sys.code, stdout = sys.stdout or "" }
        end
    end
    local res = run({ path, "daemon", "protocol" })
    if not res or res.code ~= 0 then
        return nil, "probe did not run"
    end
    local version, min = res.stdout:match("protocol%s+(%d+)%s+%(min%s+(%d+)%)")
    if not version then
        return nil, "unrecognized protocol output"
    end
    return { version = tonumber(version), min = tonumber(min) }, nil
end

--- Resolve the runtime the daemon would be driven from.
---
--- All probes are injectable so the decision logic is unit-testable without
--- touching the real environment. Defaults wire the real sources.
---
--- @param root string workspace root (for the repo pin)
--- @param opts? {
---   getenv?: fun(name:string):string|nil,
---   pin_read?: fun(root:string):table|nil,   -- boot.pin.read shape ({ version, hashes })
---   which?: fun(exe:string):string|nil,       -- PATH lookup for `lw`
---   data_runtime?: fun():string|nil,          -- newest provisioned runtime dir, or nil
---   probe?: fun(path:string):table|nil,       -- protocol probe; nil ⇒ candidate skipped for probe
--- }
--- @return table result {
---   kind: string,          -- one of M.KIND
---   in_process: boolean,   -- true only for the bundled-dev fallback
---   path?: string,         -- resolved binary/dir when applicable
---   version?: string,      -- pinned version when kind == "pin"
---   reason: string,        -- human explanation of the choice
--- }
function M.resolve(root, opts)
    opts = opts or {}
    local getenv = opts.getenv or os.getenv
    local which = opts.which or default_which

    -- 1. Explicit override — highest precedence, a caller-owned opt-in.
    local override = getenv("LOOMWORKS_LW")
    if override ~= nil and override ~= "" then
        return {
            kind = M.KIND.env_override,
            in_process = false,
            path = override,
            reason = "LOOMWORKS_LW names the runtime binary",
        }
    end

    -- 2. Repo pin — the per-folder version authority (§16.21/§16.23).
    local pin_read = opts.pin_read
    if pin_read == nil then
        local ok, pin = pcall(require, "boot.pin")
        if ok and pin and pin.read then pin_read = pin.read end
    end
    if pin_read then
        local ok, p = pcall(pin_read, root)
        if ok and type(p) == "table" and p.version then
            return {
                kind = M.KIND.pin,
                in_process = false,
                version = p.version,
                reason = "repo lw.pin pins version " .. tostring(p.version),
            }
        end
    end

    -- 3. System `lw` on PATH, gated by the wire-protocol compatibility floor
    --    (§17.3). When a probe is supplied it is run against the candidate: a
    --    protocol OUTSIDE our supported range makes the candidate fall through
    --    (never silently driven); a probe that cannot run leaves the compat owed
    --    but still names the candidate rather than discarding it. With no probe
    --    supplied the candidate is named with the probe still owed.
    local sys = which("lw")
    if sys then
        local proto = require("loomworks.daemon.protocol")
        local probe = opts.probe
        local result = {
            kind = M.KIND.system,
            in_process = false,
            path = sys,
            reason = "system lw on PATH (" .. sys .. ")",
        }
        if probe then
            local info = probe(sys)
            if info and info.version then
                -- Compatible when the peer's version is in our range AND our
                -- version is in the peer's advertised range (symmetric, §17.3).
                local ours_ok = proto.compatible(info.version)
                local theirs_ok = (info.min == nil) or (proto.VERSION >= info.min)
                if ours_ok and theirs_ok then
                    result.protocol_version = info.version
                    return result
                end
                -- Incompatible: fall through to the next rung.
            else
                result.needs_protocol_probe = true -- probe ran but told us nothing
                return result
            end
        else
            result.needs_protocol_probe = true
            return result
        end
    end

    -- 4. A previously-provisioned runtime under stdpath("data") (§5.2). Never
    --    fetched here — only used if a prior consented install left one.
    local data_runtime = opts.data_runtime
    if data_runtime then
        local ok, dir = pcall(data_runtime)
        if ok and dir then
            return {
                kind = M.KIND.data_cache,
                in_process = false,
                path = dir,
                reason = "cached runtime under stdpath('data')",
            }
        end
    end

    -- 5. fetch (CONSENTED) — intentionally NOT a resolution outcome: the broker
    --    never triggers an install. The chain falls through.

    -- 6. Bundled/dev — the plugin's own source, run in-process. Always available,
    --    always the fallback, so the daemon is never a hard dependency (§1, §5.2).
    return {
        kind = M.KIND.bundled_dev,
        in_process = true,
        reason = "no external runtime resolved; run in-process from plugin source",
    }
end

M._default_which = default_which

return M
