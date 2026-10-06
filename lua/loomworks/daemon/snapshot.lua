--- loomworks/daemon/snapshot.lua — scope snapshots, the client's read-only
--- projection, the welcome header and the host-probing queries (spec §19.13,
--- §19.14).
---
--- **Snapshot** (daemon side, `build`): the file-shaped tables the loaded model
--- already serializes — `config` the published baseline as loaded
--- (`Workspace._shared_baseline`, parsed and stripped), `user` the working copy
--- (`Workspace:_serialize_user`), `cache` the cache (`Workspace:_serialize_cache`),
--- each stamped with its schema `_meta` exactly as a save stamps it — plus the
--- resolved toolchain detection (`tools`), the stripped program-bearing fields
--- (`shared_ignored`) and the current-key → opaque-id index (§19.12).
---
--- **Projection** (client side, `project`): the same deserializer the on-disk
--- load uses (`workspace.assemble_snapshot` → `Workspace.new` → `remerge`),
--- fed the snapshot's tables instead of files, on a private core. It is
--- read-only: `_no_write` is set before the first remerge, so it never saves
--- the working copy or the cache, and it tracks no files.
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
--- frees its entry (its id is still never handed out again).
--- @field next integer the last id handed out
--- @field by_obj table<table, integer> object → id (weak keys)
local Registry = {}
Registry.__index = Registry

--- @return loomworks.daemon.IdRegistry
function M.registry()
    return setmetatable({ next = 0, by_obj = setmetatable({}, { __mode = "k" }) }, Registry)
end

--- The object's id, assigned on first sight.
--- @param obj table
--- @return integer
function Registry:id(obj)
    local id = self.by_obj[obj]
    if not id then
        self.next = self.next + 1
        id = self.next
        self.by_obj[obj] = id
    end
    return id
end

--- The current-key → id index of a workspace's keyed objects.
--- @param ws table
--- @param reg loomworks.daemon.IdRegistry
--- @return table { projects, config_sets, profiles, config_units } each key → id
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
        if not u._removed and u.id then idx.config_units[u.id] = reg:id(u) end
    end
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
    snap.tools = vim.deepcopy(ws._tools_by_type or {})
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
        local out = {}
        for mod_type, list in pairs(detected or {}) do
            local rows = {}
            for _, t in ipairs(list) do
                rows[#rows + 1] = { key = t.tool_key, label = t.tool_label, tool_data = t.tool_data }
            end
            out[mod_type] = rows
        end
        return { tools = out }
    end,
    --- The compiler cache a profile resolves for one of its projects, as the
    --- `Cache` row shows it (`lw profile query <profile> <project> cache`):
    --- `args.profile` (key), `args.project` (key) → `{ cache = text }` ("" for
    --- a module that does not cache C/C++). Probes the client's PATH.
    profile_cache = function(ws, args)
        -- (Wire keys are resolved to objects here, at the boundary, §19.14.)
        local profile
        for _, p in pairs(ws._profiles or {}) do
            if not p._removed and p.key == args.profile then profile = p end
        end
        if not profile then return nil, "no profile '" .. tostring(args.profile) .. "'" end
        for _, pp in ipairs(profile:projects()) do
            if pp:project_key() == args.project then
                local status = profile:compiler_cache_status(pp)
                return { cache = status and (status.text:gsub("^Cache: ", "")) or "" }
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
    local client = require("loomworks.daemon.client")
    local reply, err = client.request(conn, { kind = require("loomworks.daemon.protocol").KIND.snapshot,
        scope = opts.scope or "all", env = opts.env or require("loomworks.daemon.envscope").capture() },
        opts.timeout_ms)
    if not reply then return nil, err end
    if reply.kind == "error" then return nil, reply.error end
    if reply.outcome ~= "ok" then return nil, reply.message or reply.reason or reply.outcome end
    return reply
end

--- Build the read-only projection of a full snapshot (see the header).
--- @param root string the workspace root
--- @param snap table a reply to a `snapshot` of scope "all"
--- `opts.tools` replaces the snapshot's toolchain detection (tools_by_type:
--- a fresh `tools` query, or the machine-level tool cache).
--- @param opts? { notify?: function, tools?: table }
--- @return table|nil ws, string|nil err
function M.project(root, snap, opts)
    opts = opts or {}
    if not (snap and snap.config and snap.user and snap.cache) then
        return nil, "a projection needs a snapshot of every scope"
    end
    local ws_mod = require("loomworks.workspace")
    local tools = vim.deepcopy(opts.tools or snap.tools or {})
    local core = require("loomworks.core").new({
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
    local client = require("loomworks.daemon.client")
    local reply, err = client.request(conn, { kind = require("loomworks.daemon.protocol").KIND.query,
        name = name, args = args or {}, env = opts.env or require("loomworks.daemon.envscope").capture() },
        opts.timeout_ms)
    if not reply then return nil, err end
    if reply.kind == "error" then return nil, reply.error end
    if reply.outcome ~= "ok" then return nil, reply.message or reply.reason or reply.outcome end
    return reply.result
end

return M
