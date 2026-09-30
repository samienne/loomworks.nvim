--- loomworks/remote/run.lua — remote execution of a foreign build-target
--- artifact on a device (spec §18.5, §18.8, §18.13).
---
--- Under the device lock (§18.7): open the runner's log session (invalid log
--- options fail here, before any device-side effect) → stage the manifest
--- (§18.4) → clear the log (best-effort) + crash snapshot → execute with live
--- output, the exit status recovered from the runner's nonce-tagged sentinel →
--- pull declared result files and new crash reports into the run folder
--- `<build dir>/.device-runs/<UTC>-<serial>/` (the 10 newest per unit are
--- kept). A lost status is a transport failure, never a program status; a
--- crash fails the run whatever the status. Program output is always saved
--- unfiltered to `output.log`; the runner log stream's kept lines go to
--- `device.log`; what is shown follows the session's show policy.
---
--- Pure orchestration over injectable seams (`o.backend`, `o.write_out`,
--- `o.write_err`, `o.note`, `o.on_cleanup`, `o.liveness_ms`) so the CLI and
--- tests drive identical code.

local spec_exec = require("loomworks.remote.spec_exec")
local transport_mod = require("loomworks.remote.transport")
local devices_mod = require("loomworks.remote.devices")
local manifest_mod = require("loomworks.remote.manifest")
local staging = require("loomworks.remote.staging")

local M = {}

local function uv() return vim.uv or vim.loop end

--- Run folders kept per ConfigUnit (spec §18.5).
M.KEEP_RUNS = 10
--- Device re-list cadence while a program runs (liveness, §18.8).
M.LIVENESS_MS = 15000
--- How long the log stream is drained after the sentinel.
M.LOG_DRAIN_MS = 500
--- Exit code for a transport failure (no status recovered).
M.EXIT_TRANSPORT = 255
--- Exit code for an execution timeout (`--timeout`).
M.EXIT_TIMEOUT = 124

local RUN_DIR_PATTERN = "^%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ%-"

local function basename(p) return (tostring(p):match("([^/]+)$")) or tostring(p) end

-- ---------------------------------------------------------------------------
-- Run folders
-- ---------------------------------------------------------------------------

--- Create a fresh run folder under `<build>/.device-runs/`.
--- @return string|nil dir, string|nil err
function M.make_run_dir(build_dir, serial, now)
    local runs = manifest_mod.canon(build_dir) .. "/" .. manifest_mod.RUNS_DIR
    vim.fn.mkdir(runs, "p")
    local stamp = os.date("!%Y%m%dT%H%M%SZ", now or os.time())
    local base = stamp .. "-" .. manifest_mod.segment(serial)
    local dir = runs .. "/" .. base
    local n = 1
    while uv().fs_stat(dir) do
        n = n + 1
        dir = runs .. "/" .. base .. "-" .. n
    end
    local ok = vim.fn.mkdir(dir, "p")
    if ok == 0 and not uv().fs_stat(dir) then return nil, "cannot create run folder " .. dir end
    return dir
end

