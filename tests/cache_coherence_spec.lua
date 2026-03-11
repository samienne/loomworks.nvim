--- Cache coherence tests.
---
--- Integration-style tests that simulate real workflows:
--- configure, build, delete profiles (full and ad-hoc),
--- and verify cache invariants after each operation.
---
--- Key invariant: every cached config in configured/built/failed state
--- is referenced by at least one profile. No orphaned configs or
--- leftover build directories after profile deletion.

local Core = require("loomworks.core")
local h = require("tests.helpers")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Assert the cache coherence invariant: every cached config with state
--- is referenced by at least one profile.
local function assert_cache_coherent(core, msg)
  local ws = core:get_workspace()
  if not ws then return end

  local prefix = msg and (msg .. ": ") or ""

  -- Build a set of all (project_key, config_key) referenced by profiles
  local referenced = {}
  if ws.cache.profiles then
    for _, profile in pairs(ws.cache.profiles) do
      if profile.projects then
        for pkey, pdata in pairs(profile.projects) do
          if pdata.config_key then
            referenced[pkey .. "\0" .. pdata.config_key] = true
          end
        end
      end
    end
  end

  -- Check every cached config is referenced
  if ws.cache.projects then
    for project_key, cached_proj in pairs(ws.cache.projects) do
      if cached_proj.configurations then
        for config_key, cached_config in pairs(cached_proj.configurations) do
          local state = cached_config.state
          if state and state ~= "unconfigured" then
            local lookup = project_key .. "\0" .. config_key
            assert(referenced[lookup],
              prefix .. "orphaned config: " .. project_key .. "/" .. config_key
              .. " (state=" .. state .. ") not referenced by any profile")
          end
        end
      end
    end
  end
end

--- Assert that the cache has no configs at all.
local function assert_cache_empty(core, msg)
  local ws = core:get_workspace()
  local prefix = msg and (msg .. ": ") or ""
  assert(ws, prefix .. "workspace should exist")

  local has_configs = false
  if ws.cache.projects then
    for _, proj in pairs(ws.cache.projects) do
      if proj.configurations and next(proj.configurations) then
        has_configs = true
        break
      end
    end
  end
  assert(not has_configs, prefix .. "cache should have no configurations")

  local has_profiles = ws.cache.profiles and next(ws.cache.profiles)
  assert(not has_profiles, prefix .. "cache should have no profiles")
end

--- Count cached configs across all projects.
local function count_cached_configs(core)
  local ws = core:get_workspace()
  if not ws or not ws.cache.projects then return 0 end
  local count = 0
  for _, proj in pairs(ws.cache.projects) do
    if proj.configurations then
      for _ in pairs(proj.configurations) do
        count = count + 1
      end
    end
  end
  return count
end

--- Count profiles in cache.
local function count_profiles(core)
  local ws = core:get_workspace()
  if not ws or not ws.cache.profiles then return 0 end
  local count = 0
  for _ in pairs(ws.cache.profiles) do
    count = count + 1
  end
  return count
end

