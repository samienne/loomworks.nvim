--- loomworks/session_tracker.lua — Unified launch/debug lifecycle manager.
---
--- Tracks active runs (overseer launches and dap debug sessions).
--- Handles build → deploy → execute chains, fidget progress, confirmation
--- dialogs when replacing a running session, and unified stop logic.
--- Single and multi-adapter debug use the same code path.
---
--- In `daemon` runtime mode (step 5k C2, spec §19.16 "Editor operations")
--- the build and deploy of a non-device target's launch are the workspace
--- daemon's preparation (`Launch/1.prepare_run` / `prepare_debug` through
--- loomworks.daemon.editor_ops); the program is still started here, from
--- the returned spec. A preparation the daemon cannot carry or declines is
--- refused, never run in-process (step 5s, "Availability"). A device
--- target's launch (step 5n C2, §19.16 "Devices") is the daemon's too:
--- `Launch/1.build`, then `Devices/1.install` and `Devices/1.launch`, each
--- a task the editor owns (start_device_run); its stop is `Devices/1.stop`
--- and its device log is unavailable until the daemon carries it. In the
--- deprecated `in-process` mode every launch runs the chain below in the
--- editor.

local Future = require("loomworks.future")

local M = {}

--- @class loomworks.TrackedRun
--- @field target loomworks.LaunchTarget
--- @field mode "launch"|"debug"
--- @field multi_adapter boolean
--- @field fidget_handle table|nil
--- @field started_at number
--- @field device_serial string|nil
--- @field device_bundle string|nil
--- @field device_pid number|nil
--- @field pidof_timer uv_timer_t|nil
--- @field device_task any|nil `daemon` mode: the `Devices/1.launch` task that launched the program (a stop names it, step 5n C2)

--- @type loomworks.TrackedRun|nil
local _active_run = nil

--- A launch the workspace daemon is preparing (step 5k C2): no program yet,
--- but a stop cancels it and a second launch asks before replacing it, as
--- for a running session.
--- @class loomworks.PreparingRun
--- @field target loomworks.LaunchTarget
--- @field mode "launch"|"debug"
--- @field preparation loomworks.daemon.Preparation|nil the routed call (editor_ops.prepare), once sent; a device run's current step (step 5n C2)
--- @field fidget_handle table|nil a device run's progress entry (failed on a stop)

--- @type loomworks.PreparingRun|nil
local _preparing = nil

