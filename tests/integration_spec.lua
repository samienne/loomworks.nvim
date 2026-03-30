--- Integration tests for workspace_view orchestration.
---
--- Tests exercise the full domain stack (Workspace, merge, cache, profile,
--- config_unit) through workspace_view functions. Only I/O, notifications,
--- and scheduling are mocked. No Neovim UI APIs needed.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")
local wv = require("loomworks.workspace_view")

local Workspace = workspace.Workspace

--- Mock modules with info() returning detectable configurations.
local mock_modules = {
    cmake = {
        id = "cmake",
        has_keyed_tools = true,
        has_options = true,
        default_configurations = function()
            return { Debug = { variant = "Debug" }, Release = { variant = "Release" }, RelWithDebInfo = { variant = "RelWithDebInfo" } }
        end,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        tool_key = function(tool_data) return tool_data.id end,
        tool_label = function(tool_data) return tool_data.display end,
        detect_tools_async = function(callback) callback({}) end,
        info = function(path, config)
            local configs = {
                Debug = { variant = "Debug", is_default = true },
                Release = { variant = "Release", is_default = true },
                RelWithDebInfo = { variant = "RelWithDebInfo", is_default = true },
            }
            if config and config.configurations then
                for name, data in pairs(config.configurations) do
                    configs[name] = vim.tbl_extend("force", { is_user = true }, data)
                end
            end
            return { configurations = configs }
        end,
    },
    ets = {
        id = "ets",
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type or name == variant_type then return name end
            end
            return nil
        end,
        info = function()
            return { configurations = { debug = {}, release = {} } }
        end,
    },
    typescript = {
        id = "typescript",
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        info = function()
            return { configurations = { default = {} } }
        end,
    },
}

--- Create a real Workspace instance with mock deps for testing.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @return loomworks.Workspace, table events_log
local function make_ws(config_overrides, user_overrides, cache_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local cache_json = cache_overrides and h.make_cache_json(cache_overrides) or nil

    local data = workspace.assemble("/root", config_json, user_json, cache_json)
    assert(data, "assemble failed")

    local events_log = {}
    local mock_core = {
        _deps = {
            merge = merge,
            cache = cache_mod,
            events = {
                emit = function(event, ev_data)
                    events_log[#events_log + 1] = { event = event, data = ev_data }
                end,
            },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            clock = function() return 0 end,
            now = function() return "2000-01-01T00:00:00Z" end,
        },
        _events_log = events_log,
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws, events_log
end

-- =========================================================================
-- Config set lifecycle: create → edit → rename → delete
-- =========================================================================

describe("config set lifecycle", function()
    it("create → edit → rename → delete", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
        })

        -- 1. Create config set with auto-detected mappings
        local ctx = wv.compute_create_config_set_context(ws)
        assert.equals(2, #ctx.projects)
        local app = h.find_project_in(ws:get_projects(), "App")
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        assert.is_not_nil(ctx.available_configs[app])
        assert.is_not_nil(ctx.available_configs[frontend])

        local cs, err = wv.execute_create_config_set(ws, "Debug", {
            [app] = app:get_configuration("Debug"),
            [frontend] = frontend:get_configuration("debug"),
        })
        assert.is_not_nil(cs)
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(),"Debug"))

        -- 2. Edit: change Frontend mapping
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        assert.is_not_nil(edit_ctx)
        assert.equals("Debug", edit_ctx.mappings[app].name)
        assert.equals("debug", edit_ctx.mappings[frontend].name)

        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        ok = wv.execute_edit_config_set(cs, "Debug",
            { [app] = app:get_configuration("Release"), [frontend] = frontend:get_configuration("release") },
            edit_ctx.mappings)
        assert.is_true(ok)
        local debug_cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.equals("Release", h.cs_mapping(debug_cs, "App"))
        assert.equals("release", h.cs_mapping(debug_cs, "Frontend"))

        -- 3. Rename: Debug → Production
        cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        ok = wv.execute_edit_config_set(cs, "Production",
            { [app] = app:get_configuration("Release"), [frontend] = frontend:get_configuration("release") },
            edit_ctx.mappings)
        assert.is_true(ok)
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(), "Production"))

        -- 4. Delete
        local prod_cs = h.find_config_set_in(ws:get_config_sets(),"Production")
        local del_ctx = wv.compute_delete_config_set_context(ws, prod_cs)
        assert.is_not_nil(del_ctx)

        ok = wv.execute_delete_config_set(ws, prod_cs)
        assert.is_true(ok)
        -- Last set removed
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Production"))
    end)

    it("renaming config set updates profile key and survives round-trip", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Frontend = "debug" },
            },
        })

        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")

        -- Materialize a profile for "Debug" config set
        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals(2, #profile:projects())

        -- Rename config set: Debug → Release
        cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        local app = h.find_project_in(ws:get_projects(), "App")
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        local ok = wv.execute_edit_config_set(cs, "Release",
            { [app] = app:get_configuration("Debug"), [frontend] = frontend:get_configuration("debug") },
            edit_ctx.mappings)
        assert.is_true(ok)

        -- Config set should be renamed
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))
        local new_cs = h.find_config_set_in(ws:get_config_sets(), "Release")
        assert.is_not_nil(new_cs)

        -- Profile key must have updated to match new set name
        local new_profile = h.find_profile(ws:get_profiles(), "Release")
        assert.is_not_nil(new_profile, "Profile key should be renamed to 'Release'")
        assert.is_nil(h.find_profile(ws:get_profiles(), "Debug"),
            "Old profile key 'Debug' should no longer exist")

        -- Profile must still have its projects
        assert.equals(2, #new_profile:projects())

        -- Active profile key must track the rename
        assert.equals("Release", ws._active_profile_key)

        -- Round-trip: serialize cache and simulate reload
        local cache = ws:_serialize_cache()
        assert.is_not_nil(cache.profiles["Release"],
            "Serialized cache should have profile under new key 'Release'")
        assert.is_nil(cache.profiles["Debug"],
            "Serialized cache should not have profile under old key 'Debug'")
        assert.equals("Release", cache.profiles["Release"].configuration_set)
    end)

    it("create validates duplicate names", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })

        local app = h.find_project_in(ws:get_projects(), "App")
        local cs, err = wv.execute_create_config_set(ws, "Debug", {
            [app] = app:get_configuration("Debug"),
        })
        assert.is_nil(cs)
        assert.is_not_nil(err)
    end)

    it("edit removes mappings set to nil", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Frontend = "debug" },
            },
        })

        local app = h.find_project_in(ws:get_projects(), "App")
        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { [app] = app:get_configuration("Debug") }, -- Frontend removed
            edit_ctx.mappings)
        assert.is_true(ok)
        local debug_cs2 = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_nil(h.cs_mapping(debug_cs2, "Frontend"))
    end)
end)

-- =========================================================================
-- Profile lifecycle: create from config set → verify state
-- =========================================================================

