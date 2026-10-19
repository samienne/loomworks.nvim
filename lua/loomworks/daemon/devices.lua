--- loomworks/daemon/devices.lua — `loomworks.Devices/1` on `/devices`, the
--- workspace's devices in the workspace daemon (spec §19.16 "Devices",
--- §19.18, §19.20; API.md §15; step 5n part B2):
---
---   list {}          the registry (Workspace:devices) as it is: never loads,
---                    never probes; an unloaded workspace has none
---   scan {} T        each module that has devices lists them
---                    (Workspace:scan_devices) in the caller's environment
---                    (§19.15 "Environment": started inside its model
---                    segment), the registry updated in a model segment
---   install {…} T    the module's install command of a device target
---                    (LaunchTarget:device_install_command) on its
---                    profile's device
---   launch {…} T     its launch command (LaunchTarget:device_launch_command),
---                    then the program's pid (LaunchTarget:device_resolve_pid);
---                    `done.result` carries `{ pid?, bundle? }`
---   stop { task }    its stop command (LaunchTarget:device_stop_command) for
---                    the program a finished `launch` task of the caller
---                    launched
---   changed          the registry's records differ from the last ones
---                    signalled (`check`, at the header check: after every
---                    model segment and committed write)
---
--- install / launch address their target as `prepare_run` does (`{ profile?,
--- project?, target?, kind? }`, API.md §9.1): the profile resolved before
--- the task is accepted (a refusal is the `refused` result); the target, its
--- being a device target, the profile's device and the module's command
--- inside the task (a failure ends it nonzero, as `Launch/1.build`'s).
---
--- Tasks: each is OWNED by the calling connection (§19.15) — a run in
--- `Service.runs`, cancelled by `Tasks/1.cancel` or by its owner's
--- disconnect; a cancel kills the running command's process tree. Every
--- command is spawned with exactly the caller's environment plus the
--- module command's own variables, its output streamed on the task.
---
--- Locks (§19.3, order R → O → B → D → F): an install holds the device
--- target's build-directory lock (B, fail-fast: a build of that directory
--- refuses the install rather than installing a half-written artifact) and
--- then the device lock (D, §18.7: waits — on a timer, so the endpoint keeps
--- serving — for a live holder, printing it once; a hung holder fails); a
--- launch and a stop take only D. Each is held for the command only.
---
--- No deletion: runner devices (§18), `lw device clean` and `lw run
--- --device` stay out of step 5n.

local envelope = require("loomworks.proto.envelope")
local envscope = require("loomworks.daemon.envscope")
local tasks_mod = require("loomworks.daemon.tasks")

local M = {}

local uv = vim.uv or vim.loop

M.WHERE = { path = "/devices", iface = "loomworks.Devices", v = 1 }

--- A scan whose modules have not all answered by then fails.
M.SCAN_TIMEOUT_MS = 60 * 1000
--- How often a command waiting for its device lock tries again.
M.LOCK_POLL_MS = 500
--- A pid probe's own timeout (as LaunchTarget:device_resolve_pid asks).
M.PROBE_TIMEOUT_MS = 3000

-- ---------------------------------------------------------------------------
-- The registry's records
-- ---------------------------------------------------------------------------

--- @class loomworks.DeviceRecord
--- @field id string the daemon's opaque id
--- @field key string the serial
--- @field label string the name (the serial when it has none)
--- @field state string `online` or `offline`
--- @field provider string the module that found it
--- @field profiles? string[] the keys of the profiles that chose it

