--- Tests for Projects section status rendering with cmake tool-qualified keys.
--- Replicates the exact flow of projects.lua rendering to verify
--- that tool entries show correct status from cached configurations.

local Core = require("loomworks.core")
local h = require("tests.helpers")

--- Create a Core with mocked deps and standard test files.
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

local real_merge = require("loomworks.merge")

local function merge_with_cmake_tools()
    return {
        detect_tools = function()
            return {
                cmake = {
                    {
                        tool_data = { id = "ninja-gcc-12", generator = "Ninja", compiler_path = "/usr/bin/gcc-12" },
                        tool_key = "ninja-gcc-12",
                        tool_label = "Ninja + GCC 12",
                    },
                },
            }
        end,
        merge = real_merge.merge,

        get_all_profiles = real_merge.get_all_profiles,

        build_config_key = real_merge.build_config_key,
        profile_key = real_merge.profile_key,
        detect_tools_for_type = real_merge.detect_tools_for_type,
    }
end

local function merge_without_tools()
    return {
        detect_tools = function() return {} end,
        merge = real_merge.merge,

        get_all_profiles = real_merge.get_all_profiles,

        build_config_key = real_merge.build_config_key,
        profile_key = real_merge.profile_key,
        detect_tools_for_type = real_merge.detect_tools_for_type,
    }
end

local cmake_module = {
    validate = function() return { valid = true, warnings = {} } end,
    info = function() return { configurations = { Debug = {}, Release = {} } } end,
}

--- Replicate exactly what collect_tool_entries + resolve_config_status_global does.
--- @param core loomworks.Core
--- @param project_key string
--- @param variant string configuration name (e.g. "Debug")
--- @return table[] entries with { config_key, tool_key, state }
local function simulate_projects_section_rendering(core, project_key, variant)
    local proj = h.find_project_in(core:get_projects(), project_key)
    if not proj then return {} end

    local tools_by_type = core:get_tools_by_type()

    -- Step 1: Replicate collect_tool_entries (case-insensitive variant match)
    local entries = {}
    local seen_tool_keys = {}
    local variant_lower = variant:lower()

    if proj.cached_configurations then
        for config_key, cached_config in pairs(proj.cached_configurations) do
            local v = cached_config.variant
            local tk = cached_config.tool_key
            if v and tk and v:lower() == variant_lower then
                entries[#entries + 1] = {
                    config_key = config_key,
                    tool_key = tk,
                    cached = cached_config,
                }
                seen_tool_keys[tk] = true
            end
        end
    end

    local relevant_tools = tools_by_type[proj.type] or {}
    for _, dt in ipairs(relevant_tools) do
        if dt.tool_key and not seen_tool_keys[dt.tool_key] then
            entries[#entries + 1] = {
                config_key = variant .. ":" .. dt.tool_key,
                tool_key = dt.tool_key,
                cached = nil,
            }
        end
    end

    -- Step 2: Replicate resolve_config_status_global -> ConfigUnit:state()
    local results = {}
    for _, entry in ipairs(entries) do
        local cache_id = project_key .. "/" .. entry.config_key
        local unit = h.find_config_unit_by_id(core._workspace._config_units, cache_id)
        if not unit then
            -- Lazily create for unconfigured entries (detected tools with no cache entry)
            local ws_project = h.find_project_in(core:get_projects(), project_key)
            if ws_project then
                local cfg_variant = entry.config_key
                local colon = cfg_variant:find(":")
                if colon then cfg_variant = cfg_variant:sub(1, colon - 1) end
                local cfg_obj = h.get_or_create_config(ws_project, cfg_variant)
                unit = core._workspace:ensure_config_unit(ws_project, cfg_obj, nil)
            end
        end
        local state = unit:state()
        results[#results + 1] = {
            config_key = entry.config_key,
            tool_key = entry.tool_key,
            state = state,
            has_cache = entry.has_cache,
        }
    end

    return results
end

