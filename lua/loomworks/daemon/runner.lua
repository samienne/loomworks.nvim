--- loomworks/daemon/runner.lua — run build steps daemon-side, streaming output.
---
--- The daemon owns build EXECUTION (DAEMON.md §3.4). It runs the SAME build
--- path as the in-process `lw build` — `loomworks.build_run` (lock → plan with
--- the build gate + build request → per step: conflict gate / full-reconfigure
--- reset → announce + log the command → hardened spawn → record the result →
--- failure message) — and differs only in that each step is spawned ASYNC with
--- its stdout/stderr forwarded into the workspace task stream (so every
--- connected client sees the build live) and a refusal is a task-stream error
--- instead of a process exit. The caller emits the durable `model_change`
--- (build_state) on completion.
---
--- **Cancellation** (spec §19.12): `run_build` returns a controller whose
--- `cancel(reason)` kills the running step's process tree and stops the run
--- WITHOUT recording the interrupted step — the daemon equivalent of Ctrl-C on
--- an in-process build (whose exit hooks release the locks and whose killed
--- child never records). The service cancels a build when its launching client
--- disconnects, when the daemon stops, and when the workspace it runs in is
--- unloaded (a refused working copy / cache, §17.4) or its profile disappears.
---
--- **Main-loop discipline.** A daemon command is handled inside a libuv pipe
--- callback (a Neovim *fast event context* when the daemon runs in-process under
--- an editor). The build TASK BUILDERS (`plan_profile_build`) and the cache
--- write-back call `vim.fn.*` (e.g. `mkdir`), which is forbidden in a fast event
--- context. So every step that touches `vim.fn`/`vim.api` — planning, lock
--- acquisition, `record_task_result`, artifact population — is hopped onto the
--- main loop via `on_main`. Under the standalone (luvi) host there is no fast
--- context, but `vim.schedule` is a harmless drained-scheduler defer there.

local build_run = require("loomworks.build_run")

local M = {}

local uv = vim.uv or vim.loop

--- How often a running build re-checks that its workspace is still loaded.
M.WATCH_MS = 500

--- Run `fn` on the main loop (nvim) / drained scheduler (luvi), so
--- `vim.fn`/`vim.api` work never executes in a libuv fast event context.
--- @param fn fun()
local function on_main(fn)
    if vim.schedule then vim.schedule(fn) else fn() end
end

--- Spawn `argv` asynchronously, forwarding output to `sink.output(stream, text)`
--- and completion to `sink.done(code)`. Returns the process handle (with
--- `pid` and `kill(signal)`).
--- @param argv string[]
--- @param opts { cwd?: string, env?: table }
--- @param sink { output: fun(stream:string, text:string), done: fun(code:integer) }
--- @return any handle
function M.spawn_stream(argv, opts, sink)
    opts = opts or {}
    local env = (opts.env and next(opts.env)) and opts.env or nil
    return vim.system(argv, {
        cwd = opts.cwd,
        env = env,
        text = true,
        stdout = function(_, data) if data and data ~= "" then sink.output("stdout", data) end end,
        stderr = function(_, data) if data and data ~= "" then sink.output("stderr", data) end end,
    }, function(res)
        sink.done(res.code or 0)
    end)
end

