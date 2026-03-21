local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

--- Create a real Workspace instance with mock deps for testing mutations.
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
            modules = { get = function() return nil end },
            notify = function() end,
            schedule = function(fn) fn() end,
        },
        _events_log = events_log,
    }

    local ws = Workspace.new(mock_core, data)
    return ws
end

describe("upgrade_profiles_for_tool", function()
    local tool_entry = {
        tool_key = "ninja-gcc-12",
        tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_id = "GNU" },
        tool_label = "Ninja - GCC 12",
        tool_mod_type = "cmake",
    }

    it("renames no-tool profiles to keyed profiles", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { Frontend = "debug", App = "Debug" },
                    Release = { Frontend = "release", App = "Release" },
                },
            },
            { active_profile = "Debug" },
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
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                    ["Frontend/release"] = {
                        project_key = "Frontend",
                        config_key = "release",
                        type = "ets",
                        variant = "release",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- Old keys removed
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_nil(ws.cache.profiles["Release"])

        -- New keyed profiles exist
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
        assert.is_not_nil(ws.cache.profiles["Release:ninja-gcc-12"])

        -- Tool fields set
        local p = ws.cache.profiles["Debug:ninja-gcc-12"]
        assert.equals("ninja-gcc-12", p.tool_key)
        assert.equals("Ninja - GCC 12", p.tool_label)
        assert.equals("cmake", p.tool_mod_type)
        assert.is_not_nil(p.tool_data)

        -- active_profile migrated
        assert.equals("Debug:ninja-gcc-12", ws.user.active_profile)
    end)

    it("preserves existing configuration entries in renamed profiles", function()
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
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                        state = "configured",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        local p = ws.cache.profiles["Debug:ninja-gcc-12"]
        -- Original entry still in configurations array
        local has_frontend = false
        for _, ck in ipairs(p.configurations) do
            if ck == "Frontend/debug" then has_frontend = true end
        end
        assert.is_true(has_frontend)

        -- Original cache entry still has its state
        assert.equals("configured", ws.cache.configurations["Frontend/debug"].state)
    end)

    it("adds skeleton entries for new keyed-module projects in config set", function()
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
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- New cmake entry should be added with tool suffix
        local cmake_ck = "App/Debug:ninja-gcc-12"
        assert.is_not_nil(ws.cache.configurations[cmake_ck])
        assert.equals("App", ws.cache.configurations[cmake_ck].project_key)
        assert.equals("Debug:ninja-gcc-12", ws.cache.configurations[cmake_ck].config_key)
        assert.equals("cmake", ws.cache.configurations[cmake_ck].type)
        assert.equals("Debug", ws.cache.configurations[cmake_ck].variant)
        assert.equals("ninja-gcc-12", ws.cache.configurations[cmake_ck].tool_key)

        -- Profile configurations should include both
        local p = ws.cache.profiles["Debug:ninja-gcc-12"]
        assert.is_not_nil(p)
        local cks = {}
        for _, ck in ipairs(p.configurations) do cks[ck] = true end
        assert.is_true(cks["Frontend/debug"])
        assert.is_true(cks[cmake_ck])
    end)

    it("does not add tool suffix to non-keyed project entries", function()
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
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- ets entry should NOT have tool suffix
        assert.is_nil(ws.cache.configurations["Frontend/debug:ninja-gcc-12"])
        assert.is_not_nil(ws.cache.configurations["Frontend/debug"])
    end)

    it("extends existing keyed profiles with new project entries", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug", Lib = "Debug" },
                },
            },
            nil,
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tool_key = "ninja-gcc-12",
                        tool_data = { id = "ninja-gcc-12" },
                        tool_label = "Ninja - GCC 12",
                        tool_mod_type = "cmake",
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12",
                        type = "cmake",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- Profile should be extended with new Lib entry
        local p = ws.cache.profiles["Debug:ninja-gcc-12"]
        assert.is_not_nil(p)
        local cks = {}
        for _, ck in ipairs(p.configurations) do cks[ck] = true end
        assert.is_true(cks["App/Debug:ninja-gcc-12"])
        assert.is_true(cks["Lib/Debug:ninja-gcc-12"])

        -- Lib skeleton entry should exist
        assert.is_not_nil(ws.cache.configurations["Lib/Debug:ninja-gcc-12"])
        assert.equals("Lib", ws.cache.configurations["Lib/Debug:ninja-gcc-12"].project_key)
    end)

    it("does not modify pinned profiles", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "Debug" } },
            },
            nil,
            {
                profiles = {
                    ["App/Debug"] = {
                        configuration_set = nil,  -- pinned
                        configurations = { "App/Debug" },
                    },
                },
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App",
                        config_key = "Debug",
                        type = "cmake",
                        variant = "Debug",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- Pinned profile should be unchanged
        assert.is_not_nil(ws.cache.profiles["App/Debug"])
        assert.is_nil(ws.cache.profiles["App/Debug"].tool_key)
    end)

    it("skips profiles whose config set has no keyed-module mapping", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = {
                    -- Debug has cmake mapping, Release does not
                    Debug = { Frontend = "debug", App = "Debug" },
                    Release = { Frontend = "release" },
                },
            },
            { active_profile = "Release" },
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
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                    ["Frontend/release"] = {
                        project_key = "Frontend",
                        config_key = "release",
                        type = "ets",
                        variant = "release",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- Debug should be upgraded (has cmake mapping)
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])

        -- Release should NOT be upgraded (no cmake mapping)
        assert.is_not_nil(ws.cache.profiles["Release"])
        assert.is_nil(ws.cache.profiles["Release:ninja-gcc-12"])
        assert.is_nil(ws.cache.profiles["Release"].tool_key)

        -- active_profile should NOT change (Release was not upgraded)
        assert.equals("Release", ws.user.active_profile)
    end)

    it("handles empty profiles gracefully", function()
        local ws = make_ws(
            {
                projects = { Frontend = { ets = {} } },
                configuration_sets = { Debug = { Frontend = "debug" } },
            },
            nil,
            { configurations = {} }
        )

        -- No profiles at all - should be a no-op
        ws:upgrade_profiles_for_tool(tool_entry)
        assert.is_nil(ws.cache.profiles)
    end)

    it("migrates active_profile only when it matches renamed profile", function()
        local ws = make_ws(
            {
                projects = {
                    Frontend = { ets = {} },
                    App = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { Frontend = "debug", App = "Debug" },
                    Release = { Frontend = "release", App = "Release" },
                },
            },
            { active_profile = "Release" },
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
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                    ["Frontend/release"] = {
                        project_key = "Frontend",
                        config_key = "release",
                        type = "ets",
                        variant = "release",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- active_profile should match Release (which was active)
        assert.equals("Release:ninja-gcc-12", ws.user.active_profile)
    end)

    it("handles mixed no-tool and keyed profiles", function()
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
                    -- A no-tool profile that needs upgrading
                    Debug = {
                        configuration_set = "Debug",
                        configurations = { "Frontend/debug" },
                    },
                    -- A keyed profile that just needs extending
                    ["Debug:ninja-msvc-17"] = {
                        configuration_set = "Debug",
                        tool_key = "ninja-msvc-17",
                        tool_data = { id = "ninja-msvc-17" },
                        tool_label = "Ninja - MSVC 17",
                        tool_mod_type = "cmake",
                        configurations = { "Frontend/debug", "App/Debug:ninja-msvc-17" },
                    },
                },
                configurations = {
                    ["Frontend/debug"] = {
                        project_key = "Frontend",
                        config_key = "debug",
                        type = "ets",
                        variant = "debug",
                    },
                    ["App/Debug:ninja-msvc-17"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-msvc-17",
                        type = "cmake",
                        variant = "Debug",
                        tool_key = "ninja-msvc-17",
                    },
                },
            }
        )

        ws:upgrade_profiles_for_tool(tool_entry)

        -- No-tool profile upgraded
        assert.is_nil(ws.cache.profiles["Debug"])
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])

        -- Keyed profile extended (not renamed)
        assert.is_not_nil(ws.cache.profiles["Debug:ninja-msvc-17"])
        -- Its configurations should still use its own tool key
        local p_msvc = ws.cache.profiles["Debug:ninja-msvc-17"]
        local cks = {}
        for _, ck in ipairs(p_msvc.configurations) do cks[ck] = true end
        assert.is_true(cks["App/Debug:ninja-msvc-17"])
    end)
end)

describe("add_project (simplified)", function()
    it("adds project without set_mappings", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { Debug = { Frontend = "debug" } },
        })

        local ok, err = ws:add_project("App", "cmake")
        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_not_nil(ws.config.projects.App)
        assert.equals("cmake", ws.config.projects.App.type)
    end)

    it("does not modify configuration sets", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { Debug = { Frontend = "debug" } },
        })

        ws:add_project("App", "cmake")

        -- Config set should not have App
        assert.is_nil(ws.config.configuration_sets.Debug.App)
    end)

    it("rejects duplicate project keys", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })

        local ok, err = ws:add_project("App", "cmake")
        assert.is_false(ok)
        assert.matches("already exists", err)
    end)

    it("uses path when provided", function()
        local ws = make_ws({
            projects = { Frontend = { ets = {} } },
        })

        ws:add_project("MyLib", "cmake", "libs/MyLib")
        assert.equals("libs/MyLib", ws.config.projects.MyLib.path)
    end)
end)
