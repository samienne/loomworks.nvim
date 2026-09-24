--- Staleness is judged against the PROFILE BEING BUILT, not the active one
--- (core §1.3.1 / §1.3.2 / §5.1). Regression: `lw profile set <p> <proj> cache
--- sccache` on a profile that is not the active one made every `lw build <p>`
--- reconfigure ("compiler launcher changed"): configure resolved the launcher
--- against <p>'s fill, but the staleness check re-resolved it against the
--- (absent) active profile. The same split hid a changed fill of an ordinary
--- variable used in an option — the options snapshot was taken without the
--- built profile's fill, so changing that fill never reconfigured.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local GCC_TOOL = {
    key = "ninja-gcc-13",
    data = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake" },
}

--- cmake project App/Debug (option FOO = "${warn}", blank variable `warn`),
--- profile `debug` on gcc + Ninja with the given fills, NOT active.
local function make_core(fills, active)
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local user = { profiles = { debug = {
        configuration_set = "debug",
        tools = { cmake = { key = GCC_TOOL.key, data = GCC_TOOL.data } },
    } } }
    if fills then user.profile_variables = { ["debug:ninja-gcc-13"] = { App = fills } } end
    if active then user.active_profile = "debug:ninja-gcc-13" end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = {
                variables = { warn = { type = "string" } },
                cmake = { configurations = { Debug = {
                    variant = "Debug", options = { FOO = "${warn}" },
                    env = { MY_WARN = "${warn}" },
                } } },
            } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json(user),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = GCC_TOOL.key, tool_data = GCC_TOOL.data, tool_label = GCC_TOOL.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    return ws, profile, profile:projects()[1]._config_unit, root
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, res = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(res))
    return res
end

local function configure_step(ws, profile)
    local steps = with_ws(ws, function() return overseer.plan_profile_build(profile) end)
    for _, s in ipairs(steps or {}) do if s.kind == "configure" then return s end end
end

local function has(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

describe("staleness against the profile being built", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        -- Only sccache "installed": gcc `auto` resolves it, a `cache=off` fill
        -- resolves none — so the two resolutions differ.
        cpp.lookup_path = function(n) return n == "sccache" and "/usr/bin/sccache" or nil end
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("a non-active profile's cache fill does not reconfigure every build", function()
        local ws, profile, unit, r = make_core({ warn = "-Wall", cache = "off" })
        root = r
        assert.is_nil(ws._active_profile)
        local first = configure_step(ws, profile)
        assert.is_not_nil(first)
        assert.equals("none", first.module_info.cache_launcher)
        require("loomworks.cli")._record_step(ws, first, true)

        assert.is_nil(unit:stale_reason(profile))
        assert.is_nil(configure_step(ws, profile))
        -- `lw profile show` reads the same status.
        local status = profile:compiler_cache_status()
        assert.is_false(status.stale)
        assert.equals("off", status.policy)
    end)

    it("the recorded options/env snapshot uses the built profile's fill", function()
        local ws, profile, unit, r = make_core({ warn = "-Wall" })
        root = r
        require("loomworks.cli")._record_step(ws, configure_step(ws, profile), true)
        assert.same({ FOO = "-Wall" }, unit._cached_options)
        assert.same({ MY_WARN = "-Wall" }, unit.module_info.configure_env)
        assert.is_nil(configure_step(ws, profile))

        -- Changing the (non-active) profile's fill makes its unit stale.
        profile._profile_variables.App.warn = "-Wextra"
        assert.equals("options changed (FOO changed)", unit:stale_reason(profile))
        local step = configure_step(ws, profile)
        assert.is_not_nil(step)
        assert.is_true(has(step.cmd, "--fresh"))
        assert.equals("options changed (FOO changed)", step.configure_reason)
    end)

    it("the active profile is still the default context", function()
        local ws, profile, unit, r = make_core({ warn = "-Wall", cache = "off" }, true)
        root = r
        assert.equals(profile, ws._active_profile)
        require("loomworks.cli")._record_step(ws, configure_step(ws, profile), true)
        assert.is_false(unit:is_stale())
        assert.is_false(unit:launcher_changed())
    end)
end)
