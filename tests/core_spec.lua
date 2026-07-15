local Core = require("loomworks.core")
local ConfigUnit = require("loomworks.config_unit")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

--- Find a ConfigurationSet by name from a core's registry.
--- @param core loomworks.Core
--- @param name string
--- @return loomworks.ConfigurationSet|nil
local function get_cs(core, name)
    return h.find_config_set_in(core:get_config_sets(), name)
end

--- Get or create a ConfigUnit from the workspace by project_key and config_key.
--- Falls back to ensure_config_unit when the unit does not yet exist in the registry.
--- If the project doesn't exist either, creates a bare ConfigUnit directly.
--- @param core loomworks.Core
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
local function get_unit(core, project_key, config_key)
    local ws = core._workspace
    -- Try to find by project_key + variant match first (property-based)
    local variant = config_key
    local colon = config_key:find(":")
    if colon then variant = config_key:sub(1, colon - 1) end
    for _, unit in pairs(ws._config_units) do
        if unit._init_project_key == project_key and unit._variant == variant then
            return unit
        end
    end
    -- Also try by build_dir key
    local bd_key = h.build_dir_key(project_key, variant)
    local unit = h.find_config_unit_by_id(ws._config_units, bd_key)
    if unit then return unit end
    local project = h.find_project_in(core:get_projects(), project_key)
    if not project then
        -- Project not in workspace — create bare ConfigUnit (test-only scenario)
        return h.ensure_config_unit_by_id(ws, bd_key, project_key)
    end
    local tool = nil
    if colon then
        local tool_key = config_key:sub(colon + 1)
        tool = ws:find_tool(project.type, tool_key)
        if not tool then
            tool = ws:get_or_create_tool(project.type, tool_key, {}, nil)
        end
    end
    local cfg = h.get_or_create_config(project, variant)
    return ws:ensure_config_unit(project, cfg, tool)
end

--- Create a Core with mocked deps and standard test files.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @param dep_overrides? table
--- @return loomworks.Core, table deps (with _events_log)
local function make_core(config_overrides, user_overrides, cache_overrides, dep_overrides)
    local files = {
        ["loomworks.json"] = h.make_config_json(config_overrides),
    }
    if user_overrides then
        files["loomworks.user.json"] = h.make_user_json(user_overrides)
    end
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end

    -- Auto-derive detect_tools_async from merge.detect_tools if available
    if dep_overrides and dep_overrides.merge and dep_overrides.merge.detect_tools
            and not dep_overrides.detect_tools_async then
        local sync_detect = dep_overrides.merge.detect_tools
        dep_overrides.detect_tools_async = function(config, cache, callback)
            callback(sync_detect(config, cache))
        end
    end

    local deps = h.make_test_deps(files, dep_overrides)
    local core = Core.new(deps)
    return core, deps
end

