-- Step 5m part A: the test source the loomtest and neotest adapters read
-- instead of the workspace model (daemon.md §19.16 "Tests", LOOMTEST.md §13).

local test_source = require("loomworks.test_source")
local test_state = require("loomworks.test_state")

--- A configuration unit with recorded calls.
local function unit(name, opts)
    opts = opts or {}
    local u = { name = name, calls = {}, targets = opts.targets }
    u._test_tree = opts.tree
    function u:test_tree() return self._test_tree end
    function u:config_key() return "Debug" end
    function u:test_availability() return nil end
    function u:discover_tests()
        self.calls[#self.calls + 1] = "discover"
        self._test_tree = self._test_tree or opts.discovers
        return self._test_tree
    end
    function u:discover_tests_async(cb)
        self.calls[#self.calls + 1] = "discover_async"
        if opts.defer then self.pending_cb = cb else cb(opts.discovers) end
    end
    function u:invalidate_tests() self.calls[#self.calls + 1] = "invalidate"; self._test_tree = nil end
    function u:test_units() return opts.tus or {} end
    function u:_find_test_unit(id)
        for _, tu in ipairs(opts.tus or {}) do
            for _, e in ipairs(tu:entries() or {}) do if e.id == id then return tu end end
        end
        return (opts.tus or {})[1]
    end
    function u:_apply_test_results(r) self.applied = r end
    return u
end

local function tu(ids)
    local entries = {}
    for _, id in ipairs(ids) do entries[#entries + 1] = { id = id } end
    return { entries = function() return entries end }
end

--- A facade over a workspace whose active profile maps `pps`
--- ({ key, path, unit }); `extra` are projects outside the profile.
local function facade(pps, extra)
    local projects, list, by_key = {}, {}, {}
    local emitted = {}
    for _, p in ipairs(pps) do
        local project = { key = p.key, path = p.path }
        projects[#projects + 1] = project
        local pp = { _project = project, _config_unit = p.unit, project_key = function() return p.key end }
        list[#list + 1] = pp
        by_key[p.key] = pp
    end
    for _, p in ipairs(extra or {}) do projects[#projects + 1] = { key = p.key, path = p.path } end
    local profile = {
        key = "dev",
        projects = function() return list end,
        project = function(_, key) return by_key[key] end,
    }
    local ws = {
        root = "C:/w", _projects = projects, _active_profile = profile,
        _core = { _deps = { events = { emit = function(ev, arg) emitted[#emitted + 1] = { ev, arg } end } } },
    }
    return {
        get_workspace = function() return ws end,
        get_active_profile = function() return profile end,
    }, emitted
end

describe("test_source (in-process)", function()
    after_each(function() test_source._facade = nil end)

    it("nothing loaded: not ready, no units, unloaded view", function()
        test_source._facade = { get_workspace = function() return nil end, get_active_profile = function() return nil end }
        assert.is_false(test_source.ready())
        assert.is_false(test_source.has_profile())
        assert.is_nil(test_source.root())
        assert.same({}, test_source.units())
        assert.same({ state = "unloaded", stale = false, units = {} }, test_source.state())
    end)

    it("units in profile order with project key and directory", function()
        local a, b = unit("a"), unit("b")
        test_source._facade = facade({ { key = "App", path = "app", unit = a }, { key = "Root", path = ".", unit = b } })
        assert.is_true(test_source.ready())
        assert.equals("dev", test_source.profile_key())
        local units = test_source.units()
        assert.equals(2, #units)
        assert.equals(a, units[1].unit)
        assert.equals("App", units[1].project)
        assert.equals("C:/w/app", units[1].dir)
        assert.equals("C:/w", units[2].dir)
    end)

    it("unit_for_file: the longest project directory among all projects", function()
        local a, b = unit("a"), unit("b")
        test_source._facade = facade(
            { { key = "App", path = "app", unit = a }, { key = "Root", path = ".", unit = b } },
            { { key = "Lib", path = "app/lib" } })
        local u, key = test_source.unit_for_file("C:\\w\\app\\src\\x_test.cpp")
        assert.equals(a, u)
        assert.equals("App", key)
        assert.equals(b, (test_source.unit_for_file("C:/w/tools/t.cpp")))
        -- The best project is outside the profile: no unit (never a looser match).
        u, key = test_source.unit_for_file("C:/w/app/lib/l.cpp")
        assert.is_nil(u)
        assert.equals("Lib", key)
        -- A sibling with a shared prefix is not inside.
        assert.equals(b, (test_source.unit_for_file("C:/w/apple/a.cpp")))
    end)

    it("discovery, warm and invalidate go through the units", function()
        local cached = unit("c", { tree = { { id = "target:x" } } })
        local fresh = unit("f", { discovers = { { id = "target:y" } } })
        test_source._facade = facade({ { key = "A", path = "a", unit = cached }, { key = "B", path = "b", unit = fresh } })
        test_source.warm()
        assert.same({}, cached.calls)
        assert.same({ "discover_async" }, fresh.calls)
        test_source.warm(true)
        assert.same({ "discover_async", "discover" }, fresh.calls)
        assert.equals("target:y", test_source.cached_tree(fresh)[1].id)
        test_source.invalidate()
        assert.same({ "invalidate" }, cached.calls)
        assert.is_nil(test_source.cached_tree(cached))
    end)

    it("owner dispatch: the owning unit, else the first unit with a TestUnit", function()
        local t1, t2 = tu({ "target:A" }), tu({ "target:B" })
        local u1, u2 = unit("1", { tus = { t1 } }), unit("2", { tus = { t2 } })
        test_source._facade = facade({ { key = "A", path = "a", unit = u1 }, { key = "B", path = "b", unit = u2 } })
        assert.equals(u2, test_source.owning_unit("target:B"))
        assert.is_nil(test_source.owning_unit("target:C"))
        local u, t = test_source.find_test_unit("target:B")
        assert.equals(u2, u)
        assert.equals(t2, t)
        u, t = test_source.find_test_unit("target:C")
        assert.equals(u1, u)
        assert.equals(t1, t)
    end)

    it("build_target_for: the owner's target matching the test's executable", function()
        local tree = {
            { id = "target:core", executable = "/b/core_tests.exe" },
            { id = "test:S.C", parent = "target:core", executable = "/b/core_tests.exe" },
        }
        local owner = unit("o", { tree = tree, tus = { tu({ "test:S.C" }) },
            targets = { core_tests = { id = "core_tests_id" } } })
        local other = unit("x", { tus = { tu({ "target:z" }) } })
        test_source._facade = facade({ { key = "X", path = "x", unit = other }, { key = "O", path = "o", unit = owner } })
        local u, target = test_source.build_target_for({ "test:S.C" })
        assert.equals(owner, u)
        assert.equals("core_tests_id", target)
        -- No owner: the first unit, the whole unit.
        u, target = test_source.build_target_for({ "test:none" })
        assert.equals(other, u)
        assert.is_nil(target)
    end)

    it("apply_results records on the unit and emits test_results_changed", function()
        local u = unit("u")
        local f, emitted = facade({ { key = "A", path = "a", unit = u } })
        test_source._facade = f
        local res = { { test_id = "test:S.C", status = "passed" } }
        test_source.apply_results(u, res)
        assert.equals(res, u.applied)
        assert.same({ { "test_results_changed", u } }, emitted)
    end)

    it("state(): the view.Tests/1 shape from the in-process model (local keys)", function()
        local u = unit("u", { tree = {
            { id = "target:t", name = "t", runnable = true },
            { id = "test:S.C", name = "S.C", parent = "target:t", runnable = true },
        } })
        test_source._facade = facade({ { key = "App", path = "app", unit = u } })
        local v = test_source.state()
        assert.equals("loaded", v.state)
        assert.equals("dev", v.profile)
        assert.equals("ok", v.units[1].state)
        local kinds = {}
        for _, n in ipairs(v.units[1].nodes) do kinds[#kinds + 1] = n.kind end
        assert.same({ "target", "suite", "test" }, kinds)
        assert.equals(test_state.local_key("App", "Debug", "test:S.C"), v.units[1].nodes[3].id)
    end)
end)

describe("loomtest adapter reads through the test source", function()
    after_each(function()
        test_source._facade = nil
        package.loaded["loomworks.loomtest_adapter"] = nil
    end)

    it("discovery merges the units' trees (ids deduplicated) as before", function()
        local u1 = unit("1", { defer = true, discovers = {
            { id = "target:t", name = "t", runnable = true },
            { id = "test:S.C", name = "S.C", parent = "target:t", runnable = true, status = "passed" },
        } })
        local u2 = unit("2", { defer = true, discovers = { { id = "target:t", name = "t", runnable = true } } })
        test_source._facade = facade({ { key = "A", path = "a", unit = u1 }, { key = "B", path = "b", unit = u2 } })
        package.loaded["loomworks.loomtest_adapter"] = nil
        local captured
        local saved = package.loaded["loomtest"]
        package.loaded["loomtest"] = { register_adapter = function(a) captured = a end }
        require("loomworks.loomtest_adapter").register()
        package.loaded["loomtest"] = saved
        assert.equals("dev", captured.description())
        local nodes
        captured.discover_async(function(n) nodes = n end)
        -- Discovery completes asynchronously, unit by unit.
        u1.pending_cb({
            { id = "target:t", name = "t", runnable = true },
            { id = "test:S.C", name = "S.C", parent = "target:t", runnable = true, status = "passed" },
        })
        assert.is_nil(nodes)
        u2.pending_cb({ { id = "target:t", name = "t", runnable = true } })
        assert.equals(2, #nodes)
        assert.same({ id = "test:S.C", name = "S.C", type = "test", parent = "target:t", runnable = true,
            status = "passed" }, nodes[2])
        assert.equals(2, #captured.discover())
    end)
end)