describe("Projects section cmake status", function()
    it("shows built status for tool-qualified cache entry with active profile", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                        build_dir = "/root/.nvim/build/App/Debug-ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_projects_section_rendering(core, "App", "Debug")
        assert.equals(1, #results, "should find exactly one tool entry")
        assert.equals("Debug:ninja-gcc-12", results[1].config_key)
        assert.equals("built", results[1].state,
            "ConfigUnit should return 'built' but got '" .. results[1].state .. "'"
            .. "\n  has_cache: " .. tostring(results[1].has_cache))
    end)

    it("shows built status when no tools detected but cache has keyed entries", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            nil,
            {
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                        build_dir = "/root/.nvim/build/App/Debug-ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_without_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_projects_section_rendering(core, "App", "Debug")
        -- Should still find cached keyed entry
        assert.equals(1, #results, "should find cached tool entry even without detection")
        assert.equals("Debug:ninja-gcc-12", results[1].config_key)
        assert.equals("built", results[1].state)
    end)

    it("shows multiple tool entries with correct states", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                    ["App/Debug:msvc-17"] = {
                        project_key = "App",
                        config_key = "Debug:msvc-17", variant = "Debug",
                        type = "cmake",
                        state = "configured",
                        variant = "Debug",
                        tool_key = "msvc-17",
                    },
                    ["App/Release:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Release:ninja-gcc-12", variant = "Release",
                        type = "cmake",
                        state = "built",
                        variant = "Release",
                        tool_key = "ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        -- Check Debug variant
        local debug_results = simulate_projects_section_rendering(core, "App", "Debug")
        -- Should find 2 entries for Debug: ninja-gcc-12 (built) and msvc-17 (configured)
        assert.equals(2, #debug_results, "should find 2 Debug tool entries")

        local states = {}
        for _, r in ipairs(debug_results) do
            states[r.tool_key] = r.state
        end
        assert.equals("built", states["ninja-gcc-12"])
        assert.equals("configured", states["msvc-17"])

        -- Check Release variant
        local release_results = simulate_projects_section_rendering(core, "App", "Release")
        assert.is_true(#release_results >= 1, "should find at least 1 Release entry")
        local release_states = {}
        for _, r in ipairs(release_results) do
            release_states[r.tool_key] = r.state
        end
        assert.equals("built", release_states["ninja-gcc-12"])
    end)

    it("matches cached variant case-insensitively against cmake preset name", function()
        -- Reproduces a case-sensitivity scenario:
        --   configuration_set maps App -> "debug" (lowercase variant)
        --   CMakePresets defines preset "Debug" (capitalized)
        --   Cache key is "debug:ninja-clang" (uses config_set variant)
        --   Projects section iterates cmake presets: cname = "Debug"
        --   collect_tool_entries must match "debug" against "Debug"
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "debug" } },
            },
            { active_profile = "Debug:ninja-gcc-12" },
            {
                profiles = {
                    ["Debug:ninja-gcc-12"] = {
                        configuration_set = "Debug",
                        tool_key = "ninja-gcc-12",
                        configurations = { "App/debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "debug:ninja-gcc-12", variant = "debug",
                        type = "cmake",
                        state = "built",
                        variant = "debug",
                        tool_key = "ninja-gcc-12",
                        build_dir = "/root/.nvim/build/App/debug-ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                -- cmake.info() returns capitalized preset names
                modules = {
                    get = function(t)
                        return t == "cmake" and {
                            validate = function() return { valid = true, warnings = {} } end,
                            info = function() return { configurations = { Debug = {}, Release = {} } } end,
                        } or nil
                    end,
                },
            }
        )
        core:setup({ root = "/root" })

        -- The variant in cache is "debug" (lowercase), but cmake preset is "Debug"
        -- collect_tool_entries("Debug") must find "debug:ninja-gcc-12" via case-insensitive match
        local results = simulate_projects_section_rendering(core, "App", "Debug")

        -- Should find the cached entry despite case mismatch
        assert.equals(1, #results, "should match cached 'debug' against preset 'Debug'")
        assert.equals("debug:ninja-gcc-12", results[1].config_key)
        assert.equals("built", results[1].state)
    end)

    it("workspace cache accessible from ConfigUnit during rendering", function()
        -- Verify the workspace/cache reference chain is intact
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        -- Verify the Project object has correct cached_configurations
        local proj = h.find_project_in(core:get_projects(), "App")
        assert.is_not_nil(proj.cached_configurations["Debug:ninja-gcc-12"],
            "Project.cached_configurations should have tool-qualified key")

        -- Verify the workspace cache has the same data
        local ws = core:get_workspace()
        assert.is_not_nil(ws:_serialize_cache().configurations["App/Debug:ninja-gcc-12"],
            "serialized cache should have flat config entry")

        -- Verify ConfigUnit reads from the same workspace
        local unit = h.find_config_unit_by_id(core._workspace._config_units, "App/Debug:ninja-gcc-12")
        assert.is_not_nil(unit, "ConfigUnit should exist for the cache entry")
        assert.equals("built", unit.state_value)
    end)
end)

--- Replicate entry_highlight from projects.lua for testing.
local function entry_highlight(config_status, status_hl, is_spinning, is_active)
    if is_spinning then return status_hl end
    if is_active then return "LoomworksActive" end
    if config_status == "failed_configure" or config_status == "failed_build" then
        return "LoomworksFailed"
    end
    if config_status == "unconfigured" then return "LoomworksUnconfigured" end
    return "LoomworksConfigured"
end

--- Simulate rendering with highlights, matching projects.lua logic.
--- @param core loomworks.Core
--- @param project_key string
--- @param variant string
--- @param active_profile_key string|nil
--- @return table[] entries with { config_key, tool_key, state, hl }
local function simulate_with_highlights(core, project_key, variant, active_profile_key)
    local proj = h.find_project_in(core:get_projects(), project_key)
    if not proj then return {} end

    local tools_by_type = core:get_tools_by_type()
    -- Derive active_tool_key from the active profile object, matching production code
    local active_profile = active_profile_key and h.find_profile(core:get_profiles(), active_profile_key) or nil
    local active_tools = active_profile and active_profile:tools_data() or nil
    local active_project_tool = active_tools and active_tools[proj.type] or nil
    local active_tool_key = active_project_tool and active_project_tool.key or nil
    local is_active_project = proj.configuration ~= nil and not proj.orphaned
    local is_active_variant = is_active_project
            and proj.configuration:lower() == variant:lower()

    -- Collect entries (same as simulate_projects_section_rendering)
    local entries = {}
    local seen_tool_keys = {}
    local variant_lower = variant:lower()

    if proj.cached_configurations then
        for config_key, cached_config in pairs(proj.cached_configurations) do
            local v = cached_config.variant
            local tk = cached_config.tool_key
            if v and tk and v:lower() == variant_lower then
                entries[#entries + 1] = {
                    config_key = config_key,
                    tool_key = tk,
                    cached = cached_config,
                }
                seen_tool_keys[tk] = true
            end
        end
    end

    local relevant_tools = tools_by_type[proj.type] or {}
    for _, dt in ipairs(relevant_tools) do
        if dt.tool_key and not seen_tool_keys[dt.tool_key] then
            entries[#entries + 1] = {
                config_key = variant .. ":" .. dt.tool_key,
                tool_key = dt.tool_key,
                cached = nil,
            }
        end
    end

    -- Compute state + highlight for each entry
    local results = {}
    for _, entry in ipairs(entries) do
        local cache_id = project_key .. "/" .. entry.config_key
        local unit = h.find_config_unit_by_id(core._workspace._config_units, cache_id)
        if not unit then
            local ws_project = h.find_project_in(core:get_projects(), project_key)
            if ws_project then
                local cfg_variant = entry.config_key
                local colon = cfg_variant:find(":")
                if colon then cfg_variant = cfg_variant:sub(1, colon - 1) end
                local cfg_obj = h.get_or_create_config(ws_project, cfg_variant)
                unit = core._workspace:ensure_config_unit(ws_project, cfg_obj, nil)
            end
        end
        local state = unit:state()
        local is_spinning = (state == "configuring" or state == "building" or state == "deleting")
        local is_active = is_active_variant and active_tool_key == entry.tool_key
        -- Map state names for hl lookup (same as resolve_unit_status)
        local config_status = state
        if state == "configure_failed" then config_status = "failed_configure" end
        if state == "build_failed" then config_status = "failed_build" end
        local status_hl = ({
            unconfigured     = "LoomworksUnconfigured",
            configured       = "LoomworksConfigured",
            built            = "LoomworksBuilt",
            failed_configure = "LoomworksFailed",
            failed_build     = "LoomworksFailed",
            configuring      = "LoomworksRunning",
            building         = "LoomworksRunning",
            deleting         = "LoomworksDeleting",
        })[config_status] or "Comment"

        results[#results + 1] = {
            config_key = entry.config_key,
            tool_key = entry.tool_key,
            state = state,
            hl = entry_highlight(config_status, status_hl, is_spinning, is_active),
        }
    end

    return results
end

describe("Projects section tool entry highlights", function()
    it("active tool entry gets LoomworksActive", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_with_highlights(core, "App", "Debug", "debug:ninja-gcc-12")
        assert.equals(1, #results)
        assert.equals("LoomworksActive", results[1].hl,
            "active tool entry should be LoomworksActive (green)")
    end)

    it("non-active built tool entry gets LoomworksConfigured", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                    ["App/Debug:msvc-17"] = {
                        project_key = "App",
                        config_key = "Debug:msvc-17", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "msvc-17",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_with_highlights(core, "App", "Debug", "debug:ninja-gcc-12")
        assert.equals(2, #results)
        local by_tool = {}
        for _, r in ipairs(results) do by_tool[r.tool_key] = r end

        assert.equals("LoomworksActive", by_tool["ninja-gcc-12"].hl,
            "active tool should be LoomworksActive")
        assert.equals("LoomworksConfigured", by_tool["msvc-17"].hl,
            "non-active built tool should be LoomworksConfigured (light blue)")
    end)

    it("unconfigured active tool gets LoomworksActive (active takes precedence)", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12",
                        variant = "Debug",
                        type = "cmake",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        -- ninja-gcc-12 detected but not cached -> unconfigured, but active takes precedence
        local results = simulate_with_highlights(core, "App", "Debug", "debug:ninja-gcc-12")
        assert.equals(1, #results)
        assert.equals("LoomworksActive", results[1].hl,
            "active tool should be LoomworksActive even when unconfigured")
    end)

    it("unconfigured non-active tool gets LoomworksUnconfigured", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            nil, -- no active profile
            {
                configurations = {},
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_with_highlights(core, "App", "Debug", nil)
        assert.equals(1, #results)
        assert.equals("LoomworksUnconfigured", results[1].hl,
            "unconfigured non-active tool should be LoomworksUnconfigured (gray)")
    end)

    it("non-active variant built entry gets LoomworksConfigured not LoomworksActive", function()
        -- Active profile is for Debug, but we're looking at Release variant
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                    ["App/Release:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Release:ninja-gcc-12", variant = "Release",
                        type = "cmake",
                        state = "built",
                        variant = "Release",
                        tool_key = "ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        -- Release variant: same tool_key but NOT the active variant
        local results = simulate_with_highlights(core, "App", "Release", "debug:ninja-gcc-12")
        assert.equals(1, #results)
        assert.equals("ninja-gcc-12", results[1].tool_key)
        assert.equals("LoomworksConfigured", results[1].hl,
            "same tool on non-active variant should be LoomworksConfigured, not LoomworksActive")
    end)

    it("no active profile: all built entries get LoomworksConfigured", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            nil, -- no active profile
            {
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "built",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_with_highlights(core, "App", "Debug", nil)
        assert.equals(1, #results)
        assert.equals("LoomworksConfigured", results[1].hl,
            "without active profile, built entry should be LoomworksConfigured")
    end)

    it("failed active tool gets LoomworksActive (active takes precedence)", function()
        local core = make_core(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            },
            { active_profile = "debug:ninja-gcc-12" },
            {
                profiles = {
                    ["debug:ninja-gcc-12"] = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12" } },
                        configurations = { "App/Debug:ninja-gcc-12" },
                    },
                },
                configurations = {
                    ["App/Debug:ninja-gcc-12"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc-12", variant = "Debug",
                        type = "cmake",
                        state = "failed_build",
                        variant = "Debug",
                        tool_key = "ninja-gcc-12",
                    },
                    ["App/Debug:msvc-17"] = {
                        project_key = "App",
                        config_key = "Debug:msvc-17", variant = "Debug",
                        type = "cmake",
                        state = "failed_configure",
                        variant = "Debug",
                        tool_key = "msvc-17",
                    },
                },
            },
            {
                merge = merge_with_cmake_tools(),
                modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
            }
        )
        core:setup({ root = "/root" })

        local results = simulate_with_highlights(core, "App", "Debug", "debug:ninja-gcc-12")
        local by_tool = {}
        for _, r in ipairs(results) do by_tool[r.tool_key] = r end

        -- Active takes precedence over failed (consistent with profiles/config_sets)
        assert.equals("LoomworksActive", by_tool["ninja-gcc-12"].hl,
            "active tool should be LoomworksActive even when failed")
        -- Non-active failed should be red
        assert.equals("LoomworksFailed", by_tool["msvc-17"].hl,
            "failed non-active tool should be LoomworksFailed")
    end)
end)

-- ---------------------------------------------------------------------------
-- Target rendering tests
-- ---------------------------------------------------------------------------

describe("Target rendering", function()
    local helpers = require("loomworks.ui.helpers")

    --- Minimal tree mock that records all output.
    local function make_mock_tree()
        local lines = {}
        local level = 0
        return {
            _lines = lines,
            leaf = function(_, text, hl)
                lines[#lines + 1] = { text = text, hl = hl, level = level, type = "leaf" }
            end,
            node = function(_, text, opts, children_fn)
                lines[#lines + 1] = { text = text, hl = opts and opts.hl, level = level, type = "node" }
                level = level + 1
                children_fn()
                level = level - 1
            end,
            group = function(_, label, hl, children_fn)
                lines[#lines + 1] = { text = label, hl = hl, level = level, type = "group" }
                level = level + 1
                children_fn()
                level = level - 1
            end,
        }
    end

    it("renders targets grouped by type with counts", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable" },
            cli = { type = "executable" },
            libcore = { type = "static_library" },
            libutil = { type = "shared_library" },
        })

        -- Top-level: foldable Targets header with total count
        assert.equals("Targets (4)", tree._lines[1].text)
        assert.equals("node", tree._lines[1].type)

        -- Type group headers (level 1) with per-group counts
        local group_headers = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 1 and line.type == "node" then
                group_headers[#group_headers + 1] = line.text
            end
        end
        assert.equals(3, #group_headers)
        assert.equals("Executables (2)", group_headers[1])
        assert.equals("Static Libraries (1)", group_headers[2])
        assert.equals("Shared Libraries (1)", group_headers[3])

        -- Target names inside groups (level 2), sorted alphabetically
        local target_names = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 2 then
                target_names[#target_names + 1] = line.text
            end
        end
        assert.equals(4, #target_names)
        assert.equals("app", target_names[1])
        assert.equals("cli", target_names[2])
        assert.equals("libcore", target_names[3])
        assert.equals("libutil", target_names[4])
    end)

    it("renders leaf nodes for targets without dependencies", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable" },
        })

        local target_line
        for _, line in ipairs(tree._lines) do
            if line.text == "app" then
                target_line = line
                break
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("leaf", target_line.type)
    end)

    it("renders foldable nodes for targets with dependencies", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable", dependencies = { "libcore", "libutil" } },
        })

        local target_line, links_line
        for _, line in ipairs(tree._lines) do
            if line.text == "app" then
                target_line = line
            end
            if line.text and line.text:match("^Links:") then
                links_line = line
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("node", target_line.type)
        assert.is_not_nil(links_line)
        assert.equals("Links: libcore, libutil", links_line.text)
    end)

    it("renders foldable nodes for targets with artifact path", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            libcore = { type = "static_library", artifact = "libs/core/libcore.a" },
        })

        local target_line, path_line
        for _, line in ipairs(tree._lines) do
            if line.text == "libcore" then
                target_line = line
            end
            if line.text and line.text:match("^Path:") then
                path_line = line
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("node", target_line.type)
        assert.is_not_nil(path_line)
        assert.equals("Path: libs/core/libcore.a", path_line.text)
    end)

    it("renders path before links when target has both", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable", artifact = "bin/app.exe", dependencies = { "lib" } },
        })

        local detail_lines = {}
        for _, line in ipairs(tree._lines) do
            if line.text and (line.text:match("^Path:") or line.text:match("^Links:")) then
                detail_lines[#detail_lines + 1] = line.text
            end
        end
        assert.equals(2, #detail_lines)
        assert.equals("Path: bin/app.exe", detail_lines[1])
        assert.equals("Links: lib", detail_lines[2])
    end)

    it("renders type groups in correct order", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            iface = { type = "interface_library" },
            obj = { type = "object_library" },
            mod = { type = "module_library" },
            app = { type = "executable" },
        })

        local group_headers = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 1 and line.type == "node" then
                group_headers[#group_headers + 1] = line.text
            end
        end
        assert.equals("Executables (1)", group_headers[1])
        assert.equals("Module Libraries (1)", group_headers[2])
        assert.equals("Object Libraries (1)", group_headers[3])
        assert.equals("Interface Libraries (1)", group_headers[4])
    end)

    it("integrates into render_cached_details when ConfigUnit has targets", function()
        local tree = make_mock_tree()
        local mock_unit = {
            targets = {
                app = { type = "executable", dependencies = { "lib" } },
                lib = { type = "static_library" },
            },
        }
        helpers.render_cached_details(tree, "built", "LoomworksBuilt", {
            state = "built",
            build_dir = "/root/.nvim/build/App/Debug",
            cmake = { generator = "Ninja" },
        }, nil, mock_unit)

        -- Should include Targets node with count
        local has_targets = false
        for _, line in ipairs(tree._lines) do
            if line.text and line.text:match("^Targets %(%d+%)$") then
                has_targets = true
                break
            end
        end
        assert.is_true(has_targets, "render_cached_details should include Targets node")
    end)

    it("does not render Targets when ConfigUnit has no targets", function()
        local tree = make_mock_tree()
        helpers.render_cached_details(tree, "built", "LoomworksBuilt", {
            state = "built",
            cmake = { generator = "Ninja" },
        }, nil, { targets = nil })

        for _, line in ipairs(tree._lines) do
            if line.text then
                assert.is_nil(line.text:match("^Targets %(%d+%)$"),
                    "should not render Targets node without target data")
            end
        end
    end)
end)
