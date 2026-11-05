--- loomworks/lsp_source.lua — where the editor's LSP layer reads the LSP
--- configuration state (spec §9.2 "Where the entries come from", daemon.md
--- §19.16 "LSP configuration"). loomworks/lsp.lua and the server
--- integrations read projects, entries, options and readiness only through
--- this module, never from the workspace model.
---
--- The source is **only** the workspace daemon the editor observes: its
--- `LspConfig/1.get` state, cached per connection by the observer
--- (loomworks.daemon.observer `lsp_phase`). It is **in use** while the last
--- read answered `loaded`; otherwise the editor is **waiting** for it
--- (connecting, the daemon's workspace `unloaded`, or unloaded by a lost
--- connection — the §9.7 hold with no timeout) or it is **unavailable** (no
--- host binary, the interface not carried, a declined or failed read, a state
--- `error` / `refused` — the buffers are withheld). Without an observer
--- nothing is loaded: a root set but not observed yet is pending. There is no
--- fallback: the state is never built in the editor.

local lsp_config = require("loomworks.lsp_config")

local M = {}

--- Test seam: the facade to read instead of `require("loomworks")`.
--- @type table|nil
M._facade = nil

--- The loomworks facade, or nil when it cannot be loaded.
--- @return table|nil
local function facade()
    if M._facade then return M._facade end
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw) ~= "table" then return nil end
    return lw
end

--- The editor's observer of the workspace daemon, or nil. Never loads the
--- daemon modules.
--- @return loomworks.daemon.Observer|nil
local function observer()
    local mod = package.loaded["loomworks.daemon.observer"]
    if type(mod) ~= "table" or type(mod.current) ~= "function" then return nil end
    return mod.current()
end

--- "daemon" while the editor observes a workspace daemon (the LSP state's
--- only source), else "detached" (nothing loaded).
--- @return "daemon"|"detached"
function M.mode()
    return observer() and "daemon" or "detached"
end

--- Where the daemon's LSP state stands (daemon mode; loomworks.daemon.observer
--- `lsp_phase`): "loaded" with the state (in use), "waiting" with
--- `{ why }`, "unavailable" with `{ kind, note }`. nil while detached.
--- @return "loaded"|"waiting"|"unavailable"|nil phase
--- @return table|nil detail
function M.daemon_phase()
    local obs = observer()
    if not obs then return nil, nil end
    return obs:lsp_phase()
end

--- The daemon's state while it is in use, else nil.
--- @return loomworks.LspConfigState|nil
local function daemon_state()
    local phase, st = M.daemon_phase()
    if phase == "loaded" and type(st) == "table" then return st end
    return nil
end

--- Whether the daemon's state is in use (§19.16 "LSP configuration").
--- @return boolean
function M.in_use()
    return daemon_state() ~= nil
end

--- Whether the editor waits for the daemon (daemon mode: connecting, its
--- workspace `unloaded`, or unloaded by a lost connection) — buffers under
--- the root stay held with no safety timeout (§9.7).
--- @return boolean
function M.waiting()
    return (M.daemon_phase()) == "waiting"
end

--- Whether a workspace is loaded AND the active profile's owned LSP
--- databases are ready (§9.7): the daemon's state in use and `ready`.
--- @return boolean
function M.loaded_and_ready()
    local st = daemon_state()
    return st ~= nil and st.ready == true
end

--- Whether the facade can be loaded at all (never false in practice).
--- @return boolean
function M.available()
    return facade() ~= nil
end

--- Whether a workspace is loaded: the daemon's state in use.
--- @return boolean
function M.loaded()
    return daemon_state() ~= nil
end

--- Whether a workspace load is pending: a root is set but not observed yet,
--- or the editor waits for the daemon or for its `ready`.
--- @return boolean
function M.pending()
    local phase, st = M.daemon_phase()
    if phase then
        return phase == "waiting" or (phase == "loaded" and type(st) == "table" and st.ready ~= true)
    end
    local lw = facade()
    return lw ~= nil and type(lw.workspace_root) == "function" and lw.workspace_root() ~= nil
end

--- The observed workspace's root, or nil.
--- @return string|nil
function M.root()
    local obs = observer()
    return obs and obs.root or nil
end

