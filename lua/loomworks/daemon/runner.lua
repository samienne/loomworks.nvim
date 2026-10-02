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

--- Spawn a step (test seam). `sink.output(stream, text)`, `sink.done(code)`.
--- @param spec { cmd: string[], cwd: string, env: table }
--- @param sink table
--- @return table|nil obj with `pid` and `kill`
function M.spawn(spec, sink)
    return vim.system(spec.cmd, {
        cwd = spec.cwd,
        env = spec.env,
        clear_env = true,
        stdout = function(_, data) if data and data ~= "" then sink.output("stdout", data) end end,
        stderr = function(_, data) if data and data ~= "" then sink.output("stderr", data) end end,
    }, function(res) sink.done(res.code or 0) end)
end

--- Kill a spawned step's process tree (test seam).
--- @param child { obj: table, pid: integer|nil, start: string|nil }
function M.kill(child)
    local proc = require("loomworks.proc")
    if child.pid and type(child.start) == "string" then
        local ok = pcall(proc.kill_tree, child.pid, child.start)
        if ok then return end
    end
    if child.obj and child.obj.kill then pcall(child.obj.kill, child.obj, "sigkill") end
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
        if not run.finished and child.obj then run.child = child end
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
