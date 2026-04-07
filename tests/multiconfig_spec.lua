--- Tests for multi-config cmake behavior.
---
--- Verifies that building a profile only creates cache entries for the
--- active configuration, not all available configurations. This is the
--- regression test for the bug where cmake tasks() generated build tasks
--- for Debug, Release, and RelWithDebInfo when only Debug was active.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cache_mod = require("loomworks.cache")

--- Create a Core with a cmake project that has multiple configurations.
--- The mock cmake module's tasks() simulates multi-config behavior.
--- @param opts? { multi_config?: boolean, configurations?: table }
--- @return loomworks.Core, table saved_results
local function make_multiconfig_core(opts)
    opts = opts or {}
    local multi_config = opts.multi_config ~= false -- default true
    local configurations = opts.configurations or {
        Debug = { generator = "Ninja Multi-Config" },
        Release = { generator = "Ninja Multi-Config" },
        RelWithDebInfo = { generator = "Ninja Multi-Config" },
    }

    local saved_results = {}

    local mock_cmake = {
        validate = function() return { valid = true, warnings = {} } end,
        info = function()
            return { configurations = configurations }
        end,
        tasks = function(project, active_config)
            local tasks = {}
            local abs_path = project.workspace_root .. "/" .. project.path
            local configuration_key = project.configuration_key or active_config

            -- Configure task
            tasks[#tasks + 1] = {
                name = project.name .. ": configure",
                builder = function()
                    return { cmd = { "echo", "configure" }, cwd = abs_path }
                end,
                loomworks = {
                    project_key = project.name,
                    action = "configure",
                    configuration_key = configuration_key,
                    build_dir = "/build/" .. project.name,
                },
            }

            if multi_config then
                -- BUG SIMULATION: generate tasks for ALL configurations
                -- (this is what the old code did)
                for config_name in pairs(project.configurations or {}) do
                    local build_config_key = configuration_key
                    if config_name ~= active_config then
                        local kit_id = project.tool_key
                                or (project.tool and project.tool.key)
                        if kit_id then
                            build_config_key = config_name .. ":" .. kit_id
                        else
                            build_config_key = config_name
                        end
                    end

                    tasks[#tasks + 1] = {
                        name = project.name .. ": build " .. config_name,
                        builder = function()
                            return { cmd = { "echo", "build", config_name }, cwd = abs_path }
                        end,
                        loomworks = {
                            project_key = project.name,
                            action = "build",
                            configuration_key = build_config_key,
                            build_dir = "/build/" .. project.name,
                        },
                    }
                end
            else
                -- CORRECT: only build active config
                tasks[#tasks + 1] = {
                    name = project.name .. ": build " .. active_config,
                    builder = function()
                        return { cmd = { "echo", "build", active_config }, cwd = abs_path }
                    end,
                    loomworks = {
                        project_key = project.name,
                        action = "build",
                        configuration_key = configuration_key,
                        build_dir = "/build/" .. project.name,
                    },
                }
            end

            return tasks
        end,
        detect_tools = function()
            return {
                { tool_data = { generator = "Ninja Multi-Config", id = "ninja-clang" } },
            }
        end,
        tool_key = function(td) return td.id end,
        tool_label = function(td) return td.id end,
        tools_match = function(a, b)
            return a and b and a.id == b.id
        end,
    }

    local saved_cache = nil
    local core = Core.new(h.make_test_deps(
        {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    debug = { App = "Debug" },
                    release = { App = "Release" },
                },
            }),
            ["loomworks.user.json"] = h.make_user_json({ active_profile = "debug:ninja-clang" }),
        },
        {
            modules = { get = function(t) if t == "cmake" then return mock_cmake end return nil end },
            cache = {
                save = function(_, data) saved_cache = data; return true end,
            },
        }
    ))
    core:setup({ root = "/root" })

    return core, function() return saved_cache end
end

--- Count cache configurations (v7: build_dirs)
local function count_configs(cache_data)
    if not cache_data or not cache_data.build_dirs then return 0 end
    local count = 0
    for _ in pairs(cache_data.build_dirs) do count = count + 1 end
    return count