--- The whole state (the §19.20 `LspConfig/1.get` shape): the daemon's while
--- in use, else an empty `unloaded` one — never built in the editor.
--- @return loomworks.LspConfigState
function M.state()
    return daemon_state() or { state = "unloaded", ready = false, projects = {}, options = {} }
end

--- The project records in ascending key order (empty while the daemon's
--- state is not in use).
--- @return loomworks.LspConfigProject[]
function M.projects()
    local st = daemon_state()
    return st and type(st.projects) == "table" and st.projects or {}
end

--- The record of the project a buffer belongs to, or nil: the record whose
--- key is `lw.buf_project`'s (§19.13: the separator-bounded longest prefix,
--- so a project at `/a/foo` never claims a buffer in `/a/foobar`), in both
--- modes and with no other rule (§19.16 "LSP configuration" Buffer →
--- project).
--- @param bufnr integer
--- @return loomworks.LspConfigProject|nil
function M.project_for_buf(bufnr)
    local lw = facade()
    if not lw or type(lw.buf_project) ~= "function" then return nil end
    local hit = lw.buf_project(bufnr)
    local key = type(hit) == "table" and hit.key or nil
    if key == nil then return nil end
    for _, rec in ipairs(M.projects()) do
        if rec.project == key then return rec end
    end
    return nil
end

--- The record and entry of `server` whose `root_dir` is `root_dir`.
--- @param server string
--- @param root_dir string|nil
--- @return loomworks.LspConfigProject|nil record, loomworks.LspStateEntry|nil entry
function M.find_by_root(server, root_dir)
    if not root_dir then return nil, nil end
    local normalize = vim.fs.normalize
    local target = normalize(root_dir)
    for _, rec in ipairs(M.projects()) do
        local entry = lsp_config.entry(rec, server)
        if entry and entry.root_dir and normalize(entry.root_dir) == target then
            return rec, entry
        end
    end
    return nil, nil
end

--- A project's module type (for display), from the daemon's project index
--- (loomworks.views), or nil.
--- @param key string
--- @return string|nil
function M.project_type(key)
    if not observer() then return nil end
    local index = require("loomworks.views").projects_index()
    for _, rec in ipairs(type(index) == "table" and type(index.projects) == "table" and index.projects or {}) do
        if rec.key == key then return rec.type end
    end
    return nil
end

--- A server's options with defaults applied: the daemon's while its state is
--- in use, else nil (the integration then uses its own defaults).
--- @param server string
--- @return table|nil
function M.options(server)
    local st = daemon_state()
    local opts = st and type(st.options) == "table" and st.options[server] or nil
    return type(opts) == "table" and opts or nil
end

--- Write a per-server option in daemon mode (§19.16 "LSP configuration"
--- Options): **only** through `LspConfig/1.set_option`
--- (loomworks.daemon.editor_ops `set_lsp_option`), applied from the state
--- read back. Not carried, refused, failed or unanswered is an error
--- (notified) and nothing is written. `cb(ok, err)` on the main loop.
--- @param server string
--- @param key string
--- @param value any nil removes the key
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean sent false (with the error, `cb` called) when it failed at once
--- @return string|nil err
function M.set_option(server, key, value, cb)
    return require("loomworks.daemon.editor_ops").set_lsp_option(nil, server, key, value, cb)
end

