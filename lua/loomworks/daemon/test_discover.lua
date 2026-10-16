--- loomworks/daemon/test_discover.lua — `loomworks.Tests/1.discover`, the
--- editor's test discovery in the workspace daemon (spec §19.15 "Tests",
--- §19.20 `Tests/1`; step 5m part B1).
---
--- A task (`meta.kind = discover`) owned by the calling client, in its
--- environment (§19.15 "Environment": accepted in a model segment through
--- `Service:live`, so a different environment reloads the workspace first,
--- declined while a build runs). For each unit of the active profile, in
--- project-key order:
---
---   * a unit with nothing to probe (not configured here, foreign kit, no
---     TestUnit and no saved test targets) gets its view state;
---   * a unit whose tree is current (loomworks.daemon.test_store `fresh`)
---     is not probed again unless `force`;
---   * otherwise the unit is probed — the in-process discovery
---     (`ConfigUnit:discover_tests_async`, §8.9.3) — holding its build
---     directory's lock for the probe only: it first waits in the Tests/1
---     queue of the directory (loomworks.daemon.test_store `acquire_dirs`,
---     behind a test run of it), then behind a task of this daemon that
---     holds the lock (released when that task ends); a holder in another
---     process fails fast, and the unit's state is `error` with the busy
---     line. Every program the probe runs is spawned here
---     (`TestUnit._system`): in the client's environment, killed on a cancel
---     or after its probe timeout, as a build step is. A probe that never
---     calls back is abandoned after PROBE_TIMEOUT_MS, and one that throws
---     fails: either is the unit's `error`, its TestUnits dropped.
---
--- The probing itself is `M.prober`, shared with the discovery a test run
--- makes before its build (loomworks.daemon.test_runs).
---
--- A unit's failure does not end the task. The task ends 0 with
--- `DISCOVER OK: <profile> (<n> tests, <k> failed)` and its result
--- `{ exit_code, tests, failed }`; the view's `update` is sent before `done`.
--- A cancel stops between units and at a probe's programs: the units already
--- probed keep their new trees, the others their earlier ones, and the view
--- stays stale.

local uv = vim.uv or vim.loop
local envscope = require("loomworks.daemon.envscope")
local tasks_mod = require("loomworks.daemon.tasks")
local test_state = require("loomworks.test_state")
local test_store = require("loomworks.daemon.test_store")

local M = {}

--- How often a discovery waiting behind a task of this daemon checks the
--- build directory's lock again.
M.WAIT_POLL_MS = 100

--- How long a cancelled discovery waits for its probe to call back after its
--- programs were killed before it ends anyway.
M.CANCEL_GRACE_MS = 2000

--- The hang guard of one unit's probe: a probe that has not called back by
--- then is abandoned (its programs killed) as that unit's error, so a
--- TestUnit that never answers cannot keep a discovery running.
M.PROBE_TIMEOUT_MS = 10 * 60 * 1000

--- The refusal with no active profile (as `lw status` words it).
M.NO_PROFILE = "no active profile — `lw profile select <profile>` (`lw profile list`)"

--- The number of tests among a unit's discovered entries: the entries no
--- other entry names as its parent (a case, or a target without cases).
--- @param entries table[]|nil
--- @return integer
function M.count_tests(entries)
    local parents, n = {}, 0
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" and e.parent then parents[e.parent] = true end
    end
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" and type(e.id) == "string" and not parents[e.id] then n = n + 1 end
    end
    return n
end

--- @class loomworks.daemon.TestProber
--- @field children table<table, boolean> the programs of the probe in flight
--- @field held table[] the build-directory lock of the probe in flight
--- @field timers table<userdata, boolean> its pending timers (wait polls, the hang guard)
--- @field entry table|nil its Tests/1 queue entry (`queue`)
--- @field probe fun(u: table, label: string, k: fun(outcome: "ok"|"error"|"stopped", v: integer|string|nil))
--- @field system fun(cmd: string[], opts: table, on_exit: fun(res: table)): table
--- @field busy fun(): boolean
--- @field kill fun()
--- @field release_locks fun()
--- @field close fun()

