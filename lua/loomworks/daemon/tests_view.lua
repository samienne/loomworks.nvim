--- loomworks/daemon/tests_view.lua — the workspace daemon's tests view
--- (`loomworks.view.Tests/1` on `/views`, spec §19.13 "The tests view"; step
--- 5m part B1): the session's test state behind it and the state itself,
--- built by loomworks.test_state (the builder the editor uses in-process)
--- with the daemon's opaque ids (§19.12) and its session fields.
---
--- The session's test state (`service._tests`, created on first use) holds,
--- per configuration unit (weak keys: a reloaded workspace's units are new
--- objects, so a reload drops what the old ones had):
---
---   records  what the last `Tests/1.discover` found for the unit: its merged
---            entries (`ok`), its failure (`error`) or that it had nothing to
---            probe (`avail`: not configured here, foreign kit, no tests),
---            with the unit's build fingerprint and its run mark at the time
---   marks    a counter raised whenever a configure, build, clean, reset or
---            test run that covered the unit ended (`on_run_done`)
---   anchors  one table per node local key (test_state.local_key): the
---            object the node's opaque id is issued for, so a node keeps its
---            id while its unit, TestUnit and name do
---   results  the nodes' last results, by local key (written by the runs)
---
--- plus `discovered` (the profile of the last discovery that ran to its end)
--- and `discovering` (the running discovery: its task and profile).
---
--- **Stale** (the view's `stale`, schema `view.Tests/1`): true while a
--- profile is active and no discovery of it has run to its end since it
--- became the active one, or since then one of its units changed — its build
--- fingerprint (state, last configure, last build, saved test target list)
--- differs from the one its discovery recorded (also a change made by
--- another process, read through the cache), a configure, build, clean,
--- reset or test run that covered it ended (`marks`, also one that changed
--- nothing), or it is a unit the discovery has not seen. Only a discovery
--- clears it; the daemon never discovers by itself. A unit whose discovery
--- failed is not stale for that: the failure is its state until the next
--- discovery.

local test_state = require("loomworks.test_state")

local M = {}

M.VIEW = { path = "/views", iface = "loomworks.view.Tests", v = 1 }

--- @class loomworks.daemon.TestsRecord
--- @field outcome "ok"|"error"|"avail"
--- @field entries? table[] the unit's merged test entries (`ok`)
--- @field message? string why (`error`)
--- @field fp string the unit's build fingerprint when its discovery started
--- @field mark integer the unit's run mark when its discovery started

--- @class loomworks.daemon.TestsStore
--- @field records table<table, loomworks.daemon.TestsRecord>
--- @field marks table<table, integer>
--- @field anchors table<table, table<string, table>>
--- @field results table<table, table<string, { status: string, duration?: number, message?: string }>>
--- @field discovered table|nil the profile of the last discovery that ran to its end
--- @field discovering { task: loomworks.daemon.Task, profile: table }|nil

local function weak() return setmetatable({}, { __mode = "k" }) end

--- The session's test state of a service (created on first use).
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.TestsStore
function M.store(service)
    local st = service._tests
    if not st then
        st = { records = weak(), marks = weak(), anchors = weak(), results = weak() }
        service._tests = st
    end
    return st
end

--- A unit's build fingerprint: what a configure, build, clean or reset (of
--- any process) changes in its cached state, and its saved test targets.
--- @param unit table a ConfigUnit
--- @return string
function M.fingerprint(unit)
    local saved = type(unit._saved_tests_fingerprint) == "function" and unit:_saved_tests_fingerprint() or ""
    return table.concat({ tostring(unit.state_value), tostring(unit.last_configured), tostring(unit.last_built),
        saved }, "\1")
end

--- A unit's run mark.
--- @param st loomworks.daemon.TestsStore
--- @param unit table
--- @return integer
function M.mark_of(st, unit)
    return st.marks[unit] or 0
end

--- Is the unit's record current: recorded with the unit's present
--- fingerprint and run mark (`tree`: and holding a tree)?
--- @param st loomworks.daemon.TestsStore
--- @param unit table
--- @param tree? boolean
--- @return boolean
function M.current(st, unit, tree)
    local rec = st.records[unit]
    if not rec or rec.fp ~= M.fingerprint(unit) or rec.mark ~= M.mark_of(st, unit) then return false end
    return not tree or rec.outcome == "ok"
end

