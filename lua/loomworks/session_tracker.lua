--- loomworks/session_tracker.lua — Unified launch/debug lifecycle manager.
---
--- Tracks active runs (overseer launches and dap debug sessions).
--- Handles build → deploy → execute chains, fidget progress, confirmation
--- dialogs when replacing a running session, and unified stop logic.
--- Single and multi-adapter debug use the same code path.

local Future = require("loomworks.future")

local M = {}

--- @class loomworks.TrackedRun
--- @field target loomworks.LaunchTarget
--- @field mode "launch"|"debug"
--- @field multi_adapter boolean
--- @field fidget_handle table|nil
--- @field started_at number

--- @type loomworks.TrackedRun|nil
local _active_run = nil

--- Check if the active run is still actually running.
--- @return boolean
local function is_active_running()
    if not _active_run then return false end
    if _active_run.mode == "launch" then
        return _active_run.target:is_running()
    else
        local ok, dap = pcall(require, "dap")
        return ok and dap.session() ~= nil
    end
end

--- Clear the device's hilog buffer before a fresh launch so the
--- device-log view doesn't mix in stale entries from previous
--- sessions. Best-effort: a clear failure doesn't fail the launch.
--- Runs synchronously (it's one quick RPC to hdc).
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
        vim.system(cmd, { text = true, timeout = 3000 }):wait()
    end)
end

--- Start the device-log view + streaming task for the active run.
--- Composes the module's `device_log` cmd spec and hands it to the
--- device_log module, which owns the view, ring buffer, and the
--- streaming overseer task. The task handle is kept inside
--- device_log, not on the active run record — session_tracker just
--- asks device_log to stop during teardown.
--- @param target loomworks.LaunchTarget
--- @param device_serial string
--- @param bundle string
--- @param pid number
local function start_device_log_view(target, device_serial, bundle, pid)
    local mod = target._project and target._project._module
        and target._project._module.impl
    if not mod or not mod.device_log then return end
    local td = target._config_unit and target._config_unit._tool_data or {}

    -- Ask for the raw stream (no device-side filter flags — we parse
    -- and filter client-side where it's reliable).
    local spec = mod.device_log(td, device_serial, {})
    if not spec or not spec.cmd then return end
    local cmd = vim.list_extend({ spec.cmd }, spec.args or {})

    -- Clear stale hilog buffer right before starting the stream so
    -- we don't show entries from a previous run, but AFTER the
    -- device_launch completed so any launch-time logs the app has
    -- already emitted are still on the device and will stream in.
    clear_device_log(target, device_serial)

    local device_log = require("loomworks.device_log")
    device_log.start({
        name = target._project.key .. ": device logs (pid " .. pid .. ")",
        cmd = cmd,
        prefilter = device_log.make_prefilter({ pid = pid, bundle = bundle }),
        -- On the first launch in this nvim process, apply a sensible
        -- default soft filter so the user isn't drowning in V/D-level
        -- noise. On subsequent launches we preserve whatever filter
        -- they tuned with `cl` / `cf` — explicit soft_filter is NOT
        -- passed, so device_log keeps the existing filter instead of
        -- reapplying the default.
        default_soft_filter = { level = "I" },
    })
end

--- Start a periodic pidof poll for auto-stop when the app exits on
--- device. Two consecutive empty results = app is gone; tear the
--- session down the same way a user-initiated stop would.
---
--- 3s cadence is long enough that hdc RTT isn't a burden but short
--- enough that users see the session clean up promptly. Two misses
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
--- the pidof poll timer, the hilog streaming task, and the soft
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
    if _active_run.mode == "launch" then
        if _active_run.target:is_running() then
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
--- @param handle table fidget handle
--- @param multi boolean multi-adapter run
local function register_debug_listeners(handle, multi)
    local ok, dap = pcall(require, "dap")
    if not ok then return end

    local fidget = require("loomworks.fidget")
    local ts = tostring(os.clock())

    -- Finish fidget on session initialized
    local init_key = "loomworks-tracker-init-" .. ts
    dap.listeners.after.event_initialized[init_key] = function()
        dap.listeners.after.event_initialized[init_key] = nil
        if _active_run and _active_run.fidget_handle == handle then
            _active_run.fidget_handle = nil
        end
        local label = multi and "debugging (multi-adapter)" or "debugging"
        fidget.finish(handle, label)
    end

    -- Clean up tracked run on session end
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
    end
    dap.listeners.before.event_terminated[term_key] = on_end
    dap.listeners.before.event_exited[term_key] = on_end
end

--- Execute the build → deploy → launch/debug chain.
--- Handles both single and multi-adapter debug uniformly.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
local function start_run(target, mode)
    local fidget = require("loomworks.fidget")
    local multi = mode == "debug" and target:is_multi_adapter()
    local label = mode == "debug" and "Debugging " or "Launching "
    local handle = fidget.start_action(label .. target:display_name())

    local chain
    if target:is_buildable() then
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
                local serial = target._profile:device_serial()
                if not serial then
                    -- Prompt for device selection
                    return Future.create(function(resolve, reject)
                        target._workspace:scan_devices(function(devices)
                            local items = {}
                            for _, d in ipairs(devices) do
                                if d:is_online() then
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
                                    return d.display_name .. " (" .. d.serial .. ")"
                                end,
                            }, function(choice)
                                if not choice then
                                    reject("device selection cancelled")
                                    return
                                end
                                target._profile:set_device(choice.serial)
                                resolve(choice.serial)
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
                    -- We do NOT trust hdc/hilog's on-device filter
                    -- flags (they're inconsistent across releases)
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
                    local debug_mod = require("loomworks.debug")
                    local adapters, spec_data = target:multi_adapter_specs()
                    local primary = adapters[1]
                    local primary_spec = vim.tbl_extend("force", spec_data, {
                        adapter = primary.adapter,
                        name = target:display_name() .. " (" .. primary.adapter .. ")",
                    })

                    register_debug_listeners(handle, true)

                    debug_mod.run(primary_spec, {
                        on_pid = function(pid)
                            for i = 2, #adapters do
                                local a = adapters[i]
                                fidget.report(handle, "attaching " .. a.adapter .. "...")
                                debug_mod.run({
                                    adapter = a.adapter,
                                    request = "attach",
                                    attach_pid = pid,
                                    program = spec_data.program,
                                    cwd = spec_data.cwd,
                                    name = target:display_name() .. " (" .. a.adapter .. ")",
                                })
                            end
                        end,
                    })
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

--- Start a launch or debug run.
--- Shows confirmation if something is already running.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
function M.start(target, mode)
    if is_active_running() then
        local name = _active_run.target:display_name()
        local running_mode = _active_run.mode == "debug" and "Debugging" or "Running"
        vim.ui.select({ "Yes", "No" }, {
            prompt = running_mode .. " '" .. name .. "'. Terminate and start new?",
        }, function(choice)
            if choice ~= "Yes" then return end
            stop_run()
            start_run(target, mode)
        end)
        return
    end

    -- Clean up stale reference
    _active_run = nil
    start_run(target, mode)
end

--- Stop the active run.
function M.stop()
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
