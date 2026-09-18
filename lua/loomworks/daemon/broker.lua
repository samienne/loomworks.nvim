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

    -- 3. System `lw` on PATH. The wire-protocol compatibility floor (§5.3) is a
    --    Phase-1 probe (it means running the candidate); resolution names it and
    --    flags that the probe is still owed.
    local sys = which("lw")
    if sys then
        return {
            kind = M.KIND.system,
            in_process = false,
            path = sys,
            needs_protocol_probe = true,
            reason = "system lw on PATH (" .. sys .. ")",
        }
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
