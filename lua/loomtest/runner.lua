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
    -- Several RunSpecs (an adapter's run-all over several test units): run
    -- them one after another, building once before the first.
    if type(spec) == "table" and spec.cmd == nil and type(spec[1]) == "table" then
        local specs = spec
        local function run_from(i, o)
            if not specs[i] then return end
            M.execute(adapter, specs[i], test_ids, vim.tbl_extend("force", o, {
                on_done = function() run_from(i + 1, vim.tbl_extend("force", o, { skip_build = true })) end,
            }))
        end
        run_from(1, opts)
        return
    end
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomtest: overseer.nvim not found", vim.log.levels.ERROR)
        return
    end

    local loomtest = require("loomtest")
    local explorer = require("loomtest.explorer")

    clear_stale_tests(test_ids, loomtest)

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
            M._execute_task(adapter, spec, test_ids, loomtest, explorer, opts.on_done)
        end)
        return
    end

    M._execute_task(adapter, spec, test_ids, loomtest, explorer, opts.on_done)
end

--- Run a RunSpec's own preparation (e.g. a saved launch entry's deploy)
--- when its step executes, before its program. On failure (`false, err` or
--- an error raised) the step's node is marked failed, its cases that were
--- pending are cleared (they never ran), and the caller must not run it.
--- @return boolean ok
local function prepare_spec(spec, test_ids, loomtest, explorer)
    if type(spec.prepare) ~= "function" then return true end
    local ok, pok, perr = pcall(spec.prepare)
    if ok and pok then return true end
    local msg = tostring((ok and perr) or (not ok and pok) or "preparation failed")
    vim.notify("loomtest: " .. msg, vim.log.levels.ERROR)
    if spec.test_id then
        for _, id in ipairs(test_ids) do
            local node = loomtest.get_node(id)
            if node and node.parent == spec.test_id and node.status == "pending" then node.status = nil end
        end
        loomtest.apply_results({ { test_id = spec.test_id, status = "failed", message = msg } })
    end
    if explorer.is_open() then explorer.refresh() end
    return false
end

--- Internal: execute the overseer task (after build if needed).
--- `on_done` (optional) runs after the results were applied.
function M._execute_task(adapter, spec, test_ids, loomtest, explorer, on_done)
    -- The spec's own preparation (e.g. a saved launch entry's deploy) runs
    -- when the step executes; a failure fails this step without running its
    -- program, and the next spec still runs.
    if not prepare_spec(spec, test_ids, loomtest, explorer) then
        if on_done then on_done() end
        return
    end
    local overseer = require("overseer")
    fidget_update("0% ✔ 0")

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

    -- Wrap the cmd in nice/ionice so a long test run yields CPU/IO to
    -- the editor; resolve the display name from the original program
    -- name first so the wrapper binary doesn't leak into the title.
    local test_program = spec.cmd[1] or "test"
    local task_name = "loomtest: "
        .. (test_program:match("[/\\]([^/\\]+)$") or test_program)
    local wrapped_cmd = require("loomworks.nice").wrap_cmd(spec.cmd)
    local task = overseer.new_task({
        name = task_name,
        cmd = wrapped_cmd,
        cwd = spec.cwd,
        env = spec.env,
        components = {
            "on_exit_set_status",
            -- No "on_complete_notify" — suppresses success/failure notifications
        },
    })

    _last_task_id = task.id

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

        local batch_end = math.min(processed_lines + BATCH_SIZE, end_line)
        local lines = vim.api.nvim_buf_get_lines(output_bufnr, processed_lines, batch_end, false)
        processed_lines = batch_end

        for _, line in ipairs(lines) do
            process_line(line)
        end

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

        if has_more or not task_complete then
            vim.defer_fn(tick, TICK_MS)
        end
    end

    task:subscribe("on_start", function()
        output_bufnr = task:get_bufnr()
        vim.defer_fn(tick, TICK_MS)
    end)

    task:subscribe("on_complete", function()
        vim.schedule(function()
            task_complete = true

            while process_batch() do end

            local results
            if spec.output_path then
                results = adapter.parse_results(spec.output_path, spec)
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

            require("loomtest.signs").update_all()
            require("loomtest.inline").update_all()
            if explorer.is_open() then
                explorer.refresh()
            end

            fidget_update(format_progress(test_ids, loomtest), true)
            if on_done then on_done() end
        end)
    end)

    task:start()
