--- loomworks/daemon/runner.lua — run a profile build in the daemon (spec
--- §19.15), streaming it on the task stream — or a batch test run (`lw test`,
--- §16.16): the same locks and for-test build, then each native test runner —
--- or the preparation of `lw run` (§19.15 "Run"): the same locks and build
--- (unless `no_build`), the locks released, then the launch target selected,
--- deployed and its launch spec resolved (loomworks.run_prep), returned in
--- the task's `done` for the client to execute — or a clean (`lw clean`,
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
            if line then task:line("err", "lw: " .. line .. "\n") end
        end
    end
    return true
end

--- @class loomworks.daemon.BuildRun
--- @field task loomworks.daemon.Task
--- @field op "build"|"test"|"run"|"clean" the operation
--- @field cancelled boolean
--- @field cancel_reason string|nil
--- @field cancel_code integer|nil
--- @field finished boolean|nil
--- @field held table[] the build-directory lock handles held
--- @field op_tok table|nil a clean's workspace operation lock (it wipes)
--- @field release_all fun()|nil releases the build-directory locks and the operation lock (also on daemon stop)
--- @field child table|nil the running step { obj, pid, start }
--- @field wiping boolean|nil a clean's wipe is running (cancel stops it between entries)
--- @field ctx table|nil the service request that started it
--- @field cancel fun(reason?: string, code?: integer)