--- The live configuration units of a profile, in project-key order (then
--- configuration key), as the view lists them.
--- @param profile table
--- @return { unit: table, project: string, configuration: string }[]
function M.profile_units(profile)
    local list = {}
    for _, pp in ipairs(type(profile.projects) == "function" and profile:projects() or {}) do
        local unit = pp._config_unit
        local project = type(pp.project_key) == "function" and pp:project_key() or nil
        if unit and not unit._removed and type(project) == "string" then
            list[#list + 1] = { unit = unit, project = project, configuration = tostring(unit:config_key() or "") }
        end
    end
    table.sort(list, function(a, b)
        if a.project ~= b.project then return a.project < b.project end
        return a.configuration < b.configuration
    end)
    return list
end

--- Is the view of the workspace's active profile stale (see the header)?
--- @param st loomworks.daemon.TestsStore
--- @param ws table|nil
--- @return boolean
function M.stale(st, ws)
    local ap = test_state.active_profile(ws)
    if not ap then return false end
    if st.discovered ~= ap then return true end
    for _, u in ipairs(M.profile_units(ap)) do
        if not M.current(st, u.unit) then return true end
    end
    return false
end

--- The anchor of a node (the object its opaque id is issued for).
--- @param st loomworks.daemon.TestsStore
--- @param unit table
--- @param key string the node's local key
--- @return table
local function anchor(st, unit, key)
    local per = st.anchors[unit]
    if not per then per = {}; st.anchors[unit] = per end
    local a = per[key]
    if not a then a = { key = key }; per[key] = a end
    return a
end

--- The builder options of the daemon's view.
--- @param service loomworks.daemon.BuildService
--- @param st loomworks.daemon.TestsStore
--- @param ws table
--- @return loomworks.TestsViewOpts
local function opts(service, st, ws)
    local ap = test_state.active_profile(ws)
    local d = st.discovering
    return {
        id = function(obj) return service.ids:id(obj) end,
        node_id = function(unit, key) return service.ids:id(anchor(st, unit, key)) end,
        tree_of = function(unit)
            local rec = st.records[unit]
            if not rec or rec.outcome == "avail" then return nil, "pending" end
            if rec.outcome == "error" then return nil, "error", rec.message end
            return rec.entries or {}, "ok"
        end,
        result_of = function(unit, key)
            local per = st.results[unit]
            return per and per[key] or nil
        end,
        stale = M.stale(st, ws),
        discovering = (d and ap and d.profile == ap and not d.task.finished) and d.task.id or nil,
    }
end

--- `loomworks.view.Tests/1`'s state. Never loads, never discovers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.TestsView
function M.state(service)
    local ws, err = service:header_model()
    if not ws then
        local state = require("loomworks.view_state").base_header(nil, err).state
        return test_state.state(nil, { state = state, stale = false })
    end
    local st = M.store(service)
    return test_state.state(ws, opts(service, st, ws))
end

--- The node a view id names in the current view of the active profile, or
--- nil (a stale reference: a re-discovery dropped it, the active profile
--- changed, an id of another session): its unit, local key, view node and,
--- unless it is a suite, the discovery entry it stands for.
--- @param service loomworks.daemon.BuildService
--- @param id string
--- @return { unit: table, key: string, node: loomworks.TestsViewNode, entry: table|nil }|nil
function M.find_node(service, id)
    if type(id) ~= "string" then return nil end
    local ap = test_state.active_profile((service:header_model()))
    if not ap then return nil end
    local st = M.store(service)
    for _, u in ipairs(M.profile_units(ap)) do
        for key, a in pairs(st.anchors[u.unit] or {}) do
            if service.ids.by_obj[a] == id then
                local rec = st.records[u.unit]
                if not rec or rec.outcome ~= "ok" then return nil end
                local nodes = test_state.nodes(u.unit, u.project, u.configuration, rec.entries or {},
                    { node_id = function(unit, k) return service.ids:id(anchor(st, unit, k)) end })
                for _, n in ipairs(nodes) do
                    if n.id == id then
                        local entry
                        for _, e in ipairs(rec.entries or {}) do
                            if type(e) == "table" and test_state.local_key(u.project, u.configuration, e.id) == key then
                                entry = e
                            end
                        end
                        return { unit = u.unit, key = key, node = n, entry = entry }
                    end
                end
                return nil
            end
        end
    end
    return nil
end

--- Record a node's last result (a run's, step 5m part B2).
--- @param service loomworks.daemon.BuildService
--- @param unit table
--- @param key string the node's local key
--- @param result { status: string, duration?: number, message?: string }|nil nil: none
function M.set_result(service, unit, key, result)
    local st = M.store(service)
    local per = st.results[unit]
    if not per then per = {}; st.results[unit] = per end
    per[key] = result
end

--- The operations whose end marks the units they covered (their trees may
--- no longer match the build).
local MARKING = { build = true, configure = true, clean = true, reset = true, test = true, run = true, debug = true }

--- A run of the service ended (Service:on_run_done): a configure, build,
--- clean, reset or test run — or a launch preparation that built — marks
--- the units it covered (every unit of the workspace when its scope is not
--- known). The views' update follows at the end of the model segment it
--- ended in, or here when it ended outside one.
--- @param service loomworks.daemon.BuildService
--- @param run table
function M.on_run_done(service, run)
    if not MARKING[run.op] then return end
    local ctx = run.ctx
    if (run.op == "run" or run.op == "debug") and ctx and ctx.args and ctx.args.no_build then return end
    local st = M.store(service)
    local units = {}
    if ctx and ctx.units then
        units = ctx.units
    elseif ctx and ctx.profile and run.op ~= "reset" then
        for _, u in ipairs(M.profile_units(ctx.profile)) do units[#units + 1] = u.unit end
    else
        local ws = (ctx and ctx.ws) or service.ws
        for _, u in pairs(ws and ws._config_units or {}) do units[#units + 1] = u end
    end
    for _, u in ipairs(units) do st.marks[u] = (st.marks[u] or 0) + 1 end
    if service.current == nil then pcall(require("loomworks.daemon.views").check, service) end
end

return M
