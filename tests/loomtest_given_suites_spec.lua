-- Step 5m part A (LOOMTEST.md §3, §3.1, §4.1): adapter-supplied suite nodes,
-- exact-id results and adapter-executed runs (`start`).

local loomtest = require("loomtest")
local explorer = require("loomtest.explorer")
local runner = require("loomtest.runner")

--- A view-shaped tree: opaque ids, an explicit suite.
local function given_tree()
    return {
        { id = "n1", name = "core_tests", type = "target", runnable = true },
        { id = "n2", name = "Math", type = "suite", parent = "n1", runnable = true },
        { id = "n3", name = "Add", type = "test", parent = "n2", runnable = true },
        { id = "n4", name = "Sub", type = "test", parent = "n2", runnable = true },
        { id = "n5", name = "Lone", type = "test", parent = "n1", runnable = true },
    }
end

describe("loomtest: adapter-supplied suites", function()
    before_each(function() loomtest.clear() end)
    after_each(function()
        loomtest.clear()
        loomtest.unregister_adapter("fake")
    end)

    it("a target with given suites is shown as given, never inferred", function()
        loomtest.set_nodes(given_tree())
        local grouped = explorer._build_grouped_nodes(loomtest.nodes())
        local ids, names = {}, {}
        for _, n in ipairs(grouped) do
            ids[#ids + 1] = n.id
            names[#names + 1] = n.name
        end
        assert.same({ "n1", "n2", "n3", "n4", "n5" }, ids)
        assert.same({ "core_tests", "Math", "Add", "Sub", "Lone" }, names)
        assert.equals(2, grouped[2]._test_count)
    end)

    it("inference is unchanged for a target without given suites", function()
        loomtest.set_nodes({
            { id = "target:t", name = "t", type = "target", runnable = true },
            { id = "test:S.B", name = "S.B", type = "test", parent = "target:t", runnable = true },
            { id = "test:S.A", name = "S.A", type = "test", parent = "target:t", runnable = true },
        })
        local grouped = explorer._build_grouped_nodes(loomtest.nodes())
        assert.equals("target:t::S", grouped[2].id)
        assert.is_true(grouped[2]._synthetic)
        assert.equals("B", grouped[3].name)
    end)

    it("results apply by exact id only, and propagate test → suite → target", function()
        loomtest.set_nodes(given_tree())
        loomtest.apply_results({
            { test_id = "n3", status = "passed" },
            { test_id = "n4", status = "failed", message = "boom" },
            -- A name-shaped id never matches with given suites.
            { test_id = "test:Lone", status = "failed" },
        })
        assert.equals("passed", loomtest.get_node("n3").status)
        assert.equals("failed", loomtest.get_node("n4").status)
        assert.is_nil(loomtest.get_node("n5").status)
        assert.equals("failed", loomtest.get_node("n2").status)
        assert.equals("failed", loomtest.get_node("n1").status)
    end)

    it("name matching still applies without given suites", function()
        loomtest.set_nodes({
            { id = "test:S.A", name = "S.A", type = "test", runnable = true },
        })
        loomtest.apply_results({ { test_id = "test:S.A", status = "passed" } })
        assert.equals("passed", loomtest.get_node("test:S.A").status)
    end)

    it("descendant_tests covers a suite's and a target's cases", function()
        loomtest.set_nodes(given_tree())
        assert.same({ "n3", "n4" }, loomtest.descendant_tests("n2"))
        assert.same({ "n3", "n4", "n5" }, loomtest.descendant_tests("n1"))
    end)
end)

describe("loomtest: adapter-executed runs (start)", function()
    local started, sink, cancelled
    local function adapter()
        started, sink, cancelled = nil, nil, false
        return {
            name = "fake",
            description = function() return "dev" end,
            discover = function() return nil end,
            discover_async = function(cb) cb(nil) end,
            run = function() error("run must not be called with start") end,
            run_all = function() error("run_all must not be called with start") end,
            run_suite = function() error("run_suite must not be called with start") end,
            ensure_built = function() error("ensure_built must not be called with start") end,
            parse_results = function() error("parse_results must not be called with start") end,
            invalidate = function() end,
            get_cursor_test = function() return nil end,
            start = function(selection, opts, s)
                started = { selection = selection, opts = opts }
                sink = s
                return { cancel = function() cancelled = true end }
            end,
        }
    end

    before_each(function()
        loomtest.clear()
        loomtest.register_adapter(adapter())
        loomtest.set_nodes(given_tree())
    end)
    after_each(function()
        loomtest.unregister_adapter("fake")
        loomtest.clear()
    end)

    it("a suite runs as one start with its id; statuses come from the sink", function()
        loomtest.run("n2")
        assert.same({ "n2" }, started.selection)
        assert.is_false(started.opts.no_build)
        sink.status({ { id = "n3", status = "queued" }, { id = "n4", status = "queued" } })
        assert.equals("queued", loomtest.get_node("n3").status)
        sink.status({ { id = "n3", status = "passed", duration = 4 }, { id = "n4", status = "running" } })
        assert.equals("passed", loomtest.get_node("n3").status)
        assert.equals(4, loomtest.get_node("n3").duration)
        assert.is_true(runner.cancel())
        assert.is_true(cancelled)
        sink.done(true)
        -- A covered node left running had no result.
        assert.is_nil(loomtest.get_node("n4").status)
        assert.equals("passed", loomtest.get_node("n3").status)
        assert.is_false(runner.cancel())
    end)

    it("run-all selects nothing; no-build passes no_build", function()
        loomtest.run_all_no_build()
        assert.is_nil(started.selection)
        assert.is_true(started.opts.no_build)
        sink.done(false, "build failed")
    end)

    it("a test and a target each run with their own id", function()
        loomtest.run("n5")
        assert.same({ "n5" }, started.selection)
        sink.done(true)
        loomtest.run("n1")
        assert.same({ "n1" }, started.selection)
        sink.done(true)
    end)
end)