describe("profile lifecycle", function()
    it("create profile from config set without tools", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { Debug = { Frontend = "debug" } },
        })

        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        assert.is_not_nil(cs)

        -- Create profile (activate since first)
        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals("Debug", ws._active_profile_key)
    end)

    it("materialized profile has projects and config units from config set", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Frontend = "debug" },
            },
        })

        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)

        -- Materialize profile (no tools)
        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)

        -- Profile must have ProfileProjects for both config set projects
        local pps = profile:projects()
        assert.equals(2, #pps)

        -- Each PP must have a resolved project and config unit
        local found_app, found_frontend = false, false
        for _, pp in ipairs(pps) do
            assert.is_not_nil(pp._project, "PP must have resolved project")
            assert.is_not_nil(pp._config_unit, "PP must have config unit")
            assert.is_not_nil(pp._config_unit._config_key, "ConfigUnit must have config_key")
            if pp._project.key == "App" then
                found_app = true
                assert.equals("Debug", pp:variant_name())
            elseif pp._project.key == "Frontend" then
                found_frontend = true
                assert.equals("debug", pp:variant_name())
            end
        end
        assert.is_true(found_app, "Profile must include App project")
        assert.is_true(found_frontend, "Profile must include Frontend project")

        -- Config units must be registered in workspace
        local app_unit, frontend_unit
        for _, unit in pairs(ws._config_units) do
            if unit._init_project_key == "App" then app_unit = unit end
            if unit._init_project_key == "Frontend" then frontend_unit = unit end
        end
        assert.is_not_nil(app_unit, "App ConfigUnit must be registered")
        assert.is_not_nil(frontend_unit, "Frontend ConfigUnit must be registered")

        -- Cache must contain entries for both
        local cache = ws:_serialize_cache()
        local found_configs = 0
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" or entry.project_key == "Frontend" then
                found_configs = found_configs + 1
            end
        end
        assert.equals(2, found_configs, "Cache must have entries for both projects")
    end)

    it("materialized profile with tool has correct tool-qualified config units", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", Frontend = "debug" },
            },
        })

        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        local tool_entry = {
            tool_key = "ninja-gcc",
            tool_data = { generator = "Ninja" },
            tool_label = "Ninja GCC",
            tool_mod_type = "cmake",
        }

        local profile = wv.execute_create_profile(cs, tool_entry, true)
        assert.is_not_nil(profile)

        local pps = profile:projects()
        assert.equals(2, #pps)

        -- App (cmake) should have tool-qualified config key
        -- Frontend (ets) should have bare config key
        for _, pp in ipairs(pps) do
            if pp._project.key == "App" then
                assert.truthy(pp._config_unit:config_key():find("ninja%-gcc"),
                    "cmake project should have tool-qualified config key")
            elseif pp._project.key == "Frontend" then
                assert.equals("debug", pp._config_unit:config_key(),
                    "ets project should have bare config key")
            end
        end
    end)

    it("create profile from config set with tool", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { ets = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Frontend = "debug" },
                },
            },
            nil,
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                    },
                },
            }
        )

        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")

        local tool_entry = {
            tool_key = "ninja-gcc-12",
            tool_data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" },
            tool_label = "Ninja - GCC 12",
            tool_mod_type = "cmake",
        }

        -- Create second profile (don't activate)
        local profile = wv.execute_create_profile(cs, tool_entry, false)
        assert.is_not_nil(profile)
        -- Profile key should include tool
        assert.truthy(profile.key:find("ninja%-gcc%-12"))
    end)

    it("resolve_config_set_choice handles auto-detected sets", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local choice = {
            auto = true,
            real_name = "Debug",
            mappings = { App = "Debug" },
        }

        local cs, err = wv.resolve_config_set_choice(ws, choice)
        assert.is_not_nil(cs)
        assert.is_nil(err)
        -- Config set was created in workspace
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))
    end)

    it("resolve_config_set_choice passes through existing sets", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })

        local config_sets = ws:get_config_sets()
        local choice = { auto = false, cs = config_sets["Debug"] }

        local cs, err = wv.resolve_config_set_choice(ws, choice)
        assert.equals(config_sets["Debug"], cs)
        assert.is_nil(err)
    end)
end)

-- =========================================================================
-- Project lifecycle: add → remove with cached configs
-- =========================================================================

describe("project lifecycle", function()
    it("add project with mappings then remove with cleanup", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = {
                Debug = { Frontend = "debug" },
                Release = { Frontend = "release" },
            },
        })

        -- Add project with mappings
        local result = { mappings = { Debug = "Debug", Release = "Release" }, tool_entry = nil }
        local ok, err = wv.execute_add_project(ws, "App", "cmake", nil, result, false)
        assert.is_true(ok)
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "App"))
        -- Check via domain objects
        local debug_cs = nil
        for _, cs in pairs(ws._config_sets) do
            if cs.name == "Debug" then debug_cs = cs; break end
        end
        assert.is_not_nil(debug_cs)
        local app_variant = nil
        for proj, config in pairs(debug_cs.mappings) do
            if proj.key == "App" then app_variant = config.name end
        end
        assert.equals("Debug", app_variant)

        -- Simulate cached state by injecting cache before remerge
        local bd_key = h.build_dir_key("App", "Debug")
        local injected_cache = {
            _meta = {},
            build_dirs = {
                [bd_key] = {
                    project_key = "App", config_key = "Debug",
                    type = "cmake", variant = "Debug", state = "built",
                    build_dir = "/root/.nvim/build/App/Debug",
                },
            },
        }
        ws:remerge(nil, injected_cache)

        -- Compute removal context
        local app = h.find_project_in(ws:get_projects(), "App")
        local ctx = wv.compute_remove_context(ws, app)
        assert.is_not_nil(ctx)
        assert.equals("cmake", ctx.project_type)
        assert.equals(1, #ctx.cached_configs)

        -- Execute removal
        local done = false
        wv.execute_remove_project(ws, app, ctx, function(success)
            done = true
            assert.is_true(success)
        end)
        assert.is_true(done)
        assert.is_nil(h.find_project_in(ws:get_projects(), "App"))
        local post_cache = ws:_serialize_cache()
        assert.is_nil(post_cache.build_dirs[bd_key])
    end)

    it("prepare_add_project_from_browser returns add_direct when no config sets", function()
        local ws = make_ws({ projects = {} })

        local prep = wv.prepare_add_project_from_browser(
            ws, "/root", "/root/MyApp", "MyApp", "cmake")
        assert.equals("add_direct", prep.action)
        assert.equals("MyApp", prep.key)
    end)

    it("prepare_add_project_from_browser returns show_dialog when config sets exist", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { Debug = { Frontend = "debug" } },
        })

        local prep = wv.prepare_add_project_from_browser(
            ws, "/root", "/root/App", "App", "cmake")
        assert.equals("show_dialog", prep.action)
        assert.equals("App", prep.key)
        assert.is_true(#prep.config_names > 0)
        assert.is_true(prep.has_keyed)
    end)

    it("find_project_by_path matches by path", function()
        local ws = make_ws({
            projects = {
                MyApp = { cmake = {}, path = "src/app" },
            },
        })

        local proj = wv.find_project_by_path(ws, "src/app", "app")
        assert.is_not_nil(proj)
        assert.equals("MyApp", proj.key)
        assert.is_nil(wv.find_project_by_path(ws, "other", "other"))
    end)

    it("find_project_by_path matches by basename", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local proj = wv.find_project_by_path(ws, "App", "App")
        assert.is_not_nil(proj)
        assert.equals("App", proj.key)
    end)

    it("derive_key_and_path handles root, root-level, and nested", function()
        local key, path

        -- Root itself
        key, path = wv.derive_key_and_path("/root", "/root", "myproject")
        assert.equals("myproject", key)
        assert.equals(".", path)

        -- Root-level child
        key, path = wv.derive_key_and_path("/root", "/root/App", "App")
        assert.equals("App", key)
        assert.is_nil(path)

        -- Nested
        key, path = wv.derive_key_and_path("/root", "/root/src/lib", "lib")
        assert.equals("src_lib", key)
        assert.equals("src/lib", path)
    end)
end)

-- =========================================================================
-- Profile upgrade/downgrade when adding/removing keyed-tool projects
-- =========================================================================

