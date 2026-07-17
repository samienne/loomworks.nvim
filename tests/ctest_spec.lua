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
        run_env = function() return opts.run_env end,
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

-- ctest launches the test executables itself and, unlike `meson test`, does NOT
-- put the build tree's sibling DLL dirs on PATH. So run_command_all must carry
-- the unit's run environment (§8.7) or a DLL-dependent test fails in the loader
-- with 0xc0000135 on Windows. Caught by the multi-lib CLI e2e (scripts/ci).
describe("CTestUnit run environment (§8.7)", function()
    it("carries the config unit's run_env into the run command", function()
        local sentinel = { PATH = "/build/lib;/orig" }
        local tu = CTestUnit.new(stub_unit({
            build_dir = "/b", config_name = "Debug",
            configuration = { module_config = { variant = "Debug" } },
            run_env = sentinel,
        }))
        -- Bypass on-disk ctest-dir discovery for a pure unit test.
        tu._find_ctest_dir = function() return "/b/ctestdir" end
        tu._base_cmd = function() return { "ctest", "--test-dir", "/b/ctestdir" } end
        local spec = tu:run_command_all()
        assert.equals(sentinel, spec.env)
    end)
end)
