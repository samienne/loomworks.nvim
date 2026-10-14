--- loomworks/test_state.lua — the one builder of the tests view's state
--- (`loomworks.view.Tests/1`, daemon.md §19.13 "The tests view"; step 5m
--- part A): the active profile's configuration units with their test-view
--- state, each `ok` unit's test tree with **explicit** suite nodes, node ids
--- scoped to their unit, `source`, and the per-node last results.
---
--- Host-neutral (pure Lua, no `vim.*`, requires nothing): the editor builds
--- the state in-process through loomworks/test_source.lua, and the workspace
--- daemon serves the same shape (step 5m part B1) with its session fields
--- and opaque ids (§19.12). Never discovers, loads, writes or reads files:
--- the trees come from what the units have discovered (or from `tree_of`).
---
--- Node ids. Every node has a **local key** scoped to its unit — the unit's
--- project and configuration keys plus the entry's id (a suite: its target's
--- entry id plus the suite name) — so the same `Suite.Case` in two projects
--- is two nodes. The id provider (`opts.node_id`) turns a local key into the
--- node's id: in-process the key itself, in the daemon an opaque id that is
--- stable while the key is. Clients never parse either.

local M = {}

--- @class loomworks.TestsViewNode
--- @field id string the node's id (opts.node_id of its local key)
--- @field kind "target"|"suite"|"test"
--- @field parent? string the parent node's id; absent for a top-level node
--- @field name string display text (a case without its suite)
--- @field file? string absolute, `/`-separated
--- @field line? integer 1-based
--- @field runnable boolean
--- @field source? string ctest, meson, gtest (probed cases), saved, or a module's runner name
--- @field status? "queued"|"running"|"passed"|"failed"|"skipped"|"errored"
--- @field duration? integer milliseconds, of the last result
--- @field message? string the last result's first failure line

--- @class loomworks.TestsViewUnit
--- @field id? string the configuration unit's opaque id (daemon only)
--- @field project string the project key
--- @field configuration string the configuration-unit key, as in `meta.units`
--- @field state "ok"|"pending"|"not_configured"|"foreign"|"no_tests"|"error"
--- @field message? string why, for error, not_configured and foreign
--- @field nodes loomworks.TestsViewNode[] discovery order, parents first; empty unless `ok`

--- @class loomworks.TestsView
--- @field state "loaded"|"unloaded"|"error"|"refused" the workspace's, as `view.Header/1`
--- @field profile? string the active profile's key
--- @field profile_id? string its opaque id (daemon only)
--- @field stale boolean
--- @field discovering? string the TaskId of a running discovery (daemon only)
--- @field units loomworks.TestsViewUnit[] project-key order

--- A unit's discovery outcome as `tree_of` reports it.
--- @alias loomworks.TestsTreeOutcome "ok"|"pending"|"error"

--- @class loomworks.TestsViewOpts
--- @field state? "unloaded"|"error"|"refused" the workspace's state when `ws` is nil (default `unloaded`)
--- @field id? fun(obj: table): string the opaque id of a profile or unit (daemon only)
--- @field node_id? fun(unit: table, key: string): string a node's id from its local key (default: the key)
--- @field tree_of? fun(unit: table): table[]|nil, loomworks.TestsTreeOutcome|nil, string|nil a unit's discovered entries, outcome and message (default: the unit's cached tree, `pending` without one)
--- @field result_of? fun(unit: table, key: string): { status: string, duration?: number, message?: string }|nil a node's last result, over the entry's own (daemon)
--- @field stale? boolean (default: some unit is `pending`)
--- @field discovering? string

--- Statuses a node carries (`loomworks.Common/1` TestStatus).
local STATUSES = {
    queued = true, running = true, passed = true, failed = true, skipped = true, errored = true,
}

--- The separator of a local key's parts (never part of a key or an id).
local SEP = "\31"

--- The local key of an entry of a unit.
--- @param project string
--- @param configuration string
--- @param entry_id string
--- @return string
function M.local_key(project, configuration, entry_id)
    return project .. SEP .. configuration .. SEP .. entry_id
end

--- The local key of a suite under a target entry of a unit.
--- @param project string
--- @param configuration string
--- @param target_entry_id string
--- @param suite string
--- @return string
function M.suite_key(project, configuration, target_entry_id, suite)
    return project .. SEP .. configuration .. SEP .. target_entry_id .. SEP .. "suite" .. SEP .. suite
end

--- The suite and case of a gtest-style case name (`Suite.Case`,
--- `Prefix/Suite.Case/0`), or nil when the name has none.
--- @param name string
--- @return string|nil suite, string|nil case
function M.split_case(name)
    if type(name) ~= "string" then return nil, nil end
    local suite, case = name:match("^([^%.]+)%.(.+)$")
    return suite, case
end

--- The live active profile of a workspace (nil: none, or a removed one) —
--- the one source both the builder and loomworks/test_source.lua read.
--- @param ws table|nil
--- @return table|nil
function M.active_profile(ws)
    local ap = type(ws) == "table" and ws._active_profile or nil
    if ap and not ap._removed then return ap end
    return nil
end
local active_profile = M.active_profile

--- `/`-separated path (nil passes through).
local function slashes(p)
    if type(p) ~= "string" or p == "" then return nil end
    return (p:gsub("\\", "/"))
end

--- A non-negative integer of milliseconds (nil passes through).
local function millis(d)
    if type(d) ~= "number" or d ~= d then return nil end
    if d < 0 then d = 0 end
    return math.floor(d + 0.5)