--- The prober of one task: probes units one at a time, the way discovery
--- does (see the header), for `Tests/1.discover` and for the units a
--- `Tests/1.run_cases` / `prepare_debug` discovers before its build.
---
--- `probe(u, label, k)` (in a model segment) waits — in the Tests/1 queue
--- for the unit's build directory (`o.queue`; a run already holds it), then
--- behind a task of this daemon holding it — announces the unit, takes its
--- lock for the probe only and probes it, recording the outcome in the
--- store; then `k` runs in a model segment: `("ok", n)`, `("error", msg)`, or
--- `("stopped", why?)` when the run was cancelled (`why` nil) or is no longer
--- current. Nothing is called once `run.finished`. A probe that never calls
--- back is abandoned after PROBE_TIMEOUT_MS as the unit's error, and one that
--- throws is that unit's error: either way the unit's TestUnits are dropped
--- with their `_system`. `close()` (when the task ends) stops the timers and
--- releases the lock and the queue entry.
--- @param svc loomworks.daemon.BuildService
--- @param ctx table the request (its `env`, `command`; the model segments')
--- @param run table the task's run: `cancelled`, `finished`
--- @param o { task: table, ws: table, current: fun(): boolean, string|nil, queue?: boolean }
--- @return loomworks.daemon.TestProber
function M.prober(svc, ctx, run, o)
    local runner = require("loomworks.daemon.runner")
    local build_lock = require("loomworks.build_lock")
    local st = test_store.of(svc)
    local task, ws = o.task, o.ws
    local P = { children = {}, held = {}, timers = {} }

    local function shown(bd) return ws._display_build_dir and ws:_display_build_dir(bd) or bd end

    --- A one-shot timer whose callback runs on the main loop (unless stopped).
    local function timer(ms, fn)
        local t = uv.new_timer()
        P.timers[t] = true
        t:start(ms, 0, function()
            vim.schedule(function()
                if not P.timers[t] then return end
                P.timers[t] = nil
                pcall(function() t:close() end)
                fn()
            end)
        end)
        return t
    end
    local function stop_timer(t)
        if t and P.timers[t] then
            P.timers[t] = nil
            pcall(function() t:stop(); t:close() end)
        end
    end

    function P.busy() return next(P.children) ~= nil end
    function P.kill() for child in pairs(P.children) do runner.kill(child) end end
    function P.release_locks()
        for _, h in ipairs(P.held) do build_lock.release(h) end
        P.held = {}
    end
    local function release_entry()
        if P.entry then
            local e = P.entry
            P.entry = nil
            st:release(e)
        end
    end
    function P.close()
        for t in pairs(P.timers) do stop_timer(t) end
        P.release_locks()
        release_entry()
    end

    --- A program of the probe (TestUnit._system): spawned as a build step is,
    --- in the client's environment plus the TestUnit's variables, killed on a
    --- cancel or after `opts.timeout`; `on_exit` gets the `vim.system` result
    --- shape.
    function P.system(cmd, so, on_exit)
        so = so or {}
        local function failed_spawn(why)
            local res = { code = 127, signal = 0, stdout = "", stderr = tostring(why) }
            vim.schedule(function() on_exit(res) end)
            return { kill = function() end, is_closing = function() return true end,
                wait = function() return res end }
        end
        if run.cancelled or run.finished then return failed_spawn("discovery stopped") end
        local spec, herr = require("loomworks.exe").harden_spec({ cmd = cmd, cwd = so.cwd,
            env = envscope.with_overlay(ctx.env, so.env) })
        if not spec then return failed_spawn(herr) end
        local out, errb, t = {}, {}, nil
        local child = {}
        local function text(parts)
            local s = table.concat(parts)
            if so.text then s = s:gsub("\r\n", "\n") end
            return s
        end
        child.obj = runner.spawn(spec, {
            output = function(stream, data)
                if stream == "stdout" then out[#out + 1] = data else errb[#errb + 1] = data end
            end,
            done = function(code, signal)
                if t then pcall(function() t:stop(); t:close() end); t = nil end
                P.children[child] = nil
                on_exit({ code = code, signal = signal and 1 or 0, stdout = text(out), stderr = text(errb) })
            end,
        })
        if child.obj then
            child.pid = child.obj.pid
            if child.pid then child.start = require("loomworks.proc").start_time(child.pid) end
            P.children[child] = true
            if type(so.timeout) == "number" and so.timeout > 0 then
                t = uv.new_timer()
                t:start(so.timeout, 0, function() vim.schedule(function() runner.kill(child) end) end)
            end
        end
        return { pid = child.pid, kill = function() runner.kill(child) end,
            is_closing = function() return P.children[child] == nil end }
    end

    --- The build directory's lock for the probe: fail-fast against another
    --- process (a hung or dead holder handled by lock_break, §19.5).
    local function take_lock(bd)
        local lock_break = require("loomworks.lock_break")
        local lctx = { what = shown(bd), command = ctx.command or "lw test", unlock = shown(bd) }
        local h, msg = lock_break.acquire(function()
            local hh, _, info = build_lock.acquire(bd, "discover", lctx)
            return hh, info
        end, lctx)
        if not h then return false, msg end
        P.held[#P.held + 1] = h
        if h.reclaimed and ws._recover_interrupted_build_dir then
            local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
            if line then task:line("err", "lw: " .. line, "plain") end
        end
        return true
    end

    --- What an abandoned probe (hung, or thrown) left on the unit: its
    --- TestUnits with their `_system`, dropped.
    local function scrub(unit)
        for _, tu in ipairs(unit._test_units or {}) do tu._system = nil end
        unit:invalidate_tests()
    end

    function P.probe(u, label, k)
        local unit = u.unit
        local bd = unit.build_dir and unit:build_dir() or nil
        local waited = false

        --- May the probe go on (in a model segment)? Calls `k` when stopped.
        local function go_on()
            if run.finished then return false end
            if run.cancelled then k("stopped"); return false end
            local okc, why = o.current()
            if not okc then k("stopped", why); return false end
            return true
        end

        local function start()
            if bd and build_lock.held_by_me(bd) then
                -- Behind a task of this daemon: wait for its end.
                if not waited then
                    waited = true
                    task:line("note", "waiting for " .. shown(bd) .. " (in use by another task of this workspace)", "plain")
                end
                timer(M.WAIT_POLL_MS, function()
                    svc:with_model(ctx, function() if go_on() then start() end end)
                end)
                return
            end
            local fp, mark = test_store.fingerprint(unit), st:mark_of(unit)
            local function record(rec)
                rec.fp, rec.mark = fp, mark
                st:set_record(unit, rec)
            end
            task:line("out", require("loomworks.cli_color").header("discover", label), "phase")
            if bd then
                local lok, lmsg = take_lock(bd)
                if not lok then
                    release_entry()
                    task:line("err", label .. ": " .. tostring(lmsg), "fail")
                    record({ outcome = "error", message = tostring(lmsg) })
                    return k("error", tostring(lmsg))
                end
            end
            -- Re-probe: the TestUnits' own caches (framework probes) go too.
            unit:invalidate_tests()
            run.probing = unit
            local called, guard = false, nil
            local function ended()
                called = true
                stop_timer(guard)
                run.probing = nil
                P.release_locks()
                release_entry()
            end
            local function failed(msg)
                scrub(unit)
                task:line("err", label .. ": " .. msg, "fail")
                record({ outcome = "error", message = msg })
                return k("error", msg)
            end
            guard = timer(M.PROBE_TIMEOUT_MS, function()
                if called then return end
                ended()
                P.kill()
                svc:with_model(ctx, function()
                    if not go_on() then scrub(unit); return end
                    failed(string.format("test discovery timed out (no answer after %d s)",
                        math.floor(M.PROBE_TIMEOUT_MS / 1000 + 0.5)))
                end)
            end)
            local function on_done(entries)
                if called then return end
                ended()
                svc:with_model(ctx, function()
                    if run.finished then return end
                    if run.cancelled then
                        -- Its killed probes may have cached "no framework".
                        unit:invalidate_tests()
                        return k("stopped")
                    end
                    local okc, why = o.current()
                    if not okc then return k("stopped", why) end
                    local n = M.count_tests(entries)
                    task:line("out", label .. ": " .. n .. (n == 1 and " test" or " tests"), "plain")
                    record({ outcome = "ok", entries = entries or {} })
                    k("ok", n)
                end)
            end
            local ok, err = pcall(unit.discover_tests_async, unit, on_done, { system = P.system })
            if not ok and not called then
                ended()
                return failed("test discovery failed: " .. tostring(err))
            end
        end

        if o.queue and bd then
            -- The Tests/1 queue of the directory first (§5.3, FIFO), as a
            -- test run waits for it.
            local now, granted = true, false
            local e = st:acquire_dirs({ bd }, function()
                if now then granted = true; return end
                svc:with_model(ctx, function() if go_on() then start() end end)
            end)
            now = false
            P.entry = e
            if granted then return start() end
            task:line("note", "waiting for another test task of " .. shown(bd), "plain")
            return
        end
        start()
    end

    return P
end

--- Run an accepted discovery (see the header).
--- @param svc loomworks.daemon.BuildService
--- @param ctx table the request: { conn, env, args, task, ws, profile }
--- @return table run
function M.run(svc, ctx)
    local task, ws, profile = ctx.task, ctx.ws, ctx.profile
    local force = ctx.args.force == true
    local st = test_store.of(svc)
    local run = { task = task, op = "discover", cancelled = false }
    ctx.run = run
    local units = test_store.profile_units(profile)
    local disc = { task = task, profile = profile }
    st.discovering = disc
    local total, failed, i = 0, 0, 0
    local P

    local function current()
        if svc.ws ~= ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
        if profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
        return true
    end

    local function finish(code, err, result)
        if run.finished then return end
        run.finished = true
        P.close()
        if st.discovering == disc then st.discovering = nil end
        if run.cancelled or code ~= 0 then
            -- (A cancelled or failed discovery leaves the view stale.)
            if st.discovered == profile then st.discovered = nil end
        end
        -- The view's update before `done` (§19.15 "Tests").
        pcall(require("loomworks.daemon.views").check, svc)
        task:done(code, err, result and { result = result } or nil)
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function stopped(why)
        return "discover stopped: " .. tostring(why or run.cancel_reason)
    end

    P = M.prober(svc, ctx, run, { task = task, ws = ws, current = current, queue = true })
    run.release_all = P.close

    --- Stop the discovery (idempotent; a no-op once finished).
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.probing and P.busy() then
            -- Its programs' exits end the probe, and the probe's callback
            -- the task; a probe that never calls back ends it after a grace.
            P.kill()
            vim.defer_fn(function()
                svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
            end, M.CANCEL_GRACE_MS)
        else
            svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
        end
    end

    local step

    --- A probe's end (in a model segment): count it, then the next unit.
    local function probed(outcome, v)
        if outcome == "stopped" then
            if v == nil then return finish(run.cancel_code, stopped()) end
            return finish(1, stopped(v))
        end
        if outcome == "error" then failed = failed + 1 else total = total + v end
        step()
    end

    --- The next unit (in a model segment).
    step = function()
        if run.finished then return end
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        i = i + 1
        local u = units[i]
        if not u then
            st.discovered = profile
            task:line("out", string.format("DISCOVER OK: %s (%d %s, %d failed)", profile.key, total,
                total == 1 and "test" or "tests", failed), "ok")
            return finish(0, nil, { tests = total, failed = failed })
        end
        task:progress((i - 1) / math.max(#units, 1))
        local unit = u.unit
        if unit._removed then return step() end
        local label = u.project .. "/" .. u.configuration
        local avail = unit:test_availability()
        if avail then
            st:set_record(unit, { outcome = "avail" })
            return step()
        end
        if not force and st:fresh(unit, true) then
            total = total + M.count_tests(st.records[unit].entries)
            return step()
        end
        return P.probe(u, label, probed)
    end

    local meta_units = {}
    for _, u in ipairs(units) do meta_units[#meta_units + 1] = { project = u.project, configuration = u.configuration } end
    task:start({ name = profile.key, kind = "discover", profile = profile.key, units = meta_units })
    step()
    return run
end

--- The model segment that accepts (or refuses / declines) a discovery.
--- @param svc loomworks.daemon.BuildService
--- @param ctx table
function M.accept(svc, ctx)
    if ctx.conn.closed then return end
    local ws, refusal, decline = svc:live(ctx)
    if not ws then
        if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
        return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    if ctx.refused then
        return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local profile = test_state.active_profile(ws)
    if not profile then
        return ctx.reply({ outcome = "refused", message = M.NO_PROFILE, exit_code = 1,
            notes = ctx.notes, note_roles = ctx.note_roles })
    end
    local task = svc.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.profile = task, ws, profile
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile.key,
        pid = svc.server.pid, notes = ctx.notes, note_roles = ctx.note_roles })
    local run = M.run(svc, ctx)
    svc.server:log("discover %s (task %s) accepted", profile.key, task.id)
    if run and not run.finished then
        run.ctx = ctx
        svc.runs[run] = true
    end
end

--- The `Tests/1.discover` handler.
--- @param service loomworks.daemon.BuildService
--- @param where { path: string, iface: string, v: integer }
--- @return function
function M.handler(service, where)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(cctx, args)
        local srv = service.server
        local env, eerr = envscope.validate(cctx.env)
        local ctx = { op = "discover", conn = cctx.conn, env = env, args = args or {}, command = "lw test",
            call = require("loomworks.daemon.core_interfaces").task_call(cctx.registry, where, "discover") }
        function ctx.reply(fields)
            ctx.replied = true
            service:_before_ack(ctx)
            return cctx.reply(fields)
        end
        if not env then
            ctx.reply({ outcome = "declined", reason = eerr })
        elseif service.stopping or srv.stopped then
            ctx.reply({ outcome = "declined", reason = "the workspace runtime is stopping" })
        elseif srv.retiring then
            ctx.reply({ outcome = "declined", reason = "the daemon is retiring" })
        else
            service:with_model(ctx, function() M.accept(service, ctx) end)
        end
        return interfaces.ASYNC
    end
end

return M
