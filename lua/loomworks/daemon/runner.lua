--- loomworks/daemon/runner.lua — run build steps daemon-side, streaming output.
---
--- The daemon owns build EXECUTION (DAEMON.md §3.4). This reuses the SAME
--- planning seam the CLI/editor use — `overseer.plan_profile_build(profile)` —
--- and runs each resolved step with an ASYNC streaming spawn (the async form of
--- the CLI's `run_spec`), forwarding stdout/stderr into the workspace task stream
--- so every connected client sees the build live. The durable outcome is emitted
--- by the caller as a `model_change` (build_state) when the run completes.
---
--- `spawn_stream` is the streaming primitive; `run_build` is the multi-step
--- driver. Both keep the daemon loop unblocked (no `:wait()`).

local M = {}

--- Spawn `argv` asynchronously, forwarding output to `sink.output(stream, text)`
--- and completion to `sink.done(code)`. Returns the process handle.
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

--- Run a profile's build steps sequentially, streaming each into `task_stream`
--- under `task_id`, and call `on_done(overall_code)` when finished (stopping at
--- the first failing step). Reuses `overseer.plan_profile_build`.
--- @param workspace table the authoritative Workspace
--- @param profile table the resolved Profile
--- @param task_stream loomworks.daemon.TaskStream
--- @param task_id integer|string
--- @param opts? table forwarded to plan_profile_build (e.g. { extra_args })
--- @param on_done fun(code: integer)
function M.run_build(workspace, profile, task_stream, task_id, opts, on_done)
    opts = opts or {}
    local ok, overseer = pcall(require, "loomworks.overseer")
    if not ok then
        task_stream:notify("error", "build", "overseer module unavailable", task_id)
        task_stream:done(task_id, 1)
        return on_done(1)
    end
    local steps = overseer.plan_profile_build(profile, opts)
    if not steps or #steps == 0 then
        task_stream:done(task_id, 0)
        return on_done(0)
    end
    task_stream:start(task_id, { name = profile.key, kind = "build", total_steps = #steps })

    local i = 0
    local function next_step()
        i = i + 1
        if i > #steps then
            task_stream:done(task_id, 0)
            return on_done(0)
        end
        local step = steps[i]
        task_stream:progress(task_id, (i - 1) / #steps)
        task_stream:output(task_id, "stdout",
            string.format("==> [%s] %s\n", step.kind, step.name or "?"))
        M.spawn_stream(step.cmd, { cwd = step.cwd or workspace.root, env = step.env }, {
            output = function(stream, text) task_stream:output(task_id, stream, text) end,
            done = function(code)
                if code ~= 0 then
                    task_stream:notify("error", "build",
                        string.format("%s failed (exit %d): %s", step.kind, code, step.name or "?"),
                        task_id)
                    task_stream:done(task_id, code)
                    return on_done(code)
                end
                task_stream:progress(task_id, i / #steps)
                next_step()
            end,
        })
    end
    next_step()
end

return M
