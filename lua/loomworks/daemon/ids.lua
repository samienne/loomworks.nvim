--- loomworks/daemon/ids.lua — opaque, session-local wire identity (DAEMON.md §3.2).
---
--- Object references cannot cross a socket, so the wire needs a serializable
--- token. Domain objects have no stable semantic id — deserialization anchors on
--- MUTABLE semantic keys, and a rename rewrites those keys in place; the only
--- thing preserved across a rename is the in-memory Lua-table POINTER. This
--- registry exploits exactly that: it keys ids by **object identity** (a
--- weak-key map), so an id is
---
---   * **rename-stable** — a rename mutates the object's `.key` in place but keeps
---     the table, so `id_for` returns the same id under the new key; and
---   * **refresh-stable** — `data_model.refresh` reuses the existing object table
---     when a semantic key still matches (identity preserved), so the id carries
---     across an external edit for surviving items.
---
--- Ids are monotonic and **never reused within a session**; a daemon restart
--- makes a new registry (a new session generation, §17.6), on which a client
--- flushes its id-map and re-hydrates.
---
--- The `index(workspace)` output stamps the CURRENT key/name → stable id for each
--- addressable item into a snapshot, so a client can build its id↔key map — the
--- transport-layer router that is ALSO its subscription set (§3.3). Threading ids
--- into per-object DELTAS is a deferred optimization (§3.3 endorses coarse
--- snapshot re-pull first); this layer is the foundation for it.

--- @class loomworks.daemon.IdRegistry
local IdRegistry = {}
IdRegistry.__index = IdRegistry

local M = {}

--- Create a fresh id registry (one per daemon session).
--- @return loomworks.daemon.IdRegistry
function M.new()
    return setmetatable({
        _ids = setmetatable({}, { __mode = "k" }), -- object -> id, weak keys
        _next = 0,
    }, IdRegistry)
end

--- The stable id for an object, assigning one on first sight.
--- @param obj table|nil
--- @return integer|nil
function IdRegistry:id_for(obj)
    if obj == nil then return nil end
    local id = self._ids[obj]
    if not id then
        self._next = self._next + 1
        id = self._next
        self._ids[obj] = id
    end
    return id
end

--- Build the key/name → id index for a workspace's addressable items, for
--- stamping into a snapshot. Config units index by their build-dir id.
--- @param workspace table
--- @return table { profiles, projects, config_sets, config_units }
function IdRegistry:index(workspace)
    local idx = { profiles = {}, projects = {}, config_sets = {}, config_units = {} }
    for _, p in ipairs(workspace._profiles or {}) do
        if p.key then idx.profiles[p.key] = self:id_for(p) end
    end
    for _, p in ipairs(workspace._projects or {}) do
        if p.key then idx.projects[p.key] = self:id_for(p) end
    end
    for _, cs in ipairs(workspace._config_sets or {}) do
        if cs.name then idx.config_sets[cs.name] = self:id_for(cs) end
    end
    for _, cu in ipairs(workspace._config_units or {}) do
        if cu.id then idx.config_units[cu.id] = self:id_for(cu) end
    end
    return idx
end

M.IdRegistry = IdRegistry
return M
