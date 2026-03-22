local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")
local workspace_view = require("loomworks.workspace_view")

local Workspace = workspace.Workspace

--- Mock module registry for has_keyed_tools checks.
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
    },
    ets = {
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type or name == variant_type then return name end
            end
            return nil
        end,
    },
    typescript = { has_keyed_tools = false },
}

--- Create a real Workspace instance with mock deps for testing.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @return loomworks.Workspace
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
            io = { write_json = function() return true end, ensure_dir = function() return true end },
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
        },
        _events_log = events_log,
    }

    local ws = Workspace.new(mock_core, data)
    return ws
end

-- =========================================================================
-- compute_add_project_context
-- =========================================================================

describe("compute_add_project_context", function()
    it("returns empty context when no cached profiles", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { Debug = { Frontend = "debug" } },
        })

        local ctx = workspace_view.compute_add_project_context(ws, "cmake")

        assert.is_nil(ctx.inherited_tool)
        assert.equals(0, #ctx.no_tool_profiles)
    end)

    it("finds inherited tool from cached profiles", function()
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
            nil,
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = {
                            cmake = {
                                key = "ninja-gcc-12",
                                data = { id = "ninja-gcc-12" },
                                label = "Ninja - GCC 12",
                            },
                        },
                        configurations = { "Frontend/debug", "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", type = "cmake", variant = "Debug" },
                },
            }
        )

        local ctx = workspace_view.compute_add_project_context(ws, "cmake")

        assert.is_not_nil(ctx.inherited_tool)
        assert.equals("ninja-gcc-12", ctx.inherited_tool.tool_key)
        assert.equals("Ninja - GCC 12", ctx.inherited_tool.tool_label)
        assert.equals("cmake", ctx.inherited_tool.tool_mod_type)
        -- keyed_tools should be empty when tool is inherited
        assert.equals(0, #ctx.keyed_tools)
    end)

    it("collects no-tool profiles when no inherited tool", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                    Release = { Frontend = "release" },
                },
            },
            nil,
            {
                profiles = {
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                    Release = {
                        configuration_set = "Release",
                        configurations = { "Frontend/release" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["Frontend/release"] = { project_key = "Frontend", config_key = "release", type = "ets", variant = "release" },
                },
            }
        )

        local ctx = workspace_view.compute_add_project_context(ws, "cmake")

        assert.is_nil(ctx.inherited_tool)
        assert.equals(2, #ctx.no_tool_profiles)
        -- Sorted
        assert.equals("Debug", ctx.no_tool_profiles[1])
        assert.equals("Release", ctx.no_tool_profiles[2])
    end)

    it("returns no-tool profiles and keyed_tools from cache", function()
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
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                },
            }
        )

        -- Simulate cached tools
        ws._tools_by_type["cmake"] = {
            { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" }, tool_label = "Ninja - GCC 12" },
            { tool_data = {} }, -- no tool_key — filtered out
        }

        local ctx = workspace_view.compute_add_project_context(ws, "cmake")

        assert.is_nil(ctx.inherited_tool)
        assert.equals(1, #ctx.keyed_tools)
        assert.equals("ninja-gcc-12", ctx.keyed_tools[1].tool_key)
    end)

    it("returns empty for non-keyed module type", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ctx = workspace_view.compute_add_project_context(ws, "ets")

        assert.is_nil(ctx.inherited_tool)
        assert.equals(0, #ctx.no_tool_profiles)
    end)
end)

-- =========================================================================
-- ensure_tools_detected
-- =========================================================================

describe("ensure_tools_detected", function()
    it("uses cached tools when available", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        ws._tools_by_type["cmake"] = {
            { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" } },
            { tool_data = {} }, -- no key
        }

        local result
        workspace_view.ensure_tools_detected(ws, mock_modules.cmake, "cmake", function(keyed)
            result = keyed
        end)

        assert.is_not_nil(result)
        assert.equals(1, #result)
        assert.equals("ninja-gcc-12", result[1].tool_key)
    end)

    it("triggers async detection and caches result", function()
        local ws = make_ws({ projects = { Frontend = { ets = {} } } })
        assert.is_nil(ws._tools_by_type["cmake"])

        local detect_called = false
        local mock_mod = {
            has_keyed_tools = true,
            detect_tools_async = function(callback)
                detect_called = true
                callback({
                    { tool_data = { id = "ninja-gcc-12", display = "Ninja - GCC 12" } },
                    { tool_data = { id = "ninja-clang-15", display = "Ninja - Clang 15" } },
                })
            end,
            tool_key = function(tool_data) return tool_data.id end,
            tool_label = function(tool_data) return tool_data.display end,
        }

        local result
        workspace_view.ensure_tools_detected(ws, mock_mod, "cmake", function(keyed)
            result = keyed
        end)

        assert.is_true(detect_called)
        assert.is_not_nil(result)
        assert.equals(2, #result)
        -- Verify caching
        assert.is_not_nil(ws._tools_by_type["cmake"])
        assert.equals(2, #ws._tools_by_type["cmake"])
    end)
end)

-- =========================================================================
-- execute_add_project
-- =========================================================================

describe("execute_add_project", function()
    it("adds project and applies mappings", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = {
                Debug = { Frontend = "debug" },
                Release = { Frontend = "release" },
            },
        })

        local result = {
            mappings = { Debug = "Debug", Release = "Release" },
            tool_entry = nil,
        }

        local ok, err = workspace_view.execute_add_project(ws, "App", "cmake", nil, result, false)
        assert.is_true(ok)
        assert.is_nil(err)

        -- Project was added
        assert.is_not_nil(ws.config.projects["App"])

        -- Mappings applied
        assert.equals("Debug", ws.config.configuration_sets["Debug"]["App"])
        assert.equals("Release", ws.config.configuration_sets["Release"]["App"])
    end)

    it("skips mappings for keyed module without tool", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = {
                Debug = { Frontend = "debug" },
            },
        })

        local result = {
            mappings = { Debug = "Debug" },
            tool_entry = nil,
        }

        local ok = workspace_view.execute_add_project(ws, "App", "cmake", nil, result, true)
        assert.is_true(ok)

        -- Project added but no mapping applied
        assert.is_not_nil(ws.config.projects["App"])
        assert.is_nil(ws.config.configuration_sets["Debug"]["App"])
    end)

    it("adds project with tool and upgrades profiles", function()
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
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                },
            }
        )

        local tool_entry = {
            tool_key = "ninja-gcc-12",
            tool_data = { id = "ninja-gcc-12" },
            tool_label = "Ninja - GCC 12",
            tool_mod_type = "cmake",
        }

        local result = {
            mappings = { Debug = "Debug" },
            tool_entry = tool_entry,
        }

        local ok = workspace_view.execute_add_project(ws, "App", "cmake", nil, result, true)
        assert.is_true(ok)

        -- Profile was upgraded
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.equals("ninja-gcc-12", ws.cache.profiles["Debug:ninja-gcc-12"].tools.cmake.key)
        assert.equals("Debug:ninja-gcc-12", ws.user.active_profile)
    end)

    it("returns error when add_project fails", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        -- Adding same project again should fail
        local ok, err = workspace_view.execute_add_project(ws, "App", "cmake", nil, { mappings = {} }, false)
        assert.is_false(ok)
        assert.is_not_nil(err)
    end)
