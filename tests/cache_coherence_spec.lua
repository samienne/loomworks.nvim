--- Cache coherence tests.
---
--- Integration-style tests that simulate real workflows:
--- configure, build, delete profiles (full and pinned),
--- and verify cache invariants after each operation.
---
--- Key invariant after user actions: every cached config in
--- configured/built/failed state is referenced by at least one profile.
--- Orphaned configs (unreferenced) ARE allowed to exist from branch switching
--- or cache loading — they show up in the "Orphaned Configurations" UI section.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local merge_mod = require("loomworks.merge")
local cache_mod = require("loomworks.cache")

--- Find a ConfigurationSet by name from a core's registry.
--- @param core loomworks.Core
--- @param name string
--- @return loomworks.ConfigurationSet
local function get_cs(core, name)
    return h.find_config_set_in(core:get_config_sets(), name)
end

--- Get or create a ConfigUnit by project_key and config_key.
--- Falls back to ensure_config_unit when the unit does not yet exist.
--- @param core loomworks.Core
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
local function get_unit(core, project_key, config_key)
    local ws = core._workspace
    local variant = config_key
    local tool_key_filter = nil
    local colon = config_key:find(":")
    if colon then
        variant = config_key:sub(1, colon - 1)
        tool_key_filter = config_key:sub(colon + 1)
    end
    -- Try property-based lookup first (match project_key + variant + tool_key)
    for _, unit in pairs(ws._config_units) do
        if unit._init_project_key == project_key and unit._variant == variant then
            if tool_key_filter == nil and unit._tool_key == nil then
                return unit
            elseif tool_key_filter and unit._tool_key == tool_key_filter then
                return unit
            end
        end
    end
    local project = h.find_project_in(core:get_projects(), project_key)
    assert(project, "project " .. project_key .. " not found in workspace")
    local tool = nil
    if colon then
        tool = ws:find_tool(project.type, tool_key_filter)
        if not tool then
            tool = ws:get_or_create_tool(project.type, tool_key_filter, {}, nil)
        end
    end
    local Configuration = require("loomworks.configuration")
    local cfg = project:get_configuration(variant)
    if not cfg then
        cfg = Configuration.new(project, variant, {})
        project._configurations[#project._configurations + 1] = cfg
    end
    return ws:ensure_config_unit(project, cfg, tool)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Assert strict cache coherence: every cached config with state
--- is referenced by at least one profile. No orphaned configs allowed.
--- Use this to verify user actions don't create new orphans.
local function assert_cache_coherent(core, msg)
    local ws = core:get_workspace()
    if not ws then return end

    local prefix = msg and (msg .. ": ") or ""
    local cache = ws:_serialize_cache()

    -- Build a set of all cache keys referenced by profiles via ProfileProjects
    local referenced = {}
    for _, profile in pairs(ws._profiles) do
        for _, pp in ipairs(profile:projects()) do
            if pp._config_unit then
                referenced[pp._config_unit.id] = true
            end
        end
    end

    -- Also allow orphaned configs (unreferenced from branch switching)
    -- For strict checks, use assert_no_orphans separately
    local orphans = core:get_orphaned_configs()
    local orphan_set = {}
    for _, o in ipairs(orphans) do
        -- Use the ConfigUnit id (build_dir key) for matching against cache keys
        if o.unit then
            orphan_set[o.unit.id] = true
        end
    end

    -- Check every cached config is either referenced or a known orphan
    if cache.build_dirs then
        for cache_key, cached_config in pairs(cache.build_dirs) do
            local state = cached_config.state
            if state and state ~= "unconfigured" then
                assert(referenced[cache_key] or orphan_set[cache_key],
                    prefix .. "orphaned config: " .. cache_key
                    .. " (state=" .. state .. ") not referenced by any profile")
            end
        end
    end
end

--- Assert that no orphaned configs exist. Use after user actions to verify
--- that actions don't accidentally create orphans.
local function assert_no_orphans(core, msg)
    local prefix = msg and (msg .. ": ") or ""
    local orphans = core:get_orphaned_configs()
    assert(#orphans == 0,
        prefix .. "expected no orphaned configs, found " .. #orphans)
end

--- Assert that the cache has no configs at all.
local function assert_cache_empty(core, msg)
    local ws = core:get_workspace()
    local prefix = msg and (msg .. ": ") or ""
    assert(ws, prefix .. "workspace should exist")

    local cache = ws:_serialize_cache()
    local has_configs = cache.build_dirs and next(cache.build_dirs)
    assert(not has_configs, prefix .. "cache should have no build_dirs")

    -- Profiles are runtime-only, not in cache
end

--- Count cached configs in the flat dict.
local function count_cached_configs(core)
    local ws = core:get_workspace()
    if not ws then return 0 end
    local cache = ws:_serialize_cache()
    if not cache.build_dirs then return 0 end
    local count = 0
    for _ in pairs(cache.build_dirs) do
        count = count + 1
    end
    return count
end

--- Look up a cached config by project_key and variant from serialized cache.
--- Returns the entry (or nil) from build_dirs.
--- @param cache table serialized cache
--- @param project_key string
--- @param variant string
--- @return table|nil entry
local function find_cached(cache, project_key, variant, tool_key)
    if not cache.build_dirs then return nil end
    for _, entry in pairs(cache.build_dirs) do
        if entry.project_key == project_key and entry.variant == variant then
            if tool_key then
                if entry.tool_key == tool_key then return entry end
            else
                return entry
            end
        end
    end
    return nil
end

--- Count profiles in workspace (runtime objects).
local function count_profiles(core)
    local ws = core:get_workspace()
    if not ws then return 0 end
    return #ws._profiles
end

--- Simulate a configure+build result for a config.
local function simulate_build(core, project_key, config_key, build_dir)
    local unit = get_unit(core, project_key, config_key)
    core:record_task_result({
        unit = unit,
        action = "configure",
        success = true,
        build_dir = build_dir,
    })
    core:record_task_result({
        unit = unit,
        action = "build",
        success = true,
        build_dir = build_dir,
    })
end

--- Build a tool_entry from core's _tools_by_type for a given tool_key.
--- @param core loomworks.Core
--- @param tool_key string
--- @return table|nil tool_entry
local function tool_entry_for(core, tool_key)
    for mod_type, tools in pairs(core._workspace._tools_by_type) do
        for _, tool in ipairs(tools) do
            if tool.tool_key == tool_key then
                return {
                    tool_key = tool.tool_key,
                    tool_data = tool.tool_data,
                    tool_label = tool.tool_label,
                    tool_mod_type = mod_type,
                }
            end
        end
    end
    return nil
end

--- Create a Core with tracked cache saves and rm_rf calls.
--- extra_opts.tools_by_type is extracted and injected after setup to
--- override module detection (which requires real modules).
local function make_tracked_core(config_overrides, user_overrides, cache_overrides, extra_opts)
    local rm_rf_calls = {}
    extra_opts = extra_opts or {}
    local injected_tools = extra_opts.tools_by_type
    extra_opts.tools_by_type = nil

    local opts = vim.tbl_deep_extend("force", {
        io = {
            rm_rf = function(path)
                rm_rf_calls[#rm_rf_calls + 1] = path
                return true
            end,
            rm_rf_async = function(path, cb)
                rm_rf_calls[#rm_rf_calls + 1] = path
                cb(true, nil)
            end,
        },
        cache = {
            save = function(root, data) return true end,
        },
    }, extra_opts)

    local files = {
        ["loomworks.json"] = h.make_config_json(config_overrides),
    }
    if user_overrides then
        files["loomworks.user.json"] = h.make_user_json(user_overrides)
    end
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end

    local deps = h.make_test_deps(files, opts)
    local core = Core.new(deps)

    --- Custom setup that injects tools_by_type before merge.
    --- @param setup_opts { root: string }
    local function setup(setup_opts)
        core:setup(setup_opts)
        if injected_tools then
            core._workspace._tools_by_type = injected_tools
            core:remerge()
        end
    end

    return core, rm_rf_calls, setup
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("cache coherence", function()

    describe("single project, single tool (typescript)", function()

        it("starts coherent with empty cache", function()
            local core = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })
            assert_cache_coherent(core, "after setup")
            assert_cache_empty(core, "fresh workspace")
        end)

        it("materialize_pinned + build creates coherent state", function()
            local core = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            get_unit(core, "App", "development"):materialize_pinned("development")
            assert_cache_coherent(core, "after materialize_pinned")
            assert.equals(1, count_profiles(core))

            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "after build")
        end)

        it("deleting sole pinned profile cleans config and build dir", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            get_unit(core, "App", "development"):materialize_pinned("development")
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert.equals(1, count_cached_configs(core))

            -- Delete via plan+execute (as UI would)
            local profile = h.find_profile(core:get_profiles(), "App/development")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            -- Config is unreferenced after removing sole profile
            assert.equals(1, #plan.items)

            local done = false
            core:execute_deletion(plan, { deactivate_profile = profile },
                function() done = true end)
            assert.is_true(done)

            assert_cache_empty(core, "after deleting sole profile")
            assert.equals(1, #rm_calls)
            assert.truthy(rm_calls[1]:match("build/App/development"))
        end)

        it("deleting one of two profiles keeps shared config", function()
            local core = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            -- Materialize a set-based profile
            get_cs(core, "debug"):activate()
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "after set-based profile build")

            -- Also create an pinned for the same config
            get_unit(core, "App", "development"):materialize_pinned("development")
            assert_cache_coherent(core, "after also creating pinned")
            local n_profiles = count_profiles(core)
            assert.is_true(n_profiles >= 2)

            -- Delete pinned — config should survive intact (set-based profile still references it)
            local adhoc = h.find_profile(core:get_profiles(), "App/development")
            assert.is_not_nil(adhoc)
            local plan = adhoc:plan_deletion()
            assert.equals(1, #plan.items)
            assert.equals("keep", plan.items[1].disposition)

            local done = false
            core:execute_deletion(plan, { deactivate_profile = adhoc },
                function() done = true end)
            assert.is_true(done)

            assert_cache_coherent(core, "after deleting pinned")
            assert.equals(1, count_cached_configs(core))
            -- Config entry exists with state preserved
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.equals("built", find_cached(cache, "App", "development").state)
        end)
    end)

    describe("single project, keyed tools (cmake)", function()

        it("two tool profiles, delete one, other keeps its config", function()
            local core, rm_calls, setup = make_tracked_core(
                {
                    projects = { Lib = { cmake = {} } },
                },
                nil, nil,
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                            { tool_key = "ninja-clang", tool_data = { id = "ninja-clang", generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
                        },
                    },
                }
            )
            setup({ root = "/root" })
            assert_cache_coherent(core, "after setup")

            -- Build with gcc
            get_unit(core, "Lib", "Debug:ninja-gcc"):materialize_pinned("Debug", { key = "ninja-gcc" })
            simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/ninja-gcc/Debug")
            assert_cache_coherent(core, "after gcc build")

            -- Build with clang
            get_unit(core, "Lib", "Debug:ninja-clang"):materialize_pinned("Debug", { key = "ninja-clang" })
            simulate_build(core, "Lib", "Debug:ninja-clang", "/root/.nvim/build/Lib/ninja-clang/Debug")
            assert_cache_coherent(core, "after clang build")
            assert.equals(2, count_cached_configs(core))

            -- Delete gcc profile
            local gcc_profile = h.find_profile(core:get_profiles(), "Lib/Debug:ninja-gcc")
            assert.is_not_nil(gcc_profile)
            local plan = gcc_profile:plan_deletion()
            assert.equals(1, #plan.items)

            local done = false
            core:execute_deletion(plan, { deactivate_profile = gcc_profile },
                function() done = true end)
            assert.is_true(done)

            assert_cache_coherent(core, "after deleting gcc profile")
            assert.equals(1, count_cached_configs(core))
            assert.equals(1, #rm_calls)
            assert.truthy(rm_calls[1]:match("ninja%-gcc"))

            -- Clang config should still be there
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(find_cached(cache, "Lib", "Debug", "ninja-clang"))
        end)

        it("delete all profiles leaves cache empty", function()
            local core, rm_calls, setup = make_tracked_core(
                {
                    projects = { Lib = { cmake = {} } },
                },
                nil, nil,
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        },
                    },
                }
            )
            setup({ root = "/root" })

            get_unit(core, "Lib", "Debug:ninja-gcc"):materialize_pinned("Debug", { key = "ninja-gcc" })
            simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/ninja-gcc/Debug")
            get_unit(core, "Lib", "Release:ninja-gcc"):materialize_pinned("Release", { key = "ninja-gcc" })
            simulate_build(core, "Lib", "Release:ninja-gcc", "/root/.nvim/build/Lib/ninja-gcc/Release")
            assert.equals(2, count_cached_configs(core))
            assert_cache_coherent(core, "after two builds")

            -- Delete first
            local p1 = h.find_profile(core:get_profiles(), "Lib/Debug:ninja-gcc")
            local plan1 = p1:plan_deletion()
            core:execute_deletion(plan1, { deactivate_profile = p1 })
            assert_cache_coherent(core, "after first delete")
            assert.equals(1, count_cached_configs(core))

            -- Delete second
            local p2 = h.find_profile(core:get_profiles(), "Lib/Release:ninja-gcc")
            local plan2 = p2:plan_deletion()
            core:execute_deletion(plan2, { deactivate_profile = p2 })

            assert_cache_empty(core, "after deleting all profiles")
            assert.equals(2, #rm_calls)
        end)
    end)

    describe("multi-project workspace", function()

        it("set-based profile build + delete cleans all project configs", function()
            local core, rm_calls, setup = make_tracked_core({
                projects = {
                    Backend = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    debug = { Backend = "Debug", Frontend = "development" },
                },
            }, nil, nil, {
                tools_by_type = {
                    cmake = {
                        { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                    },
                },
            })
            setup({ root = "/root" })

            -- Materialize the debug:ninja-gcc profile
            get_cs(core, "debug"):activate(tool_entry_for(core, "ninja-gcc"))
            simulate_build(core, "Backend", "Debug:ninja-gcc", "/root/.nvim/build/Backend/ninja-gcc/Debug")
            simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")
            assert_cache_coherent(core, "after full build")
            assert.equals(2, count_cached_configs(core))

            -- Delete the profile
            local profile = h.find_profile(core:get_profiles(), "debug:ninja-gcc")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(2, #plan.items) -- both configs unreferenced

            local done = false
            core:execute_deletion(plan, { deactivate_profile = profile },
                function() done = true end)
            assert.is_true(done)

            assert_cache_empty(core, "after deleting set-based profile")
            assert.equals(2, #rm_calls)
        end)

        it("mixed full + pinned profiles with shared configs", function()
            local core, rm_calls, setup = make_tracked_core({
                projects = {
                    Backend = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    debug = { Backend = "Debug", Frontend = "development" },
                },
            }, nil, nil, {
                tools_by_type = {
                    cmake = {
                        { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                    },
                },
            })
            setup({ root = "/root" })

            -- Full profile build
            get_cs(core, "debug"):activate(tool_entry_for(core, "ninja-gcc"))
            simulate_build(core, "Backend", "Debug:ninja-gcc", "/root/.nvim/build/Backend/ninja-gcc/Debug")
            simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")

            -- Pinned: build Backend with same config (overlapping reference)
            get_unit(core, "Backend", "Debug:ninja-gcc"):materialize_pinned("Debug", { key = "ninja-gcc" })
            assert_cache_coherent(core, "after pinned overlapping")

            -- Delete pinned — config shared by set-based profile, kept intact
            local adhoc = h.find_profile(core:get_profiles(), "Backend/Debug:ninja-gcc")
            assert.is_not_nil(adhoc)
            local plan = adhoc:plan_deletion()
            assert.equals(1, #plan.items)
            assert.equals("keep", plan.items[1].disposition)
            core:execute_deletion(plan, { deactivate_profile = adhoc })
            assert_cache_coherent(core, "after pinned delete")
            assert.equals(2, count_cached_configs(core))
            assert.equals(0, #rm_calls) -- "keep" does not touch build dir

            -- Now delete set-based profile — both configs should be cleaned
            local full = h.find_profile(core:get_profiles(), "debug:ninja-gcc")
            assert.is_not_nil(full)
            local plan2 = full:plan_deletion()
            assert.equals(2, #plan2.items)
            core:execute_deletion(plan2, { deactivate_profile = full })

            assert_cache_empty(core, "after set-based profile delete")
            assert.equals(2, #rm_calls)
        end)
    end)

    describe("delete_config from Projects section", function()

        it("resets config but keeps pinned profile when no set-based profile refs", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            get_unit(core, "App", "development"):materialize_pinned("development")
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "after build")

            local done = false
            get_unit(core, "App", "development"):delete(function() done = true end)
            assert.is_true(done)

            assert_cache_coherent(core, "after delete_config")
            assert.equals(1, #rm_calls)

            -- Config reset but pinned profile stays
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "App/development"))
            assert.is_nil(find_cached(cache, "App", "development").state)
        end)

        it("keeps config when set-based profile references it", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            -- Full profile + pinned both reference the config
            get_cs(core, "debug"):activate()
            get_unit(core, "App", "development"):materialize_pinned("development")
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "after build")

            -- delete_config resets config (both profiles still ref it)
            local done = false
            get_unit(core, "App", "development"):delete(function() done = true end)
            assert.is_true(done)

            assert_cache_coherent(core, "after delete_config with full ref")
            assert.equals(1, count_cached_configs(core))
            assert.equals(1, #rm_calls) -- build dir cleaned on reset

            -- Config entry exists but state cleared to unconfigured
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_nil(find_cached(cache, "App", "development").state)

            -- Both profiles still intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug"))
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "App/development"))
        end)

        it("keyed tool: deletes specific tool config, keeps other tools", function()
            local core, rm_calls, setup = make_tracked_core({
                projects = { Lib = { cmake = {} } },
            }, nil, nil, {
                tools_by_type = {
                    cmake = {
                        { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        { tool_key = "ninja-clang", tool_data = { id = "ninja-clang", generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
                    },
                },
            })
            setup({ root = "/root" })

            get_unit(core, "Lib", "Debug:ninja-gcc"):materialize_pinned("Debug", { key = "ninja-gcc" })
            simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/ninja-gcc/Debug")
            get_unit(core, "Lib", "Debug:ninja-clang"):materialize_pinned("Debug", { key = "ninja-clang" })
            simulate_build(core, "Lib", "Debug:ninja-clang", "/root/.nvim/build/Lib/ninja-clang/Debug")
            assert.equals(2, count_cached_configs(core))

            get_unit(core, "Lib", "Debug:ninja-gcc"):delete()
            assert_cache_coherent(core, "after delete one tool config")
            -- Both configs still exist (gcc was reset, clang is built)
            assert.equals(2, count_cached_configs(core))
            assert.equals(1, #rm_calls)

            -- GCC config reset, clang config still built
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_nil(find_cached(cache, "Lib", "Debug", "ninja-gcc").state)
            assert.is_not_nil(find_cached(cache, "Lib", "Debug", "ninja-clang"))
            assert.equals("built", find_cached(cache, "Lib", "Debug", "ninja-clang").state)

            -- Both pinned profiles still intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "Lib/Debug:ninja-gcc"))
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "Lib/Debug:ninja-clang"))
        end)
    end)

    describe("init with orphaned configs", function()

        it("preserves orphaned built config without creating profile", function()
            local core = make_tracked_core(
                { projects = { App = { typescript = {} } } },
                nil,
                {
                    -- Built config with no profile referencing it
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

            -- Should remain as orphan, no profile created
            assert_cache_coherent(core, "after init with orphan")
            assert.equals(0, count_profiles(core))
            assert.equals(1, count_cached_configs(core))

            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("App", orphans[1].project_key)
            assert.equals("development", orphans[1].config_key)
        end)

        it("drops unconfigured skeleton on init", function()
            local core = make_tracked_core(
                { projects = { App = { typescript = {} } } },
                nil,
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            -- no state
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert_cache_empty(core, "skeleton should be dropped")
        end)

        it("configs referenced by profile are not orphaned", function()
            local core = make_tracked_core(
                { projects = { App = { typescript = {} } } },
                {
                    pinned_profiles = {
                        ["App/development"] = { mappings = { App = "development" } },
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
            assert_cache_coherent(core, "after init")
            -- Should have exactly 1 profile (the pinned one)
            assert.equals(1, count_profiles(core))
        end)

        it("failed_configure config stays as orphan", function()
            local core = make_tracked_core(
                { projects = { App = { typescript = {} } } },
                nil,
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "failed_configure",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert_cache_coherent(core, "failed_configure as orphan")
            assert.equals(0, count_profiles(core))

            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("failed_configure", orphans[1].unit.state_value)
        end)

        it("keyed-tool config without profile stays as orphan", function()
            local core, _, setup = make_tracked_core(
                { projects = { Lib = { cmake = {} } } },
                nil,
                {
                    configurations = {
                        ["Lib/Debug:ninja-gcc"] = {
                            project_key = "Lib",
                            config_key = "Debug:ninja-gcc", variant = "Debug",
                            type = "cmake",
                            state = "built",
                            variant = "Debug",
                            tool_key = "ninja-gcc",
                            build_dir = "/root/.nvim/build/Lib/Debug",
                        },
                    },
                },
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        },
                    },
                }
            )
            setup({ root = "/root" })
            assert_cache_coherent(core, "keyed tool as orphan")

            -- No profile created, config remains as orphan
            assert.equals(0, count_profiles(core))
            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("Lib", orphans[1].project_key)
            assert.equals("Debug:ninja-gcc", orphans[1].config_key)
        end)
    end)

    describe("init with pre-populated cache", function()

        it("set-based profile with matching configs stays intact", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                { active_profile = "debug" },
                {
                    build_dirs = {
                        ["build/App/development"] = {
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

            assert_cache_coherent(core, "pre-populated set-based profile")
            assert.equals(1, count_profiles(core))
            assert.equals(1, count_cached_configs(core))

            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            -- Profile exists as runtime object, not in cache
            assert.is_not_nil(h.find_profile(ws._profiles, "debug"))
            assert.equals("built", find_cached(cache, "App", "development").state)
        end)

        it("multiple set-based profiles sharing same config stays coherent", function()
            -- Two profiles referencing the same config (different sets mapping to same variant)
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        staging = { App = "development" },
                    },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                        staging = {
                            configuration_set = "staging",
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

            assert_cache_coherent(core, "two profiles sharing config")
            assert.equals(2, count_profiles(core))
            assert.equals(1, count_cached_configs(core))
        end)

        it("set-based profile + pinned both referencing same config", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    pinned_profiles = {
                        ["App/development"] = { mappings = { App = "development" } },
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            assert_cache_coherent(core, "full + pinned overlap")
            assert.equals(2, count_profiles(core))
            assert.equals(1, count_cached_configs(core))
        end)

        it("profile referencing config that was removed from loomworks.json", function()
            -- Config set references project "App", but loomworks.json no longer has it
            local core, rm_calls = make_tracked_core(
                {
                    projects = { Other = { typescript = {} } }, -- App removed from config
                },
                nil,
                {
                    profiles = {
                        ["App/development"] = {
                            mappings = { App = "development" },
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

            -- The profile still references the config, so it's coherent
            -- (orphaned project in cache is fine as long as profile references it)
            assert_cache_coherent(core, "profile refs removed project")
        end)

        it("multi-project cache with mixed states all referenced", function()
            local core = make_tracked_core(
                {
                    projects = {
                        Backend = { cmake = {} },
                        Frontend = { typescript = {} },
                        Docs = { typescript = {} },
                    },
                    configuration_sets = {
                        debug = { Backend = "Debug", Frontend = "development", Docs = "development" },
                    },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = {
                                "Backend/Debug",
                                "Frontend/development",
                                "Docs/development",
                            },
                        },
                    },
                    configurations = {
                        ["Backend/Debug"] = {
                            project_key = "Backend",
                            config_key = "Debug",
                            variant = "Debug",
                            type = "cmake",
                            state = "configured",
                            build_dir = "/root/.nvim/build/Backend/Debug",
                        },
                        ["Frontend/development"] = {
                            project_key = "Frontend",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/Frontend/dev",
                        },
                        ["Docs/development"] = {
                            project_key = "Docs",
                            config_key = "development",
                            variant = "development",
                            type = "typescript",
                            state = "failed_build",
                            build_dir = "/root/.nvim/build/Docs/dev",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            assert_cache_coherent(core, "multi-project mixed states")
            assert.equals(1, count_profiles(core))
            assert.equals(3, count_cached_configs(core))
        end)

        it("cache without profile section loads fine (profiles are runtime only)", function()
            -- Profiles are no longer stored in cache, so cache inconsistency
            -- from stale profile references can't happen.
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                },
                nil,
                {
                    build_dirs = {
                        ["build/App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/production",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert.equals("initialized", core:state())
        end)

        it("multiple pinned profiles for same project different configs", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                },
                {
                    pinned_profiles = {
                        ["App/development"] = { mappings = { App = "development" } },
                        ["App/production"] = { mappings = { App = "production" } },
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                        ["build/App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "configured",
                            build_dir = "/root/.nvim/build/App/production",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            assert_cache_coherent(core, "multiple pinned same project")
            assert.equals(2, count_profiles(core))
            assert.equals(2, count_cached_configs(core))
        end)

        it("keyed tool profiles with multiple tools pre-cached", function()
            local core, _, setup = make_tracked_core(
                {
                    projects = { Lib = { cmake = {} } },
                    configuration_sets = { debug = { Lib = "Debug" } },
                },
                nil,
                {
                    profiles = {
                        ["debug:ninja-gcc"] = {
                            configuration_set = "debug",
                            tools = {
                                cmake = {
                                    key = "ninja-gcc",
                                    data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" },
                                    label = "Ninja GCC",
                                },
                            },
                            configurations = { "build/Lib/ninja-gcc/Debug" },
                        },
                        ["debug:ninja-clang"] = {
                            configuration_set = "debug",
                            tools = {
                                cmake = {
                                    key = "ninja-clang",
                                    data = { id = "ninja-clang", generator = "Ninja", compiler_id = "clang" },
                                    label = "Ninja Clang",
                                },
                            },
                            configurations = { "build/Lib/ninja-clang/Debug" },
                        },
                    },
                    build_dirs = {
                        ["build/Lib/ninja-gcc/Debug"] = {
                            project_key = "Lib",
                            config_key = "Debug:ninja-gcc", variant = "Debug",
                            type = "cmake",
                            state = "built",
                            tool_key = "ninja-gcc",
                            tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" },
                            build_dir = "/root/.nvim/build/Lib/ninja-gcc/Debug",
                        },
                        ["build/Lib/ninja-clang/Debug"] = {
                            project_key = "Lib",
                            config_key = "Debug:ninja-clang", variant = "Debug",
                            type = "cmake",
                            state = "configured",
                            tool_key = "ninja-clang",
                            tool_data = { id = "ninja-clang", generator = "Ninja", compiler_id = "clang" },
                            build_dir = "/root/.nvim/build/Lib/ninja-clang/Debug",
                        },
                    },
                },
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                            { tool_key = "ninja-clang", tool_data = { id = "ninja-clang", generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
                        },
                    },
                }
            )
            setup({ root = "/root" })

            assert_cache_coherent(core, "keyed tool profiles pre-cached")
            assert.equals(2, count_cached_configs(core))

            -- Both profiles should exist (cached + auto-generated overlap is fine)
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug:ninja-gcc"))
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug:ninja-clang"))
        end)

        it("init then delete all profiles leaves cache clean", function()
            local core, rm_calls = make_tracked_core(
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert_cache_coherent(core, "before delete")

            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            core:execute_deletion(plan, { deactivate_profile = profile })

            assert_cache_empty(core, "after deleting pre-populated profile")
            assert.equals(1, #rm_calls)
        end)

        it("init with orphans + existing profiles, delete existing, orphans survive", function()
            local core, rm_calls = make_tracked_core(
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/production",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- "production" is orphaned (no profile references it)
            assert_cache_coherent(core, "after init with orphan")
            assert.equals(1, count_profiles(core))
            assert.equals(2, count_cached_configs(core))

            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("production", orphans[1].config_key)

            -- Delete the set-based profile — only "development" gets cleaned
            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            assert.is_not_nil(plan.items[1].unit)
            assert.equals("development", plan.items[1].unit:config_key())

            core:execute_deletion(plan, { deactivate_profile = profile })
            assert_cache_coherent(core, "after delete, orphan survives")
            -- Set-based profiles persist (runtime-derived), so count stays at 1
            assert.equals(1, count_profiles(core))
            assert.equals(1, count_cached_configs(core))
            assert.equals(1, #rm_calls)

            -- The orphaned production config should still exist (not auto-deleted)
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(find_cached(cache, "App", "production"))

            -- And it's still an orphan
            orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
            assert.equals("production", orphans[1].config_key)
        end)

        it("init with cache referencing tools no longer detected", function()
            -- Cache has build_dir entries with a tool that detection no longer returns.
            -- With the new model, profiles are derived from config_sets x detected tools.
            -- The old tool's build entry becomes orphaned (no profile references it).
            local core, _, setup = make_tracked_core(
                {
                    projects = { Lib = { cmake = {} } },
                    configuration_sets = { debug = { Lib = "Debug" } },
                },
                nil,
                {
                    build_dirs = {
                        ["build/Lib/old-compiler/Debug"] = {
                            project_key = "Lib",
                            config_key = "Debug:ninja-old-compiler", variant = "Debug",
                            type = "cmake",
                            state = "built",
                            tool_key = "ninja-old-compiler",
                            tool_data = { generator = "Ninja", compiler_id = "old-compiler" },
                            build_dir = "/root/.nvim/build/Lib/old-compiler/Debug",
                        },
                    },
                },
                {
                    -- Current detection only finds gcc — the old compiler is gone
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        },
                    },
                }
            )
            setup({ root = "/root" })

            -- Profile "debug:ninja-gcc" is derived from detected tools
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug:ninja-gcc"))
            -- Old build entry is orphaned (no profile for the old tool)
            assert.equals(1, count_cached_configs(core))
            local orphans = core:get_orphaned_configs()
            assert.equals(1, #orphans)
        end)
    end)

    describe("sequential workflow", function()

        it("build -> delete -> rebuild -> delete leaves cache clean", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            -- First build
            get_unit(core, "App", "development"):materialize_pinned("development")
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "first build")

            -- Delete
            local p1 = h.find_profile(core:get_profiles(), "App/development")
            local plan1 = p1:plan_deletion()
            core:execute_deletion(plan1, { deactivate_profile = p1 })
            assert_cache_empty(core, "first delete")

            -- Rebuild (materialize_pinned creates a new pinned)
            get_unit(core, "App", "development"):materialize_pinned("development")
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "rebuild")

            -- Delete again
            local p2 = h.find_profile(core:get_profiles(), "App/development")
            local plan2 = p2:plan_deletion()
            core:execute_deletion(plan2, { deactivate_profile = p2 })
            assert_cache_empty(core, "second delete")
            assert.equals(2, #rm_calls)
        end)

        it("set-based profile configure -> failed build -> delete cleans up", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            get_cs(core, "debug"):activate()

            -- Configure succeeds
            local unit = get_unit(core, "App", "development")
            core:record_task_result({
                unit = unit,
                action = "configure",
                success = true,
                build_dir = "/root/.nvim/build/App/development",
            })
            assert_cache_coherent(core, "after configure")

            -- Build fails
            core:record_task_result({
                unit = unit,
                action = "build",
                success = false,
            })
            assert_cache_coherent(core, "after failed build")

            -- Delete profile
            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            core:execute_deletion(plan, { deactivate_profile = profile })

            assert_cache_empty(core, "after deleting failed build profile")
            assert.equals(1, #rm_calls)
        end)

        it("materialize_pinned is idempotent", function()
            local core = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            local key1 = get_unit(core, "App", "development"):materialize_pinned("development")
            local key2 = get_unit(core, "App", "development"):materialize_pinned("development")
            assert.equals(key1, key2)
            assert.equals(1, count_profiles(core))
            assert_cache_coherent(core, "idempotent materialize")
        end)
    end)

    describe("shared config GC handoff", function()

        it("two set-based profiles sharing config, delete both sequentially", function()
            local core, rm_calls = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        staging = { App = "development" },
                    },
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert_cache_coherent(core, "initial")
            assert.equals(2, count_profiles(core))

            -- Both set-based profiles share the same config.
            -- plan_deletion for either profile always shows "keep" because
            -- the other set-based profile (which is runtime-derived and
            -- cannot be removed) also references the config.
            local p1 = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(p1)
            local plan1 = p1:plan_deletion()
            assert.equals(1, #plan1.items)
            assert.equals("keep", plan1.items[1].disposition)

            local p2 = h.find_profile(core:get_profiles(), "staging")
            assert.is_not_nil(p2)
            local plan2 = p2:plan_deletion()
            assert.equals(1, #plan2.items)
            assert.equals("keep", plan2.items[1].disposition)

            -- To actually clean shared configs between set-based profiles,
            -- delete the config sets. After removing "debug" config set,
            -- its derived profile disappears. Now only "staging" refs the config.
            local ws = core:get_workspace()
            local cs_debug = h.find_config_set_in(ws:get_config_sets(), "debug")
            ws:remove_configuration_set(cs_debug)
            assert.equals(1, count_profiles(core))

            -- Now staging's plan_deletion shows "clean" (sole reference)
            p2 = h.find_profile(core:get_profiles(), "staging")
            assert.is_not_nil(p2)
            local plan3 = p2:plan_deletion()
            assert.equals(1, #plan3.items)
            assert.equals("clean", plan3.items[1].disposition)

            -- Remove staging config set — its derived profile also disappears
            local cs_staging = h.find_config_set_in(ws:get_config_sets(), "staging")
            ws:remove_configuration_set(cs_staging)
            assert.equals(0, count_profiles(core))

            -- Config becomes orphaned, can be cleaned via orphan cleanup
            local orphans = ws:get_orphaned_configs()
            assert.equals(1, #orphans)
        end)

        it("three-way sharing: A->XY, B->YZ, C->Z — delete B keeps Y (A) and Z (C)", function()
            -- Profile A refs configs X,Y; Profile B refs Y,Z; Profile C refs Z
            -- All set-based: plan_deletion always shows "keep" for shared configs.
            -- Removing config sets eliminates derived profiles, making configs
            -- orphaned and cleanable.
            local core, _ = make_tracked_core(
                {
                    projects = {
                        P1 = { typescript = {} },
                        P2 = { typescript = {} },
                        P3 = { typescript = {} },
                    },
                    configuration_sets = {
                        setA = { P1 = "dev", P2 = "dev" },
                        setB = { P2 = "dev", P3 = "dev" },
                        setC = { P3 = "dev" },
                    },
                },
                nil,
                {
                    configurations = {
                        ["P1/dev"] = {
                            project_key = "P1",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/P1/dev",
                        },
                        ["P2/dev"] = {
                            project_key = "P2",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/P2/dev",
                        },
                        ["P3/dev"] = {
                            project_key = "P3",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/P3/dev",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })
            assert_cache_coherent(core, "initial 3-way")
            assert.equals(3, count_profiles(core))
            assert.equals(3, count_cached_configs(core))

            local ws = core:get_workspace()

            -- All profiles are set-based: plan_deletion for B shows "keep"
            -- because A and C also reference the same configs
            local pB = h.find_profile(core:get_profiles(), "setB")
            assert.is_not_nil(pB)
            local planB = pB:plan_deletion()
            assert.equals(2, #planB.items)
            for _, item in ipairs(planB.items) do
                assert.equals("keep", item.disposition)
            end

            -- Delete config set B — derived profile B disappears
            local csB = h.find_config_set_in(ws:get_config_sets(), "setB")
            ws:remove_configuration_set(csB)
            assert.equals(2, count_profiles(core))

            -- P2/dev still held by A, P3/dev still held by C — all configs remain
            assert.equals(3, count_cached_configs(core))

            -- Delete config set A — derived profile A disappears
            -- P1/dev becomes orphaned, P2/dev becomes orphaned
            local csA = h.find_config_set_in(ws:get_config_sets(), "setA")
            ws:remove_configuration_set(csA)
            assert.equals(1, count_profiles(core))

            -- P3/dev still held by C; P1 and P2 are orphaned
            local orphans = ws:get_orphaned_configs()
            assert.equals(2, #orphans)

            -- Delete config set C — last derived profile disappears
            local csC = h.find_config_set_in(ws:get_config_sets(), "setC")
            ws:remove_configuration_set(csC)
            assert.equals(0, count_profiles(core))

            -- All three configs are now orphaned
            orphans = ws:get_orphaned_configs()
            assert.equals(3, #orphans)
        end)
    end)

    describe("skeleton and unmaterialized profiles", function()

        it("delete profile that was materialized but never built", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            get_cs(core, "debug"):activate()
            assert_cache_coherent(core, "after materialize")
            assert.equals(1, count_profiles(core))
            assert.equals(1, count_cached_configs(core))

            -- Config is a skeleton (no state, but build_dir is always set in v7)
            local ws = core:get_workspace()
            local cached = find_cached(ws:_serialize_cache(), "App", "development")
            assert.is_nil(cached.state)
            assert.is_not_nil(cached.build_dir)

            -- Delete — skeleton cleanup; in v7 skeletons have build_dir
            local profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            core:execute_deletion(plan, { deactivate_profile = profile })

            assert_cache_empty(core, "after deleting unbuild profile")
            -- In v7, skeletons have a build_dir so deletion attempts cleanup
            assert.equals(1, #rm_calls)
        end)

        it("pinned materialized but never built, then deleted", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
            })
            core:setup({ root = "/root" })

            get_unit(core, "App", "production"):materialize_pinned("production")
            assert_cache_coherent(core, "after materialize_pinned")
            assert.equals(1, count_profiles(core))

            local profile = h.find_profile(core:get_profiles(), "App/production")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            core:execute_deletion(plan, { deactivate_profile = profile })

            assert_cache_empty(core, "after deleting unbuilt pinned")
            -- In v7, skeletons have a build_dir so deletion attempts cleanup
            assert.equals(1, #rm_calls)
        end)
    end)

    describe("active profile deactivation", function()

        it("deleting active profile clears active_profile in user data", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                { active_profile = "debug" },
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
                            build_dir = "/root/.nvim/build/App/dev",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            local ws = core:get_workspace()
            assert.equals("debug", ws._active_profile_key)

            local profile = h.find_profile(core:get_profiles(), "debug")
            local plan = profile:plan_deletion()
            core:execute_deletion(plan, { deactivate_profile = profile })

            assert.is_nil(ws._active_profile_key)
            assert_cache_empty(core, "after active profile deleted")
        end)

        it("deleting non-active profile does not clear active_profile", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        release = { App = "production" },
                    },
                },
                { active_profile = "debug" },
                {
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
                            build_dir = "/root/.nvim/build/App/dev",
                        },
                        ["App/production"] = {
                            project_key = "App",
                            config_key = "production",
                            variant = "production",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/App/prod",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            local ws = core:get_workspace()
            assert.equals("debug", ws._active_profile_key)

            -- Delete release (not active)
            local release = h.find_profile(core:get_profiles(), "release")
            local plan = release:plan_deletion()
            core:execute_deletion(plan, { deactivate_profile = release })

            assert.equals("debug", ws._active_profile_key)
            assert_cache_coherent(core, "active profile untouched")
            assert.equals(1, count_cached_configs(core))
        end)
    end)

    describe("re-materialize after deletion", function()

        it("set-based profile can be re-materialized and rebuilt after deletion", function()
            local core, rm_calls = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            -- First cycle: materialize, build, delete
            get_cs(core, "debug"):activate()
            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "first build")

            local p1 = h.find_profile(core:get_profiles(), "debug")
            local plan1 = p1:plan_deletion()
            core:execute_deletion(plan1, { deactivate_profile = p1 })
            assert_cache_empty(core, "after first delete")

            -- Second cycle: re-materialize the same profile
            get_cs(core, "debug"):activate()
            assert_cache_coherent(core, "after re-materialize")
            assert.equals(1, count_profiles(core))
            assert.equals(1, count_cached_configs(core))

            simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
            assert_cache_coherent(core, "after rebuild")

            -- Can delete again cleanly
            local p2 = h.find_profile(core:get_profiles(), "debug")
            local plan2 = p2:plan_deletion()
            assert.equals(1, #plan2.items)
            core:execute_deletion(plan2, { deactivate_profile = p2 })
            assert_cache_empty(core, "after second delete")
            assert.equals(2, #rm_calls)
        end)
    end)

    describe("disposition: keep vs clean", function()

        it("keep leaves config completely untouched", function()
            -- Two set-based profiles share same config. Delete one -> keep.
            -- Verify config entry survives with all fields intact.
            local core, rm_calls, setup = make_tracked_core(
                {
                    projects = { Lib = { cmake = {} } },
                    configuration_sets = {
                        debug = { Lib = "Debug" },
                        staging = { Lib = "Debug" },
                    },
                },
                nil,
                {
                    profiles = {
                        ["debug:ninja-gcc"] = {
                            configuration_set = "debug",
                            tools = {
                                cmake = {
                                    key = "ninja-gcc",
                                    data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" },
                                    label = "Ninja GCC",
                                },
                            },
                            configurations = { "Lib/Debug:ninja-gcc" },
                        },
                        ["staging:ninja-gcc"] = {
                            configuration_set = "staging",
                            tools = {
                                cmake = {
                                    key = "ninja-gcc",
                                    data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" },
                                    label = "Ninja GCC",
                                },
                            },
                            configurations = { "Lib/Debug:ninja-gcc" },
                        },
                    },
                    configurations = {
                        ["Lib/Debug:ninja-gcc"] = {
                            project_key = "Lib",
                            config_key = "Debug:ninja-gcc", variant = "Debug",
                            type = "cmake",
                            state = "built",
                            variant = "Debug",
                            tool_key = "ninja-gcc",
                            tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" },
                            build_dir = "/root/.nvim/build/Lib/ninja-gcc/Debug",
                            last_configured = "2026-03-01",
                            last_built = "2026-03-01",
                            cmake = { compile_commands = "/root/.nvim/build/Lib/ninja-gcc/Debug/compile_commands.json" },
                        },
                    },
                },
                {
                    tools_by_type = {
                        cmake = {
                            { tool_key = "ninja-gcc", tool_data = { id = "ninja-gcc", generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
                        },
                    },
                }
            )
            setup({ root = "/root" })
            assert_cache_coherent(core, "initial")

            -- Delete debug profile — config shared with staging -> keep
            local profile = h.find_profile(core:get_profiles(), "debug:ninja-gcc")
            assert.is_not_nil(profile)
            local plan = profile:plan_deletion()
            assert.equals(1, #plan.items)
            assert.equals("keep", plan.items[1].disposition)

            core:execute_deletion(plan, { deactivate_profile = profile })
            assert_cache_coherent(core, "after keep")

            -- Config entry still exists with all fields intact
            local ws = core:get_workspace()
            local cached = find_cached(ws:_serialize_cache(), "Lib", "Debug", "ninja-gcc")
            assert.is_not_nil(cached, "config entry should still exist after keep")

            -- All fields preserved
            assert.equals("built", cached.state)
            assert.equals("/root/.nvim/build/Lib/ninja-gcc/Debug", cached.build_dir)
            assert.equals("2026-03-01", cached.last_configured)
            assert.equals("2026-03-01", cached.last_built)
            assert.is_not_nil(cached.cmake)
            assert.equals("Debug", cached.variant)
            assert.equals("ninja-gcc", cached.tool_key)
            assert.is_not_nil(cached.tool_data)

            -- No build dir cleanup
            assert.equals(0, #rm_calls)
        end)

        it("kept config preserves built state for remaining profile", function()
            -- Delete one profile sharing a config; the config stays built
            -- for the remaining profile.
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        staging = { App = "development" },
                    },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                        staging = {
                            configuration_set = "staging",
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

            -- Delete debug -> config kept
            local p1 = h.find_profile(core:get_profiles(), "debug")
            local plan = p1:plan_deletion()
            assert.equals("keep", plan.items[1].disposition)
            core:execute_deletion(plan, { deactivate_profile = p1 })

            -- Config still built
            local ws = core:get_workspace()
            local cached = find_cached(ws:_serialize_cache(), "App", "development")
            assert.equals("built", cached.state)
            assert.equals("/root/.nvim/build/App/development", cached.build_dir)
            assert_cache_coherent(core, "config stays built")
        end)

        it("plan_deletion always includes all items even when all shared", function()
            -- If every config is shared, plan still returns all items (all "keep")
            local core = make_tracked_core(
                {
                    projects = {
                        A = { typescript = {} },
                        B = { typescript = {} },
                    },
                    configuration_sets = {
                        debug = { A = "dev", B = "dev" },
                        staging = { A = "dev", B = "dev" },
                    },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "A/dev", "B/dev" },
                        },
                        staging = {
                            configuration_set = "staging",
                            configurations = { "A/dev", "B/dev" },
                        },
                    },
                    configurations = {
                        ["A/dev"] = {
                            project_key = "A",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/A/dev",
                        },
                        ["B/dev"] = {
                            project_key = "B",
                            config_key = "dev",
                            variant = "dev",
                            type = "typescript",
                            state = "built",
                            build_dir = "/root/.nvim/build/B/dev",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            local profile = h.find_profile(core:get_profiles(), "debug")
            local plan = profile:plan_deletion()

            -- All items present (not filtered out)
            assert.equals(2, #plan.items)

            -- All are "keep" since staging holds them
            for _, item in ipairs(plan.items) do
                assert.equals("keep", item.disposition)
            end
        end)

        it("delete_config with set-based profile ref resets config instead of blocking", function()
            local core, rm_calls = make_tracked_core(
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- plan_config_deletion should return "reset" since set-based profile refs it
            local plan = get_unit(core, "App", "development"):plan_deletion()
            assert.equals(1, #plan.items)
            assert.equals("reset", plan.items[1].disposition)

            -- Execute deletion
            get_unit(core, "App", "development"):delete()
            assert_cache_coherent(core, "after config delete with full ref")

            -- Config reset to unconfigured (skeleton kept for set-based profile)
            local ws = core:get_workspace()
            local scache = ws:_serialize_cache()
            local cached = find_cached(scache, "App", "development")
            assert.is_not_nil(cached, "config should survive reset")
            assert.is_nil(cached.state)
            assert.is_nil(cached.build_dir)

            -- Build dir was cleaned
            assert.equals(1, #rm_calls)

            -- Profile still intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug"))
        end)

        it("delete_config with only pinned profile resets config", function()
            local core, rm_calls = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                },
                {
                    pinned_profiles = {
                        ["App/development"] = { mappings = { App = "development" } },
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
                            build_dir = "/root/.nvim/build/App/development",
                        },
                    },
                }
            )
            core:setup({ root = "/root" })

            -- plan_config_deletion should return "reset" (pinned profile still refs it)
            local plan = get_unit(core, "App", "development"):plan_deletion()
            assert.equals(1, #plan.items)
            assert.equals("reset", plan.items[1].disposition)

            get_unit(core, "App", "development"):delete()
            assert_cache_coherent(core, "after config delete with pinned ref")
            assert.equals(1, #rm_calls)

            -- Config reset to unconfigured (skeleton kept for pinned profile)
            local ws = core:get_workspace()
            local scache = ws:_serialize_cache()
            local cached = find_cached(scache, "App", "development")
            assert.is_not_nil(cached, "config should survive reset")
            assert.is_nil(cached.state)
            assert.is_nil(cached.build_dir)

            -- Pinned profile still intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "App/development"))
        end)
    end)

    describe("find_referencing_profiles", function()

        it("counts both set-based and pinned profiles", function()
            -- In the new model, config sets DO create profiles (derived at runtime).
            -- Both set-based and pinned profiles count as references.
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = { debug = { App = "development" } },
                },
                {
                    pinned_profiles = {
                        ["App/development"] = { mappings = { App = "development" } },
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

            -- "debug" profile exists (derived from config_sets)
            local debug_profile = h.find_profile(core:get_profiles(), "debug")
            assert.is_not_nil(debug_profile)

            -- referencing_profiles should find both the set-based and pinned profiles
            local refs = get_unit(core, "App", "development"):referencing_profiles()
            assert.equals(2, #refs)
        end)

        it("returns empty when no cached profiles reference config", function()
            local core = make_tracked_core({
                projects = { App = { typescript = {} } },
                configuration_sets = { debug = { App = "development" } },
            })
            core:setup({ root = "/root" })

            -- No cached profiles at all
            local refs = get_unit(core, "App", "development"):referencing_profiles()
            assert.equals(0, #refs)
        end)

        it("counts multiple materialized profiles", function()
            local core = make_tracked_core(
                {
                    projects = { App = { typescript = {} } },
                    configuration_sets = {
                        debug = { App = "development" },
                        staging = { App = "development" },
                    },
                },
                nil,
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                        staging = {
                            configuration_set = "staging",
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
                }
            )
            core:setup({ root = "/root" })

            local refs = get_unit(core, "App", "development"):referencing_profiles()
            assert.equals(2, #refs)
            -- Sorted alphabetically
            assert.equals("debug", refs[1].key)
            assert.equals("staging", refs[2].key)
        end)
    end)

    describe("delete_config cross-project isolation", function()

        it("delete_config on one project does not affect other projects", function()
            local core, rm_calls = make_tracked_core({
                projects = {
                    Backend = { typescript = {} },
                    Frontend = { typescript = {} },
                },
            })
            core:setup({ root = "/root" })

            -- Build both projects via pinned
            get_unit(core, "Backend", "development"):materialize_pinned("development")
            simulate_build(core, "Backend", "development", "/root/.nvim/build/Backend/dev")
            get_unit(core, "Frontend", "development"):materialize_pinned("development")
            simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")
            assert_cache_coherent(core, "both built")
            assert.equals(2, count_profiles(core))
            assert.equals(2, count_cached_configs(core))

            -- Delete Backend config — Frontend unaffected, Backend profile stays
            get_unit(core, "Backend", "development"):delete()
            assert_cache_coherent(core, "after Backend delete")
            assert.equals(2, count_profiles(core)) -- both pinned profiles stay
            assert.equals(2, count_cached_configs(core)) -- Backend reset, Frontend built
            assert.equals(1, #rm_calls)

            -- Backend config reset, pinned profile still exists
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "Backend/development"))
            assert.is_nil(find_cached(cache, "Backend", "development").state)

            -- Frontend still fully intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "Frontend/development"))
            assert.is_not_nil(find_cached(cache, "Frontend", "development"))
            assert.equals("built", find_cached(cache, "Frontend", "development").state)
        end)

        it("delete_config removes only target from multi-config profile's reachable set", function()
            -- Full profile covers two projects. delete_config on one project's config
            -- only removes the pinned, the set-based profile still keeps the config.
            local core, rm_calls = make_tracked_core({
                projects = {
                    Backend = { typescript = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    debug = { Backend = "development", Frontend = "development" },
                },
            })
            core:setup({ root = "/root" })

            get_cs(core, "debug"):activate()
            simulate_build(core, "Backend", "development", "/root/.nvim/build/Backend/dev")
            simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")

            -- Also pin Backend via pinned
            get_unit(core, "Backend", "development"):materialize_pinned("development")
            assert_cache_coherent(core, "full + pinned")

            -- delete_config on Backend — resets config (both profiles still ref it)
            get_unit(core, "Backend", "development"):delete()
            assert_cache_coherent(core, "after delete_config")
            assert.equals(2, count_cached_configs(core)) -- both still there
            assert.equals(1, #rm_calls) -- Backend build dir cleaned on reset

            -- Backend config reset to unconfigured
            local ws = core:get_workspace()
            local cache = ws:_serialize_cache()
            assert.is_nil(find_cached(cache, "Backend", "development").state)

            -- Both profiles still intact
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "Backend/development"))
            assert.is_not_nil(h.find_profile(core:get_workspace()._profiles, "debug"))
            assert.equals("built", find_cached(cache, "Frontend", "development").state)
        end)
    end)
end)
