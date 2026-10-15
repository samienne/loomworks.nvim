--- loomworks/daemon/command.lua — `lw daemon <sub>` (spec §19.11).
---
--- Kept out of cli.lua (which sits at Lua's 200-local limit); cli.lua passes
--- its output helpers in `host`:
---   host.out(line)     stdout line
---   host.note(line)    stderr line
---   host.die(msg, code) print `lw: <msg>` and exit (never returns)
---   host.config        lw's settings table (runtime-mode, daemon-idle-timeout)
---
--- None of these sub-commands loads the workspace.

local runtime = require("loomworks.daemon.runtime")
local inspect = require("loomworks.daemon.inspect")
local lock_record = require("loomworks.lock_record")

local M = {}

M.SUBS = { "status" }

--- The resolved runtime mode for a settings table, with a description of
--- where it came from. Reports an invalid configured value once.
--- @param host table
--- @return string mode, string source_text
function M.mode(host)
    local cfg = host.config or {}
    local mode, source, warning = runtime.resolve(cfg[runtime.SETTING])
    if warning and host.note then host.note("lw: " .. warning) end
    local src = ({ env = runtime.ENV, setting = "setting " .. runtime.SETTING, default = "default" })[source]
    return mode, src
end

local function age(secs) return lock_record.age_text(math.max(0, tonumber(secs) or 0)) end

--- `lw daemon status`: the mode, then the daemon as the runtime files describe
--- it. Never launches.
--- @param root string|nil
--- @param host table
--- @return integer
function M.status(root, host)
    local out = host.out
    local mode, src = M.mode(host)
    out(string.format("Runtime mode   %s (%s)", mode, src))
    if not root then
        out("Daemon         no loomworks workspace here")
        return 0
    end
    local st = inspect.state(root)
    local own = require("loomworks.daemon.version").identity()
    if st.kind == "none" then
        out("Daemon         not running" .. (mode == runtime.DAEMON and " (starts on the next command)" or ""))
    else
        out("Daemon         " .. inspect.row(st, mode, own))
    end
    local lk, h = st.lock, st.handle
    if lk and st.kind ~= "stale" then
        out(string.format("  holder       pid %s on %s, %s", tostring(lk.pid or "?"), tostring(lk.host or "?"),
            tostring(lk.mode or lk.kind or "?")))
        out("  heartbeat    " .. age(lk.age) .. " ago")
    end
    if h and h.valid and (st.kind == "live" or st.kind == "hung" or st.kind == "foreign") then
        local sch = type(h.schemas) == "table" and h.schemas or {}
        out(string.format("  version      %s (protocol %s, schemas user %s / cache %s)", tostring(h.lw_version or "?"),
            tostring(h.protocol), tostring(sch.user or "?"), tostring(sch.cache or "?")))
        out("  endpoint     " .. tostring(h.endpoint))
        if type(h.started_at) == "number" then out("  started      " .. age(os.time() - h.started_at) .. " ago") end
    end
    return 0
end

--- Dispatch `lw daemon [<sub>]`.
--- @param sub string|nil
--- @param root string|nil
--- @param args string[]
--- @param host table
--- @return integer
function M.run(sub, root, args, host)
    sub = sub or "status"
    if sub == "status" then return M.status(root, host) end
    host.die("unknown daemon subcommand '" .. tostring(sub) .. "' — use " .. table.concat(M.SUBS, "|")
        .. " (see `lw help daemon`)", 2)
    return 2
end

return M
