--- loomworks/daemon/test_store.lua — the build service's test state for the
--- session (spec §19.13 "The tests view", §19.15 "Tests", step 5m), the one
--- store of it: what `Tests/1.discover` found per unit and whether the view
--- is stale, the opaque ids of test nodes, the per-node last results and the
--- statuses of a running `Tests/1.run_cases`, the build-directory operation
--- queue of the `Tests/1` tasks, and the `prepare_debug` tokens.
---
--- One store per build service (`M.of(service)`), in the daemon's memory:
--- it survives the editor's reconnects, not a daemon restart.
---
--- **Discovery** (step 5m part B1, loomworks.daemon.test_discover), per
--- configuration unit (weak keys: a reloaded workspace's units are new
--- objects, so a reload drops their trees — the view shows them pending
--- until the next discovery, which keeps their nodes' ids and last results):
---
---   records  what the last discovery found for the unit: its merged
---            entries (`ok`), its failure (`error`) or that it had nothing to
---            probe (`avail`: not configured here, foreign kit, no tests),
---            with the unit's build fingerprint and its run mark at the time.
---            A build's invalidation of the unit's own cache leaves it: the
---            view keeps the tree, stale, until the next discovery.
---   marks    a counter raised whenever a configure, build, clean, reset,
---            test run or editor test run (`Tests/1.run_cases` /
---            `prepare_debug`, unless `no_build`) that covered the unit ended
---            (`M.on_run_done`)
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
---
--- **Node ids.** A node's id is an opaque session id (§19.12) issued for its
--- local key (loomworks.test_state: unit-scoped), stable while the key is —
--- so a re-discovery, also after a reload, keeps the id (and the last
--- result) of a node it keeps: ids and results are keyed by the local key,
--- never by unit objects.
---
--- **The view's seam** (`view.Tests/1`, loomworks.daemon.tests_view): the
--- view is built with `view_opts(ws)` (ids, node ids, the trees, the current
--- statuses, `stale`, `discovering`). Per-case progress is not an `update`
--- (it travels as `Tests/1.results`): loomworks.daemon.views decides whether
--- to send `update` on the state built with `view_opts(ws, { committed =
--- true })` — the statuses as of the last `commit()` (a run's start, its end,
--- a collect) — so a running run's per-case changes never cause an `update`,
--- while `get` and the `update` sent (the current state) include them.
--- `commit()` bumps `rev`.

local test_state = require("loomworks.test_state")

local M = {}

local IS_WIN = package.config:sub(1, 1) == "\\"

--- @class loomworks.daemon.TestResult
--- @field status "passed"|"failed"|"skipped"|"errored"
--- @field duration? integer milliseconds
--- @field message? string the first failure line
--- @field output? string the captured output (at most OUTPUT_CAP bytes, its end)
--- @field truncated? boolean output was cut
--- @field errors? { message: string, file?: string, line?: integer }[]

--- @class loomworks.daemon.TestsRecord
--- @field outcome "ok"|"error"|"avail"
--- @field entries? table[] the unit's merged test entries (`ok`)
--- @field message? string why (`error`)
--- @field fp string the unit's build fingerprint when its discovery started
--- @field mark integer the unit's run mark when its discovery started

--- @class loomworks.daemon.TestStore
--- @field service table the build service
--- @field records table<table, loomworks.daemon.TestsRecord> unit → its last discovery (weak keys)
--- @field marks table<table, integer> unit → its run mark (weak keys)
--- @field discovered table|nil the profile of the last discovery that ran to its end
--- @field discovering { task: table, profile: table }|nil the running discovery
--- @field ids table<string, string> local key → node id
--- @field keys table<string, string> node id → local key
--- @field holders table<string, table> local key → the object the session id registry issued its id for
--- @field results table<string, loomworks.daemon.TestResult> local key → last result
--- @field live table<string, "queued"|"running"> local key → status of a running run
--- @field committed table<string, table> local key → { status, duration?, message? } as of the last commit
--- @field rev integer bumped by every commit
--- @field held table<string, table> normalized build dir → the queue entry holding it
--- @field waiting table[] queue entries waiting, FIFO
--- @field prepared table<string, table> prepare_debug token → { conn, root, path, results, tu, by_entry }
local Store = {}
Store.__index = Store

--- The most bytes of a node's output `Tests/1.result` answers (its end).
M.OUTPUT_CAP = 256 * 1024

--- The store of a build service, created on first use.
--- @param service table
--- @return loomworks.daemon.TestStore
function M.of(service)
    local s = service._test_store
    if not s then
        s = setmetatable({ ids = {}, keys = {}, holders = {}, results = {}, live = {}, committed = {}, rev = 0,
            records = setmetatable({}, { __mode = "k" }), marks = setmetatable({}, { __mode = "k" }),
            held = {}, waiting = {}, prepared = {}, _next_token = 0 }, Store)
        s.service = service
        service._test_store = s
    end
    return s
end

--- The id of the node with local key `key` (issued on first sight, through
--- the session's id registry: never reused, carries the session generation).
--- @param key string
--- @return string
function Store:node_id(key)
    local id = self.ids[key]
    if not id then
        local holder = {}
        id = self.service.ids:id(holder)
        self.holders[key] = holder
        self.ids[key], self.keys[id] = id, key
    end
    return id
end

--- The local key an id was issued for (nil: not a node id of this session).
--- @param id string
--- @return string|nil
function Store:key_of(id)
    if type(id) ~= "string" then return nil end
    return self.keys[id]
end

--- A unit's discovered entries, as its last discovery left them (see the
--- header): `ok` with its entries, `error` with its message, else (never
--- discovered, or nothing to probe) `pending`.
--- @param unit table
--- @return table[]|nil entries, string outcome, string|nil message
function Store:entries_of(unit)
    local rec = self.records[unit]
    if not rec or rec.outcome == "avail" then return nil, "pending" end
    if rec.outcome == "error" then return nil, "error", rec.message end
    return rec.entries or {}, "ok"
end

-- ---------------------------------------------------------------------------
-- Staleness
-- ---------------------------------------------------------------------------

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
--- @param unit table
--- @return integer
function Store:mark_of(unit)
    return self.marks[unit] or 0
end

--- Is the unit's record current: recorded with the unit's present
--- fingerprint and run mark (`tree`: and holding a tree)?
--- @param unit table
--- @param tree? boolean
--- @return boolean
function Store:fresh(unit, tree)
    local rec = self.records[unit]
    if not rec or rec.fp ~= M.fingerprint(unit) or rec.mark ~= self:mark_of(unit) then return false end
    return not tree or rec.outcome == "ok"
end

--- Record a unit's discovery: `rec.fp` / `rec.mark` as the caller took them
--- when the discovery started, else the unit's present ones.
--- @param unit table
--- @param rec loomworks.daemon.TestsRecord
function Store:set_record(unit, rec)
    rec.fp = rec.fp or M.fingerprint(unit)
    rec.mark = rec.mark or self:mark_of(unit)
    self.records[unit] = rec
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
--- @param ws table|nil
--- @return boolean
function Store:stale(ws)
    local ap = test_state.active_profile(ws)
    if not ap then return false end
    if self.discovered ~= ap then return true end
    for _, u in ipairs(M.profile_units(ap)) do
        if not self:fresh(u.unit) then return true end
    end
    return false
end

--- The operations whose end marks the units they covered (their trees may
--- no longer match the build): `cases` is an editor test run or test debug
--- preparation (`Tests/1.run_cases` / `prepare_debug`), which builds.
local MARKING = { build = true, configure = true, clean = true, reset = true, test = true, run = true, debug = true,
    cases = true }

--- The operations that build only without `no_build`.
local BUILDS_UNLESS_NO_BUILD = { run = true, debug = true, cases = true }

--- A run of the service ended (Service:on_run_done): a configure, build,
--- clean, reset or test run — or a launch preparation or editor test run
--- that built (not one with `no_build`) — marks the units it covered (every
--- unit of the workspace when its scope is not known). An editor test run
--- that ended before it was registered (no `ctx`) built nothing. The views'
--- update follows at the end of the model segment it ended in, or here when
--- it ended outside one.
--- @param service table
--- @param run table
function M.on_run_done(service, run)
    if not MARKING[run.op] then return end
    local ctx = run.ctx
    if run.op == "cases" and not ctx then return end
    if BUILDS_UNLESS_NO_BUILD[run.op] and ctx and ctx.args and ctx.args.no_build then return end
    local st = M.of(service)
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

-- ---------------------------------------------------------------------------
-- Node statuses
-- ---------------------------------------------------------------------------

--- A node's current status: a running run's (queued, running), else its
--- last result.
--- @param key string
--- @return table|nil { status, duration?, message? }
function Store:current(key)
    local l = self.live[key]
    if l then return { status = l } end
    return self.results[key]
end

--- The builder options of `view.Tests/1` (loomworks.test_state) in the
--- daemon for the workspace `ws`. `committed`: the statuses as of the last
--- commit (see the header).
--- @param ws table
--- @param o? { committed?: boolean }
--- @return loomworks.TestsViewOpts
function Store:view_opts(ws, o)
    local committed = o and o.committed
    local service = self.service
    local ap = test_state.active_profile(ws)
    local d = self.discovering
    return {
        id = function(obj) return service.ids:id(obj) end,
        node_id = function(_, key) return self:node_id(key) end,
        result_of = function(_, key)
            if committed then return self.committed[key] end
            return self:current(key)
        end,
        tree_of = function(unit) return self:entries_of(unit) end,
        stale = self:stale(ws),
        discovering = (d and ap and d.profile == ap and not d.task.finished) and d.task.id or nil,
    }
end

--- Take the current statuses as the committed ones (a run started or
--- ended, a collect recorded results); bumps `rev`.
function Store:commit()
    local c = {}
    for key in pairs(self.results) do
        local r = self:current(key)
        if r then c[key] = { status = r.status, duration = r.duration, message = r.message } end
    end
    for key, st in pairs(self.live) do c[key] = { status = st } end
    self.committed = c
    self.rev = self.rev + 1
end

--- Record a node's last result (its live status ends).
--- @param key string
--- @param r loomworks.daemon.TestResult
function Store:record(key, r)
    self.live[key] = nil
    self.results[key] = r
end

-- ---------------------------------------------------------------------------
-- The node index of the active profile
-- ---------------------------------------------------------------------------

--- @class loomworks.daemon.TestNodeRec
--- @field id string
--- @field key string the local key
--- @field kind "target"|"suite"|"test"
--- @field unit table the ConfigUnit
--- @field project string the project key
--- @field entry table|nil the discovered entry (nil for a suite)
--- @field target table|nil the top-level entry it belongs to (itself for a target)
--- @field suite string|nil a suite's name, or a test's suite
--- @field name string
--- @field runnable boolean
--- @field message string|nil a non-runnable entry's message
--- @field children loomworks.daemon.TestNodeRec[]

--- The nodes of the active profile's discovered units, as the view numbers
--- them (loomworks.test_state.nodes: explicit suites, unit-scoped keys).
--- @param ws table
--- @return { profile: table|nil, units: table[], by_id: table<string, loomworks.daemon.TestNodeRec>, list: loomworks.daemon.TestNodeRec[], tops: table<table, loomworks.daemon.TestNodeRec[]> }
function Store:index(ws)
    local idx = { units = {}, by_id = {}, list = {}, tops = {} }
    local ap = test_state.active_profile(ws)
    idx.profile = ap
    if not ap then return idx end
    for _, u in ipairs(M.profile_units(ap)) do
        local unit, project, configuration = u.unit, u.project, u.configuration
        local avail = unit.test_availability and unit:test_availability() or nil
        local entries, outcome = nil, nil
        if not avail then entries, outcome = self:entries_of(unit) end
        if entries and outcome ~= "error" then
            idx.units[#idx.units + 1] = u
            local tops, by_entry, suites, top_list = {}, {}, {}, {}
            for _, e in ipairs(entries) do
                if type(e) == "table" and type(e.id) == "string" and not e.parent then tops[e.id] = e end
            end
            local function add(rec)
                rec.id = self:node_id(rec.key)
                rec.unit, rec.project, rec.children = unit, project, {}
                idx.by_id[rec.id] = rec
                idx.list[#idx.list + 1] = rec
                return rec
            end
            for _, e in ipairs(entries) do
                if type(e) == "table" and type(e.id) == "string" then
                    local rec = { key = test_state.local_key(project, configuration, e.id), entry = e,
                        name = tostring(e.name or e.id), runnable = e.runnable == true,
                        message = type(e.message) == "string" and e.message or nil }
                    local top = e.parent and tops[e.parent] or nil
                    if not e.parent then
                        rec.kind, rec.target = "target", e
                        add(rec)
                        top_list[#top_list + 1] = rec
                    else
                        rec.kind = "test"
                        local suite = top and test_state.split_case(e.name) or nil
                        local parent
                        if suite then
                            local skey = test_state.suite_key(project, configuration, top.id, suite)
                            parent = suites[skey]
                            if not parent then
                                parent = add({ key = skey, kind = "suite", name = suite, suite = suite, target = top,
                                    runnable = top.runnable == true })
                                suites[skey] = parent
                                local tp = by_entry[top.id]
                                if tp then tp.children[#tp.children + 1] = parent end
                            end
                            rec.suite = suite
                        else
                            parent = by_entry[e.parent]
                            if not parent then rec.kind = "target" end
                        end
                        rec.target = top or (rec.kind == "target" and e) or (parent and parent.target) or e
                        add(rec)
                        if parent then parent.children[#parent.children + 1] = rec end
                        if rec.kind == "target" then top_list[#top_list + 1] = rec end
                    end
                    by_entry[e.id] = rec
                end
            end
            idx.tops[unit] = top_list
        end
    end
    return idx
end

--- A node and every node below it, depth first.
--- @param rec loomworks.daemon.TestNodeRec
--- @param out? loomworks.daemon.TestNodeRec[]
--- @return loomworks.daemon.TestNodeRec[]
function M.subtree(rec, out)
    out = out or {}
    out[#out + 1] = rec
    for _, c in ipairs(rec.children or {}) do M.subtree(c, out) end
    return out
end

-- ---------------------------------------------------------------------------
-- The build-directory operation queue of the Tests/1 tasks (§5.3, FIFO)
-- ---------------------------------------------------------------------------

local function dir_key(d)
    local k = tostring(d):gsub("\\", "/"):gsub("/+$", "")
    if IS_WIN then k = k:lower() end
    return k
end

--- Wait (FIFO) until no other Tests/1 task of this daemon holds one of
--- `dirs`, then hold them all and call `fn(entry)`. Returns the entry, which
--- `release` frees (also while it still waits: it is dropped from the
--- queue). `fn` may run before this returns (the directories are free) and
--- the task may end inside it: it gets the entry, so it can release it then.
--- A task of another kind (a build) still meets the build-directory lock
--- itself, which fails fast (§19.3).
--- @param dirs string[]
--- @param fn fun(entry: table)
--- @return table entry
function Store:acquire_dirs(dirs, fn)
    local e = { keys = {}, fn = fn }
    for _, d in ipairs(dirs or {}) do e.keys[#e.keys + 1] = dir_key(d) end
    self.waiting[#self.waiting + 1] = e
    self:_grant()
    return e
end

--- Can `e` take its directories now?
function Store:_free(e)
    for _, k in ipairs(e.keys) do
        if self.held[k] and self.held[k] ~= e then return false end
    end
    return true
end

--- Grant waiting entries in order; an entry never passes an earlier one
--- that waits for one of its directories.
function Store:_grant()
    local i, blocked = 1, {}
    while i <= #self.waiting do
        local e = self.waiting[i]
        local ok = self:_free(e)
        for _, k in ipairs(e.keys) do if blocked[k] then ok = false end end
        if ok then
            table.remove(self.waiting, i)
            for _, k in ipairs(e.keys) do self.held[k] = e end
            e.granted = true
            local fn = e.fn
            e.fn = nil
            fn(e)
        else
            for _, k in ipairs(e.keys) do blocked[k] = true end
            i = i + 1
        end
    end
end

--- Release an entry of `acquire_dirs` (idempotent).
--- @param e table|nil
function Store:release(e)
    if not e or e.released then return end
    e.released = true
    e.fn = nil
    for i, w in ipairs(self.waiting) do
        if w == e then table.remove(self.waiting, i); break end
    end
    for _, k in ipairs(e.keys) do
        if self.held[k] == e then self.held[k] = nil end
    end
    self:_grant()
end

-- ---------------------------------------------------------------------------
-- prepare_debug tokens
-- ---------------------------------------------------------------------------

--- Hold a prepared debug session for `conn`. Returns its token.
--- @param conn table
--- @param p table { root, path, results, tu, by_entry }
--- @return string
function Store:hold(conn, p)
    self._next_token = self._next_token + 1
    local token = string.format("pd-%s-%d", tostring(self.service.server and self.service.server.generation or 0),
        self._next_token)
    p.conn = conn
    self.prepared[token] = p
    return token
end

--- Take a token of `conn` (nil: not one it holds).
--- @param conn table
--- @param token string
--- @return table|nil
function Store:take(conn, token)
    local p = type(token) == "string" and self.prepared[token] or nil
    if not p or p.conn ~= conn then return nil end
    self.prepared[token] = nil
    return p
end

--- A path for comparison: `/`-separated, no repeated or trailing `/`,
--- lowercased on Windows.
local function norm_path(p)
    p = p:gsub("\\", "/"):gsub("/+", "/")
    if #p > 1 then p = p:gsub("/$", "") end
    if IS_WIN then p = p:lower() end
    return p
end

--- Remove a per-run results file of the workspace `root` (spec §19.15
--- "Tests": `<root>/.nvim/tmp/lw-test-<hex>.xml`, §16.40). Deletion safety:
--- only a regular file (lstat: never a directory or a link's target) that
--- is a direct child of `<root>/.nvim/tmp` (separator-bounded) whose name is
--- exactly `lw-test-<hex>.xml`, with `<root>/.nvim` and `<root>/.nvim/tmp`
--- real directories (lstat: never a link or junction); anything else is
--- refused and left alone.
--- @param root string|nil the workspace root
--- @param path string|nil
--- @return boolean removed
function M.unlink(root, path)
    if type(root) ~= "string" or root == "" or type(path) ~= "string" or path == "" then return false end
    local prefix = norm_path(root) .. "/.nvim/tmp"
    local p = norm_path(path)
    if p:sub(1, #prefix + 1) ~= prefix .. "/" then return false end
    if not p:sub(#prefix + 2):match("^lw%-test%-%x+%.xml$") then return false end
    local uv = vim.uv or vim.loop
    local r = root:gsub("[/\\]+$", "")
    for _, dir in ipairs({ r .. "/.nvim", r .. "/.nvim/tmp" }) do
        local dst = uv.fs_lstat(dir)
        if not dst or dst.type ~= "directory" then return false end
    end
    local st = uv.fs_lstat(path)
    if not st or st.type ~= "file" then return false end
    local ok, res = pcall(uv.fs_unlink, path)
    return ok and res == true
end
local unlink = M.unlink

--- Drop the tokens of `conn` (every one when nil: the daemon stops) with
--- their results files (only the token's own `path`).
--- @param conn table|nil
function Store:drop(conn)
    for token, p in pairs(self.prepared) do
        if conn == nil or p.conn == conn then
            self.prepared[token] = nil
            unlink(p.root, p.path)
        end
    end
end

return M
