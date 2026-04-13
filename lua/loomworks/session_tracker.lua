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
        if ok and dap.session() then
            dap.terminate({ hierarchy = true })
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