end

--- Copy the last result (entry fields, or `result_of`'s) onto a node.
local function set_result(node, r)
    if not r or not STATUSES[r.status] then return end
    node.status = r.status
    node.duration = millis(r.duration)
    if type(r.message) == "string" and r.message ~= "" then node.message = r.message end
end

--- The default `tree_of`: what the unit discovered and cached.
--- @param unit table
--- @return table[]|nil, loomworks.TestsTreeOutcome
local function cached_tree(unit)
    local tree = type(unit.test_tree) == "function" and unit:test_tree() or nil
    if tree then return tree, "ok" end
    return nil, "pending"
end

--- A unit's test tree as view nodes: its entries in discovery order with
--- explicit suite nodes (gtest-style `Suite.Case` children of a top-level
--- entry grouped by suite, a suite before its first case), ids from local
--- keys through `node_id`.
--- @param unit table a ConfigUnit
--- @param project string
--- @param configuration string
--- @param entries table[] the unit's merged test entries (§8.9.3)
--- @param opts loomworks.TestsViewOpts
--- @return loomworks.TestsViewNode[]
function M.nodes(unit, project, configuration, entries, opts)
    local node_id = opts.node_id or function(_, key) return key end
    local nodes, by_entry, suites, tops = {}, {}, {}, {}
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" and type(e.id) == "string" and not e.parent then tops[e.id] = e end
    end
    for _, e in ipairs(entries or {}) do
        if type(e) ~= "table" or type(e.id) ~= "string" then goto continue end
        local key = M.local_key(project, configuration, e.id)
        local node = {
            id = node_id(unit, key),
            name = tostring(e.name or e.id),
            runnable = e.runnable == true,
            file = slashes(e.file),
            line = type(e.line) == "number" and e.line >= 1 and math.floor(e.line) or nil,
            source = type(e.source) == "string" and e.source or nil,
        }
        local parent_entry = e.parent and tops[e.parent] or nil
        if not e.parent then
            node.kind = "target"
        else
            node.kind = "test"
            local suite, case = nil, nil
            if parent_entry then suite, case = M.split_case(e.name) end
            if suite then
                local skey = M.suite_key(project, configuration, parent_entry.id, suite)
                local snode = suites[skey]
                if not snode then
                    snode = { id = node_id(unit, skey), kind = "suite", name = suite,
                        parent = by_entry[parent_entry.id] and by_entry[parent_entry.id].id or nil,
                        runnable = parent_entry.runnable == true, source = node.source }
                    suites[skey] = snode
                    nodes[#nodes + 1] = snode
                end
                node.parent = snode.id
                node.name = case
            else
                local pnode = by_entry[e.parent]
                node.parent = pnode and pnode.id or nil
                if not pnode then node.kind = "target" end
            end
        end
        set_result(node, e)
        if opts.result_of then set_result(node, opts.result_of(unit, key)) end
        by_entry[e.id] = node
        nodes[#nodes + 1] = node
        ::continue::
    end
    return nodes
end

--- One unit's record: its test-view state, and its nodes when `ok`.
--- @param unit table a ConfigUnit
--- @param project string
--- @param opts loomworks.TestsViewOpts
--- @return loomworks.TestsViewUnit
function M.unit_record(unit, project, opts)
    local configuration = type(unit.config_key) == "function" and unit:config_key() or nil
    local rec = { project = project, configuration = tostring(configuration or ""), state = "pending", nodes = {} }
    if opts.id then rec.id = opts.id(unit) end
    local avail, why = nil, nil
    if type(unit.test_availability) == "function" then avail, why = unit:test_availability() end
    if avail then
        rec.state = avail
        rec.message = why
        return rec
    end
    local entries, outcome, message = (opts.tree_of or cached_tree)(unit)
    if outcome == "error" then
        rec.state = "error"
        rec.message = message or "test discovery failed"
    elseif entries then
        rec.state = "ok"
        rec.nodes = M.nodes(unit, project, rec.configuration, entries, opts)
    end
    return rec
end

--- `loomworks.view.Tests/1`'s state for the workspace's active profile.
--- @param ws table|nil the live workspace (nil: not loaded)
--- @param opts? loomworks.TestsViewOpts
--- @return loomworks.TestsView
function M.state(ws, opts)
    opts = opts or {}
    if type(ws) ~= "table" then
        return { state = opts.state or "unloaded", stale = opts.stale == true, units = {} }
    end
    local view = { state = "loaded", units = {} }
    local ap = active_profile(ws)
    if not ap or type(ap.key) ~= "string" then
        view.stale = opts.stale == true
        return view
    end
    view.profile = ap.key
    if opts.id then view.profile_id = opts.id(ap) end
    local list = {}
    for _, pp in ipairs(type(ap.projects) == "function" and ap:projects() or {}) do
        local unit = pp._config_unit
        local project = type(pp.project_key) == "function" and pp:project_key() or nil
        if unit and not unit._removed and type(project) == "string" then
            list[#list + 1] = M.unit_record(unit, project, opts)
        end
    end
    table.sort(list, function(a, b)
        if a.project ~= b.project then return a.project < b.project end
        return a.configuration < b.configuration
    end)
    view.units = list
    local pending = false
    for _, u in ipairs(list) do
        if u.state == "pending" then pending = true end
    end
    if opts.stale ~= nil then view.stale = opts.stale == true else view.stale = pending end
    view.discovering = opts.discovering
    return view
end

return M