describe("profile upgrade and downgrade", function()
    local tool_entry = {
        tool_key = "ninja-gcc-12",
        tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" },
        tool_label = "Ninja - GCC 12",
        tool_mod_type = "cmake",
    }

    it("adding keyed-tool project upgrades profiles and creates skeletons", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                },
            },
            { active_profile = "Debug" },
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug", state = "configured",
                    },
                },
            }
        )

        -- Add cmake project with tool
        local result = {
            mappings = { Debug = "Debug" },
            tool_entry = tool_entry,
        }
        local ok = wv.execute_add_project(ws, "App", "cmake", nil, result, true)
        assert.is_true(ok)

        -- Profile upgraded: Debug → Debug:ninja-gcc-12
        local cache = ws:_serialize_cache()
        assert.is_nil(cache.profiles["Debug"])
        assert.is_not_nil(cache.profiles["Debug:ninja-gcc-12"])
        assert.equals("Debug:ninja-gcc-12", ws._active_profile_key)

        -- Skeleton cache entry created for cmake project (build_dir-keyed)
        local cmake_entry = nil
        local frontend_entry = nil
        local frontend_tooled = false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "Debug"
                    and entry.tool_key == "ninja-gcc-12" then
                cmake_entry = entry
            end
            if entry.project_key == "Frontend" and entry.variant == "debug" then
                frontend_entry = entry
                if entry.tool_key then frontend_tooled = true end
            end
        end
        assert.is_not_nil(cmake_entry, "cmake skeleton should exist")
        assert.equals("cmake", cmake_entry.type)

        -- Non-keyed entry preserved without tool suffix
        assert.is_not_nil(frontend_entry, "Frontend entry should exist")
        assert.is_false(frontend_tooled, "Frontend should not have tool key")
    end)

    it("removing last keyed-tool project downgrades profiles", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { Frontend = "debug", App = "Debug" },
                },
            },
            { active_profile = "Debug:ninja-gcc-12" },
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = {
                            cmake = { key = "ninja-gcc-12", data = {}, label = "Ninja - GCC 12" },
                        },
                        configurations = { "Frontend/debug", "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                    },
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc-12",
                        type = "cmake", variant = "Debug",
                    },
                },
            }
        )

        local app = h.find_project_in(ws:get_projects(), "App")
        local ctx = wv.compute_remove_context(ws, app)
        assert.equals(1, #ctx.downgrade_preview)

        local done = false
        wv.execute_remove_project(ws, app, ctx, function(ok)
            done = true
            assert.is_true(ok)
        end)
        assert.is_true(done)

        -- Profile downgraded: Debug:ninja-gcc-12 → Debug
        local cache = ws:_serialize_cache()
        assert.is_nil(cache.profiles["Debug:ninja-gcc-12"])
        assert.is_not_nil(cache.profiles["Debug"])
        assert.is_nil(cache.profiles["Debug"].tools)
        assert.equals("Debug", ws._active_profile_key)
    end)

    it("pinned profiles are not affected by upgrade", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = { Debug = { Frontend = "debug", App = "Debug" } },
            },
            nil,
            {
                profiles = {
                    -- Pinned profile (no configuration_set)
                    ["App/Debug"] = {
                        configurations = { "App/Debug" },
                    },
                    -- Set-based profile
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App", config_key = "Debug",
                        type = "cmake", variant = "Debug",
                    },
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- Set-based profile upgraded
        local cache = ws:_serialize_cache()
        assert.is_nil(cache.profiles["Debug"])
        assert.is_not_nil(cache.profiles["Debug:ninja-gcc-12"])

        -- Pinned profile unchanged
        assert.is_not_nil(cache.profiles["App/Debug"])
        assert.is_nil(cache.profiles["App/Debug"].tools)
    end)

    it("downgrade is no-op when other keyed-module projects remain", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
                configuration_sets = { Debug = { App = "Debug", Lib = "Debug" } },
            },
            nil,
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12", "Lib/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                    ["Lib/Debug:ninja-gcc-12"] = { project_key = "Lib", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                },
            }
        )

        ws:downgrade_profiles_from_tool("cmake")

        -- Profile unchanged — Lib still uses cmake
        local cache = ws:_serialize_cache()
        assert.is_not_nil(cache.profiles["Debug:ninja-gcc-12"])
        assert.is_nil(cache.profiles["Debug"])
    end)
end)

-- =========================================================================
-- Orphan lifecycle: delete config set → orphans appear → clean up
-- =========================================================================

describe("orphan lifecycle", function()
    it("deleting config set then profile orphans configs, cleanup removes them", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            { active_profile = "Debug" },
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/debug",
                    },
                },
            }
        )

        -- Initially no orphans
        assert.equals(0, #ws:get_orphaned_configs())

        -- Delete config set — profile becomes orphaned_set but still
        -- references the config via cached configurations
        local ok = wv.execute_delete_config_set(ws, h.find_config_set_in(ws:get_config_sets(),"Debug"))
        assert.is_true(ok)

        -- Profile is orphaned_set
        local profiles = ws:get_config_sets()
        local profile = h.find_profile(ws:get_profiles(), "Debug")
        assert.is_not_nil(profile)
        assert.is_true(profile.orphaned_set)

        -- Config still referenced by orphaned profile → not orphaned yet
        assert.equals(0, #ws:get_orphaned_configs())

        -- Delete the profile from cache → config becomes orphaned
        local temp_cache = ws:_serialize_cache()
        temp_cache.profiles["Debug"] = nil
        ws:remerge(nil, temp_cache)

        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("Frontend", orphans[1].project_key)

        -- Compute cleanup context
        local ctx = wv.compute_orphan_cleanup_context(ws)
        assert.equals(1, #ctx.orphaned_configs)

        -- Execute cleanup
        local done = false
        wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, function()
            done = true
        end)
        assert.is_true(done)

        -- Cache entry removed (v7: check by property match)
        local found = false
        for _, entry in pairs(ws:_serialize_cache().build_dirs) do
            if entry.project_key == "Frontend" and entry.variant == "debug" then found = true end
        end
        assert.is_false(found, "orphan should be cleaned from cache")
        assert.equals(0, #ws:get_orphaned_configs())
    end)

    it("editing config set mappings can create orphans", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            nil,
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug", state = "configured",
                    },
                },
            }
        )

        -- Change mapping from "debug" to "release"
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { [frontend] = frontend:get_configuration("release") },
            edit_ctx.mappings)
        assert.is_true(ok)
        local debug_cs3 = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.equals("release", h.cs_mapping(debug_cs3, "Frontend"))

        -- Frontend/debug is now orphaned (profile references "release", not "debug")
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("debug", orphans[1].config_key)
    end)
end)

-- =========================================================================
-- Confirmation context builders
-- =========================================================================

describe("confirmation contexts", function()
    it("clean confirmation includes running tasks and items", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local items = {
            { project_key = "App", config_key = "Debug", build_dir = "/root/.nvim/build/App/Debug" },
        }
        local ctx = wv.compute_clean_confirmation_context(ws, "Clean profile: Debug", items)
        assert.is_not_nil(ctx.lines)
        assert.is_not_nil(ctx.highlights)

        -- Title present
        local found_title = false
        for _, line in ipairs(ctx.lines) do
            if line:find("Clean profile: Debug") then found_title = true; break end
        end
        assert.is_true(found_title)
    end)

    it("delete confirmation splits items by disposition", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local plan = {
            items = {
                { project_key = "App", config_key = "Debug", disposition = "clean",
                  build_dir = "/root/.nvim/build/App/Debug" },
                { project_key = "App", config_key = "Release", disposition = "reset" },
                { project_key = "App", config_key = "Shared", disposition = "keep" },
            },
        }

        local ctx = wv.compute_delete_confirmation_context(ws, "Delete profile: X", plan)

        local found_remove, found_reset, found_keep = false, false, false
        for _, line in ipairs(ctx.lines) do
            if line:find("Will remove") then found_remove = true end
            if line:find("Will reset") then found_reset = true end
            if line:find("Will keep") then found_keep = true end
        end
        assert.is_true(found_remove)
        assert.is_true(found_reset)
        assert.is_true(found_keep)
    end)

    it("delete confirmation shows empty message when no items", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        local plan = { items = {}, profile = { key = "Debug" } }
        local ctx = wv.compute_delete_confirmation_context(ws, "Delete profile: Debug", plan)

        local found = false
        for _, line in ipairs(ctx.lines) do
            if line:find("No configurations to clean") then found = true; break end
        end
        assert.is_true(found)
    end)

    it("stray dir confirmation shows relative path", function()
        local ws = make_ws({ projects = {} })

        local ctx = wv.compute_delete_stray_dir_context(ws, "/root/.nvim/build/OldProject")
        local found = false
        for _, line in ipairs(ctx.lines) do
            if line:find("OldProject") then found = true; break end
        end
        assert.is_true(found)
    end)
end)

