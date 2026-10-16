--- loomworks/loomtest_adapter.lua — loomtest adapter for loomworks.
---
--- Bridges loomworks tests to the loomtest TestAdapter interface, reading
--- them only through loomworks/test_source.lua (never the workspace model).
--- Registers on workspace load, re-registers on profile switch. One form per
--- runtime mode (LOOMTEST.md §13, §13.1):
---
---   * `in-process`: the RunSpec adapter over ConfigUnit/TestUnit (discovery,
---     commands, results parsing, `ensure_built`), unchanged until step 6b;
---   * `daemon` (step 5m C1, C2): the tree, unit states and last results
---     come only from the daemon's `loomworks.view.Tests/1`, a run's live
---     statuses from `Tests/1` `results` (any client's run); discovery is
---     `Tests/1.discover`, sent when the view is `stale` on the first ask or
---     while the explorer is open, and forced by the explorer's refresh;
---     `start` is one `Tests/1.run_cases`, `debug_start` a
---     `Tests/1.prepare_debug` → the debugger → `Tests/1.collect`, and
---     `result` reads `Tests/1.result`; `status` reports where the daemon's
---     tests stand (blocked: the tree empty, nothing done in-process).

local test_source = require("loomworks.test_source")

local M = {}

--- @type loomtest.TestAdapter|nil
local _adapter = nil

--- A tree entry as a loomtest node.
--- @param e table
--- @return loomtest.TestNode
local function to_node(e)
    return {
        id = e.id,
        name = e.name,
        type = e.parent and "test" or "target",
        parent = e.parent,
        file = e.file,
        line = e.line,
        runnable = e.runnable,
        status = e.status,
        message = e.message,
        duration = e.duration,
    }
end

--- The test at or above the cursor line in the buffer's file (client UI over
--- loomtest's nodes, both forms).
--- @param bufnr number
--- @param line number
--- @return string|nil
local function cursor_test(bufnr, line)
    local buf_path = vim.api.nvim_buf_get_name(bufnr)
    if buf_path == "" then return nil end

    local norm_path = buf_path:gsub("\\", "/"):lower()
    local loomtest = require("loomtest")

    -- Find test at or above cursor line in the same file
    local best_id = nil
    local best_line = 0
    for _, node in ipairs(loomtest.nodes()) do
        if node.file and node.file:gsub("\\", "/"):lower() == norm_path
            and node.line and node.line <= line and node.line > best_line
            and node.type == "test" then
            best_id = node.id
            best_line = node.line
        end
    end
    return best_id
end

-- ---------------------------------------------------------------------------
-- The daemon form (step 5m C1, LOOMTEST.md §13.1)
-- ---------------------------------------------------------------------------

--- The view's node kinds and statuses loomtest shows as given; any other is
--- shown neutral (a plain node, no status).
local KINDS = { target = true, suite = true, test = true }
local STATUSES = { passed = true, failed = true, skipped = true, errored = true, queued = true, running = true }

--- A unit's one node when it has no tree (§13.1): its label by state; the
--- view's message for `not_configured`, `foreign` and `error`.
local UNIT_LABELS = { no_tests = "no tests", pending = "not discovered yet" }

--- Whether the adapter asked for the tree since the daemon's view arrived
--- (its first ask discovers a `stale` view, §19.16 "Tests" Discovery).
local _asked = false
--- A `Tests/1.discover` the editor sent is in flight (single flight).
local _inflight = false
--- The adapter re-renders loomtest itself (M._render): that is not loomtest
--- asking for the tree, so it neither discovers nor counts as the first ask.
local _rendering = false
--- The view's `stale` as the last re-render saw it (nil: no view seen yet):
--- a re-render discovers on the turn to stale only, never on its level.
local _last_stale = nil
--- The view turned stale while the editor's discovery was in flight: looked
--- at again once that discovery succeeds.
local _stale_meanwhile = false
--- The editor's last discovery was cancelled, failed or refused: no automatic
--- discovery until the view turns stale again, the explorer opens or a
--- refresh forces one.
local _held = false
--- The editor's test run in progress (step 5m C2): loomtest's sink and the
--- owned call's handle (its `task_id` once accepted), so the run's own
--- `results` feed its sink (progress) and other runs' only the nodes.
--- `results` arriving before its `accepted` reply wait in `early` until the
--- reply says whose they are.
--- @type { sink: loomtest.RunSink, handle: table|nil, early: table[]|nil }|nil
local _run = nil

--- The daemon's tests view as loomtest nodes, or nil (none to show).
--- @param view loomworks.TestsView
--- @return loomtest.TestNode[]|nil
function M._view_nodes(view)
    local out = {}
    for _, u in ipairs(type(view.units) == "table" and view.units or {}) do
        if u.state == "ok" then
            for _, n in ipairs(type(u.nodes) == "table" and u.nodes or {}) do
                local kind = KINDS[n.kind] and n.kind or (n.parent and "test" or "target")
                out[#out + 1] = {
                    id = n.id,
                    name = n.name,
                    type = kind,
                    parent = n.parent,
                    file = n.file,
                    line = n.line,
                    runnable = n.runnable == true,
                    status = STATUSES[n.status] and n.status or nil,
                    message = n.message,
                    duration = n.duration,
                }
            end
        else
            local label = UNIT_LABELS[u.state] or u.message or tostring(u.state)
            out[#out + 1] = {
                id = "unit:" .. tostring(u.id or (tostring(u.project) .. "/" .. tostring(u.configuration))),
                name = string.format("%s (%s): %s", tostring(u.project), tostring(u.configuration), label),
                type = "target",
                runnable = false,
                status = u.state == "error" and "errored" or nil,
                message = u.message,
            }
        end
    end
    return #out > 0 and out or nil
end

--- Whether the test explorer is open.
--- @return boolean
local function explorer_open()
    local ok, explorer = pcall(require, "loomtest.explorer")
    return ok and explorer.is_open() or false
end

--- Send `Tests/1.discover` when the view needs it (§19.16 "Tests"
--- Discovery): `force` on the explorer's refresh, else only while it is
--- `stale`; never while a discovery runs (another client's included — its
--- `update` is waited for), while one the editor sent is in flight, or while
--- the tests are blocked. An automatic one (not `force`) is held off after
--- the editor's last discovery was cancelled, failed or refused.
--- @param force boolean
function M._discover(force)
    if force then _held = false end
    if _inflight or (not force and _held) then return end
    local st = test_source.daemon_status()
    if st and st.blocked then return end
    local view = test_source.daemon_view()
    if type(view) ~= "table" or view.discovering ~= nil then return end
    if not force and view.stale ~= true then return end
    _inflight, _stale_meanwhile = true, false
    local sent = test_source.daemon_discover(force, function(ok)
        _inflight = false
        _held = not ok
        -- A turn to stale it held off: one more look, after a success only.
        local again = ok and _stale_meanwhile
        _stale_meanwhile = false
        if again and explorer_open() then M._discover(false) end
    end)
    if not sent then _inflight = false end
end

--- Why a `Tests/1` call cannot be sent now: the tests' blocked status, else
--- a fixed line (never run in-process instead).
--- @param what string e.g. "run tests"
--- @return string
local function not_carried(what)
    local st = test_source.daemon_status()
    if st and st.blocked then return st.text end
    return "the workspace daemon cannot " .. what .. " now"
end

--- `TestCaseResult`s (the run's result, `results`, a `collect`) as sink
--- updates; an unknown status is shown neutral.
--- @param cases table[]|nil
--- @return { id: string, status: string|nil, duration: number|nil, message: string|nil }[]
function M._updates(cases)
    local out = {}
    for _, c in ipairs(type(cases) == "table" and cases or {}) do
        if type(c) == "table" and type(c.id) == "string" then
            out[#out + 1] = { id = c.id, status = STATUSES[c.status] and c.status or nil,
                duration = tonumber(c.duration), message = type(c.message) == "string" and c.message or nil }
        end
    end
    return out
end

--- Whether a run's end is only its failed tests (§19.16 "Tests" `run_cases`:
--- no error, or no `discovery_error` and at least one case failed or
--- errored): such an end is quiet, its failures the tree's.
--- @param done table the run's result (`cases`, `counts`, `discovery_error`)
--- @param err string|nil the task's error
--- @return boolean
local function only_failed_tests(done, err)
    if err == nil then return true end
    if done.discovery_error ~= nil then return false end
    local counts = type(done.counts) == "table" and done.counts or nil
    if counts then
        return (tonumber(counts.failed) or 0) + (tonumber(counts.errored) or 0) > 0
    end
    for _, c in ipairs(type(done.cases) == "table" and done.cases or {}) do
        if type(c) == "table" and (c.status == "failed" or c.status == "errored") then return true end
    end
    return false
end

--- Run nodes through the daemon (§19.16 "Tests" Runs, LOOMTEST.md §13.1):
--- one `Tests/1.run_cases` the editor owns (its overseer row's stop cancels
--- it). A run that ran shows its cases; it ends well when only its tests
--- failed — its failed tests are the tree's, its end the view's `update` —
--- anything else (a failed discovery included) ends the sink with why.
--- @param selection string[]|nil
--- @param opts { no_build: boolean }|nil
--- @param sink loomtest.RunSink
--- @return loomtest.RunHandle|nil
local function start_run(selection, opts, sink)
    local run = { sink = sink, early = {} }
    -- `results` that came before the reply: the run's to its sink, the
    -- rest to the nodes.
    local function flush()
        local early = run.early
        run.early = nil
        for _, d in ipairs(early or {}) do
            local updates = M._updates(d.cases)
            if run.handle and d.task_id ~= nil and run.handle.task_id == d.task_id then
                sink.status(updates)
            else
                require("loomtest.runner").apply_status(updates)
            end
        end
    end
    local function settle()
        flush()
        if _run == run then _run = nil end
    end
    local sent, handle = test_source.daemon_run(selection, { no_build = opts and opts.no_build or nil }, {
        accepted = flush,
        resolve = function(done, err)
            settle()
            if type(done.cases) == "table" then
                sink.status(M._updates(done.cases))
                if only_failed_tests(done, err) then return sink.done(true) end
                return sink.done(false, err)
            end
            sink.done(false, err or done.error or "the test run failed")
        end,
        reject = function(err)
            settle()
            sink.done(false, err)
        end,
    })
    if not sent then
        sink.done(false, not_carried("run tests"))
        vim.schedule(function() M._render() end)
        return nil
    end
    run.handle = handle
    if handle and handle.task_id ~= nil then run.early = nil end
    _run = run
    return {
        cancel = function()
            settle()
            if handle then handle:cancel() end
            sink.done(true)
        end,
    }
end

--- Debug one node through the daemon (§19.16 "Tests" Debug, LOOMTEST.md
--- §13.1): `Tests/1.prepare_debug` (an owned task building what its run
--- would), then the returned `debug` spec handed to the editor's debugger,
--- and `Tests/1.collect { prepared }` once the session ends. No language or
--- adapter is assumed: the adapter comes with the spec, so its installed
--- check is made here, after `done`; a missing one shows the install hint,
--- starts nothing and collects at once (dropping the token and its file).
--- @param test_id string
--- @param sink loomtest.RunSink
--- @return loomtest.RunHandle|nil
local function start_debug(test_id, sink)
    -- The started session's control (`stop`), once the debugger runs.
    local session
    local function collect(token, after)
        local sent = type(token) == "string" and test_source.daemon_collect(token, function(cases)
            if cases then sink.status(M._updates(cases)) end
            after()
        end)
        if not sent then after() end
    end
    local function launch(done)
        local d, token = done.debug, done.prepared
        local debug_mod = require("loomworks.debug")
        local primary = type(d) == "table" and type(d.adapters) == "table" and d.adapters[1] or nil
        if type(primary) ~= "table" or type(d.program) ~= "string" then
            return collect(token, function()
                sink.done(false, "the workspace daemon returned no debug launch")
            end)
        end
        if not debug_mod.adapter_installed(primary.adapter) then
            debug_mod.adapter_hint(primary.adapter, primary.language or d.language)
            return collect(token, function() sink.done(false) end)
        end
        local env = type(d.env) == "table" and next(d.env) and d.env or nil
        local name = type(d.name) == "string" and d.name or "Debug test"
        -- The one nvim-dap start of a prepared test (the program is the
        -- editor's, §19.16 "Tests" Debug): the launch and any attach.
        local function dap_start(spec, cbs) return debug_mod.run(spec, cbs) end
        local callbacks = {
            on_terminated = function()
                collect(token, function() sink.done(true) end)
            end,
        }
        -- The other debug languages attach to the program's process
        -- (§8.9.6 "Multi-adapter debugging").
        if #d.adapters > 1 then
            callbacks.on_pid = function(pid)
                for i = 2, #d.adapters do
                    local a = d.adapters[i]
                    if type(a) == "table" and a.adapter then
                        dap_start({ adapter = a.adapter, request = "attach", attach_pid = pid,
                            program = d.program, cwd = d.cwd, name = name .. " (" .. a.adapter .. ")" })
                    end
                end
            end
        end
        local started, ctl = dap_start({ name = name, program = d.program, args = d.args or {}, cwd = d.cwd,
            env = env, adapter = primary.adapter }, callbacks)
        session = started and ctl or nil
        if not started then
            collect(token, function() sink.done(false, "the debugger did not start") end)
        end
    end
    local sent, handle = test_source.daemon_prepare_debug(test_id, {
        resolve = function(done, err)
            if err then
                return collect(done.prepared, function() sink.done(false, err) end)
            end
            launch(done)
        end,
        reject = function(err) sink.done(false, err) end,
    })
    if not sent then
        sink.done(false, not_carried("debug tests"))
        return nil
    end
    -- Stopping it: the preparation cancelled, or once the debugger runs its
    -- session stopped — whose end then collects.
    return {
        cancel = function()
            if session then
                session.stop()
            elseif handle then
                handle:cancel()
            end
            sink.done(true)
        end,
    }
end

--- A node's output and error locations (`Tests/1.result`, §19.16 "Tests"
--- Output) as a loomtest result; nil when it cannot be read.
--- @param test_id string
--- @param callback fun(r: loomtest.TestResult|nil)
local function read_result(test_id, callback)
    local sent = test_source.daemon_result(test_id, function(r)
        if type(r) ~= "table" then return callback(nil) end
        local errors = {}
        for _, e in ipairs(type(r.errors) == "table" and r.errors or {}) do
            if type(e) == "table" then
                errors[#errors + 1] = { message = tostring(e.message or ""),
                    file = type(e.file) == "string" and e.file or nil, line = tonumber(e.line) }
            end
        end
        local output = type(r.output) == "string" and r.output or nil
        if output and r.truncated then output = "[… earlier output cut]\n" .. output end
        callback({ test_id = test_id, status = STATUSES[r.status] and r.status or nil,
            message = type(r.message) == "string" and r.message or nil, output = output, errors = errors,
            duration = tonumber(r.duration) })
    end)
    if not sent then callback(nil) end
end

--- The daemon form of the adapter.
--- @return loomtest.TestAdapter
local function create_daemon_adapter()
    local function nodes()
        local st = test_source.daemon_status()
        local view = test_source.daemon_view()
        if (st and st.blocked) or type(view) ~= "table" then return nil end
        if not _rendering then
            -- The first ask, or the explorer open: a stale view is discovered.
            if view.stale == true and (not _asked or explorer_open()) then M._discover(false) end
            _asked = true
        end
        return M._view_nodes(view)
    end
    return {
        name = "loomworks",
        _form = "daemon",

        description = function()
            local view = test_source.daemon_view()
            return type(view) == "table" and view.profile or nil
        end,

        status = function()
            return test_source.daemon_status()
        end,

        discover = function() return nodes() end,
        discover_async = function(callback) callback(nodes()) end,

        -- The explorer's refresh: a forced discovery.
        invalidate = function() M._discover(true) end,

        -- Runs, debug and output through `Tests/1` (step 5m C2); with `start`
        -- and `debug_start` given loomtest never asks for a RunSpec.
        start = start_run,
        debug_start = start_debug,
        result = read_result,
        run = function() return nil end,
        run_suite = function() return nil end,
        run_all = function() return nil end,
        parse_results = function() return nil end,

        get_cursor_test = cursor_test,
    }
end

--- Re-render loomtest from the daemon's view (an `update`, a cleared view,
--- the observer's state changed): the tree, its signs and inline marks;
--- cleared when there is nothing to show.
function M._render()
    if test_source.mode() ~= "daemon" then return end
    local ok, loomtest = pcall(require, "loomtest")
    if not ok then return end
    if not _adapter or _adapter._form ~= "daemon" then M.register() end
    local view = test_source.daemon_view()
    if type(view) ~= "table" then _asked, _last_stale, _held = false, nil, false end
    local st = test_source.daemon_status()
    local inline = require("loomtest.inline")
    if (st and st.blocked) or type(view) ~= "table" then inline.clear_all() end
    -- The view turned stale while the explorer is open: discover, once per
    -- turn (one in flight looks again when it ends).
    if type(view) == "table" then
        local turned = view.stale == true and _last_stale ~= true
        _last_stale = view.stale == true
        if turned and explorer_open() then
            _held = false
            if _inflight then _stale_meanwhile = true else M._discover(false) end
        end
    end
    _rendering = true
    local ok_d, err = pcall(loomtest.discover, function()
        inline.update_all()
    end)
    _rendering = false
    if not ok_d then error(err) end
end

local _render_pending = false
--- Coalesce re-renders: one per event-loop turn.
local function schedule_render()
    if _render_pending then return end
    _render_pending = true
    vim.schedule(function()
        _render_pending = false
        M._render()
    end)
end

-- ---------------------------------------------------------------------------
-- The in-process form (runtime.mode = "in-process", until step 6b)
-- ---------------------------------------------------------------------------

--- Create the in-process adapter from the current active profile.
--- @return loomtest.TestAdapter
local function create_adapter()
    return {
        name = "loomworks",

        description = function()
            return test_source.profile_key()
        end,

        discover = function()
            if not test_source.has_profile() then return nil end

            local all_nodes = {}
            local seen = {}
            for _, u in ipairs(test_source.units()) do
                local entries = test_source.discover(u.unit)
                if entries then
                    for _, e in ipairs(entries) do
                        if not seen[e.id] then
                            seen[e.id] = true
                            all_nodes[#all_nodes + 1] = to_node(e)
                        end
                    end
                end
            end
            return #all_nodes > 0 and all_nodes or nil
        end,

        discover_async = function(callback)
            if not test_source.has_profile() then
                callback(nil)
                return
            end

            local all_nodes = {}
            local seen = {}
            local units = test_source.units()
            if #units == 0 then
                callback(nil)
                return
            end

            -- Deliver ONE combined result (TestAdapter contract). A unit
            -- with a cached tree calls back synchronously, so `pending`
            -- starts at 1 (a sentinel for this loop) and is released after
            -- it; otherwise each cached unit would drive it to 0 and fire.
            local pending = 1
            local function finish()
                pending = pending - 1
                if pending == 0 then
                    callback(#all_nodes > 0 and all_nodes or nil)
                end
            end

            for _, u in ipairs(units) do
                pending = pending + 1
                test_source.discover_async(u.unit, function(entries)
                    if entries then
                        for _, e in ipairs(entries) do
                            if not seen[e.id] then
                                seen[e.id] = true
                                all_nodes[#all_nodes + 1] = to_node(e)
                            end
                        end
                    end
                    finish()
                end)
            end
            finish()
        end,

        --- Build the test target before running tests.
        --- Module-agnostic: the unit's module gives the build command
        --- (`test_source.build_spec`). Uses a plain overseer task (not the
        --- loomworks task tracker) to avoid invalidating the test cache.
        --- @param test_ids string[] test IDs to build for
        --- @param callback fun(ok: boolean)
        ensure_built = function(test_ids, callback)
            if not test_source.has_profile() then callback(false); return end

            -- The unit that owns the first id (spec §8.9.4), else the first
            -- unit; a per-target build when the test's executable matches a
            -- known build target of it.
            local unit, target_id = test_source.build_target_for(test_ids)
            if not unit then callback(false); return end

            local ok_o, overseer = pcall(require, "overseer")
            if not ok_o then callback(false); return end

            local spec = test_source.build_spec(unit, target_id)
            M._log_spec("ensure_built target=" .. tostring(target_id), unit, spec)
            if not spec or not spec.cmd then callback(false); return end

            local build_task = overseer.new_task({
                name = "loomtest build: " .. (target_id or "all"),
                cmd = spec.cmd,
                cwd = spec.cwd,
                env = spec.env,
                components = { "on_exit_set_status" },
            })
            build_task:subscribe("on_complete", function(_, status)
                vim.schedule(function()
                    callback(status == "SUCCESS")
                end)
            end)
            build_task:start()
        end,

        -- Owning-unit dispatch (spec §8.9.4): a single test, suite or target
        -- runs through the TestUnit that owns its id; the spec remembers that
        -- TestUnit so its results are parsed by it.
        run = function(test_id, opts)
            local unit = M._find_test_unit(test_id)
            if not unit then return nil end
            local spec, tu = test_source.command_for(unit, test_id, opts)
            if spec then spec._test_unit = tu end
            M._log_spec("run " .. test_id, unit, spec)
            return spec
        end,

        -- Run-all covers EVERY TestUnit of every ConfigUnit of the profile:
        -- one spec per TestUnit with `test_command_all`, one per runnable
        -- target of the saved-targets TestUnit. A single spec is returned as
        -- is; several as a list (loomtest runs them one after another).
        run_all = function(opts)
            if not test_source.has_profile() then return nil end

            local specs = {}
            for _, u in ipairs(test_source.units()) do
                for _, c in ipairs(test_source.commands_all(u.unit, opts)) do
                    local spec = c.cmd
                    spec._test_unit = c.tu
                    M._log_spec("run_all", u.unit, spec)
                    specs[#specs + 1] = spec
                end
            end
            if #specs == 0 then return nil end
            if #specs == 1 then return specs[1] end
            return specs
        end,

        run_suite = function(suite_id, opts)
            -- Suite ID format: "target_id::SuiteName"
            local suite_name = suite_id:match("::(.+)$")
            if not suite_name then return nil end

            -- The suite's target runs through the TestUnit that owns it, with
            -- GTEST_FILTER selecting the suite (works for add_test() and
            -- gtest_discover_tests() alike: the filter reaches the executable
            -- via env).
            local target_id = suite_id:match("^(.+)::") or ""
            -- A saved `launch:` entry keeps its kind; a bare id is a target.
            local id = target_id:match("^%a+:") and target_id or ("target:" .. target_id)
            local unit = M._find_test_unit(id)
            if not unit then return nil end
            local spec, tu = test_source.command_for(unit, id, { gtest_filter = suite_name .. ".*" })
            if spec then spec._test_unit = tu end
            return spec
        end,

        -- Results are parsed by the TestUnit that produced the run (§8.9.4).
        parse_results = function(output_path, spec)
            if spec and spec._test_unit then
                return test_source.parse_results(spec._test_unit, output_path)
            end
            if not test_source.has_profile() then return nil end
            return test_source.parse_results_any(output_path)
        end,

        invalidate = function()
            test_source.invalidate()
        end,

        get_cursor_test = cursor_test,
    }
end

--- Log a spec returned to loomtest. Writes to the loomworks log so
--- diagnostics for test launches and subsequent build calls line up in
--- a single file. env values are withheld; only keys are recorded.
--- @param label string caller context (e.g. "run test:Foo.Bar")
--- @param unit table|nil the configuration unit (a test source handle)
--- @param spec table|nil
function M._log_spec(label, unit, spec)
    local log = unit and test_source.log() or nil
    if not log then return end
    if not spec then
        log:warn("loomtest spec %s: nil", label)
        return
    end
    local env_keys = {}
    if type(spec.env) == "table" then
        for k in pairs(spec.env) do env_keys[#env_keys + 1] = k end
        table.sort(env_keys)
    end
    log:debug("loomtest spec %s: cmd=%s cwd=%s env_keys=[%s] output_path=%s",
        label,
        vim.inspect(spec.cmd),
        tostring(spec.cwd),
        table.concat(env_keys, ","),
        tostring(spec.output_path))
end

--- The unit whose TestUnit owns `test_id`, or nil — never a fallback guess
--- (spec §8.9.4).
--- @param test_id string
--- @return table|nil
function M._owning_test_unit(test_id)
    return test_source.owning_unit(test_id)
end

--- Find the unit (and its TestUnit) that owns a test ID: the owning unit,
--- else the first unit with a TestUnit (its first TestUnit).
--- @param test_id string
--- @return table|nil, table|nil
function M._find_test_unit(test_id)
    return test_source.find_test_unit(test_id)
end

--- Register the loomworks adapter with loomtest, in the form of the current
--- runtime mode. Called on workspace load and profile switch.
function M.register()
    local ok, loomtest = pcall(require, "loomtest")
    if not ok then return end

    _adapter = test_source.mode() == "daemon" and create_daemon_adapter() or create_adapter()
    loomtest.register_adapter(_adapter)
end

--- Test seam: forget the daemon form's state.
function M._reset()
    _adapter, _asked, _inflight, _rendering = nil, false, false, false
    _last_stale, _stale_meanwhile, _held, _run = nil, false, false, nil
end

--- The event listeners the last `setup` registered (`{ event, fn }`).
local _listeners = {}

--- Set up event listeners for automatic registration. Idempotent: a repeated
--- call replaces the listeners of the previous one rather than adding more.
function M.setup()
    local loomworks = require("loomworks")
    for _, l in ipairs(_listeners) do loomworks.off(l[1], l[2]) end
    _listeners = {}
    local lw = {
        on = function(event, fn)
            loomworks.on(event, fn)
            _listeners[#_listeners + 1] = { event, fn }
        end,
    }

    lw.on("workspace_changed", function(ws)
        if ws then
            vim.defer_fn(M.register, 500)
        end
    end)

    lw.on("active_set_changed", function()
        vim.defer_fn(function()
            -- Daemon mode: the view follows the profile itself (it turns
            -- stale); nothing is invalidated in-process.
            if test_source.mode() == "daemon" then return M._render() end
            M.register()
            local ok, loomtest = pcall(require, "loomtest")
            if ok then
                require("loomtest.inline").clear_all()
                loomtest.refresh()
            end
        end, 200)
    end)

    -- Refresh after a build completes. A first build typically runs
    -- right after configure, and configure has already triggered a
    -- discovery that saw the meson test list before the binary was
    -- linked. The framework probe skipped that binary (ENOENT), so
    -- individual test cases aren't in the tree yet. When the build
    -- finishes, workspace emits `tests_invalidated`; re-running
    -- discovery then picks up the binary and probes it properly.
    lw.on("tests_invalidated", function()
        if test_source.mode() == "daemon" then return end
        vim.defer_fn(function()
            local ok, loomtest = pcall(require, "loomtest")
            if ok then loomtest.refresh() end
        end, 100)
    end)

    -- Daemon mode (§19.16 "Tests"): the tree follows the daemon's view and
    -- where it stands; opening the explorer discovers a stale view.
    lw.on("daemon_view_changed", function(d)
        if type(d) == "table" and d.view ~= nil and d.view ~= "tests" then return end
        schedule_render()
    end)
    lw.on("daemon_runtime_changed", function() schedule_render() end)
    -- A run's per-case progress (§19.16 "Tests" Runs): the editor's own run
    -- feeds its sink (progress), another client's run or a collect only the
    -- nodes.
    lw.on("daemon_test_results", function(d)
        if test_source.mode() ~= "daemon" or type(d) ~= "table" then return end
        local run = _run
        if run and run.early then
            run.early[#run.early + 1] = d
            return
        end
        local updates = M._updates(d.cases)
        if run and d.task_id ~= nil and run.handle and run.handle.task_id == d.task_id then
            return run.sink.status(updates)
        end
        require("loomtest.runner").apply_status(updates)
    end)
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "loomtest",
        group = vim.api.nvim_create_augroup("loomworks_loomtest_daemon", { clear = true }),
        callback = function()
            if test_source.mode() == "daemon" then
                _held = false
                M._discover(false)
            end
        end,
    })

    if test_source.mode() == "daemon" or test_source.ready() then
        M.register()
    end
end

return M
