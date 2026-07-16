local MesonTestUnit = require("loomworks.test_units.meson")
local meson = require("loomworks.modules.meson")

--- Paths reported by `meson introspect --tests` get normalized by the
--- test unit: on Windows forward slashes become backslashes. Assertions
--- that key into `_exec_specs` need the same transform so the fixtures
--- remain portable across OSes.
local function norm(p)
    if vim.fn.has("win32") ~= 1 then return p end
    return (p:gsub("/", "\\"))
end

--- Minimal stub ConfigUnit for MesonTestUnit construction.
local function stub_config_unit(build_dir)
    return {
        _tool_data = { meson = { "/usr/bin/meson" } },
        build_dir = function() return build_dir end,
        variant = function() return "Debug" end,
    }
end

--- Test fixture: a fake `meson introspect --tests` JSON.
--- Two tests, one named "Suite.TestA" (gtest-style) + one "basic".
local SAMPLE_JSON = [[
[
  {
    "name": "basic",
    "suite": ["project"],
    "cmd": ["/build/test_basic"],
    "workdir": "/src",
    "env": {"HELLO": "world"},
    "timeout": 30,
    "protocol": "exitcode"
  },
  {
    "name": "GTestSuite.MyTest",
    "suite": ["project"],
    "cmd": ["/build/test_gtest"],
    "workdir": "/src",
    "env": {},
    "timeout": 30
  }
]
]]

describe("meson test integration", function()
    describe("meson module.create_test_unit", function()
        it("returns nil when no build dir is resolved", function()
            local unit = stub_config_unit(nil)
            assert.is_nil(meson.create_test_unit(unit))
        end)

        it("returns a MesonTestUnit when build_dir is available", function()
            local unit = stub_config_unit("/build/App/Debug")
            local tu = meson.create_test_unit(unit)
            assert.is_not_nil(tu)
            assert.equals("/build/App/Debug", tu._build_dir)
        end)
    end)

    describe("run_command_all (native `meson test` runner, §8.9.2)", function()
        it("builds `meson test --print-errorlogs -C <build_dir>`", function()
            local tu = meson.create_test_unit(stub_config_unit("/build/App/Debug"))
            local spec = tu:run_command_all()
            assert.is_not_nil(spec)
            assert.same(
                { "/usr/bin/meson", "test", "--print-errorlogs", "-C", "/build/App/Debug" },
                spec.cmd)
            assert.equals("/build/App/Debug", spec.cwd)
        end)

        it("appends a filter as a test-name argument", function()
            local tu = meson.create_test_unit(stub_config_unit("/build/App/Debug"))
            local spec = tu:run_command_all({ filter = "MyTest" })
            assert.same(
                { "/usr/bin/meson", "test", "--print-errorlogs", "-C", "/build/App/Debug", "MyTest" },
                spec.cmd)
        end)
    end)

    describe("parse_meson_tests (via discovery shape)", function()
        -- We can't directly test the private parser, but we can assert
        -- that a MesonTestUnit initialized with a known JSON produces
        -- the expected entries by using the sync discover path with a
        -- stubbed `vim.system`.
        local orig_system
        before_each(function()
            orig_system = vim.system
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.system = function(_cmd, _opts)
                return {
                    wait = function()
                        return { code = 0, stdout = SAMPLE_JSON }
                    end,
                }
            end
        end)
        after_each(function()
            vim.system = orig_system
        end)

        it("emits a target:+test: pair for gtest-style names", function()
            -- Stub gtest.probe_sync to avoid actually spawning the executable
            local gtest = require("loomworks.gtest")
            local orig_probe = gtest.probe_sync
            ---@diagnostic disable-next-line: duplicate-set-field
            gtest.probe_sync = function() return nil, nil end

            local unit = stub_config_unit("/build/App/Debug")
            local tu = meson.create_test_unit(unit)
            local entries = tu:discover()
            assert.is_not_nil(entries)

            local ids = {}
            for _, e in ipairs(entries) do ids[e.id] = e end
            assert.is_not_nil(ids["target:test_gtest"])
            assert.is_not_nil(ids["test:GTestSuite.MyTest"])
            assert.is_not_nil(ids["target:basic"])
            assert.equals("gtest", ids["test:GTestSuite.MyTest"].framework)

            gtest.probe_sync = orig_probe
        end)

        it("treats JSON null workdir as nil (vim.NIL must not leak)", function()
            local gtest = require("loomworks.gtest")
            local orig_probe = gtest.probe_sync
            ---@diagnostic disable-next-line: duplicate-set-field
            gtest.probe_sync = function() return nil, nil end

            local json_null_workdir = [[
[
  {
    "name": "basic",
    "suite": ["project"],
    "cmd": ["/build/test_basic"],
    "workdir": null,
    "env": null,
    "timeout": null
  }
]
]]
            local orig_system = vim.system
            ---@diagnostic disable-next-line: duplicate-set-field
            vim.system = function(_cmd, _opts)
                return { wait = function() return { code = 0, stdout = json_null_workdir } end }
            end

            local unit = stub_config_unit("/build/App/Debug")
            local tu = meson.create_test_unit(unit)
            tu:discover()

            local spec = tu._exec_specs[norm("/build/test_basic")]
            assert.is_not_nil(spec)
            assert.is_nil(spec.cwd, "cwd must be Lua nil when JSON workdir is null")
            assert.are.same({}, spec.env, "env must be empty table when JSON env is null")
            assert.is_nil(spec.timeout)

            vim.system = orig_system
            gtest.probe_sync = orig_probe
        end)

        it("captures workdir and env as exec_spec for each executable", function()
            local gtest = require("loomworks.gtest")
            local orig_probe = gtest.probe_sync
            ---@diagnostic disable-next-line: duplicate-set-field
            gtest.probe_sync = function() return nil, nil end

            local unit = stub_config_unit("/build/App/Debug")
            local tu = meson.create_test_unit(unit)
            tu:discover()

            local spec = tu._exec_specs[norm("/build/test_basic")]
            assert.is_not_nil(spec)
            assert.equals(norm("/src"), spec.cwd)
            assert.equals("world", spec.env.HELLO)
            assert.equals(30, spec.timeout)

            gtest.probe_sync = orig_probe
        end)
    end)
end)