--- Simulate a configure+build result for a config.
local function simulate_build(core, project_key, config_key, build_dir)
  core:record_task_result({
    project_key = project_key,
    configuration_key = config_key,
    action = "configure",
    success = true,
    build_dir = build_dir,
  })
  core:record_task_result({
    project_key = project_key,
    configuration_key = config_key,
    action = "build",
    success = true,
    build_dir = build_dir,
  })
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
      core._tools_by_type = injected_tools
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

    it("materialize_adhoc + build creates coherent state", function()
      local core = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      core:materialize_adhoc("App", "development")
      assert_cache_coherent(core, "after materialize_adhoc")
      assert.equals(1, count_profiles(core))

      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after build")
    end)

    it("deleting sole ad-hoc profile cleans config and build dir", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      core:materialize_adhoc("App", "development")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert.equals(1, count_cached_configs(core))

      -- Delete via plan+execute (as UI would)
      local profile = core:get_profile("adhoc:App:development")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      -- Config is unreferenced after removing sole profile
      assert.equals(1, #plan.items)

      local done = false
      core:execute_deletion(plan, { deactivate_profile = profile.key },
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

      -- Materialize a full profile
      core:materialize_profile("debug")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after full profile build")

      -- Also create an ad-hoc for the same config
      core:materialize_adhoc("App", "development")
      assert_cache_coherent(core, "after also creating ad-hoc")
      local n_profiles = count_profiles(core)
      assert.is_true(n_profiles >= 2)

      -- Delete ad-hoc — config should survive but be reset (full profile still references it)
      local adhoc = core:get_profile("adhoc:App:development")
      assert.is_not_nil(adhoc)
      local plan = adhoc:plan_deletion()
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)

      local done = false
      core:execute_deletion(plan, { deactivate_profile = adhoc.key },
        function() done = true end)
      assert.is_true(done)

      assert_cache_coherent(core, "after deleting ad-hoc")
      assert.equals(1, count_cached_configs(core))
      -- Config entry exists but state was reset
      local ws = core:get_workspace()
      assert.is_nil(ws.cache.projects.App.configurations.development.state)
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
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
              { tool_key = "ninja-clang", tool_data = { generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
            },
          },
        }
      )
      setup({ root = "/root" })
      assert_cache_coherent(core, "after setup")

      -- Build with gcc
      core:materialize_adhoc("Lib", "Debug:ninja-gcc")
      simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/Debug-gcc")
      assert_cache_coherent(core, "after gcc build")

      -- Build with clang
      core:materialize_adhoc("Lib", "Debug:ninja-clang")
      simulate_build(core, "Lib", "Debug:ninja-clang", "/root/.nvim/build/Lib/Debug-clang")
      assert_cache_coherent(core, "after clang build")
      assert.equals(2, count_cached_configs(core))

      -- Delete gcc profile
      local gcc_profile = core:get_profile("adhoc:Lib:Debug:ninja-gcc")
      assert.is_not_nil(gcc_profile)
      local plan = gcc_profile:plan_deletion()
      assert.equals(1, #plan.items)

      local done = false
      core:execute_deletion(plan, { deactivate_profile = gcc_profile.key },
        function() done = true end)
      assert.is_true(done)

      assert_cache_coherent(core, "after deleting gcc profile")
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls)
      assert.truthy(rm_calls[1]:match("Debug%-gcc"))

      -- Clang config should still be there
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.projects.Lib.configurations["Debug:ninja-clang"])
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
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
          },
        }
      )
      setup({ root = "/root" })

      core:materialize_adhoc("Lib", "Debug:ninja-gcc")
      simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/Debug")
      core:materialize_adhoc("Lib", "Release:ninja-gcc")
      simulate_build(core, "Lib", "Release:ninja-gcc", "/root/.nvim/build/Lib/Release")
      assert.equals(2, count_cached_configs(core))
      assert_cache_coherent(core, "after two builds")

      -- Delete first
      local p1 = core:get_profile("adhoc:Lib:Debug:ninja-gcc")
      local plan1 = p1:plan_deletion()
      core:execute_deletion(plan1, { deactivate_profile = p1.key })
      assert_cache_coherent(core, "after first delete")
      assert.equals(1, count_cached_configs(core))

      -- Delete second
      local p2 = core:get_profile("adhoc:Lib:Release:ninja-gcc")
      local plan2 = p2:plan_deletion()
      core:execute_deletion(plan2, { deactivate_profile = p2.key })

      assert_cache_empty(core, "after deleting all profiles")
      assert.equals(2, #rm_calls)
    end)
  end)

  describe("multi-project workspace", function()

    it("full profile build + delete cleans all project configs", function()
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
            { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
          },
        },
      })
      setup({ root = "/root" })

      -- Materialize the debug:ninja-gcc profile
      core:materialize_profile("debug:ninja-gcc")
      simulate_build(core, "Backend", "Debug:ninja-gcc", "/root/.nvim/build/Backend/Debug")
      simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")
      assert_cache_coherent(core, "after full build")
      assert.equals(2, count_cached_configs(core))

      -- Delete the profile
      local profile = core:get_profile("debug:ninja-gcc")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(2, #plan.items) -- both configs unreferenced

      local done = false
      core:execute_deletion(plan, { deactivate_profile = profile.key },
        function() done = true end)
      assert.is_true(done)

      assert_cache_empty(core, "after deleting full profile")
      assert.equals(2, #rm_calls)
    end)

    it("mixed full + ad-hoc profiles with shared configs", function()
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
            { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
          },
        },
      })
      setup({ root = "/root" })

      -- Full profile build
      core:materialize_profile("debug:ninja-gcc")
      simulate_build(core, "Backend", "Debug:ninja-gcc", "/root/.nvim/build/Backend/Debug")
      simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")

      -- Ad-hoc: build Backend with same config (overlapping reference)
      core:materialize_adhoc("Backend", "Debug:ninja-gcc")
      assert_cache_coherent(core, "after ad-hoc overlapping")

      -- Delete ad-hoc — config shared by full profile, should be reset
      local adhoc = core:get_profile("adhoc:Backend:Debug:ninja-gcc")
      assert.is_not_nil(adhoc)
      local plan = adhoc:plan_deletion()
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)
      core:execute_deletion(plan, { deactivate_profile = adhoc.key })
      assert_cache_coherent(core, "after ad-hoc delete")
      assert.equals(2, count_cached_configs(core))
      assert.equals(1, #rm_calls) -- Backend build dir cleaned on reset

      -- Now delete full profile — both configs should be cleaned
      local full = core:get_profile("debug:ninja-gcc")
      assert.is_not_nil(full)
      local plan2 = full:plan_deletion()
      assert.equals(2, #plan2.items)
      -- Backend was already reset (no build dir), Frontend still has one
      core:execute_deletion(plan2, { deactivate_profile = full.key })

      assert_cache_empty(core, "after full profile delete")
      assert.equals(2, #rm_calls)
    end)
  end)

  describe("delete_config from Projects section", function()

    it("deletes config and ad-hoc profile when no full profile refs", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      core:materialize_adhoc("App", "development")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after build")

      local done = false
      core:delete_config("App", "development", function() done = true end)
      assert.is_true(done)

      assert_cache_empty(core, "after delete_config")
      assert.equals(1, #rm_calls)
    end)

    it("keeps config when full profile references it", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })

      -- Full profile + ad-hoc both reference the config
      core:materialize_profile("debug")
      core:materialize_adhoc("App", "development")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after build")

      -- delete_config removes ad-hoc, resets config (full profile still refs it)
      local done = false
      core:delete_config("App", "development", function() done = true end)
      assert.is_true(done)

      assert_cache_coherent(core, "after delete_config with full ref")
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls) -- build dir cleaned on reset

      -- Config entry exists but state was reset to unconfigured
      local ws = core:get_workspace()
      assert.is_nil(ws.cache.projects.App.configurations.development.state)

      -- Ad-hoc should be gone
      local adhoc_gone = not ws.cache.profiles
          or not ws.cache.profiles["adhoc:App:development"]
      assert.is_true(adhoc_gone)
    end)

    it("keyed tool: deletes specific tool config, keeps other tools", function()
      local core, rm_calls, setup = make_tracked_core({
        projects = { Lib = { cmake = {} } },
      }, nil, nil, {
        tools_by_type = {
          cmake = {
            { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            { tool_key = "ninja-clang", tool_data = { generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
          },
        },
      })
      setup({ root = "/root" })

      core:materialize_adhoc("Lib", "Debug:ninja-gcc")
      simulate_build(core, "Lib", "Debug:ninja-gcc", "/root/.nvim/build/Lib/Debug-gcc")
      core:materialize_adhoc("Lib", "Debug:ninja-clang")
      simulate_build(core, "Lib", "Debug:ninja-clang", "/root/.nvim/build/Lib/Debug-clang")
      assert.equals(2, count_cached_configs(core))

      core:delete_config("Lib", "Debug:ninja-gcc")
      assert_cache_coherent(core, "after delete one tool config")
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls)

      -- Clang config still present
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.projects.Lib.configurations["Debug:ninja-clang"])
    end)
  end)

  describe("init adoption", function()

    it("adopts orphaned built config as ad-hoc profile", function()
      local core = make_tracked_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          -- Built config with no profile referencing it
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- Should have been adopted
      assert_cache_coherent(core, "after init adoption")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))

      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["adhoc:App:development"])
    end)

    it("drops unconfigured skeleton on init", function()
      local core = make_tracked_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {}, -- no state
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_empty(core, "skeleton should be dropped")
    end)

    it("does not adopt configs already referenced by profile", function()
      local core = make_tracked_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_coherent(core, "after init")
      -- Should still have exactly 1 profile (the existing one, no duplicate)
      assert.equals(1, count_profiles(core))
    end)

    it("adopts failed_configure as ad-hoc profile", function()
      local core = make_tracked_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "failed_configure" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_coherent(core, "failed_configure adopted")
      assert.equals(1, count_profiles(core))
    end)

    it("adopts keyed-tool config with correct ad-hoc key", function()
      local core, _, setup = make_tracked_core(
        { projects = { Lib = { cmake = {} } } },
        nil,
        {
          projects = {
            Lib = {
              type = "cmake",
              configurations = {
                ["Debug:ninja-gcc"] = {
                  state = "built",
                  variant = "Debug",
                  tool_key = "ninja-gcc",
                  build_dir = "/root/.nvim/build/Lib/Debug",
                },
              },
            },
          },
        },
        {
          tools_by_type = {
            cmake = {
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
          },
        }
      )
      setup({ root = "/root" })
      assert_cache_coherent(core, "keyed tool adopted")

      local ws = core:get_workspace()
      local adhoc = ws.cache.profiles["adhoc:Lib:Debug:ninja-gcc"]
      assert.is_not_nil(adhoc)
      assert.is_true(adhoc.ad_hoc)
      assert.equals("Lib", adhoc.project_key)
      assert.equals("Debug:ninja-gcc", adhoc.config_key)
      assert.equals("ninja-gcc", adhoc.tool_key)
    end)
  end)

  describe("init with pre-populated cache", function()

    it("full profile with matching configs stays intact", function()
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
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      assert_cache_coherent(core, "pre-populated full profile")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))

      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles.debug)
      assert.equals("built", ws.cache.projects.App.configurations.development.state)
    end)

    it("multiple full profiles sharing same config stays coherent", function()
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
              projects = { App = { config_key = "development" } },
            },
            staging = {
              configuration_set = "staging",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      assert_cache_coherent(core, "two profiles sharing config")
      assert.equals(2, count_profiles(core))
      assert.equals(1, count_cached_configs(core))
    end)

    it("full profile + ad-hoc both referencing same config", function()
      local core = make_tracked_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      assert_cache_coherent(core, "full + ad-hoc overlap")
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
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
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
              projects = {
                Backend = { config_key = "Debug" },
                Frontend = { config_key = "development" },
                Docs = { config_key = "development" },
              },
            },
          },
          projects = {
            Backend = {
              type = "cmake",
              configurations = {
                Debug = {
                  state = "configured",
                  build_dir = "/root/.nvim/build/Backend/Debug",
                },
              },
            },
            Frontend = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/Frontend/dev",
                },
              },
            },
            Docs = {
              type = "typescript",
              configurations = {
                development = {
                  state = "failed_build",
                  build_dir = "/root/.nvim/build/Docs/dev",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      assert_cache_coherent(core, "multi-project mixed states")
      assert.equals(1, count_profiles(core))
      assert.equals(3, count_cached_configs(core))
    end)

    it("stale profile with missing config entry gets config adopted", function()
      -- Profile references a config_key but the config entry is missing from cache
      -- The profile still holds the reference, so no adoption needed.
      -- But also a separate orphaned config with no profile exists.
      local core = make_tracked_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                -- "development" is missing! (profile references it but it's gone)
                production = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/production",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- "production" is orphaned (no profile) so adoption creates ad-hoc for it
      assert_cache_coherent(core, "stale profile + orphaned config")
      assert.equals(2, count_profiles(core))

      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["adhoc:App:production"])
    end)

    it("multiple ad-hoc profiles for same project different configs", function()
      local core = make_tracked_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
            ["adhoc:App:production"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "production",
              projects = { App = { config_key = "production" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
                production = {
                  state = "configured",
                  build_dir = "/root/.nvim/build/App/production",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      assert_cache_coherent(core, "multiple ad-hoc same project")
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
              tool_key = "ninja-gcc",
              tool_data = { generator = "Ninja", compiler_id = "gcc" },
              tool_label = "Ninja GCC",
              tool_mod_type = "cmake",
              projects = { Lib = { config_key = "Debug:ninja-gcc" } },
            },
            ["debug:ninja-clang"] = {
              configuration_set = "debug",
              tool_key = "ninja-clang",
              tool_data = { generator = "Ninja", compiler_id = "clang" },
              tool_label = "Ninja Clang",
              tool_mod_type = "cmake",
              projects = { Lib = { config_key = "Debug:ninja-clang" } },
            },
          },
          projects = {
            Lib = {
              type = "cmake",
              configurations = {
                ["Debug:ninja-gcc"] = {
                  state = "built",
                  variant = "Debug",
                  tool_key = "ninja-gcc",
                  build_dir = "/root/.nvim/build/Lib/Debug-gcc",
                },
                ["Debug:ninja-clang"] = {
                  state = "configured",
                  variant = "Debug",
                  tool_key = "ninja-clang",
                  build_dir = "/root/.nvim/build/Lib/Debug-clang",
                },
              },
            },
          },
        },
        {
          tools_by_type = {
            cmake = {
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
              { tool_key = "ninja-clang", tool_data = { generator = "Ninja", compiler_id = "clang" }, tool_label = "Ninja Clang" },
            },
          },
        }
      )
      setup({ root = "/root" })

      assert_cache_coherent(core, "keyed tool profiles pre-cached")
      assert.equals(2, count_cached_configs(core))

      -- Both profiles should exist (cached + auto-generated overlap is fine)
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["debug:ninja-gcc"])
      assert.is_not_nil(ws.cache.profiles["debug:ninja-clang"])
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
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_coherent(core, "before delete")

      local profile = core:get_profile("debug")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      core:execute_deletion(plan, { deactivate_profile = profile.key })

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
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
                production = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/production",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- "production" was orphaned and adopted as ad-hoc
      assert_cache_coherent(core, "after init with orphan")
      assert.equals(2, count_profiles(core))
      assert.equals(2, count_cached_configs(core))

      -- Delete the full profile — only "development" is unreferenced
      local profile = core:get_profile("debug")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      assert.equals("development", plan.items[1].config_key)

      core:execute_deletion(plan, { deactivate_profile = profile.key })
      assert_cache_coherent(core, "after delete, orphan-adopted survives")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls)

      -- The adopted ad-hoc profile for production should still exist
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["adhoc:App:production"])
      assert.is_not_nil(ws.cache.projects.App.configurations.production)
    end)

    it("init with cache referencing tools no longer detected", function()
      -- Cache has a profile with a tool that detection no longer returns.
      -- The cached profile should still be functional since cache stores tool data.
      local core, _, setup = make_tracked_core(
        {
          projects = { Lib = { cmake = {} } },
          configuration_sets = { debug = { Lib = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-old-compiler"] = {
              configuration_set = "debug",
              tool_key = "ninja-old-compiler",
              tool_data = { generator = "Ninja", compiler_id = "old-compiler" },
              tool_label = "Ninja Old",
              tool_mod_type = "cmake",
              projects = { Lib = { config_key = "Debug:ninja-old-compiler" } },
            },
          },
          projects = {
            Lib = {
              type = "cmake",
              configurations = {
                ["Debug:ninja-old-compiler"] = {
                  state = "built",
                  variant = "Debug",
                  tool_key = "ninja-old-compiler",
                  tool_data = { generator = "Ninja", compiler_id = "old-compiler" },
                  build_dir = "/root/.nvim/build/Lib/Debug-old",
                },
              },
            },
          },
        },
        {
          -- Current detection only finds gcc — the old compiler is gone
          tools_by_type = {
            cmake = {
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
          },
        }
      )
      setup({ root = "/root" })

      -- Cache profile references a tool no longer detected, but it's still valid
      assert_cache_coherent(core, "stale tool in cache")
      assert.equals(1, count_cached_configs(core))

      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["debug:ninja-old-compiler"])
    end)
  end)

  describe("sequential workflow", function()

    it("build → delete → rebuild → delete leaves cache clean", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      -- First build
      core:materialize_adhoc("App", "development")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "first build")

      -- Delete
      local p1 = core:get_profile("adhoc:App:development")
      local plan1 = p1:plan_deletion()
      core:execute_deletion(plan1, { deactivate_profile = p1.key })
      assert_cache_empty(core, "first delete")

      -- Rebuild (materialize_adhoc creates a new ad-hoc)
      core:materialize_adhoc("App", "development")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "rebuild")

      -- Delete again
      local p2 = core:get_profile("adhoc:App:development")
      local plan2 = p2:plan_deletion()
      core:execute_deletion(plan2, { deactivate_profile = p2.key })
      assert_cache_empty(core, "second delete")
      assert.equals(2, #rm_calls)
    end)

    it("full profile configure → failed build → delete cleans up", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })

      core:materialize_profile("debug")

      -- Configure succeeds
      core:record_task_result({
        project_key = "App",
        configuration_key = "development",
        action = "configure",
        success = true,
        build_dir = "/root/.nvim/build/App/development",
      })
      assert_cache_coherent(core, "after configure")

      -- Build fails
      core:record_task_result({
        project_key = "App",
        configuration_key = "development",
        action = "build",
        success = false,
      })
      assert_cache_coherent(core, "after failed build")

      -- Delete profile
      local profile = core:get_profile("debug")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      core:execute_deletion(plan, { deactivate_profile = profile.key })

      assert_cache_empty(core, "after deleting failed build profile")
      assert.equals(1, #rm_calls)
    end)

    it("materialize_adhoc is idempotent", function()
      local core = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      local key1 = core:materialize_adhoc("App", "development")
      local key2 = core:materialize_adhoc("App", "development")
      assert.equals(key1, key2)
      assert.equals(1, count_profiles(core))
      assert_cache_coherent(core, "idempotent materialize")
    end)
  end)

  describe("shared config GC handoff", function()

    it("two full profiles sharing config, delete both sequentially", function()
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
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            staging = {
              configuration_set = "staging",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_coherent(core, "initial")
      assert.equals(2, count_profiles(core))

      -- Delete first profile — config reset (staging still refs it)
      local p1 = core:get_profile("debug")
      assert.is_not_nil(p1)
      local plan1 = p1:plan_deletion()
      assert.equals(1, #plan1.items)
      assert.equals("reset", plan1.items[1].disposition)
      core:execute_deletion(plan1, { deactivate_profile = p1.key })

      assert_cache_coherent(core, "after first delete")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls) -- build dir cleaned on reset

      -- Delete second profile — config now unreferenced, cleaned
      local p2 = core:get_profile("staging")
      assert.is_not_nil(p2)
      local plan2 = p2:plan_deletion()
      assert.equals(1, #plan2.items)
      assert.equals("clean", plan2.items[1].disposition)
      core:execute_deletion(plan2, { deactivate_profile = p2.key })

      assert_cache_empty(core, "after deleting both")
      assert.equals(1, #rm_calls)
      assert.truthy(rm_calls[1]:match("development"))
    end)

    it("three-way sharing: A→XY, B→YZ, C→Z — delete B keeps Y (A) and Z (C)", function()
      -- Profile A refs configs X,Y; Profile B refs Y,Z; Profile C refs Z
      -- Deleting B: Y still held by A, Z still held by C — nothing cleaned
      local core, rm_calls = make_tracked_core(
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
          profiles = {
            setA = {
              configuration_set = "setA",
              projects = {
                P1 = { config_key = "dev" },
                P2 = { config_key = "dev" },
              },
            },
            setB = {
              configuration_set = "setB",
              projects = {
                P2 = { config_key = "dev" },
                P3 = { config_key = "dev" },
              },
            },
            setC = {
              configuration_set = "setC",
              projects = {
                P3 = { config_key = "dev" },
              },
            },
          },
          projects = {
            P1 = {
              type = "typescript",
              configurations = {
                dev = { state = "built", build_dir = "/root/.nvim/build/P1/dev" },
              },
            },
            P2 = {
              type = "typescript",
              configurations = {
                dev = { state = "built", build_dir = "/root/.nvim/build/P2/dev" },
              },
            },
            P3 = {
              type = "typescript",
              configurations = {
                dev = { state = "built", build_dir = "/root/.nvim/build/P3/dev" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert_cache_coherent(core, "initial 3-way")
      assert.equals(3, count_profiles(core))
      assert.equals(3, count_cached_configs(core))

      -- Delete B — P2/dev held by A (reset), P3/dev held by C (reset)
      local pB = core:get_profile("setB")
      assert.is_not_nil(pB)
      local planB = pB:plan_deletion()
      assert.equals(2, #planB.items)
      for _, item in ipairs(planB.items) do
        assert.equals("reset", item.disposition)
      end
      core:execute_deletion(planB, { deactivate_profile = pB.key })

      assert_cache_coherent(core, "after B deleted")
      assert.equals(2, count_profiles(core))
      assert.equals(3, count_cached_configs(core))
      assert.equals(2, #rm_calls) -- P2 and P3 build dirs cleaned on reset

      -- Delete A — P1/dev unreferenced (cleaned), P2/dev already reset (cleaned)
      local pA = core:get_profile("setA")
      assert.is_not_nil(pA)
      local planA = pA:plan_deletion()
      assert.equals(2, #planA.items)
      core:execute_deletion(planA, { deactivate_profile = pA.key })

      assert_cache_coherent(core, "after A deleted")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))
      -- P1 build dir cleaned + P2 build dir was already nil from reset
      assert.equals(3, #rm_calls)

      -- Delete C — P3/dev unreferenced (cleaned, but build dir already nil from reset)
      local pC = core:get_profile("setC")
      assert.is_not_nil(pC)
      local planC = pC:plan_deletion()
      assert.equals(1, #planC.items)
      assert.equals("clean", planC.items[1].disposition)
      core:execute_deletion(planC, { deactivate_profile = pC.key })

      assert_cache_empty(core, "after all deleted")
      -- 2 from B's reset + 1 from A's clean of P1 (P2,P3 build dirs already nil)
      assert.equals(3, #rm_calls)
    end)
  end)

  describe("skeleton and unmaterialized profiles", function()

    it("delete profile that was materialized but never built", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })

      core:materialize_profile("debug")
      assert_cache_coherent(core, "after materialize")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))

      -- Config is a skeleton (no state, no build_dir)
      local ws = core:get_workspace()
      local cached = ws.cache.projects.App.configurations.development
      assert.is_nil(cached.state)
      assert.is_nil(cached.build_dir)

      -- Delete — skeleton should be cleaned even though there's nothing on disk
      local profile = core:get_profile("debug")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      core:execute_deletion(plan, { deactivate_profile = profile.key })

      assert_cache_empty(core, "after deleting unbuild profile")
      assert.equals(0, #rm_calls) -- no build dir to delete
    end)

    it("ad-hoc materialized but never built, then deleted", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })

      core:materialize_adhoc("App", "production")
      assert_cache_coherent(core, "after materialize_adhoc")
      assert.equals(1, count_profiles(core))

      local profile = core:get_profile("adhoc:App:production")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      core:execute_deletion(plan, { deactivate_profile = profile.key })

      assert_cache_empty(core, "after deleting unbuilt ad-hoc")
      assert.equals(0, #rm_calls)
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
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built", build_dir = "/root/.nvim/build/App/dev" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      local ws = core:get_workspace()
      assert.equals("debug", ws.user.active_profile)

      local profile = core:get_profile("debug")
      local plan = profile:plan_deletion()
      core:execute_deletion(plan, { deactivate_profile = profile.key })

      assert.is_nil(ws.user.active_profile)
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
              projects = { App = { config_key = "development" } },
            },
            release = {
              configuration_set = "release",
              projects = { App = { config_key = "production" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built", build_dir = "/root/.nvim/build/App/dev" },
                production = { state = "built", build_dir = "/root/.nvim/build/App/prod" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      local ws = core:get_workspace()
      assert.equals("debug", ws.user.active_profile)

      -- Delete release (not active)
      local release = core:get_profile("release")
      local plan = release:plan_deletion()
      core:execute_deletion(plan, { deactivate_profile = release.key })

      assert.equals("debug", ws.user.active_profile)
      assert_cache_coherent(core, "active profile untouched")
      assert.equals(1, count_cached_configs(core))
    end)
  end)

  describe("re-materialize after deletion", function()

    it("full profile can be re-materialized and rebuilt after deletion", function()
      local core, rm_calls = make_tracked_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })

      -- First cycle: materialize, build, delete
      core:materialize_profile("debug")
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "first build")

      local p1 = core:get_profile("debug")
      local plan1 = p1:plan_deletion()
      core:execute_deletion(plan1, { deactivate_profile = p1.key })
      assert_cache_empty(core, "after first delete")

      -- Second cycle: re-materialize the same profile
      core:materialize_profile("debug")
      assert_cache_coherent(core, "after re-materialize")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))

      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after rebuild")

      -- Can delete again cleanly
      local p2 = core:get_profile("debug")
      local plan2 = p2:plan_deletion()
      assert.equals(1, #plan2.items)
      core:execute_deletion(plan2, { deactivate_profile = p2.key })
      assert_cache_empty(core, "after second delete")
      assert.equals(2, #rm_calls)
    end)
  end)

  describe("disposition: reset vs clean", function()

    it("reset clears state but keeps cache entry skeleton", function()
      -- Two full profiles share same config. Delete one → reset.
      -- Verify config entry survives with tool fields intact but state cleared.
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
              tool_key = "ninja-gcc",
              tool_data = { generator = "Ninja", compiler_id = "gcc" },
              tool_label = "Ninja GCC",
              tool_mod_type = "cmake",
              projects = { Lib = { config_key = "Debug:ninja-gcc" } },
            },
            ["staging:ninja-gcc"] = {
              configuration_set = "staging",
              tool_key = "ninja-gcc",
              tool_data = { generator = "Ninja", compiler_id = "gcc" },
              tool_label = "Ninja GCC",
              tool_mod_type = "cmake",
              projects = { Lib = { config_key = "Debug:ninja-gcc" } },
            },
          },
          projects = {
            Lib = {
              type = "cmake",
              configurations = {
                ["Debug:ninja-gcc"] = {
                  state = "built",
                  variant = "Debug",
                  tool_key = "ninja-gcc",
                  tool_data = { generator = "Ninja", compiler_id = "gcc" },
                  build_dir = "/root/.nvim/build/Lib/Debug-gcc",
                  last_configured = "2026-03-01",
                  last_built = "2026-03-01",
                  cmake = { compile_commands = "/root/.nvim/build/Lib/Debug-gcc/compile_commands.json" },
                },
              },
            },
          },
        },
        {
          tools_by_type = {
            cmake = {
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
          },
        }
      )
      setup({ root = "/root" })
      assert_cache_coherent(core, "initial")

      -- Delete debug profile — config shared with staging → reset
      local profile = core:get_profile("debug:ninja-gcc")
      assert.is_not_nil(profile)
      local plan = profile:plan_deletion()
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)

      core:execute_deletion(plan, { deactivate_profile = profile.key })
      assert_cache_coherent(core, "after reset")

      -- Config entry still exists
      local ws = core:get_workspace()
      local cached = ws.cache.projects.Lib.configurations["Debug:ninja-gcc"]
      assert.is_not_nil(cached, "config entry should still exist after reset")

      -- State fields cleared
      assert.is_nil(cached.state)
      assert.is_nil(cached.build_dir)
      assert.is_nil(cached.last_configured)
      assert.is_nil(cached.last_built)
      assert.is_nil(cached.cmake)

      -- Tool fields preserved
      assert.equals("Debug", cached.variant)
      assert.equals("ninja-gcc", cached.tool_key)
      assert.is_not_nil(cached.tool_data)

      -- Build dir was cleaned
      assert.equals(1, #rm_calls)
      assert.truthy(rm_calls[1]:match("Debug%-gcc"))
    end)

    it("reset config can be rebuilt", function()
      -- After reset, a config should go from unconfigured → built again
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
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            staging = {
              configuration_set = "staging",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- Delete debug → config reset
      local p1 = core:get_profile("debug")
      local plan = p1:plan_deletion()
      assert.equals("reset", plan.items[1].disposition)
      core:execute_deletion(plan, { deactivate_profile = p1.key })

      -- Config is reset
      local ws = core:get_workspace()
      local cached = ws.cache.projects.App.configurations.development
      assert.is_nil(cached.state)

      -- Rebuild via staging profile
      simulate_build(core, "App", "development", "/root/.nvim/build/App/development")
      assert_cache_coherent(core, "after rebuild")

      cached = ws.cache.projects.App.configurations.development
      assert.equals("built", cached.state)
      assert.equals("/root/.nvim/build/App/development", cached.build_dir)
    end)

    it("plan_deletion always includes all items even when all shared", function()
      -- If every config is shared, plan still returns all items (all "reset")
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
              projects = { A = { config_key = "dev" }, B = { config_key = "dev" } },
            },
            staging = {
              configuration_set = "staging",
              projects = { A = { config_key = "dev" }, B = { config_key = "dev" } },
            },
          },
          projects = {
            A = {
              type = "typescript",
              configurations = {
                dev = { state = "built", build_dir = "/root/.nvim/build/A/dev" },
              },
            },
            B = {
              type = "typescript",
              configurations = {
                dev = { state = "built", build_dir = "/root/.nvim/build/B/dev" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      local profile = core:get_profile("debug")
      local plan = profile:plan_deletion()

      -- All items present (not filtered out)
      assert.equals(2, #plan.items)

      -- All are "reset" since staging holds them
      for _, item in ipairs(plan.items) do
        assert.equals("reset", item.disposition)
      end
    end)

    it("delete_config with full profile ref resets config instead of blocking", function()
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
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- plan_config_deletion should return "reset" since full profile refs it
      local plan = core:plan_config_deletion("App", "development")
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)
      assert.is_nil(plan.adhoc_profiles)

      -- Execute deletion
      core:delete_config("App", "development")
      assert_cache_coherent(core, "after config delete with full ref")

      -- Config still exists but state cleared
      local ws = core:get_workspace()
      local cached = ws.cache.projects.App.configurations.development
      assert.is_not_nil(cached, "config should survive reset")
      assert.is_nil(cached.state)
      assert.is_nil(cached.build_dir)

      -- Build dir was cleaned
      assert.equals(1, #rm_calls)

      -- Profile still intact
      assert.is_not_nil(ws.cache.profiles.debug)
    end)

    it("delete_config without full profile cleans config entirely", function()
      local core, rm_calls = make_tracked_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/development",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- plan_config_deletion should return "clean" (only ad-hoc refs)
      local plan = core:plan_config_deletion("App", "development")
      assert.equals(1, #plan.items)
      assert.equals("clean", plan.items[1].disposition)
      assert.is_not_nil(plan.adhoc_profiles)
      assert.equals(1, #plan.adhoc_profiles)

      core:delete_config("App", "development")
      assert_cache_empty(core, "after clean delete")
      assert.equals(1, #rm_calls)
    end)
  end)

  describe("find_referencing_profiles", function()

    it("only counts materialized profiles", function()
      -- Config set generates unmaterialized profiles. These should NOT
      -- count as references for GC purposes.
      local core = make_tracked_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          -- Only an ad-hoc profile is materialized; the auto-generated "debug"
          -- profile is not in the cache so it's unmaterialized.
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- The auto-generated "debug" profile exists but is unmaterialized
      local debug_profile = core:get_profile("debug")
      assert.is_not_nil(debug_profile)
      assert.is_falsy(debug_profile.materialized)

      -- find_referencing_profiles should only find the ad-hoc (materialized)
      local refs = core:find_referencing_profiles("App", "development")
      assert.equals(1, #refs)
      assert.equals("adhoc:App:development", refs[1])
    end)

    it("returns empty when only unmaterialized profiles reference config", function()
      local core = make_tracked_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })

      -- "debug" profile exists from config_sets but is not materialized
      local refs = core:find_referencing_profiles("App", "development")
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
              projects = { App = { config_key = "development" } },
            },
            staging = {
              configuration_set = "staging",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      local refs = core:find_referencing_profiles("App", "development")
      assert.equals(2, #refs)
      -- Sorted alphabetically
      assert.equals("debug", refs[1])
      assert.equals("staging", refs[2])
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

      -- Build both projects via ad-hoc
      core:materialize_adhoc("Backend", "development")
      simulate_build(core, "Backend", "development", "/root/.nvim/build/Backend/dev")
      core:materialize_adhoc("Frontend", "development")
      simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")
      assert_cache_coherent(core, "both built")
      assert.equals(2, count_profiles(core))
      assert.equals(2, count_cached_configs(core))

      -- Delete Backend config — Frontend unaffected
      core:delete_config("Backend", "development")
      assert_cache_coherent(core, "after Backend delete")
      assert.equals(1, count_profiles(core))
      assert.equals(1, count_cached_configs(core))
      assert.equals(1, #rm_calls)

      -- Frontend still fully intact
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["adhoc:Frontend:development"])
      assert.is_not_nil(ws.cache.projects.Frontend.configurations.development)
      assert.equals("built", ws.cache.projects.Frontend.configurations.development.state)
    end)

    it("delete_config removes only target from multi-config profile's reachable set", function()
      -- Full profile covers two projects. delete_config on one project's config
      -- only removes the ad-hoc, the full profile still keeps the config.
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

      core:materialize_profile("debug")
      simulate_build(core, "Backend", "development", "/root/.nvim/build/Backend/dev")
      simulate_build(core, "Frontend", "development", "/root/.nvim/build/Frontend/dev")

      -- Also pin Backend via ad-hoc
      core:materialize_adhoc("Backend", "development")
      assert_cache_coherent(core, "full + ad-hoc")

      -- delete_config on Backend — removes ad-hoc, resets config (full profile keeps it)
      core:delete_config("Backend", "development")
      assert_cache_coherent(core, "after delete_config")
      assert.equals(2, count_cached_configs(core)) -- both still there
      assert.equals(1, #rm_calls) -- Backend build dir cleaned on reset

      -- Backend config exists but state reset
      local ws = core:get_workspace()
      assert.is_nil(ws.cache.projects.Backend.configurations.development.state)

      -- Ad-hoc is gone
      local adhoc_gone = not ws.cache.profiles
          or not ws.cache.profiles["adhoc:Backend:development"]
      assert.is_true(adhoc_gone)

      -- Full profile still has both configs, Frontend untouched
      assert.is_not_nil(ws.cache.profiles.debug)
      assert.equals("built", ws.cache.projects.Frontend.configurations.development.state)
    end)
  end)
end)