-- =========================================================================
-- Collect helpers
-- =========================================================================

describe("collect helpers", function()
    it("collect_clean_items gathers profile project data", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            nil,
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/debug",
                    },
                },
            }
        )

        local debug_cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        local profiles = debug_cs:find_profile(nil)
        assert.is_not_nil(profiles)

        local items = wv.collect_clean_items(profiles)
        assert.equals(1, #items)
        assert.equals("Frontend", items[1].project_key)
        assert.equals("debug", items[1].config_key)
        assert.equals("/root/.nvim/build/Frontend/debug", items[1].build_dir)
    end)

    it("collect_clean_items_for_unit returns single item", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            nil,
            {
                profiles = {
                    ["App/Debug"] = {
                        configurations = { "App/Debug" },
                        mappings = { App = "Debug" },
                    },
                },
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App", config_key = "Debug",
                        type = "cmake", variant = "Debug", state = "configured",
                    },
                },
            }
        )
        local unit = h.find_config_unit(ws._config_units, "App", "Debug")
        local items = wv.collect_clean_items_for_unit(unit)
        assert.equals(1, #items)
        assert.equals(unit, items[1].unit)
        assert.equals("App", items[1].unit._project.key)
        assert.equals("Debug", items[1].unit:config_key())
    end)
end)

-- =========================================================================
-- Rename with profile migration
-- =========================================================================

describe("config set rename", function()
    it("migrates cached profiles to new name", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Frontend = { ets = {} },
                },
                configuration_sets = {
                    debug = { App = "Debug", Frontend = "debug" },
                },
            },
            nil,
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = {
                            cmake = { key = "ninja-gcc-12", data = {}, label = "Ninja - GCC 12" },
                        },
                        configurations = { "App/Debug:ninja-gcc-12", "Frontend/debug" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc-12",
                        type = "cmake", variant = "Debug",
                    },
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                    },
                },
            }
        )

        local ok = wv.execute_rename_config_set(ws, h.find_config_set_in(ws:get_config_sets(),"debug"), "Debug",
            { App = "Debug", Frontend = "debug" })
        assert.is_true(ok)

        -- Old set gone, new set exists
        assert.is_nil(h.find_config_set_in(ws:get_config_sets(), "debug"))
        assert.is_not_nil(h.find_config_set_in(ws:get_config_sets(), "Debug"))

        -- Profile key must have been renamed alongside the set
        local cache = ws:_serialize_cache()
        assert.is_nil(cache.profiles["debug:ninja-gcc-12"],
            "old profile key should be gone")
        assert.is_not_nil(cache.profiles["Debug:ninja-gcc-12"],
            "profile key should use new set name")
        assert.equals("Debug",
            cache.profiles["Debug:ninja-gcc-12"].configuration_set)
    end)
end)

-- =========================================================================
-- Case collision prevention
-- =========================================================================

describe("name validation and collision prevention", function()
    it("add_configuration_set rejects case-colliding name", function()
        local ws = make_ws({
            configuration_sets = { Debug = { App = "Debug" } },
        })
        local cs, err = ws:add_configuration_set("debug", { App = "debug" })
        assert.is_nil(cs)
        assert.matches("case%-insensitive", err)
    end)

    it("add_project rejects case-colliding key", function()
        local ws = make_ws()
        -- "App" already exists from default config
        local proj, err = ws:add_project("app", "cmake")
        assert.is_nil(proj)
        assert.matches("same build directory", err)
    end)

    it("add_project rejects slashes in key", function()
        local ws = make_ws()
        local proj, err = ws:add_project("foo/bar", "cmake")
        assert.is_nil(proj)
        assert.matches("slashes", err)
    end)

    it("add_project rejects dot-dot key", function()
        local ws = make_ws()
        local proj, err = ws:add_project("..", "cmake")
        assert.is_nil(proj)
    end)

    it("add_project rejects sanitization collision", function()
        local ws = make_ws({ projects = { ["My_App"] = { cmake = {} } } })
        -- "My:App" sanitizes to "My_App" — collision
        local proj, err = ws:add_project("My:App", "cmake")
        assert.is_nil(proj)
        assert.matches("same build directory", err)
    end)

    it("save_configuration rejects slashes", function()
        local ws = make_ws()
        local project = h.find_project_in(ws:get_projects(), "App")
        local ok, err = project:save_configuration("foo/bar", {})
        assert.is_false(ok)
        assert.matches("slashes", err)
    end)
end)

-- =========================================================================
-- Configuration rename propagation
-- =========================================================================