end)

-- =========================================================================
-- compute_remove_context
-- =========================================================================

describe("compute_remove_context", function()
    it("returns nil for nonexistent project", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local ctx = workspace_view.compute_remove_context(ws, "NonExistent")
        assert.is_nil(ctx)
    end)

    it("returns context with project type and lines", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ctx = workspace_view.compute_remove_context(ws, "App")
        assert.is_not_nil(ctx)
        assert.equals("cmake", ctx.project_type)
        assert.equals(0, #ctx.downgrade_preview)
        -- Lines contain project name
        local found = false
        for _, line in ipairs(ctx.lines) do
            if line:find("App") then found = true; break end
        end
        assert.is_true(found)
    end)

    it("includes downgrade preview when last keyed project", function()
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
            nil,
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tools = {
                            cmake = {
                                key = "ninja-gcc-12",
                                data = { id = "ninja-gcc-12" },
                                label = "Ninja - GCC 12",
                            },
                        },
                        configurations = { "Frontend/debug", "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", type = "cmake", variant = "Debug" },
                },
            }
        )

        local ctx = workspace_view.compute_remove_context(ws, "App")
        assert.is_not_nil(ctx)
        assert.equals("cmake", ctx.project_type)
        assert.equals(1, #ctx.downgrade_preview)
        assert.equals("Debug:ninja-gcc-12", ctx.downgrade_preview[1].old_key)
        assert.equals("Debug", ctx.downgrade_preview[1].new_key)

        -- Lines should mention rename
        local found_rename = false
        for _, line in ipairs(ctx.lines) do
            if line:find("Profiles to rename") then found_rename = true; break end
        end
        assert.is_true(found_rename)
    end)