--- Cancel the launch being prepared, if any: its call is cancelled and no
--- program is started (editor_ops.prepare's preparation).
local function cancel_preparing()
    local p = _preparing
    _preparing = nil
    if p and p.preparation then p.preparation:cancel() end
    if p and p.fidget_handle then require("loomworks.fidget").fail(p.fidget_handle, "stopped") end
end

--- Check if the active run is still actually running.
--- @return boolean
local function is_active_running()
    if not _active_run then return false end
    -- A program the daemon launched on a device runs until it is stopped
    -- (the editor cannot see it end).
    if _active_run.device_task ~= nil then return true end
    if _active_run.mode == "launch" then
        return _active_run.target:is_running()
    else
        local ok, dap = pcall(require, "dap")
        return ok and dap.session() ~= nil
    end
end

--- Clear the device's log buffer before a fresh launch so the
--- device-log view doesn't mix in stale entries from previous
--- sessions. Best-effort: a clear failure doesn't fail the launch.
--- Runs synchronously (it's one quick RPC to the device connector).
--- @param target loomworks.LaunchTarget
--- @param device_serial string
local function clear_device_log(target, device_serial)
    local mod = target._project and target._project._module
        and target._project._module.impl
    if not mod or not mod.device_log_clear then return end
    local td = target._config_unit and target._config_unit._tool_data or {}
    local spec = mod.device_log_clear(td, device_serial)
    if not spec or not spec.cmd then return end
    local cmd = vim.list_extend({ spec.cmd }, spec.args or {})
    pcall(function()
        require("loomworks.exe").system(cmd, { text = true, timeout = 3000 }):wait()
    end)
end

--- Start the device-log view + streaming task for the active run.
--- Composes the module's `device_log` cmd spec and hands it to the
--- device_log module, which owns the view, ring buffer, and the
--- streaming overseer task. The task handle is kept inside
--- device_log, not on the active run record — session_tracker just
--- asks device_log to stop during teardown.
---
--- Modules with device-log support own the soft-filter level and any
--- module-specific log-stream options. We read them via the optional
--- `mod.device_log_options(tool_data)` hook (returning `{ level,
--- strict_pid, ... }`) and pass `pid` through when the module asks
--- for strict-pid filtering. The level travels into device_log purely
--- as the initial soft filter — re-rendering only, never restarts.
---
--- @param target loomworks.LaunchTarget
--- @param device_serial string
--- @param bundle string
--- @param pid number
local function start_device_log_view(target, device_serial, bundle, pid)
    local mod = target._project and target._project._module
        and target._project._module.impl
    if not mod or not mod.device_log then return end
    local td = target._config_unit and target._config_unit._tool_data or {}

    local log_options = (mod.device_log_options and mod.device_log_options(td))
        or {}
    local level = log_options.level or "I"
    local strict_pid = log_options.strict_pid and true or false
    local log_opts = {}
    if strict_pid then log_opts.pid = pid end
    local spec = mod.device_log(td, device_serial, log_opts)
    if not spec or not spec.cmd then return end
    local cmd = vim.list_extend({ spec.cmd }, spec.args or {})

    -- Clear the on-device log buffer right before starting the stream
    -- so the view doesn't mix in stale entries from previous sessions,
    -- but AFTER the device_launch completed so any launch-time logs
    -- the app has already emitted are still on the device and will
    -- stream in.
    clear_device_log(target, device_serial)

    local device_log = require("loomworks.device_log")
    local pid_label = strict_pid and "strict-pid " .. pid or "no pid filter"
    device_log.start({
        name = target._project.key .. ": device logs (pid " .. pid .. ")",
        cmd = cmd,
        prefilter = device_log.make_prefilter({ pid = pid, bundle = bundle }),
        banner = string.format(
            "device-log session: %s  bundle=%s  pid=%d  %s  soft-level=%s",
            target._project.key, bundle, pid, pid_label, level),
        -- On the first launch in this nvim process, apply the
        -- configured soft level so the user isn't drowning in V/D
        -- noise. On subsequent launches we preserve whatever filter
        -- they tuned with `cl` / `cf` — explicit soft_filter is NOT
        -- passed, so device_log keeps the existing filter instead of
        -- reapplying the default.
        default_soft_filter = { level = level },
    })
end

--- Start a periodic pidof poll for auto-stop when the app exits on
--- device. Two consecutive empty results = app is gone; tear the
--- session down the same way a user-initiated stop would.
---
--- 3s cadence is long enough that device-connector RTT isn't a
--- burden but short enough that users see the session clean up
--- promptly. Two misses
--- before closing smooths over a transient shell hiccup or a brief
--- respawn.
--- @param target loomworks.LaunchTarget
--- @param device_serial string
--- @param bundle string
local function start_pidof_poll(target, device_serial, bundle)
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    if not timer then return end

    local consecutive_misses = 0
    local function tick()
        if not _active_run or _active_run.target ~= target then
            pcall(function() timer:stop(); timer:close() end)
            return
        end
        target:device_resolve_pid(device_serial, bundle,
            { tries = 1, interval_ms = 0 })
            :next(function(pid)
                if not _active_run or _active_run.target ~= target then
                    pcall(function() timer:stop(); timer:close() end)
                    return
                end
                if pid then
                    consecutive_misses = 0
                else
                    consecutive_misses = consecutive_misses + 1
                    if consecutive_misses >= 2 then
                        pcall(function() timer:stop(); timer:close() end)
                        _active_run.pidof_timer = nil
                        vim.notify(
                            "loomworks: device app exited, closing log stream",
                            vim.log.levels.INFO)
                        local device_log = require("loomworks.device_log")
                        pcall(device_log.stop)
                        _active_run = nil
                    end
                end
            end)
    end

    timer:start(3000, 3000, vim.schedule_wrap(tick))
    _active_run.pidof_timer = timer
end

--- Tear down the device-log session attached to the run, if any:
--- the pidof poll timer, the log streaming task, and the soft
--- binding between the session and the log view. Swallow errors —
--- this is cleanup and timer / task state varies with lifecycle.
local function stop_log_session()
    if not _active_run then return end
    if _active_run.pidof_timer then
        pcall(function() _active_run.pidof_timer:stop() end)
        pcall(function() _active_run.pidof_timer:close() end)
        _active_run.pidof_timer = nil
    end
    local ok, device_log = pcall(require, "loomworks.device_log")
    if ok then pcall(device_log.stop) end
end

--- Stop the active run.
local function stop_run()
    if not _active_run then return end
    -- Cancel any pending fidget handle
    if _active_run.fidget_handle then
        require("loomworks.fidget").fail(_active_run.fidget_handle, "stopped")
        _active_run.fidget_handle = nil
    end
    stop_log_session()
    if _active_run.device_task ~= nil then
        -- `daemon` mode (step 5n C2): the daemon stops the program its
        -- launch task started (`Devices/1.stop { task }`); a refusal or
        -- failure is notified, never retried in the editor.
        local ops = require("loomworks.daemon.editor_ops")
        ops.device_stop(ops.scope_workspace({ profile = _active_run.target._profile }), _active_run.device_task)
    elseif _active_run.mode == "launch" then
        -- Device launch: `<target>:stop()` only knows how to kill a
        -- local process; the app is running on the device, so
        -- delegate to the module's `device_stop` RPC. Fire and
        -- forget — failures are a notify-worthy warning, not a
        -- reason to block teardown.
        if _active_run.device_serial and _active_run.device_bundle then
            local target = _active_run.target
            local serial = _active_run.device_serial
            local bundle = _active_run.device_bundle
            target:device_stop(serial, bundle):catch(function(err)
                vim.notify(
                    "loomworks: device stop failed: " .. tostring(err),
                    vim.log.levels.WARN)
            end)
        elseif _active_run.target:is_running() then
            _active_run.target:stop()
        end
    else
        local ok, dap = pcall(require, "dap")
        if ok then
            if _active_run.multi_adapter then
                dap.terminate({ hierarchy = true, all = true })
            elseif dap.session() then
                dap.terminate({ hierarchy = true })
            end
        end
    end
    _active_run = nil
end

--- Register dap listeners to finish fidget and clean up tracked run on session end.
---
--- Both `event_initialized` (the happy path) and session end must finish
--- the fidget handle. If the dap session terminates or exits before
--- initialising — adapter crashed, attach failed, debuggee died at startup —
--- only the end listener fires; without it the popup would spin forever. The
--- `finished` flag makes whichever event fires first win, the second a no-op.
--- @param handle table fidget handle
--- @param multi boolean multi-adapter run
local function register_debug_listeners(handle, multi)
    local ok, dap = pcall(require, "dap")
    if not ok then return end

    local fidget = require("loomworks.fidget")
    local ts = tostring(os.clock())
    local finished = false

    local function finish_once(label)
        if finished then return end
        finished = true
        fidget.finish(handle, label)
    end

    -- Finish fidget on session initialized (happy path)
    local init_key = "loomworks-tracker-init-" .. ts
    dap.listeners.after.event_initialized[init_key] = function()
        dap.listeners.after.event_initialized[init_key] = nil
        if _active_run and _active_run.fidget_handle == handle then
            _active_run.fidget_handle = nil
        end
        finish_once(multi and "debugging (multi-adapter)" or "debugging")
    end

    -- Clean up tracked run on session end. Also finishes the
    -- fidget handle if it wasn't already — covers the case where
    -- a session terminates before initialisation.
    local term_key = "loomworks-tracker-term-" .. ts
    local function on_end()
        dap.listeners.before.event_terminated[term_key] = nil
        dap.listeners.before.event_exited[term_key] = nil
        if _active_run and _active_run.mode == "debug" then
            if multi then
                -- Disconnect all remaining sessions
                for _, s in pairs(dap.sessions()) do
                    s:disconnect({ terminateDebuggee = false })
                end
            end
            _active_run = nil
        end
        finish_once("debug session ended")
    end
    dap.listeners.before.event_terminated[term_key] = on_end
    dap.listeners.before.event_exited[term_key] = on_end
end

--- Start a debug session from a resolved spec: the first adapter launches
--- the program, the others attach to its pid (§8.9.6 "Multi-adapter
--- debugging"). The in-process multi-adapter path and every debug launch the
--- workspace daemon prepared start here. Fails the progress entry when
--- nvim-dap cannot start it.
--- @param handle table|nil fidget handle
--- @param target loomworks.LaunchTarget
--- @param adapters { adapter: string }[] ordered
--- @param data { name?: string, program: string|nil, args?: string[], cwd?: string, env?: table }
local function start_dap(handle, target, adapters, data)
    local fidget = require("loomworks.fidget")
    local debug_mod = require("loomworks.debug")
    local multi = #adapters > 1
    local primary = adapters[1]
    local primary_spec = vim.tbl_extend("force", data, {
        adapter = primary.adapter,
        name = multi and (target:display_name() .. " (" .. tostring(primary.adapter) .. ")")
            or data.name or target:display_name(),
    })
    local callbacks = nil
    if multi then
        callbacks = {
            on_pid = function(pid)
                for i = 2, #adapters do
                    local a = adapters[i]
                    fidget.report(handle, "attaching " .. a.adapter .. "...")
                    debug_mod.run({
                        adapter = a.adapter,
                        request = "attach",
                        attach_pid = pid,
                        program = data.program,
                        cwd = data.cwd,
                        name = target:display_name() .. " (" .. a.adapter .. ")",
                    })
                end
            end,
        }
    end
    -- `debug.run` returns false when dap is unavailable or the adapter isn't
    -- configured. The listeners are registered only for a session that
    -- starts: otherwise they would never fire and the fidget popup would
    -- spin forever.
    local started = debug_mod.run(primary_spec, callbacks)
    if not started then
        fidget.fail(handle, "debug adapter not available")
        _active_run = nil
        return
    end
    register_debug_listeners(handle, multi)
end

--- Execute the build → deploy → launch/debug chain in-process.
--- Handles both single and multi-adapter debug uniformly.
--- `from_deploy`: the workspace daemon already built it (a preparation that
--- ended with `device = true`, §19.15 "Run", "Build scope of a launch"): the
--- chain continues from the post-build deploy, never building again.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
--- @param from_deploy? boolean
local function start_run_in_process(target, mode, from_deploy)
    local fidget = require("loomworks.fidget")
    local multi = mode == "debug" and target:is_multi_adapter()
    local label = mode == "debug" and "Debugging " or "Launching "
    local handle = fidget.start_action(label .. target:display_name())

    local chain
    if not from_deploy and target:is_buildable() then
        fidget.report(handle, "building...")
        chain = target:build()
    else
        chain = Future.resolved(true)
    end

    chain
        :next(function()
            fidget.report(handle, "deploying...")
            return target:deploy()
        end)
        :next(function()
            -- Device target path: install + launch on device, then return
            if target:requires_device() then
                local device_source = require("loomworks.device_source")
                local serial = device_source.chosen_in(nil, target._profile)
                if not serial then
                    -- Prompt for device selection
                    return Future.create(function(resolve, reject)
                        device_source.scan_for_target(target, function(devices)
                            local items = {}
                            for _, d in ipairs(devices or {}) do
                                if d.state == "online" then
                                    items[#items + 1] = d
                                end
                            end
                            if #items == 0 then
                                reject("no online devices found")
                                return
                            end
                            vim.ui.select(items, {
                                prompt = "Select device:",
                                format_item = function(d)
                                    return d.label .. " (" .. d.key .. ")"
                                end,
                            }, function(choice)
                                if not choice then
                                    reject("device selection cancelled")
                                    return
                                end
                                device_source.select_for_target(target, choice)
                                resolve(choice.key)
                            end)
                        end)
                    end)
                end
                return serial
            end
        end)
        :next(function(device_serial)
            if target:requires_device() then
                if not device_serial then return end  -- chain was handled above
                fidget.report(handle, "installing on device...")
                return target:device_install(device_serial):next(function()
                    return device_serial
                end)
            end
        end)
        :next(function(device_serial)
            if target:requires_device() then
                if not device_serial then return end
                fidget.report(handle, "launching on device...")
                return target:device_launch(device_serial):next(function()
                    fidget.finish(handle, "running on device")
                    _active_run = {
                        target = target,
                        mode = "launch",
                        multi_adapter = false,
                        started_at = os.clock(),
                        device_serial = device_serial,
                    }
                    -- Kick off the log view asynchronously. The
                    -- launch already succeeded; a log stream that
                    -- fails to attach is a notification, not a
                    -- chain failure.
                    --
                    -- We do NOT trust the device connector's on-device
                    -- filter flags (they're inconsistent across releases)
                    -- — device_log parses the raw stream client-side
                    -- and applies a prefilter {pid, bundle} with
                    -- union semantics, catching both the app's main
                    -- process and any runtime helper that logs under
                    -- a different PID but for the same app.
                    local info = target:device_launch_info()
                    local bundle = info and info.bundle_name
                    if bundle then
                        target:device_resolve_pid(device_serial, bundle)
                            :next(function(pid)
                                if not _active_run
                                    or _active_run.target ~= target then
                                    return
                                end
                                if not pid then
                                    vim.notify(
                                        "loomworks: app PID didn't appear — skipping log stream",
                                        vim.log.levels.WARN)
                                    return
                                end
                                _active_run.device_pid = pid
                                _active_run.device_bundle = bundle
                                _active_run.device_serial = device_serial
                                start_device_log_view(target, device_serial, bundle, pid)
                                start_pidof_poll(target, device_serial, bundle)
                            end)
                            :catch(function(err)
                                vim.notify(
                                    "loomworks: device log stream failed: " .. tostring(err),
                                    vim.log.levels.WARN)
                            end)
                    end
                end)
            end

            -- Non-device path: launch or debug locally
            if mode == "debug" then
                fidget.report(handle, "starting debugger...")

                _active_run = {
                    target = target,
                    mode = "debug",
                    multi_adapter = multi,
                    fidget_handle = handle,
                    started_at = os.clock(),
                }

                if multi then
                    -- Multi-adapter: launch primary, attach rest via PID
                    local adapters, spec_data = target:multi_adapter_specs()
                    if not adapters then
                        _active_run = nil
                        error(spec_data)
                    end
                    start_dap(handle, target, adapters, spec_data)
                else
                    -- Single adapter: delegate to LaunchTarget:debug()
                    target:debug()

                    local ok, dap = pcall(require, "dap")
                    if ok and dap.session() then
                        register_debug_listeners(handle, false)
                    else
                        -- dap unavailable or fell back to launch
                        fidget.finish(handle, "launched")
                        _active_run = { target = target, mode = "launch", multi_adapter = false, started_at = os.clock() }
                    end
                end
            else
                fidget.report(handle, "launching...")
                target:launch()
                fidget.finish(handle, "launched")
                _active_run = { target = target, mode = "launch", multi_adapter = false, started_at = os.clock() }
            end
        end)
        :catch(function(err)
            fidget.fail(handle, err)
            vim.notify("loomworks: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end)
end

--- Start the program of a launch the workspace daemon prepared (step 5k C2):
--- a run's `launch` in the task runner (LaunchTarget:launch_resolved), a
--- debug's `debug` handed to nvim-dap (start_dap). A `device` result (a
--- foreign artifact, §18.1, found once the daemon built it) continues as the
--- in-process chain from the post-build deploy, never building again
--- (§19.15 "Run", "Build scope of a launch"): its launch is refused there as
--- in-process. The progress entry covers only this final phase (the
--- preparation's own task was its build phase, D13). A program still
--- running is stopped first, never left untracked. An error starting it is
--- notified and fails the progress entry, as the in-process chain's.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
--- @param done table the preparation's task result
local function start_prepared(target, mode, done)
    local fidget = require("loomworks.fidget")
    local name = target:display_name()
    if is_active_running() then stop_run() end
    _active_run = nil
    if mode ~= "debug" and done.device then return start_run_in_process(target, mode, true) end
    local handle
    local ok, err = pcall(function()
        if mode == "debug" then
            local d = done.debug
            if type(d) ~= "table" or type(d.program) ~= "string" or type(d.adapters) ~= "table"
                or not d.adapters[1] then
                vim.notify("loomworks: the workspace daemon returned no debug launch for '" .. name
                    .. "' — it was not started", vim.log.levels.ERROR)
                return
            end
            local adapters = {}
            for i, a in ipairs(d.adapters) do adapters[i] = { adapter = a.adapter } end
            handle = fidget.start_action("Debugging " .. name)
            fidget.report(handle, "starting debugger...")
            _active_run = {
                target = target, mode = "debug", multi_adapter = #adapters > 1,
                fidget_handle = handle, started_at = os.clock(),
            }
            local env = type(d.env) == "table" and next(d.env) and d.env or nil
            start_dap(handle, target, adapters, {
                name = d.name, program = d.program, args = d.args or {}, cwd = d.cwd, env = env })
            return
        end
        local l = done.launch
        if type(l) ~= "table" or type(l.cmd) ~= "string" then
            vim.notify("loomworks: the workspace daemon returned no launch for '" .. name
                .. "' — it was not run", vim.log.levels.ERROR)
            return
        end
        local spec = { name = tostring(l.name or l.cmd), cmd = l.cmd,
            cwd = type(l.cwd) == "string" and l.cwd or nil, args = {}, env = nil }
        for _, a in ipairs(type(l.args) == "table" and l.args or {}) do spec.args[#spec.args + 1] = tostring(a) end
        if type(l.env) == "table" and next(l.env) then
            spec.env = {}
            for k, v in pairs(l.env) do spec.env[tostring(k)] = tostring(v) end
        end
        handle = fidget.start_action("Launching " .. name)
        fidget.report(handle, "launching...")
        target:launch_resolved(spec)
        fidget.finish(handle, "launched")
        _active_run = { target = target, mode = "launch", multi_adapter = false, started_at = os.clock() }
    end)
    if not ok then
        _active_run = nil
        fidget.fail(handle, tostring(err))
        vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- A device target's launch through the workspace daemon (step 5n C2,
--- §19.16 "Devices"): its build (`Launch/1.build`, the post-build deploy
--- included), the profile's device — when it has none, a scan
--- (`Devices/1.scan`) and a choice among the online devices
--- (`Profiles/1.set_device`) — then `Devices/1.install` and
--- `Devices/1.launch`, each a task the editor owns. Nothing of it runs in
--- the editor; a step refused or failed ends it (notified). While it runs
--- it is `_preparing`: a stop cancels the current step, a second launch asks
--- first. Launched, the run is tracked by its launch task (a stop sends
--- `Devices/1.stop`) and the device log is refused (device_log.refuse_daemon:
--- the daemon does not carry its stream yet).
--- @param target loomworks.LaunchTarget
local function start_device_run(target)
    local ops = require("loomworks.daemon.editor_ops")
    local device_source = require("loomworks.device_source")
    local fidget = require("loomworks.fidget")
    --- @type loomworks.PreparingRun
    local token = { target = target, mode = "launch" }
    _preparing = token
    local handle = fidget.start_action("Launching " .. target:display_name())
    token.fidget_handle = handle
    local function live() return _preparing == token end
    local function fail(err, notified)
        if not live() then return end
        _preparing = nil
        fidget.fail(handle, tostring(err))
        if not notified then
            vim.notify("loomworks: " .. tostring(err or "the launch failed"), vim.log.levels.ERROR)
        end
    end
    --- One owned call of the chain; `after(done)` once it ended with exit 0.
    local function call(start, after)
        if not live() then return end
        local _, step = start({
            resolve = function(done) if live() then after(done) end end,
            reject = fail,
        })
        token.preparation = step
        -- Stopped before the call returned: nothing more of it may run.
        if not live() and step then step:cancel() end
    end
    local function launched(done)
        _preparing = nil
        fidget.finish(handle, "running on device")
        _active_run = { target = target, mode = "launch", multi_adapter = false, started_at = os.clock(),
            device_task = done.task_id }
        require("loomworks.device_log").refuse_daemon()
    end
    local function install()
        fidget.report(handle, "installing on device...")
        call(function(k) return ops.device_step("install", target, k) end, function()
            fidget.report(handle, "launching on device...")
            call(function(k) return ops.device_step("launch", target, k) end, launched)
        end)
    end
    local function choose()
        device_source.chosen_for_target(target, function(serial)
            if not live() then return end
            if serial then return install() end
            fidget.report(handle, "scanning for devices...")
            device_source.scan_for_target(target, function(devices, err)
                if not live() then return end
                if not devices then return fail(err, true) end
                local items = {}
                for _, d in ipairs(devices) do
                    if d.state == "online" then items[#items + 1] = d end
                end
                if #items == 0 then return fail("no online devices found") end
                vim.ui.select(items, {
                    prompt = "Select device:",
                    format_item = function(d) return d.label .. " (" .. d.key .. ")" end,
                }, function(choice)
                    if not live() then return end
                    if not choice then return fail("device selection cancelled") end
                    device_source.select_for_target(target, choice, function(ok, serr)
                        if not live() then return end
                        if not ok then return fail(serr, true) end
                        install()
                    end)
                end)
            end)
        end)
    end
    fidget.report(handle, "building...")
    call(function(k) return ops.build_target(target, k) end, choose)
end

--- The build → deploy → launch/debug chain: in `daemon` mode prepared by the
--- workspace daemon (spec §19.16 "Editor operations") — refused when it
--- cannot carry it ("Availability") — and a device target's run in the
--- editor only while connected; in the `in-process` mode in-process.
--- A debug without nvim-dap launches (as LaunchTarget:debug does); a debug
--- whose launching adapter is not installed stops here with the install
--- hint, before the preparation (§8.9.6: the client's check) - the adapter
--- the daemon's `DebugConfig/1` mapping names while it is carried
--- (editor_ops.debug_adapter_resolver; not carried, or a language it does
--- not name: not checked here — debug.run checks the prepared adapter).
--- While the daemon prepares, the
--- launch is `_preparing`: a stop cancels it, a second launch asks first.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
local function start_run(target, mode)
    local ops = require("loomworks.daemon.editor_ops")
    if target:requires_device() then
        if not ops.prepares(target) then return start_run_in_process(target, mode) end
        -- Not carried now: refused like any operation, nothing of it run.
        if ops.device_run_refused(target) then return end
        return start_device_run(target)
    end
    local debug_mod = require("loomworks.debug")
    local prep = (mode == "debug" and debug_mod.available()) and "debug" or "launch"
    if not ops.prepares(target) then return start_run_in_process(target, mode) end

    --- @type loomworks.PreparingRun
    local token = { target = target, mode = mode }
    _preparing = token
    -- This launch's outcome, unless it was cancelled or replaced meanwhile.
    local function settle()
        if _preparing ~= token then return false end
        _preparing = nil
        return true
    end
    local function send()
        if _preparing ~= token then return end
        local routed, preparation = ops.prepare(prep, target, {
            resolve = function(done) if settle() then start_prepared(target, prep, done) end end,
            -- Refused (not carried, declined, degraded, refused), failed, or
            -- the connection lost after `accepted`: no program is started
            -- (never run in-process). A refusal or a failed call was already
            -- notified.
            reject = function(err, notified)
                if not settle() then return end
                if not notified then
                    vim.notify("loomworks: " .. tostring(err or "the launch failed"), vim.log.levels.ERROR)
                end
            end,
        })
        if not routed then
            if settle() then start_run_in_process(target, mode) end
            return
        end
        token.preparation = preparation
        -- Settled or cancelled before `prepare` returned (refused at once):
        -- nothing more of it may run.
        if _preparing ~= token and preparation then preparation:cancel() end
    end
    if prep ~= "debug" then return send() end
    ops.debug_adapter_resolver(target, function(resolve)
        if _preparing ~= token then return end
        -- No daemon mapping (DebugConfig/1 not carried, or its read failed),
        -- or a language it does not name: unchecked here — never the
        -- editor's own mapping; debug.run checks the prepared adapter.
        if not resolve then return send() end
        local adapter, language = target:primary_debug_adapter(resolve)
        if not select(2, resolve(language)) then return send() end
        if not debug_mod.adapter_installed(adapter) then
            settle()
            debug_mod.adapter_hint(adapter, language)
            return
        end
        send()
    end)
end

--- Why a run or debug launch of `target` is refused now, or nil: in
--- `daemon` mode while the editor's workspace is unloaded (spec §19.16
--- "Editor operations": not offered, refused with that status). Never loads
--- the daemon modules (in-process mode has no observer).
--- @param target loomworks.LaunchTarget
--- @return string|nil
function M.launch_refusal(target)
    local mod = package.loaded["loomworks.daemon.observer"]
    if type(mod) ~= "table" or not (target and target._profile) then return nil end
    local ws = require("loomworks.daemon.editor_ops").scope_workspace({ profile = target._profile })
    local obs = ws and mod.of(ws) or nil
    if not obs then return nil end
    local unloaded, why = obs:workspace_unloaded()
    if not unloaded then return nil end
    return "the workspace is unloaded (" .. tostring(why) .. ")"
end

--- Start a launch or debug run.
--- Shows confirmation if something is already running.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
function M.start(target, mode)
    -- Refuse incomplete profiles upfront. Going further would have
    -- the build chain run with a nil tool_data and produce malformed
    -- on-disk artefacts (`.nvim/build/<project>/<bare-name>` shape).
    -- Module-agnostic — Profile:assert_buildable iterates module
    -- capability flags via Profile:is_complete.
    local profile = target._profile
    if profile then
        local ok, err = profile:assert_buildable()
        if not ok then
            vim.notify("loomworks: " .. err, vim.log.levels.WARN)
            return
        end
    end

    -- `daemon` mode with the workspace unloaded — the daemon reports it
    -- `unloaded`, or the connection is lost (spec §19.16
    -- "Editor operations", "Unloaded on disconnect"): refused with that
    -- status, never prepared in-process (its launch information comes only
    -- from the daemon).
    local why = M.launch_refusal(target)
    if why then
        vim.notify("loomworks: cannot " .. (mode == "debug" and "debug" or "run") .. " '"
            .. target:display_name() .. "': " .. why, vim.log.levels.WARN)
        return
    end

    -- A running session, or a launch the workspace daemon is preparing:
    -- ask, then stop (cancel) it before starting the new one.
    local current = (is_active_running() and _active_run) or _preparing
    if current then
        local name = current.target:display_name()
        local running_mode = current == _preparing and "Preparing"
            or (current.mode == "debug" and "Debugging" or "Running")
        vim.ui.select({ "Yes", "No" }, {
            prompt = running_mode .. " '" .. name .. "'. Terminate and start new?",
        }, function(choice)
            if choice ~= "Yes" then return end
            cancel_preparing()
            stop_run()
            start_run(target, mode)
        end)
        return
    end

    -- Clean up stale reference
    _active_run = nil
    start_run(target, mode)
end

--- Stop the active run, or cancel the launch the workspace daemon is
--- preparing (its task cancelled; no program is started).
function M.stop()
    if _preparing then
        cancel_preparing()
        return
    end
    if is_active_running() then
        stop_run()
        return
    end
    _active_run = nil
    vim.notify("loomworks: no running session", vim.log.levels.INFO)
end

--- Check if any run is active.
--- @return boolean
function M.is_running()
    return is_active_running()
end

--- Get the active run (for status display).
--- @return loomworks.TrackedRun|nil
function M.active_run()
    if is_active_running() then
        return _active_run
    end
    _active_run = nil
    return nil
end

return M