describe("configuration rename propagation", function()
    it("renames config and updates config set mappings", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug", options = { ASAN = "ON" } },
                        },
                    },
                },
            },
            configuration_sets = {
                debug = { App = "Debug-asan" },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)

        -- Config renamed on Configuration domain objects
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_nil(app:get_configuration("Debug-asan"))
        local renamed_cfg = app:get_configuration("DebugASAN")
        assert.is_not_nil(renamed_cfg)
        assert.is_true(renamed_cfg.is_user)

        -- Config set mapping updated
        local debug_cs_rename = h.find_config_set_in(ws:get_config_sets(), "debug")
        assert.equals("DebugASAN", h.cs_mapping(debug_cs_rename, "App"))
    end)

    it("migrates cache entries and preserves build_dir", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
            configuration_sets = {
                debug = { App = "Debug-asan" },
            },
        }, nil, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "Ninja GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {})
        assert.is_true(ok)

        -- Old variant gone, new variant exists in cache
        local cache = ws:_serialize_cache()
        local old_entry = nil
        local new_entry = nil
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "Debug-asan" then old_entry = entry end
            if entry.project_key == "App" and entry.variant == "DebugASAN" then new_entry = entry end
        end
        assert.is_nil(old_entry)
        assert.is_not_nil(new_entry)

        -- Fields updated
        assert.equals("DebugASAN", new_entry.variant)

        -- Profile configurations array updated
        local profile = cache.profiles["debug:ninja-gcc"]
        assert.is_not_nil(profile)
    end)

    it("updates inherits in sibling configs", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            base = { options = { X = "1" } },
                            child = { inherits = "base", options = { Y = "2" } },
                            multi = { inherits = { "Debug", "base" } },
                        },
                    },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("base", "BaseConfig", {
            options = { X = "1" },
        })
        assert.is_true(ok)

        -- String inherits updated on Configuration domain objects
        local app = h.find_project_in(ws:get_projects(), "App")
        local child_cfg = app:get_configuration("child")
        assert.is_not_nil(child_cfg)
        assert.same({ "BaseConfig" }, child_cfg.inherits_names)

        -- Array inherits updated
        local multi_cfg = app:get_configuration("multi")
        assert.is_not_nil(multi_cfg)
        assert.equals("Debug", multi_cfg.inherits_names[1])
        assert.equals("BaseConfig", multi_cfg.inherits_names[2])
    end)

    it("succeeds with no cache entries", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            old = { options = { A = "1" } },
                        },
                    },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("old", "new", {
            options = { A = "1" },
        })
        assert.is_true(ok)
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_nil(app:get_configuration("old"))
        local new_cfg = app:get_configuration("new")
        assert.is_not_nil(new_cfg)
        assert.is_true(new_cfg.is_user)
    end)

    it("updates multiple profiles referencing same variant", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
            configuration_sets = {
                debug = { App = "Debug-asan" },
            },
        }, nil, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
                ["build/App/ninja-clang/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-clang",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-clang",
                    tool_data = { id = "ninja-clang" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-clang/Debug-asan",
                },
            },
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
                ["debug:ninja-clang"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-clang", data = { id = "ninja-clang" }, label = "Clang" } },
                    configurations = { "build/App/ninja-clang/Debug-asan" },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {})
        assert.is_true(ok)

        -- Both variants migrated in cache
        local cache = ws:_serialize_cache()
        local found_gcc, found_clang = false, false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "DebugASAN" then
                if entry.tool_key == "ninja-gcc" then found_gcc = true end
                if entry.tool_key == "ninja-clang" then found_clang = true end
            end
        end
        assert.is_true(found_gcc, "gcc entry should have new variant")
        assert.is_true(found_clang, "clang entry should have new variant")
    end)

    it("updates pinned profile mappings", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
        }, nil, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Old pinned profile key gone
        local cache = ws:_serialize_cache()
        assert.is_nil(cache.profiles["App/Debug-asan:ninja-gcc"])

        -- New pinned profile key exists with updated mapping
        local profile = cache.profiles["App/DebugASAN:ninja-gcc"]
        assert.is_not_nil(profile)
        assert.equals("DebugASAN", profile.mappings.App)
    end)

    it("updates active_profile when pinned profile key changes", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
        }, {
            active_profile = "App/Debug-asan:ninja-gcc",
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
            },
        })

        assert.equals("App/Debug-asan:ninja-gcc", ws._active_profile_key)

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Active profile updated to new key
        assert.equals("App/DebugASAN:ninja-gcc", ws._active_profile_key)
    end)

    it("rename updates Configuration domain objects and PP resolves new name", function()
        -- Simulates: user configures Debug-asan, then renames it to DebugASAN.
        -- The PP._configuration must resolve to the renamed Configuration.
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
            configuration_sets = {
                asan = { App = "Debug-asan" },
            },
        }, nil, {
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["asan:ninja-gcc"] = {
                    configuration_set = "asan",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" }, label = "GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
            },
        })

        -- Before rename: PP resolves correctly
        local profile = h.find_profile(ws:get_profiles(), "asan:ninja-gcc")
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("Debug-asan", pp:variant_name())
        assert.is_not_nil(pp:configuration())

        -- Rename
        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Configuration domain object exists under new name
        assert.is_not_nil(project:get_configuration("DebugASAN"))
        assert.is_nil(project:get_configuration("Debug-asan"))

        -- PP resolves the renamed Configuration
        profile = h.find_profile(ws:get_profiles(), "asan:ninja-gcc")
        pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("DebugASAN", pp:variant_name())
        assert.is_not_nil(pp:configuration())
        assert.equals("DebugASAN", pp:configuration().name)
    end)

    it("rename updates pinned profile PP._configuration", function()
        -- Simulates: pinned profile references Debug-asan, user renames to DebugASAN.
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
        }, nil, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc", display = "GCC" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" }, label = "GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
            },
        })

        -- Before rename: PP works
        local profile = h.find_profile(ws:get_profiles(), "App/Debug-asan:ninja-gcc")
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.equals("Debug-asan", pp:variant_name())

        -- Rename
        local ok = h.find_project_in(ws:get_projects(), "App"):rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Pinned profile key changed
        assert.is_nil(h.find_profile(ws:get_profiles(), "App/Debug-asan:ninja-gcc"))
        profile = h.find_profile(ws:get_profiles(), "App/DebugASAN:ninja-gcc")
        assert.is_not_nil(profile)

        -- PP resolves new name
        pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("DebugASAN", pp:variant_name())
        assert.is_not_nil(pp:configuration())
    end)

    it("rename while building preserves running state on ProfileProject", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-asan"] = { inherits = "Debug" },
                        },
                    },
                },
            },
            configuration_sets = {
                debug = { App = "Debug-asan" },
            },
        }, nil, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                    configurations = { "build/App/ninja-gcc/Debug-asan" },
                },
            },
        })

        -- Simulate a running build on the config unit
        local old_unit = h.find_config_unit(ws._config_units, "App", "Debug-asan")
        assert.is_not_nil(old_unit)
        old_unit:register_task(42, "build")
        assert.is_true(old_unit:is_running())

        -- Verify ProfileProject sees the running state before rename
        local profile = h.find_profile(ws:get_profiles(), "debug:ninja-gcc")
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("build", pp:running_action())

        -- Rename while building
        local ok = h.find_project_in(ws:get_projects(), "App"):rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- ConfigUnit should have the new variant and still be running
        local new_unit = h.find_config_unit(ws._config_units, "App", "DebugASAN")
        assert.is_not_nil(new_unit)
        assert.is_true(new_unit:is_running())
        assert.equals("build", new_unit:running_action())
        -- Should be the same object (identity preserved)
        assert.is_true(rawequal(old_unit, new_unit))

        -- ProfileProject should still see running state
        profile = h.find_profile(ws:get_profiles(), "debug:ninja-gcc")
        pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("build", pp:running_action())
        assert.equals("DebugASAN", pp:variant_name())

        -- Old variant should no longer exist
        assert.is_nil(h.find_config_unit(ws._config_units, "App", "Debug-asan"))
    end)

    it("cache-only variant creates Configuration for PP resolution", function()
        -- Simulates: variant exists only in cache (source removed, e.g. branch switch).
        -- PP should still resolve via cache-enriched Configuration.
        local ws = make_ws({
            projects = {
                App = { cmake = {} },  -- no user-defined configs
            },
            configuration_sets = {
                custom = { App = "CustomBuild" },
            },
        }, nil, {
            configurations = {
                ["App/CustomBuild:ninja-gcc"] = {
                    project_key = "App", config_key = "CustomBuild:ninja-gcc",
                    type = "cmake", variant = "CustomBuild", tool_key = "ninja-gcc",
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/CustomBuild",
                },
            },
            profiles = {
                ["custom:ninja-gcc"] = {
                    configuration_set = "custom",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" }, label = "GCC" } },
                    configurations = { "App/CustomBuild:ninja-gcc" },
                },
            },
        })

        -- "CustomBuild" is not in cmake defaults or user configs,
        -- but exists in cache — should be enriched as _source_missing
        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("CustomBuild")
        assert.is_not_nil(cfg)
        assert.is_true(cfg._source_missing)

        -- PP resolves the cache-enriched Configuration
        local profile = h.find_profile(ws:get_profiles(), "custom:ninja-gcc")
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("CustomBuild", pp:variant_name())
        assert.is_not_nil(pp:configuration())
        assert.is_true(pp:configuration()._source_missing)
    end)

    it("save_configuration creates Configuration domain object for PP", function()
        -- Simulates: user creates a new custom config, then a profile uses it.
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = {
                custom = { App = "Debug" },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")

        -- Create a new configuration
        local ok = project:save_configuration("Debug-ASAN", {
            inherits = "Debug",
            options = { ASAN = "ON" },
        })
        assert.is_true(ok)

        -- Configuration domain object exists immediately
        local cfg = project:get_configuration("Debug-ASAN")
        assert.is_not_nil(cfg)
        assert.is_false(cfg._source_missing)
        assert.is_true(cfg.is_user)

        -- Update config set to use the new configuration
        local cs = h.find_config_set_in(ws:get_config_sets(),"custom")
        ok = cs:update_mapping(project, cfg)
        assert.is_true(ok)

        -- PP now resolves the new Configuration
        for _, profile in pairs(ws._profiles) do
            if profile._config_set_ref == cs then
                local pp = profile:project("App")
                if pp then
                    assert.equals("Debug-ASAN", pp:variant_name())
                    assert.is_not_nil(pp:configuration())
                end
            end
        end
    end)

    it("execute_save_configuration uses rename for name change", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            old_cfg = { options = { A = "1" } },
                        },
                    },
                },
            },
            configuration_sets = {
                debug = { App = "old_cfg" },
            },
        })

        local ok = wv.execute_save_configuration(h.find_project_in(ws:get_projects(), "App"), "old_cfg", "new_cfg", {
            options = { A = "1" },
        })
        assert.is_true(ok)

        -- Config renamed (not delete+create)
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_nil(app:get_configuration("old_cfg"))
        local new_cfg = app:get_configuration("new_cfg")
        assert.is_not_nil(new_cfg)
        assert.is_true(new_cfg.is_user)

        -- Config set mapping updated atomically
        local debug_cs_exec = h.find_config_set_in(ws:get_config_sets(), "debug")
        assert.equals("new_cfg", h.cs_mapping(debug_cs_exec, "App"))
    end)