--- Kill a spawned step and its descendants (a build tool's compilers). On
--- Windows `taskkill /T` walks the tree; elsewhere the direct children are
--- signalled before the process itself. Best-effort, never throws.
--- @param handle any the object `spawn_stream` returned
function M.kill_tree(handle)
    if not handle then return end
    local pid = handle.pid
    if pid then
        if vim.fn and vim.fn.has and vim.fn.has("win32") == 1 then
            pcall(vim.system, { "taskkill", "/PID", tostring(pid), "/T", "/F" }, { text = true })
        else
            pcall(vim.system, { "pkill", "-TERM", "-P", tostring(pid) }, { text = true })
        end
    end
    if handle.kill then pcall(handle.kill, handle, "sigterm") end
end

--- Run a profile's build steps sequentially, streaming each into `task_stream`
--- under `task_id`, persisting each step's result through the workspace, and
--- calling `on_done(overall_code)` when finished (stopping at the first failing
--- step). The in-process `run_build_steps` path, async + streaming.
--- @param workspace table the authoritative Workspace
--- @param profile table the resolved Profile
--- @param task_stream loomworks.daemon.TaskStream
--- @param task_id integer|string
--- @param opts? { extra_args?: string[], force?: boolean, is_current?: fun(): boolean, string|nil }
---   `is_current()` returns false (+ reason) once the workspace/profile this
---   build runs in is no longer the daemon's live one — the build then stops.
--- @param on_done fun(code: integer)
--- @return { cancel: fun(reason?: string, code?: integer) } controller
function M.run_build(workspace, profile, task_stream, task_id, opts, on_done)
    opts = opts or {}
    local ctl = { cancelled = false, finished = false }
    local held, watch = {}, nil
    local build_lock = require("loomworks.build_lock")

    local function release_all()
        for _, h in ipairs(held) do build_lock.release(h) end
        held = {}
        if watch then pcall(function() watch:stop(); watch:close() end); watch = nil end
    end
    local function finish(code)
        if ctl.finished then return end
        ctl.finished = true
        release_all()
        task_stream:done(task_id, code)
        on_done(code)
    end
    local function fail(msg, code)
        if ctl.finished then return end
        task_stream:notify("error", "build", msg, task_id)
        finish(code or 1)
    end
    local function say(line) task_stream:output(task_id, "stdout", line .. "\n") end

    --- Stop the run: kill the running step (its result is never recorded) and
    --- report `reason`. Idempotent; a no-op once the run finished.
    function ctl.cancel(reason, code)
        if ctl.cancelled or ctl.finished then return end
        ctl.cancelled = true
        ctl.cancel_code = code or 130
        ctl.cancel_reason = reason or "cancelled"
        if ctl.handle then
            M.kill_tree(ctl.handle) -- its done() finishes the run
        else
            on_main(function() fail("build stopped: " .. ctl.cancel_reason, ctl.cancel_code) end)
        end
    end

    -- All vim.fn-touching orchestration runs on the main loop (see header).
    on_main(function()
        if ctl.cancelled then return end
        -- Cross-process build-dir locks (§16.6), taken BEFORE planning exactly
        -- like the in-process `with_build_locks(profile, "build", …)`: an
        -- editor or a CLI never builds a directory the daemon is building (and
        -- vice-versa). SEPARATE from the daemon's write-authority lock (files
        -- vs build dirs).
        for _, bd in ipairs(build_run.profile_build_dirs(profile)) do
            local h, err = build_lock.acquire(bd, "build")
            if not h then return fail("cannot build: " .. tostring(err)) end
            held[#held + 1] = h
        end

        local steps, plan_err = build_run.plan(profile, { extra_args = opts.extra_args })
        if not steps then return fail(plan_err) end
        if #steps == 0 then return fail(build_run.nothing_to_build_message(profile)) end

        task_stream:start(task_id, { name = profile.key, kind = "build", total_steps = #steps })
        say("building profile: " .. profile.key)

        -- Watchdog: a workspace unloaded under a running build (a refused
        -- working copy / cache, §17.4) or a profile that disappeared stops it.
        if opts.is_current then
            watch = uv.new_timer()
            watch:start(M.WATCH_MS, M.WATCH_MS, function()
                on_main(function()
                    if ctl.finished or ctl.cancelled then return end
                    local current, why = opts.is_current()
                    if not current then ctl.cancel(why or "workspace unloaded", 1) end
                end)
            end)
        end

        local i = 0
        local function next_step()
            if ctl.cancelled then
                return fail("build stopped: " .. ctl.cancel_reason, ctl.cancel_code)
            end
            if opts.is_current then
                local current, why = opts.is_current()
                if not current then
                    return fail("build stopped: " .. tostring(why or "workspace unloaded"))
                end
            end
            i = i + 1
            if i > #steps then return finish(0) end
            local step = steps[i]
            task_stream:progress(task_id, (i - 1) / #steps)

            local ok_g, g_err = build_run.before_step(workspace, step, { force = opts.force })
            if not ok_g then return fail(g_err) end
            for _, line in ipairs(build_run.step_lines(workspace, step, {})) do say(line) end

            local function step_done(code)
                ctl.handle = nil
                if ctl.cancelled then
                    -- Interrupted: like a killed in-process build, the step's
                    -- result is never recorded.
                    return fail("build stopped: " .. ctl.cancel_reason, ctl.cancel_code)
                end
                build_run.after_step(workspace, step, code)
                if code ~= 0 then return fail(build_run.failure_message(step, code), code) end
                task_stream:progress(task_id, i / #steps)
                next_step()
            end

            local spec, s_err = build_run.spawn_spec(step, workspace.root)
            if not spec then
                task_stream:output(task_id, "stderr", "lw: " .. tostring(s_err) .. "\n")
                return step_done(127)
            end
            ctl.handle = M.spawn_stream(spec.cmd, { cwd = spec.cwd, env = spec.env }, {
                output = function(stream, text) task_stream:output(task_id, stream, text) end,
                -- Back to the main loop: cache write-back + the next builder
                -- both touch vim.fn.
                done = function(code) on_main(function() step_done(code) end) end,
            })
        end
        next_step()
    end)
    return ctl
end

return M
