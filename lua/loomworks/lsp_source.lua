--- loomworks/lsp_source.lua — where the editor's LSP layer reads the LSP
--- configuration state (spec §9.2 "Where the entries come from", daemon.md
--- §19.16 "LSP configuration"). loomworks/lsp.lua and the server
--- integrations read projects, entries, options and readiness only through
--- this module, never from the workspace model.
---
--- Two sources, one shape (as §19.13): the workspace daemon's
--- `LspConfig/1.get` state while it is **in use** (daemon runtime mode, the
--- interface carried and the last read answered `loaded`; the editor's
--- observer caches it per connection, loomworks.daemon.observer
--- `lsp_phase`), otherwise the state loomworks/lsp_config.lua builds from the
--- editor's own model, reached through the `loomworks` facade. While the
--- observer is still connecting or the daemon has not loaded the workspace,
--- the §9.7 hold waits for it (`holding`), bounded by the gate's safety
--- timeout (`hold_timed_out`).

local lsp_config = require("loomworks.lsp_config")

local M = {}

--- Test seam: the facade to read instead of `require("loomworks")` (a test
--- holding a daemon and an editor model in one process points it at the
--- editor's).
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

--- The in-process workspace model (the one place the LSP layer touches it).
--- @param lw table|nil
--- @return loomworks.Workspace|nil
local function model(lw)
    if not lw or type(lw.get_workspace) ~= "function" then return nil end
    return lw.get_workspace()
end

--- The in-process projects, as the facade lists them.
--- @param lw table
--- @return table<any, loomworks.Project>
local function projects(lw)
    return type(lw.get_projects) == "function" and lw.get_projects() or {}
end

--- The editor's observer of `ws`'s workspace daemon (daemon runtime mode),
--- or nil. Never loads the daemon modules: in in-process mode they are not
--- loaded and there is none.
--- @param ws loomworks.Workspace|nil
--- @return loomworks.daemon.Observer|nil
local function observer_of(ws)
    local mod = package.loaded["loomworks.daemon.observer"]
    if not ws or type(mod) ~= "table" or type(mod.of) ~= "function" then return nil end
    local obs = mod.of(ws)
    if obs and obs.state ~= "stopped" then return obs end
    return nil
end

--- @param phase string
--- @return boolean
local function holding_phase(phase)
    return phase == "connecting" or phase == "unloaded"
end

--- Where the LSP state comes from now (loomworks.daemon.observer
--- `lsp_phase`): "loaded" (the daemon's, in use, with its state), "connecting"
--- / "unloaded" (holding for the daemon), "declined" / "inproc" / "none" (the
--- in-process state). "none" in in-process mode.
--- @return string phase
--- @return loomworks.LspConfigState|nil state the daemon's, when in use
function M.phase()
    local obs = observer_of(model(facade()))
    if not obs then return "none", nil end
    return obs:lsp_phase()
end

--- The daemon's state while it is in use, else nil.
--- @return loomworks.LspConfigState|nil
local function daemon_state()
    local phase, st = M.phase()
    if phase == "loaded" and type(st) == "table" then return st end
    return nil
end

--- Whether the daemon's state is in use (§19.16 "LSP configuration").
--- @return boolean
function M.in_use()
    return daemon_state() ~= nil
end

--- Whether the §9.7 hold waits for the daemon: connecting, its workspace
--- not loaded yet, or its state in use but not `ready`.
--- @return boolean
function M.holding()
    local phase, st = M.phase()
    if holding_phase(phase) then return true end
    return phase == "loaded" and type(st) == "table" and st.ready ~= true
end

--- The §9.7 hold's safety timeout fired: while still holding for the daemon
--- (connecting or `unloaded`), the in-process state from now on, until the
--- daemon reports `loaded` (§19.16 "LSP configuration" Readiness).
function M.hold_timed_out()
    local obs = observer_of(model(facade()))
    if obs then obs:lsp_hold_timed_out() end
end

--- Whether the facade can be loaded at all (never false in practice).
--- @return boolean
function M.available()
    return facade() ~= nil
end

--- Whether a workspace is loaded.
--- @return boolean
function M.loaded()
    if daemon_state() then return true end
    return model(facade()) ~= nil
end

--- Whether a LOADED workspace exists AND the active profile's owned LSP
--- databases are ready (§9.7): the daemon's `ready` while its state is in
--- use, never while holding for it, else the in-process readiness. Before
--- any workspace is loaded readiness alone reports ready-to-resolve, but a
--- buffer of a workspace must still be held — so this requires a loaded
--- workspace. True when the facade has no workspace notion at all.
--- @return boolean
function M.loaded_and_ready()
    local lw = facade()
    if not lw or type(lw.get_workspace) ~= "function" then return true end
    local ws = model(lw)
    if not ws then return false end
    local obs = observer_of(ws)
    if obs then
        local phase, st = obs:lsp_phase()
        if phase == "loaded" and type(st) == "table" then return st.ready == true end
        if holding_phase(phase) then return false end
    end
    return type(lw.lsp_ready) == "function" and lw.lsp_ready() == true
end

--- Whether a workspace load is pending: readiness is not reported (the
--- facade reports ready-to-resolve when nothing is pending, §9.7), or the
--- LSP layer holds for the daemon.
--- @return boolean
function M.pending()
    local lw = facade()
    if not lw or type(lw.lsp_ready) ~= "function" then return false end
    if holding_phase((M.phase())) then return true end
    return lw.lsp_ready() ~= true
end

--- The loaded workspace's root, or nil.
--- @return string|nil
function M.root()
    local ws = model(facade())
    return ws and ws.root or nil
end

--- The whole state (the §19.20 `LspConfig/1.get` shape).
--- @return loomworks.LspConfigState
function M.state()
    local st = daemon_state()
    if st then return st end
    local lw = facade()
    local ws = model(lw)
    if not ws then
        local err = lw and type(lw.get_setup_error) == "function" and lw.get_setup_error() or nil
        return lsp_config.state(nil, { state = err and "error" or "unloaded" })
    end
    return lsp_config.state(ws, { projects = projects(lw) })
end

--- The project records in ascending key order (empty when nothing is loaded).
--- @return loomworks.LspConfigProject[]
function M.projects()
    local st = daemon_state()
    if st then return type(st.projects) == "table" and st.projects or {} end
    local lw = facade()
    local ws = model(lw)
    if not ws then return {} end
    return lsp_config.project_records(ws, projects(lw))
end

--- `p` joined onto `root` as `loomworks.view.ProjectsIndex/1` joins a
--- record's `abs_path` (`.` or empty: the root itself).
--- @param root string
--- @param p string|nil
--- @return string
local function join(root, p)
    root = (tostring(root):gsub("\\", "/"):gsub("/+$", ""))
    p = (tostring(p or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", ""))
    if p == "" or p == "." then return root end
    return root .. "/" .. p
end

--- The record of the project a buffer belongs to, or nil. The buffer's
--- project is `lw.buf_project`'s (§19.13: the separator-bounded longest
--- prefix, so a project at `/a/foo` never claims a buffer in `/a/foobar`),
--- in both modes (§19.16 "LSP configuration" Buffer → project). One case
--- applies its rule (loomworks.views `match`) to the LSP records instead:
--- the in-process state in use while the project index is the daemon's (a
--- fallback row whose daemon may not have loaded the workspace, an index
--- with no projects).
--- @param bufnr integer
--- @return loomworks.LspConfigProject|nil
function M.project_for_buf(bufnr)
    local lw = facade()
    if not lw then return nil end
    local recs = M.projects()
    local key = nil
    local views = package.loaded["loomworks.views"]
    if not M.in_use() and type(views) == "table" and views.source and views.source("projects") == "daemon" then
        local root = M.root()
        if not root then return nil end
        local index = { projects = {} }
        for i, rec in ipairs(recs) do
            index.projects[i] = { key = rec.project, abs_path = join(root, rec.path or rec.project) }
        end
        local hit = views.match(index, vim.api.nvim_buf_get_name(bufnr))
        key = hit and hit.key
    elseif type(lw.buf_project) == "function" then
        local hit = lw.buf_project(bufnr)
        key = type(hit) == "table" and hit.key or nil
    end
    if key == nil then return nil end
    for _, rec in ipairs(recs) do
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

--- A project's module type (for display), or nil.
--- @param key string
--- @return string|nil
function M.project_type(key)
    local lw = facade()
    if not lw then return nil end
    for _, p in pairs(projects(lw)) do
        if p.key == key then return p.type end
    end
    return nil
end

--- A server's options with defaults applied, or nil when the source offers
--- none (the integration then uses its own defaults).
--- @param server string
--- @return table|nil
function M.options(server)
    local st = daemon_state()
    if st then
        local opts = type(st.options) == "table" and st.options[server] or nil
        return type(opts) == "table" and opts or nil
    end
    local lw = facade()
    if not lw or type(lw.get_lsp_options) ~= "function" then return nil end
    return lw.get_lsp_options(server)
end

--- Write a per-server option through the daemon while it carries the LSP
--- configuration (§19.16 "LSP configuration" Options: `LspConfig/1.set_option`,
--- applied from the state read back). Returns false — nothing done — when it
--- does not: the caller writes it in-process. `cb(ok, err)` on the main loop.
--- @param server string
--- @param key string
--- @param value any nil removes the key
--- @param cb? fun(ok: boolean, err: string|nil)
--- @return boolean routed
function M.set_option_routed(server, key, value, cb)
    local ws = model(facade())
    local obs = observer_of(ws)
    if not (obs and obs:can_call("set_option")) then return false end
    require("loomworks.daemon.editor_ops").set_lsp_option(ws, server, key, value, cb)
    return true
end

-- ---------------------------------------------------------------------------
-- What changed (the LSP layer's re-evaluation, §9.8 / §19.16 Re-evaluation)
-- ---------------------------------------------------------------------------

--- The snapshot of the state in use at the last `changes()`.
--- @type { ws: table|nil, src: "daemon"|"hold"|"inproc", sig: string|nil, revs: table<string, integer>|nil, options: table|nil }|nil
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
--- @return table<string, integer>
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

--- The in-process options of every server the model has options for.
--- @param ws table|nil
--- @return table<string, table>
local function inproc_options(ws)
    return ws and lsp_config.options(ws) or {}
end

--- The per-key option changes from `before` to `now`, as the in-process
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

--- What changed in the state in use since the last call (the observer's
--- `daemon_lsp_config`): `switched` — it now comes from another source (the
--- daemon's, the in-process one, or the hold); `entries` — the daemon's
--- entries differ (other than `db_rev`); `written` — the `db_dir`s whose
--- `db_rev` rose (an owned database the daemon wrote); `options` — the
--- options in use that differ, one `{ server, key, value }` per key. The first
--- call for a workspace only records it (and reports a switch when the
--- daemon's state is already in use).
--- @return { switched: boolean, entries: boolean, written: string[], options: { server: string, key: string, value: any }[] }
function M.changes()
    local ws = model(facade())
    local phase, st = M.phase()
    local src = (phase == "loaded" and type(st) == "table") and "daemon"
        or (holding_phase(phase) and "hold" or "inproc")
    local cur = { ws = ws, src = src }
    if src == "daemon" then
        cur.sig = entries_signature(st.projects)
        cur.revs = revs_of(st.projects)
        cur.options = type(st.options) == "table" and st.options or {}
    end
    local prev = _last
    _last = cur
    local ch = { switched = false, entries = false, written = {}, options = {} }
    local same_ws = prev ~= nil and prev.ws == ws
    if not same_ws then
        ch.switched = src == "daemon"
        if src == "daemon" then ch.options = option_changes(inproc_options(ws), cur.options) end
        return ch
    end
    ch.switched = prev.src ~= src
    if src == "daemon" and prev.src == "daemon" then
        ch.entries = prev.sig ~= cur.sig
        for d, now in pairs(cur.revs) do
            local before = prev.revs[d]
            if before and now.rev > before.rev then ch.written[#ch.written + 1] = now.dir end
        end
        table.sort(ch.written)
    end
    ch.options = option_changes(prev.options or inproc_options(ws), cur.options or inproc_options(ws))
    return ch
end

--- Test seam: forget the last snapshot.
function M._reset_changes() _last = nil end

return M
