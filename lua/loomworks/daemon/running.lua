--- loomworks/daemon/running.lua — the running-task lines under `lw status`'s
--- Runtime row (spec §19.6 "Running tasks").
---
--- Only a daemon the handle shows live, on this host, busy and with this lw's
--- `key_id` is asked — an idle daemon is never contacted, and none is ever
--- launched. The query is one `status` request (frozen control subset, so it
--- works across a version mismatch; never a `retire`), bounded at about a
--- second. Nothing here changes `lw status`'s exit status: a failed query is
--- one line.

local M = {}

--- The bound of the whole query (connect + `status`), milliseconds.
M.TIMEOUT_MS = 1000

--- Should `lw status` ask the daemon of `st` (from loomworks.daemon.inspect)?
--- @param st table
--- @param own_key_id string|false|nil this lw's key id
--- @return boolean
function M.should_query(st, own_key_id)
    if not st or st.kind ~= "live" then return false end
    local h = st.handle or {}
    if not h.valid or not h.busy or type(h.endpoint) ~= "string" then return false end
    if type(h.key_id) ~= "string" or not own_key_id or h.key_id ~= own_key_id then return false end
    return true
end

--- Ask the daemon for its `status` (bounded). Returns the reply, or nil + a
--- reason.
--- @param endpoint string
--- @param opts? { timeout_ms?: integer, client?: table }
--- @return table|nil reply, string|nil reason
function M.query(endpoint, opts)
    opts = opts or {}
    local client = opts.client or require("loomworks.daemon.client")
    local timeout = opts.timeout_ms or M.TIMEOUT_MS
    local uv = vim.uv or vim.loop
    local t0 = uv.hrtime()
    local conn, err, detail = client.session(endpoint, { client = "cli", timeout_ms = timeout })
    if not conn then return nil, tostring(err) .. (detail and (": " .. tostring(detail)) or "") end
    local left = math.max(1, timeout - math.floor((uv.hrtime() - t0) / 1e6))
    local reply, rerr = client.request(conn, { kind = "status" }, left)
    local info = conn.challenge
    conn:close()
    if not reply then return nil, tostring(rerr) end
    reply._lw_version = info and info.lw_version
    return reply
end

local function elapsed_text(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    if secs < 60 then return secs .. "s" end
    local m = math.floor(secs / 60)
    if m < 60 then return string.format("%dm%02ds", m, secs % 60) end
    return string.format("%dh%02dm", math.floor(m / 60), m % 60)
end
M.elapsed_text = elapsed_text

--- The origin as shown: `lw` for the CLI, `editor`.
--- @param origin any
--- @return string
local function origin_text(origin)
    if origin == "cli" then return "lw" end
    if origin == "editor" then return "editor" end
    return "?"
end

--- One line per running task of a `status` reply: the operation, the
--- profile, the origin, the elapsed time and the percent when known. A reply
--- without `tasks` (an older daemon) is one line.
--- @param reply table
--- @param now? integer os.time()
--- @return string[]
function M.format(reply, now)
    if type(reply.tasks) ~= "table" then
        return { "  running tasks: not reported by daemon lw "
            .. tostring(reply._lw_version or reply.lw_version or "?") }
    end
    now = now or os.time()
    local rows, wk, wp, wo = {}, 0, 0, 0
    for _, t in ipairs(reply.tasks) do
        if type(t) == "table" then
            local r = {
                kind = tostring(t.kind or "?"),
                -- (A workspace-wide task, `lw reset --all`, has no profile.)
                profile = tostring(t.profile or (t.scope == "all" and "--all") or t.name or "?"),
                origin = "(" .. origin_text(t.origin) .. ")",
                elapsed = tonumber(t.started_at) and elapsed_text(now - tonumber(t.started_at)) or "",
                pct = tonumber(t.percent) and (math.floor(tonumber(t.percent)) .. "%") or nil,
            }
            wk, wp, wo = math.max(wk, #r.kind), math.max(wp, #r.profile), math.max(wo, #r.origin)
            rows[#rows + 1] = r
        end
    end
    local out = {}
    for _, r in ipairs(rows) do
        local line = string.format("  %-" .. wk .. "s  %-" .. wp .. "s  %-" .. wo .. "s  %s",
            r.kind, r.profile, r.origin, r.elapsed)
        if r.pct then line = line .. "  " .. r.pct end
        out[#out + 1] = (line:gsub("%s+$", ""))
    end
    return out
end

--- The running-task lines for `lw status` under the Runtime row (empty when
--- the daemon is not asked or runs nothing), and the `status` reply they came
--- from (nil when the daemon was not asked or did not answer), so `lw status`
--- can also show those tasks' profiles running (spec §16.18).
--- @param root string
--- @param opts? { state?: table, own_key_id?: string|false, query?: fun(endpoint: string): table|nil, string|nil, now?: integer }
--- @return string[] lines, table|nil reply
function M.lines(root, opts)
    opts = opts or {}
    local st = opts.state or require("loomworks.daemon.inspect").state(root)
    local own = opts.own_key_id
    if own == nil then
        local ok, k = pcall(function() return require("loomworks.daemon.auth").own_key_id() end)
        own = ok and k or false
    end
    if not M.should_query(st, own) then return {} end
    local query = opts.query or M.query
    local ok, reply, why = pcall(query, st.handle.endpoint)
    if not ok then reply, why = nil, tostring(reply) end
    if not reply then return { "  running tasks: unavailable (" .. tostring(why or "no reply") .. ")" } end
    if not reply._lw_version then reply._lw_version = st.handle.lw_version end
    return M.format(reply, opts.now), reply
end

return M
