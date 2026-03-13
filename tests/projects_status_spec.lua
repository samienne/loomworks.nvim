--- Tests for Projects section status rendering with cmake tool-qualified keys.
--- Replicates the exact flow of projects.lua rendering to verify
--- that tool entries show correct status from cached configurations.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local merge = require("loomworks.merge")

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
    module_has_keyed_tools = real_merge.module_has_keyed_tools,
    get_all_profiles = real_merge.get_all_profiles,
    parse_profile_key = real_merge.parse_profile_key,
    build_config_key = real_merge.build_config_key,
    profile_key = real_merge.profile_key,
    detect_tools_for_type = real_merge.detect_tools_for_type,
  }
end

local function merge_without_tools()
  return {
    detect_tools = function() return {} end,
    merge = real_merge.merge,
    module_has_keyed_tools = real_merge.module_has_keyed_tools,
    get_all_profiles = real_merge.get_all_profiles,
    parse_profile_key = real_merge.parse_profile_key,
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
  local proj = core:get_project(project_key)
  if not proj then return {} end

  local tools_by_type = core:get_tools_by_type()

  -- Step 1: Replicate collect_tool_entries (case-insensitive variant match)
  local entries = {}
  local seen_tool_keys = {}
  local variant_lower = variant:lower()

  if proj.cached_configurations then
    for config_key, cached_config in pairs(proj.cached_configurations) do
      local v, tk = merge.parse_profile_key(config_key)
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

  -- Step 2: Replicate resolve_config_status_global → ConfigUnit:state()
  local results = {}
  for _, entry in ipairs(entries) do
    local unit = core:get_config_unit(project_key, entry.config_key)
    local state = unit:state()
    results[#results + 1] = {
      config_key = entry.config_key,
      tool_key = entry.tool_key,
      state = state,
      cached_from_collect = entry.cached,
      cached_from_unit = unit:cached_state(),
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
            tool_key = "ninja-gcc-12",
            projects = { App = { config_key = "Debug:ninja-gcc-12" } },
          },
        },
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["Debug:ninja-gcc-12"] = {
                state = "built",
                variant = "Debug",
                tool_key = "ninja-gcc-12",
                build_dir = "/root/.nvim/build/App/Debug-ninja-gcc-12",
              },
            },
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
      .. "\n  cached_from_collect: " .. vim.inspect(results[1].cached_from_collect)
      .. "\n  cached_from_unit: " .. vim.inspect(results[1].cached_from_unit))
  end)

  it("shows built status for tool-qualified cache entry WITHOUT active profile", function()
    local core = make_core(
      {
        projects = { App = { cmake = {} } },
        configuration_sets = { debug = { App = "Debug" } },
      },
      nil, -- no active profile
      {
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["Debug:ninja-gcc-12"] = {
                state = "built",
                variant = "Debug",
                tool_key = "ninja-gcc-12",
                build_dir = "/root/.nvim/build/App/Debug-ninja-gcc-12",
              },
            },
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
    assert.equals(1, #results, "should find exactly one tool entry (from cache)")
    assert.equals("Debug:ninja-gcc-12", results[1].config_key)
    assert.equals("built", results[1].state,
      "ConfigUnit should return 'built' but got '" .. results[1].state .. "'"
      .. "\n  cached_from_collect: " .. vim.inspect(results[1].cached_from_collect)
      .. "\n  cached_from_unit: " .. vim.inspect(results[1].cached_from_unit))
  end)

  it("shows built status when no tools detected but cache has keyed entries", function()
    local core = make_core(
      {
        projects = { App = { cmake = {} } },
        configuration_sets = { debug = { App = "Debug" } },
      },
      nil,
      {
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["Debug:ninja-gcc-12"] = {
                state = "built",
                variant = "Debug",
                tool_key = "ninja-gcc-12",
                build_dir = "/root/.nvim/build/App/Debug-ninja-gcc-12",
              },
            },
          },
        },
      },
      {
        merge = merge_without_tools(),
        modules = { get = function(t) return t == "cmake" and cmake_module or nil end },
      }
    )
    core:setup({ root = "/root" })

    -- No detected tools
    assert.is_false(core:module_has_keyed_tools("cmake"))

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
            tool_key = "ninja-gcc-12",
            projects = { App = { config_key = "Debug:ninja-gcc-12" } },
          },
        },
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["Debug:ninja-gcc-12"] = {
                state = "built",
                variant = "Debug",
                tool_key = "ninja-gcc-12",
              },
              ["Debug:msvc-17"] = {
                state = "configured",
                variant = "Debug",
                tool_key = "msvc-17",
              },
              ["Release:ninja-gcc-12"] = {
                state = "built",
                variant = "Release",
                tool_key = "ninja-gcc-12",
              },
            },
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
    -- This reproduces the real-world scenario:
    --   configuration_set maps LumeTS → "debug" (lowercase)
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
            projects = { App = { config_key = "debug:ninja-gcc-12" } },
          },
        },
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["debug:ninja-gcc-12"] = {
                state = "built",
                variant = "debug",
                tool_key = "ninja-gcc-12",
                build_dir = "/root/.nvim/build/App/debug-ninja-gcc-12",
              },
            },
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
            tool_key = "ninja-gcc-12",
            projects = { App = { config_key = "Debug:ninja-gcc-12" } },
          },
        },
        projects = {
          App = {
            type = "cmake",
            configurations = {
              ["Debug:ninja-gcc-12"] = {
                state = "built",
                variant = "Debug",
                tool_key = "ninja-gcc-12",
              },
            },
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
    local proj = core:get_project("App")
    assert.is_not_nil(proj.cached_configurations["Debug:ninja-gcc-12"],
      "Project.cached_configurations should have tool-qualified key")

    -- Verify the workspace cache has the same data
    local ws = core:get_workspace()
    assert.is_not_nil(ws.cache.projects.App,
      "ws.cache.projects should have App")
    assert.is_not_nil(ws.cache.projects.App.configurations["Debug:ninja-gcc-12"],
      "ws.cache should have tool-qualified configuration")

    -- Verify Project.cached_configurations is the SAME table as ws.cache.projects.App.configurations
    assert.equals(proj.cached_configurations, ws.cache.projects.App.configurations,
      "Project.cached_configurations should reference the same table as ws.cache")

    -- Verify ConfigUnit reads from the same workspace
    local unit = core:get_config_unit("App", "Debug:ninja-gcc-12")
    local cached = unit:cached_state()
    assert.is_not_nil(cached, "ConfigUnit:cached_state() should find the cache entry")
    assert.equals("built", cached.state)
  end)
end)
