--- loomworks/daemon/test_runs.lua — the editor's test runs and test debug
--- preparations in the workspace daemon (spec §19.15 "Tests", §19.20
--- `Tests/1`; step 5m part B2):
---
---   run_cases { select?, no_build?, extra? }   T  build the selection's targets, run it,
---                                                 `{ exit_code, error?, cases, counts }`
---   prepare_debug { select, no_build? }        T  the build of a run of one node, then its
---                                                 `{ debug, prepared }`
---   collect { prepared }                          the results a debugged program wrote
---   result { id }                                 a node's last result with its output
---   signal results { seq, task_id?, cases }       per-case progress, a collect's cases
---
--- Nodes are named by their `view.Tests/1` ids (loomworks.daemon.test_store:
--- unit-scoped, opaque); an id that names no node of the active profile's
--- discovered units is refused as a stale reference before acceptance, as is
--- a node that is not runnable.
---
--- **Steps.** The selection's nodes are resolved at acceptance (a stale or
--- non-runnable one refuses the call); the units the run covers are theirs,
--- or for run-all every unit of the profile with tests to discover. Inside
--- the task, before the build, a covered unit whose tree is not current
--- (never discovered, stale, failed, or its TestUnits no longer holding the
--- entries) is discovered first (loomworks.daemon.test_discover `prober`),
--- so run-all never skips an undiscovered unit and a stale tree's node runs
--- as its unit now has it — a node the re-discovery dropped ends the task as
--- a stale reference, a unit whose discovery failed runs nothing (the task
--- then fails). The nodes are then resolved to test steps, still before the
--- build (a build drops the TestUnits' cached entries): one per executable — a
--- selected `target` node runs it whole, its selected `suite` and `test`
--- nodes are combined into one filtered invocation where its TestUnit
--- filters (a gtest program), else it runs whole. Each step's command is the
--- TestUnit's structured harness (`test_command` through the owning unit,
--- §8.9.4) with its own results file `<root>/.nvim/tmp/lw-test-<hex>.xml`
--- (§16.40; removed once parsed). Run-all (no `select`) runs every runnable
--- top-level node of every covered unit, each its own step (never a
--- TestUnit's `test_command_all`).
---
--- **The task** is a daemon/runner.lua run (`op = "cases"`): it waits for the
--- other Tests/1 tasks of its build directories (FIFO, the store's queue),
--- then for a build or other task of this daemon holding one of them (as
--- discovery waits), discovers what needs it (above), takes their locks
--- (fail-fast against another process), builds (each
--- unit's selected targets, or the whole unit when a node has no single
--- build target; nothing with `no_build`), then runs the steps here, every
--- step even after one failed, the locks held throughout.
---
--- **Progress.** While a step runs its gtest-format output moves its cases to
--- `running` and their results, sent as `results` batched every BATCH_MS; at
--- the step's end the results file is authoritative and its cases are sent
--- once more. The run's last `results` (with its target and suite nodes'
--- outcomes) precede the view's `update` that ends it (the store's `commit`);
--- a run that ends early (a cancel, a failed build) drops the statuses its
--- nodes still had (`queued`, `running`): unknown, the earlier last result not
--- restored.

local build_run = require("loomworks.build_run")
local core_ifaces = require("loomworks.daemon.core_interfaces")
local tasks_mod = require("loomworks.daemon.tasks")
local test_store = require("loomworks.daemon.test_store")

local M = {}

local uv = vim.uv or vim.loop

--- The `results` batch interval of a run (at most about 4 per second).
M.BATCH_MS = 250

local STALE = "no such test (a stale reference): "

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------

--- The first non-empty line of a message.
local function first_line(msg)
    if type(msg) ~= "string" then return nil end
    for line in msg:gmatch("[^\r\n]+") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" then return t end
    end
    return nil
end

--- A text's last `cap` bytes (never splitting a UTF-8 character), and
--- whether it was cut.
local function tail(text, cap)
    if type(text) ~= "string" or #text <= cap then return text, nil end
    local start = #text - cap + 1
    while start <= #text do
        local b = text:byte(start)
        if b < 0x80 or b > 0xBF then break end
        start = start + 1
    end
    return text:sub(start), true
end
M._tail = tail

local function millis(d)
    if type(d) ~= "number" or d ~= d then return nil end
    return math.max(0, math.floor(d + 0.5))
end

--- A node's `TestCaseResult`.
local function case_result(id, r)
    return { id = id, status = r.status, duration = millis(r.duration), message = r.message }
end

--- Send `Tests/1.results` (to the subscribers of /tests). `seq` is the
--- frame's own: gapless per object and connection (§19.12).
--- @param service table
--- @param task_id string|nil
--- @param cases table[]
function M.emit(service, task_id, cases)
    local reg = service.server and service.server.interfaces
    if not reg or #cases == 0 then return end
    local w = core_ifaces.TESTS
    if not reg:has_subscribers(w.path, w.iface, w.v, "results") then return end
    reg:emit(w.path, w.iface, w.v, "results", function(_, seq)
        return { seq = seq, task_id = task_id, cases = cases }
    end)