-- ---------------------------------------------------------------------------
-- What changed (the LSP layer's re-evaluation, §9.8 / §19.16 Re-evaluation)
-- ---------------------------------------------------------------------------

--- The snapshot of the daemon's state at the last `changes()`; `options`
--- are the last options in use (kept while the state is not in use: a
--- client started from them keeps running).
--- @type { owner: table|nil, phase: string|nil, why: string|nil, sig: string|nil, revs: table|nil, options: table|nil }|nil
local _last = nil

--- An entry signature without what does not configure a server: `db_rev`
--- (a database write is its own signal) and the opaque ids.
--- @param recs loomworks.LspConfigProject[]
--- @return string
local function entries_signature(recs)
    local out = {}
    for i, rec in ipairs(type(recs) == "table" and recs or {}) do
        local entries = {}
        for j, e in ipairs(type(rec.entries) == "table" and rec.entries or {}) do
            local c = {}
            if type(e) == "table" then
                for k, v in pairs(e) do
                    if k ~= "db_rev" then c[k] = v end
                end
            end
            entries[j] = c
        end
        out[i] = { project = rec.project, path = rec.path, entries = entries }
    end
    return lsp_config.signature({ projects = out })
end

--- The highest `db_rev` per `db_dir` (normalized) of a state's entries.
--- @param recs loomworks.LspConfigProject[]
--- @return table<string, { rev: integer, dir: string }>
local function revs_of(recs)
    local out = {}
    for _, rec in ipairs(type(recs) == "table" and recs or {}) do
        for _, e in ipairs(type(rec.entries) == "table" and rec.entries or {}) do
            if type(e) == "table" and type(e.db_dir) == "string" and type(e.db_rev) == "number" then
                local d = lsp_config.norm(e.db_dir)
                if not out[d] or e.db_rev > out[d].rev then out[d] = { rev = e.db_rev, dir = e.db_dir } end
            end
        end
    end
    return out
end

--- The per-key option changes from `before` to `now`, as the
--- `lsp_options_changed` payloads `{ server, key, value }`.
--- @param before table<string, table>
--- @param now table<string, table>
--- @return { server: string, key: string, value: any }[]
local function option_changes(before, now)
    local out = {}
    local servers = {}
    for s in pairs(before) do servers[s] = true end
    for s in pairs(now) do servers[s] = true end
    local names = vim.tbl_keys(servers)
    table.sort(names)
    for _, s in ipairs(names) do
        local a = type(before[s]) == "table" and before[s] or {}
        local b = type(now[s]) == "table" and now[s] or {}
        local keys = {}
        for k in pairs(a) do keys[k] = true end
        for k in pairs(b) do keys[k] = true end
        local knames = vim.tbl_keys(keys)
        table.sort(knames)
        for _, k in ipairs(knames) do
            if not vim.deep_equal(a[k], b[k]) then
                out[#out + 1] = { server = s, key = k, value = b[k] }
            end
        end
    end
    return out
end

--- What changed in the daemon's LSP state since the last call (the
--- observer's `daemon_lsp_config`; nothing while detached): `switched` — the state started or stopped being in
--- use, or moved between waiting and unavailable; `entries` — the entries in
--- use differ (other than `db_rev`); `written` — the `db_dir`s whose `db_rev`
--- rose (an owned database the daemon wrote); `options` — the options in use
--- that differ from the last ones in use, one `{ server, key, value }` per
--- key (none on the first state in use: no client was started from earlier
--- ones); `lost` — the connection was just lost (§19.16 "Unloaded on
--- disconnect": the controlled clients are stopped).
--- @return { switched: boolean, entries: boolean, written: string[], options: { server: string, key: string, value: any }[], lost: boolean }
function M.changes()
    -- (What the state belongs to: the observer — a new one for another root.)
    local owner = observer()
    local phase, detail = M.daemon_phase()
    local ch = { switched = false, entries = false, written = {}, options = {}, lost = false }
    local prev = _last
    if prev and prev.owner ~= owner then prev = nil end
    local cur = { owner = owner, phase = phase, options = prev and prev.options or nil }
    if phase == "waiting" and type(detail) == "table" then cur.why = detail.why end
    if phase == "loaded" and type(detail) == "table" then
        cur.sig = entries_signature(detail.projects)
        cur.revs = revs_of(detail.projects)
        cur.options = type(detail.options) == "table" and detail.options or {}
    end
    _last = cur
    if not phase then return ch end
    ch.lost = cur.why == "disconnected" and not (prev and prev.why == "disconnected")
    if not prev then
        ch.switched = phase == "loaded"
        return ch
    end
    ch.switched = prev.phase ~= phase
    if phase == "loaded" then
        if prev.phase == "loaded" then
            ch.entries = prev.sig ~= cur.sig
            for d, now in pairs(cur.revs) do
                local before = prev.revs[d]
                if before and now.rev > before.rev then ch.written[#ch.written + 1] = now.dir end
            end
            table.sort(ch.written)
        end
        if prev.options then ch.options = option_changes(prev.options, cur.options) end
    end
    return ch
end

--- Test seam: forget the last snapshot.
function M._reset_changes() _last = nil end

return M
