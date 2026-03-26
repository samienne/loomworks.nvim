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
        has_keyed_tools = true,
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
    ws:_cleanup_orphaned_skeletons()
    ws:remerge()
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
        assert.is_not_nil(ctx.available_configs["App"])
        assert.is_not_nil(ctx.available_configs["Frontend"])

        local ok, err = wv.execute_create_config_set(ws, "Debug", {
            App = "Debug",
            Frontend = "debug",
        })
        assert.is_true(ok)
        assert.is_not_nil(ws.config.configuration_sets["Debug"])

        -- Verify config set object was created
        local config_sets = ws:get_config_sets()
        assert.is_not_nil(config_sets["Debug"])

        -- 2. Edit: change Frontend mapping
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        assert.is_not_nil(edit_ctx)
        assert.equals("Debug", edit_ctx.mappings["App"])
        assert.equals("debug", edit_ctx.mappings["Frontend"])

        local cs = ws._config_sets["Debug"]
        ok = wv.execute_edit_config_set(cs, "Debug",
            { App = "Release", Frontend = "release" },
            { App = "Debug", Frontend = "debug" })
        assert.is_true(ok)
        assert.equals("Release", ws.config.configuration_sets["Debug"]["App"])
        assert.equals("release", ws.config.configuration_sets["Debug"]["Frontend"])

        -- 3. Rename: Debug → Production
        cs = ws._config_sets["Debug"]
        ok = wv.execute_edit_config_set(cs, "Production",
            { App = "Release", Frontend = "release" },
            { App = "Release", Frontend = "release" })
        assert.is_true(ok)
        assert.is_nil(ws.config.configuration_sets["Debug"])
        assert.is_not_nil(ws.config.configuration_sets["Production"])

        -- 4. Delete
        local del_ctx = wv.compute_delete_config_set_context(ws, "Production")
        assert.is_not_nil(del_ctx)

        ok = wv.execute_delete_config_set(ws, "Production")
        assert.is_true(ok)
        -- Last set removed → configuration_sets is nil
        assert.is_true(ws.config.configuration_sets == nil
            or ws.config.configuration_sets["Production"] == nil)
    end)

    it("create validates duplicate names", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "Debug" } },
        })

        local ok, err = wv.execute_create_config_set(ws, "Debug", { App = "Debug" })
        assert.is_false(ok)
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

        local cs = ws._config_sets["Debug"]
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { App = "Debug" }, -- Frontend removed
            { App = "Debug", Frontend = "debug" })
        assert.is_true(ok)
        assert.is_nil(ws.config.configuration_sets["Debug"]["Frontend"])
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

        local config_sets = ws:get_config_sets()
        local cs = config_sets["Debug"]
        assert.is_not_nil(cs)

        -- Create profile (activate since first)
        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", profile.key)
        assert.equals("Debug", ws.user.active_profile)
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

        local config_sets = ws:get_config_sets()
        local cs = config_sets["Debug"]

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
        assert.is_not_nil(ws.config.configuration_sets["Debug"])
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
        assert.is_not_nil(ws._projects["App"])
        assert.equals("Debug", ws.config.configuration_sets["Debug"]["App"])

        -- Simulate cached state
        local ck = cache_mod.config_cache_key("App", "Debug")
        ws.cache.configurations = ws.cache.configurations or {}
        ws.cache.configurations[ck] = {
            project_key = "App", config_key = "Debug",
            type = "cmake", variant = "Debug", state = "built",
            build_dir = "/root/.nvim/build/App/Debug",
        }
        ws:remerge()

        -- Compute removal context
        local ctx = wv.compute_remove_context(ws, "App")
        assert.is_not_nil(ctx)
        assert.equals("cmake", ctx.project_type)
        assert.equals(1, #ctx.cached_configs)

        -- Execute removal
        local done = false
        wv.execute_remove_project(ws, "App", ctx, function(success)
            done = true
            assert.is_true(success)
        end)
        assert.is_true(done)
        assert.is_nil(ws._projects["App"])
        assert.is_nil(ws.cache.configurations[ck])
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

    it("find_project_key_by_path matches by path", function()
        local ws = make_ws({
            projects = {
                MyApp = { cmake = {}, path = "src/app" },
            },
        })

        assert.equals("MyApp", wv.find_project_key_by_path(ws, "src/app", "app"))
        assert.is_nil(wv.find_project_key_by_path(ws, "other", "other"))
    end)

    it("find_project_key_by_path matches by basename", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        assert.equals("App", wv.find_project_key_by_path(ws, "App", "App"))
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
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.equals("Debug:ninja-gcc-12", ws.user.active_profile)

        -- Skeleton cache entry created for cmake project
        assert.is_not_nil(ws.cache.configurations["App/Debug:ninja-gcc-12"])
        assert.equals("cmake", ws.cache.configurations["App/Debug:ninja-gcc-12"].type)

        -- Non-keyed entry preserved without tool suffix
        assert.is_not_nil(ws.cache.configurations["Frontend/debug"])
        assert.is_nil(ws.cache.configurations["Frontend/debug:ninja-gcc-12"])
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

        local ctx = wv.compute_remove_context(ws, "App")
        assert.equals(1, #ctx.downgrade_preview)

        local done = false
        wv.execute_remove_project(ws, "App", ctx, function(ok)
            done = true
            assert.is_true(ok)
        end)
        assert.is_true(done)

        -- Profile downgraded: Debug:ninja-gcc-12 → Debug
        assert.is_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.is_not_nil(ws.cache.profiles["Debug"])
        assert.is_nil(ws.cache.profiles["Debug"].tools)
        assert.equals("Debug", ws.user.active_profile)
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
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])

        -- Pinned profile unchanged
        assert.is_not_nil(ws.cache.profiles["App/Debug"])
        assert.is_nil(ws.cache.profiles["App/Debug"].tools)
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
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.is_nil(ws.cache.profiles["Debug"])
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
        local ok = wv.execute_delete_config_set(ws, "Debug")
        assert.is_true(ok)

        -- Profile is orphaned_set
        local profiles = ws:get_config_sets()
        local profile = ws._profiles["Debug"]
        assert.is_not_nil(profile)
        assert.is_true(profile.orphaned_set)

        -- Config still referenced by orphaned profile → not orphaned yet
        assert.equals(0, #ws:get_orphaned_configs())

        -- Delete the profile from cache → config becomes orphaned
        ws.cache.profiles["Debug"] = nil
        ws:remerge()

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

        -- Cache entry removed
        assert.is_nil(ws.cache.configurations["Frontend/debug"])
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
        local cs = ws._config_sets["Debug"]
        local ok = wv.execute_edit_config_set(cs, "Debug",
            { Frontend = "release" },
            { Frontend = "debug" })
        assert.is_true(ok)
        assert.equals("release", ws.config.configuration_sets["Debug"]["Frontend"])

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

        local plan = { items = {}, profile_key = "Debug" }
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

        local profiles = ws:get_config_sets()["Debug"]:find_profile(nil)
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
        local unit = ws._config_units["App/Debug"]
        local items = wv.collect_clean_items_for_unit(unit)
        assert.equals(1, #items)
        assert.equals("App", items[1].project_key)
        assert.equals("Debug", items[1].config_key)
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

        local ok = wv.execute_rename_config_set(ws, "debug", "Debug",
            { App = "Debug", Frontend = "debug" })
        assert.is_true(ok)

        -- Old set gone, new set exists
        assert.is_nil(ws.config.configuration_sets["debug"])
        assert.is_not_nil(ws.config.configuration_sets["Debug"])

        -- Cached profile points to new name
        assert.equals("Debug",
            ws.cache.profiles["debug:ninja-gcc-12"].configuration_set)
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
        local ok, err = ws:add_configuration_set("debug", { App = "debug" })
        assert.is_false(ok)
        assert.matches("case%-insensitive", err)
    end)

    it("add_project rejects case-colliding key", function()
        local ws = make_ws()
        -- "App" already exists from default config
        local ok, err = ws:add_project("app", "cmake")
        assert.is_false(ok)
        assert.matches("same build directory", err)
    end)

    it("add_project rejects slashes in key", function()
        local ws = make_ws()
        local ok, err = ws:add_project("foo/bar", "cmake")
        assert.is_false(ok)
        assert.matches("slashes", err)
    end)

    it("add_project rejects dot-dot key", function()
        local ws = make_ws()
        local ok, err = ws:add_project("..", "cmake")
        assert.is_false(ok)
    end)

    it("add_project rejects sanitization collision", function()
        local ws = make_ws({ projects = { ["My_App"] = { cmake = {} } } })
        -- "My:App" sanitizes to "My_App" — collision
        local ok, err = ws:add_project("My:App", "cmake")
        assert.is_false(ok)
        assert.matches("same build directory", err)
    end)

    it("save_configuration rejects slashes", function()
        local ws = make_ws()
        local project = ws._projects["App"]
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

        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug", options = { ASAN = "ON" },
        })
        assert.is_true(ok)

        -- Config renamed in type_config
        assert.is_nil(ws._projects["App"].type_config.configurations["Debug-asan"])
        assert.is_not_nil(ws._projects["App"].type_config.configurations["DebugASAN"])

        -- Config set mapping updated
        assert.equals("DebugASAN", ws.config.configuration_sets.debug.App)
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
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = {}, label = "Ninja GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
            },
        })

        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {})
        assert.is_true(ok)

        -- Old cache key gone, new one exists
        assert.is_nil(ws.cache.configurations["App/Debug-asan:ninja-gcc"])
        local new_entry = ws.cache.configurations["App/DebugASAN:ninja-gcc"]
        assert.is_not_nil(new_entry)

        -- Fields updated
        assert.equals("DebugASAN", new_entry.variant)
        assert.equals("DebugASAN:ninja-gcc", new_entry.config_key)

        -- Build dir preserved (old path stays)
        assert.equals("/root/.nvim/build/App/ninja-gcc/Debug-asan", new_entry.build_dir)

        -- Profile configurations array updated
        local profile = ws.cache.profiles["debug:ninja-gcc"]
        assert.is_not_nil(profile)
        assert.equals("App/DebugASAN:ninja-gcc", profile.configurations[1])
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

        local project = ws._projects["App"]
        local ok = project:rename_configuration("base", "BaseConfig", {
            options = { X = "1" },
        })
        assert.is_true(ok)

        -- String inherits updated
        assert.equals("BaseConfig",
            ws._projects["App"].type_config.configurations.child.inherits)

        -- Array inherits updated
        local multi_inh = ws._projects["App"].type_config.configurations.multi.inherits
        assert.equals("Debug", multi_inh[1])
        assert.equals("BaseConfig", multi_inh[2])
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

        local project = ws._projects["App"]
        local ok = project:rename_configuration("old", "new", {
            options = { A = "1" },
        })
        assert.is_true(ok)
        assert.is_nil(ws._projects["App"].type_config.configurations.old)
        assert.is_not_nil(ws._projects["App"].type_config.configurations.new)
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
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "built",
                },
                ["App/Debug-asan:ninja-clang"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-clang",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-clang",
                    state = "configured",
                },
            },
            profiles = {
                ["debug:ninja-gcc"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc", data = {}, label = "GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
                ["debug:ninja-clang"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-clang", data = {}, label = "Clang" } },
                    configurations = { "App/Debug-asan:ninja-clang" },
                },
            },
        })

        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {})
        assert.is_true(ok)

        -- Both cache entries migrated
        assert.is_not_nil(ws.cache.configurations["App/DebugASAN:ninja-gcc"])
        assert.is_not_nil(ws.cache.configurations["App/DebugASAN:ninja-clang"])

        -- Both profiles updated
        assert.equals("App/DebugASAN:ninja-gcc",
            ws.cache.profiles["debug:ninja-gcc"].configurations[1])
        assert.equals("App/DebugASAN:ninja-clang",
            ws.cache.profiles["debug:ninja-clang"].configurations[1])
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
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = {}, label = "GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
            },
        })

        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Old pinned profile key gone
        assert.is_nil(ws.cache.profiles["App/Debug-asan:ninja-gcc"])

        -- New pinned profile key exists with updated mapping
        local profile = ws.cache.profiles["App/DebugASAN:ninja-gcc"]
        assert.is_not_nil(profile)
        assert.equals("DebugASAN", profile.mappings.App)

        -- Cache entry rekeyed
        assert.is_not_nil(ws.cache.configurations["App/DebugASAN:ninja-gcc"])

        -- Profile configurations array updated
        assert.equals("App/DebugASAN:ninja-gcc", profile.configurations[1])
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
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "configured",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = {}, label = "GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
            },
        })

        assert.equals("App/Debug-asan:ninja-gcc", ws.user.active_profile)

        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Active profile updated to new key
        assert.equals("App/DebugASAN:ninja-gcc", ws.user.active_profile)
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
        local profile = ws._profiles["asan:ninja-gcc"]
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("Debug-asan", pp:variant_name())
        assert.is_not_nil(pp:configuration())

        -- Rename
        local project = ws._projects["App"]
        local ok = project:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Configuration domain object exists under new name
        assert.is_not_nil(project:get_configuration("DebugASAN"))
        assert.is_nil(project:get_configuration("Debug-asan"))

        -- PP resolves the renamed Configuration
        profile = ws._profiles["asan:ninja-gcc"]
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
            configurations = {
                ["App/Debug-asan:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug-asan:ninja-gcc",
                    type = "cmake", variant = "Debug-asan", tool_key = "ninja-gcc",
                    state = "built", build_dir = "/root/.nvim/build/App/ninja-gcc/Debug-asan",
                },
            },
            profiles = {
                ["App/Debug-asan:ninja-gcc"] = {
                    mappings = { App = "Debug-asan" },
                    tools = { cmake = { key = "ninja-gcc", data = { id = "ninja-gcc", display = "GCC" }, label = "GCC" } },
                    configurations = { "App/Debug-asan:ninja-gcc" },
                },
            },
        })

        -- Before rename: PP works
        local profile = ws._profiles["App/Debug-asan:ninja-gcc"]
        assert.is_not_nil(profile)
        local pp = profile:project("App")
        assert.equals("Debug-asan", pp:variant_name())

        -- Rename
        local ok = ws._projects["App"]:rename_configuration("Debug-asan", "DebugASAN", {
            inherits = "Debug",
        })
        assert.is_true(ok)

        -- Pinned profile key changed
        assert.is_nil(ws._profiles["App/Debug-asan:ninja-gcc"])
        profile = ws._profiles["App/DebugASAN:ninja-gcc"]
        assert.is_not_nil(profile)

        -- PP resolves new name
        pp = profile:project("App")
        assert.is_not_nil(pp)
        assert.equals("DebugASAN", pp:variant_name())
        assert.is_not_nil(pp:configuration())
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
        local project = ws._projects["App"]
        local cfg = project:get_configuration("CustomBuild")
        assert.is_not_nil(cfg)
        assert.is_true(cfg._source_missing)

        -- PP resolves the cache-enriched Configuration
        local profile = ws._profiles["custom:ninja-gcc"]
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

        local project = ws._projects["App"]

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
        local cs = ws._config_sets["custom"]
        ok = cs:update_mapping(project, "Debug-ASAN")
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

        local ok = wv.execute_save_configuration(ws._projects["App"], "old_cfg", "new_cfg", {
            options = { A = "1" },
        })
        assert.is_true(ok)

        -- Config renamed (not delete+create)
        assert.is_nil(ws._projects["App"].type_config.configurations.old_cfg)
        assert.is_not_nil(ws._projects["App"].type_config.configurations.new_cfg)

        -- Config set mapping updated atomically
        assert.equals("new_cfg", ws.config.configuration_sets.debug.App)
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

        -- Create config set
        ok = wv.execute_create_config_set(ws, "Debug", {
            App = "Debug",
            Frontend = "debug",
        })
        assert.is_true(ok)

        -- Verify config set context is correct
        local edit_ctx = wv.compute_edit_config_set_context(ws, "Debug")
        assert.is_not_nil(edit_ctx)
        assert.equals(2, #edit_ctx.project_keys)
        assert.equals("Debug", edit_ctx.mappings["App"])
        assert.equals("debug", edit_ctx.mappings["Frontend"])

        -- Create profile from config set
        local config_sets = ws:get_config_sets()
        local cs = config_sets["Debug"]
        assert.is_not_nil(cs)

        local profile = wv.execute_create_profile(cs, nil, true)
        assert.is_not_nil(profile)
        assert.equals("Debug", ws.user.active_profile)

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
        local app = ws._projects["App"]
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
        assert.equals("npx", ws._projects["App"].launch["debug"].command)
        assert.equals("true", ws._projects["App"].launch["debug"].env.DEBUG)

        -- 4. Rename: debug → dev
        ok = wv.execute_save_launch_config(app, "debug", "dev", {
            command = "npx",
            args = { "ts-node", "app.ts" },
            working_dir = "",
            env = { NODE_ENV = "development" },
        })
        assert.is_true(ok)
        assert.is_nil(ws._projects["App"].launch["debug"])
        assert.is_not_nil(ws._projects["App"].launch["dev"])

        -- 5. Delete
        ok = wv.execute_delete_launch_config(app, "dev")
        assert.is_true(ok)
        -- launch key cleaned up when empty
        assert.is_nil(ws._projects["App"].launch)
    end)

    it("compute_edit_launch_context returns defaults for new config", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        local ctx = wv.compute_edit_launch_context(ws._projects["App"], nil)
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

        local ctx = wv.compute_edit_launch_context(ws._projects["App"], "debug")
        assert.equals("debug", ctx.name)
        assert.equals("node", ctx.command)
        assert.equals(2, #ctx.args)
        assert.equals("app.js", ctx.args[1])
        assert.equals("${workspace_root}/App", ctx.working_dir)
        assert.equals("dev", ctx.env.NODE_ENV)
    end)

    it("omits empty optional fields when saving", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        wv.execute_save_launch_config(ws._projects["App"], nil, "minimal", {
            command = "echo",
            args = {},
            working_dir = "",
            env = {},
        })

        local saved = ws._projects["App"].launch["minimal"]
        assert.equals("echo", saved.command)
        assert.is_nil(saved.args)
        assert.is_nil(saved.working_dir)
        assert.is_nil(saved.env)
    end)

    it("returns error for removed project", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local app = ws._projects["App"]

        -- Simulate project removal: remove from config
        ws:remove_project("App")

        local ok, err = app:save_launch_config("test", { command = "echo" })
        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("get_launch_configs returns empty for project without launches", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local configs = wv.get_launch_configs(ws._projects["App"])
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

        local configs = wv.get_launch_configs(ws._projects["App"])
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
        local ok, err = wv.execute_save_configuration(ws._projects["App"], nil, "Debug-ASAN", {
            inherits = "Debug",
            options = { SANITIZE_ADDRESS = "ON" },
        })
        assert.is_true(ok)
        assert.is_not_nil(ws._projects["App"].type_config)
        assert.is_not_nil(ws._projects["App"].type_config.configurations["Debug-ASAN"])
        assert.equals("Debug",
            ws._projects["App"].type_config.configurations["Debug-ASAN"].inherits)
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

        local ok = wv.execute_save_configuration(ws._projects["App"], "Debug", "Debug", {
            options = { ENABLE_TESTS = "OFF", VERBOSE = "ON" },
        })
        assert.is_true(ok)
        assert.equals("OFF",
            ws._projects["App"].type_config.configurations["Debug"].options.ENABLE_TESTS)
        assert.equals("ON",
            ws._projects["App"].type_config.configurations["Debug"].options.VERBOSE)
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

        local ok = wv.execute_save_configuration(ws._projects["App"], "Debug-ASAN", "Debug-Sanitized", {
            inherits = "Debug",
            options = { ASAN = "ON" },
        })
        assert.is_true(ok)
        assert.is_nil(ws._projects["App"].type_config.configurations["Debug-ASAN"])
        assert.is_not_nil(ws._projects["App"].type_config.configurations["Debug-Sanitized"])
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

        local ok = wv.execute_delete_configuration(ws._projects["App"], "Debug-ASAN")
        assert.is_true(ok)
        -- configurations key cleaned up when empty
        assert.is_true(
            ws._projects["App"].type_config.configurations == nil
            or ws._projects["App"].type_config.configurations["Debug-ASAN"] == nil)
    end)

    it("saves project-wide options", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ok = wv.execute_save_project_options(ws._projects["App"], {
            CMAKE_EXPORT_COMPILE_COMMANDS = "ON",
            MY_FLAG = "hello",
        })
        assert.is_true(ok)
        assert.equals("ON", ws._projects["App"].type_config.options.CMAKE_EXPORT_COMPILE_COMMANDS)
        assert.equals("hello", ws._projects["App"].type_config.options.MY_FLAG)
    end)

    it("clears project-wide options when empty", function()
        local ws = make_ws({
            projects = {
                App = { cmake = { options = { FOO = "bar" } } },
            },
        })

        local ok = wv.execute_save_project_options(ws._projects["App"], {})
        assert.is_true(ok)
        assert.is_nil(ws._projects["App"].type_config.options)
    end)

    it("compute_edit_configuration_context returns defaults for new config", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ctx = wv.compute_edit_configuration_context(ws._projects["App"], nil)
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

        local ctx = wv.compute_edit_configuration_context(ws._projects["App"], "Debug-ASAN")
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

        local ctx = wv.compute_edit_configuration_context(ws._projects["App"], "Debug")
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
        assert.is_not_nil(ws._projects["proj-alpha"])
        assert.equals("cmake", ws._projects["proj-alpha"].type)
        assert.is_not_nil(ws._projects["proj-beta"])
        assert.equals("ets", ws._projects["proj-beta"].type)
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

        -- ConfigUnit has cached state with arbitrary key
        local cached = pp_alpha:cached_state()
        assert.is_not_nil(cached)
        assert.equals("built", cached.state)
        assert.equals("/root/.nvim/build/arbitrary-dir", cached.build_dir)
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
        local proj = ws._projects["proj-alpha"]
        local cfg = proj:get_configuration("Debug")
        assert.is_not_nil(cfg)
        local units = proj:config_units_for_configuration(cfg)
        assert.equals(1, #units)
        assert.equals("cfg-42", units[1]._cached.config_key)
    end)

    it("build_dir_refs track arbitrary cache entries", function()
        local ws = make_opaque_ws()
        local refs = ws:get_build_dir_refs("/root/.nvim/build/arbitrary-dir")
        assert.equals(1, #refs)
        assert.equals("cfg-42", refs[1]._cached.config_key)
    end)

    it("config set mapping updates work with arbitrary project keys", function()
        local ws = make_opaque_ws()
        local cs = ws._config_sets["set-x"]
        assert.is_not_nil(cs)

        local proj = ws._projects["proj-alpha"]
        cs:update_mapping(proj, "Release")

        -- Verify mapping changed
        assert.equals("Release", cs.mappings[proj])
    end)

    it("save_configuration works on project with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = ws._projects["proj-alpha"]

        local ok = proj:save_configuration("custom-cfg", {
            options = { MY_FLAG = "ON" },
        })
        assert.is_true(ok)
        assert.is_not_nil(proj.type_config.configurations["custom-cfg"])
    end)

    it("rename_configuration propagates with arbitrary keys", function()
        local ws = make_opaque_ws()
        local proj = ws._projects["proj-alpha"]

        -- Add a user-defined config to rename
        proj:save_configuration("temp-name", { options = { X = "1" } })

        local ok = proj:rename_configuration("temp-name", "new-name", {
            options = { X = "1" },
        })
        assert.is_true(ok)
        assert.is_nil(proj.type_config.configurations["temp-name"])
        assert.is_not_nil(proj.type_config.configurations["new-name"])
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
