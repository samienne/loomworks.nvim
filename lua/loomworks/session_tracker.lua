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

--- Stop the active run.
local function stop_run()
    if not _active_run then return end
    -- Cancel any pending fidget handle
    if _active_run.fidget_handle then
        require("loomworks.fidget").fail(_active_run.fidget_handle, "stopped")
        _active_run.fidget_handle = nil
    end
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
