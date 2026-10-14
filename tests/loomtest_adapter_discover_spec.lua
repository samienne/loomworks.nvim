-- loomtest adapter discovery across several units of the active profile.
--
-- Regression: when every unit already had a cached test tree, the adapter's
-- discover_async called back once per unit (synchronously) and then once more
-- with nil; loomtest.discover keeps only the first callback per adapter, so
-- the explorer showed only the first unit's tests.

local ConfigUnit = require("loomworks.config_unit")

describe("loomtest adapter: discover_async over several units", function()
    local lw = require("loomworks")
    local loomtest = require("loomtest")
    local orig_active

    before_each(function()
        orig_active = lw.get_active_profile
        loomtest.unregister_adapter("loomworks")
        loomtest.clear()
    end)
    after_each(function()
        lw.get_active_profile = orig_active
        loomtest.unregister_adapter("loomworks")
        loomtest.clear()
    end)

    --- A unit using the real ConfigUnit discovery path.
    --- @param tree table[]|nil cached test tree (nil = not cached)
    --- @param async_entries table[]|nil entries its TestUnit discovers later
    local function unit(tree, async_entries)
        return {
            _test_tree = tree,
            _check_saved_tests = function() end,
            test_units = function()
                return { {
                    discover_async = function(_, cb)
                        vim.schedule(function() cb(async_entries) end)
                    end,
                } }
            end,
            discover_tests_async = ConfigUnit.discover_tests_async,
        }
    end

    local function entries(target, test)
        return {
            { id = target, name = target, runnable = true },
            { id = target .. "::" .. test, name = test, parent = target, runnable = true },
        }
    end

    local function register(units)
        lw.get_active_profile = function()
            return { projects = function()
                local pps = {}
                for i, u in ipairs(units) do pps[i] = { _config_unit = u } end
                return pps
            end }
        end
        package.loaded["loomworks.loomtest_adapter"] = nil
        require("loomworks.loomtest_adapter").register()
    end

    local function discovered_ids()
        local done = false
        loomtest.discover(function() done = true end)
        vim.wait(2000, function() return done end, 10)
        assert.is_true(done)
        local ids = {}
        for _, n in ipairs(loomtest.nodes()) do ids[#ids + 1] = n.id end
        table.sort(ids)
        return ids
    end

    it("shows every unit's tests when all units have a cached tree", function()
        register({ unit(entries("target:A", "a1")), unit(entries("target:B", "b1")) })
        assert.same({ "target:A", "target:A::a1", "target:B", "target:B::b1" }, discovered_ids())
    end)

    it("calls back exactly once with the combined result (cached units)", function()
        register({ unit(entries("target:A", "a1")), unit(entries("target:B", "b1")) })
        local calls = {}
        loomtest.adapters()[1].discover_async(function(nodes) calls[#calls + 1] = nodes end)
        vim.wait(50)
        assert.equals(1, #calls)
        assert.equals(4, #calls[1])
    end)

    it("still combines asynchronously discovered units, once", function()
        register({ unit(nil, entries("target:A", "a1")), unit(nil, entries("target:B", "b1")) })
        local calls = {}
        loomtest.adapters()[1].discover_async(function(nodes) calls[#calls + 1] = nodes end)
        vim.wait(2000, function() return #calls > 0 end, 10)
        vim.wait(50)
        assert.equals(1, #calls)
        assert.equals(4, #calls[1])
    end)

    it("combines a cached unit with an asynchronously discovered one", function()
        register({ unit(entries("target:A", "a1")), unit(nil, entries("target:B", "b1")) })
        assert.same({ "target:A", "target:A::a1", "target:B", "target:B::b1" }, discovered_ids())
    end)

    it("calls back nil once when no unit has tests", function()
        register({ unit(nil, nil), unit(nil, nil) })
        local calls = {}
        loomtest.adapters()[1].discover_async(function(nodes) calls[#calls + 1] = { nodes } end)
        vim.wait(2000, function() return #calls > 0 end, 10)
        vim.wait(50)
        assert.equals(1, #calls)
        assert.is_nil(calls[1][1])
    end)
end)