end

--- Debug a test RunSpec via nvim-dap.
--- Falls back to execute() if nvim-dap is not available.
--- @param adapter loomtest.TestAdapter the adapter (for ensure_built)
--- @param spec loomtest.RunSpec the command to execute
--- @param test_ids string[] test IDs being debugged
--- @param opts? table { skip_build?: boolean }
function M.debug(adapter, spec, test_ids, opts)
    -- A debugger session runs one program: the first of several RunSpecs.
    if type(spec) == "table" and spec.cmd == nil and type(spec[1]) == "table" then
        spec = spec[1]
    end
    local debug_mod = require("loomworks.debug")
    if not debug_mod.available() then
        M.execute(adapter, spec, test_ids, opts)
        return
    end

    opts = opts or {}
    local loomtest = require("loomtest")
    local explorer = require("loomtest.explorer")

    local function start_debug()
        -- The spec's own preparation (a saved launch entry's deploy) first.
        if not prepare_spec(spec, test_ids, loomtest, explorer) then return end
        local lw = require("loomworks")
        local ws = lw.get_workspace()

        for _, id in ipairs(test_ids) do
            local node = loomtest.get_node(id)
            if node then
                node.status = "pending"
                node.message = nil
                node._output = nil
                node._errors = nil
            end
        end
        if explorer.is_open() then explorer.refresh() end
        require("loomtest.signs").update_all()

        -- spec.cmd is an array: first element is the program, rest are args
        local program = spec.cmd[1]
        local args = {}
        for i = 2, #spec.cmd do
            args[#args + 1] = spec.cmd[i]
        end

        local adapter_type = "codelldb"
        if ws then
            adapter_type = require("loomworks.debug_config").resolve_adapter(ws, "c++")
        end

        debug_mod.run({
            name = "Debug test",
            program = program,
            args = args,
            cwd = spec.cwd,
            env = spec.env,
            adapter = adapter_type,
        }, {
            on_terminated = function()
                vim.schedule(function()
                    if spec.output_path then
                        local results = adapter.parse_results(spec.output_path, spec)
                        if results then
                            loomtest.apply_results(results)
                        end
                    end

                    -- Tests still "pending" had no result
                    for _, id in ipairs(test_ids) do
                        local node = loomtest.get_node(id)
                        if node and (node.status == "pending" or node.status == "running") then
                            node.status = nil
                        end
                    end

                    _last_run_time = os.time()

                    require("loomtest.signs").update_all()
                    require("loomtest.inline").update_all()
                    if explorer.is_open() then explorer.refresh() end
                end)
            end,
        })
    end

    if adapter.ensure_built and not opts.skip_build then
        adapter.ensure_built(test_ids, function(ok)
            if not ok then
                vim.notify("loomtest: build failed, cannot debug test", vim.log.levels.ERROR)
                return
            end
            start_debug()
        end)
        return
    end

    start_debug()
end

--- @type loomtest.RunHandle|nil the running adapter-executed run's handle
local _active_handle = nil

--- Redraw what shows node statuses: the explorer, signs and inline marks.
local function redraw()
    vim.schedule(function()
        local explorer = require("loomtest.explorer")
        if explorer.is_open() then explorer.refresh() end
        require("loomtest.signs").update_all()
        require("loomtest.inline").update_all()
    end)
end

--- Apply node statuses by exact id (LOOMTEST.md §3: a sink's `status`, and
--- an adapter's statuses of a run it did not start — another client's) and
--- redraw. A changed status drops the node's loaded output (§8: read again
--- from the adapter's `result` when shown).
--- @param updates { id: string, status: string, duration?: number, message?: string }[]
function M.apply_status(updates)
    local loomtest = require("loomtest")
    for _, u in ipairs(updates or {}) do
        local node = type(u) == "table" and loomtest.get_node(u.id) or nil
        if node then
            node.status = u.status
            node.duration = u.duration
            node.message = u.message
            node._output, node._errors, node._result_loaded = nil, nil, nil
        end
    end
    redraw()
end

--- Run through the adapter's own execution (LOOMTEST.md §3 "Adapter-executed
--- runs", §5): `adapter.start` builds, runs and parses; loomtest shows the
--- statuses the adapter reports through the sink and the final state. The
--- staleness clearing (§5.3) and the progress line (§5.6) still apply;
--- nothing is streamed or parsed here.
--- @param adapter loomtest.TestAdapter an adapter with `start`
--- @param selection string[]|nil the selected node ids; nil runs all
--- @param test_ids string[] the test nodes the run covers (progress, staleness)
--- @param opts? table { skip_build?: boolean }
--- @return loomtest.RunHandle|nil
function M.start(adapter, selection, test_ids, opts)
    opts = opts or {}
    local loomtest = require("loomtest")

    clear_stale_tests(test_ids, loomtest)

    local finished = false
    local handle
    --- @type loomtest.RunSink
    local sink = {
        status = function(updates)
            M.apply_status(updates)
            if not finished then fidget_update(format_progress(test_ids, loomtest)) end
        end,
        done = function(ok, err)
            if finished then return end
            finished = true
            if _active_handle == handle then _active_handle = nil end
            -- A covered node left queued or running had no result.
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and (node.status == "queued" or node.status == "running") then
                    node.status = nil
                end
            end
            _last_run_time = os.time()
            if not ok then
                vim.schedule(function()
                    vim.notify("loomtest: " .. tostring(err or "test run failed"), vim.log.levels.ERROR)
                end)
            end
            fidget_update(format_progress(test_ids, loomtest), true)
            redraw()
        end,
    }

    fidget_update(opts.skip_build and "starting..." or "building...")
    handle = adapter.start(selection, { no_build = opts.skip_build == true }, sink)
    if not finished then _active_handle = handle end
    return handle
end

--- Debug through the adapter's own debug form (LOOMTEST.md §3, §13.1):
--- `adapter.debug_start` prepares, starts the debugger and reports the
--- results through the sink, as `start` does for a run. The covered tests
--- show pending meanwhile; one left pending or running had no result. A
--- failure is notified once, with the adapter's text (a `done(false)`
--- without one was already said by the adapter).
--- @param adapter loomtest.TestAdapter an adapter with `debug_start`
--- @param test_id string the node to debug
--- @param test_ids string[] the test nodes it covers
--- @return loomtest.RunHandle|nil
function M.start_debug(adapter, test_id, test_ids)
    local loomtest = require("loomtest")
    for _, id in ipairs(test_ids) do
        local node = loomtest.get_node(id)
        if node then
            node.status, node.message = "pending", nil
            node._output, node._errors, node._result_loaded = nil, nil, nil
        end
    end
    redraw()
    local finished = false
    local handle
    --- @type loomtest.RunSink
    local sink = {
        status = function(updates) M.apply_status(updates) end,
        done = function(ok, err)
            if finished then return end
            finished = true
            if _active_handle == handle then _active_handle = nil end
            for _, id in ipairs(test_ids) do
                local node = loomtest.get_node(id)
                if node and (node.status == "pending" or node.status == "queued" or node.status == "running") then
                    node.status = nil
                end
            end
            _last_run_time = os.time()
            if not ok and err then
                vim.schedule(function()
                    vim.notify("loomtest: " .. tostring(err), vim.log.levels.ERROR)
                end)
            end
            redraw()
        end,
    }
    handle = adapter.debug_start(test_id, sink)
    -- Its stop (`cancel`) is the run's, as a run's is.
    if not finished then _active_handle = handle end
    return handle
end

--- Cancel the running adapter-executed run, if any.
--- @return boolean cancelled
function M.cancel()
    local h = _active_handle
    if not h or type(h.cancel) ~= "function" then return false end
    h.cancel()
    return true
end

--- Get the last task ID.
--- @return number|nil
function M.last_task_id()
    return _last_task_id
end

--- Reset the last run time (e.g. on profile switch).
function M.reset_run_time()
    _last_run_time = nil
end

return M