describe("Core", function()
    describe("setup", function()
        it("loads workspace successfully", function()
            local core = make_core()
            core:setup({ root = "/root" })
            assert.equals("initialized", core:state())
        end)

        it("fails when config file is missing", function()
            local deps = h.make_test_deps({}) -- no files
            local core = Core.new(deps)
            core:setup({ root = "/root" })
            assert.equals("uninitialized", core:state())
            assert.is_nil(core:get_workspace())
        end)

        it("emits workspace_changed and active_set_changed", function()
            local core, deps = make_core()
            core:setup({ root = "/root" })
            local events = deps._events_log
            local names = {}
            for _, e in ipairs(events) do
                names[#names + 1] = e.event
            end
            assert.is_not_nil(vim.tbl_contains(names, "workspace_changed"))
            assert.is_not_nil(vim.tbl_contains(names, "active_set_changed"))
        end)

    end)

    describe("remerge", function()
        it("is a no-op when no workspace", function()
            local core = make_core()
            -- Don't setup
            core:remerge()
            assert.is_nil(core:get_active_configuration_set())
        end)
    end)

    describe("ConfigurationSet:activate", function()
        it("activates existing profile without re-materializing", function()
            local cache_saves = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "production" },
                    },
                },
                nil,
                {
                    -- Both profiles already materialized
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                        release = {
                            configuration_set = "release",
                            configurations = { "App/production" },
                        },
                    },
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "configured",
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            cache_saves[#cache_saves + 1] = vim.deepcopy(data)
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            -- Record cache state after setup (no cache writes expected from setup
            -- since both profiles are already materialized and referenced)
            local saves_after_setup = #cache_saves

            -- Activate A
            get_cs(core, "debug"):activate()
            -- Activate B
            get_cs(core, "release"):activate()
            -- Return to A
            get_cs(core, "debug"):activate()

            -- No cache writes should have happened during profile switching
            assert.equals(saves_after_setup, #cache_saves,
                "switching between materialized profiles should not write to cache")
        end)

        it("is safe without workspace", function()
            local core = make_core()
            -- No config sets exist without workspace — test that accessing nil is safe
            assert.is_nil(get_cs(core, "debug"))
        end)
    end)

    describe("running tasks", function()
        it("has_running_tasks delegates to ConfigUnit registry", function()
            local core = make_core()
            core:setup({ root = "/root" })
            assert.is_false(core:has_running_tasks())
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(42, "build")
            assert.is_true(core:has_running_tasks())
            unit:unregister_task(42)
            assert.is_false(core:has_running_tasks())
        end)
    end)

    describe("record_task_result", function()
        it("records configure success", function()
            local saved_cache = nil
            local core = make_core(nil, nil, nil, {
                cache = {
                    save = function(root, data)
                        saved_cache = data
                        return true
                    end,
                },
            })
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                build_dir = "/root/.nvim/build/App/Debug",
            })
            assert.is_not_nil(saved_cache)
            local cached = saved_cache.build_dirs["build/App/Debug"]
            assert.is_not_nil(cached, "expected build_dirs entry for build/App/Debug")
            assert.equals("configured", cached.state)
            assert.is_not_nil(cached.last_configured)
        end)

        it("records build failure", function()
            local saved_cache = nil
            local core = make_core(nil, nil, nil, {
                cache = {
                    save = function(root, data)
                        saved_cache = data
                        return true
                    end,
                },
            })
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "build",
                success = false,
            })
            assert.is_not_nil(saved_cache)
            local cached = saved_cache.build_dirs["build/App/Debug"]
            assert.is_not_nil(cached, "expected build_dirs entry for build/App/Debug")
            assert.equals("failed_build", cached.state)
        end)
    end)


    describe("get_profiles", function()
        it("returns nil for unknown profile key", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })
            assert.is_nil(h.find_profile(core:get_profiles(), "nonexistent"))
        end)

        it("returns Profile object for known profile", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            assert.equals("debug", profile.key)
            assert.equals("debug", profile._configuration_set_name)
        end)

    end)

    describe("get_projects", function()
        it("returns Project for known project", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local proj = h.find_project_in(core:get_projects(), "App")
            assert.is_not_nil(proj)
            assert.equals("App", proj.key)
            assert.equals("cmake", proj.type)
        end)

    end)

    describe("project_for_buf", function()
        it("matches buffer to project by path prefix", function()
            local function test_normalize(p) return p:gsub("\\", "/") end
            local core = make_core(nil, nil, nil, {
                buf_name = function() return "/root/App/src/main.cpp" end,
                normalize = test_normalize,
            })
            core:setup({ root = "/root" })
            local proj = core:project_for_buf(1)
            assert.is_not_nil(proj)
            assert.equals("App", proj.key)
        end)

        it("picks innermost project for nested paths", function()
            local function test_normalize(p) return p:gsub("\\", "/") end
            local core = make_core({
                projects = {
                    Root = { cmake = {} },
                    ["Root/Sub"] = { cmake = {} },
                },
            }, nil, nil, {
                buf_name = function() return "/root/Root/Sub/src/file.cpp" end,
                normalize = test_normalize,
            })
            core:setup({ root = "/root" })
            local proj = core:project_for_buf(1)
            assert.is_not_nil(proj)
            assert.equals("Root/Sub", proj.key)
        end)

    end)

    describe("rescan_tools", function()
        local real_merge = require("loomworks.merge")

        --- Build a merge override that replaces detect_tools but keeps merge.merge.
        local function merge_with_mock_detect(detect_fn)
            return {
                detect_tools = detect_fn,
                merge = real_merge.merge,
                get_all_profiles = real_merge.get_all_profiles,
            }
        end

        it("updates tools_by_type from module detection", function()
            local mock_tools = {
                cmake = {
                    {
                        tool_data = { id = "ninja-gcc-12", display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                        tool_key = "ninja-gcc-12",
                        tool_label = "Ninja + GCC 12",
                    },
                },
            }
            local core = make_core(nil, nil, nil, {
                merge = merge_with_mock_detect(function() return mock_tools end),
                detect_tools_async = function(config, cache, callback) callback(mock_tools) end,
            })
            core:setup({ root = "/root" })

            core:rescan_tools()

            local tools = core:get_tools_by_type()
            assert.is_not_nil(tools.cmake)
            assert.equals(1, #tools.cmake)
            assert.equals("ninja-gcc-12", tools.cmake[1].tool_key)
            assert.equals("Ninja + GCC 12", tools.cmake[1].tool_label)
        end)

        it("does not error without workspace", function()
            local core = make_core(nil, nil, nil, {
                merge = merge_with_mock_detect(function() return {} end),
            })
            -- Do NOT call setup

            -- Should not raise
            assert.has_no.errors(function()
                core:rescan_tools()
            end)

            -- tools_by_type should remain empty
            assert.same({}, core:get_tools_by_type())
        end)
    end)

    describe("Profile:deactivate (via Core)", function()
        it("clears active profile when it matches", function()
            local saved = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                        },
                    },
                },
                {
                    user = {
                        save = function(root, data)
                            saved.data = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            h.find_profile(core:get_profiles(), "debug"):deactivate()
            assert.is_nil(saved.data.active_profile)
        end)

        it("does nothing when profile does not match active", function()
            local save_called = false
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "development" },
                    },
                },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                        release = { configuration_set = "release" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "configured",
                        },
                    },
                },
                {
                    user = {
                        save = function()
                            save_called = true
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            save_called = false -- reset from setup
            h.find_profile(core:get_profiles(), "release"):deactivate()
            assert.is_false(save_called)
        end)
    end)

    describe("ConfigurationSet:activate (switch set)", function()
        it("activates profile for known configuration set", function()
            local saved = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "production" },
                    },
                },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                        release = { configuration_set = "release" },
                    },
                },
                nil,
                {
                    user = {
                        save = function(root, data)
                            saved.data = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            get_cs(core, "release"):activate()
            assert.equals("release", saved.data.active_profile)
        end)
    end)

    describe("_materialize_from_data", function()
        pending("creates skeleton config units in cache", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil, nil,
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            core:_materialize_from_data(get_cs(core, "debug"))

            assert.is_not_nil(saved_cache)
            -- No profiles in cache (profiles are runtime-only)
            assert.is_nil(saved_cache.profiles)
            -- Skeleton config entry in flat cache
            assert.is_not_nil(saved_cache.build_dirs["build/App/development"])
            assert.equals("development", saved_cache.build_dirs["build/App/development"].variant)
        end)

        it("is idempotent (second call still saves but creates no new units)", function()
            local save_count = 0
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil, nil,
                {
                    cache = {
                        save = function()
                            save_count = save_count + 1
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            local ws = core._workspace
            core:_materialize_from_data(get_cs(core, "debug"))
            local units_after_first = #ws._config_units
            core:_materialize_from_data(get_cs(core, "debug"))
            assert.equals(units_after_first, #ws._config_units) -- no additional config units
        end)

        it("is safe without workspace", function()
            local ConfigurationSet = require("loomworks.configuration_set")
            local core = make_core()
            -- don't setup — _materialize_from_data checks for workspace
            local dummy_cs = ConfigurationSet.new(core, "debug", {})
            core:_materialize_from_data(dummy_cs) -- should not error
        end)

        pending("stores tool data in config unit when tool_entry provided", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { Lib = { cmake = {} } },
                    configuration_sets = { debug = { Lib = "Debug" } },
                },
                nil, nil,
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            core:_materialize_from_data(get_cs(core, "debug"), {
                tool_key = "ninja-gcc",
                tool_data = { generator = "Ninja", compiler_id = "gcc" },
                tool_label = "Ninja GCC",
                tool_mod_type = "cmake",
            })

            assert.is_not_nil(saved_cache)
            -- No profiles in cache
            assert.is_nil(saved_cache.profiles)
            -- Config unit has tool data (no tool id in default path since tool_data has no .id)
            local bd = saved_cache.build_dirs["build/Lib/Debug"]
            assert.is_not_nil(bd)
            assert.equals("Debug", bd.variant)
            assert.equals("ninja-gcc", bd.tool_key)
        end)

    end)

    describe("shutdown", function()
        it("tears down the workspace (stops file tracker, drops the ref)", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local ws = core._workspace
            assert.is_not_nil(ws._tracker)
            core:shutdown()
            assert.is_nil(ws._tracker)
            assert.is_nil(core._workspace)
        end)

        it("is safe without tracker", function()
            local core = make_core()
            core:shutdown() -- should not error
        end)
    end)

    describe("_on_file_changed", function()
        it("reloads workspace when config changes", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            -- Simulate config file change with updated content
            local new_config = h.make_config_json({
                projects = { App = { typescript = {} }, Lib = { typescript = {} } },
                configuration_sets = { debug = { App = "development", Lib = "development" } },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", new_config)
            -- New project should be in workspace domain objects
            local found_lib = false
            for _, p in pairs(core._workspace._projects) do
                if p.key == "Lib" then found_lib = true; break end
            end
            assert.is_true(found_lib)
        end)

        it("updates user data when user file changes", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            local new_user = h.make_user_json({ active_profile = "debug" })
            core._workspace:_on_file_changed("/root/.nvim/loomworks.user.json", new_user)
            assert.equals("debug", core._workspace._active_profile_key)
        end)

        it("updates cache data when cache file changes", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            local new_cache = h.make_cache_json({
                configurations = {
                    ["App/development"] = {
                        project_key = "App",
                        config_key = "development",
                        variant = "development",
                        type = "typescript",
                        state = "built",
                    },
                },
            })
            core._workspace:_on_file_changed("/root/.nvim/loomworks.cache.json", new_cache)
            assert.is_not_nil(core._workspace:_serialize_cache().build_dirs["build/App/development"])
        end)

        it("does nothing for unrecognized path", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local ws_before = core._workspace
            core._workspace:_on_file_changed("/root/some_other_file.txt", "content")
            -- Workspace unchanged (same reference)
            assert.equals(ws_before, core._workspace)
        end)

        it("notifies INFO on successful config reload", function()
            local notifications = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil, nil,
                {
                    notify = function(msg, level)
                        notifications[#notifications + 1] = { msg = msg, level = level }
                    end,
                }
            )
            core:setup({ root = "/root" })
            notifications = {} -- clear setup notifications

            local new_config = h.make_config_json({
                projects = { App = { typescript = {} }, Lib = { typescript = {} } },
                configuration_sets = { debug = { App = "development", Lib = "development" } },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", new_config)

            local found_info = false
            for _, n in ipairs(notifications) do
                if n.msg:match("config reloaded") and n.level == vim.log.levels.INFO then
                    found_info = true
                end
            end
            assert.is_true(found_info, "should notify INFO on successful config reload")
        end)

        it("notifies WARN when config reload fails with invalid JSON", function()
            local notifications = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil, nil,
                {
                    notify = function(msg, level)
                        notifications[#notifications + 1] = { msg = msg, level = level }
                    end,
                }
            )
            core:setup({ root = "/root" })
            notifications = {} -- clear setup notifications

            core._workspace:_on_file_changed("/root/loomworks.json", "not valid json {{{")

            local found_warn = false
            for _, n in ipairs(notifications) do
                if n.msg:match("config reload failed") and n.level == vim.log.levels.WARN then
                    found_warn = true
                end
            end
            assert.is_true(found_warn, "should notify WARN on config reload failure")
        end)

        it("logs validation warnings but still loads", function()
            local notifications = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil, nil,
                {
                    notify = function(msg, level)
                        notifications[#notifications + 1] = { msg = msg, level = level }
                    end,
                    modules = {
                        get = function(mod_type)
                            if mod_type == "cmake" then
                                return {
                                    validate = function()
                                        return { valid = false, warnings = { "missing CMakeLists.txt" } }
                                    end,
                                }
                            end
                            return nil
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            notifications = {} -- clear setup notifications

            -- Change config to add a cmake project with validation warnings
            local new_config = h.make_config_json({
                projects = { BadProject = { cmake = {} } },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", new_config)

            -- Should still reload (not block), but produce a warning
            local found_warn = false
            for _, n in ipairs(notifications) do
                if n.msg:match("missing CMakeLists") and n.level == vim.log.levels.WARN then
                    found_warn = true
                end
            end
            assert.is_true(found_warn, "should log validation warning")
            -- Should have reloaded successfully
            local found_reload = false
            for _, n in ipairs(notifications) do
                if n.msg:match("config reloaded") then found_reload = true end
            end
            assert.is_true(found_reload, "should still reload config")
        end)

        it("does not update workspace on config reload failure", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            core._workspace:_on_file_changed("/root/loomworks.json", "not valid json {{{")

            -- Original project should still be there (no remerge on invalid JSON)
            local found_app = false
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then found_app = true; break end
            end
            assert.is_true(found_app)
        end)

        it("emits active_set_changed when user file changes", function()
            local core, deps = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })
            -- Clear events from setup
            for i = #deps._events_log, 1, -1 do
                table.remove(deps._events_log, i)
            end

            local new_user = h.make_user_json({ active_profile = "debug" })
            core._workspace:_on_file_changed("/root/.nvim/loomworks.user.json", new_user)

            local found = false
            for _, e in ipairs(deps._events_log) do
                if e.event == "active_set_changed" then found = true end
            end
            assert.is_true(found, "should emit active_set_changed on user file change")
        end)

        it("emits active_set_changed when cache file changes", function()
            local core, deps = make_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })
            for i = #deps._events_log, 1, -1 do
                table.remove(deps._events_log, i)
            end

            local new_cache = h.make_cache_json({
                configurations = {
                    ["App/development"] = {
                        project_key = "App",
                        config_key = "development",
                        variant = "development",
                        type = "typescript",
                        state = "configured",
                    },
                },
            })
            core._workspace:_on_file_changed("/root/.nvim/loomworks.cache.json", new_cache)

            local found = false
            for _, e in ipairs(deps._events_log) do
                if e.event == "active_set_changed" then found = true end
            end
            assert.is_true(found, "should emit active_set_changed on cache file change")
        end)

        it("defaults user data when user file content is nil", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            }, { active_profile = "debug" })
            core:setup({ root = "/root" })
            assert.equals("debug", core._workspace._active_profile_key)

            -- Simulate user file being deleted (nil content)
            core._workspace:_on_file_changed("/root/.nvim/loomworks.user.json", nil)

            assert.is_nil(core._workspace._active_profile_key)
        end)

        it("defaults cache data when cache file content is nil", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil,
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.is_not_nil(core._workspace:_serialize_cache().build_dirs["build/App/development"])

            -- Simulate cache file being deleted (nil content)
            core._workspace:_on_file_changed("/root/.nvim/loomworks.cache.json", nil)

            -- Cache should be reset to default (empty build_dirs)
            assert.same({}, core._workspace:_serialize_cache().build_dirs)
        end)

        it("emits active_set_changed when config file changes", function()
            local core, deps = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })
            for i = #deps._events_log, 1, -1 do
                table.remove(deps._events_log, i)
            end

            local new_config = h.make_config_json({
                projects = { App = { typescript = {} } },
                configuration_sets = {
                    debug = { App = "development" },
                    release = { App = "production" },
                },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", new_config)

            local found = false
            for _, e in ipairs(deps._events_log) do
                if e.event == "active_set_changed" then found = true end
            end
            assert.is_true(found, "should emit active_set_changed on config file change")
        end)

        it("updates configuration_sets when config changes", function()
            local core = make_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })
            local found_release = false
            for _, cs in pairs(core._workspace._config_sets) do
                if cs.name == "release" then found_release = true end
            end
            assert.is_false(found_release)

            local new_config = h.make_config_json({
                projects = { App = { typescript = {} } },
                configuration_sets = {
                    debug = { App = "development" },
                    release = { App = "production" },
                },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", new_config)

            found_release = false
            local release_app_variant = nil
            for _, cs in pairs(core._workspace._config_sets) do
                if cs.name == "release" then
                    found_release = true
                    for proj, config in pairs(cs.mappings) do
                        if proj.key == "App" then release_app_variant = config.name end
                    end
                end
            end
            assert.is_true(found_release)
            assert.equals("production", release_app_variant)
        end)

        --- Capture observable workspace state for round-trip equality checks.
        --- Returns a deep-comparable table (no domain object refs).
        --- @param ws loomworks.Workspace
        --- @return table snapshot
        local function snapshot_state(ws)
            local snap = {
                active_profile = ws._active_profile_key,
                projects = {},
                config_sets = {},
                profiles = {},
            }
            for _, p in pairs(ws._projects) do
                local cfgs = {}
                for _, cfg in ipairs(p._configurations or {}) do
                    cfgs[cfg.name] = { intent = cfg._intent }
                end
                snap.projects[p.key] = {
                    intent = p._intent,
                    type = p.type,
                    configurations = cfgs,
                }
            end
            for _, cs in pairs(ws._config_sets) do
                snap.config_sets[cs.name] = { intent = cs._intent }
            end
            for _, prof in pairs(ws._profiles) do
                snap.profiles[prof.key] = { intent = prof._intent }
            end
            return snap
        end

        it("round-trips A → B → A: state restored when no user modifications", function()
            -- Branch A: App + Lib, debug + release sets, profile P1 active on debug
            local config_a = {
                projects = { App = { typescript = {} }, Lib = { typescript = {} } },
                configuration_sets = {
                    debug = { App = "development", Lib = "development" },
                    release = { App = "production", Lib = "production" },
                },
            }
            local core = make_core(config_a, { active_profile = "debug" })
            core:setup({ root = "/root" })

            -- Capture initial state on branch A
            local before = snapshot_state(core._workspace)
            assert.equals("debug", before.active_profile)

            -- Switch to branch B: drops "release" set entirely, adds an "Extra"
            -- project. App and Lib unchanged. debug set unchanged.
            local config_b = h.make_config_json({
                projects = {
                    App = { typescript = {} },
                    Lib = { typescript = {} },
                    Extra = { typescript = {} },
                },
                configuration_sets = {
                    debug = { App = "development", Lib = "development" },
                },
            })
            core._workspace:_on_file_changed("/root/loomworks.json", config_b)

            -- Sanity: on branch B, Extra has appeared and release has gone
            local on_b = snapshot_state(core._workspace)
            assert.is_not_nil(on_b.projects["Extra"])
            assert.is_nil(on_b.config_sets["release"])

            -- Switch back to branch A
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json(config_a))

            -- Assert state restored to initial
            local after = snapshot_state(core._workspace)
            assert.same(before, after,
                "workspace state should be identical after A → B → A round-trip")
        end)

        it("effective intent: published config set forces referenced project+config into shared", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- Demote App and App.development to "local" via direct intent
            -- mutation, but keep config set debug as "local+shared".
            -- Effective intent should re-promote them via the cascade.
            local app, debug_cs
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p end
            end
            for _, cs in pairs(core._workspace._config_sets) do
                if cs.name == "debug" then debug_cs = cs end
            end
            assert.is_not_nil(app)
            assert.is_not_nil(debug_cs)

            app._intent = "local"
            for _, cfg in ipairs(app._configurations) do
                if cfg.name == "development" then cfg._intent = "local" end
            end
            -- debug_cs is "shared" (in baseline only). It should still propagate.
            assert.is_truthy(debug_cs._intent ~= "local",
                "debug set must have effective intent including shared")

            local raw = core._workspace:_serialize_config()
            -- App should be in loomworks.json (transitively promoted by debug set)
            assert.is_not_nil(raw.projects["App"],
                "App must be in loomworks.json — debug set references it")
            -- The debug config set is published
            assert.is_not_nil(raw.configuration_sets["debug"])
        end)

        it("removed-upstream flag: set when local+shared item disappears from upstream", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            local app
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p; break end
            end
            assert.is_not_nil(app)
            assert.equals("local+shared", app._intent)
            assert.is_falsy(app._removed_upstream, "no flag at start")

            -- Switch to branch B that doesn't have App
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json({
                projects = { Other = { typescript = {} } },
            }))

            -- App should now have removed_upstream flag
            local app_after
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app_after = p; break end
            end
            assert.is_not_nil(app_after)
            assert.is_true(app_after._removed_upstream,
                "App must be flagged removed-upstream (was in baseline, isn't now)")
        end)

        it("publish drops auto-gen configurations from loomworks.json", function()
            -- Auto-gens (configs with a `prefix:name` canonical key)
            -- come from module.info() on every load. They must never
            -- be persisted — otherwise stale entries pile up in
            -- loomworks.json and the parser later trips on the
            -- reserved `:` character.
            local Configuration = require("loomworks.configuration")
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            local app
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p; break end
            end
            assert.is_not_nil(app)
            -- Inject a synthetic auto-gen with module data the bug would
            -- have written to loomworks.json.
            local autogen = Configuration.new(app, "auto:Debug", {
                module_config = { variant = "Debug", generator = "Ninja" },
                is_default = true,
            })
            autogen._intent = "shared"
            app._configurations[#app._configurations + 1] = autogen
            assert.is_true(autogen:is_auto_gen())

            local raw = core._workspace:_serialize_config()
            local cfgs = raw.projects["App"]
                and raw.projects["App"].typescript
                and raw.projects["App"].typescript.configurations or {}
            assert.is_nil(cfgs["auto:Debug"],
                "auto-gen must be filtered out of loomworks.json")
        end)

        it("publish_one writes only the named item to loomworks.json", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                        Lib = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            local lib
            for _, p in pairs(core._workspace._projects) do
                if p.key == "Lib" then lib = p; break end
            end
            assert.is_not_nil(lib)
            -- Lib starts as local (not in baseline)
            assert.equals("local", lib._intent)

            -- publish_one bumps Lib to local+shared and writes loomworks.json
            local ok = core._workspace:publish_one(lib)
            assert.is_true(ok)
            assert.equals("local+shared", lib._intent)
        end)

        it("revert_to_baseline (:e!) demotes locally-added items to local", function()
            -- Branch A: App in user.json + baseline. user.json adds a Lib that's
            -- NOT in baseline. revert_to_baseline should keep both projects but
            -- demote Lib to local intent (data preserved, publication wish dropped).
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                        Lib = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- Both projects exist; mark Lib as local+shared (would be the case
            -- if user explicitly published it but the file hasn't been written).
            local app, lib
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p end
                if p.key == "Lib" then lib = p end
            end
            assert.is_not_nil(app)
            assert.is_not_nil(lib)
            lib._intent = "local+shared"

            core._workspace:revert_to_baseline()

            -- App: still local+shared (in baseline)
            -- Lib: demoted to local (not in baseline)
            local app_after, lib_after
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app_after = p end
                if p.key == "Lib" then lib_after = p end
            end
            assert.is_not_nil(app_after, "App preserved")
            assert.is_not_nil(lib_after, "Lib preserved (data not lost)")
            assert.equals("local+shared", app_after._intent)
            assert.equals("local", lib_after._intent,
                "Lib demoted to local (not in baseline)")
        end)

        it("removed-upstream flag clears on publish", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- Trigger removed-upstream
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json({
                projects = { Other = { typescript = {} } },
            }))
            local app
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p; break end
            end
            assert.is_true(app._removed_upstream)

            -- Publish — flag should clear
            core._workspace:publish()
            assert.is_falsy(app._removed_upstream,
                "removed-upstream flag must clear after :w (item republished)")
        end)

        it("sticky intent: local+shared survives upstream removal", function()
            -- App is materialized in user.json on branch A.
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    active_profile = "debug",
                    projects = {
                        App = { typescript = { configurations = { development = {} } } },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- Sanity: App's intent is local+shared on branch A
            local app
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app = p; break end
            end
            assert.is_not_nil(app)
            assert.equals("local+shared", app._intent)

            -- Switch to branch B which doesn't have App at all
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json({
                projects = { Other = { typescript = {} } },
            }))

            -- App should still be in workspace (data in user.json) AND intent
            -- should still be local+shared (sticky), NOT flipped to local.
            -- :w on this state should republish App to loomworks.json.
            local app_after
            for _, p in pairs(core._workspace._projects) do
                if p.key == "App" then app_after = p; break end
            end
            assert.is_not_nil(app_after, "App should remain (data in user.json)")
            assert.equals("local+shared", app_after._intent,
                "intent should stay local+shared after upstream removal (specification.md §2.4 stickiness)")
        end)

        it("round-trips A → B → A with materialized user.json content", function()
            -- Branch A with App materialized in user.json (simulating cascade-on-use
            -- having pulled App's data into the working copy).
            local config_a = {
                projects = { App = { typescript = {} }, Lib = { typescript = {} } },
                configuration_sets = { debug = { App = "development", Lib = "development" } },
            }
            local user_a = {
                active_profile = "debug",
                projects = {
                    App = { typescript = { configurations = { development = {} } } },
                },
            }
            local core = make_core(config_a, user_a)
            core:setup({ root = "/root" })

            local before = snapshot_state(core._workspace)
            -- Sanity: App was materialized → effective intent local+shared
            assert.equals("local+shared", before.projects["App"].intent)

            -- Switch to branch B: drops Lib entirely, App unchanged
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            }))

            -- Switch back to branch A
            core._workspace:_on_file_changed("/root/loomworks.json", h.make_config_json(config_a))

            local after = snapshot_state(core._workspace)
            assert.same(before, after,
                "workspace state should be identical after round-trip with materialized projects")
        end)
    end)

    describe("find_running_tasks_for_items", function()
        it("finds matching tasks", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local app_unit = get_unit(core, "App", "Debug")
            local lib_unit = get_unit(core, "Lib", "Debug")
            app_unit:register_task(1, "build")
            lib_unit:register_task(2, "configure")

            local matches = core:find_running_tasks_for_items({
                { project_key = "App", config_key = "Debug", unit = app_unit },
            })
            assert.is_not_nil(matches[1])
            assert.is_nil(matches[2])
        end)

    end)

    describe("stop_tasks_then", function()
        it("calls on_done immediately for empty list", function()
            local core = make_core()
            local done = false
            core:stop_tasks_then({}, function() done = true end)
            assert.is_true(done)
        end)

    end)

    describe("plan_config_deletion", function()
        it("resets config when only profiles reference it", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { development = { App = "development" } },
                },
                {
                    profiles = {
                        development = { configuration_set = "development" },
                    },
                },
                {
                    build_dirs = {
                        ["build/App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "configured",
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local plan = get_unit(core, "App", "development"):plan_deletion()
            assert.equals(1, #plan.items)
            assert.is_not_nil(plan.items[1].unit)
            assert.equals("App", plan.items[1].unit._project.key)
            assert.equals("/root/.nvim/build/App/development", plan.items[1].build_dir)
            -- Profile still references it, so disposition is "reset"
            assert.equals("reset", plan.items[1].disposition)
            assert.is_true(plan.defined_in_config)
        end)

        it("returns empty plan when no workspace", function()
            -- ConfigUnit with nil workspace returns empty plan
            local unit = ConfigUnit.new(nil, "App", "Debug")
            local plan = unit:plan_deletion()
            assert.are.same({}, plan.items)
            assert.is_false(plan.defined_in_config)
        end)

        it("excludes config when a pinned profile references it", function()
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                    configuration_sets = { debug = { App = "Debug" } },
                },
                {
                    profiles = {
                        ["debug:ninja-gcc"] = {
                            configuration_set = "debug",
                            tools = { cmake = { key = "ninja-gcc", data = { generator = "Ninja", compiler_id = "gcc" } } },
                        },
                    },
                },
                {
                    configurations = {
                        ["App/Debug:ninja-gcc"] = {
                            project_key = "App",
                            config_key = "Debug:ninja-gcc", variant = "Debug",
                            type = "cmake",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/Debug",
                            tool_key = "ninja-gcc",
                        },
                    },
                },
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local plan = get_unit(core, "App", "Debug:ninja-gcc"):plan_deletion()
            -- Config is referenced by pinned profile — disposition is "reset"
            assert.equals(1, #plan.items)
            assert.equals("reset", plan.items[1].disposition)
        end)
    end)

    describe("delete_cached_configs", function()
        it("removes config from cache and saves", function()
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                    },
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "development")
            core:delete_cached_configs({
                { unit = unit },
            })
            local ws = core:get_workspace()
            -- Config should be removed from flat cache
            assert.is_nil(ws:_serialize_cache().build_dirs["build/App/development"])
        end)

        it("refuses to delete build dir outside workspace root", function()
            local notifications = {}
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil,
                nil,
                {
                    notify = function(msg, level)
                        notifications[#notifications + 1] = { msg = msg, level = level }
                    end,
                }
            )
            core:setup({ root = "/root" })
            assert.is_false(core:_validate_build_dir("/other/path/App", "/root"))
            local found_refusal = false
            for _, n in ipairs(notifications) do
                if n.msg:match("refusing to delete") then
                    found_refusal = true
                    break
                end
            end
            assert.is_true(found_refusal)
        end)

        it("refuses prefix collision (e.g. /root vs /roots)", function()
            local notifications = {}
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil,
                nil,
                {
                    notify = function(msg, level)
                        notifications[#notifications + 1] = { msg = msg, level = level }
                    end,
                }
            )
            core:setup({ root = "/root" })
            -- /roots starts with /root but is NOT under /root
            assert.is_false(core:_validate_build_dir("/roots/build/App", "/root"))
        end)

        it("allows build dir under workspace root", function()
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil,
                nil,
                { notify = function() end }
            )
            core:setup({ root = "/root" })
            assert.is_true(core:_validate_build_dir("/root/.nvim/build/App", "/root"))
            assert.is_true(core:_validate_build_dir("/root/build/Debug", "/root"))
        end)
    end)

    describe("execute_deletion", function()
        it("marks items as deleting during execution", function()
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil,
                {
                    configurations = {
                        ["App/dev"] = {
                            project_key = "App",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "configured",
                        },
                    },
                },
                {
                    cache = { save = function() return true end },
                }
            )
            core:setup({ root = "/root" })

            local plan = {
                items = {
                    { project_key = "App", config_key = "dev" },
                },
            }

            local done = false
            core:execute_deletion(plan, nil, function() done = true end)
            assert.is_true(done)
            -- After completion, deleting flag should be cleared
            assert.is_false(get_unit(core, "App", "dev"):is_deleting())
        end)

        it("deletes profile config entries on profile deletion", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    build_dirs = {
                        ["build/App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            local unit = get_unit(core, "App", "development")
            local plan = {
                profile = profile,
                items = {
                    { unit = unit },
                },
            }

            local done = false
            core:execute_deletion(plan, nil, function() done = true end)
            assert.is_true(done)
            assert.is_not_nil(saved_cache)
            -- No profiles in cache (profiles are runtime-only)
            assert.is_nil(saved_cache.profiles)
        end)

        it("empty items deletion preserves config entries", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "development" },
                    },
                },
                nil,
                {
                    build_dirs = {
                        ["build/App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local debug_profile = h.find_profile(core:get_profiles(), "debug")
            local plan = {
                profile = debug_profile,
                items = {},
            }

            local done = false
            core:execute_deletion(plan, { deactivate_profile = debug_profile }, function() done = true end)
            assert.is_true(done)
            -- Config preserved (no items to delete)
            assert.is_not_nil(saved_cache)
            assert.is_not_nil(saved_cache.build_dirs["build/App/development"])
        end)
    end)

    describe("find_referencing_profiles", function()
        it("finds profiles referencing a config", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { development = { App = "development" } },
                },
                {
                    profiles = {
                        development = { configuration_set = "development" },
                    },
                },
                {
                    build_dirs = {
                        ["build/App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            local refs = get_unit(core, "App", "development"):referencing_profiles()
            assert.equals(1, #refs)
            assert.equals("development", refs[1].key)
        end)

    end)

    describe("_cleanup_orphaned_skeletons", function()
        it("drops unconfigured skeleton with no profile reference", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil,
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            -- no state = unconfigured
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.is_not_nil(saved_cache)
            -- Config should have been dropped
            assert.is_nil(saved_cache.build_dirs["build/App/development"])
        end)

        it("preserves configs with state (leaves them as orphans)", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil,
                {
                    -- No profiles, but a built config exists
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            -- Config should NOT be dropped — it has state
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(cache.build_dirs)
            assert.is_not_nil(cache.build_dirs["build/App/development"])
            assert.equals("built", cache.build_dirs["build/App/development"].state)
            -- No pinned profile should be created
            assert.is_nil(cache.profiles)
        end)

        it("does not touch configs referenced by a profile", function()
            local saved = false
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                    },
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                },
                {
                    cache = {
                        save = function()
                            saved = true
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            -- No changes needed since config is already referenced
            assert.is_false(saved)
        end)
    end)

    describe("get_orphaned_configs", function()
        it("returns empty when no workspace", function()
            local core = make_core()
            assert.same({}, core:get_orphaned_configs())
        end)

        it("returns empty when all configs are referenced", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.same({}, core:get_orphaned_configs())
        end)

        pending("returns configs with state not referenced by any profile", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "configured",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("App", orphans[1].project_key)
            assert.equals("production", orphans[1].config_key)
            assert.equals("configured", orphans[1].unit.state_value)
        end)

        it("excludes unconfigured skeletons", function()
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil,
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            -- unconfigured skeleton — should be dropped by cleanup
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.same({}, core:get_orphaned_configs())
        end)

        it("returns sorted by project then config key", function()
            local core = make_core(
                {
                    projects = {
                        Bravo = { typescript = {} },
                        Alpha = { typescript = {} },
                    },
                },
                nil,
                {
                    configurations = {
                        ["Bravo/prod"] = {
                            project_key = "Bravo",
                            config_key = "prod",
                            variant = "prod",
                            type = "typescript",
                            state = "built",
                        },
                        ["Alpha/staging"] = {
                            project_key = "Alpha",
                            config_key = "staging",
                            variant = "staging",
                            type = "typescript",
                            state = "configured",
                        },
                        ["Alpha/dev"] = {
                            project_key = "Alpha",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            local orphans = core:get_orphaned_configs()
            assert.equals(3, #orphans)
            assert.equals("Alpha", orphans[1].project_key)
            assert.equals("dev", orphans[1].config_key)
            assert.equals("Alpha", orphans[2].project_key)
            assert.equals("staging", orphans[2].config_key)
            assert.equals("Bravo", orphans[3].project_key)
            assert.equals("prod", orphans[3].config_key)
        end)
    end)

    describe("delete_orphaned_config", function()
        it("removes orphaned config from cache", function()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil,
                {
                    configurations = {
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/production",
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = vim.deepcopy(data)
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.equals(1, #core:get_orphaned_configs())

            get_unit(core, "App", "production"):delete()
            assert.equals(0, #core:get_orphaned_configs())
            -- Cache should no longer have the config
            assert.is_not_nil(saved_cache)
            assert.is_nil(saved_cache.build_dirs["build/App/production"])
        end)
    end)

    describe("branch switching", function()
        it("configs built on feature branch become orphaned on master", function()
            -- Simulate: master has config_set "debug" with App=development
            -- Feature branch had config_set "feature" and user built App/staging
            -- After switching to master, "feature" set no longer in config
            -- The "staging" config entry becomes orphaned

            local core = make_core(
                {
                    -- master: only "debug" config set
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    -- Cache from feature branch: has configs for both
                    build_dirs = {
                        ["build/App/development"] = {
                            project_key = "App",
                            config_key = "development", variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        ["build/App/staging"] = {
                            project_key = "App",
                            config_key = "staging", variant = "staging",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- "staging" is NOT referenced by any profile (no "feature" config set)
            -- so it IS orphaned
            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("App", orphans[1].project_key)
            assert.equals("staging", orphans[1].config_key)
        end)

        pending("unreferenced configs from branch switching are orphaned", function()
            -- Scenario: user built configs directly (via ConfigUnit:materialize)
            -- on feature branch, then switched to master. The configs have no
            -- profile referencing them.
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        -- This config was built on another branch, no profile references it
                        ["App/feature-config"] = {
                            project_key = "App",
                            config_key = "feature-config",
                            variant = "feature-config",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/feature-config",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("App", orphans[1].project_key)
            assert.equals("feature-config", orphans[1].config_key)
            assert.equals("built", orphans[1].unit.state_value)
        end)

        it("deleting orphan from branch switch cleans up correctly", function()
            local deleted_dirs = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        ["App/feature-config"] = {
                            project_key = "App",
                            config_key = "feature-config",
                            variant = "feature-config",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/feature-config",
                        },
                    },
                },
                {
                    io = {
                        rm_rf_async = function(path, cb)
                            deleted_dirs[#deleted_dirs + 1] = path
                            cb(true, nil)
                        end,
                    },
                    cache = {
                        save = function() return true end,
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.equals(1, #core:get_orphaned_configs())

            get_unit(core, "App", "feature-config"):delete()

            -- Orphan should be gone
            assert.equals(0, #core:get_orphaned_configs())
            -- Build dir should have been deleted
            local found_dir = false
            for _, d in ipairs(deleted_dirs) do
                if d:match("feature%-config") then found_dir = true end
            end
            assert.is_true(found_dir, "build directory should be deleted")
            -- Referenced config should still exist
            local ws = core:get_workspace()
            assert.is_not_nil(ws:_serialize_cache().build_dirs["build/App/development"])
        end)

        it("round-trip: master->feature->master leaves cache intact", function()
            -- This is the A->B->A test but framed as branch switching.
            -- Master config, then feature config, then back to master.
            -- The user switches profiles (not branches) but the cache should not change.
            local cache_saves = {}
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "production" },
                    },
                },
                {
                    profiles = {
                        debug = { configuration_set = "debug" },
                        release = { configuration_set = "release" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                        },
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "configured",
                        },
                    },
                },
                {
                    cache = {
                        save = function(root, data)
                            cache_saves[#cache_saves + 1] = vim.deepcopy(data)
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            local saves_after_setup = #cache_saves

            get_cs(core, "debug"):activate()
            get_cs(core, "release"):activate()
            get_cs(core, "debug"):activate()

            assert.equals(saves_after_setup, #cache_saves,
                "switching between materialized profiles should not write to cache")
            assert.same({}, core:get_orphaned_configs())
        end)
    end)

    describe("after_deletions", function()
        it("calls fn immediately when nothing pending", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local called = false
            core:after_deletions(function() called = true end)
            assert.is_true(called)
        end)

        it("defers fn when deletion operation is active", function()
            local core = make_core(
                { projects = { App = { typescript = {} } } },
                nil, nil,
                { cache = { save = function() return true end } }
            )
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "dev")
            unit:mark_deleting(true)
            -- Create a deletion Operation so has_pending_deletions returns true
            core:create_operation(nil, "clean", { unit }, { [unit] = "unconfigured" })

            local called = false
            core:after_deletions(function() called = true end)
            assert.is_false(called)
        end)
    end)

    describe("task progress", function()
        it("stores and retrieves progress via ConfigUnit", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            unit:update_progress(1, { current = 3, total = 10 })
            local p = unit:progress()
            assert.is_not_nil(p)
            assert.equals(3, p.current)
            assert.equals(10, p.total)
        end)

        it("returns nil for non-running config", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            assert.is_nil(unit:progress())
        end)

        it("clears progress on unregister", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            unit:update_progress(1, { current = 3, total = 10 })
            unit:unregister_task(1)
            assert.is_nil(unit:progress())
        end)

        it("emits state_change on progress update", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            local fired = false
            unit:on_state_change(function() fired = true end)
            unit:update_progress(1, { current = 7, total = 10 })
            assert.is_true(fired)
        end)

        it("ignores progress when no task registered", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            -- Should not error
            unit:update_progress(999, { current = 1, total = 1 })
            assert.is_nil(unit:progress())
        end)
    end)

    describe("task elapsed time", function()
        it("tracks elapsed time via ConfigUnit", function()
            local time = 100
            local core = make_core(nil, nil, nil, {
                clock = function() return time end,
            })
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            time = 142
            assert.equals(42, unit:elapsed())
        end)

        it("returns nil for non-running config", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            assert.is_nil(unit:elapsed())
        end)

        it("clears elapsed on unregister", function()
            local core = make_core()
            core:setup({ root = "/root" })
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            unit:unregister_task(1)
            assert.is_nil(unit:elapsed())
        end)
    end)

    describe("operations (on Profile)", function()
        local op_config = {
            configuration_sets = { debug = { App = "Debug" } },
        }

        local op_user = {
            active_profile = "debug",
            profiles = {
                debug = { configuration_set = "debug" },
            },
        }

        local op_cache = {
            configurations = {
                ["App/Debug"] = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    type = "cmake",
                },
            },
        }

        local function make_op_core(clock_fn)
            local time = { value = 0 }
            if not clock_fn then
                clock_fn = function() return time.value end
            end
            local core = make_core(op_config, op_user, op_cache, {
                clock = clock_fn,
            })
            core:setup({ root = "/root" })
            local profile = h.find_profile(core:get_profiles(), "debug")
            return core, profile, time
        end

        it("tracks a running operation", function()
            local core, profile, time = make_op_core()
            time.value = 100
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            local op = core:create_operation(profile, "build", { unit }, { [unit] = "built" })

            assert.is_true(profile:has_active_operation())
            assert.equals("build", op.action)
            assert.equals(100, op.started_at)

            time.value = 130
            assert.equals(30, profile:operation_elapsed())
        end)

        it("finishes operation with success message", function()
            local core, profile, time = make_op_core()
            time.value = 100
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            core:create_operation(profile, "build", { unit }, { [unit] = "built" })

            -- Simulate build completing: cache state = "built", unregister task
            unit.state_value = "built"
            time.value = 190
            unit:unregister_task(1)

            local last = profile:operation()
            assert.is_not_nil(last)
            assert.equals("built in 1m30s", last.message)
            assert.is_true(last.success)
            -- No longer running
            assert.is_nil(profile:operation_elapsed())
        end)

        it("finishes operation with failure message", function()
            local core, profile, time = make_op_core()
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "configure")
            core:create_operation(profile, "configure", { unit }, { [unit] = "configured" })

            -- Simulate configure failure
            unit.state_value = "failed_configure"
            time.value = 45
            unit:unregister_task(1)

            local last = profile:operation()
            assert.equals("configure failed in 45s", last.message)
            assert.is_false(last.success)
        end)

        it("configure+build operation uses generic verb", function()
            local core, profile, time = make_op_core()
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            core:create_operation(profile, "configure+build", { unit }, { [unit] = "built" })

            unit.state_value = "built"
            time.value = 120
            unit:unregister_task(1)

            assert.equals("built in 2m00s", profile:operation().message)
        end)

        it("new operation replaces previous result", function()
            local core, profile, time = make_op_core()
            local unit = get_unit(core, "App", "Debug")

            -- First operation completes
            unit:register_task(1, "build")
            core:create_operation(profile, "build", { unit }, { [unit] = "built" })
            unit.state_value = "built"
            time.value = 10
            unit:unregister_task(1)
            assert.is_not_nil(profile:operation().message)

            -- Second operation starts
            unit:register_task(2, "build")
            unit.state_value = "configured"
            core:create_operation(profile, "build", { unit }, { [unit] = "built" })
            -- Has active operation, previous result still available until new one completes
            assert.is_true(profile:has_active_operation())
        end)

        it("returns nil before any operation", function()
            local _, profile = make_op_core()
            assert.is_nil(profile:operation())
            assert.is_nil(profile:operation_elapsed())
        end)

        it("emits operation events", function()
            local core, profile, time = make_op_core()
            local unit = get_unit(core, "App", "Debug")
            unit:register_task(1, "build")
            core:create_operation(profile, "build", { unit }, { [unit] = "built" })

            unit.state_value = "built"
            time.value = 10
            unit:unregister_task(1)

            local events = core._deps._events_log
            local found_started, found_finished = false, false
            for _, e in ipairs(events) do
                if e.event == "operation_started" then
                    assert.equals("debug", e.data.profile_key)
                    found_started = true
                end
                if e.event == "operation_finished" then
                    assert.equals("debug", e.data.profile_key)
                    assert.is_true(e.data.success)
                    found_finished = true
                end
            end
            assert.is_true(found_started)
            assert.is_true(found_finished)
        end)
    end)

    -- State transition tests (configured, failed_configure, built, failed_build)
    -- are covered exhaustively in config_unit_spec.lua. These tests focus on
    -- Core.record_task_result's cache persistence and module integration.
    describe("record_task_result cache persistence", function()
        local function make_recording_core()
            local saved_cache = nil
            local core = make_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                { active_profile = "debug" },
                nil,
                {
                    cache = {
                        save = function(root, data)
                            saved_cache = data
                            return true
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })
            return core, function() return saved_cache end
        end

        it("configure then build -> built", function()
            local core, get_cache = make_recording_core()
            local unit = get_unit(core, "App", "development")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
            })
            core:record_task_result({
                unit = unit,
                action = "build",
                success = true,
            })
            local state = get_cache().build_dirs["build/App/development"]
            assert.equals("built", state.state)
            assert.is_not_nil(state.last_configured)
            assert.is_not_nil(state.last_built)
        end)

        it("records build_dir from result (key is the build_dir)", function()
            local core, get_cache = make_recording_core()
            local unit = get_unit(core, "App", "development")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                build_dir = "/root/.nvim/build/App/development",
            })
            -- In v7, build_dir is the cache key, not a stored field
            assert.is_not_nil(get_cache().build_dirs["build/App/development"])
            -- ConfigUnit still tracks the absolute build_dir
            assert.equals("/root/.nvim/build/App/development", unit:build_dir())
        end)

        it("records module_info data from result", function()
            local core, get_cache = make_recording_core()
            local unit = get_unit(core, "App", "development")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                module_info = { compile_commands_dir = "/root/.nvim/build/App/development" },
            })
            assert.equals("/root/.nvim/build/App/development",
                get_cache().build_dirs["build/App/development"].module_info.compile_commands_dir)
        end)

        it("records tool_data from result", function()
            local core, get_cache = make_recording_core()
            local tool_data = {
                id = "ninja-gcc-14.2.0",
                display = "Ninja - GCC 14.2.0",
                generator = "Ninja",
                compiler_id = "gcc-14.2.0",
                compiler_path = "/usr/bin/g++-14",
            }
            local unit = get_unit(core, "App", "Debug:ninja-gcc-14.2.0")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                tool = { key = "ninja-gcc-14.2.0", data = tool_data },
            })
            local cached_td = get_cache().build_dirs["build/App/Debug"].tool_data
            assert.is_not_nil(cached_td)
            assert.equals("ninja-gcc-14.2.0", cached_td.id)
            assert.equals("Ninja - GCC 14.2.0", cached_td.display)
            assert.equals("Ninja", cached_td.generator)
            assert.equals("gcc-14.2.0", cached_td.compiler_id)
        end)

        it("preserves existing tool_data when result has no tool_data", function()
            local core, get_cache = make_recording_core()
            -- First, record with tool
            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                tool = { key = "ninja-gcc-14.2.0", data = { id = "ninja-gcc-14.2.0", display = "Ninja - GCC 14.2.0" } },
            })
            -- Second, record build without tool
            core:record_task_result({
                unit = unit,
                action = "build",
                success = true,
            })
            local cached = get_cache().build_dirs["build/App/Debug"]
            assert.equals("built", cached.state)
            assert.equals("ninja-gcc-14.2.0", cached.tool_data.id)
        end)

        it("calls parse_targets on successful configure and stores targets on ConfigUnit", function()
            local parse_called = false
            local parse_args = {}
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil, nil,
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                parse_targets = function(ctx)
                                    parse_called = true
                                    parse_args = { build_dir = ctx.build_dir, config_name = ctx.config_name }
                                    return {
                                        app = { type = "executable", dependencies = { "libcore" } },
                                        libcore = { type = "static_library" },
                                    }
                                end,
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "configure",
                variant = "Debug",
                success = true,
                build_dir = "/root/.nvim/build/App/Debug",
                cmake = { generator = "Ninja" },
            })

            assert.is_true(parse_called, "parse_targets should be called")
            assert.equals("/root/.nvim/build/App/Debug", parse_args.build_dir)
            assert.equals("Debug", parse_args.config_name)

            -- Targets should be stored on ConfigUnit (not in cache)
            assert.is_not_nil(unit.targets)
            assert.equals("executable", unit.targets.app.type)
            assert.are.same({ "libcore" }, unit.targets.app.dependencies)
            assert.equals("static_library", unit.targets.libcore.type)
        end)

        it("does not call parse_targets on failed configure", function()
            local parse_called = false
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil, nil,
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                parse_targets = function()
                                    parse_called = true
                                    return nil
                                end,
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = false,
                build_dir = "/root/.nvim/build/App/Debug",
            })

            assert.is_false(parse_called, "parse_targets should not be called on failure")
        end)

        it("does not call parse_targets on build action", function()
            local parse_called = false
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil, nil,
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                parse_targets = function()
                                    parse_called = true
                                    return nil
                                end,
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local unit = get_unit(core, "App", "Debug")
            core:record_task_result({
                unit = unit,
                action = "build",
                success = true,
                build_dir = "/root/.nvim/build/App/Debug",
            })

            assert.is_false(parse_called, "parse_targets should not be called for build")
        end)
    end)

    describe("get_project_options", function()
        it("delegates to module get_options with cached build_dir", function()
            local options_args = {}
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil,
                {
                    configurations = {
                        ["App/Debug"] = {
                            project_key = "App",
                            config_key = "Debug",
                            variant = "Debug",
                            type = "cmake",
                            state = "configured",
                            build_dir = "/root/.nvim/build/App/Debug",
                        },
                    },
                },
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                get_options = function(build_dir, config)
                                    options_args.build_dir = build_dir
                                    options_args.config = config
                                    return {
                                        { label = "Project Options", children = {
                                            { key = "BUILD_TESTING", value_type = "bool", value = "ON" },
                                        }},
                                    }
                                end,
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local options = get_unit(core, "App", "Debug"):options()
            assert.is_not_nil(options)
            assert.equals(1, #options)
            assert.equals("Project Options", options[1].label)
            assert.equals("BUILD_TESTING", options[1].children[1].key)
            assert.equals("/root/.nvim/build/App/Debug", options_args.build_dir)
        end)

        it("returns options even for unconfigured unit (build_dir is deterministic)", function()
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil, nil,
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                get_options = function() return {} end,
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            -- In v7, build_dir is always deterministic so options() delegates to module
            local options = get_unit(core, "App", "Debug"):options()
            assert.is_not_nil(options)
        end)

        it("returns nil when module has no get_options", function()
            local core = make_core(
                {
                    projects = { App = { cmake = {} } },
                },
                nil,
                {
                    configurations = {
                        ["App/Debug"] = {
                            project_key = "App",
                            config_key = "Debug",
                            variant = "Debug",
                            type = "cmake",
                            state = "configured",
                            build_dir = "/root/.nvim/build/App/Debug",
                        },
                    },
                },
                {
                    modules = {
                        get = function(mod_type)
                            if mod_type ~= "cmake" then return nil end
                            return {
                                validate = function() return { valid = true, warnings = {} } end,
                                info = function() return { configurations = { Debug = {} } } end,
                                -- no get_options
                            }
                        end,
                    },
                }
            )
            core:setup({ root = "/root" })

            local options = get_unit(core, "App", "Debug"):options()
            assert.is_nil(options)
        end)
    end)

    describe("cache version mismatch", function()
        local function make_mismatch_core(dep_overrides)
            -- Provide a cache file with wrong version
            local files = {
                ["loomworks.json"] = h.make_config_json(),
                ["loomworks.cache.json"] = vim.json.encode({
                    _meta = { version = 1, loomworks_hash = "", cached_at = "" },
                    configurations = {},
                }),
            }
            local deps = h.make_test_deps(files, dep_overrides)
            return Core.new(deps), deps
        end

        it("refuses to load workspace on version mismatch", function()
            local core = make_mismatch_core()
            core:setup({ root = "/test" })
            assert.equals("uninitialized", core:state())
            assert.is_nil(core:get_workspace())
        end)

        it("does not modify cache file on version mismatch", function()
            local writes = {}
            local core = make_mismatch_core({
                io = {
                    write_json = function(path, data)
                        writes[#writes + 1] = path
                        return true
                    end,
                },
            })
            core:setup({ root = "/test" })
            -- No files should have been written
            assert.equals(0, #writes)
        end)

        it("notifies user on version mismatch", function()
            local notifications = {}
            local core = make_mismatch_core({
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
            })
            core:setup({ root = "/test" })
            assert.equals(1, #notifications)
            assert.matches("version mismatch", notifications[1].msg)
            assert.equals(vim.log.levels.ERROR, notifications[1].level)
        end)

        it("stores setup error with root and message", function()
            local core = make_mismatch_core()
            core:setup({ root = "/test" })
            local err = core:get_setup_error()
            assert.is_not_nil(err)
            assert.equals("/test", err.root)
            assert.matches("version mismatch", err.message)
        end)

        it("clears setup error on successful setup", function()
            local core = make_core()
            core:setup({ root = "/test" })
            assert.is_nil(core:get_setup_error())
        end)
    end)

    describe("cache inconsistency", function()
        local function make_inconsistent_core(dep_overrides)
            -- Build dir entry missing project_key
            local files = {
                ["loomworks.json"] = h.make_config_json(),
                ["loomworks.cache.json"] = vim.json.encode({
                    _meta = { version = 8, loomworks_hash = "", cached_at = "" },
                    build_dirs = {
                        ["build/App/Debug"] = { variant = "Debug" },  -- missing project_key
                    },
                }),
            }
            local deps = h.make_test_deps(files, dep_overrides)
            return Core.new(deps), deps
        end

        it("refuses to load workspace on cache inconsistency", function()
            local core = make_inconsistent_core()
            core:setup({ root = "/test" })
            assert.equals("uninitialized", core:state())
            assert.is_nil(core:get_workspace())
        end)

        it("stores setup error with inconsistency message", function()
            local core = make_inconsistent_core()
            core:setup({ root = "/test" })
            local err = core:get_setup_error()
            assert.is_not_nil(err)
            assert.equals("/test", err.root)
            assert.matches("inconsistent", err.message)
        end)

        it("notifies user on cache inconsistency", function()
            local notifications = {}
            local core = make_inconsistent_core({
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
            })
            core:setup({ root = "/test" })
            assert.equals(1, #notifications)
            assert.matches("inconsistent", notifications[1].msg)
            assert.equals(vim.log.levels.ERROR, notifications[1].level)
        end)
    end)

    describe("user.json structurally invalid projects", function()
        -- Regression: a project object with two type-candidate keys (e.g. a
        -- hand-added `intent`) used to be silently dropped, and a later save
        -- persisted the drop — data loss. The load must now refuse instead.
        local function make_invalid_projects_core(dep_overrides)
            local files = {
                ["loomworks.json"] = h.make_config_json(),
                ["loomworks.user.json"] = vim.json.encode({
                    _meta = { version = 2 },
                    projects = { app = { cmake = vim.empty_dict(), intent = "shared" } },
                }),
            }
            local deps = h.make_test_deps(files, dep_overrides)
            return Core.new(deps), deps
        end

        it("refuses to load rather than dropping the project", function()
            local core = make_invalid_projects_core()
            core:setup({ root = "/test" })
            assert.equals("uninitialized", core:state())
            assert.is_nil(core:get_workspace())
        end)

        it("stores a setup error naming the invalid project", function()
            local core = make_invalid_projects_core()
            core:setup({ root = "/test" })
            local err = core:get_setup_error()
            assert.is_not_nil(err)
            assert.matches("user.json is invalid", err.message)
            assert.matches("app", err.message)
        end)
    end)

    describe("user.json version mismatch", function()
        local function make_user_mismatch_core(dep_overrides)
            local files = {
                ["loomworks.json"] = h.make_config_json(),
                ["loomworks.user.json"] = vim.json.encode({
                    _meta = { version = 999 },
                    active_profile = "debug",
                }),
            }
            local deps = h.make_test_deps(files, dep_overrides)
            return Core.new(deps), deps
        end

        it("refuses to load workspace on version mismatch", function()
            local core = make_user_mismatch_core()
            core:setup({ root = "/test" })
            assert.equals("uninitialized", core:state())
            assert.is_nil(core:get_workspace())
        end)

        it("stores setup error with user_version_mismatch flag", function()
            local core = make_user_mismatch_core()
            core:setup({ root = "/test" })
            local err = core:get_setup_error()
            assert.is_not_nil(err)
            assert.equals("/test", err.root)
            assert.matches("user.json", err.message)
            assert.is_true(err.user_version_mismatch)
        end)

        it("notifies user on version mismatch", function()
            local notifications = {}
            local core = make_user_mismatch_core({
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
            })
            core:setup({ root = "/test" })
            assert.equals(1, #notifications)
            assert.matches("user.json", notifications[1].msg)
            assert.equals(vim.log.levels.ERROR, notifications[1].level)
        end)

        it("delete_user_prefs removes file and reloads", function()
            local deleted = {}
            local files = {
                ["loomworks.json"] = h.make_config_json(),
                ["loomworks.user.json"] = vim.json.encode({
                    _meta = { version = 999 },
                    active_profile = "debug",
                }),
            }
            local deps = h.make_test_deps(files, {
                io = {
                    rm_rf = function(path)
                        deleted[#deleted + 1] = path
                        -- Remove from mock filesystem so reload doesn't find it
                        files["loomworks.user.json"] = nil
                        return true
                    end,
                },
            })
            local core = Core.new(deps)
            core:setup({ root = "/test" })
            assert.is_not_nil(core:get_setup_error())

            core:delete_user_prefs("/test")
            -- Should have deleted the user.json file
            assert.equals(1, #deleted)
            assert.matches("user.json", deleted[1])
            -- Should have reloaded successfully (no more setup error)
            assert.is_nil(core:get_setup_error())
            assert.is_not_nil(core:get_workspace())
        end)
    end)

    describe("nuke_cache", function()
        it("deletes build dir, cache file, and backup then reloads", function()
            local deleted = {}
            local core, deps = make_core(nil, nil, nil, {
                io = {
                    rm_rf = function(path)
                        deleted[#deleted + 1] = path
                        return true
                    end,
                },
            })
            core:setup({ root = "/test" })

            core:nuke_cache("/test")

            local found_build = false
            local found_cache = false
            local found_bak = false
            for _, p in ipairs(deleted) do
                if p:match("/%.nvim/build$") then found_build = true end
                if p:match("loomworks%.cache%.json$") then found_cache = true end
                if p:match("loomworks%.cache%.json%.bak$") then found_bak = true end
            end
            assert.is_true(found_build, "should delete .nvim/build")
            assert.is_true(found_cache, "should delete cache file")
            assert.is_true(found_bak, "should delete cache backup")
        end)

        it("re-setups after nuke", function()
            local core = make_core()
            core:setup({ root = "/test" })
            -- Nuke clears and re-setups
            core:nuke_cache("/test")
            assert.is_not_nil(core:get_workspace())
        end)

        it("refuses to delete paths outside .nvim/", function()
            local notifications = {}
            local deleted = {}
            local core = make_core(nil, nil, nil, {
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
                io = {
                    rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
                },
                cache = {
                    -- Return a path outside .nvim/ to test safety check
                    filepath = function() return "/somewhere/else/cache.json" end,
                },
            })
            core:setup({ root = "/test" })

            core:nuke_cache("/test")

            -- Should have refused and notified
            local found_refuse = false
            for _, n in ipairs(notifications) do
                if n.msg:match("refusing to delete") then found_refuse = true end
            end
            assert.is_true(found_refuse)
            -- Nothing should have been deleted
            assert.equals(0, #deleted)
        end)

        it("refuses when no loomworks.json at root", function()
            local notifications = {}
            local deleted = {}
            local files = {} -- no loomworks.json
            local deps = h.make_test_deps(files, {
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
                io = {
                    rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
                },
            })
            local core = Core.new(deps)

            core:nuke_cache("/test")

            local found_no_config = false
            for _, n in ipairs(notifications) do
                if n.msg:match("no loomworks%.json") then found_no_config = true end
            end
            assert.is_true(found_no_config)
            assert.equals(0, #deleted)
        end)

        it("refuses relative paths", function()
            local notifications = {}
            local deleted = {}
            local core = make_core(nil, nil, nil, {
                notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
                io = {
                    rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
                },
            })
            core:setup({ root = "/test" })

            core:nuke_cache("relative/path")

            local found_abs = false
            for _, n in ipairs(notifications) do
                if n.msg:match("absolute path") then found_abs = true end
            end
            assert.is_true(found_abs)
            assert.equals(0, #deleted)
        end)
    end)

    describe("_safe_nvim_path", function()
        it("accepts paths under root/.nvim/", function()
            local core = make_core()
            core:setup({ root = "/test" })
            assert.is_true(core:_safe_nvim_path("/test/.nvim/build", "/test"))
            assert.is_true(core:_safe_nvim_path("/test/.nvim/loomworks.cache.json", "/test"))
            assert.is_true(core:_safe_nvim_path("/test/.nvim/loomworks.cache.json.bak", "/test"))
        end)

        it("accepts the .nvim directory itself", function()
            local core = make_core()
            core:setup({ root = "/test" })
            assert.is_true(core:_safe_nvim_path("/test/.nvim", "/test"))
        end)

        it("rejects paths outside .nvim/", function()
            local core = make_core()
            core:setup({ root = "/test" })
            assert.is_false(core:_safe_nvim_path("/test/src/main.cpp", "/test"))
            assert.is_false(core:_safe_nvim_path("/other/project/.nvim/build", "/test"))
            assert.is_false(core:_safe_nvim_path("/test/.nvim-fake/build", "/test"))
        end)

        -- Directory traversal (e.g. /test/.nvim/../secret) is handled by
        -- vim.fs.normalize which resolves ".." before the prefix check runs.
        -- Not tested here because the test mock doesn't resolve "..".
    end)

end)
