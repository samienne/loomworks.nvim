--- overseer.plan_unit_build (spec §19.15 "Build scope of a launch"): the
--- daemon's target-scoped launch build plans ONE unit as a launch builds it
--- in-process. The plan builds the directory the runner locked (the unit's
--- build dir) and resolves against the REQUESTED profile, not the active one.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local function has_seq(cmd, seq)
    for i = 1, #cmd - #seq + 1 do
        local ok = true
        for j = 1, #seq do
            if cmd[i + j - 1] ~= seq[j] then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

--- cmake project App/Debug + profile `debug` (not activated), in a temp root.
local function make_core(tool)
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = { configurations = { Debug = { variant = "Debug" } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    return ws, ws._profiles[1], root
end

describe("overseer.plan_unit_build", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    local function setup()
        local ws, profile, r = make_core({ key = "ninja-gcc-13", data = {
            compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
        } })
        root = r
        local pp = profile:projects()[1]
        local unit = pp._config_unit
        assert.is_not_nil(unit)
        -- The build dir the runner locked: deliberately not the one cmake
        -- would derive from the configuration alone.
        unit.build_dir_value = root .. "/locked/App-Debug"
        unit.state_value = "built"
        return ws, profile, unit
    end

    it("builds a single target in the unit's locked build dir, for the requested profile", function()
        local ws, profile, unit = setup()
        assert.are_not.equal(profile, ws._active_profile)
        local steps, err = overseer.plan_unit_build(ws, unit, { target_id = "hello", profile = profile })
        assert.is_nil(err)
        assert.are.equal(1, #steps)
        local s = steps[1]
        assert.is_true(has_seq(s.cmd, { "--target", "hello" }), table.concat(s.cmd, " "))
        assert.is_true(has_seq(s.cmd, { "--build", unit:build_dir() }), table.concat(s.cmd, " "))
        assert.are.equal(unit:build_dir(), s.build_dir)
        assert.are.equal(profile, s.profile)
    end)

    it("plans a whole-unit build against the requested profile", function()
        local ws, profile, unit = setup()
        local steps, err = overseer.plan_unit_build(ws, unit, { profile = profile })
        assert.is_nil(err)
        assert.is_true(#steps >= 1)
        for _, s in ipairs(steps) do assert.are.equal(profile, s.profile) end
    end)
end)
