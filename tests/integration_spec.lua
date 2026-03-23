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
        info = function()
            return { configurations = { Debug = {}, Release = {}, RelWithDebInfo = {} } }
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

        ok = wv.execute_edit_config_set(ws, "Debug", "Debug",
            { App = "Release", Frontend = "release" },
            { App = "Debug", Frontend = "debug" })
        assert.is_true(ok)
        assert.equals("Release", ws.config.configuration_sets["Debug"]["App"])
        assert.equals("release", ws.config.configuration_sets["Debug"]["Frontend"])

        -- 3. Rename: Debug → Production
        ok = wv.execute_edit_config_set(ws, "Debug", "Production",
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

        local ok = wv.execute_edit_config_set(ws, "Debug", "Debug",
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
        assert.is_not_nil(ws.config.projects["App"])
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
        assert.is_nil(ws.config.projects["App"])
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
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", type = "cmake" },
                    ["Lib/Debug:ninja-gcc-12"] = { project_key = "Lib", config_key = "Debug:ninja-gcc-12", type = "cmake" },
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
        local ok = wv.execute_edit_config_set(ws, "Debug", "Debug",
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
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local unit = ws:get_config_unit("App", "Debug")
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
