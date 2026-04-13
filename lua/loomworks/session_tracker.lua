--- loomworks/session_tracker.lua — Unified launch/debug lifecycle manager.
---
--- Tracks active runs (overseer launches and dap debug sessions).
--- Handles build → deploy → execute chains, fidget progress, confirmation
--- dialogs when replacing a running session, and unified stop logic.

local Future = require("loomworks.future")

local M = {}

--- @class loomworks.TrackedRun
--- @field target loomworks.LaunchTarget
--- @field mode "launch"|"debug"
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

--- Stop the active run.
local function stop_run()
    if not _active_run then return end
    if _active_run.mode == "launch" then
        if _active_run.target:is_running() then
            _active_run.target:stop()
        end
    else
        local ok, dap = pcall(require, "dap")
        if ok then
            if _active_run.multi_adapter then
                -- Multi-adapter: terminate all root sessions
                dap.terminate({ hierarchy = true, all = true })
            elseif dap.session() then
                dap.terminate({ hierarchy = true })
            end
        end
    end
    _active_run = nil
end

--- Execute the build → deploy → launch/debug chain.
--- @param target loomworks.LaunchTarget
--- @param mode "launch"|"debug"
local function start_run(target, mode)
    local fidget = require("loomworks.fidget")
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
            if mode == "debug" then
                fidget.report(handle, "starting debugger...")
                target:debug()

                -- For debug: fidget finishes on event_initialized (adapter connected)
                -- or immediately if dap is unavailable (fallback to launch)
                local ok, dap = pcall(require, "dap")
                if ok and dap.session() then
                    local key = "loomworks-tracker-" .. tostring(os.clock())
                    dap.listeners.after.event_initialized[key] = function()
                        dap.listeners.after.event_initialized[key] = nil
                        fidget.finish(handle, "debugging")
                    end
                    -- Clean up tracked run on session end
                    local term_key = "loomworks-tracker-term-" .. tostring(os.clock())
                    local function on_end()
                        dap.listeners.before.event_terminated[term_key] = nil
                        dap.listeners.before.event_exited[term_key] = nil
                        if _active_run and _active_run.mode == "debug" then
                            _active_run = nil
                        end
                    end
                    dap.listeners.before.event_terminated[term_key] = on_end
                    dap.listeners.before.event_exited[term_key] = on_end
                else
                    -- dap unavailable or debug fell back to launch
                    fidget.finish(handle, "launched")
                end

                _active_run = { target = target, mode = "debug", started_at = os.clock() }
            else
                fidget.report(handle, "launching...")
                target:launch()
                fidget.finish(handle, "launched")
                _active_run = { target = target, mode = "launch", started_at = os.clock() }
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

--- Internal: execute multi-adapter build → deploy → launch + attach chain.
--- @param target loomworks.LaunchTarget
--- @param adapters { adapter: string }[]
--- @param spec_data { program: string, args?: string[], cwd?: string, env?: table, extra?: table }
local function start_multi_adapter_run(target, adapters, spec_data)
    local fidget = require("loomworks.fidget")
    local debug_mod = require("loomworks.debug")
    local handle = fidget.start_action("Debugging " .. target:display_name() .. " (multi-adapter)")

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
            fidget.report(handle, "starting primary debugger...")

            -- Launch with first adapter
            local primary = adapters[1]
            local primary_spec = vim.tbl_extend("force", spec_data, {
                adapter = primary.adapter,
                name = target:display_name() .. " (" .. primary.adapter .. ")",
            })

            _active_run = {
                target = target,
                mode = "debug",
                multi_adapter = true,
                started_at = os.clock(),
            }

            debug_mod.run(primary_spec, {
                on_pid = function(pid)
                    -- Attach remaining adapters to the same PID
                    for i = 2, #adapters do
                        local attach_adapter = adapters[i]
                        fidget.report(handle, "attaching " .. attach_adapter.adapter .. "...")
                        debug_mod.run({
                            adapter = attach_adapter.adapter,
                            request = "attach",
                            attach_pid = pid,
                            program = spec_data.program,
                            cwd = spec_data.cwd,
                            name = target:display_name() .. " (" .. attach_adapter.adapter .. ")",
                        })
                    end
                    fidget.finish(handle, "debugging (multi-adapter)")
                end,
                on_terminated = function()
                    -- Terminate all remaining sessions
                    local ok, dap = pcall(require, "dap")
                    if ok then
                        -- Terminate all sessions since multi-adapter shares a process
                        for _, s in pairs(dap.sessions()) do
                            s:disconnect({ terminateDebuggee = false })
                        end
                    end
                    if _active_run and _active_run.multi_adapter then
                        _active_run = nil
                    end
                end,
            })
        end)
        :catch(function(err)
            fidget.fail(handle, err)
            vim.notify("loomworks: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end)
end

--- Start a multi-adapter debug run.
--- First adapter launches the process, remaining adapters attach to
--- the same PID. Called by LaunchTarget when launch config has a
--- `debug` array with multiple adapters.
--- @param target loomworks.LaunchTarget
--- @param adapters { adapter: string }[] parsed adapter entries (first = primary)
--- @param spec_data { program: string, args?: string[], cwd?: string, env?: table, extra?: table }
function M.start_multi_adapter(target, adapters, spec_data)
    if is_active_running() then
        local name = _active_run.target:display_name()
        local running_mode = _active_run.mode == "debug" and "Debugging" or "Running"
        vim.ui.select({ "Yes", "No" }, {
            prompt = running_mode .. " '" .. name .. "'. Terminate and start new?",
        }, function(choice)
            if choice ~= "Yes" then return end
            stop_run()
            start_multi_adapter_run(target, adapters, spec_data)
        end)
        return
    end

    _active_run = nil
    start_multi_adapter_run(target, adapters, spec_data)
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
