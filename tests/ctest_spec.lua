-- CTestUnit: the `-C` config passed to ctest must be the cmake BUILD TYPE
-- (module variant, e.g. "Debug"), not the loomworks configuration name
-- (`variant:Debug`). A multi-config generator (Visual Studio) builds into a
-- config dir named by the build type; passing the config name made ctest
-- report tests as "Not Run". Single-config generators (Ninja) ignore -C.

local CTestUnit = require("loomworks.test_units.ctest")

local function stub_unit(opts)
    return {
        build_dir = function() return opts.build_dir end,
        variant = function() return opts.config_name end,
        configuration = function() return opts.configuration end,
        _cached_module_config = opts.cached_module_config,
    }
end

describe("CTestUnit ctest -C configuration", function()
    it("uses the module build type (variant), not the config name", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "variant:Debug",
            configuration = { module_config = { variant = "Debug" } },
        }))
        assert.equals("Debug", tu._configuration)
    end)

    it("falls back to the cached module_config variant", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "variant:Release",
            configuration = nil,
            cached_module_config = { variant = "Release" },
        }))
        assert.equals("Release", tu._configuration)
    end)

    it("falls back to the config name when there is no module variant", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b",
            config_name = "Debug",
            configuration = { module_config = {} },
        }))
        assert.equals("Debug", tu._configuration)
    end)

    it("reports run_command_all_rebuilds() false (ctest does not build)", function()
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b", config_name = "Debug",
            configuration = { module_config = { variant = "Debug" } },
        }))
        assert.is_false(tu:run_command_all_rebuilds())
    end)
end)
