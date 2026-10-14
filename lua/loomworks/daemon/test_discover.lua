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
---   * a unit whose tree is current (loomworks.daemon.tests_view `current`)
---     is not probed again unless `force`;
---   * otherwise the unit is probed — the in-process discovery
---     (`ConfigUnit:discover_tests_async`, §8.9.3) — holding its build
---     directory's lock for the probe only: behind a task of this daemon that
---     holds it, the discovery waits (it is released when that task ends);
---     a holder in another process fails fast, and the unit's state is
---     `error` with the busy line. Every program the probe runs is spawned
---     here (`TestUnit._system`): in the client's environment, killed on a
---     cancel or after its probe timeout, as a build step is.
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
local tests_view = require("loomworks.daemon.tests_view")

local M = {}

--- How often a discovery waiting behind a task of this daemon checks the
--- build directory's lock again.
M.WAIT_POLL_MS = 100

--- How long a cancelled discovery waits for its probe to call back after its
--- programs were killed before it ends anyway.
M.CANCEL_GRACE_MS = 2000

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

--- Run an accepted discovery (see the header).
--- @param svc loomworks.daemon.BuildService
--- @param ctx table the request: { conn, env, args, task, ws, profile }
--- @return table run
function M.run(svc, ctx)
    local runner = require("loomworks.daemon.runner")
    local build_lock = require("loomworks.build_lock")
    local task, ws, profile = ctx.task, ctx.ws, ctx.profile
    local force = ctx.args.force == true
    local st = tests_view.store(svc)
    local run = { task = task, op = "discover", cancelled = false, held = {}, children = {} }
    ctx.run = run
    local units = tests_view.profile_units(profile)
    local disc = { task = task, profile = profile }
    st.discovering = disc
    local total, failed, i = 0, 0, 0

    local function release_all()
        for _, h in ipairs(run.held) do build_lock.release(h) end
        run.held = {}
    end
    run.release_all = release_all

    local function finish(code, err, result)
        if run.finished then return end
        run.finished = true
        release_all()
        if run.wait_timer then pcall(function() run.wait_timer:stop(); run.wait_timer:close() end); run.wait_timer = nil end
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

    local function current()
        if svc.ws ~= ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
        if profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
        return true
    end

    --- Stop the discovery (idempotent; a no-op once finished).
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.probing and next(run.children) ~= nil then
            -- Its programs' exits end the probe, and the probe's callback
            -- the task; a probe that never calls back ends it after a grace.
            for child in pairs(run.children) do runner.kill(child) end
            vim.defer_fn(function()
                svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
            end, M.CANCEL_GRACE_MS)
        else
            svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
        end
    end

    --- A program of the probe (TestUnit._system): spawned as a build step is,
    --- in the client's environment plus the TestUnit's variables, killed on a
    --- cancel or after `opts.timeout`; `on_exit` gets the `vim.system` result
    --- shape.
    local function system(cmd, o, on_exit)
        o = o or {}
        local function failed_spawn(why)
            local res = { code = 127, signal = 0, stdout = "", stderr = tostring(why) }
            vim.schedule(function() on_exit(res) end)
            return { kill = function() end, is_closing = function() return true end,
                wait = function() return res end }
        end
        if run.cancelled or run.finished then return failed_spawn(stopped()) end
        local spec, herr = require("loomworks.exe").harden_spec({ cmd = cmd, cwd = o.cwd,
            env = envscope.with_overlay(ctx.env, o.env) })
        if not spec then return failed_spawn(herr) end
        local out, errb, timer = {}, {}, nil
        local child = {}
        local function text(t)
            local s = table.concat(t)
            if o.text then s = s:gsub("\r\n", "\n") end
            return s
        end
        child.obj = runner.spawn(spec, {
            output = function(stream, data)
                if stream == "stdout" then out[#out + 1] = data else errb[#errb + 1] = data end
            end,
            done = function(code, signal)
                if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
                run.children[child] = nil
                on_exit({ code = code, signal = signal and 1 or 0, stdout = text(out), stderr = text(errb) })
            end,
        })
        if child.obj then
            child.pid = child.obj.pid
            if child.pid then child.start = require("loomworks.proc").start_time(child.pid) end
            run.children[child] = true
            if type(o.timeout) == "number" and o.timeout > 0 then
                timer = uv.new_timer()
                timer:start(o.timeout, 0, function() vim.schedule(function() runner.kill(child) end) end)
            end
        end
        return { pid = child.pid, kill = function() runner.kill(child) end,
            is_closing = function() return run.children[child] == nil end }
    end

    --- The build directory's lock for the probe: fail-fast against another
    --- process (a hung or dead holder handled by lock_break, §19.5).
    local function take_lock(unit, bd)
        local lock_break = require("loomworks.lock_break")
        local shown = ws._display_build_dir and ws:_display_build_dir(bd) or bd
        local lctx = { what = shown, command = ctx.command or "lw test", unlock = shown }
        local h, msg = lock_break.acquire(function()
            local hh, _, info = build_lock.acquire(bd, "discover", lctx)
            return hh, info
        end, lctx)
        if not h then return false, msg end
        run.held[#run.held + 1] = h
        if h.reclaimed and ws._recover_interrupted_build_dir then
            local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
            if line then task:line("err", "lw: " .. line) end
        end
        return true
    end

    local step

    --- Probe one unit (in a model segment), then continue with the next.
    local function probe(u, label)
        local unit = u.unit
        local bd = unit.build_dir and unit:build_dir() or nil
        if bd and build_lock.held_by_me(bd) then
            -- Behind a task of this daemon: wait for its end.
            if not run.waiting then
                run.waiting = true
                task:line("note", "waiting for " .. (ws._display_build_dir and ws:_display_build_dir(bd) or bd)
                    .. " (in use by another task of this workspace)")
            end
            run.wait_timer = uv.new_timer()
            run.wait_timer:start(M.WAIT_POLL_MS, 0, function()
                vim.schedule(function()
                    if run.wait_timer then pcall(function() run.wait_timer:close() end); run.wait_timer = nil end
                    if run.finished then return end
                    svc:with_model(ctx, function()
                        if run.finished then return end
                        if run.cancelled then return finish(run.cancel_code, stopped()) end
                        local okc, why = current()
                        if not okc then return finish(1, stopped(why)) end
                        probe(u, label)
                    end)
                end)
            end)
            return
        end
        run.waiting = nil
        local fp, mark = tests_view.fingerprint(unit), tests_view.mark_of(st, unit)
        local function record(rec)
            rec.fp, rec.mark = fp, mark
            st.records[unit] = rec
        end
        task:line("out", "==> [discover] " .. label)
        if bd then
            local lok, lmsg = take_lock(unit, bd)
            if not lok then
                failed = failed + 1
                task:line("err", label .. ": " .. tostring(lmsg))
                record({ outcome = "error", message = tostring(lmsg) })
                return step()
            end
        end
        -- Re-probe: the TestUnits' own caches (framework probes) go too.
        unit:invalidate_tests()
        run.probing = unit
        local called = false
        local function on_done(entries)
            if called then return end
            called = true
            svc:with_model(ctx, function()
                run.probing = nil
                release_all()
                if run.finished then return end
                if run.cancelled then
                    -- Its killed probes may have cached "no framework".
                    unit:invalidate_tests()
                    return finish(run.cancel_code, stopped())
                end
                local okc, why = current()
                if not okc then return finish(1, stopped(why)) end
                local n = M.count_tests(entries)
                total = total + n
                task:line("out", label .. ": " .. n .. (n == 1 and " test" or " tests"))
                record({ outcome = "ok", entries = entries or {} })
                step()
            end)
        end
        local ok, err = pcall(unit.discover_tests_async, unit, on_done, { system = system })
        if not ok and not called then
            called = true
            run.probing = nil
            release_all()
            failed = failed + 1
            local msg = "test discovery failed: " .. tostring(err)
            task:line("err", label .. ": " .. msg)
            record({ outcome = "error", message = msg })
            return step()
        end
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
                total == 1 and "test" or "tests", failed))
            return finish(0, nil, { tests = total, failed = failed })
        end
        task:progress((i - 1) / math.max(#units, 1))
        local unit = u.unit
        if unit._removed then return step() end
        local label = u.project .. "/" .. u.configuration
        local avail = unit:test_availability()
        if avail then
            st.records[unit] = { outcome = "avail", fp = tests_view.fingerprint(unit), mark = tests_view.mark_of(st, unit) }
            return step()
        end
        if not force and tests_view.current(st, unit, true) then
            total = total + M.count_tests(st.records[unit].entries)
            return step()
        end
        return probe(u, label)
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
        return ctx.reply({ outcome = "refused", message = refusal, exit_code = 1, notes = ctx.notes })
    end
    if ctx.refused then
        return ctx.reply({ outcome = "refused", message = ctx.refused, exit_code = 1, notes = ctx.notes })
    end
    local profile = test_state.active_profile(ws)
    if not profile then
        return ctx.reply({ outcome = "refused", message = M.NO_PROFILE, exit_code = 1, notes = ctx.notes })
    end
    local task = svc.tasks:create(ctx.conn)
    task.call = ctx.call
    ctx.task, ctx.ws, ctx.profile = task, ws, profile
    ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn), profile_key = profile.key,
        pid = svc.server.pid, notes = ctx.notes })
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
