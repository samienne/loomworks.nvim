--- loomworks/daemon/runner.lua — run build steps daemon-side, streaming output.
---
--- The daemon owns build EXECUTION (DAEMON.md §3.4). This reuses the SAME
--- planning seam the CLI/editor use — `overseer.plan_profile_build(profile)` —
--- and runs each resolved step with an ASYNC streaming spawn (the async form of
--- the CLI's `run_spec`), forwarding stdout/stderr into the workspace task stream
--- so every connected client sees the build live. When each step finishes it
--- writes the result back through the workspace (`record_task_result`), so the
--- built state + cache persist exactly as an editor/CLI build would; the caller
--- emits the durable `model_change` (build_state) on completion.
---
--- **Main-loop discipline.** A daemon command is handled inside a libuv pipe
--- callback (a Neovim *fast event context* when the daemon runs in-process under
--- an editor). The build TASK BUILDERS (`plan_profile_build`) and the cache
--- write-back call `vim.fn.*` (e.g. `mkdir`), which is forbidden in a fast event
--- context. So every step that touches `vim.fn`/`vim.api` — planning, lock
--- acquisition, `record_task_result`, artifact population — is hopped onto the
--- main loop via `on_main`. Under the standalone (luvi) host there is no fast
--- context, but `vim.schedule` is a harmless drained-scheduler defer there.

local M = {}

--- Run `fn` on the main loop (nvim) / drained scheduler (luvi), so
--- `vim.fn`/`vim.api` work never executes in a libuv fast event context.
--- @param fn fun()
local function on_main(fn)
    if vim.schedule then vim.schedule(fn) else fn() end
end

--- The distinct build directories a profile's projects map to (mirrors the CLI's
--- `profile_build_dirs`), for cross-process build-dir locking.
--- @param profile table
--- @return string[]
local function profile_build_dirs(profile)
    local dirs, seen = {}, {}
    for _, pp in ipairs(profile:projects()) do
        local bd = pp.build_dir and pp:build_dir()
        if bd and not seen[bd] then seen[bd] = true; dirs[#dirs + 1] = bd end
    end
    return dirs
end

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
--- under `task_id`, persisting each step's result through the workspace, and
--- calling `on_done(overall_code)` when finished (stopping at the first failing
--- step). Mirrors the CLI's `run_build_steps` (gate → lock → configure → build →
--- record), but async + streaming.
--- @param workspace table the authoritative Workspace
--- @param profile table the resolved Profile
--- @param task_stream loomworks.daemon.TaskStream
--- @param task_id integer|string
--- @param opts? table { extra_args?: string[], force?: boolean }
--- @param on_done fun(code: integer)
function M.run_build(workspace, profile, task_stream, task_id, opts, on_done)
    opts = opts or {}
    -- All vim.fn-touching orchestration runs on the main loop (see header).
    on_main(function()
        -- Build gate: the same check the CLI/editor apply, so an unbuildable
        -- profile (e.g. mapping an abstract configuration) refuses cleanly.
        if profile.assert_buildable then
            local buildable, why = profile:assert_buildable()
            if not buildable then
                task_stream:notify("error", "build", tostring(why), task_id)
                task_stream:done(task_id, 1)
                return on_done(1)
            end
        end

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

        -- Caller args (`-- -j 4`) go to the BUILD tool only (a configure step
        -- would choke on them), matching the CLI.
        if opts.extra_args and #opts.extra_args > 0 then
            for _, s in ipairs(steps) do
                if s.kind == "build" then
                    s.cmd = vim.list_extend(vim.list_extend({}, s.cmd), opts.extra_args)
                end
            end
        end

        -- Cross-process build-dir locks (§16.6): the daemon holds the per-build-
        -- directory advisory lock while it builds, so an editor or a CLI never
        -- builds a directory the daemon is building (and vice-versa). This is
        -- SEPARATE from the daemon's write-authority lock (files vs build dirs).
        local build_lock = require("loomworks.build_lock")
        local held = {}
        local function release_all()
            for _, h in ipairs(held) do build_lock.release(h) end
            held = {}
        end
        for _, bd in ipairs(profile_build_dirs(profile)) do
            local h, err = build_lock.acquire(bd, "build")
            if not h then
                release_all()
                task_stream:notify("error", "build", "cannot build: " .. tostring(err), task_id)
                task_stream:done(task_id, 1)
                return on_done(1)
            end
            held[#held + 1] = h
        end

        task_stream:start(task_id, { name = profile.key, kind = "build", total_steps = #steps })

        local i = 0
        local function finish(code)
            release_all()
            task_stream:done(task_id, code)
            on_done(code)
        end

        local function next_step()
            i = i + 1
            if i > #steps then return finish(0) end
            local step = steps[i]
            task_stream:progress(task_id, (i - 1) / #steps)
            task_stream:output(task_id, "stdout",
                string.format("==> [%s] %s\n", step.kind, step.name or "?"))

            -- Output-artifact conflict gate on a build step (spec §16.28): refuse
            -- a build that would clobber another built profile's shared artifact
            -- unless forced. The preceding configure populated this unit's
            -- artifact set (below), so it is known here.
            if step.kind == "build" and step.unit and workspace.artifact_conflict_block then
                local block = workspace:artifact_conflict_block(step.unit, opts.force or false)
                if block then
                    task_stream:notify("error", "build", string.format(
                        "build would overwrite an artifact owned by built profile '%s': %s"
                        .. " (pass --force to overwrite)", block.profile, block.path or "?"), task_id)
                    return finish(1)
                end
            end

            M.spawn_stream(step.cmd, { cwd = step.cwd or workspace.root, env = step.env }, {
                output = function(stream, text) task_stream:output(task_id, stream, text) end,
                done = function(code)
                    -- Back to the main loop: cache write-back + the next builder
                    -- both touch vim.fn.
                    on_main(function()
                        -- Persist the step result (state + _save_cache), exactly
                        -- as the CLI's record_step does.
                        if step.unit then
                            if step.build_dir then step.unit.build_dir_value = step.build_dir end
                            pcall(function()
                                workspace:record_task_result({
                                    unit = step.unit, action = step.kind, success = (code == 0),
                                })
                            end)
                        end

                        if code ~= 0 then
                            task_stream:notify("error", "build", string.format(
                                "%s failed (exit %d): %s", step.kind, code, step.name or "?"), task_id)
                            return finish(code)
                        end

                        -- After a successful configure, populate this unit's
                        -- resolved artifact set so a following build step's
                        -- conflict check sees it (the CLI does the same).
                        if step.kind == "configure" and step.unit and step.build_dir
                            and workspace._populate_resolved_artifacts then
                            pcall(function()
                                workspace:_populate_resolved_artifacts(
                                    step.unit, step.build_dir, step.unit._variant)
                            end)
                        end

                        task_stream:progress(task_id, i / #steps)
                        next_step()
                    end)
                end,
            })
        end
        next_step()
    end)
end

return M