end

--- Get config keys from cache (v7: build_dirs)
local function config_keys(cache_data)
    local keys = {}
    if cache_data and cache_data.build_dirs then
        for k in pairs(cache_data.build_dirs) do
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

describe("multi-config cmake", function()

    describe("buggy tasks() generating all configs", function()
        pending("creates orphaned cache entries when tasks() generates all configs", function()
            local core, get_cache = make_multiconfig_core({ multi_config = true })

            -- Simulate building: record results for tasks that the buggy
            -- tasks() would generate (Debug, Release, RelWithDebInfo)
            core:record_task_result({
                project_key = "App",
                action = "configure",
                configuration_key = "Debug:ninja-clang",
                variant = "Debug",
                success = true,
                build_dir = "/build/App",
            })
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Debug:ninja-clang",
                variant = "Debug",
                success = true,
            })
            -- These are the UNWANTED results from buggy multi-config tasks()
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Release:ninja-clang",
                variant = "Release",
                success = true,
            })
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "RelWithDebInfo:ninja-clang",
                variant = "RelWithDebInfo",
                success = true,
            })

            local cache = get_cache()
            -- BUG: 3 config entries exist (Debug + Release + RelWithDebInfo)
            -- Only Debug should exist since that's the active profile's config
            local keys = config_keys(cache)
            assert.is_true(#keys > 1,
                "buggy multi-config should create multiple cache entries: " .. vim.inspect(keys))

            -- Check that Release and RelWithDebInfo are orphaned
            -- (not referenced by any profile)
            local orphans = core:get_orphaned_configs()
            assert.is_true(#orphans > 0,
                "buggy multi-config should create orphaned configs")
        end)
    end)

    describe("fixed tasks() generating only active config", function()
        it("creates only the active configuration in cache", function()
            local core, get_cache = make_multiconfig_core({ multi_config = false })

            -- Only the active config's tasks are generated
            core:record_task_result({
                project_key = "App",
                action = "configure",
                configuration_key = "Debug:ninja-clang",
                variant = "Debug",
                success = true,
                build_dir = "/build/App",
            })
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Debug:ninja-clang",
                variant = "Debug",
                success = true,
            })

            local cache = get_cache()
            -- Only the active config should have "built" state
            local built_keys = {}
            for k, cfg in pairs(cache.build_dirs) do
                if cfg.state == "built" then
                    built_keys[#built_keys + 1] = k
                end
            end
            assert.equals(1, #built_keys,
                "only active config should be built: " .. vim.inspect(built_keys))
            -- Key is build_dir-based, check it contains project and variant
            assert.truthy(built_keys[1]:match("App") and built_keys[1]:match("Debug"))
        end)
    end)

    describe("profile build with mixed project types", function()
        it("does not apply cmake tool suffix to typescript projects", function()
            local core = Core.new(h.make_test_deps(
                {
                    ["loomworks.json"] = h.make_config_json({
                        projects = {
                            App = { cmake = {} },
                            Frontend = { typescript = {} },
                        },
                        configuration_sets = {
                            debug = { App = "Debug", Frontend = "default" },
                        },
                    }),
                    ["loomworks.user.json"] = h.make_user_json({
                        active_profile = "debug",
                        profiles = {
                            debug = { configuration_set = "debug" },
                        },
                    }),
                }
            ))
            core:setup({ root = "/root" })

            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile, "profile should be materialized")

            local pps = profile:projects()
            for _, pp in ipairs(pps) do
                if pp._project and pp._project.key == "Frontend" then
                    -- TypeScript project should NOT have a tool suffix
                    -- variant_name() reads from mapping (no config_unit needed)
                    assert.equals("default", pp:variant_name(),
                        "typescript project should not have cmake tool suffix")
                end
            end
        end)

        it("does not create cache entries with wrong tool suffix for non-cmake projects", function()
            local saved_cache = nil
            local core = Core.new(h.make_test_deps(
                {
                    ["loomworks.json"] = h.make_config_json({
                        projects = {
                            App = { cmake = {} },
                            Frontend = { typescript = {} },
                        },
                        configuration_sets = {
                            debug = { App = "Debug", Frontend = "default" },
                        },
                    }),
                },
                {
                    cache = {
                        save = function(_, data) saved_cache = data; return true end,
                    },
                }
            ))
            core:setup({ root = "/root" })

            -- Simulate typescript build result
            core:record_task_result({
                project_key = "Frontend",
                action = "build",
                configuration_key = "default",
                variant = "default",
                success = true,
            })

            -- Cache entry should exist for Frontend/default without tool segment
            assert.is_not_nil(saved_cache)
            local found_frontend = false
            for key, entry in pairs(saved_cache.build_dirs) do
                if entry.project_key == "Frontend" then
                    found_frontend = true
                    -- Key should NOT contain a tool segment
                    assert.truthy(key:match("build/Frontend/default"),
                        "typescript cache entry should use bare build dir key, got: " .. key)
                end
            end
            assert.is_true(found_frontend, "should find a cache entry for Frontend")
        end)
    end)

    describe("clean and rebuild cycles", function()
        it("clean then rebuild does not create orphaned configs", function()
            local saved_cache = nil
            local core = Core.new(h.make_test_deps(
                {
                    ["loomworks.json"] = h.make_config_json({
                        projects = { App = { cmake = {} } },
                        configuration_sets = { debug = { App = "Debug" } },
                    }),
                    ["loomworks.user.json"] = h.make_user_json({ active_profile = "debug" }),
                },
                {
                    cache = {
                        save = function(_, data) saved_cache = data; return true end,
                    },
                }
            ))
            core:setup({ root = "/root" })

            -- Build
            core:record_task_result({
                project_key = "App",
                action = "configure",
                configuration_key = "Debug",
                variant = "Debug",
                success = true,
                build_dir = "/root/.nvim/build/App/Debug",
            })
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Debug",
                variant = "Debug",
                success = true,
            })

            -- Clean (reset state)
            core:reset_cached_configs({
                { project_key = "App", config_key = "Debug" },
            })

            -- Rebuild
            core:record_task_result({
                project_key = "App",
                action = "configure",
                configuration_key = "Debug",
                variant = "Debug",
                success = true,
                build_dir = "/root/.nvim/build/App/Debug",
            })
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Debug",
                variant = "Debug",
                success = true,
            })

            -- Should have exactly one built config entry
            local built_keys = {}
            for k, cfg in pairs(saved_cache.build_dirs) do
                if cfg.state == "built" or cfg.state == "configured" then
                    built_keys[#built_keys + 1] = k
                end
            end
            assert.equals(1, #built_keys,
                "rebuild should not create extra built configs: " .. vim.inspect(built_keys))
        end)

        it("switching profiles does not leave orphans from previous profile", function()
            local saved_cache = nil
            local core = Core.new(h.make_test_deps(
                {
                    ["loomworks.json"] = h.make_config_json({
                        projects = { App = { cmake = {} } },
                        configuration_sets = {
                            debug = { App = "Debug" },
                            release = { App = "Release" },
                        },
                    }),
                    ["loomworks.user.json"] = h.make_user_json({ active_profile = "debug" }),
                },
                {
                    cache = {
                        save = function(_, data) saved_cache = data; return true end,
                    },
                }
            ))
            core:setup({ root = "/root" })

            -- Build debug
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Debug",
                variant = "Debug",
                success = true,
            })

            -- Switch to release profile
            local ws = core:get_workspace()
            ws._active_profile_key = "release"
            core:remerge()

            -- Build release
            core:record_task_result({
                project_key = "App",
                action = "build",
                configuration_key = "Release",
                variant = "Release",
                success = true,
            })

            -- Both configs exist (Debug from before, Release from now)
            -- Debug is now an orphan (no profile references it since we switched)
            -- This is EXPECTED behavior — orphans from branch switching are allowed
            local keys = config_keys(saved_cache)
            assert.equals(2, #keys)
        end)
    end)
end)
