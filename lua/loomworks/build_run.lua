--- loomworks/build_run.lua — the headless profile-build step logic, shared by
--- the in-process `lw build` (cli.lua `run_build_steps`, synchronous) and the
--- daemon's build runner (daemon/runner.lua, asynchronous + streamed).
---
--- There is ONE build path: both runners call these functions in the same order
---
---   lock every build dir → plan (gate + module plan + build request)
---   → per step: before_step (conflict gate, full-reconfigure reset)
---               step_lines (announce, why, log the command line)
---               spawn_spec (hardened argv + env) → run
---               after_step (record result, populate artifacts)
---               failure_message on a nonzero exit
---
--- and differ only in HOW a step is spawned (blocking vs streamed) and how a
--- refusal is reported (die vs a task-stream error). Everything here returns
--- values/errors instead of exiting, so the daemon can stream them; nothing
--- here touches the terminal. Spec §16.4 (build), §5.9/§16.28 (artifact
--- conflicts), §5.1/§8.1 (configure record, full reconfigure), §19.12 (daemon).

local M = {}

--- The distinct build directories a profile's projects map to — the set the
--- per-build-directory advisory lock (§16.6) covers for one build.
--- @param profile loomworks.Profile
--- @return string[]
function M.profile_build_dirs(profile)
    local dirs, seen = {}, {}
    for _, pp in ipairs(profile:projects()) do
        local bd = pp.build_dir and pp:build_dir()
        if bd and not seen[bd] then seen[bd] = true; dirs[#dirs + 1] = bd end
    end
    return dirs
end

--- Whether `cmd` runs a batch file through cmd.exe: the program the build
--- really runs is inside the batch, so arguments appended to this argv never
--- reach it. Recognizes a literal batch path (`cmd /C <x.bat>`) and a program
--- named only by a variable reference cmd.exe expands (`!VAR!` / `%VAR%`) —
--- the cmake vcvarsall wrapper's `cmd /d /v:on /c !LOOMWORKS_VCVARS_BAT!`
--- form. An argv whose real program cmd.exe substitutes cannot be extended
--- safely either way, so it is treated as a batch (refuse, never drop args).
--- @param cmd string[]
--- @return boolean
function M.runs_batch_file(cmd)
    local prog = type(cmd) == "table" and type(cmd[1]) == "string"
        and (cmd[1]:match("([^/\\]+)$") or ""):lower() or ""
    if prog ~= "cmd" and prog ~= "cmd.exe" then return false end
    for i = 2, #cmd do
        local a = tostring(cmd[i]):lower()
        if a:match("%.bat$") or a:match("%.cmd$") then return true end
        if a:match("^!.+!$") or a:match("^%%.+%%$") then return true end
    end
    return false
end

--- The output-artifact conflict refusal (spec §5.9 / §16.28): names the
--- conflicting profile and the shared artifact path, and points at `--force`.
--- @param block { profile: string, path: string|nil }
--- @return string
function M.conflict_message(block)
    return string.format(
        "build would overwrite an artifact owned by built profile '%s':\n"
            .. "      %s\n"
            .. "    pass --force to overwrite it (%s will be marked stale)",
        block.profile, block.path or "?", block.profile)
end

--- The refusal for a profile with no buildable step.
--- @param profile loomworks.Profile
--- @return string
function M.nothing_to_build_message(profile)
    return "nothing to build for profile '" .. profile.key ..
        "' — no buildable projects (unavailable module or unresolved tool?)"
end

--- Plan a profile build: the build gate, the module plan, and the build
--- request (core §8.1 / §16.4) checked for every build step before anything
--- runs. A module that applied the request already put it on its native
--- command; for one that did not, `--target` is refused (no generic way to
--- select a target) and forwarded args are appended to the step's command —
--- unless that command runs a batch file, where they would be silently
--- ignored, so it is refused instead.
--- @param profile loomworks.Profile
--- @param opts? { for_test?: boolean, reconfigure?: boolean, extra_args?: string[], build_targets?: string[] }
--- @return table[]|nil steps (possibly empty), string|nil err
function M.plan(profile, opts)
    opts = opts or {}
    -- Same gate the editor applies in `Profile:build` / `Profile:configure`:
    -- without it an unbuildable profile — e.g. one mapping an abstract
    -- configuration — would build anyway, on whatever default the module picked.
    if profile.assert_buildable then
        local buildable, why = profile:assert_buildable()
        if not buildable then return nil, tostring(why) end
    end
    local steps, plan_err = require("loomworks.overseer").plan_profile_build(profile, {
        for_test = opts.for_test,
        reconfigure = opts.reconfigure,
        build_args = opts.extra_args,
        build_targets = opts.build_targets,
    })
    if plan_err then return nil, "cannot build: " .. tostring(plan_err) end
    steps = steps or {}
    for _, step in ipairs(steps) do
        if step.kind == "build" then
            if opts.build_targets and not step.applied_build_targets then
                return nil, string.format("%s: this project's module does not support --target "
                    .. "(pass the build tool's own target syntax after `--` instead)", step.name or "?")
            end
            if opts.extra_args and not step.applied_build_args then
                if M.runs_batch_file(step.cmd) then
                    return nil, string.format("%s: cannot forward build-tool args — the module runs "
                        .. "its build through a batch file and does not accept build args", step.name or "?")
                end
                step.cmd = vim.list_extend(vim.list_extend({}, step.cmd), opts.extra_args)
            end
        end
    end
    return steps
end

--- The gates evaluated immediately before a step runs:
---   * the output-artifact conflict gate (§5.9 / §16.28), directional and
---     evaluated at compile-start — for a configure→build chain the configure
---     (after_step) already populated this unit's artifact set. `force` is the
---     only bypass, never a prompt;
---   * a full reconfigure's module-named configure-state reset (core §5.1 /
---     §8.1 `pre_configure_reset`) — validated + deleted by core, under the
---     build-dir lock the runner already holds.
--- @param ws loomworks.Workspace
--- @param step table
--- @param opts? { force?: boolean }
--- @return boolean|nil ok, string|nil err
function M.before_step(ws, step, opts)
    opts = opts or {}
    if step.kind == "build" and step.unit and ws.artifact_conflict_block then
        local block = ws:artifact_conflict_block(step.unit, opts.force or false)
        if block then return nil, M.conflict_message(block) end
    end
    if step.kind == "configure" and type(step.pre_configure_reset) == "table"
            and #step.pre_configure_reset > 0 then
        local ok_r, r_err = ws:_pre_configure_reset(step.build_dir, step.pre_configure_reset)
        if not ok_r then return nil, tostring(r_err) end
    end
    return true
