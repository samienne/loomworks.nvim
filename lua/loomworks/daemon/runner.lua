--- loomworks/daemon/runner.lua — run a profile build in the daemon (spec
--- §19.15), streaming it on the task stream — or a test run (`lw test`,
--- §16.16): the same locks and for-test build, then the test plan (loomworks.test_plan) —
--- or the preparation of `lw run` (§19.15 "Run"): the same locks and build
--- (unless `no_build`), the locks released, then the launch target selected,
--- deployed and its launch spec resolved (loomworks.run_prep), returned in
--- the task's `done` for the client to execute — or the preparation of a
--- debug launch (`Launch/1.prepare_debug`, §19.15 "Debug"): the same steps,
--- ending with the debug spec for the client's debugger instead — either
--- preparation with `build_scope = "target"` building the launch flow's
--- units instead of the profile (§19.15 "Build scope of a launch") — or an
--- editor test run or test debug preparation (`op = "cases"`, `Tests/1`,
--- §19.15 "Tests"): the units' locks after the Tests/1 queue (`ctx.cases.wait`),
--- the build `ctx.cases.plan()` plans, then `ctx.cases.after_build`
--- (loomworks.daemon.test_runs) — or a clean (`lw clean`,
--- §19.15 "Clean"): the same locks, then each project's clean step — a module
--- clean spawned like a build step, or a core-performed wipe
--- (loomworks.build_run.wipe_step: the in-process build-directory deletion,
--- Workspace:clean_wipe_build_dir — asynchronous, so the endpoint keeps
--- serving, and stoppable between entries by the run's cancellation).
---
--- It runs the SAME step sequence as the in-process `lw build`
--- (`cli.run_build_steps` over `loomworks.build_run`):
---
---   take every build-directory lock (canonical order, fail-fast, a dead
---   holder reclaimed with its state recovered, §19.3 / §19.5)
---   → plan (gate, module plan, build request)
---   → per step: before_step (lock record names the step, conflict gate,
---               full-reconfigure reset) → step_lines → spawn_spec → run
---               → after_step (cache write-back) → failure line + exit code
---   → release the locks → `BUILD OK: <profile>`
---
--- and differs only in how a step is spawned (asynchronously, its output
--- streamed; in the requesting client's environment) and how a refusal
--- travels (as the task's `done` error, printed by the client exactly as the
--- in-process host prints it).
---
--- All model work (lock acquisition, planning, gates, cache write-back) runs
--- in the service's serialized model segments (`svc:with_model`), inside the
--- client's environment; only the child processes run in between.
---
--- **Cancellation** (§19.15): `cancel(reason)` kills the running step's
--- process tree (the identity-verified kill of §19.5: the child's pid AND
--- start time), records nothing for that step, releases the locks and ends
--- the task nonzero.

local build_run = require("loomworks.build_run")
local envscope = require("loomworks.daemon.envscope")

local M = {}

local uv = vim.uv or vim.loop
local WIN = package.config:sub(1, 1) == "\\"

--- After a step exits, how long to wait for its output pipes to reach EOF
--- (a grandchild may keep one open — e.g. MSVC's mspdbsrv) while they are
--- being read. A paused pipe is not waited on: its data stays in the pipe
--- until the owner caught up.
M.EOF_GRACE_MS = 500

--- Spawn a step (test seam): the program in `spec.cmd` (argv[1] already
--- resolved, loomworks.exe.harden_spec), with exactly `spec.env`, its output
--- streamed to `sink.output(stream, text)` in order and `sink.done(code,
--- signal)` called once the process exited and its output was read — `code`
--- as build_run.exit_status maps it (a signal that ended the process: 128 +
--- signal, and `signal` names it; else nil). The returned
--- object controls it:
---   * `pause()` / `resume()` stop and restart reading its stdout and stderr
---     (owner flow control, loomworks.daemon.tasks): a paused step's tool
---     blocks on its full pipe, as on a paused terminal;
---   * `kill(signal)` signals the process;
---   * `abandon()` stops reading for good (a cancelled step): `done` follows
---     as soon as the process exited, without waiting for its output.
--- Returns nil (and calls `sink.done(127)`) when it cannot be spawned.
--- @param spec { cmd: string[], cwd: string, env: table }
--- @param sink table
--- @return table|nil obj with `pid`, `kill`, `pause`, `resume`, `abandon`
function M.spawn(spec, sink)
    local so, se = uv.new_pipe(false), uv.new_pipe(false)
    local env = {}
    for k, v in pairs(spec.env or {}) do env[#env + 1] = k .. "=" .. tostring(v) end
    local exe = spec.cmd[1]
    -- cmd.exe reads forward-slash path components as switches.
    if WIN then exe = exe:gsub("/", "\\") end
    local args = {}
    for i = 2, #spec.cmd do args[i - 1] = spec.cmd[i] end
    local obj = { paused = false }
    local exit_code, exit_signal, finished, abandoned, grace = nil, nil, false, false, nil
    local open = { stdout = true, stderr = true }
    local pipes = { stdout = so, stderr = se }
    local readers = {}
    local function close_pipe(name)
        local p = pipes[name]
        open[name] = false
        pcall(function() p:read_stop() end)
        pcall(function() if not p:is_closing() then p:close() end end)
    end
    local function finish()
        if finished then return end
        finished = true
        if grace then pcall(function() grace:stop(); grace:close() end); grace = nil end
        close_pipe("stdout"); close_pipe("stderr")
        sink.done(exit_code or 0, exit_signal)
    end
    local function maybe_finish()
        if finished or exit_code == nil then return end
        if abandoned or (not open.stdout and not open.stderr) then return finish() end
        -- Exited, a pipe still open: wait a little for its EOF, but only
        -- while it is being read.
        if obj.paused or grace then return end
        grace = uv.new_timer()
        grace:start(M.EOF_GRACE_MS, 0, function() finish() end)
    end
    for _, name in ipairs({ "stdout", "stderr" }) do
        readers[name] = function(err, data)
            if finished or abandoned then return end
            if data and not err then
                if data ~= "" then sink.output(name, data) end
                return
            end
            close_pipe(name)
            maybe_finish()
        end
    end
    local handle, pid
    handle, pid = uv.spawn(exe, {
        args = args, stdio = { nil, so, se }, cwd = spec.cwd, env = env, hide = WIN,
    }, function(code, signal)
        pcall(function() handle:close() end)
        -- A process a signal ended (POSIX: code 0 + the signal) fails with
        -- 128 + signal (§16.7).
        exit_code, exit_signal = build_run.exit_status(code, signal)
        maybe_finish()
    end)
    if not handle then
        pcall(function() so:close() end)
        pcall(function() se:close() end)
        -- As the in-process run_spec reports it.
        sink.output("stderr", build_run.spawn_failure_line(spec.cmd[1], pid) .. "\n")
        sink.done(127)
        return nil
    end
    obj.pid = pid
    so:read_start(readers.stdout)
    se:read_start(readers.stderr)
    function obj.kill(_, signal)
        if exit_code == nil then pcall(uv.process_kill, handle, signal or "sigterm") end
    end
    function obj.pause()
        if obj.paused or finished then return end
        obj.paused = true
        for name, p in pairs(pipes) do
            if open[name] then pcall(function() p:read_stop() end) end
        end
        if grace then pcall(function() grace:stop(); grace:close() end); grace = nil end
    end
    function obj.resume()
        if not obj.paused or finished then return end
        obj.paused = false
        for name, p in pairs(pipes) do
            if open[name] then pcall(function() p:read_start(readers[name]) end) end
        end
        maybe_finish()
    end
    function obj.abandon()
        if finished then return end
        abandoned = true
        close_pipe("stdout"); close_pipe("stderr")
        maybe_finish()
    end
    return obj
end

--- Kill a spawned step's process tree (test seam): the identity-verified
--- tree kill, else (no start time, or the tree kill could not confirm the
--- process gone) a direct kill of the child. Then stop reading its output:
--- the step ends as soon as the process exited.
--- @param child { obj: table, pid: integer|nil, start: string|nil }
function M.kill(child)
    local proc = require("loomworks.proc")
    local gone = false
    if child.pid and type(child.start) == "string" then
        local ok, res = pcall(proc.kill_tree, child.pid, child.start)
        gone = ok and res == true
    end
    if not gone and child.obj and child.obj.kill then pcall(child.obj.kill, child.obj, "sigkill") end
    if child.obj and child.obj.abandon then pcall(child.obj.abandon, child.obj) end
end

--- Take the build-directory lock of every directory of `dirs` exclusively,
--- exactly like the in-process with_build_dir_locks: canonical order
--- (§19.3), fail-fast, a hung or dead holder handled by lock_break (§19.5),
--- a dead holder's state recovered as for a build. Each handle is appended
--- to `run.held` as it is taken (the caller releases them, also on failure).
--- @param run table
--- @param ws table
--- @param task loomworks.daemon.Task
--- @param dirs string[]
--- @param operation string the lock record's operation
--- @param command string the busy message's command
--- @return boolean ok, string|nil refusal
local function take_locks(run, ws, task, dirs, operation, command)
    local build_lock = require("loomworks.build_lock")
    local lock_break = require("loomworks.lock_break")
    for _, bd in ipairs(build_run.lock_order(dirs)) do
        local shown = ws._display_build_dir and ws:_display_build_dir(bd) or bd
        local lctx = { what = shown, command = command, unlock = shown }
        local h, msg = lock_break.acquire(function()
            local hh, _, info = build_lock.acquire(bd, operation, lctx)
            return hh, info
        end, lctx)
        if not h then return false, msg end
        run.held[#run.held + 1] = h
        if h.reclaimed and ws._recover_interrupted_build_dir then
            local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
            if line then task:line("err", "lw: " .. line .. "\n", "plain") end
        end
    end
    return true
end

--- @class loomworks.daemon.BuildRun
--- @field task loomworks.daemon.Task
--- @field op "build"|"test"|"run"|"debug"|"clean"|"configure"|"cases" the operation
--- @field cancelled boolean
--- @field cancel_reason string|nil
--- @field cancel_code integer|nil
--- @field finished boolean|nil
--- @field held table[] the build-directory lock handles held
--- @field op_tok table|nil a clean's workspace operation lock (it wipes)
--- @field release_all fun()|nil releases the build-directory locks and the operation lock (also on daemon stop)
--- @field child table|nil the running step { obj, pid, start }
--- @field wiping boolean|nil a clean's wipe is running (cancel stops it between entries)
--- @field deleting boolean|nil a reset's deletion started (the service keeps the daemon busy until it settled)
--- @field deletion_settled boolean|nil a reset's deletion ended
--- @field released boolean|nil a reset released its locks and was reported done
--- @field ctx table|nil the service request that started it
--- @field cancel fun(reason?: string, code?: integer)

--- Run a build, or a test run (`ctx.op == "test"`, spec §16.16, §19.15):
--- the same locks and build steps (in their for-test form), then — the locks
--- still held — the test plan (loomworks.test_plan: native runners, saved test targets), every step even after one failed; or
--- the preparation of a run (`ctx.op == "run"`, §19.15 "Run"): the build (not
--- under `args.no_build`), the locks released, then `prepare` (target, gate,
--- deploy, launch spec), ending the task with `launch` or `device`; or the
--- preparation of a debug launch (`ctx.op == "debug"`, §19.15 "Debug"): the
--- same, a device or foreign target refused (before the build when its kit
--- tells, else before any deploy), ending the task with `result.debug`; for
--- either, `args.build_scope == "target"` replaces the profile's build and
--- deploy with the launch flow (`target_scope`); or a clean (`ctx.op ==
--- "clean"`, §19.15 "Clean"): the locks, then `ctx.clean_steps` (planned by
--- the service before any lock, build_run.plan_clean); or a configure
--- (`ctx.op == "configure"`, §19.15 "Editor scopes and configure"): the locks
--- taken exclusive, then the configure step of every unit, also one already
--- configured, and no build.
---
--- With `ctx.units` (a build, a configure or a clean) the scope is those
--- configuration units instead of `ctx.profile` (nil then): the same steps,
--- locks, gates and lines restricted to them, the lines naming the units
--- (`<project>/<configuration>`), `meta.profile` absent.
--- @param svc table the build service (with_model, host)
--- @param ctx table the request: { op?, env, args, command, task, ws, profile?, units?, clean_steps?, cases?,
---   on_run? } — on_run(run) is called with the run before any of its work (a caller whose request is
---   another table registers the run there, so a throw while starting cancels it)
---   cases (op "cases"): { kind = "test"|"debug" (meta.kind), plan() → steps|nil, err; wait(dirs, fn, api);
---   after_build(api); on_finish(code, err) } — `api` gives the run's task, ws, ctx, finish, stopped,
---   current, spawn(step, on_exit, on_progress?, on_output?), ended_by_cancel and release_all
--- @return loomworks.daemon.BuildRun
function M.run(svc, ctx)
    local task, ws, profile, args = ctx.task, ctx.ws, ctx.profile, ctx.args or {}
    local units_scope = ctx.units
    local op = (ctx.op == "test" or ctx.op == "run" or ctx.op == "debug" or ctx.op == "clean"
        or ctx.op == "configure" or ctx.op == "cases") and ctx.op or "build"
    -- An editor test run or test debug preparation (`Tests/1.run_cases` /
    -- `prepare_debug`, §19.15 "Tests"): `ctx.cases` plans its build and
    -- runs what follows it (loomworks.daemon.test_runs).
    local cases = op == "cases" and ctx.cases or nil
    -- The build of a launch target (`Launch/1.build`, §19.15 "Build of a
    -- launch target"): a build (`meta.kind`, its lines) of the target
    -- scope's phases up to the launch target's own unit.
    local target_build = ctx.op == "target_build"
    -- What the lines name: the profile's key, or the units' names.
    local label = (units_scope and #units_scope > 0) and build_run.units_label(units_scope) or profile.key
    local scope_line = (units_scope and #units_scope > 0) and label or ("profile: " .. label)
    local testing = op == "test"
    -- A debug launch is prepared as a run is (§19.15 "Debug").
    local debugging = op == "debug"
    local running = op == "run" or debugging
    -- `lw run --print` / `--dry-run` keep the build's lines off stdout (§16.17).
    local out_stream = (running and args.quiet) and "note" or "out"
    local build_lock = require("loomworks.build_lock")
    local run = { task = task, op = op, cancelled = false, held = {} }
    ctx.run = run
    if ctx.on_run then ctx.on_run(run) end

    local function release_all()
        for _, h in ipairs(run.held) do build_lock.release(h) end
        run.held = {}
        if run.op_tok then
            local tok = run.op_tok
            run.op_tok = nil
            if ws._op_unlock then ws:_op_unlock(tok) else require("loomworks.op_lock").release(tok) end
        end
    end
    run.release_all = release_all
    -- A target-scoped task's step states (§19.15 "Steps of a task"), by
    -- index into its plan; nil for other tasks.
    local step_states
    local function set_step(index, state, err)
        if not (step_states and step_states[index]) or step_states[index] == state then return end
        step_states[index] = state
        task:step(index, state, err)
    end
    -- At the task's end, before its `done`: the running step ended as the
    -- task did (cancelled, failed with the failure line, else ok), the steps
    -- not reached `skipped`.
    local function close_steps(code, err)
        for index, state in ipairs(step_states or {}) do
            if state == "running" then
                local failed = not run.cancelled and code ~= 0
                set_step(index, run.cancelled and "cancelled" or (failed and "failed" or "ok"),
                    failed and err or nil)
            elseif state == "pending" then
                set_step(index, "skipped")
            end
        end
    end
    local function finish(code, err, fields)
        if run.finished then return end
        run.finished = true
        close_steps(code, err)
        release_all()
        if cases and cases.on_finish then pcall(cases.on_finish, code, err) end
        task:done(code, err, fields)
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function stopped(why)
        return op .. " stopped: " .. tostring(why or run.cancel_reason)
    end

    --- Stop the run (idempotent; a no-op once finished).
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.child then
            -- Its exit (any code) then finishes the run without recording.
            M.kill(run.child)
        elseif run.wiping or run.deploying then
            -- The wipe stops between entries, a test step's deploy between
            -- copies (their stop predicates see `cancelled`); their end then
            -- finishes the run, the locks held until nothing more is
            -- removed / copied.
            return
        else
            svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
        end
    end

    -- The current workspace/profile still the ones this run runs in?
    local function current()
        if svc.ws ~= ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
        if profile and profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
        for _, u in ipairs(units_scope or {}) do
            if u._removed then return false, "configuration unit " .. build_run.units_label({ u }) .. " was removed" end
        end
        return true
    end

    --- Spawn `step` streamed, in the client's environment; `on_exit(code,
    --- signal)` runs in a model segment once it exited. A step that cannot be
    --- spawned is reported as the in-process run_spec reports it (127).
    --- `on_progress(fraction)`: the step's own progress, from its module's
    --- progress parser (`step.progress_tool`, `[N/M]` for ninja) over its
    --- standard output lines — as the editor's task path reads it.
    local function spawn(step, on_exit, on_progress, on_output)
        local spec, herr = build_run.spawn_spec(step, ws.root)
        if not spec then
            task:line("err", "lw: " .. tostring(herr) .. "\n", "fail")
            return on_exit(127)
        end
        local env = envscope.with_overlay(ctx.env, spec.env)
        local parse = on_progress and type(step.progress_tool) == "string"
            and require("loomworks.progress").get(step.progress_tool) or nil
        local partial = ""
        local function scan(text)
            partial = partial .. text
            local last
            for line in partial:gmatch("([^\r\n]*)[\r\n]") do
                local u = line ~= "" and parse(line) or nil
                if u and tonumber(u.current) and tonumber(u.total) and u.total > 0 then last = u end
            end
            partial = partial:match("[^\r\n]*$") or ""
            if #partial > 4096 then partial = "" end -- (no line end: not a progress line)
            if last then on_progress(math.min(1, last.current / last.total)) end
        end
        local child = {}
        child.obj = M.spawn({ cmd = spec.cmd, cwd = spec.cwd, env = env }, {
            output = function(stream, text)
                task:output(stream, text)
                if on_output then pcall(on_output, stream, text) end
                if parse and stream == "stdout" and type(text) == "string" then pcall(scan, text) end
            end,
            done = function(code, signal)
                svc:with_model(ctx, function() on_exit(code, signal) end)
            end,
        })
        child.pid = child.obj and child.obj.pid or nil
        if child.pid then child.start = require("loomworks.proc").start_time(child.pid) end
        if not run.finished and child.obj then
            run.child = child
            -- The owner's flow control pauses / resumes this step's output.
            task:set_flow(child.obj)
        end
    end

    --- A step exited. True when that ended the run (it was cancelled: the
    --- kill itself may be reported as any exit).
    local function ended_by_cancel()
        run.child = nil
        task:set_flow(nil)
        if run.cancelled then finish(run.cancel_code, stopped()); return true end
        return false
    end

    --- `-v`: a deploy step's line (`    copy …` / `    up to date …`), on the
    --- status stream, as the in-process host prints it (cli._verbose_hooks).
    local deploy_step = args.verbose and function(ev)
        task:line(out_stream, build_run.deploy_line(ev), "command")
    end or nil

    -- Progress: a test run spends the first half building.
    -- A target-scoped launch build's current phase band `{ lo, span }`: a
    -- unit's step fractions are scaled into it, so the task's progress never
    -- moves backwards across phases (nor by a rounding at a band's edge).
    local band, peak = nil, 0
    local function progress(f)
        if band then f = band[1] + f * band[2] end
        peak = math.max(peak, f)
        task:progress((testing or cases) and peak / 2 or peak)
    end

    -- ---- the test phase (op == "test"), after the build steps -------------
    -- The in-process test plan (loomworks.test_plan, §16.16), its host this
    -- task: the same steps, lines, JUnit files, summary and failure. Each
    -- program is spawned like a build step (streamed, cancellable); the
    -- plan goes on in a model segment once it exited. A device step is not
    -- run here: the service declined a plan whose kit runs on a device.
    -- With `verbose` (`lw test -v`, §16.4 *Verbose*) each runner and program
    -- invocation streams its command lines first and a launch's deploy its
    -- steps, as the in-process host prints them (cli._test_host).
    local test_plan = require("loomworks.test_plan")
    local test_host = {
        out = function(s, role) task:line("out", s, role) end,
        err = function(s, role) task:line("err", s, role) end,
        fail = function(msg, code) finish(code or 1, msg) end,
        progress = function(f) task:progress(0.5 + f / 2) end,
    }
    function test_host.spawn(spec, cb)
        -- (A step ended without calling back leaves no results file behind.)
        local function drop() if spec.cleanup then pcall(spec.cleanup) end end
        if run.cancelled then drop(); return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then drop(); return finish(1, stopped(why)) end
        if args.verbose then
            for _, l in ipairs(build_run.command_lines(spec, spec.cwd or ws.root, { env = ctx.env })) do
                task:line("out", l, "command")
            end
        end
        spawn(spec, function(code, signal)
            if run.cancelled then drop() end
            if ended_by_cancel() then return end
            local okn, whyn = current()
            if not okn then drop(); return finish(1, stopped(whyn)) end
            cb(build_run.exit_status(code, signal))
        end)
    end
    -- The framework probe of a build target's artifact, as a child of this
    -- run (so a cancel kills it) on the event loop — never the in-process
    -- blocking probe_sync, which would stall every other client for up to
    -- gtest.PROBE_TIMEOUT_MS per program.
    function test_host.probe(exe, label, o, cb)
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        local gtest = require("loomworks.gtest")
        if gtest._foreign_diag(exe) then return cb(nil) end
        local out, timer = {}, nil
        local child = {}
        child.obj = M.spawn({ cmd = gtest.probe_argv(exe), cwd = o.cwd, env = envscope.with_overlay(ctx.env, o.env) }, {
            output = function(stream, text)
                if stream == "stdout" and type(text) == "string" then out[#out + 1] = text end
            end,
            done = function(code)
                if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
                svc:with_model(ctx, function()
                    if ended_by_cancel() then return end
                    local okn, whyn = current()
                    if not okn then return finish(1, stopped(whyn)) end
                    cb((gtest.probe_outcome(exe, label, { code = code, stdout = table.concat(out) })))
                end)
            end,
        })
        if not child.obj then return end -- (done(127) is on its way: not gtest)
        child.pid = child.obj.pid
        if child.pid then child.start = require("loomworks.proc").start_time(child.pid) end
        run.child = child
        timer = uv.new_timer()
        timer:start(gtest.PROBE_TIMEOUT_MS, 0, function() vim.schedule(function() M.kill(child) end) end)
    end
    -- A launch's deploy: each copy on the event loop, stopping between
    -- copies on a cancel (which then ends the run once the copy in flight
    -- is done).
    function test_host.deploy(lt, cb)
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        run.deploying = true
        lt:deploy_async({
            cancelled = function() return run.cancelled end,
            resume = function(fn) svc:with_model(ctx, fn) end,
            on_step = deploy_step,
        }, function(ok, err)
            run.deploying = false
            if run.cancelled then return finish(run.cancel_code, stopped()) end
            local okn, whyn = current()
            if not okn then return finish(1, stopped(whyn)) end
            cb(ok, err)
        end)
    end
    function test_host.exec(lt, o, cb) return test_plan.exec_step(ws, lt, o, test_host, cb) end
    local function test_phase()
        -- Parse the units' targets before planning: a test step's run
        -- environment (sibling DLL dirs on Windows) derives from them.
        for _, pp in ipairs(profile:projects()) do build_run.ensure_unit_targets(ws, pp._config_unit) end
        local topts = { junit = args.junit, extra = args.extra or {}, no_build = args.no_build }
        local prepared, perr = test_plan.prepare(ws, profile, ctx.test_pre, topts)
        if not prepared then return finish(1, perr) end
        -- (`no_build`: a possibly stale build's notes, §16.16.)
        for _, n in ipairs(prepared.notes or {}) do task:line("note", n, "plain") end
        if #prepared.steps == 0 then
            release_all()
            task:line("out", "no tests to run for profile '" .. profile.key .. "'", "plain")
            return finish(0, nil, { result = { steps = {}, junit = {} } })
        end
        test_plan.run(ws, profile, prepared, topts, test_host, function(code, err, results)
            -- (The structured results: Tests/1.run's task result, §19.15.)
            finish(code, err, { result = results })
        end)
    end

    -- ---- the run's preparation (op == "run"), after the build ---------------
    -- Exactly what the in-process `lw run` does before its `running …` line
    -- (cli.cmd_run, `_run_launch_target_impl`), over loomworks.run_prep; the
    -- locks are already released (deploy runs without them, as in-process).
    local target_scoped = (running and args.build_scope == "target" and not args.no_build) or target_build
    local function prepare()
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        local rp = require("loomworks.run_prep")
        -- (Refreshed: this unit's targets may predate the build.)
        local lt, serr = rp.select(ws, profile, args.target, args.project, args.kind, { refresh = true })
        if not lt then return finish(1, serr) end
        local verr = rp.validity_error(lt)
        if verr then return finish(1, verr) end
        -- No device debug (§18.11): refused before any deploy, never declined.
        -- (A target-scoped build already probed the artifact, before its
        -- post-build deploy: these checks then pass.)
        local drefusal = debugging and rp.debug_refusal(lt) or nil
        if drefusal then return finish(1, drefusal) end
        -- A wrapper (`--prefix`, kept by the client) wraps LOCAL execution:
        -- a device target is refused before any deploy, as in-process.
        if args.prefix and lt:requires_device() then
            return finish(1, "--prefix cannot wrap a device target ('" .. lt:display_name() ..
                "') — a local wrapper does not apply to on-device execution.")
        end
        -- Likewise a per-invocation working directory: a usage error (exit 2).
        if args.cwd and lt:requires_device() then
            return finish(2, "--cwd does not apply to a device run ('" .. lt:display_name()
                .. "') — set the project's device.working_dir instead")
        end
        -- A foreign artifact runs on a device, in the client (§19.15): before
        -- any deploy, which the client then does itself.
        if rp.foreign_of(lt) then return finish(0, nil, { device = true }) end
        -- (A target-scoped build deployed in its own phases.)
        if not args.no_build and not target_scoped then
            local dok, derr = lt:deploy_sync({ on_step = deploy_step })
            if not dok then return finish(1, "deploy failed: " .. tostring(derr)) end
            if ctx.refused then return finish(1, ctx.refused) end
        end
        local spec, rerr = rp.resolve_spec(lt, { extra_args = args.extra, cwd_override = args.cwd })
        if not spec then return finish(1, rerr) end
        -- The environment is the client's here (envscope): `env` is the
        -- launch's own contribution over it, never a whole environment.
        -- (An empty contribution is still a JSON object, Common/1 `env`.)
        local env = rp.env_overrides(spec.env)
        local launch = {
            name = spec.name, cmd = spec.cmd, args = spec.args or {}, cwd = spec.cwd or ws.root,
            env = next(env) and env or vim.empty_dict(),
        }
        -- A debug launch: the same resolution, handed to the client's
        -- debugger with its adapters (Common/1 DebugSpec).
        if debugging then return finish(0, nil, { result = { debug = rp.debug_spec(ws, lt, launch) } }) end
        finish(0, nil, { launch = launch })
    end

    -- ---- a clean (op == "clean"), after the locks ---------------------------
    -- Exactly what the in-process `lw clean` does (cli.cmd_clean, over
    -- loomworks.build_run): one line and step per project, the first failure
    -- ends it. A successful module clean step records its unit `configured`
    -- (build_run.after_clean_step, as in-process).
    local csteps, ci = ctx.clean_steps or {}, 0
    local wipe_groups = build_run.wipe_groups(ws, csteps)
    local next_clean
    local function clean_step_done(step, code, signal)
        if ended_by_cancel() then return end
        code, signal = build_run.exit_status(code, signal)
        build_run.after_clean_step(ws, step, code)
        if code ~= 0 then return finish(code, build_run.failure_message(step, code, nil, signal)) end
        task:progress(ci / #csteps)
        next_clean()
    end
    next_clean = function()
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        ci = ci + 1
        if ci > #csteps then
            release_all()
            task:line("out", build_run.ok_line("clean", label))
            return finish(0)
        end
        local step = csteps[ci]
        task:progress((ci - 1) / #csteps)
        task:line("out", build_run.clean_step_line(step))
        if not step.wipe_build_dir then
            if args.verbose then
                for _, l in ipairs(build_run.command_lines(step, step.cwd or ws.root, { env = ctx.env })) do
                    task:line("out", l, "command")
                end
            end
            return spawn(step, function(code, signal) clean_step_done(step, code, signal) end)
        end
        if args.verbose then task:line("out", build_run.remove_line(step.build_dir), "command") end
        -- The core-performed wipe: the in-process deletion (build_run.wipe_step
        -- over Workspace:clean_wipe_build_dir — cache `unknown` first, reset
        -- only after success, a dir shared outside the clean kept). Its
        -- removal is asynchronous; the run's cancellation is its stop
        -- predicate (a stopped wipe leaves the cache `unknown`). The locks this
        -- run holds are re-entered by the deletion.
        run.wiping = true
        build_run.wipe_step(ws, step, wipe_groups, { stop = function() return run.cancelled end },
            function(code, msg, _, note)
                svc:with_model(ctx, function()
                    run.wiping = false
                    if run.cancelled then return finish(run.cancel_code, stopped()) end
                    if code ~= 0 then return finish(code, msg) end
                    if note then task:line("out", note, "plain") end
                    task:progress(ci / #csteps)
                    next_clean()
                end)
            end)
    end

    -- ---- the build steps ---------------------------------------------------
    local steps, i = nil, 0
    local case_api
    local next_step
    -- (Set by a target-scoped launch build: what follows a unit's steps.)
    local after_steps

    local function step_done(step, code, signal)
        if ended_by_cancel() then return end
        -- (Idempotent: a step a signal ended fails with 128 + signal.)
        code, signal = build_run.exit_status(code, signal)
        build_run.after_step(ws, step, code)
        -- A refused save (§2.7) ends the build as the in-process host's `die`
        -- does, before anything else runs.
        if ctx.refused then return finish(1, ctx.refused) end
        if code ~= 0 then
            local th = step.kind == "build" and svc.host.unknown_target_hint
                and svc.host.unknown_target_hint(ws, step, args.targets) or nil
            return finish(code, build_run.failure_message(step, code, th, signal))
        end
        progress(i / #steps)
        next_step()
    end

    next_step = function()
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        i = i + 1
        if i > #steps then
            if testing then return test_phase() end
            if cases then return cases.after_build(case_api) end
            release_all()
            -- A unit of a target-scoped launch build: on to the next phase.
            if after_steps then return after_steps() end
            -- A run's build ends without a line of its own (as in-process).
            if running then return prepare() end
            task:line("out", build_run.ok_line(op == "configure" and "configure" or "build", label))
            return finish(0)
        end
        local step = steps[i]
        progress((i - 1) / #steps)
        local ok_g, g_err = build_run.before_step(ws, step, { force = args.force })
        if not ok_g then return finish(1, g_err) end
        -- (`-v`: the env line against the client's environment, §19.15.)
        local lines, roles = build_run.step_lines(ws, step, { verbose = args.verbose, env = ctx.env })
        for k, line in ipairs(lines) do task:line(out_stream, line, roles[k]) end
        -- Within the step, its build tool's progress lines move the percent.
        local base = i - 1
        spawn(step, function(code, signal) step_done(step, code, signal) end,
            function(f) if i == base + 1 then progress((base + f) / #steps) end end)
    end

    -- ---- a target-scoped launch build (§19.15 "Build scope of a launch",
    -- "Build of a launch target") ---------------------------------------------
    -- The launch flow the editor runs in-process before a launch (§8.8.4
    -- steps 3-6, LaunchTarget:build + deploy): each dependency's unit, the
    -- pre-build deploy steps, the launch target's own unit (its one target
    -- where the module builds single targets), then — a preparation only —
    -- the artifact probe and the post-build deploy steps. Each unit's build
    -- takes that unit's build-directory lock for that build only; the deploy
    -- steps run asynchronously, without locks, a cancel stopping them between
    -- two copies; the first failure ends the task, the later phases not run.
    -- Each phase is one step of the task (§19.15 "Steps of a task").

    --- The launch target and its phases, each with its step (`{ id, kind,
    --- label, project?, configuration?, target?, phase?, state = "pending"
    --- }`), planned before the task starts (its `start.meta.steps`) — or
    --- nil and the refusal of the target (resolution, validity, a debug's
    --- kit-told refusal, a device target's build, an abstract configuration).
    --- @return { lt: table, phases: table[] }|nil, string|nil
    local function plan_target_scope()
        local rp = require("loomworks.run_prep")
        local lt, serr = rp.select(ws, profile, args.target, args.project, args.kind, { refresh = true })
        if not lt then return nil, serr end
        local verr = rp.validity_error(lt)
        if verr then return nil, verr end
        local drefusal = debugging and rp.debug_refusal(lt, true) or nil
        if drefusal then return nil, drefusal end
        if target_build and lt:requires_device() then return nil, rp.device_build_refusal(lt) end
        local aerr = lt:abstract_error()
        if aerr then return nil, aerr end
        local phases = {}
        local function add(ph, step)
            ph.step = step
            phases[#phases + 1] = ph
        end
        local pkey = lt._project and lt._project.key or nil
        for _, dep in ipairs(lt:build_dependencies()) do
            -- (Named for the plan; resolved again when its turn comes.)
            local u = lt:_resolve_dep_config_unit(dep.project, dep.config_hint)
            add({ dep = dep }, { kind = "build", label = "dependency " .. dep.project.key,
                project = dep.project.key, configuration = u and u:config_key() or nil })
        end
        -- (A phase that declares no copies is no step.)
        local function deploy(phase)
            local n = lt:deploy_count(phase)
            if n > 0 then
                add({ deploy = phase, copies = n },
                    { kind = "deploy", label = "deploy (" .. phase .. ")", project = pkey, phase = phase })
            end
        end
        deploy("pre_build")
        local own = lt._target and lt._target._config_unit or lt._config_unit
        if own then
            local tid = lt._target and lt._target.id or nil
            add({ unit = own, target_id = tid }, { kind = "build", label = lt:display_name(),
                project = own._project and own._project.key or pkey, configuration = own:config_key(),
                target = tid })
        end
        -- The artifact is probed once the target's own unit built, before the
        -- post-build deploy (§19.15 "Debug"; "Run": a foreign artifact runs
        -- on a device, in the client, which then deploys itself).
        if not target_build then
            add({ probe = true }, { kind = "probe", label = "probe " .. lt:display_name(), project = pkey })
            deploy("post_build")
        end
        for index, ph in ipairs(phases) do
            ph.step.id, ph.step.state = "s" .. index, "pending"
        end
        return { lt = lt, phases = phases }
    end

    --- Run the planned phases (plan_target_scope), each step's state
    --- following it; a preparation then prepares the launch.
    local function target_scope(scope)
        local rp = require("loomworks.run_prep")
        local lt, phases = scope.lt, scope.phases
        local LaunchTarget = require("loomworks.launch_target")
        local overseer = require("loomworks.overseer")
        local pi = 0
        local next_phase
        -- The phase (its step) succeeded: on to the next one.
        local function phase_done()
            set_step(pi, "ok")
            next_phase()
        end
        next_phase = function()
            if run.cancelled then return finish(run.cancel_code, stopped()) end
            local okc, why = current()
            if not okc then return finish(1, stopped(why)) end
            pi = pi + 1
            local ph = phases[pi]
            band = nil
            if not ph then
                -- A launch target's build ends here (no launch to resolve),
                -- with the plain build's closing line.
                if target_build then
                    task:line(out_stream, build_run.ok_line("build", lt:display_name()))
                    return finish(0)
                end
                return prepare()
            end
            progress((pi - 1) / #phases)
            set_step(pi, "running")
            if ph.probe then
                -- (Refreshed: the unit's targets may predate its build.)
                local plt, perr = rp.select(ws, profile, args.target, args.project, args.kind, { refresh = true })
                if not plt then return finish(1, perr) end
                local prefusal = debugging and rp.debug_refusal(plt) or nil
                if prefusal then return finish(1, prefusal) end
                if not debugging and rp.foreign_of(plt) then
                    -- (The probe succeeded; the post-build deploy is the client's.)
                    set_step(pi, "ok")
                    return finish(0, nil, { device = true })
                end
                return phase_done()
            end
            if ph.deploy then
                -- (n counts the declared sources, fresh ones included.)
                task:line(out_stream, "deploying (" .. ph.deploy .. "): " .. ph.copies
                    .. (ph.copies == 1 and " copy" or " copies"), "plain")
                -- Each copy on the event loop, a cancel stopping between two
                -- copies (it then ends the run once the copy in flight is done).
                run.deploying = true
                lt:_deploy_phase(ph.deploy, function(dok, derr)
                    run.deploying = false
                    -- A cancel during the last copy: every copy completed and
                    -- its records were saved, so the step is ok; the cancel
                    -- then stops the run at the next phase.
                    if run.cancelled and not dok then return finish(run.cancel_code, stopped()) end
                    local okn, whyn = current()
                    if not okn then return finish(1, stopped(whyn)) end
                    if not dok then return finish(1, "deploy failed: " .. tostring(derr)) end
                    if ctx.refused then return finish(1, ctx.refused) end
                    phase_done()
                end, {
                    async = true,
                    cancelled = function() return run.cancelled end,
                    resume = function(fn) svc:with_model(ctx, fn) end,
                    on_step = deploy_step,
                })
                return
            end
            local unit = ph.unit
            if ph.dep then
                unit = lt:_resolve_dep_config_unit(ph.dep.project, ph.dep.config_hint)
                if not unit then return finish(1, LaunchTarget.unresolved_dependency_message(ph.dep.project)) end
                task:line(out_stream, "building dependency: " .. ph.dep.project.key, "plain")
            end
            local bd = unit.build_dir and unit:build_dir() or nil
            local lok, lmsg = take_locks(run, ws, task, bd and { bd } or {}, "build",
                ctx.command or ("lw " .. op))
            if not lok then return finish(1, lmsg) end
            -- (Planned against the requested profile, not the active one.)
            local planned, perr = overseer.plan_unit_build(ws, unit,
                { target_id = ph.target_id, profile = profile })
            if not planned then return finish(1, "cannot build: " .. tostring(perr)) end
            if #planned == 0 then release_all(); return phase_done() end
            steps, i, after_steps = planned, 0, phase_done
            band = { (pi - 1) / #phases, 1 / #phases }
            next_step()
        end
        task:line(out_stream, "building launch target: " .. lt:display_name(), "lead")
        next_phase()
    end

    -- The profile and its units as semantic keys: an observer resolves them
    -- to its own domain objects (spec §19.15, §19.16).
    local units = {}
    if units_scope then
        for _, u in ipairs(units_scope) do
            units[#units + 1] = { project = u._project and u._project.key or nil, configuration = u:config_key() }
        end
    else
        for _, pp in ipairs(profile:projects()) do
            units[#units + 1] = { project = pp:project_key(), configuration = pp:config_key() }
        end
    end
    -- A target-scoped task's phases are planned before it starts: its steps
    -- are its start meta's (§19.15 "Steps of a task").
    local scope_plan, scope_err
    if target_scoped then
        -- (A throw while planning ends the task, once started, as a
        -- failure with no steps.)
        local okp, a, b = pcall(plan_target_scope)
        if okp then
            scope_plan, scope_err = a, b
        else
            scope_plan, scope_err = nil, "cannot plan the launch target's build: " .. tostring(a)
        end
        if scope_plan then
            step_states = {}
            for index in ipairs(scope_plan.phases) do step_states[index] = "pending" end
        end
    end
    local plan_steps
    for _, ph in ipairs(scope_plan and scope_plan.phases or {}) do
        plan_steps = plan_steps or {}
        plan_steps[#plan_steps + 1] = ph.step
    end
    task:start({ name = label, kind = cases and cases.kind or op, profile = profile and profile.key or nil,
        units = units, steps = plan_steps })
    -- A test run's pre-build plan: the service's (its notes and refusal were
    -- the reply's, before acceptance), else checked here.
    if testing and not ctx.test_pre then
        ctx.test_pre = test_plan.precheck(profile, { extra = args.extra or {} })
        for _, n in ipairs(ctx.test_pre.notes) do task:line("note", n, "plain") end
        if ctx.test_pre.err then finish(ctx.test_pre.code, ctx.test_pre.err); return run end
    end
    -- `--no-build` / `--dry-run`: no build, no lock — straight to the launch.
    if running and args.no_build then prepare(); return run end
    if target_scoped then
        if not scope_plan then finish(1, scope_err); return run end
        target_scope(scope_plan)
        return run
    end
    -- A debug of a target its kit already tells is foreign (or a device
    -- target) is refused before the build (§19.15 "Debug"); one found by
    -- probing its artifact, once the build probed it (prepare).
    if debugging then
        local rp = require("loomworks.run_prep")
        local lt = rp.select(ws, profile, args.target, args.project, args.kind, { refresh = true })
        local drefusal = lt and rp.debug_refusal(lt, true) or nil
        if drefusal then finish(1, drefusal); return run end
    end
    -- A clean that wipes performs a deletion: the workspace operation lock
    -- first (spec §19.3 lock order, as in-process cli.cmd_clean).
    if op == "clean" and build_run.has_wipe(csteps) then
        local tok, omsg = ws:_op_lock("clean")
        if not tok then finish(1, omsg or "clean refused: the workspace operation lock is held"); return run end
        run.op_tok = tok
    end
    -- What an editor test run's own phase (after its build) runs with.
    case_api = { run = run, task = task, ws = ws, ctx = ctx, finish = finish, stopped = stopped, current = current,
        spawn = spawn, ended_by_cancel = ended_by_cancel, release_all = release_all }
    local dirs = units_scope and build_run.unit_build_dirs(units_scope) or build_run.profile_build_dirs(profile)
    local function locked()
        -- Locks first, exactly like the in-process with_build_dir_locks: every
        -- build directory, canonical order, fail-fast. A test run holds them
        -- across the build AND the test runs (a native runner may rebuild).
        -- (A configure's locks are exclusive, as a clean's: operation `configure`.)
        local lok, lmsg = take_locks(run, ws, task, dirs,
            (op == "clean" or op == "configure") and op or "build", ctx.command or ("lw " .. op))
        if not lok then finish(1, lmsg); return run end

        if op == "clean" then
            task:line("out", build_run.lead_line("clean", scope_line))
            next_clean()
            return run
        end

        -- `lw test --no-build` (§16.16 "Skipping the build"): no build steps;
        -- the locks stay held across the plan's checks and its steps.
        if testing and args.no_build then test_phase(); return run end

        local plan_err
        if cases then
            steps, plan_err = cases.plan()
        elseif testing then
            -- The for-test build: a unit whose runner rebuilds itself is not
            -- built separately unless it has saved test targets (`keep`); the
            -- arguments after `--` are the test steps'.
            steps, plan_err = build_run.plan(profile, { for_test = { keep = ctx.test_pre.keep } })
        else
            steps, plan_err = build_run.plan(profile, {
                -- (A run's `extra` are the program's arguments, not the build's.)
                extra_args = not running and args.extra or nil,
                build_targets = args.targets,
                reconfigure = args.reconfigure,
                configure_only = op == "configure" or nil,
                jobs = args.jobs,
                units = units_scope,
            })
        end
        if not steps then finish(1, plan_err); return run end
        if #steps == 0 then
            if testing then test_phase(); return run end
            if cases then cases.after_build(case_api); return run end
            -- Nothing to build: a run goes on with what is there (as in-process).
            if running then release_all(); prepare(); return run end
            -- No configure step (a module without one): nothing to do, as the
            -- editor's configure action does nothing for it.
            if op == "configure" then
                release_all()
                task:line("out", "nothing to configure for " .. (units_scope and label or ("profile '" .. label .. "'")), "plain")
                finish(0); return run
            end
            finish(1, build_run.nothing_to_build_message(profile, units_scope and label or nil)); return run
        end
        task:line(out_stream, build_run.lead_line(op == "configure" and "configure" or "build", scope_line))
        -- The same trust notice as the in-process build (spec §17.10, §19.15).
        local tn, tn_role = build_run.trust_notice(ws, profile, units_scope)
        if tn then task:line("note", tn, tn_role) end
        next_step()
    end
    -- An editor test run waits for the Tests/1 tasks of its directories
    -- (FIFO, §19.15 "Tests") before it takes their locks.
    if cases then cases.wait(dirs, locked, case_api) else locked() end
    return run
end

--- Run an accepted reset (`lw reset`, spec §19.15 "Reset", §16.30): exactly
--- what the in-process cli.cmd_reset does after its confirmation, over
--- loomworks.reset_plan — the listing (only for `-y`: a confirmed reset's
--- client printed it), the workspace operation lock (operation `reset`), then
--- the build-directory lock of every directory of the plan's lock set,
--- exclusive, then reset_plan.execute (the ONE deletion path: Profile:reset /
--- Workspace:reset_all; cache `unknown` before a tree is removed, reset only
--- after success, shared directories kept) and the non-blocking
--- gone-from-disk check, then `RESET OK: <scope>`.
---
--- The run's cancellation is the deletion's stop predicate (between
--- entries); a stopped reset leaves the cache `unknown`. The locks are held
--- until the deletion itself has settled -- also after a timeout ended the
--- task -- and then released, the operation lock last; only then is the run
--- reported done to the service (`svc:on_run_done`).
--- @param svc table the build service
--- @param ctx table { task, ws, plan, env, command, listing }
--- @return loomworks.daemon.BuildRun
function M.reset(svc, ctx)
    local reset_plan = require("loomworks.reset_plan")
    local build_lock = require("loomworks.build_lock")
    local task, ws, plan = ctx.task, ctx.ws, ctx.plan
    local run = { task = task, op = "reset", cancelled = false, held = {} }
    ctx.run = run
    -- run.deleting: the deletion started; run.deletion_settled: it ended. The
    -- service keeps the daemon busy in between, also after a timeout ended
    -- the task, and its stop sets `cancelled` for it (on_stopping).

    local function release_all()
        for _, h in ipairs(run.held) do build_lock.release(h) end
        run.held = {}
        if run.op_tok then
            local tok = run.op_tok
            run.op_tok = nil
            if ws._op_unlock then ws:_op_unlock(tok) else require("loomworks.op_lock").release(tok) end
        end
    end
    run.release_all = release_all
    -- The locks go once the task ended AND no deletion is still running.
    local function maybe_release()
        if run.released or not run.finished or (run.deleting and not run.deletion_settled) then return end
        run.released = true
        release_all()
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function finish(code, err)
        if run.finished then return end
        run.finished = true
        task:done(code, err)
        maybe_release()
    end
    local function stopped()
        return "reset stopped: " .. tostring(run.cancel_reason)
    end

    --- Stop the reset (idempotent; a no-op once finished).
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        -- A running deletion stops between entries (its stop predicate sees
        -- `cancelled`); its end finishes the run, the locks held until
        -- nothing more is removed.
        if run.deleting then return end
        svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
    end

    -- The planned units as semantic keys (an observer resolves them, §19.16);
    -- `--all` has no profile (`scope = "all"`).
    local units = {}
    for _, u in ipairs(plan.units or {}) do
        local pk = u._project and u._project.key or u._init_project_key
        if pk then units[#units + 1] = { project = pk, configuration = u:config_key() } end
    end
    local pkey = plan.profile and plan.profile.key or nil
    task:start({ name = pkey or "--all", kind = "reset", profile = pkey,
        scope = plan.scope == "all" and "all" or nil, units = units })
    if ctx.listing then
        for _, line in ipairs(reset_plan.listing(plan)) do task:line("out", line, "plain") end
    end

    -- Lock order (spec §19.3): the workspace operation lock first, then every
    -- build directory's; the workspace's own deletion re-enters both.
    local tok, omsg = ws:_op_lock("reset")
    if not tok then
        finish(1, ctx.refused or omsg or "reset refused: the workspace operation lock is held")
        return run
    end
    run.op_tok = tok
    local lok, lmsg = take_locks(run, ws, task, plan.lock_dirs, "reset", ctx.command or "lw reset")
    if not lok then finish(1, lmsg); return run end
    -- Under the locks, before anything is removed: the plan must still be the
    -- one listed (§16.30; the same check as the in-process host).
    local vok, vmsg = reset_plan.verify(ws, plan)
    if not vok then finish(1, vmsg); return run end

    run.deleting = true
    reset_plan.execute(ws, plan, {
        stop = function() return run.cancelled end,
        settled = function()
            svc:with_model(ctx, function()
                run.deletion_settled = true
                maybe_release()
            end)
        end,
    }, function(code, msg, was_stopped)
        svc:with_model(ctx, function()
            if was_stopped or run.cancelled then return finish(run.cancel_code or 1, stopped()) end
            if code ~= 0 then return finish(code or 1, msg) end
            for _, line in ipairs(reset_plan.mirror_warnings(plan)) do task:line("out", line, "warn") end
            task:line("out", reset_plan.ok_line(plan))
            finish(0)
        end)
    end)
    return run
end

return M