end)

-- =========================================================================
-- End-to-end: full workspace setup from scratch
-- =========================================================================

describe("end-to-end workspace setup", function()
    it("empty workspace → add projects → create config set → create profile", function()
        local ws = make_ws({ projects = {} })

        -- Add two projects
        local ok, err = wv.execute_add_project(ws, "App", "cmake", nil, { mappings = {} }, false)
        assert.is_true(ok)
        ok, err = wv.execute_add_project(ws, "Frontend", "ets", nil, { mappings = {} }, false)
        assert.is_true(ok)

        -- Remerge so projects get Configuration objects from module defaults
        ws:remerge()

        -- Create config set
        local app = h.find_project_in(ws:get_projects(), "App")
        local frontend = h.find_project_in(ws:get_projects(), "Frontend")
        local cs = wv.execute_create_config_set(ws, "Debug", {
            [app] = app:get_configuration("Debug"),
            [frontend] = frontend:get_configuration("debug"),
        })
        assert.is_not_nil(cs)

        -- Verify config set context is correct
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        assert.is_not_nil(edit_ctx)
        assert.equals(2, #edit_ctx.projects)
        assert.equals("Debug", edit_ctx.mappings[app].name)
        assert.equals("debug", edit_ctx.mappings[frontend].name)

        -- Create profile from config set
        local cs = h.find_config_set_in(ws:get_config_sets(),"Debug")
        assert.is_not_nil(cs)

        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", ws._active_profile_key)

        -- Profile has correct projects
        local pps = profile:projects()
        assert.equals(2, #pps)
    end)
end)

-- =========================================================================
-- Launch config lifecycle: create → edit → rename → delete
-- =========================================================================

describe("launch config lifecycle", function()
    it("create → edit → rename → delete", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },
                Frontend = { ets = {} },
            },
        })

        -- 1. Create launch config
        local app = h.find_project_in(ws:get_projects(), "App")
        local ok, err = wv.execute_save_launch_config(app, nil, "debug", {
            command = "node",
            args = { "app.js" },
            working_dir = "${workspace_root}/App",
            env = { NODE_ENV = "development" },
        })
        assert.is_true(ok)
        assert.is_not_nil(app.launch)
        assert.is_not_nil(app.launch["debug"])
        assert.equals("node", app.launch["debug"].command)

        -- 2. Get launch configs
        local configs = wv.get_launch_configs(app)
        assert.equals(1, #configs)
        assert.equals("debug", configs[1].name)

        -- 3. Edit: change command and add env var
        ok = wv.execute_save_launch_config(app, "debug", "debug", {
            command = "npx",
            args = { "ts-node", "app.ts" },
            working_dir = "${workspace_root}/App",
            env = { NODE_ENV = "development", DEBUG = "true" },
        })
        assert.is_true(ok)
        assert.equals("npx", h.find_project_in(ws:get_projects(), "App").launch["debug"].command)
        assert.equals("true", h.find_project_in(ws:get_projects(), "App").launch["debug"].env.DEBUG)

        -- 4. Rename: debug → dev
        ok = wv.execute_save_launch_config(app, "debug", "dev", {
            command = "npx",
            args = { "ts-node", "app.ts" },
            working_dir = "",
            env = { NODE_ENV = "development" },
        })
        assert.is_true(ok)
        assert.is_nil(h.find_project_in(ws:get_projects(), "App").launch["debug"])
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "App").launch["dev"])

        -- 5. Delete
        ok = wv.execute_delete_launch_config(app, "dev")
        assert.is_true(ok)
        -- launch key cleaned up when empty
        assert.is_nil(h.find_project_in(ws:get_projects(), "App").launch)
    end)

    it("compute_edit_launch_context returns defaults for new config", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        local ctx = wv.compute_edit_launch_context(h.find_project_in(ws:get_projects(), "App"), nil)
        assert.equals("App", ctx.project_key)
        assert.equals("", ctx.name)
        assert.equals("", ctx.command)
        assert.equals(0, #ctx.args)
        assert.equals("", ctx.working_dir)
        assert.is_true(not next(ctx.env))
    end)

    it("compute_edit_launch_context returns existing config data", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    launch = {
                        debug = {
                            command = "node",
                            args = { "app.js", "--verbose" },
                            working_dir = "${workspace_root}/App",
                            env = { NODE_ENV = "dev" },
                        },
                    },
                },
            },
        })

        local ctx = wv.compute_edit_launch_context(h.find_project_in(ws:get_projects(), "App"), "debug")
        assert.equals("debug", ctx.name)
        assert.equals("node", ctx.command)
        assert.equals(2, #ctx.args)
        assert.equals("app.js", ctx.args[1])
        assert.equals("${workspace_root}/App", ctx.working_dir)
        assert.equals("dev", ctx.env.NODE_ENV)
    end)

    it("omits empty optional fields when saving", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        wv.execute_save_launch_config(h.find_project_in(ws:get_projects(), "App"), nil, "minimal", {
            command = "echo",
            args = {},
            working_dir = "",
            env = {},
        })

        local saved = h.find_project_in(ws:get_projects(), "App").launch["minimal"]
        assert.equals("echo", saved.command)
        assert.is_nil(saved.args)
        assert.is_nil(saved.working_dir)
        assert.is_nil(saved.env)
    end)

    it("returns error for removed project", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local app = h.find_project_in(ws:get_projects(), "App")

        -- Simulate project removal: remove from config
        ws:remove_project(app)

        local ok, err = app:save_launch_config("test", { command = "echo" })
        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("get_launch_configs returns empty for project without launches", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local configs = wv.get_launch_configs(h.find_project_in(ws:get_projects(), "App"))
        assert.equals(0, #configs)
    end)

    it("get_launch_configs returns sorted entries", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    launch = {
                        release = { command = "app" },
                        debug = { command = "app" },
                    },
                },
            },
        })

        local configs = wv.get_launch_configs(h.find_project_in(ws:get_projects(), "App"))
        assert.equals(2, #configs)
        assert.equals("debug", configs[1].name)
        assert.equals("release", configs[2].name)
    end)
end)

-- =========================================================================
-- Project configuration lifecycle
-- =========================================================================

