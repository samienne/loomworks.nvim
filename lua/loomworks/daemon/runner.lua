--- loomworks/daemon/runner.lua — run a profile build in the daemon (spec
--- §19.15), streaming it on the task stream.
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
--- streamed to `sink.output(stream, text)` in order and `sink.done(code)`
--- called once the process exited and its output was read. The returned
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
    local exit_code, finished, abandoned, grace = nil, false, false, nil
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
        sink.done(exit_code or 0)
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
    }, function(code)
        pcall(function() handle:close() end)
        exit_code = code
        maybe_finish()
    end)
    if not handle then
        pcall(function() so:close() end)
        pcall(function() se:close() end)
        sink.output("stderr", "spawn failed: " .. tostring(spec.cmd[1]) .. ": " .. tostring(pid) .. "\n")
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

--- @class loomworks.daemon.BuildRun
--- @field task loomworks.daemon.Task
--- @field cancelled boolean

--- Run a build.
--- @param svc table the build service (with_model, host)
--- @param ctx table the request: { env, args, command, task, ws, profile }
--- @return loomworks.daemon.BuildRun
function M.run(svc, ctx)
    local task, ws, profile, args = ctx.task, ctx.ws, ctx.profile, ctx.args or {}
    local build_lock = require("loomworks.build_lock")
    local run = { task = task, cancelled = false, held = {} }
    ctx.run = run

    local function release_all()
        for _, h in ipairs(run.held) do build_lock.release(h) end
        run.held = {}
    end
    local function finish(code, err)
        if run.finished then return end
        run.finished = true
        release_all()
        task:done(code, err)
        if svc.on_run_done then svc:on_run_done(run) end
    end
    local function stopped()
        return "build stopped: " .. tostring(run.cancel_reason)
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
        else
            svc:with_model(ctx, function() finish(run.cancel_code, stopped()) end)
        end
    end

    -- The current workspace/profile still the ones this build runs in?
    local function current()
        if svc.ws ~= ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
        if profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
        return true
    end

    local steps, i = nil, 0
    local next_step

    local function step_done(step, code)
        run.child = nil
        task:set_flow(nil)
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        build_run.after_step(ws, step, code)
        -- A refused save (§2.7) ends the build as the in-process host's `die`
        -- does, before anything else runs.
        if ctx.refused then return finish(1, ctx.refused) end
        if code ~= 0 then
            local th = step.kind == "build" and svc.host.unknown_target_hint
                and svc.host.unknown_target_hint(ws, step, args.targets) or nil
            return finish(code, build_run.failure_message(step, code, th))
        end
        task:progress(i / #steps)
        next_step()
    end

    next_step = function()
        if run.cancelled then return finish(run.cancel_code, stopped()) end
        local okc, why = current()
        if not okc then return finish(1, "build stopped: " .. tostring(why)) end
        i = i + 1
        if i > #steps then
            release_all()
            task:line("out", "BUILD OK: " .. profile.key)
            return finish(0)
        end
        local step = steps[i]
        task:progress((i - 1) / #steps)
        local ok_g, g_err = build_run.before_step(ws, step, { force = args.force })
        if not ok_g then return finish(1, g_err) end
        for _, line in ipairs(build_run.step_lines(ws, step, { verbose = args.verbose })) do
            task:line("out", line)
        end
        local spec, herr = build_run.spawn_spec(step, ws.root)
        if not spec then
            -- As the in-process run_spec: report, then a 127 step failure.
            task:line("err", "lw: " .. tostring(herr) .. "\n")
            return step_done(step, 127)
        end
        local env = envscope.with_overlay(ctx.env, spec.env)
        local child = {}
        child.obj = M.spawn({ cmd = spec.cmd, cwd = spec.cwd, env = env }, {
            output = function(stream, text) task:output(stream, text) end,
            done = function(code)
                svc:with_model(ctx, function() step_done(step, code) end)
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

    task:start({ name = profile.key, kind = "build" })
    -- Locks first, exactly like the in-process with_build_dir_locks: every
    -- build directory, canonical order, fail-fast.
    local lock_break = require("loomworks.lock_break")
    for _, bd in ipairs(build_run.lock_order(build_run.profile_build_dirs(profile))) do
        local shown = ws._display_build_dir and ws:_display_build_dir(bd) or bd
        local lctx = { what = shown, command = ctx.command or "lw build", unlock = shown }
        local h, msg = lock_break.acquire(function()
            local hh, _, info = build_lock.acquire(bd, "build", lctx)
            return hh, info
        end, lctx)
        if not h then finish(1, msg); return run end
        run.held[#run.held + 1] = h
        if h.reclaimed and ws._recover_interrupted_build_dir then
            local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
            if line then task:line("err", "lw: " .. line .. "\n") end
        end
    end

    local plan_err
    steps, plan_err = build_run.plan(profile, {
        extra_args = args.extra,
        build_targets = args.targets,
        reconfigure = args.reconfigure,
    })
    if not steps then finish(1, plan_err); return run end
    if #steps == 0 then finish(1, build_run.nothing_to_build_message(profile)); return run end
    task:line("out", "building profile: " .. profile.key)
    next_step()
    return run
end

return M