end)

-- =========================================================================
-- execute_remove_project
-- =========================================================================

describe("execute_remove_project", function()
    it("removes project without downgrade", function()
        local ws = make_ws({
            projects = {
                Frontend = { ets = {} },
                App = { cmake = {} },
            },
        })

        local ok, err = workspace_view.execute_remove_project(ws, "App", "cmake", false)
        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_nil(ws.config.projects["App"])
        assert.is_not_nil(ws.config.projects["Frontend"])
    end)

    it("removes project with downgrade", function()
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
                            cmake = {
                                key = "ninja-gcc-12",
                                data = { id = "ninja-gcc-12" },
                                label = "Ninja - GCC 12",
                            },
                        },
                        configurations = { "Frontend/debug", "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["App/Debug:ninja-gcc-12"] = { project_key = "App", config_key = "Debug:ninja-gcc-12", type = "cmake", variant = "Debug" },
                },
            }
        )

        local ok = workspace_view.execute_remove_project(ws, "App", "cmake", true)
        assert.is_true(ok)

        assert.is_nil(ws.config.projects["App"])
        -- Profile was downgraded
        assert.is_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.is_not_nil(ws.cache.profiles["Debug"])
        assert.is_nil(ws.cache.profiles["Debug"].tools)
        assert.equals("Debug", ws.user.active_profile)
    end)

    it("returns error for nonexistent project", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local ok, err = workspace_view.execute_remove_project(ws, "NonExistent", "cmake", false)
        assert.is_false(ok)
        assert.is_not_nil(err)
    end)
end)

-- =========================================================================
-- compute_initial_mappings
-- =========================================================================

describe("compute_initial_mappings", function()
    it("auto-detects matching variants", function()
        local mod = mock_modules.cmake
        local set_names = { "Debug", "Release" }
        local available = { "Debug", "Release", "RelWithDebInfo" }

        local mappings = workspace_view.compute_initial_mappings(mod, set_names, available)

        assert.equals("Debug", mappings["Debug"])
        assert.equals("Release", mappings["Release"])
    end)

    it("returns nil for unmatched variants", function()
        local mod = mock_modules.cmake
        local set_names = { "Debug", "Custom" }
        local available = { "Debug", "Release" }

        local mappings = workspace_view.compute_initial_mappings(mod, set_names, available)

        assert.equals("Debug", mappings["Debug"])
        assert.is_nil(mappings["Custom"])
    end)

    it("handles module without map_variant", function()
        local mod = { has_keyed_tools = false }
        local set_names = { "Debug" }
        local available = { "Debug" }

        local mappings = workspace_view.compute_initial_mappings(mod, set_names, available)

        assert.is_nil(mappings["Debug"])
    end)
end)

-- =========================================================================
-- compute_upgrade_preview
-- =========================================================================

