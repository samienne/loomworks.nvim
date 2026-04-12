--- loomtest/runner.lua — Test execution via overseer.
---
--- Executes RunSpecs as overseer tasks. Streams gtest output for
--- real-time status with throttled batch processing. Parses gtest
--- XML on completion for authoritative results.

local M = {}

--- @type number|nil most recent test task ID
local _last_task_id = nil

--- @type number|nil timestamp (seconds) when tests last completed
local _last_run_time = nil

--- @type table|nil fidget progress handle
local _fidget_handle = nil

--- Clear status for tests whose source files changed since last run.
--- Tests without source file info are left unchanged.
--- @param test_ids string[] test IDs to check
--- @param loomtest table
--- @return number cleared count of tests cleared
local function clear_stale_tests(test_ids, loomtest)
    if not _last_run_time then return 0 end

    local uv = vim.uv or vim.loop
    -- Cache stat results per file (many tests share same file)
    local file_changed = {}
    local cleared = 0

    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if not node or not node.status then goto continue end

        local file = node.file
        if not file then goto continue end

        -- Check file mtime (cached per file)
        if file_changed[file] == nil then
            local stat = uv.fs_stat(file)
            if stat then
                file_changed[file] = stat.mtime.sec > _last_run_time
            else
                file_changed[file] = false
            end
        end

        if file_changed[file] then
            node.status = nil
            node.message = nil
            node.duration = nil
            node._output = nil
            node._errors = nil
            cleared = cleared + 1
        end

        ::continue::
    end

    return cleared
end

--- Format test progress: "✔ 590 ✗ 2 / 1323 (45%)"
--- @param test_ids string[]
--- @param loomtest table
--- @return string
local function format_progress(test_ids, loomtest)
    local p, f = 0, 0
    local total = #test_ids
    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if node then
            if node.status == "passed" then p = p + 1
            elseif node.status == "failed" then f = f + 1
            end
        end
    end
    local done = p + f
    local pct = total > 0 and math.floor(done / total * 100) or 0
    local msg = "✔ " .. p
    if f > 0 then msg = msg .. " ✗ " .. f end
    msg = msg .. " / " .. total .. " (" .. pct .. "%)"
    return msg
end

--- Create or update fidget progress.
--- @param message string
--- @param done? boolean
local function fidget_update(message, done)
    local ok, fidget_progress = pcall(function()
        return require("fidget.progress")
    end)
    if not ok or not fidget_progress then return end

    if done then
        if _fidget_handle then
            _fidget_handle.message = message
            _fidget_handle:finish()
            _fidget_handle = nil
        end
        return
    end

    if not _fidget_handle then
        pcall(function()
            _fidget_handle = fidget_progress.handle.create({
                title = "Tests",
                lsp_client = { name = "loomtest" },
            })
        end)
    end

    if _fidget_handle then
        _fidget_handle.message = message
    end
end

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
--- @param opts? table { skip_build?: boolean }
function M.execute(adapter, spec, test_ids, opts)
    opts = opts or {}
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomtest: overseer.nvim not found", vim.log.levels.ERROR)
        return
    end

    local loomtest = require("loomtest")
    local explorer = require("loomtest.explorer")

    -- Clear stale tests (source changed since last run)
    local stale_count = clear_stale_tests(test_ids, loomtest)

    -- Mark tests as pending, clear old results
    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if node then
            node.status = "pending"
            node.message = nil
            node._output = nil
            node._errors = nil
        end
    end

    if explorer.is_open() then
        explorer.refresh()
    end
    require("loomtest.signs").update_all()

    -- Auto-build if adapter supports it (unless skip_build is set)
    if adapter.ensure_built and not opts.skip_build then
        fidget_update("building...")
        adapter.ensure_built(test_ids, function(ok)
            if not ok then
                vim.notify("loomtest: build failed, cannot run tests", vim.log.levels.ERROR)
                for _, id in ipairs(test_ids) do
                    local node = loomtest.get_node(id)
                    if node then node.status = nil end
                end
                if explorer.is_open() then explorer.refresh() end
                fidget_update("build failed", true)
                return
            end
            M._execute_task(adapter, spec, test_ids, loomtest, explorer)
        end)
        return
    end

    M._execute_task(adapter, spec, test_ids, loomtest, explorer)
end

--- Internal: execute the overseer task (after build if needed).
function M._execute_task(adapter, spec, test_ids, loomtest, explorer)
    local overseer = require("overseer")
    fidget_update("0% ✔ 0")

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

    -- Create and start the task.
    -- Use minimal components to suppress overseer's default notifications.
    local task = overseer.new_task({
        name = "loomtest: " .. ((spec.cmd[1] or "test"):match("[/\\]([^/\\]+)$") or spec.cmd[1] or "test"),
        cmd = spec.cmd,
        cwd = spec.cwd,
        env = spec.env,
        components = {
            "on_exit_set_status",
            -- No "on_complete_notify" — suppresses success/failure notifications
        },
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
            require("loomtest.signs").update_all()
            require("loomtest.inline").update_all()
            if not task_complete then
                fidget_update(format_progress(test_ids, loomtest))
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

            -- Record completion time for staleness checks
            _last_run_time = os.time()

            -- Final UI update
            require("loomtest.signs").update_all()
            require("loomtest.inline").update_all()
            if explorer.is_open() then
                explorer.refresh()
            end

            fidget_update(format_progress(test_ids, loomtest), true)
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
