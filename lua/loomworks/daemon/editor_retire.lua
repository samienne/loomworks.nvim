--- loomworks/daemon/editor_retire.lua — the editor's retirement of an
--- incompatible idle daemon (spec §19.16 "Retiring an incompatible daemon",
--- §19.9 "Editor retirement", step 5h.5): the pure decisions. The observer
--- (loomworks.daemon.observer) does the I/O: it asks the daemon's `status`,
--- sends `retire` (never `stop`) and relaunches once through its "Retiring"
--- path.
---
--- * `incompatibility` — is a connected daemon incompatible with the editor?
---   No transport overlap, schemas that differ from ours (older: it cannot
---   read the editor's files; newer: refused, never retired), or, on a
---   transport-11 connection, no `loomworks.Root/1` (a protocol-10 daemon
---   offers no interfaces and is judged by version and schemas only); older
---   schemas alone leave it observable. The same problem sort as
---   the pre-launch probe (loomworks.provision.needs `problems`, with
---   `exact_schemas`). A missing feature interface only degrades that
---   feature and is never a reason to retire.
--- * `selected` — did the binary the editor selected pass the interface check
---   (the probe's *compatible* verdict, or the plugin-managed lw), and which
---   `lw_version` is it?
--- * the session guard — a daemon of a given `lw_version` is retired at most
---   once per workspace per editor session (a repository pin that redirects
---   every launch to the same incompatible release would otherwise loop).

local M = {}

--- @class loomworks.daemon.Incompatibility  why a connected daemon is incompatible with the editor
--- @field reasons string[] one line each (transport, schemas, root interface)
--- @field newer boolean its schemas are newer than ours: refused, never retired (§19.9)
--- @field observable boolean only its schemas are older (transports overlap, root interface present): observed while it is weighed for a retirement, and when the editor declines to retire it (§19.16)

--- Is the daemon behind `conn` incompatible with the editor (spec §19.16
--- "Retiring an incompatible daemon")? nil when it is compatible. The root
--- interface is weighed only on a transport-11 connection whose welcome
--- lists objects — the observer's own test for observing through
--- interfaces; over transport 10 a daemon offers none and is observed
--- through the protocol-10 broadcasts.
--- @param ch table the daemon's challenge { protocol, protocol_min, lw_version, schemas }
--- @param conn table the connection { transport, welcome = { objects } }
--- @return loomworks.daemon.Incompatibility|nil
function M.incompatibility(ch, conn)
    ch = type(ch) == "table" and ch or {}
    local welcome = type(conn) == "table" and conn.welcome or nil
    local objects = type(welcome) == "table" and welcome.objects or nil
    local interfaces = type(conn) == "table" and type(conn.transport) == "number" and conn.transport >= 11
        and type(objects) == "table"
    local d = { descriptor = 1, transport = { min = ch.protocol_min, max = ch.protocol },
        schemas = ch.schemas, objects = objects }
    local p = require("loomworks.provision.needs").problems(d, { exact_schemas = true, interfaces = interfaces })
    local reasons = {}
    for _, list in ipairs({ p.structure, p.fatal }) do
        for _, line in ipairs(list) do reasons[#reasons + 1] = line end
    end
    if #reasons == 0 then return nil end
    local version = require("loomworks.daemon.version")
    -- Observable: the transports overlap and the only problem is older
    -- schemas (no missing root interface) — the editor observes it while
    -- it waits to retire it, and for good when it declines to.
    local without_root = interfaces
        and require("loomworks.provision.needs").problems(d, { exact_schemas = true, interfaces = false }) or p
    local root_ok = #without_root.structure + #without_root.fatal == #reasons
    return { reasons = reasons, newer = version.peer_schemas_newer(ch),
        observable = root_ok and (version.observer_compatible(ch)) == true }
end

--- @class loomworks.daemon.SelectedBinary  the editor's selected binary, weighed for a retirement
--- @field ok boolean it passed the interface check (compatible verdict, or the managed lw)
--- @field version string|nil its `lw_version` (when ok)
--- @field path string|nil the binary
--- @field pending string|nil a PATH or explicit lw still to be probed (no cached verdict yet)
--- @field why string|nil why it is not usable for a retirement

--- The selected binary, weighed (spec §19.16: "the binary the editor selected
--- passed the interface check (the probe's compatible verdict, or the
--- managed lw)"). `opts.wanted` replaces loomworks.provision.managed.wanted
--- (tests); `opts.setting` (the setup option `binary`) lets it weigh
--- `binary.channel` (the managed lw may be an accepted channel release).
--- @param sel loomworks.provision.Selection|nil
--- @param opts? { wanted?: fun(): loomworks.provision.Wanted|nil, setting?: loomworks.provision.BinarySetting }
--- @return loomworks.daemon.SelectedBinary
function M.selected(sel, opts)
    opts = opts or {}
    if type(sel) ~= "table" then return { ok = false, why = "no host binary selected" } end
    if sel.env and sel.env.LOOMWORKS_LUA then
        -- binary.source (development): the binary runs another Lua tree, so
        -- its version is not the one any check vouched for.
        return { ok = false, path = sel.path, why = "binary.source is set (development)" }
    end
    if type(sel.download) == "table" then
        return { ok = type(sel.download.version) == "string", version = sel.download.version,
            why = type(sel.download.version) ~= "string" and "the plugin-managed lw has no version" or nil }
    end
    if not sel.path then return { ok = false, why = "no host binary selected" } end
    if sel.probe then return { ok = false, path = sel.path, pending = sel.probe } end
    local chosen
    for _, c in ipairs(sel.candidates or {}) do
        if c.verdict == "chosen" then chosen = c end
    end
    if sel.source == "managed" then
        local w
        if opts.wanted then w = opts.wanted()
        else w = require("loomworks.provision.managed").wanted({ setting = opts.setting }) end
        if type(w) ~= "table" or type(w.version) ~= "string" then
            return { ok = false, path = sel.path, why = "the plugin pin names no version" }
        end
        return { ok = true, path = sel.path, version = w.version }
    end
    local v = chosen and chosen.probe
    if not v then return { ok = false, path = sel.path, why = sel.path .. " was not probed" } end
    if v.verdict ~= "compatible" then
        return { ok = false, path = sel.path, why = sel.path .. " is " .. tostring(v.verdict) }
    end
    if type(v.version) ~= "string" then
        return { ok = false, path = sel.path, why = sel.path .. " names no lw version" }
    end
    return { ok = true, path = sel.path, version = v.version }
end

--- A version without a leading `v`.
local function bare(v) return (tostring(v or ""):gsub("^v", "")) end

--- Do two `lw_version`s name the same release?
--- @param a string|nil
--- @param b string|nil
--- @return boolean
function M.same_version(a, b) return bare(a) == bare(b) end

-- The session guard: workspace root -> lw_version -> { failed? }. Module
-- state, so it outlives a workspace reload (a new observer) for this editor
-- session. `failed`: the retirement was attempted and did not happen (an
-- error reply, or no reply); it is still never retried.
local retired = {}

local function root_key(root)
    -- Every spelling of one workspace is one key (a link, a Windows 8.3 short
    -- name, a different case).
    local r = tostring(root or "")
    local real = r ~= "" and (vim.uv or vim.loop).fs_realpath(r) or nil
    r = vim.fs.normalize(real or r)
    if vim.fn.has("win32") == 1 then r = r:lower() end
    return r
end

--- The guard's key for `root` and `lw_version`: "<normalized realpath of the root>\n<version>".
--- @param root string
--- @param lw_version string|nil
--- @return string
function M.key(root, lw_version) return root_key(root) .. "\n" .. bare(lw_version) end

--- Has the editor already retired (or tried to retire) a daemon of
--- `lw_version` for `root` in this session?
--- @param root string
--- @param lw_version string|nil
--- @return boolean
function M.was_retired(root, lw_version) return retired[M.key(root, lw_version)] ~= nil end

--- Did the recorded retirement of a daemon of `lw_version` for `root` fail
--- (an error reply to `retire`, or none)?
--- @param root string
--- @param lw_version string|nil
--- @return boolean
function M.retire_failed(root, lw_version)
    local e = retired[M.key(root, lw_version)]
    return e ~= nil and e.failed == true
end

--- Record a retirement (before `retire` is sent).
--- @param root string
--- @param lw_version string|nil
function M.record(root, lw_version) retired[M.key(root, lw_version)] = {} end

--- Record that the retirement recorded for `root` and `lw_version` failed.
--- It stays recorded: the editor does not try again this session.
--- @param root string
--- @param lw_version string|nil
function M.record_failed(root, lw_version) retired[M.key(root, lw_version)] = { failed = true } end

--- Forget every recorded retirement (tests).
function M.reset() retired = {} end

--- Is a daemon whose `status` reply is `st` busy (§19.9 "Busy")? No reply
--- counts as busy. The editor asks over its observer connection, so a daemon
--- without `busy_clients` counts it among the observers, not twice.
--- @param st table|nil
--- @return boolean
function M.busy(st) return require("loomworks.daemon.protocol").status_busy(st, { asker_observer = true }) end

--- The Runtime note for an incompatible daemon: what the daemon runs, why,
--- and the tail (what the editor does about it).
--- @param ch table the daemon's challenge
--- @param inc loomworks.daemon.Incompatibility
--- @param binary string|nil the daemon's binary (its handle's `exe`)
--- @param tail string
--- @return string
function M.note(ch, inc, binary, tail)
    return string.format("the workspace daemon runs lw v%s%s, which is incompatible with this plugin (%s) — %s",
        bare(ch and ch.lw_version), binary and (" at " .. binary) or "", table.concat(inc.reasons, "; "), tail)
end

return M