end

--- The batcher of a run's `results`: `add(id, r)` queues a case's current
--- status (a later one replaces it), `flush()` sends what is queued.
local function batcher(service, task_id)
    local b = { order = {}, by_id = {} }
    local timer
    function b.add(id, r)
        if not b.by_id[id] then b.order[#b.order + 1] = id end
        b.by_id[id] = case_result(id, r)
        if not timer and not b.closed then
            timer = uv.new_timer()
            timer:start(M.BATCH_MS, 0, function()
                vim.schedule(function() b.flush() end)
            end)
        end
    end
    function b.flush()
        if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
        local cases = {}
        for _, id in ipairs(b.order) do cases[#cases + 1] = b.by_id[id] end
        b.order, b.by_id = {}, {}
        M.emit(service, task_id, cases)
    end
    function b.close()
        b.closed = true
        if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
        b.order, b.by_id = {}, {}
    end
    return b
end

--- A parsed results entry as a stored last result.
local function to_result(r, captured)
    local errors = {}
    for _, e in ipairs(type(r.errors) == "table" and r.errors or {}) do
        if type(e) == "table" then
            errors[#errors + 1] = { message = tostring(e.message or ""),
                file = type(e.file) == "string" and (e.file:gsub("\\", "/")) or nil,
                line = type(e.line) == "number" and math.floor(e.line) or nil }
        end
    end
    local status = r.status
    if status ~= "passed" and status ~= "failed" and status ~= "skipped" and status ~= "errored" then
        status = "errored"
    end
    local output = type(r.output) == "string" and r.output ~= "" and r.output or captured
    local truncated
    output, truncated = tail(output, test_store.OUTPUT_CAP)
    return { status = status, duration = millis(r.duration), message = first_line(r.message),
        output = output, truncated = truncated, errors = errors }
end

-- ---------------------------------------------------------------------------
-- Resolution: the selection → test steps
-- ---------------------------------------------------------------------------

--- The build target of a unit that produces `exe` (by artifact path, else by
--- name), or nil.
local function build_target_of(ws, unit, exe)
    if type(exe) ~= "string" or exe == "" then return nil end
    build_run.ensure_unit_targets(ws, unit)
    local function norm(p)
        local n = tostring(p):gsub("\\", "/")
        if package.config:sub(1, 1) == "\\" then n = n:lower():gsub("%.exe$", "") end
        return n
    end
    local want = norm(exe)
    local base = (exe:match("[/\\]([^/\\]+)$") or exe):gsub("%.[eE][xX][eE]$", "")
    local bd = unit.build_dir and unit:build_dir() or nil
    local by_name
    for id, t in pairs(type(unit.targets) == "table" and unit.targets or {}) do
        if not t.is_executable or t:is_executable() then
            if bd and type(t.artifact) == "string" then
                local ok, p = pcall(require("loomworks.paths").artifact_path, bd, t.artifact)
                if ok and p and norm(p) == want then return t.id or id end
            end
            if id == base or t.id == base then by_name = t.id or id end
        end
    end
    return by_name
end

--- A test step's command through the owning unit, with its results file.
--- @return table|nil cmd, table|nil tu
local function command(unit, entry_id, opts)
    return unit:test_command_for(entry_id, opts)
end

--- The runnable top-level nodes of run-all: those of the units the run
--- covered at acceptance (`covered`), never of a unit that became runnable
--- since (its directory is not the run's: no queue entry, no lock).
--- @param idx table the store's index
--- @param covered table[] the run's units ({ unit, ... })
--- @return loomworks.daemon.TestNodeRec[]
function M.run_all_recs(idx, covered)
    local recs = {}
    for _, u in ipairs(covered) do
        for _, rec in ipairs(idx.tops[u.unit] or {}) do
            if rec.runnable then recs[#recs + 1] = rec end
        end
    end
    return recs
end

--- The steps of resolved nodes (a selection, or run-all's `run_all_recs`).
--- @param ws table
--- @param store loomworks.daemon.TestStore
--- @param idx table the store's index
--- @param recs loomworks.daemon.TestNodeRec[]
--- @param extra string[]|nil
--- @return table[]|nil steps, string|nil err
function M.steps(ws, store, idx, recs, extra)
    -- One group per executable (unit + top-level entry), in selection order.
    local groups, by_target = {}, {}
    for _, rec in ipairs(recs) do
        local tkey = tostring(rec.unit) .. "\0" .. tostring(rec.target and rec.target.id or rec.key)
        local g = by_target[tkey]
        if not g then
            g = { unit = rec.unit, project = rec.project, target = rec.target, items = {} }
            by_target[tkey] = g
            groups[#groups + 1] = g
        end
        if rec.kind == "target" then g.whole = true end
        g.items[#g.items + 1] = rec
        if rec.kind == "target" then g.target_rec = rec end
    end
    local steps = {}
    for _, g in ipairs(groups) do
        local unit, target = g.unit, g.target
        local path = require("loomworks.housekeeping").tmp_path(ws.root, "lw-test-", ".xml")
        local cmd, tu, name
        local canfilter = target and target.framework == "gtest"
        if not g.whole and #g.items == 1 then
            local rec = g.items[1]
            if rec.kind == "suite" then
                if canfilter then
                    cmd, tu = command(unit, target.id, { gtest_filter = rec.suite .. ".*", output_path = path })
                end
                name = (target.name or target.id) .. ": " .. rec.name
            else
                cmd, tu = command(unit, rec.entry.id, { output_path = path })
                name = (target and (target.name or target.id) .. ": " or "") .. rec.entry.name
            end
        elseif not g.whole and canfilter then
            -- The selected suites and cases of one program as one filtered
            -- invocation: each case's filter as its TestUnit would set it.
            local filters = {}
            for _, rec in ipairs(g.items) do
                if rec.kind == "suite" then
                    filters[#filters + 1] = rec.suite .. ".*"
                else
                    local c = command(unit, rec.entry.id, { output_path = path })
                    local f = c and c.env and c.env.GTEST_FILTER
                    if type(f) ~= "string" or f == "" then filters = nil; break end
                    filters[#filters + 1] = f
                end
            end
            if filters then
                cmd, tu = command(unit, target.id, { gtest_filter = table.concat(filters, ":"), output_path = path })
                name = (target.name or target.id) .. " (" .. #g.items .. " selected)"
            end
        end
        if not cmd then
            -- The program whole: a target node, or a selection its TestUnit
            -- cannot filter.
            g.whole = true
            if target then cmd, tu = command(unit, target.id, { output_path = path }) end
            name = target and (target.name or target.id) or "?"
        end
        if not cmd or type(cmd.cmd) ~= "table" or #cmd.cmd == 0 then
            return nil, string.format("%s: cannot run test '%s' (its TestUnit has no command for it)",
                g.project, tostring(name))
        end
        local argv = vim.deepcopy(cmd.cmd)
        for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
        -- The nodes the step runs: what was selected and everything below it.
        local nodes, seen = {}, {}
        local heads = g.whole and { g.target_rec or g.items[1] } or g.items
        if g.whole and not g.target_rec then
            for _, rec in ipairs(idx.tops[unit] or {}) do
                if rec.target == target then heads = { rec } end
            end
        end
        for _, h in ipairs(heads) do
            for _, n in ipairs(test_store.subtree(h)) do
                if not seen[n] then seen[n] = true; nodes[#nodes + 1] = n end
            end
        end
        -- Entry id → node and case name → node, for its results and progress.
        local by_entry, by_case = {}, {}
        for _, rec in ipairs(idx.list) do
            if rec.unit == unit and rec.entry then
                by_entry[rec.entry.id] = rec
                if rec.kind == "test" and rec.target == target then by_case[tostring(rec.entry.name)] = rec end
            end
        end
        steps[#steps + 1] = {
            unit = unit, project = g.project, name = name, tu = tu, path = path, results = cmd.output_path or path,
            spec = { cmd = argv, cwd = cmd.cwd, env = cmd.env }, prepare = cmd.prepare,
            nodes = nodes, by_entry = by_entry, by_case = by_case, head = heads[1], target = target,
            build_target = target and build_target_of(ws, unit, target.executable) or nil,
        }
    end
    return steps
end

--- The distinct units of steps, in order.
local function units_of(steps)
    local out, seen = {}, {}
    for _, s in ipairs(steps) do
        if not seen[s.unit] then seen[s.unit] = true; out[#out + 1] = s.unit end
    end
    return out
end

--- The build of the steps' units: each unit's steps' build targets, or the
--- whole unit when one of them has none.
local function plan_build(steps)
    local all = {}
    for _, unit in ipairs(units_of(steps)) do
        local targets, whole = {}, false
        for _, s in ipairs(steps) do
            if s.unit == unit then
                if s.build_target then
                    targets[#targets + 1] = { project = s.project, target = s.build_target }
                else
                    whole = true
                end
            end
        end
        local planned, err = build_run.plan(nil, { units = { unit },
            build_targets = (not whole and #targets > 0) and targets or nil })
        if not planned then return nil, err end
        for _, st in ipairs(planned) do all[#all + 1] = st end
    end
    return all
end

-- ---------------------------------------------------------------------------
-- Acceptance
-- ---------------------------------------------------------------------------

--- Resolve `select` against the index: the nodes, or the refusal.
--- @return loomworks.daemon.TestNodeRec[]|nil, string|nil
local function resolve(idx, select)
    local out, seen = {}, {}
    for _, ref in ipairs(select) do
        local rec = idx.by_id[ref.id]
        if not rec then return nil, STALE .. tostring(ref.id) end
        if not rec.runnable then
            return nil, "test '" .. rec.name .. "' cannot be run" .. (rec.message and (": " .. rec.message) or "")
        end
        if not seen[rec] then seen[rec] = true; out[#out + 1] = rec end
    end
    return out
end

--- The model segment that accepts a run_cases or prepare_debug.
--- @param service table
--- @param ctx table
--- @param kind "test"|"debug"
local function accept(service, ctx, kind)
    if ctx.conn.closed then return end
    local ws, refusal, decline = service:live(ctx)
    if not ws then
        if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
        return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if ctx.refused then
        return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local a = ctx.args
    local function refuse(msg) return ctx.reply({ outcome = "refused", message = msg, exit_code = 1,
        notes = ctx.notes, note_roles = ctx.note_roles }) end
    -- (The nodes first: an id of no node of the active profile is a stale
    -- reference, also when no profile is active.)
    local store = test_store.of(service)
    local idx = store:index(ws)
    local recs
    if a.select ~= nil then
        local rerr
        recs, rerr = resolve(idx, kind == "debug" and { a.select } or a.select)
        if not recs then return refuse(rerr) end
    end
    -- (Tests/1 acts on the active profile, §19.15 "Tests".)
    local profile = idx.profile
    if not profile then return refuse(require("loomworks.daemon.test_discover").NO_PROFILE) end
    -- The units the run covers (§19.15 "Tests"): the selection's, or for
    -- run-all every unit of the profile with tests to discover.
    local covered, units, picked = {}, {}, {}
    for _, rec in ipairs(recs or {}) do picked[rec.unit] = true end
    for _, u in ipairs(test_store.profile_units(profile)) do
        if (recs and picked[u.unit]) or (not recs and not u.unit:test_availability()) then
            covered[#covered + 1] = u
            units[#units + 1] = u.unit
        end
    end
    local task = service.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.profile, ctx.units = task, ws, profile, units
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile.key,
        pid = service.server.pid, notes = ctx.notes, note_roles = ctx.note_roles })
    -- The task is accepted: from here a throw before the runner has the run
    -- (which `ctx.run` would cancel) ends the task itself.
    local pok, phase = pcall(M.phase, service, ctx, store, { recs = recs, covered = covered, idx = idx }, kind)
    if not pok then
        service.server:log("internal error in a test run: %s", tostring(phase))
        -- (A `done` frame needs the task's `start` before it.)
        local meta_units = {}
        for _, u in ipairs(covered) do
            meta_units[#meta_units + 1] = { project = u.project, configuration = u.configuration }
        end
        task:start({ name = profile.key, kind = kind, profile = profile.key, units = meta_units })
        task:done(1, "internal error: " .. tostring(phase))
        return
    end
    -- The run is this request's before any of its work: with free
    -- directories, nothing to discover and no build, everything up to the
    -- steps' commands runs inside this segment, and a throw there must find
    -- `ctx.run` to cancel (its end frees the queue entry and the locks).
    require("loomworks.daemon.runner").run(service, {
        op = "cases", task = task, ws = ws, profile = profile, units = units, env = ctx.env,
        command = ctx.command, args = {}, cases = phase,
        on_run = function(run)
            run.ctx = ctx
            ctx.run = run
            service.runs[run] = true
        end,
    })
    service.server:log("%s %s (task %s) accepted", kind == "debug" and "test debug" or "test cases",
        profile.key, task.id)
end

--- A task-streamed Tests/1 method's handler.
local function task_method(service, method, kind)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(ictx, args)
        local srv = service.server
        local ctx = { op = "cases", conn = ictx.conn, env = ictx.env, args = args, command = "lw test",
            call = core_ifaces.task_call(ictx.registry, core_ifaces.TESTS, method) }
        function ctx.reply(fields)
            ctx.replied = true
            service:_before_ack(ctx)
            ictx.reply(fields)
        end
        if service.stopping or srv.stopped then
            return { outcome = "declined", reason = "the workspace runtime is stopping" }
        end
        if srv.retiring then return { outcome = "declined", reason = "the daemon is retiring" } end
        service:with_model(ctx, function() accept(service, ctx, kind) end)
        return interfaces.ASYNC
    end
end

-- ---------------------------------------------------------------------------
-- The task's phase after the build
-- ---------------------------------------------------------------------------

--- The gtest progress lines: `[ RUN      ] Suite.Case`, `[       OK ] …`,
--- `[  FAILED  ] … (N ms)`, `[  SKIPPED ] …`.
local function progress_line(line)
    local tag, rest = line:match("^%[%s*(%u+)%s*%]%s+(.-)%s*$")
    if not tag then return nil end
    local name, ms = rest:match("^(%S+)%s+%((%d+) ms%)$")
    if tag == "RUN" then return "running", rest:match("^(%S+)") end
    if not name then return nil end
    if tag == "OK" then return "passed", name, tonumber(ms) end
    if tag == "FAILED" then return "failed", name, tonumber(ms) end
    if tag == "SKIPPED" then return "skipped", name, tonumber(ms) end
    return nil
end
M._progress_line = progress_line

--- Does a covered unit need discovering before the run (§19.15 "Tests"):
--- its tree not current (never discovered, stale, failed), or its TestUnits
--- no longer holding the entries its tree came from?
--- @param store loomworks.daemon.TestStore
--- @param unit table
--- @return boolean
local function needs_discovery(store, unit)
    if unit._removed or unit:test_availability() then return false end
    if not store:fresh(unit, true) then return true end
    local rec = store.records[unit]
    return #(rec.entries or {}) > 0 and unit:test_tree() == nil
end

--- The runner hooks (`ctx.cases`) of an accepted run_cases / prepare_debug.
--- `sel`: the selected nodes as accepted (`recs`, nil for run-all), the
--- covered units (`covered`, as test_store.profile_units lists them) and
--- the index they were resolved in (`idx`). The test steps are resolved in
--- `plan`, after the units that needed it were discovered (`wait`).
--- @param service table
--- @param ctx table the accepted request
--- @param store loomworks.daemon.TestStore
--- @param sel { recs: loomworks.daemon.TestNodeRec[]|nil, covered: table[], idx: table }
--- @param kind "test"|"debug"
--- @return table
function M.phase(service, ctx, store, sel, kind)
    local task = ctx.task
    local batch = batcher(service, task.id)
    local mine = {} -- keys whose live status this run set
    local entry -- the queue entry
    local files = {}
    local steps = {} -- resolved in plan()
    local prober -- the discovery of the covered units (wait)
    local disc_failed, failed_unit = {}, {} -- labels / units whose discovery failed
    local phase = { kind = kind }

    local function set_live(rec, st)
        mine[rec.key] = true
        store.live[rec.key] = st
    end

    -- The run starts: its nodes, as the tree has them now, are queued (the
    -- view's `update`); `plan` adjusts that to the steps it resolves.
    -- (A throw here has no run to end it yet: the marks are dropped before
    -- it goes on to `accept`, which ends the task.)
    if kind == "test" then
        local ok, err = pcall(function()
            local heads = sel.recs or M.run_all_recs(sel.idx, sel.covered)
            for _, h in ipairs(heads) do
                for _, n in ipairs(test_store.subtree(h)) do set_live(n, "queued") end
            end
            store:commit()
        end)
        if not ok then
            for key in pairs(mine) do store.live[key] = nil end
            pcall(store.commit, store)
            batch.close()
            error(err, 0)
        end
    end

    --- The discovery failures, as the task's error (nil: none).
    local function disc_error()
        if #disc_failed == 0 then return nil end
        return "test discovery failed: " .. table.concat(disc_failed, ", ")
    end
    phase.disc_error = disc_error

    --- The steps of the run, in the tree as discovered now; then the build.
    function phase.plan()
        local idx = store:index(ctx.ws)
        local recs
        if sel.recs then
            recs = {}
            for _, old in ipairs(sel.recs) do
                local rec = idx.by_id[old.id]
                if not rec then
                    -- (A unit whose discovery failed runs nothing.)
                    if not failed_unit[old.unit] then return nil, STALE .. tostring(old.id) end
                elseif not rec.runnable then
                    return nil, "test '" .. rec.name .. "' cannot be run" .. (rec.message and (": " .. rec.message) or "")
                else
                    recs[#recs + 1] = rec
                end
            end
        else
            recs = M.run_all_recs(idx, sel.covered)
        end
        local resolved, serr = M.steps(ctx.ws, store, idx, recs, kind == "test" and ctx.args.extra or nil)
        if not resolved then return nil, serr end
        if kind == "debug" and #resolved ~= 1 then
            return nil, disc_error() or "cannot debug: the node runs no single test program"
        end
        steps = resolved
        for _, s in ipairs(steps) do files[#files + 1] = s.path end
        if kind == "test" then
            local now = {}
            for _, s in ipairs(steps) do
                for _, n in ipairs(s.nodes) do now[n.key] = true end
            end
            for key in pairs(mine) do
                if not now[key] then store.live[key] = nil; mine[key] = nil end
            end
            for _, s in ipairs(steps) do
                for _, n in ipairs(s.nodes) do set_live(n, "queued") end
            end
            store:commit()
        end
        if ctx.args.no_build then return {} end
        return plan_build(steps)
    end

    --- Wait for the directories (§19.15 "Tests"): the Tests/1 queue (FIFO),
    --- then a build or other task of this daemon holding one of them (as
    --- discovery waits); then discover the covered units that need it, and
    --- `fn` (the runner takes the locks, plans and builds).
    function phase.wait(dirs, fn, api)
        local run = api.run
        phase.task_run = run
        prober = require("loomworks.daemon.test_discover").prober(service, ctx, run,
            { task = task, ws = ctx.ws, current = api.current })
        local build_lock = require("loomworks.build_lock")
        local probed, waited = {}, false
        local ready
        ready = function()
            if run.finished or run.cancelled then return end
            local okc, why = api.current()
            if not okc then return api.finish(1, api.stopped(why)) end
            for _, d in ipairs(dirs) do
                if build_lock.held_by_me(d) then
                    if not waited then
                        waited = true
                        local ws = ctx.ws
                        task:line("note", "waiting for " .. (ws._display_build_dir and ws:_display_build_dir(d) or d)
                            .. " (in use by another task of this workspace)", "plain")
                    end
                    vim.defer_fn(function() service:with_model(ctx, ready) end,
                        require("loomworks.daemon.test_discover").WAIT_POLL_MS)
                    return
                end
            end
            for _, u in ipairs(sel.covered) do
                if not probed[u.unit] and needs_discovery(store, u.unit) then
                    probed[u.unit] = true
                    local label = u.project .. "/" .. u.configuration
                    return prober.probe(u, label, function(outcome, v)
                        if outcome == "stopped" then
                            if v == nil then return api.finish(run.cancel_code or 1, api.stopped()) end
                            return api.finish(1, api.stopped(v))
                        end
                        if outcome == "error" then
                            disc_failed[#disc_failed + 1] = label
                            failed_unit[u.unit] = true
                        end
                        ready()
                    end)
                end
            end
            fn()
        end
        local now = true
        entry = store:acquire_dirs(dirs, function(e)
            -- (Before going on: the run may end inside it, and on_finish
            -- releases the entry — granted at once, acquire_dirs has not
            -- returned.)
            entry = e
            if now then return ready() end
            service:with_model(ctx, function() ready() end)
        end)
        now = false
        if not entry.granted then
            task:line("note", "waiting for another test task of the same build directory", "plain")
        end
    end

    function phase.on_finish()
        store:release(entry)
        if prober then
            -- A discovery still in flight: its programs killed, its unit's
            -- TestUnits (which may have cached "no framework") dropped.
            prober.kill()
            prober.close()
            local probing = phase.task_run and phase.task_run.probing
            if probing then pcall(probing.invalidate_tests, probing) end
        end
        batch.close()
        -- Statuses this run still set (a cancel, a failed build): unknown.
        local changed = false
        for key in pairs(mine) do
            if store.live[key] then store.live[key] = nil; changed = true end
        end
        mine = {}
        if changed then store:commit() end
        for i, p in ipairs(files) do
            if p ~= phase.kept then test_store.unlink(ctx.ws.root, p) end
            files[i] = nil
        end
    end

    function phase.after_build(api)
        if kind == "debug" then return phase.debug(api) end
        return phase.run(api)
    end

    --- The prepare_debug end: the step's program as a debug spec.
    function phase.debug(api)
        local s = steps[1]
        if type(s.prepare) == "function" then
            local ok, pok, perr = pcall(s.prepare)
            if not (ok and pok) then return api.finish(1, tostring((ok and perr) or pok or "preparation failed")) end
        end
        local spec, herr = build_run.spawn_spec(s.spec, api.ws.root)
        if not spec then return api.finish(1, herr) end
        local rp = require("loomworks.run_prep")
        local env = rp.env_overrides(spec.env)
        local args = {}
        for k = 2, #spec.cmd do args[#args + 1] = spec.cmd[k] end
        local launch = { name = s.name, cmd = spec.cmd[1], args = args, cwd = spec.cwd or api.ws.root,
            env = next(env) and env or vim.empty_dict() }
        -- The languages: a saved launch entry's, else the unit's module's.
        local lt = s.target and s.tu and s.tu._top_by_id and s.tu._top_by_id[s.target.id]
        lt = lt and lt.launch_target or { _project = s.unit._project }
        local debug = rp.debug_spec(api.ws, lt, launch)
        phase.kept = s.path
        local token = store:hold(ctx.conn, { root = api.ws.root, path = s.path, results = s.results, tu = s.tu, by_entry = s.by_entry })
        return api.finish(0, nil, { result = { debug = debug, prepared = token } })
    end

    --- The test steps, in order, every one even after one failed.
    function phase.run(api)
        local run = api.run
        local cases, counts = {}, { passed = 0, failed = 0, skipped = 0, errored = 0 }
        local si = 0
        local next_test

        local function report(rec, r)
            store:record(rec.key, r)
            mine[rec.key] = nil
            batch.add(rec.id, r)
        end

        local function step_done(s, code)
            -- The results file is authoritative; then what the output showed.
            local got, results = {}, s.tu and s.tu:parse_results(s.results) or nil
            test_store.unlink(ctx.ws.root, s.path)
            local step_cases = {}
            for _, r in ipairs(results or {}) do
                local rec = s.by_entry[r.test_id]
                if rec and not got[rec] then
                    got[rec] = true
                    local res = to_result(r, s.captured[tostring(rec.entry.name)])
                    report(rec, res)
                    step_cases[#step_cases + 1] = case_result(rec.id, res)
                end
            end
            for name, rec in pairs(s.by_case) do
                local st = s.seen[name]
                if st and not got[rec] then
                    got[rec] = true
                    local res = st
                    if res.status == "running" then
                        res = { status = "errored", message = "the test program ended (exit code " .. tostring(code)
                            .. ") before the case finished" }
                    end
                    res = to_result(res, s.captured[name])
                    report(rec, res)
                    step_cases[#step_cases + 1] = case_result(rec.id, res)
                end
            end
            -- Suites and targets: their cases' outcome, else the exit code.
            local failed_case = false
            for _, c in ipairs(step_cases) do
                if c.status == "failed" or c.status == "errored" then failed_case = true end
            end
            for k = #s.nodes, 1, -1 do
                local n = s.nodes[k]
                if not got[n] and (n.kind == "suite" or n.kind == "target") then
                    local agg
                    for _, c in ipairs(n.children) do
                        local r = got[c] and store.results[c.key] or nil
                        if r then
                            if r.status == "failed" or r.status == "errored" then agg = "failed"
                            elseif r.status == "passed" and agg ~= "failed" then agg = "passed"
                            elseif agg == nil then agg = r.status end
                        end
                    end
                    if n.kind == "target" and code ~= 0 and not failed_case then agg = nil end
                    if agg then
                        got[n] = true
                        report(n, { status = agg, errors = {} })
                    elseif n == s.head or n.kind == "target" then
                        local msg = code ~= 0 and ("exited with code " .. tostring(code)) or nil
                        local res = to_result({ status = code == 0 and "passed" or "failed", message = msg },
                            s.output)
                        got[n] = true
                        report(n, res)
                        -- (A program whose exit is its only result is one case.)
                        step_cases[#step_cases + 1] = case_result(n.id, res)
                    end
                end
            end
            -- Nodes the step reported nothing for: unknown.
            for _, n in ipairs(s.nodes) do
                if not got[n] and store.live[n.key] then store.live[n.key] = nil; mine[n.key] = nil end
            end
            for _, c in ipairs(step_cases) do
                cases[#cases + 1] = c
                if counts[c.status] then counts[c.status] = counts[c.status] + 1 end
            end
            batch.flush()
        end

        local function summary()
            batch.flush()
            store:commit()
            pcall(core_ifaces.header_check, service)
            local result = { cases = cases, counts = counts }
            local n = #cases
            local bad = counts.failed + counts.errored
            -- (A covered unit whose discovery failed ran nothing: the run fails.)
            local derr = disc_error()
            -- (The reply names it, so a client tells it from failed tests.)
            result.discovery_error = derr
            if n == 0 then
                if derr then return api.finish(1, derr, { result = result }) end
                api.task:line("out", "no tests to run for profile '" .. ctx.profile.key .. "'", "plain")
                return api.finish(0, nil, { result = result })
            end
            if bad == 0 then
                if derr then return api.finish(1, derr, { result = result }) end
                api.task:line("out", "TESTS OK: " .. ctx.profile.key .. " (" .. counts.passed .. " passed)", "ok")
                return api.finish(0, nil, { result = result })
            end
            return api.finish(1, bad .. " of " .. n .. " tests failed" .. (derr and ("; " .. derr) or ""),
                { result = result })
        end

        next_test = function()
            if run.cancelled then return api.finish(run.cancel_code, api.stopped()) end
            local okc, why = api.current()
            if not okc then return api.finish(1, api.stopped(why)) end
            si = si + 1
            if si > #steps then return summary() end
            local s = steps[si]
            s.seen, s.captured, s.out = {}, {}, {}
            api.task:progress(0.5 + (si - 1) / #steps / 2)
            api.task:line("out", require("loomworks.cli_color").header("test", s.project .. ": " .. s.name), "phase")
            if type(s.prepare) == "function" then
                local ok, pok, perr = pcall(s.prepare)
                if not (ok and pok) then
                    local msg = tostring((ok and perr) or pok or "preparation failed")
                    api.task:line("err", "lw: " .. msg .. "\n", "fail")
                    s.output = msg
                    step_done(s, 1)
                    return next_test()
                end
            end
            -- A program whose only result is its exit: running now.
            if #s.head.children == 0 then
                set_live(s.head, "running")
                batch.add(s.head.id, { status = "running" })
            end
            local partial, current, buf = "", nil, nil
            local function on_line(line)
                local st, name, ms = progress_line(line)
                if st == "running" then
                    current, buf = name, {}
                    local rec = s.by_case[name]
                    if rec then
                        s.seen[name] = { status = "running" }
                        set_live(rec, "running")
                        batch.add(rec.id, { status = "running" })
                    end
                    return
                end
                if st and name == current then
                    local rec = s.by_case[name]
                    s.captured[name] = table.concat(buf or {}, "\n")
                    current, buf = nil, nil
                    if rec then
                        local r = { status = st, duration = ms }
                        s.seen[name] = r
                        report(rec, { status = st, duration = ms, errors = {} })
                    end
                    return
                end
                if buf then
                    buf[#buf + 1] = line
                    -- (Bounded: only the end is ever answered.)
                    if #buf > 20000 then buf = { table.concat(buf, "\n", #buf - 10000) } end
                end
            end
            local out_len = 0
            api.spawn(s.spec, function(code, signal)
                if api.ended_by_cancel() then return end
                local okn, whyn = api.current()
                if not okn then return api.finish(1, api.stopped(whyn)) end
                code = build_run.exit_status(code, signal)
                if partial ~= "" then pcall(on_line, partial); partial = "" end
                s.output = table.concat(s.out)
                step_done(s, code)
                next_test()
            end, nil, function(stream, text)
                if type(text) ~= "string" then return end
                -- The step's whole output (bounded), for a result without cases.
                s.out[#s.out + 1] = text
                out_len = out_len + #text
                if out_len > 2 * test_store.OUTPUT_CAP then
                    local t = tail(table.concat(s.out), test_store.OUTPUT_CAP)
                    s.out, out_len = { t }, #t
                end
                if stream ~= "stdout" then return end
                partial = partial .. text
                for line in partial:gmatch("([^\r\n]*)\r?\n") do on_line(line) end
                partial = partial:match("[^\n]*$") or ""
            end)
        end
        next_test()
    end

    return phase
end

-- ---------------------------------------------------------------------------
-- collect and result
-- ---------------------------------------------------------------------------

--- A call answered in a model segment (no load), its changes then checked
--- for `header_changed` / the views' `update` (the segment's end).
local function in_segment(service, ictx, op, answer)
    local interfaces = require("loomworks.daemon.interfaces")
    local ctx = { op = op, conn = ictx.conn, env = ictx.env, args = {} }
    function ctx.reply(fields)
        ctx.replied = true
        service:_before_ack(ctx)
        ictx.reply(fields)
    end
    service:with_model(ctx, function()
        if ctx.conn.closed then return end
        ctx.reply(answer(ctx))
    end)
    return interfaces.ASYNC
end

--- `collect { prepared }`: parse the results file of a prepared debug
--- session, record its cases, drop the token and the file.
local function collect(service, ictx, args)
    local store = test_store.of(service)
    return in_segment(service, ictx, "test_collect", function(ctx)
        local p = store:take(ctx.conn, args.prepared)
        if not p then
            return { outcome = "refused", exit_code = 1,
                message = "no prepared test debug session " .. tostring(args.prepared) .. " on this connection" }
        end
        local results = p.tu and (vim.uv or vim.loop).fs_stat(p.results) and p.tu:parse_results(p.results) or nil
        test_store.unlink(p.root, p.path)
        local cases, seen = {}, {}
        for _, r in ipairs(results or {}) do
            local rec = p.by_entry[r.test_id]
            if rec and not seen[rec] then
                seen[rec] = true
                local res = to_result(r)
                store:record(rec.key, res)
                cases[#cases + 1] = case_result(rec.id, res)
            end
        end
        if #cases > 0 then
            M.emit(service, nil, cases)
            store:commit()
        end
        return { outcome = "ok", cases = cases }
    end)
end

--- `result { id }`: a node's last result with its output and error
--- locations.
local function result(service, ictx, args)
    local store = test_store.of(service)
    return in_segment(service, ictx, "test_result", function()
        local ws = service:header_model()
        local rec = ws and store:index(ws).by_id[args.id] or nil
        if not rec then return { outcome = "refused", exit_code = 1, message = STALE .. tostring(args.id) } end
        local out = { id = rec.id, errors = {} }
        local r = store:current(rec.key)
        if r then
            out.status, out.duration, out.message = r.status, millis(r.duration), r.message
            out.output, out.truncated = r.output, r.truncated or nil
            out.errors = r.errors or {}
        end
        return out
    end)
end

--- The Tests/1 methods of this part.
--- @param service table
--- @return table<string, function>
function M.methods(service)
    return {
        run_cases = task_method(service, "run_cases", "test"),
        prepare_debug = task_method(service, "prepare_debug", "debug"),
        collect = function(ictx, args) return collect(service, ictx, args) end,
        result = function(ictx, args) return result(service, ictx, args) end,
    }
end

--- A connection closed: its prepared debug sessions are dropped.
--- @param service table
--- @param conn table
function M.on_conn_closed(service, conn)
    if service._test_store then service._test_store:drop(conn) end
end

--- The daemon stops: every prepared debug session is dropped.
--- @param service table
function M.on_stopping(service)
    if service._test_store then service._test_store:drop(nil) end
end

return M
