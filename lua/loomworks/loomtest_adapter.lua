--- loomworks/loomtest_adapter.lua — loomtest adapter for loomworks.
---
--- Bridges loomworks ConfigUnit/TestUnit to the loomtest TestAdapter
--- interface, reading them only through loomworks/test_source.lua (never the
--- workspace model). Registers on workspace load, re-registers on profile
--- switch.

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

--- Create the adapter from the current active profile.
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
            local pending = 0
            local units = test_source.units()
            if #units == 0 then
                callback(nil)
                return
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
                    pending = pending - 1
                    if pending == 0 then
                        callback(#all_nodes > 0 and all_nodes or nil)
                    end
                end)
            end
            if pending == 0 then
                callback(nil)
            end
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

        get_cursor_test = function(bufnr, line)
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
        end,
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

--- Register the loomworks adapter with loomtest.
--- Called on workspace load and profile switch.
function M.register()
    local ok, loomtest = pcall(require, "loomtest")
    if not ok then return end

    _adapter = create_adapter()
    loomtest.register_adapter(_adapter)
end

--- Set up event listeners for automatic registration.
function M.setup()
    local lw = require("loomworks")

    lw.on("workspace_changed", function(ws)
        if ws then
            vim.defer_fn(M.register, 500)
        end
    end)

    lw.on("active_set_changed", function()
        vim.defer_fn(function()
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
        vim.defer_fn(function()
            local ok, loomtest = pcall(require, "loomtest")
            if ok then loomtest.refresh() end
        end, 100)
    end)

    if test_source.ready() then
        M.register()
    end
end

return M
