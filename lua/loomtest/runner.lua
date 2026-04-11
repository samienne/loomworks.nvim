--- loomtest/runner.lua — Test execution via overseer.
---
--- Executes RunSpecs as overseer tasks. Streams gtest output for
--- real-time status updates. Parses gtest XML on completion for
--- authoritative results with per-test output.

local M = {}

--- @type number|nil most recent test task ID
local _last_task_id = nil

--- @type string|nil current test being run (from [ RUN ] line)
local _current_test = nil

--- @type string[] output lines for the current test
local _current_output = {}

--- @type table<string, string[]> test_id → captured output lines
local _test_outputs = {}

--- Parse a gtest stdout line for real-time status tracking.
--- @param line string
--- @param loomtest table the loomtest module
--- @param explorer table the explorer module
local function parse_gtest_line(line, loomtest, explorer)
    -- [ RUN      ] Suite.Test
    local run_test = line:match("^%[%s*RUN%s*%] (.+)$")
    if run_test then
        -- Save previous test's output
        if _current_test and #_current_output > 0 then
            _test_outputs["test:" .. _current_test] = _current_output
        end
        _current_test = run_test:match("^%s*(.-)%s*$")
        _current_output = {}

        local node = loomtest.get_node("test:" .. _current_test)
        if node then
            node.status = "running"
            if explorer.is_open() then
                explorer.refresh()
            end
        end
        return
    end

    -- [       OK ] Suite.Test (N ms)
    local ok_test = line:match("^%[%s*OK%s*%] (.+)")
    if ok_test then
        local name = ok_test:match("^%s*(.-)%s*%(")
            or ok_test:match("^%s*(.-)%s*$")
        if name then
            -- Save output
            if _current_test and #_current_output > 0 then
                _test_outputs["test:" .. _current_test] = _current_output
            end
            local node = loomtest.get_node("test:" .. name)
            if node then
                node.status = "passed"
                if explorer.is_open() then
                    explorer.refresh()
                end
            end
            _current_test = nil
            _current_output = {}
        end
        return
    end

    -- [  FAILED  ] Suite.Test (N ms)
    local fail_test = line:match("^%[%s*FAILED%s*%] (.+)")
    if fail_test then
        local name = fail_test:match("^%s*(.-)%s*%(")
            or fail_test:match("^%s*(.-)%s*$")
        if name then
            if _current_test and #_current_output > 0 then
                _test_outputs["test:" .. _current_test] = _current_output
            end
            local node = loomtest.get_node("test:" .. name)
            if node then
                node.status = "failed"
                if explorer.is_open() then
                    explorer.refresh()
                end
            end
            _current_test = nil
            _current_output = {}
        end
        return
    end

    -- Capture output lines between RUN and OK/FAILED
    if _current_test then
        _current_output[#_current_output + 1] = line
    end
end

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

    -- Reset streaming state
    _current_test = nil
    _current_output = {}
    _test_outputs = {}

    -- Mark tests as pending (queued, not yet actively running)
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
        name = "loomtest: " .. (spec.cmd[1] or "test"):match("[/\\]([^/\\]+)$") or spec.cmd[1] or "test",
        cmd = spec.cmd,
        cwd = spec.cwd,
        env = spec.env,
        components = { "default" },
    })

    _last_task_id = task.id

    -- Stream output for real-time status updates.
    -- Watch the task buffer for new lines via autocmd.
    local last_line_count = 0
    local output_bufnr = nil

    task:subscribe("on_start", function()
        output_bufnr = task:get_bufnr()
        if output_bufnr and vim.api.nvim_buf_is_valid(output_bufnr) then
            vim.api.nvim_buf_attach(output_bufnr, false, {
                on_lines = function(_, buf, _, first, _, last)
                    if not vim.api.nvim_buf_is_valid(buf) then return true end
                    local new_lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
                    -- Defer parsing to avoid E565 (can't modify buffers
                    -- inside on_lines callback)
                    vim.schedule(function()
                        for _, line in ipairs(new_lines) do
                            parse_gtest_line(line, loomtest, explorer)
                        end
                    end)
                end,
            })
        end
    end)

    task:subscribe("on_complete", function()
        vim.schedule(function()
            -- Save last test's output
            if _current_test and #_current_output > 0 then
                _test_outputs["test:" .. _current_test] = _current_output
            end
            _current_test = nil

            -- Parse gtest XML for authoritative results + per-test details
            local results
            if spec.output_path then
                results = adapter.parse_results(spec.output_path)
            end

            if results then
                -- Attach streamed output to results
                for _, r in ipairs(results) do
                    if not r.output then
                        local captured = _test_outputs[r.test_id]
                        if captured then
                            r.output = table.concat(captured, "\n")
                        end
                    end
                end
                loomtest.apply_results(results)
            end

            -- Tests still "running" or "pending" after completion
            -- had no XML result — mark as unknown
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and (node.status == "running" or node.status == "pending") then
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