--- Run a build, or a batch test run (`ctx.op == "test"`, spec §16.16, §19.15):
--- the same locks and build steps (in their for-test form), then — the locks
--- still held — each native test runner, every one even after one failed; or
--- the preparation of a run (`ctx.op == "run"`, §19.15 "Run"): the build (not
--- under `args.no_build`), the locks released, then `prepare` (target, gate,
--- deploy, launch spec), ending the task with `launch` or `device`; or a clean
--- (`ctx.op == "clean"`, §19.15 "Clean"): the locks, then `ctx.clean_steps`
--- (planned by the service before any lock, build_run.plan_clean).
--- @param svc table the build service (with_model, host)
--- @param ctx table the request: { op?, env, args, command, task, ws, profile, clean_steps? }
--- @return loomworks.daemon.BuildRun
function M.run(svc, ctx)
    local task, ws, profile, args = ctx.task, ctx.ws, ctx.profile, ctx.args or {}
    local op = (ctx.op == "test" or ctx.op == "run" or ctx.op == "clean") and ctx.op or "build"
    local testing = op == "test"
    local running = op == "run"
    -- `lw run --print` / `--dry-run` keep the build's lines off stdout (§16.17).
    local out_stream = (running and args.quiet) and "note" or "out"
    local build_lock = require("loomworks.build_lock")
    local run = { task = task, op = op, cancelled = false, held = {} }
    ctx.run = run

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
    local function finish(code, err, fields)
        if run.finished then return end
        run.finished = true
        release_all()
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
        elseif run.wiping then
            -- The wipe stops between entries (its stop predicate sees
            -- `cancelled`); its end then finishes the run, the locks held
            -- until nothing more is removed.
            return
        else
            svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
        end
    end

    -- The current workspace/profile still the ones this run runs in?
    local function current()
        if svc.ws ~= ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
        if profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
        return true
    end

    --- Spawn `step` streamed, in the client's environment; `on_exit(code,
    --- signal)` runs in a model segment once it exited. A step that cannot be
    --- spawned is reported as the in-process run_spec reports it (127).
    --- `on_progress(fraction)`: the step's own progress, from its module's
    --- progress parser (`step.progress_tool`, `[N/M]` for ninja) over its
    --- standard output lines — as the editor's task path reads it.
    local function spawn(step, on_exit, on_progress)
        local spec, herr = build_run.spawn_spec(step, ws.root)
        if not spec then
            task:line("err", "lw: " .. tostring(herr) .. "\n")
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

    -- Progress: a test run spends the first half building.
    local function progress(f) task:progress(testing and f / 2 or f) end

    -- ---- the test phase (op == "test"), after the build steps -------------
    local tsteps, ti, failed, wrote = nil, 0, {}, {}
    local next_test
    local function test_done(step, code, signal)
        if ended_by_cancel() then return end
        code = build_run.exit_status(code, signal)
        if code ~= 0 then failed[#failed + 1] = step.name or "?" end
        -- JUnit at the caller's path, also for a failed run (CI wants it).
        local path, warning = build_run.junit_result(step)
        if path then wrote[#wrote + 1] = path elseif warning then task:line("err", warning) end
        task:progress(0.5 + ti / #tsteps / 2)
        next_test()
    end
    next_test = function()
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, stopped(why)) end
        ti = ti + 1
        if ti > #tsteps then
            release_all()
            for _, p in ipairs(wrote) do task:line("out", "JUnit: " .. p) end
            local ok_line, failure = build_run.test_summary(profile, failed, #tsteps)
            if failure then return finish(1, failure) end
            task:line("out", ok_line)
            return finish(0)
        end
        local step = tsteps[ti]
        task:line("out", string.format("==> [test] %s", step.name or "?"))
        spawn(step, function(code, signal) test_done(step, code, signal) end)
    end
    local function test_phase()
        -- Parse the units' targets before planning: a test step's run
        -- environment (sibling DLL dirs on Windows) derives from them.
        for _, pp in ipairs(profile:projects()) do build_run.ensure_unit_targets(ws, pp._config_unit) end
        local ts, units = require("loomworks.overseer").plan_profile_test(profile,
            { extra_args = args.extra, junit = args.junit })
        if not ts or #ts == 0 then
            release_all()
            task:line("out", build_run.no_tests_line(profile, units))
            return finish(0)
        end
        local okj, jerr = build_run.prepare_junit(args.junit)
        if not okj then return finish(1, jerr) end
        tsteps = ts
        next_test()
    end

    -- ---- the run's preparation (op == "run"), after the build ---------------
    -- Exactly what the in-process `lw run` does before its `running …` line
    -- (cli.cmd_run, `_run_launch_target_impl`), over loomworks.run_prep; the
    -- locks are already released (deploy runs without them, as in-process).
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
        -- A wrapper (`--prefix`, kept by the client) wraps LOCAL execution:
        -- a device target is refused before any deploy, as in-process.
        if args.prefix and lt:requires_device() then
            return finish(1, "--prefix cannot wrap a device target ('" .. lt:display_name() ..
                "') — a local wrapper does not apply to on-device execution.")
        end
        -- A foreign artifact runs on a device, in the client (§19.15): before
        -- any deploy, which the client then does itself.
        if rp.foreign_of(lt) then return finish(0, nil, { device = true }) end
        if not args.no_build then
            local dok, derr = lt:deploy_sync()
            if not dok then return finish(1, "deploy failed: " .. tostring(derr)) end
            if ctx.refused then return finish(1, ctx.refused) end
        end
        local spec, rerr = rp.resolve_spec(lt, { extra_args = args.extra, cwd_override = args.cwd })
        if not spec then return finish(1, rerr) end
        -- The environment is the client's here (envscope): `env` is the
        -- launch's own contribution over it, never a whole environment.
        finish(0, nil, { launch = {
            name = spec.name, cmd = spec.cmd, args = spec.args or {}, cwd = spec.cwd or ws.root,
            env = rp.env_overrides(spec.env),
        } })
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
            task:line("out", "CLEAN OK: " .. profile.key)
            return finish(0)
        end
        local step = csteps[ci]
        task:progress((ci - 1) / #csteps)
        task:line("out", build_run.clean_step_line(step))
        if not step.wipe_build_dir then
            return spawn(step, function(code, signal) clean_step_done(step, code, signal) end)
        end
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
                    if note then task:line("out", note) end
                    task:progress(ci / #csteps)
                    next_clean()
                end)
            end)
    end

    -- ---- the build steps ---------------------------------------------------
    local steps, i = nil, 0
    local next_step

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
            release_all()
            -- A run's build ends without a line of its own (as in-process).
            if running then return prepare() end
            task:line("out", "BUILD OK: " .. profile.key)
            return finish(0)
        end
        local step = steps[i]
        progress((i - 1) / #steps)
        local ok_g, g_err = build_run.before_step(ws, step, { force = args.force })
        if not ok_g then return finish(1, g_err) end
        for _, line in ipairs(build_run.step_lines(ws, step, { verbose = args.verbose })) do
            task:line(out_stream, line)
        end
        -- Within the step, its build tool's progress lines move the percent.
        local base = i - 1
        spawn(step, function(code, signal) step_done(step, code, signal) end,
            function(f) if i == base + 1 then progress((base + f) / #steps) end end)
    end

    -- The profile and its units as semantic keys: an observer resolves them
    -- to its own domain objects (spec §19.15, §19.16).
    local units = {}
    for _, pp in ipairs(profile:projects()) do
        units[#units + 1] = { project = pp:project_key(), configuration = pp:config_key() }
    end
    task:start({ name = profile.key, kind = op, profile = profile.key, units = units })
    -- `--no-build` / `--dry-run`: no build, no lock — straight to the launch.
    if running and args.no_build then prepare(); return run end
    -- A clean that wipes performs a deletion: the workspace operation lock
    -- first (spec §19.3 lock order, as in-process cli.cmd_clean).
    if op == "clean" and build_run.has_wipe(csteps) then
        local tok, omsg = ws:_op_lock("clean")
        if not tok then finish(1, omsg or "clean refused: the workspace operation lock is held"); return run end
        run.op_tok = tok
    end
    -- Locks first, exactly like the in-process with_build_dir_locks: every
    -- build directory, canonical order, fail-fast. A test run holds them
    -- across the build AND the test runs (a native runner may rebuild).
    local lok, lmsg = take_locks(run, ws, task, build_run.profile_build_dirs(profile),
        op == "clean" and "clean" or "build", ctx.command or ("lw " .. op))
    if not lok then finish(1, lmsg); return run end

    if op == "clean" then
        task:line("out", "cleaning profile: " .. profile.key)
        next_clean()
        return run
    end

    local plan_err
    if testing then
        -- The for-test build: a unit whose runner rebuilds itself is not
        -- built separately; the arguments after `--` are the test runner's.
        steps, plan_err = build_run.plan(profile, { for_test = true })
    else
        steps, plan_err = build_run.plan(profile, {
            -- (A run's `extra` are the program's arguments, not the build's.)
            extra_args = not running and args.extra or nil,
            build_targets = args.targets,
            reconfigure = args.reconfigure,
        })
    end
    if not steps then finish(1, plan_err); return run end
    if #steps == 0 then
        if testing then test_phase(); return run end
        -- Nothing to build: a run goes on with what is there (as in-process).
        if running then release_all(); prepare(); return run end
        finish(1, build_run.nothing_to_build_message(profile)); return run
    end
    task:line(out_stream, "building profile: " .. profile.key)
    -- The same trust notice as the in-process build (spec §17.10, §19.15).
    local tn = build_run.trust_notice(ws, profile)
    if tn then task:line("note", tn) end
    next_step()
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
    local deleting, settled = false, false

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
        if run.released or not run.finished or (deleting and not settled) then return end
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
        if deleting then return end
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
        for _, line in ipairs(reset_plan.listing(plan)) do task:line("out", line) end
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

    deleting = true
    reset_plan.execute(ws, plan, {
        stop = function() return run.cancelled end,
        settled = function()
            svc:with_model(ctx, function()
                settled = true
                maybe_release()
            end)
        end,
    }, function(code, msg, was_stopped)
        svc:with_model(ctx, function()
            if was_stopped or run.cancelled then return finish(run.cancel_code or 1, stopped()) end
            if code ~= 0 then return finish(code or 1, msg) end
            task:line("out", reset_plan.ok_line(plan))
            finish(0)
        end)
    end)
    return run
end

return M
