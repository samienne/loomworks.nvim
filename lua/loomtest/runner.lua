--- loomtest/runner.lua — Test execution via overseer.
---
--- Executes RunSpecs as overseer tasks. Parses gtest XML on
--- completion for test results.

local M = {}

--- @type number|nil most recent test task ID
local _last_task_id = nil

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
    local explorer = require("loomtest.explorer")

    -- Mark tests as pending
    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if node then
            node.status = "pending"
        end
    end

    if explorer.is_open() then
        explorer.refresh()
    end

    -- Dispose previous test task
    if _last_task_id then
        pcall(function()
            for _, t in ipairs(overseer.list_tasks()) do
                if t.id == _last_task_id and t:is_complete() then
                    t:dispose()
                    break
                end
            end
        end)
    end

    -- Create and start the task
    local task = overseer.new_task({
        name = "loomtest: " .. ((spec.cmd[1] or "test"):match("[/\\]([^/\\]+)$") or spec.cmd[1] or "test"),
        cmd = spec.cmd,
        cwd = spec.cwd,
        env = spec.env,
        components = { "default" },
    })

    _last_task_id = task.id

    task:subscribe("on_complete", function()
        vim.schedule(function()
            -- Parse gtest XML for results
            local results
            if spec.output_path then
                results = adapter.parse_results(spec.output_path)
            end

            if results then
                loomtest.apply_results(results)
            end

            -- Tests still "pending" had no result
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and node.status == "pending" then
                    node.status = nil
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

--- Get the last task ID.
--- @return number|nil
function M.last_task_id()
    return _last_task_id
end

return M