--- Keep the `keep` newest run folders of a build directory; remove older ones.
---
--- Deletion safety (CLAUDE.md): the runs directory is the canonical
--- `<canonical build dir>/.device-runs` and must lie strictly inside the
--- canonical build dir (separator boundary); only entries whose NAME matches
--- the run-folder pattern (no separators) are candidates, each re-checked to
--- resolve inside the runs directory; links are removed, never followed
--- (io.rm_rf). A nil / empty build dir deletes nothing.
--- @param build_dir string|nil
--- @param keep? integer
--- @param deps? { rm_rf?: function }
--- @return string[] removed
function M.prune_runs(build_dir, keep, deps)
    keep = keep or M.KEEP_RUNS
    if type(build_dir) ~= "string" or build_dir == "" then return {} end
    local root = manifest_mod.canon(build_dir)
    local runs = root .. "/" .. manifest_mod.RUNS_DIR
    local st = uv().fs_lstat(runs)
    if not st or st.type ~= "directory" then return {} end
    local canon_runs = manifest_mod.canon(runs)
    local function key(p) return package.config:sub(1, 1) == "\\" and p:lower() or p end
    if key(canon_runs) ~= key(runs) or key(canon_runs):sub(1, #root + 1) ~= key(root) .. "/" then
        return {}
    end
    local names = {}
    local h = uv().fs_scandir(canon_runs)
    while h do
        local name = uv().fs_scandir_next(h)
        if not name then break end
        if name:match(RUN_DIR_PATTERN) and not name:find("[/\\]") then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a > b end)
    local rm_rf = (deps and deps.rm_rf) or require("loomworks.io").rm_rf
    local removed = {}
    for i = keep + 1, #names do
        local p = canon_runs .. "/" .. names[i]
        local parent = p:match("^(.*)/[^/]+$")
        if parent and key(parent) == key(canon_runs) then
            local ok = rm_rf(p)
            if ok then removed[#removed + 1] = p end
        end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- Planning
-- ---------------------------------------------------------------------------

--- Merge log options: the launch configuration's `device_log`, then the
--- per-invocation overrides (later wins per key). Values stay opaque.
--- @param launch_opts table|nil
--- @param overrides table|nil
--- @return table
function M.merge_log_options(launch_opts, overrides)
    local out = {}
    for k, v in pairs(type(launch_opts) == "table" and launch_opts or {}) do out[k] = v end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

--- Parse `key=value` (a `--log` value). Returns key, value or nil + err.
function M.parse_log_arg(s)
    local k, v = tostring(s):match("^([^=]+)=(.*)$")
    if not k or k == "" then return nil, "--log expects key=value (got '" .. tostring(s) .. "')" end
    return k, v
end

--- Plan the device-side invocation (no device contact).
--- o: runner, ws_name, unit, manifest, device (effective block), args
--- @return table|nil plan, string|nil err
function M.plan(o)
    local man = o.manifest
    local ws_prefix, root = manifest_mod.device_roots(o.runner.staging_base, o.ws_name, o.unit.id)
    local program = root .. "/" .. man.artifact
    local block = o.device or {}
    local cwd_rel = block.working_dir
    local cwd
    if cwd_rel == nil then
        local d = man.artifact:match("^(.*)/[^/]+$")
        cwd = d and (root .. "/" .. d) or root
    elseif cwd_rel == "." or cwd_rel == "" then
        cwd = root
    elseif manifest_mod.clean_rel(cwd_rel) then
        cwd = root .. "/" .. cwd_rel:gsub("\\", "/")
    else
        return nil, "device.working_dir must be a build-directory-relative path (got '" .. tostring(cwd_rel) .. "')"
    end
    local env = {}
    for k, v in pairs(type(block.env) == "table" and block.env or {}) do env[k] = tostring(v) end
    env = require("loomworks.env_policy").filter(env, { label = "device env" }) or {}
    local libs = {}
    for _, d in ipairs(man.library_rels) do libs[#libs + 1] = d == "" and root or (root .. "/" .. d) end
    table.sort(libs)
    local argv = { program }
    for _, a in ipairs(o.args or {}) do argv[#argv + 1] = a end
    return {
        ws_prefix = ws_prefix, root = root, program = program, name = basename(man.artifact),
        argv = argv, cwd = cwd, env = env, library_dirs = libs,
    }
end

--- Render the `--print` report of a foreign run (spec §16.17 "Command
--- inspection"): the device-side invocation plus the staging manifest.
--- @param plan table
--- @param man loomworks.Manifest
--- @param device { serial?: string, runner: string, error?: string }
--- @param mode "sh"|"json"
--- @return string[] lines
function M.render_print(plan, man, device, mode)
    local files = {}
    for _, f in ipairs(man.files) do files[#files + 1] = { rel = f.rel, kind = f.kind } end
    local archives = {}
    for _, a in ipairs(man.archives) do archives[#archives + 1] = { pattern = a.key, files = #a.members } end
    if mode == "json" then
        return { vim.json.encode({
            device = device.serial, device_error = device.error, runner = device.runner,
            program = plan.program, args = { unpack(plan.argv, 2) }, cwd = plan.cwd,
            library_dirs = plan.library_dirs, env = next(plan.env) and plan.env or vim.empty_dict(),
            staging_root = plan.root,
            manifest = { files = files, archives = archives },
        }) }
    end
    local q = function(s)
        if s:match("^[%w%._/%-=:,+@]+$") then return s end
        return "'" .. s:gsub("'", "'\\''") .. "'"
    end
    local args = {}
    for i = 2, #plan.argv do args[#args + 1] = q(plan.argv[i]) end
    local env = {}
    for k, v in pairs(plan.env) do env[#env + 1] = k .. "=" .. q(v) end
    table.sort(env)
    local lines = {
        "device:       " .. (device.serial or ("(unresolved: " .. tostring(device.error) .. ")"))
            .. "  [runner " .. device.runner .. "]",
        "program:      " .. plan.program,
        "args:         " .. table.concat(args, " "),
        "cwd:          " .. plan.cwd,
        "library_dirs: " .. table.concat(plan.library_dirs, " "),
        "env:          " .. table.concat(env, " "),
        "staging root: " .. plan.root,
        string.format("manifest:     %d file%s, %d archive set%s", #files, #files == 1 and "" or "s",
            #archives, #archives == 1 and "" or "s"),
    }
    for _, f in ipairs(files) do lines[#lines + 1] = "  " .. f.rel .. "  (" .. f.kind .. ")" end
    for _, a in ipairs(archives) do
        lines[#lines + 1] = "  archive " .. a.pattern .. "  (" .. a.files .. " files)"
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

--- @class loomworks.RemoteRunResult
--- @field status integer|nil the program's exit status (sentinel)
--- @field signal integer|nil status - 128 when the status is above 128
--- @field transport_error string|nil the device / transport failure, if any
--- @field timed_out boolean the execution timeout (`--timeout`) elapsed
--- @field crashes string[] local paths of collected crash reports
--- @field results table<string, string> result name → local path (pulled)
--- @field missing_results string[] requested result files that did not come back
--- @field warnings string[]
--- @field run_dir string|nil
--- @field serial string|nil
--- @field failed boolean
--- @field exit_code integer

--- A "gone" leftover is reported only while its record is younger than this
--- (seconds); an older one is dropped silently (§18.7).
M.LEFTOVER_REPORT_AGE = 86400

--- Stop a program an interrupted run left on the device (spec §18.7), through
--- the runner's `reap` (§18.2) — which verifies on the device that the pid is
--- still that program. Never a run failure: an unknown outcome, a failing
--- reap, or a runner without one is a warning on the status channel.
--- @param runner loomworks.Runner
--- @param serial string
--- @param leftover { pid: integer, nonce: string, program: string, started_at: integer|nil }
--- @param o { backend?: table, timeout?: number, note: fun(s: string), now?: integer }
--- @return "stopped"|"gone"|"unknown"|"failed"|"unsupported"
function M.reap_leftover(runner, serial, leftover, o)
    local name = leftover.program:match("([^/]+)$") or leftover.program
    local what = string.format("%s (pid %d)", name, leftover.pid)
    local from = " from an interrupted run on " .. serial
    if not runner.reap then
        o.note("warning: an interrupted run may have left " .. what .. " running on " .. serial
            .. "; this device runner cannot stop it")
        return "unsupported"
    end
    local ok, spec, parse = pcall(runner.reap, serial,
        { pid = leftover.pid, nonce = leftover.nonce, program = leftover.program })
    if not ok or type(spec) ~= "table" or type(parse) ~= "function" then
        o.note("warning: could not stop leftover " .. what .. from .. ": "
            .. tostring(not ok and spec or "device runner reap returned no command"))
        return "failed"
    end
    local job, fail = spec_exec.run(spec, { label = "stop leftover " .. name, timeout = o.timeout,
        backend = o.backend })
    if fail then
        o.note("warning: could not stop leftover " .. what .. from .. ": " .. fail)
        return "failed"
    end
    local pok, outcome = pcall(parse, job.lines)
    if pok and outcome == "stopped" then
        o.note("stopped leftover " .. what .. from)
        return "stopped"
    elseif pok and outcome == "gone" then
        local age = leftover.started_at and ((o.now or os.time()) - leftover.started_at) or nil
        if age and age < M.LEFTOVER_REPORT_AGE then
            o.note("leftover " .. what .. from .. " had already exited")
        end
        return "gone"
    end
    o.note("warning: could not tell whether leftover " .. what .. from .. " was stopped")
    return "unknown"
end

--- Execute a planned remote run.
--- o:
---   ws               workspace (name, _device_sync, _save_cache) — may be a stub
---   runner, sdk      the runner serving the artifact's platform
---   unit             ConfigUnit (id, build_dir)
---   manifest         loomworks.Manifest
---   device           effective device block
---   args             forwarded program arguments
---   serial           explicit device (`--device`)
---   persisted        the profile's persisted serial
---   profile_key      for messages
---   fresh, no_wait, timeout (program seconds), timeouts { query?, transfer? }
---   log_options      merged options map (opaque)
---   results          { name, device_rel }[]: files to pull after the run
---                    (device_rel is relative to the staging root)
---   extra_args_fn    fun(plan) → string[] appended to argv (e.g. results option)
---   backend, liveness_ms, write_out, write_err, note, on_cleanup
--- @param o table
--- @return loomworks.RemoteRunResult|nil result, string|nil err (setup failure: nothing ran)
function M.execute(o)
    local runner = o.runner
    -- stdout is flushed before each stderr line so earlier stdout (a step
    -- header) keeps its place on a shared terminal.
    local note = o.note or function(s) io.stdout:flush(); io.stderr:write("lw: " .. s .. "\n") end
    local write_out = o.write_out or function(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
    local write_err = o.write_err or function(s) io.stdout:flush(); io.stderr:write(s .. "\n") end
    local result = { crashes = {}, results = {}, missing_results = {}, warnings = {},
        timed_out = false, failed = false }

    -- Device selection (§18.3).
    local list, lerr = devices_mod.list(runner, { backend = o.backend, timeouts = o.timeouts })
    if not list then return nil, lerr end
    devices_mod.merge(o.ws, runner.id, list)
    local serial, serr = devices_mod.select(list, { explicit = o.serial, persisted = o.persisted,
        runner_id = runner.id, profile_key = o.profile_key })
    if not serial then return nil, serr end
    result.serial = serial

    local plan, perr = M.plan({ runner = runner, ws_name = o.ws.name or "workspace", unit = o.unit,
        manifest = o.manifest, device = o.device, args = o.args })
    if not plan then return nil, perr end
    if o.extra_args_fn then
        for _, a in ipairs(o.extra_args_fn(plan) or {}) do plan.argv[#plan.argv + 1] = a end
    end

    -- Device lock for the whole run (§18.7).
    local device_lock = require("loomworks.remote.device_lock")
    local lock, lock_err = device_lock.acquire(serial, {
        wait = not o.no_wait, action = "run", workspace = o.ws.name,
        on_wait = function(msg) note(msg) end,
    })
    if not lock then return nil, lock_err end

    local t = transport_mod.new({ runner = runner, serial = serial, backend = o.backend, timeouts = o.timeouts })
    local exec_job, log_job, live_job, live_timer
    local state
    local out_f, dev_f
    local cleaned = false
    local function stop_timer()
        if live_timer then pcall(function() live_timer:stop(); live_timer:close() end); live_timer = nil end
    end
    --- Stop the device-side program. Returns "stopped" (the stop request
    --- completed), "sent" (issued but not awaited, or it failed or outlived
    --- `timeout`) or nil (the runner cannot stop it).
    --- @param timeout? number seconds the stop may take (default 10)
    local function terminate(timeout)
        if runner.terminate and state and plan.nonce then
            local ok, spec = pcall(runner.terminate, serial, plan.nonce, state.pid)
            if ok and spec then
                local job = spec_exec.start(spec, { label = "terminate", timeout = timeout or 10, backend = o.backend })
                -- From a signal handler (a fast libuv callback) nothing may
                -- block: the stop request is sent and the process exits.
                local fast = vim.in_fast_event and vim.in_fast_event()
                if fast then return "sent" end
                local wok = pcall(job.wait, job)
                local failed = not wok or (job.failure and job:failure())
                if not failed then device_lock.clear_program(lock) end
                return failed and "sent" or "stopped"
            end
        end
        return nil
    end
    --- `ctx` is the interrupt context when an interrupt cancels the run
    --- (`stop_timeout` bounds the device stop, e.g. while a Windows console
    --- is closing and the process has only seconds left).
    local function cleanup(cancelled, ctx)
        if cleaned then return end
        cleaned = true
        stop_timer()
        if cancelled and exec_job and not exec_job.done then
            exec_job:kill("cancel")
            local how = terminate(type(ctx) == "table" and tonumber(ctx.stop_timeout) or nil)
            -- Interrupted mid-run (Ctrl-C in the CLI, stop in the editor):
            -- say what happened to the device program, and where the run's
            -- output was saved.
            if out_f then pcall(out_f.flush, out_f) end
            if dev_f then pcall(dev_f.flush, dev_f) end
            if how == "stopped" then
                note("interrupted — stopped " .. plan.name .. " on " .. serial)
            elseif how == "sent" then
                note("interrupted — asked " .. serial .. " to stop " .. plan.name
                    .. " (the stop may not have completed)")
            else
                note("interrupted — the connection to " .. serial .. " was closed; " .. plan.name
                    .. " may still be running there (the stop may not have completed)")
            end
            if result.run_dir then note("run folder: " .. result.run_dir) end
        end
        if log_job and not log_job.done then log_job:kill("cancel") end
        if live_job and not live_job.done then live_job:kill("cancel") end
        device_lock.release(lock)
    end
    if o.on_cleanup then o.on_cleanup(function(ctx) cleanup(true, ctx) end) end

    local function fail_setup(err)
        cleanup(false)
        return nil, err
    end

    -- (1) Log session (§18.13): invalid options fail before any device effect.
    local session
    local log_opts = o.log_options or {}
    if runner.log_session then
        local ok, s, err = pcall(runner.log_session, serial, log_opts, { path = plan.program, name = plan.name })
        if not ok then return fail_setup("device runner log_session failed: " .. tostring(s)) end
        if not s then return fail_setup(tostring(err or "device_log: invalid options")) end
        session = s
    elseif next(log_opts) then
        result.warnings[#result.warnings + 1] = "device runner '" .. runner.id
            .. "' has no log stream; log options ignored"
    end
    local show = session and type(session.show) == "table" and session.show or { program = "live", log = "off" }

    -- A program an interrupted run left on this device (§18.7): reaped
    -- before staging, still holding the new lock.
    if lock.leftover then M.reap_leftover(runner, serial, lock.leftover, { backend = o.backend,
        timeout = t.timeouts.query, note = note }) end

    -- (2) Stage (§18.4).
    o.ws._device_sync = o.ws._device_sync or {}
    local by_serial = o.ws._device_sync[serial] or {}
    local record, report = staging.stage({
        transport = t, manifest = o.manifest, ws_prefix = plan.ws_prefix, root = plan.root,
        record = by_serial[plan.root], fresh = o.fresh,
        tmp_dir = manifest_mod.canon(o.manifest.root) .. "/" .. manifest_mod.RUNS_DIR .. "/.tmp",
    })
    if not record then
        -- The device may be half-staged: forget the record so the next run
        -- re-verifies / re-sends.
        by_serial[plan.root] = nil
        o.ws._device_sync[serial] = next(by_serial) and by_serial or nil
        if o.ws._save_cache then pcall(o.ws._save_cache, o.ws) end
        return fail_setup(report)
    end
    by_serial[plan.root] = record
    o.ws._device_sync[serial] = by_serial
    if o.ws._save_cache then pcall(o.ws._save_cache, o.ws) end
    note(staging.summary(serial, report))

    -- Optional pre-execution step (spec §18.6 framework detection): the
    -- caller may probe the staged program (same cwd / env / loader path) and
    -- remove stale device files, then declare the result files to pull.
    if o.before_exec then
        local function probe(extra)
            local argv = { plan.program }
            for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
            local job, pstate = t:start_exec({ argv = argv, cwd = plan.cwd, env = plan.env,
                library_dirs = plan.library_dirs, nonce = transport_mod.nonce() },
                { label = "probe " .. plan.name }, t.timeouts.query)
            if not job then return nil, pstate end
            job:wait()
            local pf = t:exec_failure(job, pstate)
            if pf then return nil, pf end
            return pstate.status, pstate.output
        end
        local function remove(rels)
            local paths = {}
            for _, rel in ipairs(rels) do
                if not manifest_mod.clean_rel(rel) then return nil, "invalid device path " .. tostring(rel) end
                paths[#paths + 1] = plan.root .. "/" .. rel
            end
            local status, lines = t:shell({ "rm", "-f", unpack(paths) })
            if status == nil then return nil, lines end
            return status == 0
        end
        local function mkdir(rel)
            if not manifest_mod.clean_rel(rel) then return nil, "invalid device path " .. tostring(rel) end
            local status, lines = t:shell({ "mkdir", "-p", plan.root .. "/" .. rel })
            if status == nil then return nil, lines end
            return status == 0
        end
        local ok, results_or_err = pcall(o.before_exec, plan, { probe = probe, remove = remove, mkdir = mkdir })
        if not ok then return fail_setup(tostring(results_or_err)) end
        if type(results_or_err) == "table" then o.results = results_or_err end
    end

    -- Run folder + output files.
    local run_dir, rerr = M.make_run_dir(o.manifest.root, serial)
    if not run_dir then return fail_setup(rerr) end
    result.run_dir = run_dir
    out_f = io.open(run_dir .. "/output.log", "wb")
    local tail, tail_n = {}, (type(show.tail) == "number" and show.tail) or 30

    -- (3) Prepare: log clear (best-effort) + crash snapshot.
    if session and session.clear then
        local _, cfail = spec_exec.run(session.clear, { label = "clear device log", timeout = t.timeouts.query,
            backend = o.backend })
        if cfail then result.warnings[#result.warnings + 1] = cfail end
    end
    local crash_before, crash_parse
    if runner.crash_snapshot then
        local ok, spec, parse = pcall(runner.crash_snapshot, serial)
        if ok and spec and type(parse) == "function" then
            local job, cfail = spec_exec.run(spec, { label = "crash snapshot", timeout = t.timeouts.query,
                backend = o.backend })
            if cfail then
                result.warnings[#result.warnings + 1] = cfail .. " (crash reports not collected)"
            else
                local pok, set = pcall(parse, job.lines)
                if pok and type(set) == "table" then crash_before, crash_parse = set, parse end
            end
        end
    end

    -- Log stream (runs as long as the run).
    local function start_log(pid)
        if not session or log_job then return end
        local ok, spec = pcall(session.stream, pid)
        if not ok or not spec then
            result.warnings[#result.warnings + 1] = "device log stream could not start: " .. tostring(spec)
            return
        end
        dev_f = dev_f or io.open(run_dir .. "/device.log", "wb")
        log_job = spec_exec.start(spec, {
            label = "device log", backend = o.backend,
            on_line = function(_, line)
                local okr, kept = pcall(session.receive, line)
                if not okr or kept == nil then return end
                kept = tostring(kept)
                if dev_f then dev_f:write(kept, "\n") end
                local okd, shown = pcall(session.display, kept)
                if okd and shown ~= nil then
                    if show.log == "live" then write_err(tostring(shown))
                    elseif show.log == "on_failure" then
                        tail[#tail + 1] = tostring(shown)
                        if #tail > tail_n then table.remove(tail, 1) end
                    end
                end
            end,
        })
    end

    -- (4) Execute.
    plan.nonce = transport_mod.nonce()
    local req = { argv = plan.argv, cwd = plan.cwd, env = plan.env, library_dirs = plan.library_dirs,
        nonce = plan.nonce }
    if session and not runner.parse_pid then start_log(nil) end
    if not runner.parse_pid then note("running " .. plan.name .. " on " .. serial) end
    local combined = runner.combined_output
    local err
    exec_job, state = t:start_exec(req, {
        label = "run " .. plan.name .. " on " .. serial,
        on_pid = function(pid)
            -- Recorded so a run that loses its cleanup leaves the next run a
            -- program to reap (§18.7).
            device_lock.set_program(lock, { pid = pid, nonce = plan.nonce, program = plan.program })
            note("running " .. plan.name .. " on " .. serial .. " (pid " .. tostring(pid) .. ")")
            start_log(pid)
        end,
        on_output = function(stream, line)
            if out_f then out_f:write(line, "\n") end
            if show.program ~= "off" then
                if combined or stream == "stdout" then write_out(line) else write_err(line) end
            end
        end,
    }, o.timeout)
    if not exec_job then
        if out_f then out_f:close() end
        return fail_setup(state)
    end

    -- Liveness (§18.8): re-list devices; missing from two consecutive
    -- listings ends the run as a transport failure.
    local misses = 0
    local interval = o.liveness_ms or M.LIVENESS_MS
    live_timer = uv().new_timer()
    live_timer:start(interval, interval, function()
        vim.schedule(function()
            if exec_job.done or (live_job and not live_job.done) then return end
            local ok, spec = pcall(runner.list_devices)
            if not ok then return end
            live_job = spec_exec.start(spec, {
                label = "liveness", timeout = t.timeouts.query, backend = o.backend,
                on_exit = function(j)
                    if exec_job.done then return end
                    local present = false
                    if not j:failure() then
                        local pok, parsed = pcall(runner.parse_devices, j.lines)
                        for _, d in ipairs(pok and parsed or {}) do
                            if d.serial == serial and d.state == "online" then present = true end
                        end
                    end
                    misses = present and 0 or (misses + 1)
                    if misses >= 2 then
                        err = "device " .. serial .. " disappeared during the run (missing from two consecutive listings)"
                        exec_job:kill("transport")
                    end
                end,
            })
        end)
    end)

    exec_job:wait()
    stop_timer()
    -- The program reported its exit: nothing left to reap.
    if state.status ~= nil then device_lock.clear_program(lock) end

    -- (5) Exit status.
    if state.status ~= nil then
        result.status = state.status
        if state.status > 128 then result.signal = state.status - 128 end
    end
    if exec_job.timed_out then
        result.timed_out = true
        result.transport_error = nil
        terminate()
    elseif err then
        result.transport_error = err
        terminate()
    elseif state.status == nil or exec_job.spawn_error or exec_job.killed_reason then
        result.transport_error = t:exec_failure(exec_job, state)
            or ("the connector ended without reporting the program's exit status")
    else
        local cfail = t:exec_failure(exec_job, state)
        if cfail then result.transport_error = cfail end
    end
    -- Drain the log stream briefly, then stop it.
    if log_job and not log_job.done then
        vim.wait(M.LOG_DRAIN_MS, function() return log_job.done end, 20)
        if not log_job.done then log_job:kill("cancel"); log_job:wait() end
    end
    if log_job and log_job.done and not log_job.cancelled then
        local lf = log_job:failure()
        if lf then result.warnings[#result.warnings + 1] = lf end
    end
    if out_f then out_f:close() end
    if dev_f then dev_f:close() end

    -- (6) Collect: result files, then new crash reports.
    local pulled_results = {}
    for _, r in ipairs(o.results or {}) do
        local remote = plan.root .. "/" .. r.device_rel
        local local_path = run_dir .. "/" .. r.name
        local ok = t:pull(remote, local_path)
        if ok then
            result.results[r.name] = local_path
            -- Cleared from the device once pulled (§18.5 step 6); only a clean
            -- staging-root-relative path under the workspace prefix (§18.12).
            if manifest_mod.clean_rel(r.device_rel) and manifest_mod.device_path_under(remote, plan.ws_prefix) then
                pulled_results[#pulled_results + 1] = remote
            end
        else
            result.missing_results[#result.missing_results + 1] = r.name
        end
    end
    if #pulled_results > 0 and not result.transport_error then
        local argv = { "rm", "-f" }
        for _, p in ipairs(pulled_results) do argv[#argv + 1] = p end
        local status, lines = t:shell(argv)
        if status ~= 0 then
            result.warnings[#result.warnings + 1] = "could not clear pulled result files from the device: "
                .. (status == nil and tostring(lines) or table.concat(lines or {}, " "))
        else
            -- Then their now-empty directories (e.g. `.loomworks/results`):
            -- `rmdir` only — it refuses a non-empty directory, so a directory
            -- still holding anything is left alone (not a warning). Each one
            -- must be strictly below the unit's staging root, never the root
            -- itself (§18.12).
            local dirs, seen = {}, {}
            for _, r in ipairs(o.results or {}) do
                local rel = r.device_rel:gsub("\\", "/")
                local drel = rel:match("^(.+)/[^/]+$")
                local dpath = drel and (plan.root .. "/" .. drel)
                if drel and not seen[drel] and manifest_mod.clean_rel(drel)
                    and manifest_mod.device_path_under(dpath, plan.root)
                    and dpath:gsub("/+$", "") ~= plan.root:gsub("/+$", "") then
                    seen[drel] = true
                    dirs[#dirs + 1] = dpath
                end
            end
            if #dirs > 0 then t:shell({ "rmdir", unpack(dirs) }) end
        end
    end
    if crash_before and runner.crash_collect and not result.transport_error then
        local ok, spec = pcall(runner.crash_snapshot, serial)
        if ok and spec then
            local job, cfail = spec_exec.run(spec, { label = "crash snapshot", timeout = t.timeouts.query,
                backend = o.backend })
            if not cfail then
                local pok, after = pcall(crash_parse, job.lines)
                local cok, paths = pcall(runner.crash_collect, crash_before, pok and after or {},
                    { pid = state.pid })
                if cok and type(paths) == "table" then
                    for _, rp in ipairs(paths) do
                        if type(rp) == "string" and not rp:find("[%z\r\n]") then
                            vim.fn.mkdir(run_dir .. "/crash", "p")
                            local lp = run_dir .. "/crash/" .. manifest_mod.segment(basename(rp))
                            local pulled, perr2 = t:pull(rp, lp)
                            if pulled then result.crashes[#result.crashes + 1] = lp
                            else result.warnings[#result.warnings + 1] = perr2 end
                        end
                    end
                end
            else
                result.warnings[#result.warnings + 1] = cfail
            end
        end
    end
    cleanup(false)

    -- (7) Outcome.
    local failed = result.transport_error ~= nil or result.timed_out
        or (result.status ~= nil and result.status ~= 0) or #result.crashes > 0
        or (o.fail_on_missing_results and #result.missing_results > 0)
    result.failed = failed and true or false
    if result.transport_error then
        result.exit_code = M.EXIT_TRANSPORT
    elseif result.timed_out then
        result.exit_code = M.EXIT_TIMEOUT
    elseif result.status ~= 0 then
        result.exit_code = result.status
    elseif result.failed then
        result.exit_code = 1
    else
        result.exit_code = 0
    end
    result.show = show
    result.log_tail = tail
    M.prune_runs(o.manifest.root, M.KEEP_RUNS)
    return result
end

--- Print the post-run summary (spec §18.5 steps 5–7, §18.13 show policy).
--- `extra_failed` marks a failure the caller judged (e.g. failed tests).
--- @param result loomworks.RemoteRunResult
--- @param write fun(s: string) summary writer (stderr)
--- @param extra_failed? boolean
function M.report(result, write, extra_failed)
    local failed = result.failed or extra_failed
    if failed and result.show and result.show.log == "on_failure" and #(result.log_tail or {}) > 0 then
        write("--- device log (last " .. #result.log_tail .. " lines) ---")
        for _, l in ipairs(result.log_tail) do write(l) end
        write("---")
    end
    for _, w in ipairs(result.warnings) do write("lw: warning: " .. w) end
    if result.transport_error then
        write("lw: device/transport failure — no exit status was recovered: " .. result.transport_error)
    elseif result.timed_out then
        write("lw: the program exceeded the execution timeout and was stopped")
    elseif result.signal then
        write(string.format("lw: the program was terminated by signal %d (status %d)", result.signal, result.status))
    elseif result.status and result.status ~= 0 then
        write("lw: the program exited with status " .. result.status)
    end
    for _, c in ipairs(result.crashes) do write("lw: crash report: " .. c) end
    if #result.crashes > 0 and result.status == 0 then
        write("lw: the run fails because the device recorded a crash")
    end
    for _, name in ipairs(result.missing_results) do write("lw: result file did not come back: " .. name) end
    if result.run_dir then
        local extra = false
        local h = uv().fs_scandir(result.run_dir)
        while h do
            local n = uv().fs_scandir_next(h)
            if not n then break end
            if n ~= "output.log" then extra = true end
        end
        if extra or failed then write("lw: run folder: " .. result.run_dir) end
    end
end

return M
