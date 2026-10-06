--- loomworks/daemon/snapshot.lua — scope snapshots, the client's read-only
--- projection, the welcome header and the host-probing queries (spec §19.13,
--- §19.14).
---
--- **Snapshot** (daemon side, `build`): the file-shaped tables the loaded model
--- already serializes — `config` the published baseline as loaded
--- (`Workspace._shared_baseline`, parsed and stripped), `user` the working copy
--- (`Workspace:_serialize_user`), `cache` the cache (`Workspace:_serialize_cache`),
--- each stamped with its schema `_meta` exactly as a save stamps it — plus the
--- resolved toolchain detection (`tools`, tool rows: `tool_rows`), the
--- stripped program-bearing fields (`shared_ignored`) and the semantic-key →
--- opaque-id index (§19.12). It is served from the model as loaded, whatever
--- the requester's environment (service.lua `live` with `as_is`).
---
--- **Projection** (client side, `project`): the same deserializer the on-disk
--- load uses (`workspace.assemble_snapshot` → `Workspace.new` → `remerge`),
--- fed the snapshot's tables instead of files, on a private core whose
--- events bus is a no-op (its events never reach the process's subscribers).
--- It is read-only: `_no_write` is set before the first remerge, so it never
--- saves the working copy or the cache, and it tracks no files.
---
--- **Queries** (`QUERIES`): read-only requests that probe the host, run by
--- the daemon in the requesting client's environment. A query gets the live
--- workspace and its args and returns a JSON-safe result table.

local M = {}

--- The scopes a `snapshot` request may name (`"all"` is every one of them).
M.SCOPES = { "config", "user", "cache" }

--- The reason a projection carries in `_no_write`.
M.READ_ONLY = "a read-only projection of the workspace daemon's model (spec §19.13)"

-- ========================== opaque-id registry ==========================

--- @class loomworks.daemon.IdRegistry
--- Session-local opaque ids keyed by object identity (spec §19.12): assigned
--- once, never reused within the session; weak keys, so a dropped object
--- frees its entry (its id is still never handed out again). An id is a
--- string on the wire (loomworks.Common/1 `Id`): opaque to clients, which
--- only compare it and send it back. It carries the session generation
--- (`protocol.session_id`), so an id of an earlier session never resolves
--- in this one: it is a stale reference, refused (§19.20 "Errors and domain
--- results").
--- @field next integer the last id handed out
--- @field generation integer|string|nil the session generation ids carry
--- @field by_obj table<table, string> object → id (weak keys)
local Registry = {}
Registry.__index = Registry

--- @param generation? integer|string the session generation the ids carry
--- @return loomworks.daemon.IdRegistry
function M.registry(generation)
    return setmetatable({ next = 0, generation = generation, by_obj = setmetatable({}, { __mode = "k" }) },
        Registry)
end

--- The object's id, assigned on first sight.
--- @param obj table
--- @return string
function Registry:id(obj)
    local id = self.by_obj[obj]
    if not id then
        self.next = self.next + 1
        id = require("loomworks.daemon.protocol").session_id(self.generation, self.next)
        self.by_obj[obj] = id
    end
    return id
end

--- The object an id was issued for, among `candidates` (nil: none of them,
--- e.g. a stale id of a removed entity or an earlier session).
--- @param id string
--- @param candidates table[]|nil
--- @return table|nil
function Registry:find(id, candidates)
    if type(id) ~= "string" then return nil end
    for _, obj in pairs(candidates or {}) do
        if not obj._removed and self.by_obj[obj] == id then return obj end
    end
    return nil
end

--- The semantic-key → id index of a workspace's keyed objects (spec §19.13):
--- `projects` (project key → id), `config_sets` (name → id), `profiles`
--- (profile key → id), and `config_units`, a list of
--- `{ project = <project key>, configuration = <configuration key>, id }`.
--- @param ws table
--- @param reg loomworks.daemon.IdRegistry
--- @return { projects: table<string, string>, config_sets: table<string, string>, profiles: table<string, string>, config_units: { project: string, configuration: string, id: string }[] }
function M.index(ws, reg)
    local idx = { projects = {}, config_sets = {}, profiles = {}, config_units = {} }
    for _, p in pairs(ws._projects or {}) do
        if not p._removed and p.key then idx.projects[p.key] = reg:id(p) end
    end
    for _, cs in pairs(ws._config_sets or {}) do
        if not cs._removed and cs.name then idx.config_sets[cs.name] = reg:id(cs) end
    end
    for _, pr in pairs(ws._profiles or {}) do
        if not pr._removed and pr.key then idx.profiles[pr.key] = reg:id(pr) end
    end
    for _, u in pairs(ws._config_units or {}) do
        local pk = u._project and not u._project._removed and u._project.key or nil
        local ck = u.config_key and u:config_key() or nil
        if not u._removed and pk and ck then
            idx.config_units[#idx.config_units + 1] = { project = pk, configuration = ck, id = reg:id(u) }
        end
    end
    table.sort(idx.config_units, function(a, b)
        if a.project ~= b.project then return a.project < b.project end
        return a.configuration < b.configuration
    end)
    return idx
end

-- ========================== daemon side ==========================

--- Is `scope` a valid `snapshot` scope?
--- @param scope any
--- @return boolean
function M.valid_scope(scope)
    if scope == nil or scope == "all" then return true end
    return vim.tbl_contains(M.SCOPES, scope)
end

--- The tool rows of the wire (spec §19.13, §19.14), one shape for the
--- snapshot's `tools` and the `tools` query: module type → list of
--- `{ key, label, tool_data }` (`key` absent for a module whose single tool
--- has none), from a detection (`tools_by_type`: module type → list of
--- `{ tool_key, tool_label, tool_data }`).
--- @param tools_by_type table|nil
--- @return table<string, { key: string|nil, label: string|nil, tool_data: table|nil }[]>
function M.tool_rows(tools_by_type)
    local out = {}
    for mod_type, list in pairs(tools_by_type or {}) do
        local rows = {}
        for _, t in ipairs(list) do
            rows[#rows + 1] = { key = t.tool_key, label = t.tool_label, tool_data = vim.deepcopy(t.tool_data) }
        end
        out[mod_type] = rows
    end
    return out
end

--- The inverse of `tool_rows`: wire tool rows → a detection (`tools_by_type`).
--- @param rows table|nil
--- @return table
function M.tools_from_rows(rows)
    local out = {}
    for mod_type, list in pairs(type(rows) == "table" and rows or {}) do
        local entries = {}
        for _, t in ipairs(type(list) == "table" and list or {}) do
            entries[#entries + 1] = { tool_key = t.key, tool_label = t.label, tool_data = vim.deepcopy(t.tool_data) }
        end
        out[mod_type] = entries
    end
    return out
end

--- The snapshot of `ws` for `scope` (see the header). Pure: reads the model
--- through its serializers, changes nothing.
--- @param ws table the live workspace
--- @param scope string|nil "all" (default) | "config" | "user" | "cache"
--- @param reg loomworks.daemon.IdRegistry
--- @return table
function M.build(ws, scope, reg)
    scope = scope or "all"
    local function want(s) return scope == "all" or scope == s end
    local snap = { scope = scope }
    if want("config") then
        snap.config = vim.deepcopy(ws._shared_baseline or { projects = {} })
    end
    if want("user") then
        local user = ws:_serialize_user()
        user._meta = { version = require("loomworks.user").CURRENT_VERSION }
        snap.user = user
    end
    if want("cache") then
        local cache = ws:_serialize_cache()
        cache._meta = { version = require("loomworks.cache").CURRENT_VERSION }
        snap.cache = cache
    end
    snap.tools = M.tool_rows(ws._tools_by_type)
    snap.shared_ignored = vim.deepcopy(ws._shared_ignored or {})
    snap.index = M.index(ws, reg)
    return snap
end

--- The `welcome` header's model fields (spec §19.13): the loaded workspace's
--- name and active profile, or its error state.
--- @param ws table|nil the live workspace (nil: not loaded)
--- @param err table|nil { message, refused? } the host's load failure, if any
--- @return table { state = "loaded"|"unloaded"|"error"|"refused", name?, active_profile?, error? }
function M.header(ws, err)
    if ws then
        local ap = ws._active_profile
        return { state = "loaded", name = ws.name,
            active_profile = (ap and not ap._removed and ap.key) or ws._active_profile_key or nil }
    end
    if err and err.message then
        return { state = err.refused and "refused" or "error", error = err.message }
    end
    return { state = "unloaded" }
end

--- Host-probing queries (spec §19.14): name → fn(ws, args) → result table or
--- nil, error. Each runs in a model segment inside the client's environment.
M.QUERIES = {
    --- The toolchains detected in the client's environment, per module type
    --- (`merge.detect_tools` over the live model; the model is not changed).
    tools = function(ws, _)
        local deps = ws._core._deps
        local detected = deps.merge.detect_tools(ws:_config_from_objects(), ws:_serialize_cache())
        return { tools = M.tool_rows(detected) }
    end,
    --- The compiler cache a profile resolves for one of its projects
    --- (`lw profile query <profile> <project> cache`, which formats it with
    --- profile.lua `compiler_cache_text`): `args.profile` (key), `args.project`
    --- (key) → `{ cache = { policy, tool?, path?, present, stale,
    --- msvc_auto_off, applicable, not_applied_reason?, not_applied_hint? } }`;
    --- `cache` absent for a module that does not cache C/C++. Probes the
    --- client's PATH.
    profile_cache = function(ws, args)
        -- (Wire keys are resolved to objects here, at the boundary, §19.14.)
        local profile
        for _, p in pairs(ws._profiles or {}) do
            if not p._removed and p.key == args.profile then profile = p end
        end
        if not profile then return nil, "no profile '" .. tostring(args.profile) .. "'" end
        for _, pp in ipairs(profile:projects()) do
            if pp:project_key() == args.project then
                local st = profile:compiler_cache_status(pp)
                if not st then return {} end
                return { cache = { policy = st.policy, tool = st.tool, path = st.path, present = st.present,
                    stale = st.stale, msvc_auto_off = st.msvc_auto_off, applicable = st.applicable,
                    not_applied_reason = st.not_applied_reason, not_applied_hint = st.not_applied_hint } }
            end
        end
        return nil, "project '" .. tostring(args.project) .. "' is not mapped in profile '" .. profile.key .. "'"
    end,
}

-- ========================== client side ==========================

--- Request a snapshot over a session (a pipe or loopback connection).
--- @param conn table a client session (loomworks.daemon.client)
--- @param opts? { scope?: string, env?: table, timeout_ms?: integer }
--- @return table|nil reply, string|nil err
function M.fetch(conn, opts)
    opts = opts or {}
    -- (lw.internal.Snapshot/1.get over transport 11, daemon/calls.lua.)
    local reply, err = require("loomworks.daemon.calls").request_sync(conn,
        { kind = require("loomworks.daemon.protocol").KIND.snapshot, scope = opts.scope or "all",
            env = opts.env or require("loomworks.daemon.envscope").capture() }, opts.timeout_ms)
    if not reply then return nil, err end
    if reply.kind == "error" then return nil, reply.error end
    if reply.outcome ~= "ok" then return nil, reply.message or reply.reason or reply.outcome end
    return reply
end

--- Build the read-only projection of a full snapshot (see the header).
--- @param root string the workspace root
--- @param snap table a reply to a `snapshot` of scope "all"
--- `opts.tools` replaces the snapshot's toolchain detection (a detection,
--- tools_by_type: a fresh `tools` query through `tools_from_rows`, or the
--- machine-level tool cache).
--- @param opts? { notify?: function, tools?: table }
--- @return table|nil ws, string|nil err
function M.project(root, snap, opts)
    opts = opts or {}
    if not (snap and snap.config and snap.user and snap.cache) then
        return nil, "a projection needs a snapshot of every scope"
    end
    local ws_mod = require("loomworks.workspace")
    local tools = opts.tools and vim.deepcopy(opts.tools) or M.tools_from_rows(snap.tools)
    local noop = function() end
    local core = require("loomworks.core").new({
        -- A private, silent events bus: the projection's events never reach
        -- the subscribers of this process (an editor's UI, its integrations).
        events = { on = noop, off = noop, emit = noop },
        notify = opts.notify or function() end,
        on_written = false,
        on_save_refused = function() end,
        scan_targets = false,
        manual_file_tracking = true,
        detect_tools_async = function(_, _, cb) cb(vim.deepcopy(tools)) end,
    })
    local data = ws_mod.assemble_snapshot(root, snap)
    local ws = ws_mod.Workspace.new(core, data)
    ws._no_write = M.READ_ONLY
    ws._projection = true
    ws._shared_ignored = data.shared_ignored or {}
    ws._tools_by_type = tools
    core._workspace = ws
    ws:remerge(data.config, data.cache, data.user)
    ws._tool_state = "scanned"
    core._state = "initialized"
    ws._index = snap.index
    return ws
end

--- Fetch a full snapshot over `conn` and build its projection.
--- @param conn table a client session
--- @param root string
--- @param opts? { env?: table, timeout_ms?: integer, notify?: function }
--- @return table|nil ws, string|nil err
function M.projection(conn, root, opts)
    opts = opts or {}
    local snap, err = M.fetch(conn, { scope = "all", env = opts.env, timeout_ms = opts.timeout_ms })
    if not snap then return nil, err end
    return M.project(root, snap, opts)
end

--- Run a host-probing query over `conn` in this process's environment.
--- @param conn table a client session
--- @param name string
--- @param args? table
--- @param opts? { env?: table, timeout_ms?: integer }
--- @return table|nil result, string|nil err
function M.query(conn, name, args, opts)
    opts = opts or {}
    -- (Toolchains/1.list, Profiles/1.compiler_cache over transport 11,
    -- daemon/calls.lua.)
    local reply, err = require("loomworks.daemon.calls").request_sync(conn,
        { kind = require("loomworks.daemon.protocol").KIND.query, name = name, args = args or {},
            env = opts.env or require("loomworks.daemon.envscope").capture() }, opts.timeout_ms)
    if not reply then return nil, err end
    if reply.kind == "error" then return nil, reply.error end
    if reply.outcome ~= "ok" then return nil, reply.message or reply.reason or reply.outcome end
    return reply.result
end

return M
