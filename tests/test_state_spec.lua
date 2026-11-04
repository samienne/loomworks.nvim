-- Step 5m part A: the host-neutral builder of `loomworks.view.Tests/1`
-- (spec daemon.md §19.13 "The tests view", ARCHITECTURE.md test_state.lua).

local test_state = require("loomworks.test_state")

--- A configuration unit as the builder reads it.
local function unit(opts)
    return {
        config_key = function() return opts.config or "Debug" end,
        test_availability = function() return opts.avail, opts.why end,
        test_tree = function() return opts.tree end,
    }
end

--- A loaded workspace whose active profile maps `units` ({ project, unit }).
local function ws(units, key)
    local pps = {}
    for _, u in ipairs(units) do
        pps[#pps + 1] = { _config_unit = u.unit, project_key = function() return u.project end }
    end
    return { root = "/w", _active_profile = { key = key or "dev", projects = function() return pps end } }
end

local GTEST_TREE = {
    { id = "target:core_tests", name = "core_tests", runnable = true, source = "ctest", executable = "/b/core_tests" },
    { id = "test:Math.Add", name = "Math.Add", parent = "target:core_tests", runnable = true, source = "gtest",
      file = "C:\\src\\math_test.cpp", line = 12, status = "passed", duration = 3.4 },
    { id = "test:Str.Len", name = "Str.Len", parent = "target:core_tests", runnable = true, source = "gtest",
      status = "failed", message = "Expected 4" },
    { id = "test:Math.Sub", name = "Math.Sub", parent = "target:core_tests", runnable = true, source = "gtest" },
    { id = "target:smoke", name = "smoke", runnable = true, source = "ctest" },
}

describe("test_state (view.Tests/1 builder)", function()
    it("an unloaded workspace: the given state, no units", function()
        assert.same({ state = "unloaded", stale = false, units = {} }, test_state.state(nil))
        assert.same({ state = "error", stale = false, units = {} }, test_state.state(nil, { state = "error" }))
    end)

    it("no active profile: loaded, no profile, no units", function()
        local v = test_state.state({ root = "/w" })
        assert.same({ state = "loaded", stale = false, units = {} }, v)
    end)

    it("explicit suites, unit-scoped local keys, parents first, results and sources", function()
        local u = unit({ tree = GTEST_TREE })
        local v = test_state.state(ws({ { project = "App", unit = u } }))
        assert.equals("loaded", v.state)
        assert.equals("dev", v.profile)
        assert.is_false(v.stale)
        assert.is_nil(v.profile_id)
        assert.equals(1, #v.units)
        local rec = v.units[1]
        assert.equals("App", rec.project)
        assert.equals("Debug", rec.configuration)
        assert.equals("ok", rec.state)
        assert.is_nil(rec.id)

        local kinds, names, by_name = {}, {}, {}
        for _, n in ipairs(rec.nodes) do
            kinds[#kinds + 1] = n.kind
            names[#names + 1] = n.name
            by_name[n.kind .. ":" .. n.name] = n
        end
        assert.same({ "target", "suite", "test", "suite", "test", "test", "target" }, kinds)
        assert.same({ "core_tests", "Math", "Add", "Str", "Len", "Sub", "smoke" }, names)

        local target, math_s, add = by_name["target:core_tests"], by_name["suite:Math"], by_name["test:Add"]
        assert.is_nil(target.parent)
        assert.equals(target.id, math_s.parent)
        assert.equals(math_s.id, add.parent)
        assert.equals(math_s.id, by_name["test:Sub"].parent)
        assert.equals(test_state.local_key("App", "Debug", "test:Math.Add"), add.id)
        assert.equals(test_state.suite_key("App", "Debug", "target:core_tests", "Math"), math_s.id)
        assert.is_true(math_s.runnable)
        assert.equals("gtest", math_s.source)
        assert.equals("ctest", target.source)
        -- Location `/`-separated; last results as the entries carry them.
        assert.equals("C:/src/math_test.cpp", add.file)
        assert.equals(12, add.line)
        assert.equals("passed", add.status)
        assert.equals(3, add.duration)
        assert.equals("failed", by_name["test:Len"].status)
        assert.equals("Expected 4", by_name["test:Len"].message)
        assert.is_nil(by_name["test:Sub"].status)
        -- Every id unique within the unit.
        local seen = {}
        for _, n in ipairs(rec.nodes) do
            assert.is_nil(seen[n.id], n.id)
            seen[n.id] = true
        end
    end)

    it("the same Suite.Case in two projects is two nodes; units in project-key order", function()
        local tree = { GTEST_TREE[1], GTEST_TREE[2] }
        local v = test_state.state(ws({
            { project = "Zeta", unit = unit({ tree = tree }) },
            { project = "Alpha", unit = unit({ tree = tree }) },
        }))
        assert.same({ "Alpha", "Zeta" }, { v.units[1].project, v.units[2].project })
        local a, z = v.units[1].nodes[3], v.units[2].nodes[3]
        assert.equals("Add", a.name)
        assert.equals("Add", z.name)
        assert.are_not.equal(a.id, z.id)
    end)

    it("unit states: not_configured / foreign / no_tests (with message), pending, error", function()
        local v = test_state.state(ws({
            { project = "A", unit = unit({ avail = "not_configured", why = "not configured on this machine" }) },
            { project = "B", unit = unit({ avail = "foreign", why = "its kit builds for ohos" }) },
            { project = "C", unit = unit({ avail = "no_tests" }) },
            { project = "D", unit = unit({}) },
        }))
        local st = {}
        for _, u in ipairs(v.units) do
            st[#st + 1] = u.state
            assert.same({}, u.nodes)
        end
        assert.same({ "not_configured", "foreign", "no_tests", "pending" }, st)
        assert.equals("not configured on this machine", v.units[1].message)
        assert.equals("its kit builds for ohos", v.units[2].message)
        assert.is_nil(v.units[3].message)
        -- A pending unit makes the view stale unless the caller says otherwise.
        assert.is_true(v.stale)

        local e = test_state.state(ws({ { project = "E", unit = unit({}) } }), {
            stale = false,
            tree_of = function() return nil, "error", "probe failed: boom" end,
        })
        assert.is_false(e.stale)
        assert.equals("error", e.units[1].state)
        assert.equals("probe failed: boom", e.units[1].message)
    end)

    it("the id provider, unit/profile ids and result_of (the daemon's hooks)", function()
        local u = unit({ tree = { GTEST_TREE[1], GTEST_TREE[2] } })
        local w = ws({ { project = "App", unit = u } })
        local issued, n = {}, 0
        local v = test_state.state(w, {
            id = function(obj) return obj == u and "unit-1" or "prof-1" end,
            node_id = function(owner, key)
                assert.equals(u, owner)
                if not issued[key] then n = n + 1; issued[key] = "n" .. n end
                return issued[key]
            end,
            result_of = function(_, key)
                if key == test_state.local_key("App", "Debug", "test:Math.Add") then
                    return { status = "running" }
                end
            end,
            discovering = "task-7",
        })
        assert.equals("prof-1", v.profile_id)
        assert.equals("unit-1", v.units[1].id)
        assert.equals("task-7", v.discovering)
        local nodes = v.units[1].nodes
        assert.equals(3, n)
        for _, node in ipairs(nodes) do assert.truthy(node.id:match("^n%d$")) end
        assert.equals(issued[test_state.local_key("App", "Debug", "test:Math.Add")], nodes[3].id)
        assert.equals(nodes[2].id, nodes[3].parent)
        assert.equals(nodes[1].id, nodes[2].parent)
        assert.equals("running", nodes[3].status)
        -- Stable across rebuilds while the keys are.
        local again = test_state.state(w, { node_id = function(_, key) return issued[key] end })
        for i, node in ipairs(again.units[1].nodes) do assert.equals(nodes[i].id, node.id) end
    end)

    it("statuses outside the TestStatus enum are left out", function()
        local tree = { { id = "target:t", name = "t", runnable = true, status = "pending" } }
        local v = test_state.state(ws({ { project = "A", unit = unit({ tree = tree }) } }))
        assert.is_nil(v.units[1].nodes[1].status)
    end)
end)

describe("ConfigUnit:test_availability (§19.13 unit states)", function()
    local ConfigUnit = require("loomworks.config_unit")

    local function cu(state, platform, impl)
        return setmetatable({
            state_value = state,
            tool_object = function()
                return platform and { execution_platform = function() return platform end } or nil
            end,
            _module_impl = function() return impl end,
            saved_test_targets = function() return nil end,
        }, { __index = ConfigUnit })
    end

    it("not configured here, a foreign kit, no TestUnit, else nil", function()
        local s, why = cu("unconfigured"):test_availability()
        assert.equals("not_configured", s)
        assert.truthy(why:find("not configured on this machine", 1, true))
        s, why = cu("built", "ohos"):test_availability()
        assert.equals("foreign", s)
        assert.truthy(why:find("ohos", 1, true))
        assert.equals("no_tests", (cu("built"):test_availability()))
        local impl = { create_test_unit = function() return { entries = function() return nil end } end }
        assert.is_nil((cu("configured", nil, impl):test_availability()))
    end)

    it("test_tree reads the cache and never discovers", function()
        local u = cu("built")
        assert.is_nil(u:test_tree())
        u._test_tree = { { id = "target:x" } }
        assert.equals("target:x", u:test_tree()[1].id)
    end)
end)