describe("project configuration lifecycle", function()
    it("creates custom config with inheritance and options", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        -- Create a custom configuration inheriting from Debug
        local ok, err = wv.execute_save_configuration(h.find_project_in(ws:get_projects(), "App"), nil, "Debug-ASAN", {
            inherits = "Debug",
            options = { SANITIZE_ADDRESS = "ON" },
        })
        assert.is_true(ok)
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app.type_config)
        local cfg = app:get_configuration("Debug-ASAN")
        assert.is_not_nil(cfg)
        assert.is_true(cfg.is_user)
        assert.same({ "Debug" }, cfg.inherits_names)
    end)

    it("edits existing configuration options", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            Debug = { options = { ENABLE_TESTS = "ON" } },
                        },
                    },
                },
            },
        })

        local ok = wv.execute_save_configuration(h.find_project_in(ws:get_projects(), "App"), "Debug", "Debug", {
            options = { ENABLE_TESTS = "OFF", VERBOSE = "ON" },
        })
        assert.is_true(ok)
        local app = h.find_project_in(ws:get_projects(), "App")
        local cfg = app:get_configuration("Debug")
        assert.is_not_nil(cfg)
        assert.equals("OFF", cfg.options.ENABLE_TESTS)
        assert.equals("ON", cfg.options.VERBOSE)
    end)

    it("renames custom configuration", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-ASAN"] = { inherits = "Debug", options = { ASAN = "ON" } },
                        },
                    },
                },
            },
        })

        local ok = wv.execute_save_configuration(h.find_project_in(ws:get_projects(), "App"), "Debug-ASAN", "Debug-Sanitized", {
            inherits = "Debug",
            options = { ASAN = "ON" },
        })
        assert.is_true(ok)
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_nil(app:get_configuration("Debug-ASAN"))
        local renamed = app:get_configuration("Debug-Sanitized")
        assert.is_not_nil(renamed)
        assert.is_true(renamed.is_user)
    end)

    it("deletes custom configuration", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-ASAN"] = { inherits = "Debug" },
                        },
                    },
                },
            },
        })

        local ok = wv.execute_delete_configuration(h.find_project_in(ws:get_projects(), "App"), "Debug-ASAN")
        assert.is_true(ok)
        -- Configuration domain object removed
        local app = h.find_project_in(ws:get_projects(), "App")
        local deleted = app:get_configuration("Debug-ASAN")
        assert.is_nil(deleted)
    end)

    it("saves project-wide options", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ok = wv.execute_save_project_options(h.find_project_in(ws:get_projects(), "App"), {
            CMAKE_EXPORT_COMPILE_COMMANDS = "ON",
            MY_FLAG = "hello",
        })
        assert.is_true(ok)
        assert.equals("ON", h.find_project_in(ws:get_projects(), "App").type_config.options.CMAKE_EXPORT_COMPILE_COMMANDS)
        assert.equals("hello", h.find_project_in(ws:get_projects(), "App").type_config.options.MY_FLAG)
    end)

    it("clears project-wide options when empty", function()
        local ws = make_ws({
            projects = {
                App = { cmake = { options = { FOO = "bar" } } },
            },
        })

        local ok = wv.execute_save_project_options(h.find_project_in(ws:get_projects(), "App"), {})
        assert.is_true(ok)
        assert.is_nil(h.find_project_in(ws:get_projects(), "App").type_config.options)
    end)

    it("compute_edit_configuration_context returns defaults for new config", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ctx = wv.compute_edit_configuration_context(h.find_project_in(ws:get_projects(), "App"), nil)
        assert.is_not_nil(ctx)
        assert.equals("", ctx.name)
        assert.equals("", ctx.variant)
        assert.is_true(ctx.has_options)
        assert.is_true(#ctx.available_configs > 0) -- defaults exist
    end)

    it("compute_edit_configuration_context returns data for existing config", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["Debug-ASAN"] = {
                                inherits = "Debug",
                                options = { ASAN = "ON" },
                            },
                        },
                    },
                },
            },
        })

        local ctx = wv.compute_edit_configuration_context(h.find_project_in(ws:get_projects(), "App"), "Debug-ASAN")
        assert.is_not_nil(ctx)
        assert.equals("Debug-ASAN", ctx.name)
        assert.equals("Debug", ctx.inherits[1] or ctx.inherits)
        assert.equals("ON", ctx.options.ASAN)
        assert.is_true(ctx.has_options)
    end)

    it("compute_edit_configuration_context marks defaults correctly", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ctx = wv.compute_edit_configuration_context(h.find_project_in(ws:get_projects(), "App"), "Debug")
        assert.is_not_nil(ctx)
        assert.equals("Debug", ctx.name)
        assert.equals("Debug", ctx.variant)
        assert.is_true(ctx.is_default)
    end)
end)

-- =========================================================================
-- cmake options resolution
-- =========================================================================

describe("cmake options resolution", function()
    local cmake = require("loomworks.modules.cmake")

    it("resolves project-wide options", function()
        local type_config = { options = { FOO = "bar", BAZ = "qux" } }
        local configs = { Debug = { variant = "Debug" } }
        local opts = cmake.resolve_options(type_config, configs, "Debug")
        assert.equals("bar", opts.FOO)
        assert.equals("qux", opts.BAZ)
    end)

    it("config options override project options", function()
        local type_config = {
            options = { FOO = "project" },
            configurations = {
                Debug = { options = { FOO = "config" } },
            },
        }
        local configs = {
            Debug = { variant = "Debug", options = { FOO = "config" } },
        }
        local opts = cmake.resolve_options(type_config, configs, "Debug")
        assert.equals("config", opts.FOO)
    end)

    it("walks inheritance chain", function()
        local configs = {
            Debug = { variant = "Debug", options = { BASE = "from-debug" } },
            ["Debug-ASAN"] = {
                variant = "Debug",
                inherits = "Debug",
                options = { ASAN = "ON" },
            },
        }
        local type_config = {}
        local opts = cmake.resolve_options(type_config, configs, "Debug-ASAN")
        assert.equals("from-debug", opts.BASE)
        assert.equals("ON", opts.ASAN)
    end)

    it("child options override parent options", function()
        local configs = {
            Debug = { variant = "Debug", options = { SHARED = "parent" } },
            ["Debug-ASAN"] = {
                inherits = "Debug",
                options = { SHARED = "child" },
            },
        }
        local opts = cmake.resolve_options({}, configs, "Debug-ASAN")
        assert.equals("child", opts.SHARED)
    end)

    it("handles circular inheritance gracefully", function()
        local configs = {
            A = { inherits = "B", options = { X = "1" } },
            B = { inherits = "A", options = { Y = "2" } },
        }
        -- Should not infinite loop
        local opts = cmake.resolve_options({}, configs, "A")
        assert.equals("1", opts.X)
    end)

    it("multi-inheritance merges left-to-right", function()
        local configs = {
            Debug = { variant = "Debug", options = { BUILD_TYPE = "Debug" } },
            asan = { options = { SANITIZE_ADDRESS = "ON", SANITIZE_UNDEFINED = "ON" } },
            ["Debug-ASAN"] = {
                inherits = { "Debug", "asan" },
                options = { EXTRA = "yes" },
            },
        }
        local opts = cmake.resolve_options({}, configs, "Debug-ASAN")
        -- Debug options
        assert.equals("Debug", opts.BUILD_TYPE)
        -- asan options
        assert.equals("ON", opts.SANITIZE_ADDRESS)
        assert.equals("ON", opts.SANITIZE_UNDEFINED)
        -- Own options
        assert.equals("yes", opts.EXTRA)
    end)

    it("multi-inheritance: later base overrides earlier", function()
        local configs = {
            base1 = { options = { SHARED = "from-base1", ONLY1 = "yes" } },
            base2 = { options = { SHARED = "from-base2", ONLY2 = "yes" } },
            child = {
                inherits = { "base1", "base2" },
                options = {},
            },
        }
        local opts = cmake.resolve_options({}, configs, "child")
        -- base2 overrides base1 for shared key
        assert.equals("from-base2", opts.SHARED)
        assert.equals("yes", opts.ONLY1)
        assert.equals("yes", opts.ONLY2)
    end)

    it("multi-inheritance: child overrides all bases", function()
        local configs = {
            Debug = { variant = "Debug", options = { OPT = "debug" } },
            asan = { options = { OPT = "asan" } },
            child = {
                inherits = { "Debug", "asan" },
                options = { OPT = "child" },
            },
        }
        local opts = cmake.resolve_options({}, configs, "child")
        assert.equals("child", opts.OPT)
    end)

    it("resolve_configurations: multi-inherit gets variant from first base with variant", function()
        local cmake_mod = require("loomworks.modules.cmake")
        local defaults = { Debug = { variant = "Debug" }, Release = { variant = "Release" } }
        local config = {
            configurations = {
                asan = { options = { ASAN = "ON" } },  -- mixin, no variant
                ["Debug-ASAN"] = { inherits = { "Debug", "asan" } },
            },
        }
        local resolved = cmake_mod.resolve_configurations(defaults, config)

        -- Debug-ASAN gets variant from Debug (first base with variant)
        assert.equals("Debug", resolved["Debug-ASAN"].variant)
        -- asan has no variant (abstract mixin)
        assert.is_nil(resolved["asan"].variant)
        -- Debug is still a default
        assert.equals("Debug", resolved["Debug"].variant)
    end)
end)

