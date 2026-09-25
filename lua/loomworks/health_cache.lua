--- loomworks/health_cache.lua — advisory suggestion cache (headless §16.31).
---
--- A small, workspace-local cache for the `lw health` / `N suggestions`
--- results, kept deliberately SEPARATE from the build-state cache
--- (`loomworks.cache.json`): that cache carries a build-cache version and
--- deletion-safety logic, whereas this one is a self-healing advisory cache
--- with its own schema version, so the two never entangle. It lives beside the
--- build cache under the workspace's `.nvim/` directory and is an internal
--- cache — never a project or build-system file — so health still "authors
--- nothing" (§16.9).
---
--- Three tiers (§16.31, §16.33):
---   * `local_tier`   — `{ items, computed_at, key }`, the passive providers'
---     results plus a cheap invalidation fingerprint of their inputs;
---   * `network_tier` — `{ items, computed_at, key }`, the on-demand providers'
---     results, governed by a TTL and keyed to the running version (bundle, host
---     binary, channel) they describe;
---   * `inventory_tier` — `{ results, declared, computed_at, key }`, the
---     environment inventory's raw probe results (written only by a health run)
---     keyed to the environment they were probed in. Added without a schema
---     bump: an older file simply has none, and an older reader drops it.
---
--- The module is pure: it takes an injected `io` table (the same shape as
--- `loomworks.io` — `read_json`/`read_file`/`write_json`/`ensure_dir`) so both
--- production and tests drive it deterministically. A missing, corrupt, or
--- older-schema file is treated as empty and never raises.

local M = {}

--- Schema version for the health cache. Bumped independently of the build
--- cache version (`loomworks.cache`'s CURRENT_VERSION) — the two are unrelated.
--- An older/newer value is treated as an empty cache (recomputed), never an error.
M.SCHEMA_VERSION = 1

--- File path for a workspace root. Sits beside `loomworks.cache.json`.
--- @param root string
--- @return string
function M.path(root)
    return root .. "/.nvim/loomworks.health.json"
end

--- An empty (well-formed) cache table.
--- @return table
function M.empty()
    return { _meta = { version = M.SCHEMA_VERSION } }
end

--- Coerce a decoded tier into a well-formed `{ items, computed_at, key? }` or nil.
--- @param tier any
--- @return table|nil
local function normalize_tier(tier)
    if type(tier) ~= "table" then return nil end
    local items = tier.items
    if type(items) ~= "table" then items = {} end
    return {
        items = items,
        computed_at = type(tier.computed_at) == "number" and tier.computed_at or nil,
        key = type(tier.key) == "string" and tier.key or nil,
    }
end

--- Coerce a decoded inventory tier into `{ results, declared, computed_at?, key? }`
--- or nil (results/declared must be arrays of tables).
--- @param tier any
--- @return table|nil
local function normalize_inventory_tier(tier)
    if type(tier) ~= "table" or type(tier.results) ~= "table" then return nil end
    local results, declared = {}, {}
    for _, r in ipairs(tier.results) do
        if type(r) == "table" and type(r.id) == "string" then results[#results + 1] = r end
    end
    for _, d in ipairs(type(tier.declared) == "table" and tier.declared or {}) do
        if type(d) == "table" and type(d.id) == "string" then declared[#declared + 1] = d end
    end
    return {
        results = results,
        declared = declared,
        computed_at = type(tier.computed_at) == "number" and tier.computed_at or nil,
        key = type(tier.key) == "string" and tier.key or nil,
    }
end

--- Read the health cache for `root`. Returns a well-formed table ALWAYS: a
--- missing/corrupt/older-schema file yields `M.empty()`. Never raises.
--- @param io_dep table io-like dependency (`read_json` and/or `read_file`)
--- @param root string
--- @return table cache `{ _meta, local_tier?, network_tier?, inventory_tier? }`
function M.read(io_dep, root)
    local path = M.path(root)
    local data
    if type(io_dep) == "table" then
        if type(io_dep.read_json) == "function" then
            local ok, decoded = pcall(io_dep.read_json, path)
            if ok and type(decoded) == "table" then data = decoded end
        elseif type(io_dep.read_file) == "function" then
            local ok, content = pcall(io_dep.read_file, path)
            if ok and type(content) == "string" then
                local dok, decoded = pcall(vim.json.decode, content)
                if dok and type(decoded) == "table" then data = decoded end
            end
        end
    end

    if type(data) ~= "table"
        or type(data._meta) ~= "table"
        or data._meta.version ~= M.SCHEMA_VERSION then
        return M.empty()
    end

    return {
        _meta = { version = M.SCHEMA_VERSION },
        local_tier = normalize_tier(data.local_tier),
        network_tier = normalize_tier(data.network_tier),
        inventory_tier = normalize_inventory_tier(data.inventory_tier),
    }
end

--- Persist the health cache for `root`. Stamps the schema version, ensures the
--- `.nvim/` directory exists, and writes atomically (temp+rename) via the io
--- dependency's `write_json`. Best-effort: returns the writer's ok/err, and a
--- write failure is non-fatal to the caller (the cache is advisory).
--- @param io_dep table io-like dependency (`write_json`, optional `ensure_dir`)
--- @param root string
--- @param data table cache table to persist
--- @return boolean ok, string|nil err
function M.write(io_dep, root, data)
    if type(io_dep) ~= "table" or type(io_dep.write_json) ~= "function" then
        return false, "no write_json"
    end
    data = data or M.empty()
    data._meta = { version = M.SCHEMA_VERSION }
    if type(io_dep.ensure_dir) == "function" then
        pcall(io_dep.ensure_dir, root .. "/.nvim")
    end
    local ok, err = io_dep.write_json(M.path(root), data)
    return ok and true or false, err
end

return M
