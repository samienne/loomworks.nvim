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
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return vim.deep_equal(a, b)
        end,
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

--- Common detected tool entries for tests that need tool-qualified profiles.
--- Format matches what merge.get_all_profiles expects in _tools_by_type.
local function make_detected_tools(entries)
    local result = {}
    for _, e in ipairs(entries) do
        local mod_type = e.mod_type or "cmake"
        result[mod_type] = result[mod_type] or {}
        result[mod_type][#result[mod_type] + 1] = {
            tool_key = e.tool_key,
            tool_data = e.tool_data or { id = e.tool_key },
            tool_label = e.tool_label or e.tool_key,
        }
    end
    return result
end

--- Create a real Workspace instance with mock deps for testing.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @param opts? { detected_tools?: table<string, table[]> }
--- @return loomworks.Workspace, table events_log
local function make_ws(config_overrides, user_overrides, cache_overrides, opts)
    opts = opts or {}
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
    if opts.detected_tools then
        ws._tools_by_type = opts.detected_tools
    end
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
            {
                active_profile = "Debug",
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
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
        assert.is_not_nil(h.find_profile(ws._profiles, "Release"),
            "Serialized cache should have profile under new key 'Release'")
        assert.is_nil(h.find_profile(ws._profiles, "Debug"),
            "Serialized cache should not have profile under old key 'Debug'")
        local release_profile = h.find_profile(ws._profiles, "Release")
        assert.is_not_nil(release_profile)
        assert.equals("Release", release_profile._configuration_set_name)
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
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            {
                active_profile = "Debug",
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals("Debug", ws._active_profile_key)
    end)

    it("materialized profile has projects and config units from config set", function()
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
            {
                active_profile = "Debug",
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
                configurations = {
                    ["App/Debug"] = { project_key = "App", config_key = "Debug", variant = "Debug", type = "cmake", state = "configured" },
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", variant = "debug", type = "ets", state = "configured" },
                },
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug")
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
            {
                active_profile = "Debug:ninja-gcc",
                pinned_profiles = {
                    ["Debug:ninja-gcc"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc", data = { generator = "Ninja" } } },
                    },
                },
            },
            {
                configurations = {
                    ["App/Debug:ninja-gcc"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc", variant = "Debug", type = "cmake",
                        tool_key = "ninja-gcc", tool_data = { generator = "Ninja" },
                        state = "configured",
                    },
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", variant = "debug", type = "ets", state = "configured" },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc", tool_data = { generator = "Ninja" } },
                }),
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug:ninja-gcc")
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
            {
                pinned_profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" } } },
                    },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                    },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" } },
                }),
            }
        )

        local profile = h.find_profile(ws:get_profiles(), "Debug:ninja-gcc-12")
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
    pending("add project with mappings then remove with cleanup", function()
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

    pending("adding keyed-tool project upgrades profiles and creates skeletons", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                },
            },
            {
                active_profile = "Debug",
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
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
        assert.is_nil(h.find_profile(ws._profiles, "Debug"))
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
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
            {
                active_profile = "Debug:ninja-gcc-12",
                pinned_profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } } },
                    },
                },
            },
            {
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
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } },
                }),
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
        assert.is_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug"))
        assert.is_nil(h.find_profile(ws._profiles, "Debug").tools)
        assert.equals("Debug", ws._active_profile_key)
    end)

    it("pinned ad-hoc profiles are not affected by upgrade", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = { Debug = { Frontend = "debug", App = "Debug" } },
            },
            {
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                    ["App/Debug"] = { mappings = { App = "Debug" } },
                },
            },
            {
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
        assert.is_nil(h.find_profile(ws._profiles, "Debug"))
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))

        -- Pinned profile unchanged
        assert.is_not_nil(h.find_profile(ws._profiles, "App/Debug"))
        assert.is_nil(h.find_profile(ws._profiles, "App/Debug").tools)
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
            {
                pinned_profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } } },
                    },
                },
            },
            {
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                    ["Lib/Debug:ninja-gcc-12"] = { project_key = "Lib", config_key = "Debug:ninja-gcc-12", variant = "Debug", type = "cmake" },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" } },
                }),
            }
        )

        ws:downgrade_profiles_from_tool("cmake")

        -- Profile unchanged — Lib still uses cmake
        local cache = ws:_serialize_cache()
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"))
        assert.is_nil(h.find_profile(ws._profiles, "Debug"))
    end)
end)

-- =========================================================================
-- Orphan lifecycle: delete config set → orphans appear → clean up
-- =========================================================================