--- The registry as `list` answers it, by serial.
--- @param ws table|nil the loaded workspace (nil: unloaded)
--- @param ids loomworks.daemon.IdRegistry
--- @return loomworks.DeviceRecord[]
function M.records(ws, ids)
    if not ws or not ws.devices then return {} end
    local chose = {}
    for _, p in pairs(ws._profiles or {}) do
        local serial = not p._removed and p.device_serial and p:device_serial() or nil
        if serial then
            chose[serial] = chose[serial] or {}
            table.insert(chose[serial], p.key)
        end
    end
    local out = {}
    for _, d in ipairs(ws:devices()) do
        local profiles = chose[d.serial]
        if profiles then table.sort(profiles) end
        out[#out + 1] = { id = ids:id(d), key = d.serial, label = d.display_name or d.serial,
            state = d.state or "online", provider = d.provider, profiles = profiles }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- Signal `changed` when the records differ from the last ones seen (the
--- first call only records them). Runs at the header check.
--- @param service loomworks.daemon.BuildService
function M.check(service)
    local ws = service.header_model and service:header_model() or nil
    local sig = vim.json.encode(M.records(ws, service.ids))
    local last = service._devices_sig
    service._devices_sig = sig
    local reg = service.server and service.server.interfaces
    if reg and last ~= nil and last ~= sig then
        service._devices_seq = (service._devices_seq or 0) + 1
        reg:emit(M.WHERE.path, M.WHERE.iface, M.WHERE.v, "changed", { seq = service._devices_seq })
    end
end

-- ---------------------------------------------------------------------------
-- Commands: spawned in the caller's environment
-- ---------------------------------------------------------------------------

