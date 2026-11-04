-- The discovery spawner seam (spec §8.9 `discover_async`, step 5m): a
-- caller's `system` reaches every TestUnit of the discovery and the gtest
-- probe, and is dropped again when the TestUnit's discovery ended.

local TestUnit = require("loomworks.test_unit")
local ConfigUnit = require("loomworks.config_unit")
local gtest = require("loomworks.gtest")

describe("TestUnit discovery spawner (§8.9 discover_async)", function()
    it("TestUnit.system uses the TestUnit's system, else the fallback", function()
        local seen = {}
        local function fake(name)
            return function(cmd) seen[#seen + 1] = name .. ":" .. cmd[1]; return {} end
        end
        TestUnit.system({ _system = fake("caller") }, { "a" }, {}, function() end, fake("fallback"))
        TestUnit.system({}, { "b" }, {}, function() end, fake("fallback"))
        assert.same({ "caller:a", "fallback:b" }, seen)
    end)

    it("gtest.probe spawns through opts.system", function()
        local got
        local done = false
        gtest.probe("/nonexistent/probe-exe", "target:x", { system = function(cmd, o, on_exit)
            got = { cmd = cmd, timeout = o.timeout }
            on_exit({ code = 1, stdout = "", stderr = "" })
            return {}
        end }, function(framework) done = framework == nil end)
        assert.truthy(vim.wait(2000, function() return done end))
        assert.same({ "/nonexistent/probe-exe", "--gtest_list_tests" }, got.cmd)
        assert.equals(gtest.PROBE_TIMEOUT_MS, got.timeout)
    end)

    it("ConfigUnit:discover_tests_async hands the caller's system to each TestUnit for its discovery", function()
        local during, after = {}, {}
        local tus = {}
        for i = 1, 2 do
            local tu = { is_saved_targets = false }
            function tu:discover_async(cb)
                during[i] = self._system
                vim.schedule(function() cb({ { id = "target:t" .. i, name = "t" .. i } }) end)
            end
            tus[i] = tu
        end
        local unit = setmetatable({ _check_saved_tests = function() end, test_units = function() return tus end },
            { __index = ConfigUnit })
        local sys = function() end
        local entries
        unit:discover_tests_async(function(e) entries = e end, { system = sys })
        assert.truthy(vim.wait(2000, function() return entries ~= nil end))
        for i = 1, 2 do after[i] = tus[i]._system end
        assert.same({ sys, sys }, during)
        assert.same({}, after)
        assert.equals(2, #entries)
    end)
end)