describe("orphan lifecycle", function()
    pending("deleting config set orphans configs, cleanup removes them", function()
        -- Scenario: two config sets reference the same project config.
        -- One profile references via "Debug" set, one via "Staging".
        -- A third cache entry is unreferenced (orphan from branch switch).
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            {
                active_profile = "Debug",
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/debug",
                    },
                    -- Orphan: cache entry from a branch switch, no profile references it
                    ["Frontend/release"] = {
                        project_key = "Frontend", config_key = "release",
                        type = "ets", variant = "release", state = "built",
                        build_dir = "/root/.nvim/build/Frontend/release",
                    },
                },
            }
        )

        -- "release" config is orphaned (no profile references it)
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("Frontend", orphans[1].project_key)
        assert.equals("release", orphans[1].config_key)

        -- Compute cleanup context
        local ctx = wv.compute_orphan_cleanup_context(ws)
        assert.equals(1, #ctx.orphaned_configs)

        -- Execute cleanup
        local done = false
        wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, function()
            done = true
        end)
        assert.is_true(done)

        -- Orphan cleaned, referenced config still exists
        assert.equals(0, #ws:get_orphaned_configs())
        local cache = ws:_serialize_cache()
        local found_debug = false
        local found_release = false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "Frontend" and entry.variant == "debug" then found_debug = true end
            if entry.project_key == "Frontend" and entry.variant == "release" then found_release = true end
        end
        assert.is_true(found_debug, "referenced config should survive cleanup")
        assert.is_false(found_release, "orphan should be cleaned from cache")
    end)

    pending("editing config set mappings can create orphans", function()
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
            {
                pinned_profiles = {
                    Debug = { configuration_set = "Debug" },
                },
            },
            {
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

    pending("collect_clean_items_for_unit returns single item", function()
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
            {
                pinned_profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12" } } },
                    },
                },
            },
            {
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App", config_key = "Debug:ninja-gcc-12",
                        type = "cmake", variant = "Debug",
                        state = "configured",
                    },
                    ["Frontend/debug"] = {
                        project_key = "Frontend", config_key = "debug",
                        type = "ets", variant = "debug",
                        state = "configured",
                    },
                },
            },
            {
                detected_tools = make_detected_tools({
                    { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" } },
                }),
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
        assert.is_nil(h.find_profile(ws._profiles, "debug:ninja-gcc-12"),
            "old profile key should be gone")
        assert.is_not_nil(h.find_profile(ws._profiles, "Debug:ninja-gcc-12"),
            "profile key should use new set name")
        local renamed_profile = h.find_profile(ws._profiles, "Debug:ninja-gcc-12")
        assert.is_not_nil(renamed_profile)
        assert.equals("Debug", renamed_profile._configuration_set_name)
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

    pending("old build_dir becomes orphaned after rename", function()
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
        }, {
            pinned_profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" } } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc" } },
            }),
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {})
        assert.is_true(ok)

        -- Old cache entry stays as-is (orphaned — old build_dir with old variant)
        local cache = ws:_serialize_cache()
        local old_entry = nil
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "Debug-asan" then old_entry = entry end
        end
        assert.is_not_nil(old_entry)

        -- Configuration object renamed; old variant reappears as source-missing from cache
        local old_cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(old_cfg)
        assert.is_true(old_cfg._source_missing)
        assert.is_not_nil(project:get_configuration("DebugASAN"))

        -- Profile still exists as runtime object
        local profile = h.find_profile(ws._profiles, "debug:ninja-gcc")
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

    pending("pinned single-config profile updates name and variant on rename", function()
        local ws = make_ws({
            projects = {
                App = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
        }, {
            pinned_profiles = {
                ["App/Debug:ninja-gcc"] = {
                    mappings = { App = "Debug" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" } } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug"] = {
                    project_key = "App", type = "cmake", variant = "Debug",
                    tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug",
                },
            },
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc" } },
            }),
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local debug_cfg = project:get_configuration("Debug")
        assert.is_not_nil(debug_cfg)
        debug_cfg.is_user = true

        -- Verify pinned profile exists with old name
        local old_profile = h.find_profile(ws:get_profiles(), "App/Debug:ninja-gcc")
        assert.is_not_nil(old_profile, "Pinned profile should exist before rename")
        assert.equals("Debug", old_profile.mappings["App"])
        assert.equals(1, #old_profile:projects())
        assert.equals("built", old_profile:projects()[1]._config_unit.state_value)

        -- Rename "Debug" → "Development"
        local ok, err = project:rename_configuration("Debug", "Development", { variant = "Development" })
        assert.is_true(ok, "rename failed: " .. tostring(err))

        -- Pinned profile should update: new derived key, new variant mapping
        -- Old key "App/Debug:ninja-gcc" should be gone
        assert.is_nil(h.find_profile(ws:get_profiles(), "App/Debug:ninja-gcc"),
            "Old profile key should not exist after rename")

        -- New derived key based on new variant
        local new_profile = h.find_profile(ws:get_profiles(), "App/Development:ninja-gcc")
        assert.is_not_nil(new_profile, "Profile should have new derived key")
        assert.equals("Development", new_profile.mappings["App"])

        -- New profile should have unconfigured ConfigUnit (new build_dir)
        local pps = new_profile:projects()
        assert.equals(1, #pps)
        assert.is_not_nil(pps[1]._config_unit, "PP should have ConfigUnit")
        assert.is_nil(pps[1]._config_unit.state_value, "New ConfigUnit should be unconfigured")

        -- Old build_dir should be orphaned
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans, "Old build_dir should be orphaned")
        assert.equals("built", orphans[1].unit.state_value)

        -- Serialized user.json should have the updated pinned profile
        local user_data = ws:_serialize_user()
        assert.is_nil(user_data.pinned_profiles["App/Debug:ninja-gcc"],
            "Old key should not be in serialized user data")
        assert.is_not_nil(user_data.pinned_profiles["App/Development:ninja-gcc"],
            "New key should be in serialized user data")
    end)

    pending("pinned profile shows unconfigured after rename, old build_dir orphaned", function()
        local ws = make_ws({
            projects = {
                App = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = {
                debug = { App = "Debug" },
            },
        }, {
            active_profile = "debug",
            pinned_profiles = {
                ["debug"] = { configuration_set = "debug" },
            },
        }, {
            build_dirs = {
                ["build/App/Debug"] = {
                    project_key = "App", type = "cmake", variant = "Debug",
                    state = "built", build_dir = "/root/.nvim/build/App/Debug",
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local profile = h.find_profile(ws:get_profiles(), "debug")
        assert.is_not_nil(profile)

        -- Profile should have App with "built" state
        local pps = profile:projects()
        assert.equals(1, #pps)
        assert.is_not_nil(pps[1]._config_unit)
        assert.equals("built", pps[1]._config_unit.state_value)

        -- Mark Debug as user-defined (in real usage, module.info() merges user configs)
        local debug_cfg = project:get_configuration("Debug")
        assert.is_not_nil(debug_cfg, "Debug config should exist")
        debug_cfg.is_user = true

        -- Rename "Debug" → "Development"
        local ok, err = project:rename_configuration("Debug", "Development", { variant = "Development" })
        assert.is_true(ok, "rename failed: " .. tostring(err))

        -- Profile should now have App with unconfigured state (new build_dir)
        profile = h.find_profile(ws:get_profiles(), "debug")
        assert.is_not_nil(profile, "Profile should still exist after rename")
        pps = profile:projects()
        assert.equals(1, #pps)
        assert.is_not_nil(pps[1]._config_unit, "PP should have a ConfigUnit for new build_dir")
        assert.is_nil(pps[1]._config_unit.state_value, "New ConfigUnit should be unconfigured")
        assert.equals("Development", pps[1]:variant_name())

        -- Old build_dir should be orphaned
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans, "Old build_dir should be orphaned")
        assert.equals("built", orphans[1].unit.state_value)
    end)

    pending("old cache entries for multiple tools become orphaned after rename", function()
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

        -- Old cache entries stay with old variant (orphaned)
        local cache = ws:_serialize_cache()
        local found_old_gcc, found_old_clang = false, false
        for _, entry in pairs(cache.build_dirs) do
            if entry.project_key == "App" and entry.variant == "Debug-asan" then
                if entry.tool_key == "ninja-gcc" then found_old_gcc = true end
                if entry.tool_key == "ninja-clang" then found_old_clang = true end
            end
        end
        assert.is_true(found_old_gcc, "gcc old entry should still exist")
        assert.is_true(found_old_clang, "clang old entry should still exist")

        -- Configuration object renamed; old variant reappears as source-missing from cache
        local old_cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(old_cfg)
        assert.is_true(old_cfg._source_missing)
        assert.is_not_nil(project:get_configuration("DebugASAN"))
    end)

    pending("pinned profile key updates to new variant on rename", function()
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
            pinned_profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("Debug-asan")
        cfg.is_user = true
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Pinned profile key updated to reflect new variant
        assert.is_nil(h.find_profile(ws._profiles, "App/Debug-asan:ninja-gcc"))
        local profile = h.find_profile(ws._profiles, "App/DebugASAN:ninja-gcc")
        assert.is_not_nil(profile)
        assert.equals("DebugASAN", profile.mappings["App"])

        -- Configuration object renamed; old variant reappears as source-missing from cache
        local old_cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(old_cfg)
        assert.is_true(old_cfg._source_missing)
        assert.is_not_nil(project:get_configuration("DebugASAN"))
    end)

    it("active_profile unchanged after rename", function()
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
            pinned_profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        })

        assert.equals("App/Debug-asan:ninja-gcc", ws._active_profile_key)

        local project = h.find_project_in(ws:get_projects(), "App")
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Active profile key stays the same (no rekeying)
        assert.equals("App/Debug-asan:ninja-gcc", ws._active_profile_key)
    end)

    pending("rename updates Configuration domain objects; old variant lingers from cache", function()
        -- Simulates: user configures Debug-asan, then renames it to DebugASAN.
        -- The Configuration object is renamed. Old cache entries still have
        -- the old variant name, so a source-missing Configuration appears.
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
        }, {
            pinned_profiles = {
                ["asan:ninja-gcc"] = {
                    configuration_set = "asan",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" } } },
                },
            },
        }, {
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", display = "GCC" } },
            }),
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
        assert.is_true(project:get_configuration("DebugASAN").is_user)

        -- Old variant still appears as source-missing (from cache)
        local old_cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(old_cfg)
        assert.is_true(old_cfg._source_missing)

        -- Config set mapping updated to new name (via Configuration reference)
        local cs = h.find_config_set_in(ws:get_config_sets(), "asan")
        assert.equals("DebugASAN", h.cs_mapping(cs, "App"))
    end)

    it("rename updates pinned profile key and variant; Configuration mutated in place", function()
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
            pinned_profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" }, label = "GCC" } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc", display = "GCC" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        })

        -- Before rename: PP works
        local profile = h.find_profile(ws:get_profiles(), "App/Debug-asan:ninja-gcc")
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.equals("Debug-asan", pp:variant_name())

        -- Rename
        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("Debug-asan")
        cfg.is_user = true
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Pinned profile key updated to new variant
        assert.is_nil(h.find_profile(ws:get_profiles(), "App/Debug-asan:ninja-gcc"))
        profile = h.find_profile(ws:get_profiles(), "App/DebugASAN:ninja-gcc")
        assert.is_not_nil(profile)
        assert.equals("DebugASAN", profile.mappings["App"])

        -- Configuration object renamed
        assert.is_not_nil(project:get_configuration("DebugASAN"))
    end)

    pending("rename while building preserves running state on old ConfigUnit", function()
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
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc" } },
            }),
        })

        -- Simulate a running build on the config unit
        local old_unit = h.find_config_unit(ws._config_units, "App", "Debug-asan")
        assert.is_not_nil(old_unit)
        old_unit:register_task(42, "build")
        assert.is_true(old_unit:is_running())

        -- Rename while building — ConfigUnit is not migrated
        local ok = h.find_project_in(ws:get_projects(), "App"):rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Old ConfigUnit still exists with old variant and is still running
        assert.is_true(old_unit:is_running())
        assert.equals("build", old_unit:running_action())
        assert.equals("Debug-asan", old_unit._variant)

        -- Configuration object renamed
        local project = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(project:get_configuration("DebugASAN"))
    end)

    pending("cache-only variant creates Configuration for PP resolution", function()
        -- Simulates: variant exists only in cache (source removed, e.g. branch switch).
        -- PP should still resolve via cache-enriched Configuration.
        local ws = make_ws({
            projects = {
                App = { cmake = {} },  -- no user-defined configs
            },
            configuration_sets = {
                custom = { App = "CustomBuild" },
            },
        }, {
            pinned_profiles = {
                ["custom:ninja-gcc"] = {
                    configuration_set = "custom",
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" } } },
                },
            },
        }, {
            configurations = {
                ["App/CustomBuild:ninja-gcc"] = {
                    project_key = "App", config_key = "CustomBuild:ninja-gcc",
                    type = "cmake", variant = "CustomBuild", tool_key = "ninja-gcc",
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/CustomBuild",
                },
            },
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", display = "GCC" } },
            }),
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

    pending("save_configuration creates Configuration domain object for PP", function()
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

    it("rename preserves all domain object identities", function()
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
        }, {
            pinned_profiles = {
                ["App/Debug-asan"] = {
                    mappings = { App = "Debug-asan" },
                },
            },
        }, {
            build_dirs = {
                ["build/App/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan",
                    type = "cmake", variant = "Debug-asan",
                    state = "built", build_dir = "/root/.nvim/build/App/Debug-asan",
                },
            },
        })

        -- Capture object identities before rename
        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg_before = project:get_configuration("Debug-asan")
        assert.is_not_nil(cfg_before)
        cfg_before.is_user = true

        local cs_before = h.find_config_set_in(ws:get_config_sets(), "debug")
        local profile_before = h.find_profile(ws:get_profiles(), "App/Debug-asan")
        assert.is_not_nil(profile_before, "pinned profile should exist")
        local pp_before = profile_before:projects()[1]
        assert.is_not_nil(pp_before, "PP should exist")
        local unit_before = pp_before._config_unit
        assert.is_not_nil(unit_before, "ConfigUnit should exist")
        assert.equals("built", unit_before.state_value)

        -- Rename
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)

        -- Same Configuration object (table identity)
        local cfg_after = project:get_configuration("DebugASAN")
        assert.equals(cfg_before, cfg_after) -- same table
        assert.is_nil(project:get_configuration("Debug-asan"))

        -- Same ConfigurationSet object
        local cs_after = h.find_config_set_in(ws:get_config_sets(), "debug")
        assert.equals(cs_before, cs_after)
        assert.equals("DebugASAN", h.cs_mapping(cs_after, "App"))

        -- Same Profile object (key re-derived)
        local profile_after = h.find_profile(ws:get_profiles(), "App/DebugASAN")
        assert.is_not_nil(profile_after, "profile should exist with new key")
        assert.equals(profile_before, profile_after) -- same table
        assert.equals("DebugASAN", profile_after.mappings["App"])

        -- Same ProfileProject object
        local pp_after = profile_after:projects()[1]
        assert.equals(pp_before, pp_after)
        assert.equals("DebugASAN", pp_after:variant_name())

        -- Same ConfigUnit object (table identity), updated fields
        local unit_after = pp_after._config_unit
        assert.equals(unit_before, unit_after) -- same table
        assert.equals("DebugASAN", unit_after._variant)
        assert.is_nil(unit_after.state_value) -- new build dir, unconfigured
        assert.equals("build/App/DebugASAN", unit_after.id)

        -- Old BuildDir orphaned, new BuildDir created
        assert.is_not_nil(unit_after._build_dir)
        assert.equals("build/App/DebugASAN", unit_after._build_dir.rel_path)
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("build/App/Debug-asan", orphans[1].build_dir_key)
        assert.equals("built", orphans[1].cached_entry.state)
    end)

    it("rename-back round trip: old build_dir restored from cache, zero orphans", function()
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
        }, {
            pinned_profiles = {
                ["App/Debug-asan"] = {
                    mappings = { App = "Debug-asan" },
                },
            },
        }, {
            build_dirs = {
                ["build/App/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan",
                    type = "cmake", variant = "Debug-asan",
                    state = "built", build_dir = "/root/.nvim/build/App/Debug-asan",
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("Debug-asan")
        cfg.is_user = true
        local unit = h.find_config_unit(ws._config_units, "App", "Debug-asan")
        assert.is_not_nil(unit, "ConfigUnit should exist")
        assert.equals("built", unit.state_value)

        -- Rename forward: Debug-asan → DebugASAN
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)
        assert.is_nil(unit.state_value) -- state reset
        assert.equals("build/App/DebugASAN", unit.id)

        -- One orphan: the old build dir with "built" state
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("build/App/Debug-asan", orphans[1].build_dir_key)
        assert.equals("built", orphans[1].cached_entry.state)

        -- Rename back: DebugASAN → Debug-asan
        ok = project:rename_configuration("DebugASAN", "Debug-asan", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)
        assert.equals("build/App/Debug-asan", unit.id)

        -- State restored from orphaned cache entry
        assert.equals("built", unit.state_value)

        -- Zero orphans after round trip
        orphans = ws:get_orphaned_configs()
        assert.equals(0, #orphans)
    end)

    it("rename-back with tools: no orphan accumulation", function()
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
        }, {
            pinned_profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc" }, label = "GCC" } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc/Debug-asan"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    tool_data = { id = "ninja-gcc" },
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
        }, {
            detected_tools = make_detected_tools({
                { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc" } },
            }),
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(cfg)
        cfg.is_user = true

        local unit = h.find_config_unit(ws._config_units, "App", "Debug-asan")
        assert.is_not_nil(unit, "ConfigUnit should exist")
        assert.equals("built", unit.state_value)
        assert.equals("build/App/ninja-gcc/Debug-asan", unit.id)

        -- Rename forward
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)
        assert.equals("build/App/ninja-gcc/DebugASAN", unit.id)
        assert.equals("ninja-gcc", unit._tool_key)
        assert.is_nil(unit.state_value)

        -- One orphan at the old tool-qualified path
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans)
        assert.equals("build/App/ninja-gcc/Debug-asan", orphans[1].build_dir_key)

        -- Rename back
        ok = project:rename_configuration("DebugASAN", "Debug-asan", {
            inherits = "Debug",
        })
        assert.is_true(ok)
        assert.equals("build/App/ninja-gcc/Debug-asan", unit.id)
        assert.equals("built", unit.state_value) -- restored

        -- Zero orphans
        orphans = ws:get_orphaned_configs()
        assert.equals(0, #orphans)

        -- Multiple cycles: no accumulation
        for _ = 1, 3 do
            ok = project:rename_configuration("Debug-asan", "DebugASAN", {
                inherits = "Debug",
            })
            assert.is_true(ok)
            ok = project:rename_configuration("DebugASAN", "Debug-asan", {
                inherits = "Debug",
            })
            assert.is_true(ok)
        end
        orphans = ws:get_orphaned_configs()
        assert.equals(0, #orphans)
    end)

    it("configure via task result then rename-back: BuildDir adopted, state restored", function()
        -- Fresh workspace, no cache — simulates: user creates profile, configures, renames
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
        }, {
            pinned_profiles = {
                ["App/Debug-asan"] = {
                    mappings = { App = "Debug-asan" },
                },
            },
        })

        local project = h.find_project_in(ws:get_projects(), "App")
        local cfg = project:get_configuration("Debug-asan")
        assert.is_not_nil(cfg)
        cfg.is_user = true

        local unit = h.find_config_unit(ws._config_units, "App", "Debug-asan")
        assert.is_not_nil(unit, "ConfigUnit should exist from profile")

        -- Simulate a successful configure via task result
        ws:record_task_result({
            unit = unit,
            action = "configure",
            success = true,
        })
        assert.equals("configured", unit.state_value)
        assert.is_not_nil(unit._build_dir, "BuildDir should be created by task handler")
        assert.equals("configured", unit._build_dir.state)
        assert.equals(1, #ws._build_dirs)

        -- Rename: Debug-asan → DebugASAN
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)
        assert.is_nil(unit.state_value, "should be unconfigured at new build dir")
        assert.is_not_nil(unit._build_dir, "new BuildDir created")
        assert.equals("build/App/DebugASAN", unit._build_dir.rel_path)

        -- Old BuildDir orphaned
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans, "old build dir should be orphaned")

        -- Rename back: DebugASAN → Debug-asan
        ok = project:rename_configuration("DebugASAN", "Debug-asan", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)

        -- State restored from orphaned BuildDir
        assert.equals("configured", unit.state_value, "state should be restored")
        assert.is_not_nil(unit._build_dir, "BuildDir should be adopted")
        assert.equals("configured", unit._build_dir.state)

        -- Zero orphans
        orphans = ws:get_orphaned_configs()
        assert.equals(0, #orphans, "adopted BuildDir should not be orphaned")

        -- Serialized cache should reflect adoption
        local cache = ws:_serialize_cache()
        local entry = cache.build_dirs["build/App/Debug-asan"]
        assert.is_not_nil(entry, "adopted BuildDir should be in serialized cache")
        assert.equals("configured", entry.state)
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

        -- Remerge to derive profiles from the new config set
        ws:remerge()

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

    it("compute_edit_launch_context includes deploy data", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    launch = {
                        debug = {
                            command = "node",
                            deploy = {
                                ["${build_dir}/native.node"] = {
                                    project = "NativeLib",
                                    target = "native_lib",
                                },
                            },
                        },
                    },
                },
            },
        })

        local ctx = wv.compute_edit_launch_context(
            h.find_project_in(ws:get_projects(), "App"), "debug")
        assert.is_not_nil(ctx.deploy)
        assert.is_not_nil(ctx.deploy["${build_dir}/native.node"])
        assert.equals("NativeLib", ctx.deploy["${build_dir}/native.node"].project)
        assert.equals("native_lib", ctx.deploy["${build_dir}/native.node"].target)
    end)

    it("save_launch_config persists deploy and omits when empty", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local app = h.find_project_in(ws:get_projects(), "App")

        -- Save with deploy
        wv.execute_save_launch_config(app, nil, "debug", {
            command = "node",
            deploy = {
                ["${build_dir}/lib.node"] = {
                    project = "NativeLib",
                    path = "lib/output.node",
                },
            },
        })

        local saved = h.find_project_in(ws:get_projects(), "App").launch["debug"]
        assert.is_not_nil(saved.deploy)
        assert.is_not_nil(saved.deploy["${build_dir}/lib.node"])

        -- Save without deploy (empty)
        wv.execute_save_launch_config(app, "debug", "debug", {
            command = "node",
            deploy = {},
        })

        saved = h.find_project_in(ws:get_projects(), "App").launch["debug"]
        assert.is_nil(saved.deploy)
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
    -- Arbitrary project keys, config set names, tool keys, and variant names.
    -- Proves the system doesn't depend on naming conventions for runtime navigation.
    -- Profile keys are derived from config_set × tools; build_dir keys are
    -- computed from project/tool/variant — both are determined at runtime.

    local function make_opaque_ws()
        -- Derived profile key: "set-x:tool-7" (from set_name + cmake tool key)
        local detected = make_detected_tools({
            { tool_key = "tool-7", tool_data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" }, tool_label = "Tool Seven" },
        })
        return make_ws({
            projects = {
                ["proj-alpha"] = { cmake = {} },
                ["proj-beta"] = { ets = {} },
            },
            configuration_sets = {
                ["set-x"] = { ["proj-alpha"] = "Debug", ["proj-beta"] = "debug" },
            },
        }, {
            active_profile = "set-x:tool-7",
            pinned_profiles = {
                ["set-x:tool-7"] = {
                    configuration_set = "set-x",
                    tools = { cmake = { key = "tool-7", data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" } } },
                },
            },
        }, {
            -- v7 build_dirs: keys match _compute_build_dir output
            build_dirs = {
                ["build/proj-alpha/tool-7/Debug"] = {
                    project_key = "proj-alpha", config_key = "Debug:tool-7",
                    type = "cmake", variant = "Debug", tool_key = "tool-7",
                    state = "built",
                    tool_data = { id = "tool-7", display = "Tool Seven", generator = "Ninja" },
                },
                ["build/proj-beta/debug"] = {
                    project_key = "proj-beta", config_key = "debug",
                    type = "ets", variant = "debug",
                    state = "configured",
                },
            },
        }, {
            detected_tools = detected,
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
        assert.equals("set-x:tool-7", profile.key)

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
        assert.equals("/root/.nvim/build/proj-alpha/tool-7/Debug", unit.build_dir_value)
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
        assert.equals("Debug:tool-7", units[1]:config_key())
    end)

    it("build_dir_refs track arbitrary cache entries", function()
        local ws = make_opaque_ws()
        local refs = ws:get_build_dir_refs("/root/.nvim/build/proj-alpha/tool-7/Debug")
        assert.equals(1, #refs)
        assert.equals("Debug:tool-7", refs[1]:config_key())
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

-- =========================================================================
-- Two-layer merge: user.json + loomworks.json
-- =========================================================================

describe("two-layer merge", function()
    it("shared-only projects have _source = shared", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("shared", app._source)
    end)

    it("user project has _source = user", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },  -- shared
            { projects = { MyLib = { cmake = {} } } }  -- user
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(app)
        assert.is_not_nil(mylib)
        assert.equals("shared", app._source)
        assert.equals("user", mylib._source)
    end)

    it("user project overrides shared project with same key", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },  -- shared
            { projects = { App = { ets = {} } } }  -- user overrides type
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("ets", app.type)
        assert.equals("user", app._source)
    end)

    it("user config_set has _source = user", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
            }
        )
        local shared_cs = h.find_config_set_in(ws:get_config_sets(), "SharedDebug")
        local user_cs = h.find_config_set_in(ws:get_config_sets(), "UserDebug")
        assert.is_not_nil(shared_cs)
        assert.is_not_nil(user_cs)
        assert.equals("shared", shared_cs._source)
        assert.equals("user", user_cs._source)
    end)

    it("user config_set overrides shared config_set with same name", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "Debug" } },
            },
            {
                configuration_sets = { Debug = { App = "Release" } },
            }
        )
        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)
        assert.equals("user", cs._source)
        -- The mapping should reflect the user override
        assert.equals("Release", h.cs_mapping(cs, "App"))
    end)

    it("serialize_config excludes user-sourced projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        local raw = ws:_serialize_config()
        assert.is_not_nil(raw.projects.App)
        assert.is_nil(raw.projects.MyLib)
    end)

    it("serialize_config excludes user-sourced config_sets", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
            }
        )
        local raw = ws:_serialize_config()
        assert.is_not_nil(raw.configuration_sets.SharedDebug)
        assert.is_nil(raw.configuration_sets and raw.configuration_sets.UserDebug)
    end)

    it("serialize_user includes pin-reachable user-sourced projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            {
                projects = { MyLib = { cmake = {} } },
                configuration_sets = { dev = { MyLib = "Debug" } },
                pinned_profiles = { dev = { configuration_set = "dev" } },
            }
        )
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.projects)
        assert.is_not_nil(user_data.projects.MyLib)
        assert.is_nil(user_data.projects and user_data.projects.App)
    end)

    it("serialize_user excludes unreachable user-sourced projects", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        -- No pins → nothing reachable
        local user_data = ws:_serialize_user()
        assert.is_nil(user_data.projects)
    end)

    it("serialize_user includes pin-reachable user-sourced config_sets", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { SharedDebug = { App = "Debug" } },
            },
            {
                configuration_sets = { UserDebug = { App = "Release" } },
                pinned_profiles = { ["UserDebug"] = { configuration_set = "UserDebug" } },
            }
        )
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.configuration_sets)
        assert.is_not_nil(user_data.configuration_sets.UserDebug)
        assert.is_nil(user_data.configuration_sets and user_data.configuration_sets.SharedDebug)
    end)

    it("solo dev: pinned items from user.json serialized, no shared projects", function()
        local ws = make_ws(
            { projects = {} },  -- empty shared
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "Debug" } },
                pinned_profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_not_nil(app)
        assert.equals("user", app._source)

        local cs = h.find_config_set_in(ws:get_config_sets(), "Debug")
        assert.is_not_nil(cs)
        assert.equals("user", cs._source)

        -- Shared config should be empty
        local raw = ws:_serialize_config()
        assert.is_falsy(next(raw.projects))

        -- User config should contain pin-reachable items
        local user_data = ws:_serialize_user()
        assert.is_not_nil(user_data.projects.App)
        assert.is_not_nil(user_data.configuration_sets.Debug)
    end)

    it("remerge after mutation preserves two-layer source", function()
        local ws = make_ws(
            { projects = { App = { cmake = {} } } },
            { projects = { MyLib = { cmake = {} } } }
        )
        -- Remerge without raw config (simulates tool detection callback)
        ws:remerge()

        local app = h.find_project_in(ws:get_projects(), "App")
        local mylib = h.find_project_in(ws:get_projects(), "MyLib")
        assert.is_not_nil(app)
        assert.is_not_nil(mylib)
        assert.equals("shared", app._source)
        assert.equals("user", mylib._source)
    end)
