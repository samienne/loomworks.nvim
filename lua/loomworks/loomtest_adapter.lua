--- loomworks/loomtest_adapter.lua — loomtest adapter for loomworks.
---
--- Bridges loomworks ConfigUnit/TestUnit to the loomtest TestAdapter
--- interface. Registers on workspace load, re-registers on profile switch.

local M = {}

--- @type loomtest.TestAdapter|nil
local _adapter = nil

--- Create the adapter from the current active profile.
--- @return loomtest.TestAdapter
local function create_adapter()
    return {
        name = "loomworks",

        description = function()
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if profile then
                return profile.key
            end
            return nil
        end,

        discover = function()
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then return nil end

            local all_nodes = {}
            local seen = {}
            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    local entries = unit:discover_tests()
                    if entries then
                        for _, e in ipairs(entries) do
                            if not seen[e.id] then
                                seen[e.id] = true
                                all_nodes[#all_nodes + 1] = {
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
                        end
                    end
                end
            end
            return #all_nodes > 0 and all_nodes or nil
        end,

        discover_async = function(callback)
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then
                callback(nil)
                return
            end

            local all_nodes = {}
            local seen = {}
            local pending = 0
            local projects = profile:projects()
            if #projects == 0 then
                callback(nil)
                return
            end

            for _, pp in ipairs(projects) do
                local unit = pp._config_unit
                if unit then
                    pending = pending + 1
                    unit:discover_tests_async(function(entries)
                        if entries then
                            for _, e in ipairs(entries) do
                                if not seen[e.id] then
                                    seen[e.id] = true
                                    all_nodes[#all_nodes + 1] = {
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
                            end
                        end
                        pending = pending - 1
                        if pending == 0 then
                            callback(#all_nodes > 0 and all_nodes or nil)
                        end
                    end)
                end
            end
            if pending == 0 then
                callback(nil)
            end
        end,

        --- Build the test target before running tests.
        --- Module-agnostic: delegates to each project's module for the
        --- actual build command via `overseer.build_spec_for(unit, target_id)`.
        --- Uses a plain overseer task (not the loomworks task tracker)
        --- to avoid invalidating the test cache.
        --- @param test_ids string[] test IDs to build for
        --- @param callback fun(ok: boolean)
        ensure_built = function(test_ids, callback)
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then callback(false); return end

            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    -- Prefer a per-target build when the test's executable
                    -- matches a known build target on this unit.
                    local target_id = nil
                    if unit.targets and test_ids and #test_ids > 0 then
                        local tus = unit:test_units()
                        if #tus > 0 and tus[1]._entries then
                            for _, e in ipairs(tus[1]._entries) do
                                if e.id == test_ids[1] and e.executable then
                                    local exe_name = (e.executable:match("[/\\]([^/\\]+)$") or e.executable):gsub("%.exe$", "")
                                    local target_obj = unit.targets[exe_name]
                                    if target_obj then target_id = target_obj.id end
                                    break
                                end
                            end
                            if not target_id then
                                for _, e in ipairs(tus[1]._entries) do
                                    if e.executable and not e.parent then
                                        local exe_name = (e.executable:match("[/\\]([^/\\]+)$") or e.executable):gsub("%.exe$", "")
                                        local target_obj = unit.targets[exe_name]
                                        if target_obj then target_id = target_obj.id break end
                                    end
                                end
                            end
                        end
                    end

                    local ok_o, overseer = pcall(require, "overseer")
                    if not ok_o then callback(false); return end

                    local lw_overseer = require("loomworks.overseer")
                    local spec = lw_overseer.build_spec_for(unit, target_id)
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
                    return
                end
            end
            callback(false)
        end,

        run = function(test_id, opts)
            local unit, tu = M._find_test_unit(test_id)
            if not tu then return nil end
            return tu:test_command(test_id, opts)
        end,

        run_all = function(opts)
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then return nil end

            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    local tus = unit:test_units()
                    if #tus > 0 then
                        return tus[1]:test_command_all(opts)
                    end
                end
            end
            return nil
        end,

        run_suite = function(suite_id, opts)
            -- Suite ID format: "target_id::SuiteName"
            local suite_name = suite_id:match("::(.+)$")
            if not suite_name then return nil end

            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then return nil end

            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    local tus = unit:test_units()
                    if #tus > 0 then
                        -- Use GTEST_FILTER to run all tests in the suite.
                        -- This works for both add_test() and gtest_discover_tests()
                        -- because GTEST_FILTER is passed to the executable via env.
                        local target_id = suite_id:match("^(.+)::") or ""
                        local target_name = target_id:match("^target:(.+)$") or target_id
                        return tus[1]:test_command(
                            "target:" .. target_name,
                            { gtest_filter = suite_name .. ".*" }
                        )
                    end
                end
            end
            return nil
        end,

        parse_results = function(output_path)
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then return nil end

            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    local tus = unit:test_units()
                    for _, tu in ipairs(tus) do
                        local results = tu:parse_results(output_path)
                        if results then return results end
                    end
                end
            end
            return nil
        end,

        invalidate = function()
            local lw = require("loomworks")
            local profile = lw.get_active_profile()
            if not profile then return end

            for _, pp in ipairs(profile:projects()) do
                local unit = pp._config_unit
                if unit then
                    unit:invalidate_tests()
                end
            end
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

--- Find the TestUnit that owns a test ID.
--- @param test_id string
--- @return loomworks.ConfigUnit|nil, loomworks.TestUnit|nil
function M._find_test_unit(test_id)
    local lw = require("loomworks")
    local profile = lw.get_active_profile()
    if not profile then return nil, nil end

    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit then
            local tu = unit:_find_test_unit(test_id)
            if tu then return unit, tu end
        end
    end
    return nil, nil
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
                -- Clear old results and inline annotations
                require("loomtest.inline").clear_all()
                loomtest.refresh()
            end
        end, 200)
    end)

    -- Register immediately if workspace is already loaded
    if lw.get_workspace() and lw.get_active_profile() then
        M.register()
    end
end

return M
