--- Core side of the faithful reconfigure (core §5.1 / §8.1): the previous
--- configure record is handed back to the module (`recorded_module_info`,
--- `recorded_options`), plan steps carry the module record + the
--- `pre_configure_reset` list, the CLI records the module record, and core's
--- `Workspace:_pre_configure_reset` deletes only validated entries inside a
--- build directory within the workspace root (deletion safety).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

local function write(path, body)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w")); f:write(body or "x"); f:close()
end

local function exists(path)
    return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

local function make_core(root, get)
    local deps = h.make_test_deps({
        ["loomworks.json"] = h.make_config_json({ projects = {} }),
    }, { modules = { get = get or modules_get }, cache = { save = function() return true end } })
    -- Real recursive delete (the test-deps io mocks rm_rf as a no-op).
    deps.io.rm_rf = require("loomworks.io").rm_rf
    local core = Core.new(deps)
    core:setup({ root = root })
    return core
end

describe("Workspace:_pre_configure_reset (deletion safety)", function()
    local root, bd, ws
    before_each(function()
        root = (vim.fn.tempname():gsub("\\", "/"))
        bd = root .. "/.nvim/build/App/Debug"
        write(bd .. "/CMakeCache.txt", "cache")
        write(bd .. "/CMakeFiles/3.28/x.txt", "state")
        write(bd .. "/app.exe", "binary")
        write(bd .. "/meson-private/cmd_line.txt", "cmdline")
        ws = make_core(root):get_workspace()
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    it("removes the named file + directory, keeps build outputs, tolerates a missing entry", function()
        local ok, err = ws:_pre_configure_reset(bd, { "CMakeCache.txt", "CMakeFiles", "nope.txt" })
        assert.is_true(ok, err)
        assert.is_false(exists(bd .. "/CMakeCache.txt"))
        assert.is_false(exists(bd .. "/CMakeFiles"))
        assert.is_true(exists(bd .. "/app.exe"))
    end)

    it("removes a nested relative entry (meson's stored command line)", function()
        assert.is_true((ws:_pre_configure_reset(bd, { "meson-private/cmd_line.txt" })))
        assert.is_false(exists(bd .. "/meson-private/cmd_line.txt"))
        assert.is_true(exists(bd .. "/meson-private"))
    end)

    it("refuses a build directory outside the workspace root", function()
        local outside = (vim.fn.tempname():gsub("\\", "/"))
        write(outside .. "/CMakeCache.txt", "keep")
        local ok, err = ws:_pre_configure_reset(outside, { "CMakeCache.txt" })
        assert.is_false(ok)
        assert.matches("outside the workspace", err)
        assert.is_true(exists(outside .. "/CMakeCache.txt"))
        vim.fn.delete(outside, "rf")
    end)

    it("refuses a sibling whose path merely shares the root as a prefix", function()
        local sibling = root .. "-evil/build"
        write(sibling .. "/CMakeCache.txt", "keep")
        local ok = ws:_pre_configure_reset(sibling, { "CMakeCache.txt" })
        assert.is_false(ok)
        assert.is_true(exists(sibling .. "/CMakeCache.txt"))
        vim.fn.delete(root .. "-evil", "rf")
    end)

    it("refuses nil / empty build dirs", function()
        assert.is_false((ws:_pre_configure_reset(nil, { "CMakeCache.txt" })))
        assert.is_false((ws:_pre_configure_reset("", { "CMakeCache.txt" })))
    end)

    it("refuses traversal, absolute and empty-segment entries without deleting anything", function()
        for _, bad in ipairs({ "../Debug/CMakeCache.txt", "/etc/passwd", "C:/x", "a//b", "./CMakeCache.txt", "" }) do
            local ok = ws:_pre_configure_reset(bd, { bad })
            assert.is_false(ok, "accepted " .. bad)
        end
        assert.is_true(exists(bd .. "/CMakeCache.txt"))
    end)

    it("is a no-op for an empty list", function()
        assert.is_true((ws:_pre_configure_reset(nil, {})))
    end)
end)

describe("previous-configure record round trip (planner + CLI)", function()
    it("hands recorded_module_info/options back to the module and carries module_info + reset on plan steps", function()
        local seen
        local fake = {
            id = "fakemod", api_version = 1, has_keyed_tools = false, languages = { "c++" },
            resolve_build_dir = function(p, c, _, root) return root .. "/.nvim/build/" .. p .. "/" .. (c or "d") end,
            info = function(_, tc)
                local Configuration = require("loomworks.configuration")
                return { configurations = Configuration.canonicalize({}, tc and tc.configurations, "fakemod") }
            end,
            tasks = function(project, active)
                seen = project
                local function td(action)
                    return {
                        name = project.name .. ": " .. action,
                        builder = function() return { cmd = { "true" } } end,
                        loomworks = {
                            project_key = project.name, action = action,
                            configuration_key = project.configuration_key or active,
                            build_dir = project.cached_build_dir,
                            pre_configure_reset = action == "configure" and { "state.txt" } or nil,
                            module_info = action == "configure" and { passed_options = { FOO = "2" } } or nil,
                        },
                    }
                end
                return { td("configure"), td("build") }
            end,
        }
        local function get(id) if id == "fakemod" then return fake end return modules_get(id) end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { fakemod = { configurations = { Debug = { options = { FOO = "1" } } } } } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = { debug = { configuration_set = "debug", tools = {} } },
            }),
        }
        local deps = h.make_test_deps(files, { modules = { get = get }, cache = { save = function() return true end } })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        local ws = core:get_workspace()
        local profile = ws._profiles[1]
        local unit = profile:projects()[1]._config_unit

        -- The CLI's record path must pass the module record through (it used
        -- to drop module_info, so CLI configures never recorded a launcher).
        require("loomworks.cli")._record_step(ws, {
            kind = "configure", unit = unit, build_dir = unit:build_dir(),
            module_info = { cache_launcher = "none", passed_options = { FOO = "1" } },
        }, true)
        assert.same({ FOO = "1" }, unit.module_info.passed_options)
        assert.equals("none", unit.module_info.cache_launcher)

        -- Force a configure step (the unit is configured and not stale).
        unit._project.needs_refresh = true
        local loomworks = require("loomworks")
        local orig = loomworks.get_workspace
        loomworks.get_workspace = function() return ws end
        local ok, steps = pcall(overseer.plan_profile_build, profile)
        loomworks.get_workspace = orig
        assert.is_true(ok, tostring(steps))

        assert.same({ FOO = "1" }, seen.recorded_module_info.passed_options)
        assert.is_not_nil(seen.recorded_options)
        assert.equals(unit._cached_options, seen.recorded_options)
        local cfg_step
        for _, s in ipairs(steps) do if s.kind == "configure" then cfg_step = s end end
        assert.is_not_nil(cfg_step)
        assert.same({ "state.txt" }, cfg_step.pre_configure_reset)
        assert.same({ FOO = "2" }, cfg_step.module_info.passed_options)
    end)

    it("an option removed after configure makes the unit stale (gate reconfigures)", function()
        -- cache pinned off: this test is about options, and under `auto` a
        -- ccache/sccache on the host PATH would make launcher staleness fire.
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = { configurations = { Debug = {
                    options = { FOO = "1" }, variables = { cache = "off" },
                } } } } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
                configuration_set = "debug",
                tools = { cmake = { key = "ninja-gcc-12", data = { compiler_id = "gcc-12", generator = "Ninja" } } },
            } } }),
        }
        local deps = h.make_test_deps(files, { modules = { get = modules_get }, cache = { save = function() return true end } })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = { cmake = { {
            tool_key = "ninja-gcc-12", tool_data = { compiler_id = "gcc-12", generator = "Ninja" }, tool_label = "gcc",
        } } }
        core:remerge()
        local unit = core:get_workspace()._profiles[1]:projects()[1]._config_unit
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        assert.is_false(unit:is_stale())
        unit._configuration.options = {}
        assert.is_true(unit:is_stale())
    end)