--- Spawn `argv` (argv[1] resolved on the caller's PATH) in the caller's
--- environment plus `o.env`; `o.output(stream, text)` gets its output, and
--- `done(code, stdout, stderr)` (on the main loop, outside any segment) its
--- end. `o.timeout` kills it after that many ms. While it runs it is the
--- run's `child` (a cancel kills its process tree).
--- @param ctx table the request (its `env`)
--- @param run table
--- @param argv string[]
--- @param o { cwd?: string, env?: table, output?: fun(stream: string, text: string), timeout?: integer }
--- @param done fun(code: integer, stdout: string, stderr: string)
local function spawn(ctx, run, argv, o, done)
    local runner = require("loomworks.daemon.runner")
    local spec, herr = require("loomworks.exe").harden_spec({ cmd = vim.deepcopy(argv), cwd = o.cwd,
        env = envscope.with_overlay(ctx.env, o.env) })
    if not spec then
        vim.schedule(function() done(127, "", tostring(herr)) end)
        return
    end
    local out, err, t = {}, {}, nil
    local child = {}
    child.obj = runner.spawn(spec, {
        output = function(stream, text)
            if stream == "stdout" then out[#out + 1] = text else err[#err + 1] = text end
            if o.output then o.output(stream, text) end
        end,
        done = function(code)
            if t then pcall(function() t:stop(); t:close() end); t = nil end
            if run.child == child then run.child = nil end
            done(code, table.concat(out), table.concat(err))
        end,
    })
    if child.obj then
        child.pid = child.obj.pid
        if child.pid then child.start = require("loomworks.proc").start_time(child.pid) end
        run.child = child
        if type(o.timeout) == "number" and o.timeout > 0 then
            t = uv.new_timer()
            t:start(o.timeout, 0, function() vim.schedule(function() runner.kill(child) end) end)
        end
    end
end

--- The lines of a command's output (stdout then stderr), for its module's
--- `check_output`.
--- @param stdout string
--- @param stderr string
--- @return string[]
local function lines_of(stdout, stderr)
    local lines = {}
    for _, s in ipairs({ stdout, stderr }) do
        for line in (s or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    end
    return lines
end

--- Run a module's device command (loomworks.DeviceCommand), its output on
--- the task (`task` nil: collected only); `k(nil)` on success, `k(err)` on a
--- nonzero exit or a `check_output` failure — in a model segment of `ctx`.
--- Nothing is called once the run finished or was cancelled (the cancel
--- ends it).
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @param run table
--- @param command loomworks.DeviceCommand
--- @param task loomworks.daemon.Task|nil
--- @param k fun(err: string|nil)
local function run_command(service, ctx, run, command, task, k)
    local argv = { command.cmd }
    for _, a in ipairs(command.args or {}) do argv[#argv + 1] = a end
    spawn(ctx, run, argv, { cwd = command.cwd, env = command.env,
        output = task and function(stream, text) task:output(stream, text) end or nil },
        function(code, stdout, stderr)
            service:with_model(ctx, function()
                if run.finished then return end
                if run.cancelled then return run.finish(run.cancel_code, run.stopped()) end
                if code ~= 0 then
                    if not task and stderr ~= "" then
                        return k(command.name .. " failed (exit " .. code .. "): " .. vim.trim(stderr))
                    end
                    return k(command.name .. " failed (exit " .. code .. ")")
                end
                if command.check_output then
                    local ok, cerr = pcall(command.check_output, lines_of(stdout, stderr))
                    if not ok then return k(command.name .. ": " .. tostring(cerr)) end
                    if type(cerr) == "string" then return k(command.name .. ": " .. cerr) end
                end
                k(nil)
            end)
        end)
end

--- The pid probes' spawner (LaunchTarget:device_resolve_pid `opts.system`):
--- `exe.system`'s shape, in the caller's environment, killed on a cancel
--- (whose exit then finishes the run).
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @param run table
--- @return fun(cmd: string[], opts: table, on_exit: fun(res: table))
local function probe_system(service, ctx, run)
    return function(cmd, so, on_exit)
        so = so or {}
        if run.cancelled or run.finished then
            vim.schedule(function() on_exit({ code = 127, signal = 0, stdout = "", stderr = "stopped" }) end)
            return
        end
        spawn(ctx, run, cmd, { cwd = so.cwd, env = so.env, timeout = so.timeout or M.PROBE_TIMEOUT_MS },
            function(code, stdout, stderr)
                -- A cancel killed the probe: the run ends now, not after
                -- the probe's retries.
                if run.cancelled and not run.finished then
                    service:with_model(ctx, function()
                        if not run.finished then run.finish(run.cancel_code, run.stopped()) end
                    end)
                end
                on_exit({ code = code, signal = 0, stdout = stdout, stderr = stderr })
            end)
    end
end

-- ---------------------------------------------------------------------------
-- Locks
-- ---------------------------------------------------------------------------

--- Take the build-directory lock of `bd` (B, fail-fast; a dead holder's
--- state recovered as for a build). Returns true, or false + the refusal.
--- @param ctx table
--- @param run table
--- @param bd string
--- @return boolean, string|nil
local function take_build_lock(ctx, run, bd)
    local build_lock = require("loomworks.build_lock")
    local lock_break = require("loomworks.lock_break")
    local ws = ctx.ws
    local shown = ws._display_build_dir and ws:_display_build_dir(bd) or bd
    local lctx = { what = shown, command = ctx.command, unlock = shown }
    local h, msg = lock_break.acquire(function()
        local hh, _, info = build_lock.acquire(bd, run.op, lctx)
        return hh, info
    end, lctx)
    if not h then return false, msg end
    run.held[#run.held + 1] = h
    if h.reclaimed and ws._recover_interrupted_build_dir then
        local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
        if line then ctx.task:line("err", "lw: " .. line, "plain") end
    end
    return true
end

--- Take the device lock of `serial` (D): waits for a live holder — trying
--- again every LOCK_POLL_MS in a model segment, the holder announced once
--- on the task — and fails for a hung one. `k(nil)` once held, `k(err)` on
--- a failure (in a model segment); nothing once the run finished, and a
--- cancel while waiting ends the run.
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @param run table
--- @param serial string
--- @param k fun(err: string|nil)
local function take_device_lock(service, ctx, run, serial, k)
    local device_lock = require("loomworks.remote.device_lock")
    local state, announced = {}, false
    local try
    try = function()
        if run.finished then return end
        if run.cancelled then return run.finish(run.cancel_code, run.stopped()) end
        local h, err, held = device_lock.try_acquire(serial, { action = run.op, workspace = ctx.ws.root,
            command = ctx.command }, state)
        if h then
            run.device_lock = h
            return k(nil)
        end
        if err then return k(err) end
        if not announced then
            announced = true
            if ctx.task then ctx.task:line("note", held .. " — waiting for it", "plain") end
        end
        run.timer(M.LOCK_POLL_MS, function() service:with_model(ctx, try) end)
    end
    try()
end

-- ---------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------

--- A device task's run: `finish(code, err, result?)` (idempotent) releases
--- its locks and timers and ends the task; `cancel(reason, code)` kills the
--- running command (whose end then finishes the run) or finishes it at once.
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @param op "scan"|"install"|"launch"
--- @return table run
local function new_run(service, ctx, op)
    local run = { task = ctx.task, op = op, cancelled = false, held = {}, timers = {}, ctx = ctx }
    ctx.run = run
    function run.timer(ms, fn)
        local t = uv.new_timer()
        run.timers[t] = true
        t:start(ms, 0, function()
            vim.schedule(function()
                if not run.timers[t] then return end
                run.timers[t] = nil
                pcall(function() t:close() end)
                fn()
            end)
        end)
    end
    function run.release_all()
        for t in pairs(run.timers) do pcall(function() t:stop(); t:close() end) end
        run.timers = {}
        local build_lock = require("loomworks.build_lock")
        for _, h in ipairs(run.held) do build_lock.release(h) end
        run.held = {}
        if run.device_lock then
            require("loomworks.remote.device_lock").release(run.device_lock)
            run.device_lock = nil
        end
    end
    function run.stopped(why)
        return op .. " stopped: " .. tostring(why or run.cancel_reason)
    end
    function run.finish(code, err, result)
        if run.finished then return end
        run.finished = true
        run.release_all()
        run.task:done(code, err, result and { result = result } or nil)
        if service.on_run_done then service:on_run_done(run) end
    end
    function run.cancel(reason, code)
        if run.cancelled or run.finished then return end
        run.cancelled = true
        run.cancel_reason = reason or "cancelled"
        run.cancel_code = code or 1
        if run.child then
            -- Its exit (any code) then finishes the run.
            require("loomworks.daemon.runner").kill(run.child)
        else
            service:with_model(ctx, function() run.finish(run.cancel_code, run.stopped()) end)
        end
    end
    return run
end

--- Is the run's workspace (and profile) still the live one? false + why.
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @return boolean, string|nil
local function current(service, ctx)
    if service.ws ~= ctx.ws then return false, "the workspace was unloaded (refused or reloaded .nvim files)" end
    if ctx.profile and ctx.profile._removed then return false, "profile '" .. ctx.profile.key .. "' was removed" end
    return true
end

--- Run an accepted scan (see the header).
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @return table run
local function run_scan(service, ctx)
    local run = new_run(service, ctx, "scan")
    local task, ws = ctx.task, ctx.ws
    task:start({ name = "devices", kind = "scan" })
    if not ws:has_device_modules() then
        task:line("out", "no module of this workspace lists devices", "plain")
        run.finish(0, nil, { devices = #ws:devices() })
        return run
    end
    run.timer(M.SCAN_TIMEOUT_MS, function()
        service:with_model(ctx, function()
            run.finish(1, string.format("device scan timed out (no answer after %d s)",
                math.floor(M.SCAN_TIMEOUT_MS / 1000 + 0.5)))
        end)
    end)
    ws:scan_devices(function(devices)
        if run.finished then return end
        local okc, why = current(service, ctx)
        if not okc then return run.finish(1, run.stopped(why)) end
        local online = 0
        for _, d in ipairs(devices) do if d:is_online() then online = online + 1 end end
        task:line("out", string.format("SCAN OK: %d %s (%d online)", #devices,
            #devices == 1 and "device" or "devices", online), "ok")
        run.finish(0, nil, { devices = #devices })
    end, {
        resume = function(fn) service:with_model(ctx, fn) end,
        cancelled = function() return run.cancelled or run.finished end,
    })
    return run
end

--- The device target of an install / launch and its profile's device, or
--- nil + the failure line.
--- @param ctx table
--- @return table|nil lt, string serial_or_err
local function device_target(ctx)
    local rp = require("loomworks.run_prep")
    local a, profile = ctx.a, ctx.profile
    local lt, serr = rp.select(ctx.ws, profile, a.target, a.project, a.kind)
    if not lt then return nil, serr end
    local verr = rp.validity_error(lt)
    if verr then return nil, verr end
    if not lt:requires_device() then
        return nil, "'" .. lt:display_name() .. "' is not a device target"
    end
    local serial = profile:device_serial()
    if not serial then
        return nil, "profile '" .. profile.key .. "' has no device — choose one first (Profiles/1.set_device)"
    end
    return lt, serial
end

--- Run an accepted install or launch (see the header).
--- @param service loomworks.daemon.BuildService
--- @param ctx table
--- @param op "install"|"launch"
--- @return table run
local function run_device_op(service, ctx, op)
    local run = new_run(service, ctx, op)
    local task, profile = ctx.task, ctx.profile
    local lt, serial = device_target(ctx)
    task:start({ name = lt and (lt:display_name() .. " on " .. serial) or profile.key, kind = op,
        profile = profile.key })
    if not lt then
        run.finish(1, serial)
        return run
    end
    local command, info
    if op == "install" then
        command, info = lt:device_install_command(serial)
    else
        command, info = lt:device_launch_command(serial)
    end
    if not command then
        run.finish(1, tostring(info))
        return run
    end
    -- B, then D (§19.3): the artifact's build directory, then the device.
    if op == "install" then
        local unit = lt._config_unit
        local bd = unit and unit.build_dir and unit:build_dir() or nil
        if bd then
            local lok, lmsg = take_build_lock(ctx, run, bd)
            if not lok then
                run.finish(1, lmsg)
                return run
            end
        end
    end
    local function step_failed(err) return run.finish(1, err) end
    take_device_lock(service, ctx, run, serial, function(lerr)
        if lerr then return step_failed(lerr) end
        local okc, why = current(service, ctx)
        if not okc then return run.finish(1, run.stopped(why)) end
        task:line("out", (op == "install" and "installing " or "launching ") .. lt:display_name()
            .. " on " .. serial, "phase")
        run_command(service, ctx, run, command, task, function(cerr)
            run.release_all()
            if cerr then return step_failed(cerr) end
            if op == "install" then
                task:line("out", "INSTALL OK: " .. lt:display_name() .. " on " .. serial, "ok")
                return run.finish(0)
            end
            local bundle = type(info) == "table" and info.bundle_name or nil
            local function launched(pid)
                if run.finished then return end
                if run.cancelled then return run.finish(run.cancel_code, run.stopped()) end
                -- The program a `stop` of this task stops (§15 `stop`).
                M.launches(service)[task.id] = { owner = ctx.conn, serial = serial, bundle = bundle,
                    profile = profile.key, target = ctx.a.target, project = ctx.a.project, kind = ctx.a.kind }
                task:line("out", "LAUNCH OK: " .. lt:display_name() .. " on " .. serial
                    .. (pid and (" (pid " .. pid .. ")") or ""), "ok")
                run.finish(0, nil, { pid = pid, bundle = bundle })
            end
            if not bundle then return launched(nil) end
            lt:device_resolve_pid(serial, bundle, { system = probe_system(service, ctx, run) })
                :next(function(pid) service:with_model(ctx, function() launched(pid) end) end)
                :catch(function() service:with_model(ctx, function() launched(nil) end) end)
        end)
    end)
    return run
end

-- ---------------------------------------------------------------------------
-- Launches a `stop` addresses
-- ---------------------------------------------------------------------------

--- The device launches of this daemon session, by task id: `{ owner,
--- serial, bundle?, profile, target?, project?, kind? }`, kept until stopped
--- or their owner disconnects.
--- @param service loomworks.daemon.BuildService
--- @return table<string, table>
function M.launches(service)
    service._device_launches = service._device_launches or {}
    return service._device_launches
end

--- The owner disconnected: its launches can no longer be stopped through
--- the daemon (its programs keep running, as a program the client started).
--- @param service loomworks.daemon.BuildService
--- @param conn table
function M.on_conn_closed(service, conn)
    for id, l in pairs(M.launches(service)) do
        if l.owner == conn then M.launches(service)[id] = nil end
    end
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

--- A task method's handler: declined while the environment is malformed or
--- the daemon stops or retires; otherwise `accept` in a model segment.
--- @param service loomworks.daemon.BuildService
--- @param op "scan"|"install"|"launch"
--- @param run_fn fun(service: table, ctx: table): table
--- @return function
local function task_method(service, op, run_fn)
    local interfaces = require("loomworks.daemon.interfaces")
    local core_ifaces = require("loomworks.daemon.core_interfaces")
    local build_run = require("loomworks.build_run")
    local function accept(ctx)
        if ctx.conn.closed then return end
        local function refused(msg)
            return ctx.reply({ outcome = "refused", message = msg, exit_code = 1,
                notes = ctx.notes, note_roles = ctx.note_roles })
        end
        local ws, refusal, decline = service:live(ctx)
        if not ws then
            if decline then return ctx.reply({ outcome = "declined", reason = decline }) end
            return refused(refusal)
        end
        if ctx.refused then return refused(ctx.refused) end
        if op ~= "scan" then
            local a = core_ifaces.operation_args(ctx.args)
            local stale = service:_resolve_ids(ws, a)
            if stale then return refused(stale) end
            local profile, err, action = build_run.resolve_target(ws, a.profile,
                { interactive = false, usage = "lw run <profile> <target>" })
            if action == "onboard" then
                return ctx.reply({ outcome = "declined", reason = "no profile yet (interactive onboarding)" })
            end
            if not profile then return refused(err) end
            ctx.a, ctx.profile = a, profile
        end
        local task = service.tasks:create(ctx.conn)
        task.call = ctx.call
        ctx.task, ctx.ws = task, ws
        ctx.reply({ outcome = "accepted", task_id = tasks_mod.wire_id(task, ctx.conn),
            profile_key = ctx.profile and ctx.profile.key or nil, pid = service.server.pid,
            notes = ctx.notes, note_roles = ctx.note_roles })
        local run = run_fn(service, ctx)
        service.server:log("device %s (task %s) accepted", op, task.id)
        if run and not run.finished then service.runs[run] = true end
    end
    return function(cctx, args)
        local srv = service.server
        local env, eerr = envscope.validate(cctx.env)
        local ctx = { op = op, conn = cctx.conn, env = env, args = args or {}, command = "lw run",
            call = core_ifaces.task_call(cctx.registry, M.WHERE, op) }
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
            service:with_model(ctx, function() accept(ctx) end)
        end
        return interfaces.ASYNC
    end
end

--- `stop { task }` (see the header): the stop command of a launch the
--- caller owns, run in its environment under the device lock; `ok` once it
--- succeeded (the launch is then forgotten), else `refused`. Another
--- client's launch is `forbidden`.
--- @param service loomworks.daemon.BuildService
--- @return function
local function stop_method(service)
    local interfaces = require("loomworks.daemon.interfaces")
    return function(cctx, args)
        local id = args.task
        local l = M.launches(service)[id]
        if not l then
            local t = service.tasks.tasks[id]
            if t and not t.finished then
                return { outcome = "refused", exit_code = 1, message = "task " .. tostring(id)
                    .. " is still running — cancel it instead (Tasks/1.cancel)" }
            end
            return { outcome = "refused", exit_code = 1, message = "no program launched by task " .. tostring(id) }
        end
        if l.owner ~= cctx.conn then
            return nil, envelope.err(envelope.ERR.forbidden,
                string.format("task %s belongs to another client", tostring(id)))
        end
        local env, eerr = envscope.validate(cctx.env)
        if not env then return { outcome = "declined", reason = eerr } end
        if service.stopping or service.server.stopped then
            return { outcome = "declined", reason = "the workspace runtime is stopping" }
        end
        local ctx = { op = "stop", conn = cctx.conn, env = env, args = {}, command = "lw run" }
        function ctx.reply(fields)
            ctx.replied = true
            service:_before_ack(ctx)
            return cctx.reply(fields)
        end
        -- A run without a task (nothing is streamed); its locks and child
        -- are a run's, so a stop the daemon's shutdown interrupts releases them.
        -- (`ctx.run`: its later segments run even while the daemon stops,
        -- so the device lock is released.)
        local run = { op = "stop", held = {}, timers = {}, cancelled = false }
        ctx.run = run
        local function answer(fields)
            if run.finished then return end
            run.finished = true
            for t in pairs(run.timers) do pcall(function() t:stop(); t:close() end) end
            if run.device_lock then require("loomworks.remote.device_lock").release(run.device_lock) end
            ctx.reply(fields)
        end
        function run.finish(_, err) answer({ outcome = "refused", exit_code = 1, message = tostring(err) }) end
        function run.stopped() return "stop interrupted" end
        function run.timer(ms, fn)
            local t = uv.new_timer()
            run.timers[t] = true
            t:start(ms, 0, function()
                vim.schedule(function()
                    if not run.timers[t] then return end
                    run.timers[t] = nil
                    pcall(function() t:close() end)
                    fn()
                end)
            end)
        end
        service:with_model(ctx, function()
            if ctx.conn.closed then return end
            if service.stopping or service.server.stopped then
                return answer({ outcome = "declined", reason = "the workspace runtime is stopping" })
            end
            local ws, refusal, decline = service:live(ctx)
            if not ws then
                if decline then return answer({ outcome = "declined", reason = decline }) end
                return answer({ outcome = "refused", exit_code = 1, message = refusal })
            end
            ctx.ws = ws
            local profile
            for _, p in pairs(ws._profiles or {}) do
                if not p._removed and p.key == l.profile then profile = p end
            end
            if not profile then return run.finish(1, "profile '" .. l.profile .. "' was removed") end
            local lt, serr = require("loomworks.run_prep").select(ws, profile, l.target, l.project, l.kind)
            if not lt then return run.finish(1, serr) end
            local command = lt:device_stop_command(l.serial, l.bundle)
            if not command then
                M.launches(service)[id] = nil
                return answer({ outcome = "ok" })
            end
            take_device_lock(service, ctx, run, l.serial, function(lerr)
                if lerr then return run.finish(1, lerr) end
                run_command(service, ctx, run, command, nil, function(cerr)
                    if cerr then return run.finish(1, cerr) end
                    M.launches(service)[id] = nil
                    answer({ outcome = "ok" })
                end)
            end)
        end)
        return interfaces.ASYNC
    end
end

--- The `loomworks.Devices/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.impl(service)
    local methods = {}
    function methods.list()
        return { devices = M.records((service:header_model()), service.ids) }
    end
    methods.scan = task_method(service, "scan", run_scan)
    methods.install = task_method(service, "install", function(s, c) return run_device_op(s, c, "install") end)
    methods.launch = task_method(service, "launch", function(s, c) return run_device_op(s, c, "launch") end)
    methods.stop = stop_method(service)
    -- (The first check records the baseline `changed` compares with.)
    local function subscribed()
        if service._devices_sig == nil then M.check(service) end
    end
    return { methods = methods, subscribed = subscribed }
end

return M