end)

-- =========================================================================
-- Deploy steps
-- =========================================================================

describe("deploy steps", function()
    local deploy = require("loomworks.deploy")

    -- Helper: create a workspace with two cmake projects and a built config
    local function make_deploy_ws(launch_deploy, opts)
        opts = opts or {}
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    launch = {
                        debug = {
                            command = "node",
                            args = { "app.js" },
                            deploy = launch_deploy,
                        },
                    },
                },
                NativeLib = { cmake = {} },
            },
            configuration_sets = {
                Debug = { App = "Debug", NativeLib = "Debug" },
                Release = { App = "Release", NativeLib = "Release" },
            },
        }, {
            active_profile = "Debug",
            pinned_profiles = {
                Debug = { configuration_set = "Debug" },
                Release = { configuration_set = "Release" },
            },
        }, {
            build_dirs = vim.tbl_extend("force", {
                [h.build_dir_key("NativeLib", "Debug")] = {
                    project_key = "NativeLib", config_key = "Debug",
                    type = "cmake", variant = "Debug", state = "built",
                    build_dir = "/root/.nvim/build/NativeLib/Debug",
                },
                [h.build_dir_key("App", "Debug")] = {
                    project_key = "App", config_key = "Debug",
                    type = "cmake", variant = "Debug", state = "built",
                    build_dir = "/root/.nvim/build/App/Debug",
                },
            }, opts.extra_build_dirs or {}),
            deploy_state = opts.deploy_state or {},
        })
        return ws
    end

    describe("validation", function()
        it("accepts valid deploy definition with target", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/native.node"] = {
                    project = "NativeLib",
                    target = "native_lib",
                },
            })
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("accepts valid deploy definition with path", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/lib/"] = {
                    project = "NativeLib",
                    path = "lib/output.node",
                },
            })
            assert.is_true(ok)
        end)

        it("accepts deploy with pinned configuration", function()
            local ok = deploy.validate_deploy_definitions({
                ["${build_dir}/native.node"] = {
                    project = "NativeLib",
                    target = "native_lib",
                    configuration = "Release",
                },
            })
            assert.is_true(ok)
        end)

        it("rejects deploy with .. in destination", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/../secret"] = {
                    project = "NativeLib",
                    target = "native_lib",
                },
            })
            assert.is_false(ok)
            assert.truthy(err:find("%.%."))
        end)

        it("rejects deploy with . segment in destination", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/./file"] = {
                    project = "NativeLib",
                    target = "native_lib",
                },
            })
            assert.is_false(ok)
        end)

        it("rejects deploy missing project", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/file"] = { target = "native_lib" },
            })
            assert.is_false(ok)
            assert.truthy(err:find("project"))
        end)

        it("rejects deploy missing both target and path", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/file"] = { project = "NativeLib" },
            })
            assert.is_false(ok)
            assert.truthy(err:find("target.*path"))
        end)

        it("rejects deploy with both target and path", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["${build_dir}/file"] = {
                    project = "NativeLib",
                    target = "foo",
                    path = "bar",
                },
            })
            assert.is_false(ok)
            assert.truthy(err:find("not both"))
        end)
    end)

    describe("resolution", function()
        it("resolves deploy step using path in profile context", function()
            local ws = make_deploy_ws({
                ["${build_dir}/native.node"] = {
                    project = "NativeLib",
                    path = "lib/native.node",
                },
            })

            local profile = ws._active_profile
            local app = h.find_project_in(ws:get_projects(), "App")

            local resolved, err = deploy.resolve_deploy_step(
                "${build_dir}/native.node",
                { project = "NativeLib", path = "lib/native.node" },
                { workspace = ws, profile = profile, launch_project = app })

            assert.is_not_nil(resolved, err)
            assert.equals("/root/.nvim/build/NativeLib/Debug/lib/native.node",
                resolved.source_path)
            -- Destination is App's build dir
            assert.equals("/root/.nvim/build/App/Debug/native.node",
                resolved.dest_path)
            assert.equals("build/NativeLib/Debug", resolved.source_build_dir_id)
            assert.equals("lib/native.node", resolved.source_rel_path)
        end)

        it("resolves deploy step with pinned configuration", function()
            local ws = make_deploy_ws(nil, {
                extra_build_dirs = {
                    [h.build_dir_key("NativeLib", "Release")] = {
                        project_key = "NativeLib", config_key = "Release",
                        type = "cmake", variant = "Release", state = "built",
                        build_dir = "/root/.nvim/build/NativeLib/Release",
                    },
                },
            })

            -- Active profile is Debug, but deploy pins to Release
            -- We need a Release profile for this to work
            local release_profile
            for _, p in pairs(ws._profiles) do
                if p.key == "Release" then
                    release_profile = p
                    break
                end
            end
            if not release_profile then
                -- Skip if Release profile not available
                return
            end

            local app = h.find_project_in(ws:get_projects(), "App")
            local resolved, err = deploy.resolve_deploy_step(
                "${workspace_root}/shared/native.node",
                { project = "NativeLib", configuration = "Release", path = "lib/native.node" },
                { workspace = ws, profile = release_profile, launch_project = app })

            assert.is_not_nil(resolved, err)
            assert.truthy(resolved.source_path:find("Release"))
        end)

        it("fails when source project not found", function()
            local ws = make_deploy_ws(nil)
            local profile = ws._active_profile
            local app = h.find_project_in(ws:get_projects(), "App")

            local resolved, err = deploy.resolve_deploy_step(
                "${build_dir}/file",
                { project = "NonExistent", path = "lib.so" },
                { workspace = ws, profile = profile, launch_project = app })

            assert.is_nil(resolved)
            assert.truthy(err:find("not found"))
        end)

        it("fails when source project not in profile", function()
            -- Create workspace with a project not in any config set
            local ws = make_ws({
                projects = {
                    App = { cmake = {}, launch = { debug = { command = "node" } } },
                    Orphan = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug" },  -- Orphan not mapped
                },
            }, {
                active_profile = "Debug",
                pinned_profiles = { Debug = { configuration_set = "Debug" } },
            })

            local profile = ws._active_profile
            local app = h.find_project_in(ws:get_projects(), "App")

            local resolved, err = deploy.resolve_deploy_step(
                "${build_dir}/file",
                { project = "Orphan", path = "lib.so" },
                { workspace = ws, profile = profile, launch_project = app })

            assert.is_nil(resolved)
            assert.truthy(err:find("not in profile") or err:find("no config"))
        end)

        it("destination ending with / appends source filename", function()
            local ws = make_deploy_ws(nil)
            local profile = ws._active_profile
            local app = h.find_project_in(ws:get_projects(), "App")

            local resolved, err = deploy.resolve_deploy_step(
                "${build_dir}/lib/",
                { project = "NativeLib", path = "output/native.node" },
                { workspace = ws, profile = profile, launch_project = app })

            assert.is_not_nil(resolved, err)
            -- Should append "native.node" (last segment of source path)
            assert.truthy(resolved.dest_path:find("lib/native%.node$"))
        end)
    end)

    describe("freshness", function()
        it("needs copy when no record exists", function()
            local needs = deploy.check_freshness({
                source_path = "/root/.nvim/build/NativeLib/Debug/lib.node",
                dest_path = "/root/App/Debug/lib.node",
                source_build_dir_id = "build/NativeLib/Debug",
                source_rel_path = "lib.node",
            }, {}, function(p) return p end)
            assert.is_true(needs)
        end)

        it("needs copy when source_build_dir changed (config switch)", function()
            local records = {
                ["/root/App/Debug/lib.node"] = {
                    source_build_dir = "build/NativeLib/Debug",
                    source_rel_path = "lib.node",
                    source_mtime = 1000,
                },
            }
            -- Switching to Release
            local needs = deploy.check_freshness({
                source_path = "/root/.nvim/build/NativeLib/Release/lib.node",
                dest_path = "/root/App/Debug/lib.node",
                source_build_dir_id = "build/NativeLib/Release",
                source_rel_path = "lib.node",
            }, records, function(p) return p end)
            assert.is_true(needs)
        end)

        it("needs copy when source_rel_path changed", function()
            local records = {
                ["/root/App/Debug/lib.node"] = {
                    source_build_dir = "build/NativeLib/Debug",
                    source_rel_path = "old_lib.node",
                    source_mtime = 1000,
                },
            }
            local needs = deploy.check_freshness({
                source_path = "/root/.nvim/build/NativeLib/Debug/lib.node",
                dest_path = "/root/App/Debug/lib.node",
                source_build_dir_id = "build/NativeLib/Debug",
                source_rel_path = "lib.node",
            }, records, function(p) return p end)
            assert.is_true(needs)
        end)
    end)

    describe("cleanup", function()
        it("removes deploy records for deleted build dir", function()
            local records = {
                ["/root/App/Debug/lib.node"] = {
                    source_build_dir = "build/NativeLib/Debug",
                    source_rel_path = "lib.node",
                    source_mtime = 1000,
                },
                ["/root/App/Release/lib.node"] = {
                    source_build_dir = "build/NativeLib/Release",
                    source_rel_path = "lib.node",
                    source_mtime = 2000,
                },
                ["/root/App/other.dll"] = {
                    source_build_dir = "build/NativeLib/Debug",
                    source_rel_path = "other.dll",
                    source_mtime = 1500,
                },
            }

            local removed = deploy.clean_deploy_records(records, "build/NativeLib/Debug")

            -- Should remove Debug-sourced entries, keep Release
            assert.equals(2, #removed)
            assert.is_nil(records["/root/App/Debug/lib.node"])
            assert.is_nil(records["/root/App/other.dll"])
            assert.is_not_nil(records["/root/App/Release/lib.node"])
        end)

        it("deploy records survive serialization round-trip", function()
            local ws = make_deploy_ws(nil, {
                deploy_state = {
                    ["/root/App/Debug/lib.node"] = {
                        source_build_dir = "build/NativeLib/Debug",
                        source_rel_path = "lib.node",
                        source_mtime = 1000,
                    },
                },
            })

            -- Records should be loaded from cache
            assert.is_not_nil(ws._deploy_records["/root/App/Debug/lib.node"])

            -- Serialize and check
            local cache = ws:_serialize_cache()
            assert.is_not_nil(cache.deploy_state)
            assert.is_not_nil(cache.deploy_state["/root/App/Debug/lib.node"])
            assert.equals("build/NativeLib/Debug",
                cache.deploy_state["/root/App/Debug/lib.node"].source_build_dir)
        end)
    end)

    describe("config validation", function()
        it("rejects loomworks.json with invalid deploy definitions", function()
            local config_mod = require("loomworks.config")
            local raw = {
                projects = {
                    App = {
                        cmake = {},
                        launch = {
                            debug = {
                                command = "node",
                                deploy = {
                                    ["${build_dir}/../escape"] = {
                                        project = "NativeLib",
                                        target = "lib",
                                    },
                                },
                            },
                        },
                    },
                },
            }
            local config, err = config_mod.validate(raw, "/root")
            assert.is_nil(config)
            assert.truthy(err:find("%.%."))
        end)

        it("accepts loomworks.json with valid deploy definitions", function()
            local config_mod = require("loomworks.config")
            local raw = {
                projects = {
                    App = {
                        cmake = {},
                        launch = {
                            debug = {
                                command = "node",
                                deploy = {
                                    ["${build_dir}/native.node"] = {
                                        project = "NativeLib",
                                        target = "native_lib",
                                    },
                                },
                            },
                        },
                    },
                },
            }
            local config, err = config_mod.validate(raw, "/root")
            assert.is_not_nil(config, err)
        end)
    end)

    describe("launch target deploy method", function()
        it("deploy() calls on_complete(true) when no deploy config", function()
            local ws = make_deploy_ws(nil)  -- no deploy section
            local profile = ws._active_profile
            local lt = profile:default_target()

            -- LaunchTarget may not exist (no default target set), test deploy directly
            local LaunchTarget = require("loomworks.launch_target")
            local target = LaunchTarget.new(ws, profile, { project = "App", launch = "debug" })

            local result
            target:deploy(function(ok, err)
                result = { ok = ok, err = err }
            end)
            assert.is_not_nil(result)
            assert.is_true(result.ok)
        end)
    end)

    describe("destination parsing", function()
        local de = require("loomworks.ui.deploy_editor")

        it("parses ${workspace_root}/path", function()
            local base, rel = de._parse_destination("${workspace_root}/lib/native.node")
            assert.equals("${workspace_root}", base)
            assert.equals("lib/native.node", rel)
        end)

        it("parses ${build_dir}/path", function()
            local base, rel = de._parse_destination("${build_dir}/native.node")
            assert.equals("${build_dir}", base)
            assert.equals("native.node", rel)
        end)

        it("parses ${project_path}/path", function()
            local base, rel = de._parse_destination("${project_path}/out/")
            assert.equals("${project_path}", base)
            assert.equals("out/", rel)
        end)

        it("parses bare variable with no relative part", function()
            local base, rel = de._parse_destination("${build_dir}")
            assert.equals("${build_dir}", base)
            assert.equals("", rel)
        end)

        it("parses unknown path as no base", function()
            local base, rel = de._parse_destination("/absolute/path/file.dll")
            assert.equals("", base)
            assert.equals("/absolute/path/file.dll", rel)
        end)

        it("parses plain relative path as no base", function()
            local base, rel = de._parse_destination("some/relative/path")
            assert.equals("", base)
            assert.equals("some/relative/path", rel)
        end)

        it("combine round-trips with base", function()
            local dest = de._combine_destination("${build_dir}", "lib/native.node")
            assert.equals("${build_dir}/lib/native.node", dest)
            local base, rel = de._parse_destination(dest)
            assert.equals("${build_dir}", base)
            assert.equals("lib/native.node", rel)
        end)

        it("combine with no base returns relative only", function()
            local dest = de._combine_destination("", "some/path")
            assert.equals("some/path", dest)
        end)

        it("combine with empty relative returns base only", function()
            local dest = de._combine_destination("${build_dir}", "")
            assert.equals("${build_dir}", dest)
        end)
    end)
end)