end)

-- A configure REPLACES the unit's module-owned record (core §8.1): a key the
-- module stopped returning (meson's `cross_file` after `machine_file` is
-- dropped) must not survive from the previous configure, or every later
-- configure compares against the stale value and takes the full reconfigure
-- forever (regression: additive merge kept `cross_file`).
describe("configure record replacement (nil-can't-clear regression)", function()
    local meson = require("loomworks.modules.meson")

    local function make_unit()
        local fake = {
            id = "fakemod", api_version = 1, has_keyed_tools = false, languages = { "c++" },
            -- Stands in for meson's record (its tasks drive the classification).
            configure_record_version = meson.configure_record_version,
            resolve_build_dir = function(p, c, _, root) return root .. "/.nvim/build/" .. p .. "/" .. (c or "d") end,
            info = function(_, tc)
                local Configuration = require("loomworks.configuration")
                return { configurations = Configuration.canonicalize({}, tc and tc.configurations, "fakemod") }
            end,
            tasks = function() return {} end,
        }
        local function get(id) if id == "fakemod" then return fake end return modules_get(id) end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { fakemod = { configurations = { Debug = {} } } } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = { debug = { configuration_set = "debug", tools = {} } },
            }),
        }
        local deps = h.make_test_deps(files, { modules = { get = get }, cache = { save = function() return true end } })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        return core, core:get_workspace()._profiles[1]:projects()[1]._config_unit
    end

    local function meson_configure(unit, machine_file, build_dir)
        local cfg = { buildtype = "debug", machine_file = machine_file }
        for _, t in ipairs(meson.tasks({
            name = "App", path = "app", workspace_root = "/root",
            tool_data = { meson = { "/usr/bin/meson" } },
            configurations = { Debug = cfg }, env = {},
            cached_build_dir = build_dir,
            recorded_module_info = unit.module_info,
            recorded_cache_launcher = unit.module_info and unit.module_info.cache_launcher or nil,
        }, "Debug")) do
            if t.loomworks.action == "configure" then return t end
        end
    end

    local function is_full(t) return t.loomworks.pre_configure_reset ~= nil end

    it("removing machine_file takes exactly one full reconfigure, then the next is in place", function()
        local core, unit = make_unit()
        local build_dir = vim.fn.tempname()
        vim.fn.mkdir(build_dir .. "/meson-info", "p")
        local function record(t)
            core:record_task_result({ unit = unit, action = "configure", success = true,
                build_dir = build_dir, module_info = t.loomworks.module_info })
        end

        record(meson_configure(unit, "/x/cross.ini", build_dir))
        assert.equals("/x/cross.ini", unit.module_info.cross_file)
        assert.is_false(is_full(meson_configure(unit, "/x/cross.ini", build_dir)))

        -- Drop the cross file: one full reconfigure.
        local t = meson_configure(unit, nil, build_dir)
        assert.is_true(is_full(t))
        record(t)
        assert.is_nil(unit.module_info.cross_file)

        -- The next configure is NOT full.
        assert.is_false(is_full(meson_configure(unit, nil, build_dir)))
        vim.fn.delete(build_dir, "rf")
    end)

    it("a non-configure result merges (does not wipe the configure record)", function()
        local core, unit = make_unit()
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = "/root/.nvim/build/App/Debug",
            module_info = { passed_options = { A = "1" }, cache_launcher = "none" } })
        core:record_task_result({ unit = unit, action = "build", success = true,
            module_info = { extra = true } })
        core:record_task_result({ unit = unit, action = "build", success = true })
        assert.same({ A = "1" }, unit.module_info.passed_options)
        assert.equals("none", unit.module_info.cache_launcher)
        assert.is_true(unit.module_info.extra)
    end)
end)
