--- loomtest/runner.lua — Test execution via overseer.
---
--- Executes RunSpecs as overseer tasks, parses results on completion,
--- and updates the test tree.

local M = {}

--- @type number|nil most recent test task ID
local _last_task_id = nil

--- @type string|nil output from last test run
local _last_output = nil

--- Execute a test RunSpec via overseer.
--- @param adapter loomtest.TestAdapter the adapter for result parsing
--- @param spec loomtest.RunSpec the command to execute
--- @param test_ids string[] test IDs being run (for status tracking)
function M.execute(adapter, spec, test_ids)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomtest: overseer.nvim not found", vim.log.levels.ERROR)
        return
    end

    local loomtest = require("loomtest")

    -- Mark tests as running
    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if node then
            node.status = "running"
        end
    end

    -- Refresh explorer to show running state
    local explorer = require("loomtest.explorer")
    if explorer.is_open() then
        explorer.refresh()
    end

    -- Dispose previous test task
    if _last_task_id then
        local prev_task = nil
        pcall(function()
            for _, t in ipairs(overseer.list_tasks()) do
                if t.id == _last_task_id then
                    prev_task = t
                    break
                end
            end
        end)
        if prev_task and prev_task:is_complete() then
            prev_task:dispose()
        end
    end

    -- Create and start the task
    local task = overseer.new_task({
        name = "loomtest: " .. (spec.cmd[1] or "test"),
        cmd = spec.cmd,
        cwd = spec.cwd,
        env = spec.env,
        components = { "default" },
    })

    _last_task_id = task.id

    task:subscribe("on_complete", function(_, status)
        vim.schedule(function()
            -- Capture output
            local bufnr = task:get_bufnr()
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                _last_output = table.concat(lines, "\n")
            end

            -- Parse results
            if spec.output_path then
                local results = adapter.parse_results(spec.output_path)
                if results then
                    -- Attach output to results
                    for _, r in ipairs(results) do
                        if not r.output then
                            r.output = _last_output
                        end
                    end
                    loomtest.apply_results(results)
                end
            end

            -- Fallback: if no structured results, use exit code
            local any_result = false
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and node.status ~= "running" then
                    any_result = true
                    break
                end
            end
            if not any_result then
                local fallback_status = status == "SUCCESS" and "passed" or "failed"
                for _, id in ipairs(test_ids) do
                    local node = loomtest.get_node(id)
                    if node then
                        node.status = fallback_status
                    end
                end
            end

            -- Clear running status for any tests still marked running
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and node.status == "running" then
                    node.status = status == "SUCCESS" and "passed" or "failed"
                end
            end

            -- Update UI
            require("loomtest.signs").update_all()
            if explorer.is_open() then
                explorer.refresh()
            end
        end)
    end)

    task:start()
end

--- Get the output from the last test run.
--- @return string|nil
function M.last_output()
    return _last_output
end

--- Get the last task ID.
--- @return number|nil
function M.last_task_id()
    return _last_task_id
end

return M