end

--- The status lines announcing a step (§16.4): `==> [kind] name`, WHY a
--- configure runs (the gate's reason + the module's full / in-place choice),
--- and with `verbose` the command line + cwd. Also writes the command line to
--- the workspace log (always, §16.4).
--- @param ws loomworks.Workspace
--- @param step table
--- @param opts? { verbose?: boolean }
--- @return string[] lines (no trailing newlines)
function M.step_lines(ws, step, opts)
    opts = opts or {}
    local overseer = require("loomworks.overseer")
    local lines = { string.format("==> [%s] %s", step.kind, step.name or "?") }
    if step.kind == "configure" then
        local why = overseer.configure_reason_line(step)
        if why then lines[#lines + 1] = "    " .. why end
    end
    local cwd = step.cwd or ws.root
    overseer.log_task_command(ws, step.name, step, cwd)
    if opts.verbose then
        lines[#lines + 1] = "    $ " .. overseer.command_text(step)
        lines[#lines + 1] = "    (in " .. tostring(cwd) .. ")"
    end
    return lines
end

--- The spawnable form of a step: the program resolved to an absolute path
--- (never the cwd / a relative PATH entry) and, on Windows,
--- NoDefaultCurrentDirectoryInExePath=1 in the child env (spec §17). An
--- unresolvable program is reported, never spawned by name. An empty env is
--- dropped (it would wipe PATH; the child inherits the parent env instead).
--- @param step table { cmd, cwd?, env? }
--- @param root string the workspace root (default cwd)
--- @return { cmd: string[], cwd: string, env: table|nil }|nil spec, string|nil err
function M.spawn_spec(step, root)
    local hardened, herr = require("loomworks.exe").harden_spec({ cmd = step.cmd, env = step.env })
    if not hardened then return nil, "cannot run step: " .. tostring(herr) end
    local env = (hardened.env and next(hardened.env)) and hardened.env or nil
    return { cmd = hardened.cmd, cwd = step.cwd or root, env = env }
end

--- Persist a headless step's outcome (state + config snapshot for staleness)
--- to the cache via Workspace:record_task_result, so a later invocation skips
--- an already-done, unchanged configure. build_dir is set on the unit but not
--- passed as result.build_dir (that triggers the post-configure parse_targets
--- scan the headless runners opt out of).
--- @param ws loomworks.Workspace
--- @param step table
--- @param ok boolean
function M.record(ws, step, ok)
    if not step.unit then return end
    if step.build_dir then step.unit.build_dir_value = step.build_dir end
    pcall(function()
        -- Pass the module's configure record (cache_launcher, passed_options, …)
        -- exactly like the editor's task path, so launcher staleness and the
        -- faithful-reconfigure retraction (core §5.1) work for headless
        -- configures too.
        ws:record_task_result({
            unit = step.unit, action = step.kind, success = ok,
            module_info = step.module_info,
            -- The profile being built: the snapshot is taken in its context.
            profile = step.profile,
        })
    end)
end

--- After a step exits: record its result, and after a successful configure
--- populate this unit's resolved artifact set so a following build step in
--- THIS run sees it (the headless runners opt out of the record_task_result
--- post-configure scan by not passing build_dir).
--- @param ws loomworks.Workspace
--- @param step table
--- @param code integer
function M.after_step(ws, step, code)
    M.record(ws, step, code == 0)
    if step.kind == "configure" and code == 0 and step.unit and step.build_dir
            and ws._populate_resolved_artifacts then
        pcall(function()
            ws:_populate_resolved_artifacts(step.unit, step.build_dir, step.unit._variant)
        end)
    end
end

--- The failure line for a step that exited nonzero. A build that fails after
--- the post-configure scan predicted it (an error-severity cache-compat
--- finding, e.g. /Zi under sccache) closes with one line pointing back at that
--- finding — advisory: the scan never gates the build (§5.1). `extra_hint`
--- (e.g. an unknown `--target`) leads the hint lines.
--- @param step table
--- @param code integer
--- @param extra_hint? string
--- @return string
function M.failure_message(step, code, extra_hint)
    local hint
    if step.kind == "build" and step.unit and step.unit.module_info then
        hint = require("loomworks.compiler_cache").compat_failure_hint(
            step.unit.module_info.cache_compat)
    end
    if extra_hint then hint = hint and (extra_hint .. "\nlw: " .. hint) or extra_hint end
    return string.format("%s failed (exit %d): %s", step.kind, code, step.name or "?")
        .. (hint and ("\nlw: " .. hint) or "")
end

return M