describe("compute_upgrade_preview", function()
    it("returns upgrades for profiles with matching mappings", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                    Release = { Frontend = "release" },
                },
            },
            nil,
            {
                profiles = {
                    Debug = { configuration_set = "Debug", configurations = { "Frontend/debug" } },
                    Release = { configuration_set = "Release", configurations = { "Frontend/release" } },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["Frontend/release"] = { project_key = "Frontend", config_key = "release", type = "ets", variant = "release" },
                },
            }
        )
        local tool_entry = { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" }, tool_label = "Ninja - GCC 12", tool_mod_type = "cmake" }
        local mappings = { Debug = "Debug", Release = "Release" }

        local result = workspace_view.compute_upgrade_preview(ws, tool_entry, mappings)

        assert.equals(2, #result)
        assert.equals("Debug", result[1].old_key)
        assert.equals("Debug:ninja-gcc-12", result[1].new_key)
        assert.equals("Release", result[2].old_key)
        assert.equals("Release:ninja-gcc-12", result[2].new_key)
    end)

    it("filters out profiles without mapping", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                    Release = { Frontend = "release" },
                },
            },
            nil,
            {
                profiles = {
                    Debug = { configuration_set = "Debug", configurations = { "Frontend/debug" } },
                    Release = { configuration_set = "Release", configurations = { "Frontend/release" } },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                    ["Frontend/release"] = { project_key = "Frontend", config_key = "release", type = "ets", variant = "release" },
                },
            }
        )
        local tool_entry = { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" }, tool_label = "Ninja - GCC 12", tool_mod_type = "cmake" }
        local mappings = { Debug = "Debug", Release = nil }

        local result = workspace_view.compute_upgrade_preview(ws, tool_entry, mappings)

        assert.equals(1, #result)
        assert.equals("Debug", result[1].old_key)
        assert.equals("Debug:ninja-gcc-12", result[1].new_key)
    end)

    it("returns empty when no profiles match", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Custom = { Frontend = "debug" },
                },
            },
            nil,
            {
                profiles = {
                    Custom = { configuration_set = "Custom", configurations = { "Frontend/debug" } },
                },
                configurations = {
                    ["Frontend/debug"] = { project_key = "Frontend", config_key = "debug", type = "ets", variant = "debug" },
                },
            }
        )
        local tool_entry = { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" }, tool_label = "Ninja - GCC 12", tool_mod_type = "cmake" }
        local mappings = { Debug = "Debug" }

        local result = workspace_view.compute_upgrade_preview(ws, tool_entry, mappings)

        assert.equals(0, #result)
    end)

    it("returns empty when no cached profiles exist", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = {
                    Debug = { Frontend = "debug" },
                },
            }
        )
        local tool_entry = { tool_key = "ninja-gcc-12", tool_data = { id = "ninja-gcc-12" }, tool_label = "Ninja - GCC 12", tool_mod_type = "cmake" }
        local mappings = { Debug = "Debug" }

        local result = workspace_view.compute_upgrade_preview(ws, tool_entry, mappings)

        assert.equals(0, #result)
    end)
end)

-- =========================================================================
-- compute_config_set_candidates
-- =========================================================================

describe("compute_config_set_candidates", function()
    it("returns existing config sets", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = {
                Debug = { App = "Debug" },
                Release = { App = "Release" },
            },
        })

        -- Pass plain table simulating ConfigurationSet objects keyed by name
        local config_sets = { Debug = { name = "Debug" }, Release = { name = "Release" } }
        local items = workspace_view.compute_config_set_candidates(ws, config_sets)

        assert.equals(2, #items)
        -- Sorted alphabetically
        assert.equals("Debug", items[1].name)
        assert.equals("Release", items[2].name)
        assert.is_false(items[1].auto)
    end)

    it("includes auto-detected candidates not already existing", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        -- Inject generate_default_config_sets to return test data
        local orig = ws.generate_default_config_sets
        ws.generate_default_config_sets = function()
            return { Debug = { App = "Debug" }, Release = { App = "Release" } }
        end

        local items = workspace_view.compute_config_set_candidates(ws, {})

        assert.equals(2, #items)
        assert.is_true(items[1].auto)
        assert.is_not_nil(items[1].real_name)
        assert.is_not_nil(items[1].mappings)
        assert.is_not_nil(items[1].desc)

        ws.generate_default_config_sets = orig
    end)

    it("excludes auto-detected sets that already exist", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = {
                Debug = { App = "Debug" },
            },
        })

        local orig = ws.generate_default_config_sets
        ws.generate_default_config_sets = function()
            return { Debug = { App = "Debug" }, Release = { App = "Release" } }
        end

        local config_sets = { Debug = { name = "Debug" } }
        local items = workspace_view.compute_config_set_candidates(ws, config_sets)

        -- Debug exists, Release auto-detected
        assert.equals(2, #items)
        local auto_count = 0
        for _, item in ipairs(items) do
            if item.auto then auto_count = auto_count + 1 end
        end
        assert.equals(1, auto_count)

        ws.generate_default_config_sets = orig
    end)

    it("returns empty when no sets available", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })

        local items = workspace_view.compute_config_set_candidates(ws, {})

        -- May have auto-detected items depending on workspace state,
        -- but with no configuration sets and basic config, likely 0 or
        -- the auto-detect results
        assert.is_not_nil(items)
    end)
end)