-- =========================================================================
-- Opaque key test: arbitrary keys with no semantic structure
-- =========================================================================

describe("opaque keys", function()
    -- All keys are arbitrary strings with no pattern.
    -- Proves the system doesn't depend on key format for runtime navigation.

    local function make_opaque_ws()
        return make_ws({
            projects = {
                ["proj-alpha"] = { cmake = {} },
                ["proj-beta"] = { ets = {} },
            },
            configuration_sets = {
                ["set-x"] = { ["proj-alpha"] = "Debug", ["proj-beta"] = "debug" },
            },
        }, {
            active_profile = "profile-z",
        }, {
            configurations = {
                -- Dict keys follow cache format (project_key/config_key),
                -- but config_key itself is arbitrary (not "variant:tool")
                ["proj-alpha/cfg-42"] = {
                    project_key = "proj-alpha", config_key = "cfg-42",
                    type = "cmake", variant = "Debug", tool_key = "tool-7",
                    state = "built",
                    build_dir = "/root/.nvim/build/arbitrary-dir",
                    tool_data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" },
                },
                ["proj-beta/cfg-99"] = {
                    project_key = "proj-beta", config_key = "cfg-99",
                    type = "ets", variant = "debug",
                    state = "configured",
                    build_dir = "/root/.nvim/build/another-dir",
                },
            },
            profiles = {
                -- Arbitrary profile key
                ["profile-z"] = {
                    configuration_set = "set-x",
                    tools = {
                        cmake = { key = "tool-7", data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" }, label = "Tool Seven" },
                    },
                    configurations = { "proj-alpha/cfg-42", "proj-beta/cfg-99" },
                },
            },
        })
    end

    it("loads workspace with arbitrary keys", function()
        local ws = make_opaque_ws()
        assert.is_not_nil(ws)

        -- Projects resolved
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "proj-alpha"))
        assert.equals("cmake", h.find_project_in(ws:get_projects(), "proj-alpha").type)
        assert.is_not_nil(h.find_project_in(ws:get_projects(), "proj-beta"))
        assert.equals("ets", h.find_project_in(ws:get_projects(), "proj-beta").type)
    end)

    it("resolves active profile and its projects", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()
        assert.is_not_nil(profile)
        assert.equals("profile-z", profile.key)

        local pps = profile:projects()
        assert.equals(2, #pps)

        -- ProfileProjects have correct variants
        local variants = {}
        for _, pp in ipairs(pps) do
            variants[pp._project.key] = pp:variant_name()
        end
        assert.equals("Debug", variants["proj-alpha"])
        assert.equals("debug", variants["proj-beta"])
    end)

    it("ProfileProject references resolve correctly", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()

        local pp_alpha = profile:project("proj-alpha")
        assert.is_not_nil(pp_alpha)
        assert.is_not_nil(pp_alpha._config_unit)
        assert.is_not_nil(pp_alpha._project)
        assert.equals("proj-alpha", pp_alpha._project.key)

        -- ConfigUnit has first-class fields with arbitrary key
        local unit = pp_alpha._config_unit
        assert.is_not_nil(unit)
        assert.equals("built", unit.state_value)
        assert.equals("/root/.nvim/build/arbitrary-dir", unit.build_dir_value)
    end)

    it("ConfigUnit state resolves through arbitrary cache keys", function()
        local ws = make_opaque_ws()
        local profile = ws:get_active_profile()

        local pp_alpha = profile:project("proj-alpha")
        assert.equals("built", pp_alpha:status())

        local pp_beta = profile:project("proj-beta")
        assert.equals("configured", pp_beta:status())
    end)

    it("Project:config_units_for_configuration finds units with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")
        local cfg = proj:get_configuration("Debug")
        assert.is_not_nil(cfg)
        local units = proj:config_units_for_configuration(cfg)
        assert.equals(1, #units)
        assert.equals("cfg-42", units[1]:config_key())
    end)

    it("build_dir_refs track arbitrary cache entries", function()
        local ws = make_opaque_ws()
        local refs = ws:get_build_dir_refs("/root/.nvim/build/arbitrary-dir")
        assert.equals(1, #refs)
        assert.equals("cfg-42", refs[1]:config_key())
    end)

    it("config set mapping updates work with arbitrary project keys", function()
        local ws = make_opaque_ws()
        local cs = h.find_config_set_in(ws:get_config_sets(),"set-x")
        assert.is_not_nil(cs)

        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")
        local release_cfg = proj:get_configuration("Release")
        assert.is_not_nil(release_cfg)
        cs:update_mapping(proj, release_cfg)

        -- Verify mapping changed
        assert.equals("Release", cs.mappings[proj].name)
    end)

    it("save_configuration works on project with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")

        local ok = proj:save_configuration("custom-cfg", {
            options = { MY_FLAG = "ON" },
        })
        assert.is_true(ok)
        local cfg = proj:get_configuration("custom-cfg")
        assert.is_not_nil(cfg)
        assert.is_true(cfg.is_user)
    end)

    it("rename_configuration propagates with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = h.find_project_in(ws:get_projects(), "proj-alpha")

        -- Add a user-defined config to rename
        proj:save_configuration("temp-name", { options = { X = "1" } })

        local ok = proj:rename_configuration("temp-name", "new-name", {
            options = { X = "1" },
        })
        assert.is_true(ok)
        assert.is_nil(proj:get_configuration("temp-name"))
        local new_cfg = proj:get_configuration("new-name")
        assert.is_not_nil(new_cfg)
        assert.is_true(new_cfg.is_user)
    end)

    it("delete preserves arbitrary build dirs in cache", function()
        local ws = make_opaque_ws()
        local deleted_dirs = {}
        ws._core._deps.io.rm_rf_async = function(dir, cb)
            deleted_dirs[#deleted_dirs + 1] = dir
            cb(true, nil)
        end

        -- Delete cfg-42's config via profile deletion
        local profile = ws:get_active_profile()
        assert.is_not_nil(profile)

        local done = false
        profile:delete(function() done = true end)
        assert.is_true(done)

        -- Build dir should have been cleaned
        assert.is_true(#deleted_dirs > 0)
    end)

    it("serialization round-trips with arbitrary keys", function()
        local ws = make_opaque_ws()
        local raw = ws:_serialize_config()

        -- Projects preserved
        assert.is_not_nil(raw.projects["proj-alpha"])
        assert.is_not_nil(raw.projects["proj-beta"])

        -- Config sets preserved
        assert.is_not_nil(raw.configuration_sets["set-x"])
        assert.equals("Debug", raw.configuration_sets["set-x"]["proj-alpha"])
    end)
end)
