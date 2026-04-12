--- loomtest/runner.lua — Test execution via overseer.
---
--- Executes RunSpecs as overseer tasks. Streams gtest output for
--- real-time status with throttled batch processing. Parses gtest
--- XML on completion for authoritative results.

local M = {}

--- @type number|nil most recent test task ID
local _last_task_id = nil

--- Batch size: max lines to process per tick
local BATCH_SIZE = 20
--- Processing interval in ms
local TICK_MS = 50
--- Explorer refresh interval: refresh at most every N ticks
local REFRESH_EVERY = 5  -- 5 * 50ms = 250ms

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

    -- Streaming state
    local output_bufnr = nil
    local processed_lines = 0
    local task_complete = false
    local ticks_since_refresh = 0
    local dirty = false  -- true if nodes changed since last refresh

    --- Process a single gtest output line.
    local function process_line(line)
        -- [ RUN      ] Suite.Test
        local run_name = line:match("%[%s*RUN%s*%]%s*(.+)")
        if run_name then
            local name = run_name:match("^(.-)%s*%[") or run_name
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then
                local node = loomtest.get_node("test:" .. name)
                if node then
                    node.status = "running"
                    dirty = true
                end
            end
            return
        end

        -- [       OK ] Suite.Test (N ms)
        local ok_name = line:match("%[%s*OK%s*%]%s*(.+)")
        if ok_name then
            local name = ok_name:match("^%s*(.-)%s*%(") or ok_name:match("^%s*(.-)%s*$")
            if name and name ~= "" then
                local node = loomtest.get_node("test:" .. name)
                if node then
                    node.status = "passed"
                    dirty = true
                end
            end
            return
        end

        -- [  FAILED  ] Suite.Test (N ms)
        local fail_name = line:match("%[%s*FAILED%s*%]%s*(.+)")
        if fail_name then
            local name = fail_name:match("^%s*(.-)%s*%(") or fail_name:match("^%s*(.-)%s*$")
            if name and name ~= "" and not name:match("^%d+ test") then
                local node = loomtest.get_node("test:" .. name)
                if node then
                    node.status = "failed"
                    dirty = true
                end
            end
            return
        end
    end

    --- Process a batch of lines from the buffer.
    --- Returns true if there are more lines to process.
    local function process_batch()
        if not output_bufnr or not vim.api.nvim_buf_is_valid(output_bufnr) then
            return false
        end

        local line_count = vim.api.nvim_buf_line_count(output_bufnr)
        -- Skip last line (might be incomplete) unless task is done
        local end_line = task_complete and line_count or math.max(processed_lines, line_count - 1)
        if end_line <= processed_lines then return false end

        -- Read a batch
        local batch_end = math.min(processed_lines + BATCH_SIZE, end_line)
        local lines = vim.api.nvim_buf_get_lines(output_bufnr, processed_lines, batch_end, false)
        processed_lines = batch_end

        for _, line in ipairs(lines) do
            process_line(line)
        end

        -- More lines available?
        return batch_end < end_line
    end

    --- Tick: process a batch and optionally refresh UI.
    local function tick()
        local has_more = process_batch()

        ticks_since_refresh = ticks_since_refresh + 1
        if dirty and (ticks_since_refresh >= REFRESH_EVERY or not has_more) then
            ticks_since_refresh = 0
            dirty = false
            if explorer.is_open() then
                explorer.refresh()
            end
        end

        -- Schedule next tick if task is running or there are unprocessed lines
        if has_more or not task_complete then
            vim.defer_fn(tick, TICK_MS)
        end
    end

    task:subscribe("on_start", function()
        output_bufnr = task:get_bufnr()
        -- Start the processing loop
        vim.defer_fn(tick, TICK_MS)
    end)

    task:subscribe("on_complete", function()
        vim.schedule(function()
            task_complete = true

            -- Process any remaining lines
            while process_batch() do end

            -- Parse gtest XML for authoritative results
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
                if node and (node.status == "pending" or node.status == "running") then
                    node.status = nil
                end
            end

            -- Final UI update
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
